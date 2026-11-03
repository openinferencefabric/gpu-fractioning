// SPDX-License-Identifier: Apache-2.0

// Package amd is the AMD counterpart of the memory limit fractiond applies on NVIDIA. On NVIDIA the container
// toolkit's CDI hook has the driver enforce NVIDIA_GPU_MEMORY_LIMIT; ROCm has no such hook, but since Linux 6.14
// amdgpu registers its VRAM with the dmem cgroup controller, so the kernel itself can cap a cgroup's VRAM.
//
// The cap is set on the pod's cgroup (the fraction KAI assigns belongs to the pod), before its containers start:
// the dmem controller is enabled from the cgroup root down to the pod's parent, and the pod cgroup's dmem.max gets
// "drm/<pci address>/vram <bytes>". Processes in the containers below are charged to the pod cgroup, so the kernel
// refuses allocations beyond the share (hipErrorOutOfMemory) while other pods on the same GPU are unaffected.
//
// ROCm still reports the whole GPU inside the cap (ROCm/rocm-systems#14860), so the soft limit given to PyTorch
// (OIF_GPU_MEMORY_FRACTION, set by the device plugin side) stays as the sizing hint.
package amd

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Pod annotations written by KAI's binder for a pod that shares an AMD GPU (Open Inference Fabric, ADR-032).
const (
	AnnotationGPU       = "oif.ai/amd-gpu"           // PCI address of the shared GPU, e.g. 0000:07:00.0
	AnnotationContainer = "oif.ai/amd-gpu-container" // the container that gets it; all containers when absent
	AnnotationFraction  = "oif.ai/amd-gpu-fraction"  // the pod's share of the GPU, 0 < f <= 1
)

var bdfRe = regexp.MustCompile(`^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$`)

// Host is where the cap is applied: the real /sys and /sys/fs/cgroup, or fake trees in tests.
type Host struct {
	SysRoot    string // /sys
	CgroupRoot string // /sys/fs/cgroup (cgroup v2)
}

// Request is a parsed AMD share for one container: nil when the pod shares no AMD GPU or the container is not the
// one named.
type Request struct {
	BDF      string
	Fraction float64
}

// Parse reads the share from the pod's annotations for the named container.
func Parse(ann map[string]string, ctrName string) (*Request, error) {
	bdf, ok := ann[AnnotationGPU]
	if !ok {
		return nil, nil
	}
	if c, ok := ann[AnnotationContainer]; ok && c != ctrName {
		return nil, nil
	}
	bdf = strings.ToLower(strings.TrimSpace(bdf))
	if !bdfRe.MatchString(bdf) {
		return nil, fmt.Errorf("%s=%q is not a PCI address", AnnotationGPU, bdf)
	}
	f, ok := ann[AnnotationFraction]
	if !ok {
		return nil, nil // a whole GPU or no share given: nothing to cap
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(f), 64)
	if err != nil || v <= 0 || v > 1 {
		return nil, fmt.Errorf("%s=%q is not a fraction between 0 and 1", AnnotationFraction, f)
	}
	return &Request{BDF: bdf, Fraction: v}, nil
}

// Region is the dmem region amdgpu registers for the GPU's VRAM.
func Region(bdf string) string { return "drm/" + bdf + "/vram" }

// VRAMBytes is the GPU's VRAM size from amdgpu's sysfs file.
func (h Host) VRAMBytes(bdf string) (int64, error) {
	b, err := os.ReadFile(filepath.Join(h.SysRoot, "bus/pci/devices", bdf, "mem_info_vram_total"))
	if err != nil {
		return 0, fmt.Errorf("GPU %s: VRAM size: %w", bdf, err)
	}
	return strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
}

// regionKnown: the root cgroup's dmem.capacity lists every region (a kernel without dmem, or a GPU not on amdgpu,
// has none).
func (h Host) regionKnown(region string) error {
	b, err := os.ReadFile(filepath.Join(h.CgroupRoot, "dmem.capacity"))
	if err != nil {
		return fmt.Errorf("no dmem cgroup controller (kernel 6.14 or later with amdgpu): %w", err)
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) > 0 && f[0] == region {
			return nil
		}
	}
	return fmt.Errorf("dmem region %s not registered (is the GPU on amdgpu?)", region)
}

