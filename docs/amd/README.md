# GPU fractioning on AMD GPUs (Open Inference Fabric fork)

This fork adds an AMD backend to `fractiond`, the NRI plugin that enforces a fractional GPU's memory limit. With `--gpu-vendor=amd` (or `GPU_VENDOR=amd`), `fractiond` caps the VRAM of a pod that shares an AMD GPU, using the Linux `dmem` cgroup controller.

## How the NVIDIA mechanism maps to AMD

| NVIDIA (upstream) | AMD (this fork) | Status |
|---|---|---|
| `fractiond` injects `NVIDIA_GPU_MEMORY_LIMIT`, and the container toolkit's CDI hook has the driver enforce it | `fractiond` writes `dmem.max` (`drm/<pci address>/vram <bytes>`) on the pod's cgroup, and the kernel enforces it (Linux 6.14+, amdgpu) | **implemented** |
| `cudaMemGetInfo` reports the limit | `hipMemGetInfo` still reports the whole GPU, so PyTorch's `per_process_memory_fraction` stays as the sizing hint | ROCm/rocm-systems#14860 |
| `mpsd` and `sm-sharing` (MPS) | No AMD equivalent. `HSA_CU_MASK` is only set by the process itself | not ported |
| `metricsd`: NVML per process | Memory per pod from `dmem.current`. ROCm has no per-process compute time yet | ROCm/rocm-systems#14861 |
| Device assignment (`NVIDIA_VISIBLE_DEVICES`, CDI) | `/dev/kfd` and the GPU's DRM nodes, given by `oif-amd-share` | in Open Inference Fabric |

## How the cap works

1. KAI's binder names the GPU and the pod's share in two annotations: `oif.ai/amd-gpu` and `oif.ai/amd-gpu-fraction`.
2. On `CreateContainer`, `fractiond` checks that the GPU's region is listed in `/sys/fs/cgroup/dmem.capacity`.
3. It enables `dmem` in `cgroup.subtree_control` from the root down to the pod's parent, wherever it is not on yet. The kubelet usually has it on already, because it enables every controller the kernel offers.
4. It sets `dmem.max = fraction × VRAM` on the pod cgroup.
5. The containers' allocations are charged to that pod cgroup. Past the share, `hipMalloc` fails with `hipErrorOutOfMemory`. Other pods on the same GPU are unaffected.

If the share cannot be capped, the container is refused, unless `--fail-open` is set. This matches the NVIDIA path.

Retroactive enforcement is NVIDIA-only and is turned off for AMD.

## Test

- **Unit tests:** `go test ./fractioning-manager/fractiond/internal/amd/`. These need Linux, because PCI addresses contain colons.
- **Lab test:** `test/amd/quick-dmem-cap.sh`, on an Open Inference Fabric cluster.
