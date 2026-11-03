#!/bin/bash
# Serving benchmark of GPU fractions, the same on both vendors: vLLM 0.19.1 with a small model on an Open Inference
# Fabric cluster, KAI placing the pods. The node's oif.ai/gpu-vendor label picks the vendor:
#   amd     memory capped by fractiond's AMD backend (dmem; started by this script from the binary next to it)
#   nvidia  memory capped by Run:ai's gpu-fractioning (its fractiond already runs on the node, driver r615)
#   A. whole GPU                                         baseline
#   B. one 0.5 pod                                       what the cap costs
#   C. two 0.5 pods benchmarked at the same time         per-pod and total throughput on a shared GPU
#   D. a 0.5 pod whose vLLM asks for 0.9                 AMD: the kernel refuses it at the cap; NVIDIA: it sees only
#                                                        its share (the limit is transparent) and fits
# The 0.5 pods get the same KV budget on both: ROCm reports the whole GPU, so 0.45 there; CUDA reports the share, 0.9.
# PyTorch's own cap from oif-amd-share is lifted in the AMD pods: the only memory limit is dmem.
# Run on the lab host with passwordless 'ssh <control node>' and 'ssh <GPU node>'.
# Undoes everything at the end (pods, the AMD plugin and the dmem it enabled, the model cache unless KEEP_CACHE=1);
# the vLLM image stays in the node's containerd.
#   ./bench-qwen3.sh [control-node] [gpu-node] [namespace]     defaults: cp1 gpu-amd runai-team-c
set -euo pipefail
CP=${1:-cp1} NODE=${2:-gpu-amd} NS=${3:-runai-team-c}
MODEL=${MODEL:-Qwen/Qwen3-0.6B} ISL=${ISL:-512} OSL=${OSL:-128} CONCURRENCY=${CONCURRENCY:-"1 8 32"}
D=$(cd "$(dirname "$0")" && pwd) REMOTE=/var/tmp/oif-gf CACHE=/var/tmp/oif-bench/hf
k() { ssh "$CP" sudo kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }
g() { ssh "$NODE" "$@"; }

VENDOR=$(k get node "$NODE" -L oif.ai/gpu-vendor --no-headers | awk '{print $NF}')   # no jsonpath: ssh's shell eats escapes
case $VENDOR in
  amd) IMAGE=${VLLM_IMAGE:-docker.io/rocm/vllm:rocm7.13.0_gfx110X-all_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1@sha256:09dcd1437d20f70c60a91d4ece04e73e4c72b341d9da2a9546fe6bb3b4eec4e4}
    GPU_RES=amd.com/gpu HALF_UTIL=0.45 SIZE="10.6 GB" ;;
  nvidia) IMAGE=${VLLM_IMAGE:-docker.io/vllm/vllm-openai:v0.19.1@sha256:2622f38a0aa646c15ccc27bd5033911a58fd94ac69fd8f86aba0692d77cfe5b9}
    GPU_RES=nvidia.com/gpu HALF_UTIL=0.9 SIZE="9.8 GB" ;;
  *) echo "node $NODE has no oif.ai/gpu-vendor label (amd or nvidia)"; exit 1 ;;
esac
P=${VENDOR:0:3} RD=$D/bench-$VENDOR-$(date +%Y%m%d-%H%M); mkdir -p "$RD"; OUT=$RD/console.txt
say() { echo "$*" | tee -a "$OUT"; }
die() { say "FAIL: $*"; exit 1; }