// PodDir turns the pod's cgroup parent, as the runtime reports it, into a directory under CgroupRoot. The systemd
// driver names a slice ("kubepods-burstable-pod<uid>.slice", nested as kubepods.slice/kubepods-burstable.slice/...);
// the cgroupfs driver gives a path ("/kubepods/burstable/pod<uid>").
func (h Host) PodDir(cgroupParent string) (string, error) {
	p := strings.TrimSpace(cgroupParent)
	switch {
	case p == "":
		return "", errors.New("the runtime gave no cgroup parent for the pod")
	case strings.HasPrefix(p, "/"):
		return filepath.Join(h.CgroupRoot, filepath.Clean(p)), nil
	case strings.HasSuffix(p, ".slice") && !strings.Contains(p, "/"):
		name := strings.TrimSuffix(p, ".slice")
		if name == "" || strings.HasPrefix(name, "-") || strings.HasSuffix(name, "-") || strings.Contains(name, "--") {
			return "", fmt.Errorf("invalid slice name %q", p)
		}
		parts := strings.Split(name, "-")
		dir := h.CgroupRoot
		for i := range parts {
			dir = filepath.Join(dir, strings.Join(parts[:i+1], "-")+".slice")
		}
		return dir, nil
	}
	return "", fmt.Errorf("unrecognised cgroup parent %q", p)
}

// enableDmem adds dmem to subtree_control of every cgroup from the root down to the pod's parent, so the pod cgroup
// gets a dmem.max file. Cgroups that already have it are left alone.
func (h Host) enableDmem(podDir string) error {
	rel, err := filepath.Rel(h.CgroupRoot, filepath.Dir(podDir))
	if err != nil || strings.HasPrefix(rel, "..") {
		return fmt.Errorf("%s is not under %s", podDir, h.CgroupRoot)
	}
	dir := h.CgroupRoot
	steps := []string{""}
	if rel != "." {
		steps = append(steps, strings.Split(rel, string(filepath.Separator))...)
	}
	for _, s := range steps {
		dir = filepath.Join(dir, s)
		ctl := filepath.Join(dir, "cgroup.subtree_control")
		b, err := os.ReadFile(ctl)
		if err != nil {
			return fmt.Errorf("enable dmem: %w", err)
		}
		if hasWord(string(b), "dmem") {
			continue
		}
		if err := os.WriteFile(ctl, []byte("+dmem"), 0o644); err != nil {
			return fmt.Errorf("enable dmem in %s: %w", dir, err)
		}
	}
	return nil
}

// Apply caps the pod's VRAM on the GPU at its fraction and returns the cap in bytes. It is idempotent: every
// container of the pod may call it.
func (h Host) Apply(cgroupParent string, r *Request) (int64, error) {
	region := Region(r.BDF)
	if err := h.regionKnown(region); err != nil {
		return 0, err
	}
	vram, err := h.VRAMBytes(r.BDF)
	if err != nil {
		return 0, err
	}
	podDir, err := h.PodDir(cgroupParent)
	if err != nil {
		return 0, err
	}
	if _, err := os.Stat(podDir); err != nil {
		return 0, fmt.Errorf("pod cgroup: %w", err)
	}
	if err := h.enableDmem(podDir); err != nil {
		return 0, err
	}
	limit := int64(float64(vram) * r.Fraction)
	limit -= limit % (1 << 20) // whole MiB, as on NVIDIA
	if err := os.WriteFile(filepath.Join(podDir, "dmem.max"), []byte(fmt.Sprintf("%s %d", region, limit)), 0o644); err != nil {
		return 0, fmt.Errorf("set dmem.max of %s: %w", podDir, err)
	}
	return limit, nil
}

func hasWord(s, w string) bool {
	for _, f := range strings.Fields(s) {
		if f == w {
			return true
		}
	}
	return false
}
