/*
 *
 */

#ifndef DGL_KERNEL_CUDA_SDDMM_CUH_
#define DGL_KERNEL_CUDA_SDDMM_CUH_

#include "../utils.h"
#include "../binary_reduce_impl_decl.h"
#include "../binary_reduce.h"
#include "atomic.cuh"
#include "../../runtime/cuda/cuda_common.h"

namespace dgl {
namespace kernel {
namespace cuda {

template <typename T>
__device__ __forceinline__ T _ldg(T* addr) {
#if __CUDA_ARCH__ >= 350
  return __ldg(addr);
#else
  return *addr;
#endif
}

template <typename Idx, typename DType,
          typename BinaryOp>
__global__ void SDDMMCooKernel(
  const DType *ufeat, const DType *vfeat, DType *out,
  const Idx *row, const Idx *col, const Idx* edge_map,
  int64_t N, int64_t M, int64_t E, int64_t reduce_size,
  const int64_t *ubcast_off, const int64_t *vbcast_off,
  int64_t ufeat_len, int64_t vfeat_len, int64_t out_len) {
  // SDDMM with COO.
  Idx ty = blockIdx.y * blockDim.y + threadIdx.y;
  const Idx stride_y = blockDim.y * gridDim.y;
  while (ty < E) {
    const Idx src = _ldg(row + ty);
    const Idx dst = _ldg(col + ty);
    const Idx eid = edge_map ? _ldg(edge_map + ty) : ty;
    const DType* lhsoff = BinaryOp::use_lhs ?
      (ufeat + src * ufeat_len * reduce_size): nullptr;
    const DType* rhsoff = BinaryOp::use_rhs ?
      (vfeat + dst * vfeat_len * reduce_size): nullptr;
    DType* outoff = out + eid * out_len;
    int tx = blockIdx.x * blockDim.x + threadIdx.x;
    const int stride_x = blockDim.x * gridDim.x;
    while (tx < out_len) {
      const Idx lhs_add = ubcast_off ? ubcast_off[tx] : tx;
      const Idx rhs_add = vbcast_off ? vbcast_off[tx] : tx;
      DType val = BinaryOp::Call(
          lhsoff + lhs_add * reduce_size,
          rhsoff + rhs_add * reduce_size,
          reduce_size, reduce_size);
      outoff[tx] = val;
      tx += stride_x;
    }
    ty += stride_y;
  }
}

// Binary search the row_offsets to find the source node of the edge id.
template <typename Idx>
__device__ __forceinline__ Idx BinarySearchSrc(const Idx *array, Idx length, Idx eid) {
  Idx lo = 0, hi = length - 1;
  while (lo < hi) {
    Idx mid = (lo + hi) >> 1;
    if (_ldg(array + mid) <= eid) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // INVARIANT: lo == hi
  if (_ldg(array + hi) == eid) {
    return hi;
  } else {
    return hi - 1;
  }
}

template <typename Idx, typename DType,
          typename BinaryOp>
__global__ void SDDMMCsrKernel(
  const DType *ufeat, const DType *vfeat, DType *out,
  const Idx *indptr, const Idx *indices, const Idx* edge_map,
  int64_t N, int64_t M, int64_t E, int64_t reduce_size,
  int64_t *ubcast_off, int64_t *vbcast_off,
  int64_t ufeat_len, int64_t vfeat_len, int64_t out_len) {
  // SDDMM with Csr.
  const bool has_idx = edge_map;
  Idx ty = blockIdx.y * blockDim.y + threadIdx.y;
  const Idx stride_y = blockDim.y * gridDim.y;
  while (ty < E) {
    const Idx src = BinarySearchSrc<Idx>(indptr, N, ty);
    const Idx dst = _ldg(indices + ty);
    const Idx eid = has_idx ? _ldg(edge_map + ty) : ty;
    int64_t tx = blockIdx.x * blockDim.x + threadIdx.x;
    const int64_t stride_x = blockDim.x * gridDim.x;
    const DType* lhsoff = BinaryOp::use_lhs ? (ufeat + src * ufeat_len): nullptr;
    const DType* rhsoff = BinaryOp::use_rhs ? (vfeat + dst * vfeat_len): nullptr;
    DType* outoff = out + eid * out_len;
    while (tx < out_len) {
      const Idx lhs_add = ubcast_off ? ubcast_off[tx] : tx;
      const Idx rhs_add = vbcast_off ? vbcast_off[tx] : tx;
      DType val = BinaryOp::Call(
          lhsoff + lhs_add * reduce_size,
          rhsoff + rhs_add * reduce_size,
          reduce_size, reduce_size);
      outoff[tx] = val;
      tx += stride_x;
    }
    ty += stride_y;
  }
}

template <typename Idx, typename DType, typename Op>
void SDDMMCoo(
    const dgl::aten::COOMatrix& coo,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) {
  const Idx *row = static_cast<Idx*>(coo.row->data);
  const Idx *col = static_cast<Idx*>(coo.col->data);
  const Idx *edge_map = aten::IsNullArray(coo.data)? nullptr : static_cast<Idx*>(coo.data->data);
  const DType *ufeat_data = aten::IsNullArray(ufeat)? nullptr : static_cast<DType*>(ufeat->data);
  const DType *vfeat_data = aten::IsNullArray(vfeat)? nullptr : static_cast<DType*>(vfeat->data);
  DType *out_data = static_cast<DType*>(out->data);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();

  int64_t *ubcast_off = nullptr, *vbcast_off = nullptr;
  int64_t len = 1;
  for (int64_t i = 1; i < out->ndim; ++i)
    len *= out->shape[i];
  int64_t reduce_dim = 1;
  if (Op::reduce_last_dim) {
    CHECK(!aten::IsNullArray(ufeat));
    reduce_dim = ufeat->shape[ufeat->ndim - 1];
  }

  const int64_t nnz = coo.row->shape[0];

  const int ntx = utils::FindNumThreads(len, 1024);
  const int nty = 1024 / ntx;
  const int nbx = (len + ntx - 1) / ntx;
  const int nby = (nnz + nty - 1) / nty;
  //LOG(INFO) << "nblks=(" << nbx << ", " << nby << ") nthrs=(" << ntx << ", " << nty << ")";
  const dim3 nblks(nbx, nby);
  const dim3 nthrs(ntx, nty);

  SDDMMCooKernel<Idx, DType, Op>
    <<<nblks, nthrs, 0, thr_entry->stream>>>(
      ufeat_data, vfeat_data, out_data,
      row, col, edge_map,
      coo.num_rows, coo.num_cols, nnz, reduce_dim,
      ubcast_off, vbcast_off,
      len, len, len
    );
}

template <typename Idx, typename DType, typename Op>
void SDDMMBcastCoo(
    const BcastInfo& info,
    const dgl::aten::COOMatrix& coo,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) {
  const Idx *row = static_cast<Idx*>(coo.row->data);
  const Idx *col = static_cast<Idx*>(coo.col->data);
  const Idx *edge_map = aten::IsNullArray(coo.data)? nullptr : static_cast<Idx*>(coo.data->data);
  const DType *ufeat_data = aten::IsNullArray(ufeat)? nullptr : static_cast<DType*>(ufeat->data);
  const DType *vfeat_data = aten::IsNullArray(vfeat)? nullptr : static_cast<DType*>(vfeat->data);
  DType *out_data = static_cast<DType*>(out->data);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  
  DLContext ctx = ufeat->ctx;
  auto device = runtime::DeviceAPI::Get(ctx); 
  int64_t *ubcast_off = static_cast<int64_t*>(
    device->AllocWorkspace(ctx, sizeof(int64_t) * info.lhs_offset.size()));
  CUDA_CALL(cudaMemcpy(ubcast_off, &info.lhs_offset[0],
    sizeof(int64_t) * info.lhs_offset.size(), cudaMemcpyHostToDevice));
  int64_t *vbcast_off = static_cast<int64_t*>(
    device->AllocWorkspace(ctx, sizeof(int64_t) * info.rhs_offset.size()));
  CUDA_CALL(cudaMemcpy(vbcast_off, &info.rhs_offset[0],
    sizeof(int64_t) * info.rhs_offset.size(), cudaMemcpyHostToDevice));

  int64_t len = 1, lhs_len = 1, rhs_len = 1;
  for (size_t i = 1; i < info.out_shape.size(); ++i) {
    len *= info.out_shape[i];
    lhs_len *= info.lhs_shape[i];
    rhs_len *= info.rhs_shape[i];
  }
  int64_t reduce_dim = 1;
  if (Op::reduce_last_dim) {
    CHECK(!aten::IsNullArray(ufeat));
    reduce_dim = ufeat->shape[ufeat->ndim - 1];
  }

  const int64_t nnz = coo.row->shape[0];

  const int ntx = utils::FindNumThreads(len, 1024);
  const int nty = 1024 / ntx;
  const int nbx = (len + ntx - 1) / ntx;
  const int nby = (nnz + nty - 1) / nty;
  //LOG(INFO) << "nblks=(" << nbx << ", " << nby << ") nthrs=(" << ntx << ", " << nty << ")";
  const dim3 nblks(nbx, nby);
  const dim3 nthrs(ntx, nty);

  SDDMMCooKernel<Idx, DType, Op>
    <<<nblks, nthrs, 0, thr_entry->stream>>>(
      ufeat_data, vfeat_data, out_data,
      row, col, edge_map,
      coo.num_rows, coo.num_cols, nnz, reduce_dim,
      ubcast_off, vbcast_off,
      lhs_len, rhs_len, len
    );
  device->FreeWorkspace(ctx, ubcast_off);
  device->FreeWorkspace(ctx, vbcast_off);
}

template <typename Idx, typename DType, typename Op>
void SDDMMCsr(
    const dgl::aten::CSRMatrix& csr,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) {
  const Idx *indptr = static_cast<Idx*>(csr.indptr->data);
  const Idx *indices = static_cast<Idx*>(csr.indices->data);
  const Idx *edge_map = aten::IsNullArray(csr.data)? nullptr : static_cast<Idx*>(csr.data->data);
  const DType *ufeat_data = aten::IsNullArray(ufeat)? nullptr : static_cast<DType*>(ufeat->data);
  const DType *vfeat_data = aten::IsNullArray(vfeat)? nullptr : static_cast<DType*>(vfeat->data);
  DType *out_data = static_cast<DType*>(out->data);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  int64_t N = csr.num_rows, M = csr.num_cols, E = csr.indices->shape[0];

  int64_t *ubcast_off = nullptr, *vbcast_off = nullptr;
  int64_t len = 1;
  for (int64_t i = 1; i < ufeat->ndim; ++i)
    len *= ufeat->shape[i];
  int64_t reduce_dim = 1;
  if (Op::reduce_last_dim) {
    CHECK(!aten::IsNullArray(ufeat));
    reduce_dim = ufeat->shape[ufeat->ndim - 1];
  }

  const dim3 nblks(E, 1);
  const dim3 nthrs(1, (128 < len) ? 128 : len);

  SDDMMCsrKernel<Idx, DType, Op>
    <<<nblks, nthrs, 0, thr_entry->stream>>>(
      ufeat_data, vfeat_data, out_data,
      indptr, indices, edge_map,
      N, M, E, reduce_dim,
      ubcast_off, vbcast_off,
      len, len, len
    );
}

template <typename Idx, typename DType, typename Op>
void SDDMMBcastCsr(
    const BcastInfo& info,
    const dgl::aten::CSRMatrix& csr,
    NDArray ufeat,
    NDArray vfeat,
    NDArray out) {
  const Idx *indptr = static_cast<Idx*>(csr.indptr->data);
  const Idx *indices = static_cast<Idx*>(csr.indices->data);
  const Idx *edge_map = aten::IsNullArray(csr.data)? nullptr : static_cast<Idx*>(csr.data->data);
  const DType *ufeat_data = aten::IsNullArray(ufeat)? nullptr : static_cast<DType*>(ufeat->data);
  const DType *vfeat_data = aten::IsNullArray(vfeat)? nullptr : static_cast<DType*>(vfeat->data);
  DType *out_data = static_cast<DType*>(out->data);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  int64_t N = csr.num_rows, M = csr.num_cols, E = csr.indices->shape[0];

  DLContext ctx = ufeat->ctx;
  auto device = runtime::DeviceAPI::Get(ctx); 
  int64_t *ubcast_off = static_cast<int64_t*>(
    device->AllocWorkspace(ctx, sizeof(int64_t) * info.lhs_offset.size()));
  CUDA_CALL(cudaMemcpy(ubcast_off, &info.lhs_offset[0],
    sizeof(int64_t) * info.lhs_offset.size(), cudaMemcpyHostToDevice));
  int64_t *vbcast_off = static_cast<int64_t*>(
    device->AllocWorkspace(ctx, sizeof(int64_t) * info.rhs_offset.size()));
  CUDA_CALL(cudaMemcpy(vbcast_off, &info.rhs_offset[0],
    sizeof(int64_t) * info.rhs_offset.size(), cudaMemcpyHostToDevice));

  int64_t len = 1, lhs_len = 1, rhs_len = 1;
  for (size_t i = 1; i < info.out_shape.size(); ++i) {
    len *= info.out_shape[i];
    lhs_len *= info.lhs_shape[i];
    rhs_len *= info.rhs_shape[i];
  }
  int64_t reduce_dim = 1;
  if (Op::reduce_last_dim) {
    CHECK(!aten::IsNullArray(ufeat));
    reduce_dim = ufeat->shape[ufeat->ndim - 1];
  }

  const dim3 nblks(E, 1);
  const dim3 nthrs(1, (128 < len) ? 128 : len);

  SDDMMCsrKernel<Idx, DType, Op>
    <<<nblks, nthrs, 0, thr_entry->stream>>>(
      ufeat_data, vfeat_data, out_data,
      indptr, indices, edge_map,
      N, M, E, reduce_dim,
      ubcast_off, vbcast_off,
      lhs_len, rhs_len, len
    );

  device->FreeWorkspace(ctx, ubcast_off);
  device->FreeWorkspace(ctx, vbcast_off);
}


}
}
}

#endif