pod() {   # name gpu(whole|fraction) gpu-memory-utilization: a KAI-scheduled vLLM server in the vendor's pool
  local res="" ann=""
  if [ "$2" = whole ]; then res="resources: {limits: {$GPU_RES: 1}}"; else ann="annotations: {gpu-fraction: \"$2\"}"; fi
  cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels: {runai/node-pool: $VENDOR, app.kubernetes.io/part-of: gf-bench-$VENDOR}
  $ann
spec:
  schedulerName: runai-scheduler
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
  nodeSelector: {kubernetes.io/hostname: $NODE}
  containers:
    - name: main
      image: $IMAGE
      command: [sh, -c, "unset PYTORCH_ALLOC_CONF PYTORCH_HIP_ALLOC_CONF PYTORCH_CUDA_ALLOC_CONF; exec vllm serve $MODEL --gpu-memory-utilization $3 --max-model-len 4096 --port 8000"]
      env: [{name: HF_HOME, value: /hf}]
      $res
      volumeMounts: [{name: hf, mountPath: /hf}, {name: shm, mountPath: /dev/shm}]
  volumes:
    - {name: hf, hostPath: {path: $CACHE, type: DirectoryOrCreate}}
    - {name: shm, emptyDir: {medium: Memory, sizeLimit: 4Gi}}
EOF
}

wait_ready() {   # pod: until vLLM answers, or the pod ends (returns 1)
  local i phase
  for i in $(seq 1 180); do
    k -n "$NS" logs "$1" 2>/dev/null | grep -q 'Application startup complete' && return 0
    phase=$(k -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case $phase in Succeeded|Failed) return 1 ;; esac
    sleep 5
  done
  die "$1: vLLM not ready in 15 min: $(k -n "$NS" logs "$1" 2>&1 | tail -3)"
}

pod_mem() {   # pod: its GPU memory cap and use, one line (AMD: dmem of the pod cgroup; NVIDIA: what the container sees)
  if [ "$VENDOR" = nvidia ]; then
    k -n "$NS" exec "$1" -- nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null \
      | awk -F', *' '{printf "sees %d MiB, in use %d MiB\n", $1, $2}'
    return
  fi
  local uid; uid=$(k -n "$NS" get pod "$1" -o jsonpath='{.metadata.uid}')
  g "d=\$(find /sys/fs/cgroup/kubepods.slice -maxdepth 2 -type d -name '*pod${uid//-/_}.slice' | head -1)
     [ -n \"\$d\" ] || { echo 'pod cgroup gone'; exit 0; }
     awk '{print \$2}' \$d/dmem.max | { read m; case \$m in max) echo -n 'cap none';; *) echo -n \"cap \$((m/1048576)) MiB\";; esac; }
     awk '{printf \", in use %d MiB\n\", \$2/1048576}' \$d/dmem.current"
}

bench() {   # pod label: vllm bench serve at each concurrency, results to $RD/<label>-c<n>.json
  local c n
  for c in $CONCURRENCY; do
    n=$(( c * 8 )); [ $n -lt 16 ] && n=16
    k -n "$NS" exec "$1" -- vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 --model "$MODEL" \
      --dataset-name random --random-input-len "$ISL" --random-output-len "$OSL" --ignore-eos --num-prompts $n \
      --max-concurrency "$c" --percentile-metrics ttft,tpot,e2el --metric-percentiles 50,99 \
      --save-result --result-dir /tmp/bench --result-filename "$2-c$c.json" > "$RD/$2-c$c.log" 2>&1 \
      || { tail -5 "$RD/$2-c$c.log"; die "$2: benchmark at concurrency $c failed"; }
    k -n "$NS" exec "$1" -- cat "/tmp/bench/$2-c$c.json" > "$RD/$2-c$c.json"
    say "   $2 concurrency $c: done ($n requests)"
  done
}

stop() { k -n "$NS" delete pod "$@" --wait=true --timeout=120s >/dev/null 2>&1 || true; }

