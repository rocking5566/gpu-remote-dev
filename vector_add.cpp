#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>

#define HIP_CHECK(cmd)                                                      \
  do {                                                                      \
    hipError_t e = (cmd);                                                   \
    if (e != hipSuccess) {                                                  \
      fprintf(stderr, "HIP error %s at %s:%d\n",                           \
              hipGetErrorString(e), __FILE__, __LINE__);                    \
      exit(1);                                                              \
    }                                                                       \
  } while (0)

__global__ void vector_add(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}

int main() {
  const int n = 256;
  const size_t bytes = n * sizeof(float);

  float *ha = (float*)malloc(bytes);
  float *hb = (float*)malloc(bytes);
  float *hc = (float*)malloc(bytes);
  for (int i = 0; i < n; ++i) { ha[i] = (float)i; hb[i] = (float)(2 * i); }

  float *da, *db, *dc;
  HIP_CHECK(hipMalloc(&da, bytes));
  HIP_CHECK(hipMalloc(&db, bytes));
  HIP_CHECK(hipMalloc(&dc, bytes));

  HIP_CHECK(hipMemcpy(da, ha, bytes, hipMemcpyHostToDevice));
  HIP_CHECK(hipMemcpy(db, hb, bytes, hipMemcpyHostToDevice));

  const int threads = 64;
  const int blocks = (n + threads - 1) / threads;
  vector_add<<<dim3(blocks), dim3(threads), 0, 0>>>(da, db, dc, n);
  HIP_CHECK(hipGetLastError());
  HIP_CHECK(hipDeviceSynchronize());

  HIP_CHECK(hipMemcpy(hc, dc, bytes, hipMemcpyDeviceToHost));

  int errors = 0;
  for (int i = 0; i < n; ++i) {
    float expected = ha[i] + hb[i];
    if (fabsf(hc[i] - expected) > 1e-5f) {
      if (errors < 5)
        fprintf(stderr, "mismatch at %d: got %f expected %f\n", i, hc[i], expected);
      ++errors;
    }
  }

  HIP_CHECK(hipFree(da));
  HIP_CHECK(hipFree(db));
  HIP_CHECK(hipFree(dc));
  free(ha); free(hb); free(hc);

  if (errors == 0) {
    printf("vector_add PASSED (n=%d)\n", n);
    return 0;
  } else {
    printf("vector_add FAILED (%d errors)\n", errors);
    return 1;
  }
}
