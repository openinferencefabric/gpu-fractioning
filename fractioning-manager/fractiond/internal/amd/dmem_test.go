// SPDX-License-Identifier: Apache-2.0

package amd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const bdf = "0000:07:00.0"

// fakeHost: a /sys with one 48 GiB amdgpu GPU and a cgroup v2 tree with a systemd burstable pod.
func fakeHost(t *testing.T, regions string) (Host, string) {
	t.Helper()
	root := t.TempDir()
	h := Host{SysRoot: filepath.Join(root, "sys"), CgroupRoot: filepath.Join(root, "cgroup")}
	write(t, filepath.Join(h.SysRoot, "bus/pci/devices", bdf, "mem_info_vram_total"), "51539607552\n")
	if regions != "" {
		write(t, filepath.Join(h.CgroupRoot, "dmem.capacity"), regions)
	}
	pod := filepath.Join(h.CgroupRoot, "kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod1a2b_3c.slice")
	for d := pod; ; d = filepath.Dir(d) {
		write(t, filepath.Join(d, "cgroup.subtree_control"), "cpu memory pids\n")
		if d == h.CgroupRoot {
			break
		}
	}
	return h, pod
}

func write(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestParse(t *testing.T) {
	for _, tc := range []struct {
		name string
		ann  map[string]string
		want *Request
		err  string
	}{
		{"no share", map[string]string{}, nil, ""},
		{"share", map[string]string{AnnotationGPU: bdf, AnnotationFraction: "0.25"}, &Request{bdf, 0.25}, ""},
		{"upper-case address", map[string]string{AnnotationGPU: "0000:C8:00.0", AnnotationFraction: "0.5"}, &Request{"0000:c8:00.0", 0.5}, ""},
		{"other container", map[string]string{AnnotationGPU: bdf, AnnotationContainer: "side", AnnotationFraction: "0.5"}, nil, ""},
		{"named container", map[string]string{AnnotationGPU: bdf, AnnotationContainer: "main", AnnotationFraction: "0.5"}, &Request{bdf, 0.5}, ""},
		{"no fraction", map[string]string{AnnotationGPU: bdf}, nil, ""},
		{"bad address", map[string]string{AnnotationGPU: "07:00.0", AnnotationFraction: "0.5"}, nil, "not a PCI address"},
		{"fraction 0", map[string]string{AnnotationGPU: bdf, AnnotationFraction: "0"}, nil, "between 0 and 1"},
		{"fraction 1.5", map[string]string{AnnotationGPU: bdf, AnnotationFraction: "1.5"}, nil, "between 0 and 1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Parse(tc.ann, "main")
			if tc.err != "" {
				if err == nil || !strings.Contains(err.Error(), tc.err) {
					t.Fatalf("err = %v, want %q", err, tc.err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if (got == nil) != (tc.want == nil) || (got != nil && *got != *tc.want) {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestPodDir(t *testing.T) {
	h := Host{CgroupRoot: "/cg"}
	for in, want := range map[string]string{
		"kubepods-burstable-pod1a2b_3c.slice": "/cg/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod1a2b_3c.slice",
		"kubepods-pod9.slice":                 "/cg/kubepods.slice/kubepods-pod9.slice",
		"/kubepods/burstable/pod9":            "/cg/kubepods/burstable/pod9",
	} {
		got, err := h.PodDir(in)
		if err != nil || filepath.ToSlash(got) != want {
			t.Errorf("PodDir(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "kubepods--x.slice", "-x.slice", "pod9", "a/b.slice"} {
		if _, err := h.PodDir(bad); err == nil {
			t.Errorf("PodDir(%q): no error", bad)
		}
	}
}

func TestApply(t *testing.T) {
	h, pod := fakeHost(t, "drm/"+bdf+"/vram 51539607552\n")
	limit, err := h.Apply("kubepods-burstable-pod1a2b_3c.slice", &Request{bdf, 0.25})
	if err != nil {
		t.Fatal(err)
	}
	if limit != 12884901888 {
		t.Fatalf("limit = %d, want 12 GiB", limit)
	}
	if got := read(t, filepath.Join(pod, "dmem.max")); got != "drm/"+bdf+"/vram 12884901888" {
		t.Fatalf("dmem.max = %q", got)
	}
	// dmem enabled from the root down to the pod's parent, not in the pod itself
	for d, want := range map[string]string{
		h.CgroupRoot: "+dmem",
		filepath.Join(h.CgroupRoot, "kubepods.slice"):                          "+dmem",
		filepath.Join(h.CgroupRoot, "kubepods.slice/kubepods-burstable.slice"): "+dmem",
		pod: "cpu memory pids\n",
	} {
		if got := read(t, filepath.Join(d, "cgroup.subtree_control")); got != want {
			t.Errorf("%s subtree_control = %q, want %q", d, got, want)
		}
	}
	// a second container of the pod: the same cap again
	if _, err := h.Apply("kubepods-burstable-pod1a2b_3c.slice", &Request{bdf, 0.25}); err != nil {
		t.Fatal(err)
	}
}

func TestApplyKeepsEnabledControllers(t *testing.T) {
	h, _ := fakeHost(t, "drm/"+bdf+"/vram 51539607552\n")
	write(t, filepath.Join(h.CgroupRoot, "cgroup.subtree_control"), "cpu dmem memory\n")
	if _, err := h.Apply("kubepods-burstable-pod1a2b_3c.slice", &Request{bdf, 0.5}); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(h.CgroupRoot, "cgroup.subtree_control")); got != "cpu dmem memory\n" {
		t.Fatalf("root subtree_control rewritten: %q", got)
	}
}

func TestApplyRefuses(t *testing.T) {
	t.Run("no dmem controller", func(t *testing.T) {
		h, _ := fakeHost(t, "")
		if _, err := h.Apply("kubepods-burstable-pod1a2b_3c.slice", &Request{bdf, 0.5}); err == nil || !strings.Contains(err.Error(), "no dmem") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("GPU not registered", func(t *testing.T) {
		h, _ := fakeHost(t, "drm/0000:c8:00.0/vram 1\n")
		if _, err := h.Apply("kubepods-burstable-pod1a2b_3c.slice", &Request{bdf, 0.5}); err == nil || !strings.Contains(err.Error(), "not registered") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("pod cgroup missing", func(t *testing.T) {
		h, _ := fakeHost(t, "drm/"+bdf+"/vram 51539607552\n")
		if _, err := h.Apply("kubepods-burstable-podother.slice", &Request{bdf, 0.5}); err == nil || !strings.Contains(err.Error(), "pod cgroup") {
			t.Fatalf("err = %v", err)
		}
	})
}