cleanup() {
  set +e
  k -n "$NS" delete pod -l app.kubernetes.io/part-of=gf-bench-$VENDOR --wait=true --timeout=120s >/dev/null 2>&1
  g "sudo sh -c '[ -f $REMOTE/pid ] && kill \$(cat $REMOTE/pid); sleep 1
     for c in $DMEM_OFF; do
       grep -qw dmem \$c/cgroup.subtree_control 2>/dev/null && echo -dmem > \$c/cgroup.subtree_control 2>/dev/null; done
     rm -rf $REMOTE; [ \"${KEEP_CACHE:-0}\" = 1 ] || rm -rf /var/tmp/oif-bench'"
  say "cleanup: bench pods$([ "$VENDOR" = amd ] && echo ", plugin, dmem settings fractiond added, $REMOTE")$([ "${KEEP_CACHE:-0}" = 1 ] || echo " and the model cache") on $NODE removed"
}

say "== GPU fractions, vLLM benchmark ($VENDOR), $(date -u '+%F %T UTC')"
say "node $NODE, namespace $NS, model $MODEL, input $ISL / output $OSL tokens, concurrency $CONCURRENCY"
k get ns "$NS" >/dev/null || die "namespace $NS not found"
DMEM_OFF=""
if [ "$VENDOR" = amd ]; then
  [ -x "$D/fractiond" ] || chmod +x "$D/fractiond"
  say "node: kernel $(g uname -r); $(g cat /sys/fs/cgroup/dmem.capacity | tr '\n' ' ')"
  g grep -q '^drm/.*/vram' /sys/fs/cgroup/dmem.capacity || die "no amdgpu VRAM region in dmem.capacity on $NODE"
  DMEM_OFF=$(g "for c in /sys/fs/cgroup /sys/fs/cgroup/kubepods.slice /sys/fs/cgroup/kubepods.slice/kubepods-*.slice; do
    grep -qw dmem \$c/cgroup.subtree_control || echo \$c; done | tac | xargs")
else
  say "node: kernel $(g uname -r); $(g nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader)"
  k -n runai get pods -o wide --no-headers 2>/dev/null | grep "$NODE" | grep -q 'gpu-fractioning-fractiond.*Running' \
    || die "Run:ai's gpu-fractioning fractiond is not running on $NODE (NVIDIA driver r615 needed)"
fi
trap cleanup EXIT

# the kubelet pulls one image at a time and says nothing meanwhile: pull here first, with progress
if ! g "sudo crictl inspecti $IMAGE" >/dev/null 2>&1; then
  say; say "pulling the vLLM image on $NODE (about $SIZE)"
  g "sudo crictl pull $IMAGE" > "$RD/pull.log" 2>&1 & pull=$!
  while kill -0 $pull 2>/dev/null; do
    sleep 30; echo "   $(g "sudo du -sh /oif/containerd/io.containerd.content.v1.content 2>/dev/null | cut -f1") in the content store"
  done
  wait $pull || { cat "$RD/pull.log"; die "image pull failed"; }
fi

# one benchmark at a time: both GPUs throttle when loaded together on the lab chassis (ADR-009)
others() { ps -eo sid=,args= | awk -v s="$(ps -o sid= $$ | tr -d ' ')" '$1 != s && /bench-qwen3\.sh/ && !/awk/' | grep -q .; }
if others; then
  say "waiting for the other benchmark on this host to finish (one GPU loaded at a time)"
  while others; do sleep 30; done
fi

if [ "$VENDOR" = amd ]; then
  g "mkdir -p $REMOTE" && scp -q "$D/fractiond" "$NODE:$REMOTE/fractiond"
  g "sudo sh -c 'cd $REMOTE && nohup ./fractiond --gpu-vendor=amd --plugin-name=oif-amd-dmem --plugin-idx=20 --readiness-port=0 --map-dir=$REMOTE/map > $REMOTE/fractiond.log 2>&1 & echo \$! > $REMOTE/pid'"
  for _ in $(seq 1 30); do g "grep -q 'synchroniz' $REMOTE/fractiond.log" && break; sleep 1; done
  g "grep -q 'synchroniz' $REMOTE/fractiond.log" || die "fractiond did not register with containerd's NRI"
  say "fractiond --gpu-vendor=amd registered with NRI on $NODE"
else
  say "memory limits by Run:ai's gpu-fractioning (fractiond running on $NODE)"
fi

say; say "A. whole GPU, vLLM at 0.9 (the first start downloads the model)"
pod $P-whole whole 0.9; wait_ready $P-whole || die "$P-whole: $(k -n "$NS" logs $P-whole 2>&1 | tail -3)"
say "   $P-whole $(pod_mem $P-whole)"; bench $P-whole A-whole; stop $P-whole

say; say "B. one 0.5 pod with the hard cap, vLLM at $HALF_UTIL"
pod $P-half 0.5 $HALF_UTIL; wait_ready $P-half || die "$P-half: $(k -n "$NS" logs $P-half 2>&1 | tail -3)"
say "   $P-half $(pod_mem $P-half)"; bench $P-half B-half

say; say "C. two 0.5 pods on the same GPU, benchmarked together"
pod $P-half2 0.5 $HALF_UTIL; wait_ready $P-half2 || die "$P-half2: $(k -n "$NS" logs $P-half2 2>&1 | tail -3)"
say "   $P-half  $(pod_mem $P-half)"; say "   $P-half2 $(pod_mem $P-half2)"
bench $P-half C-pod1 & b1=$!; bench $P-half2 C-pod2 & b2=$!
wait $b1 && wait $b2 || die "concurrent benchmark failed"
stop $P-half $P-half2

say; say "D. a 0.5 pod whose vLLM asks for 0.9 of the memory it sees"
pod $P-greedy 0.5 0.9
if wait_ready $P-greedy; then
  refused=0; say "   $P-greedy $(pod_mem $P-greedy)"
  if [ "$VENDOR" = nvidia ]; then say "   started inside its share: the limit is transparent (vLLM sees only the share)"
  else say "   FAIL vLLM started past its cap"; fi
else
  refused=1; say "   $P-greedy $(pod_mem $P-greedy)"
  k -n "$NS" logs $P-greedy 2>&1 | grep -iE 'out of memory|OutOfMemory|hipError|cudaError' | tail -2 | cut -c1-220 | sed "s/^/   $P-greedy: /" | tee -a "$OUT"
fi
stop $P-greedy
[ "$VENDOR" = amd ] && say "   fractiond: $(g "grep -h 'capped AMD GPU memory' $REMOTE/fractiond.log" | sed -E 's/.*"pod":"([^"]*)".*"limitMiB":([0-9]+).*/\1=\2 MiB/' | tr '\n' ' ')"

say; say "results (median / p99 in ms; throughput in output tokens/s):"
python3 - "$RD" <<'PY' | tee -a "$OUT"
import glob, json, os, re, sys
rows = {}
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*-c*.json"))):
    m = re.match(r"(.+)-c(\d+)\.json", os.path.basename(f)); d = json.load(open(f))
    rows.setdefault(int(m.group(2)), {})[m.group(1)] = d
hdr = "%-11s %-6s %15s %13s %15s %10s" % ("run", "conc.", "TTFT med/p99", "TPOT med", "latency med", "tok/s")
print("   " + hdr); print("   " + "-" * len(hdr))
for c in sorted(rows):
    tot = 0
    for name, d in sorted(rows[c].items()):
        print("   %-11s %-6d %7.0f / %5.0f %13.1f %15.0f %10.0f" % (name, c, d["median_ttft_ms"], d["p99_ttft_ms"],
              d["median_tpot_ms"], d["median_e2el_ms"], d["output_throughput"]))
        if name.startswith("C-"): tot += d["output_throughput"]
    if tot: print("   %-11s %-6d %15s %13s %15s %10.0f" % ("C-total", c, "", "", "", tot))
PY
say
case $VENDOR:$refused in
  amd:1) say "RESULT: done; the cap refused the greedy pod" ;;
  nvidia:0) say "RESULT: done; the greedy pod fit inside its share" ;;
  *) say "RESULT: done; WARNING scenario D behaved unexpectedly (see above)" ;;
esac
say "results: $RD"
