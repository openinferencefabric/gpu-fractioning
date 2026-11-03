// SPDX-License-Identifier: Apache-2.0
// vram-probe: allocate WANT_GIB of VRAM on the first AMD GPU in 256 MiB steps through the HSA runtime (the KFD path
// HIP and PyTorch use), report how far it got, then hold the memory for HOLD seconds. Output matches
// test/amd/quick-dmem-cap.sh: "allocated N MiB of M MiB asked" and "HOLDING".
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static hsa_agent_t gpu;
static hsa_amd_memory_pool_t pool;
static int have_gpu, have_pool;

static hsa_status_t find_gpu(hsa_agent_t a, void *d) {
  hsa_device_type_t t;
  (void)d;
  if (hsa_agent_get_info(a, HSA_AGENT_INFO_DEVICE, &t) == HSA_STATUS_SUCCESS && t == HSA_DEVICE_TYPE_GPU) {
    gpu = a, have_gpu = 1;
    return HSA_STATUS_INFO_BREAK;
  }
  return HSA_STATUS_SUCCESS;
}

static hsa_status_t find_vram(hsa_amd_memory_pool_t p, void *d) {
  hsa_amd_segment_t seg;
  uint32_t flags;
  (void)d;
  hsa_amd_memory_pool_get_info(p, HSA_AMD_MEMORY_POOL_INFO_SEGMENT, &seg);
  hsa_amd_memory_pool_get_info(p, HSA_AMD_MEMORY_POOL_INFO_GLOBAL_FLAGS, &flags);
  if (seg == HSA_AMD_SEGMENT_GLOBAL && (flags & HSA_AMD_MEMORY_POOL_GLOBAL_FLAG_COARSE_GRAINED)) {
    pool = p, have_pool = 1;
    return HSA_STATUS_INFO_BREAK;
  }
  return HSA_STATUS_SUCCESS;
}

int main(void) {
  const char *w = getenv("WANT_GIB"), *h = getenv("HOLD"), *share = getenv("OIF_GPU_MEMORY_FRACTION"), *msg;
  uint64_t want = (uint64_t)atoll(w ? w : "1") << 30, step = 256ull << 20, got = 0;
  size_t total = 0;
  char name[64] = "";
  hsa_status_t s;
  void *p;

  if ((s = hsa_init()) != HSA_STATUS_SUCCESS) {
    hsa_status_string(s, &msg);
    printf("hsa_init failed: %s\n", msg);
    return 1;
  }
  hsa_iterate_agents(find_gpu, NULL);
  if (!have_gpu) {
    printf("no AMD GPU visible (/dev/kfd and the GPU's render node needed)\n");
    return 1;
  }
  hsa_amd_agent_iterate_memory_pools(gpu, find_vram, NULL);
  if (!have_pool) {
    printf("no VRAM pool on the GPU\n");
    return 1;
  }
  hsa_agent_get_info(gpu, HSA_AGENT_INFO_NAME, name);
  hsa_amd_memory_pool_get_info(pool, HSA_AMD_MEMORY_POOL_INFO_SIZE, &total);
  printf("start: %s, VRAM %zu MiB; share %s\n", name, total >> 20, share ? share : "none");
  fflush(stdout);
  while (got + step <= want) {
    if ((s = hsa_amd_memory_pool_allocate(pool, step, 0, &p)) != HSA_STATUS_SUCCESS) {
      hsa_status_string(s, &msg);
      printf("allocation failed after %llu MiB: %s\n", (unsigned long long)(got >> 20), msg);
      break;
    }
    got += step;
  }
  printf("allocated %llu MiB of %llu MiB asked\nHOLDING\n", (unsigned long long)(got >> 20), (unsigned long long)(want >> 20));
  fflush(stdout);
  sleep(atoi(h ? h : "30"));
  return 0;
}
