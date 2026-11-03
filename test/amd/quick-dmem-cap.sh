#!/bin/bash
# Quick lab test of fractiond's AMD backend (--gpu-vendor=amd): the kernel caps a fractional AMD pod's VRAM.
# On an Open Inference Fabric cluster (KAI places AMD fractions, oif-amd-share gives the pod the GPU): pods ask the
# scheduler for a share of the AMD GPU, then try to allocate far more than that share (vram-probe: HSA, the KFD path HIP uses).
#   1. control, no plugin:   a 0.25 pod allocates 30 GiB (nothing stops it)
#   2. fractiond --gpu-vendor=amd running on the GPU node:
#        the 0.25 pod is stopped near 1/4 of the VRAM (dmem.max on its pod cgroup, hipErrorOutOfMemory)
#        a 0.5 neighbour on the same GPU allocates 20 GiB meanwhile
# Run on the lab host with passwordless 'ssh <control node>' and 'ssh <GPU node>'; the fractiond binary next to this
# script. Undoes everything at the end (pods, plugin process, dmem enabled on the node's cgroups).
#   ./quick-dmem-cap.sh [control-node] [amd-gpu-node] [namespace]     defaults: cp1 gpu-amd runai-team-c
set -euo pipefail
CP=${1:-cp1} NODE=${2:-gpu-amd} NS=${3:-runai-team-c}
D=$(cd "$(dirname "$0")" && pwd) OUT=$D/results-$(date +%Y%m%d-%H%M).txt
REMOTE=/var/tmp/oif-gf
IMAGE=${VRAM_PROBE_IMAGE:-docker.io/manmohanbrahma/oif-vram-probe:0.1@sha256:7b5b53e667c3f6cc940d64516db6395ecb00f160d8185bf58f8d06b8d20c9560}   # built from vram-probe/
say() { echo "$*" | tee -a "$OUT"; }
die() { say "FAIL: $*"; exit 1; }
k() { ssh "$CP" sudo kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
g() { ssh "$NODE" "$@"; }

pod() {   # name fraction want_gib hold_s: a KAI-scheduled pod on the amd pool that allocates want_gib
  cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels: {runai/node-pool: amd, app.kubernetes.io/part-of: gf-amd-test}
  annotations: {gpu-fraction: "$2"}
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  nodeSelector: {kubernetes.io/hostname: $NODE}
  containers:
    - name: main
      image: $IMAGE
      env: [{name: WANT_GIB, value: "$3"}, {name: HOLD, value: "$4"}]
EOF
}

wait_hold() {   # pod: until it prints HOLDING or ends (the first run pulls the image)
  local i phase
  for i in $(seq 1 360); do
    k -n "$NS" logs "$1" 2>/dev/null | grep -q HOLDING && return 0
    phase=$(k -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case $phase in Succeeded|Failed) return 0 ;; esac
    sleep 5
  done
  die "$1 did not start in 30 min: $(k -n "$NS" get pod "$1" -o wide 2>&1 | tail -1)"
}

pod_dmem() {   # pod: dmem.max and dmem.current of its pod cgroup on the node
  local uid; uid=$(k -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}')
  g "d=\$(find /sys/fs/cgroup/kubepods.slice -maxdepth 2 -type d -name '*pod${uid//-/_}.slice' | head -1)
     [ -n \"\$d\" ] || { echo 'pod cgroup not found'; exit 0; }
     echo \"dmem.max: \$(cat \$d/dmem.max 2>/dev/null || echo 'no file (dmem not enabled above the pod)')\"
     echo \"dmem.current: \$(awk '{printf \"%s %d MiB\", \$1, \$2/1048576}' \$d/dmem.current 2>/dev/null)\""
}

show() { k -n "$NS" logs "$1" 2>&1 | grep -v HOLDING | sed "s/^/   $1: /" | tee -a "$OUT"; pod_dmem "$1" | sed "s/^/   $1 /" | tee -a "$OUT"; }

cleanup() {
  set +e
  k -n "$NS" delete pod -l app.kubernetes.io/part-of=gf-amd-test --wait=true --timeout=120s >/dev/null 2>&1
  # the plugin (by its own PID), then dmem off again, bottom-up, only where it was off before the test
  g "sudo sh -c '[ -f $REMOTE/pid ] && kill \$(cat $REMOTE/pid); sleep 1
     for c in $DMEM_OFF; do
       grep -qw dmem \$c/cgroup.subtree_control 2>/dev/null && echo -dmem > \$c/cgroup.subtree_control 2>/dev/null; done
     rm -rf $REMOTE'"
  say "cleanup: test pods, plugin, dmem settings fractiond added and $REMOTE on $NODE removed"
}

: > "$OUT"
say "== fractiond AMD backend quick test, $(date -u '+%F %T UTC'); node $NODE, namespace $NS"
[ -x "$D/fractiond" ] || chmod +x "$D/fractiond"
k get node "$NODE" >/dev/null || die "node $NODE not in the cluster"
k get ns "$NS" >/dev/null || die "namespace $NS not found (Run:ai project with an AMD GPU)"
say "node: kernel $(g uname -r); dmem regions: $(g cat /sys/fs/cgroup/dmem.capacity 2>/dev/null | tr '\n' ' ')"
g grep -q '^drm/.*/vram' /sys/fs/cgroup/dmem.capacity || die "no amdgpu VRAM region in dmem.capacity on $NODE (kernel 6.14+, GPU on amdgpu)"
# the kubelet usually enables every controller down the kubepods tree, dmem included; remember the levels it is off in
# (bottom-up), so cleanup turns off only what fractiond turned on
DMEM_OFF=$(g "for c in /sys/fs/cgroup /sys/fs/cgroup/kubepods.slice /sys/fs/cgroup/kubepods.slice/kubepods-*.slice; do
  grep -qw dmem \$c/cgroup.subtree_control || echo \$c; done | tac | xargs")
say "dmem off before the test in: ${DMEM_OFF:-none (already enabled down to the pods)}"
trap cleanup EXIT

say; say "1. control, no plugin: a 0.25 pod asks for 30 GiB"
pod ctl-a 0.25 30 20; wait_hold ctl-a; show ctl-a
k -n "$NS" delete pod ctl-a --wait=true >/dev/null

say; say "2. fractiond --gpu-vendor=amd on $NODE"
g "mkdir -p $REMOTE" && scp -q "$D/fractiond" "$NODE:$REMOTE/fractiond"
g "sudo sh -c 'cd $REMOTE && nohup ./fractiond --gpu-vendor=amd --plugin-name=oif-amd-dmem --plugin-idx=20 --readiness-port=0 --map-dir=$REMOTE/map > $REMOTE/fractiond.log 2>&1 & echo \$! > $REMOTE/pid'"
for _ in $(seq 1 30); do g "grep -q 'synchroniz' $REMOTE/fractiond.log" && break; sleep 1; done
g "grep -q 'synchroniz' $REMOTE/fractiond.log" || { g "tail -20 $REMOTE/fractiond.log"; die "fractiond did not register with containerd's NRI"; }
say "   registered with NRI"
say "   a 0.25 pod asks for 30 GiB; a 0.5 neighbour asks for 20 GiB at the same time"
pod cap-a 0.25 30 60; pod nb-b 0.5 20 30
wait_hold cap-a; wait_hold nb-b; show cap-a; show nb-b
say "   fractiond: $(g "grep -h 'capped AMD GPU memory' $REMOTE/fractiond.log" | sed 's/.*msg=//' | tr '\n' ' ')"

say; say "verdict:"
ctl=$(grep -o 'ctl-a: allocated [0-9]*' "$OUT" | awk '{print $3}'); cap=$(grep -o 'cap-a: allocated [0-9]*' "$OUT" | awk '{print $3}')
nb=$(grep -o 'nb-b: allocated [0-9]*' "$OUT" | awk '{print $3}')
max=$(grep -o 'cap-a dmem.max: drm/[^ ]* [0-9]*' "$OUT" | awk '{print int($4 / 1048576)}')
ok=1
[ "${ctl:-0}" -ge 30000 ] && say "   PASS control got ${ctl} MiB without the plugin" || { say "   FAIL control got ${ctl:-?} MiB"; ok=0; }
[ -n "$cap" ] && [ -n "$max" ] && [ "$cap" -le "$max" ] && [ "$cap" -ge $(( max - 2048 )) ] \
  && say "   PASS the 0.25 pod was stopped at ${cap} MiB by its cap of ${max} MiB" || { say "   FAIL the 0.25 pod got ${cap:-?} MiB, cap ${max:-none}"; ok=0; }
[ "${nb:-0}" -ge 20480 ] && say "   PASS the 0.5 neighbour got ${nb} MiB alongside" || { say "   FAIL the neighbour got ${nb:-?} MiB"; ok=0; }
say; [ $ok = 1 ] && say "RESULT: PASS" || say "RESULT: FAIL"; say "results: $OUT"
