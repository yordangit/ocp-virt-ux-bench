#!/bin/bash
#
# Guest UX bench — runs on a bastion with oc/virtctl pre-configured.
# Deploys a Fedora VM, measures user-experience metrics, destroys it.
# Focus: what does a user feel when working inside the VM?
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — load order: defaults ← env.sh (unset only) ← exported/CLI (already set)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set KEY=VAL only if KEY is currently unset (empty counts as set → skip/override intentional).
set_if_unset() {
    local key="$1" val="$2"
    if [[ -z "${!key+x}" ]]; then
        export "$key=$val"
    fi
}

load_env_file() {
    local file="$1" line key val
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"
        [[ "$key" == GUEST_UX_* ]] || continue
        # strip optional surrounding quotes
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
        if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        set_if_unset "$key" "$val"
    done < "$file"
}

ENV_FILE="${GUEST_UX_ENV_FILE:-$SCRIPT_DIR/env.sh}"
# When copied to /tmp on a bastion, also try sibling guest-ux-env.sh
if [[ ! -f "$ENV_FILE" && -f /tmp/guest-ux-env.sh ]]; then
    ENV_FILE=/tmp/guest-ux-env.sh
fi
load_env_file "$ENV_FILE"

# Built-in defaults when still unset (empty string from env.sh means "skip" for URLs — leave empty)
set_if_unset GUEST_UX_IMAGE fedora
set_if_unset GUEST_UX_VM_PROFILE default
set_if_unset GUEST_UX_SC ocs-storagecluster-ceph-rbd-virtualization
set_if_unset GUEST_UX_WORKER busiest
set_if_unset GUEST_UX_WORKER_MAX_CPU 80
set_if_unset GUEST_UX_WORKER_MAX_MEM 85
# External URL defaults only if unset (not if explicitly emptied)
set_if_unset GUEST_UX_GIT_URL "https://github.com/yordangit/ocp-virt-ux-bench.git"
set_if_unset GUEST_UX_PING_TARGET "8.8.8.8"
set_if_unset GUEST_UX_DNS_NAME "google.com"
set_if_unset GUEST_UX_DOWNLOAD_URL "http://speedtest.tele2.net/10MB.zip"

# Profile → size defaults (explicit CORES/MEMORY/DISK still win)
case "${GUEST_UX_VM_PROFILE}" in
    small)   _p_cores=1; _p_mem=2Gi; _p_disk=15Gi ;;
    default) _p_cores=2; _p_mem=4Gi; _p_disk=30Gi ;;
    *)       _p_cores=2; _p_mem=4Gi; _p_disk=30Gi
             echo "[$(date +%H:%M:%S)] WARNING: unknown GUEST_UX_VM_PROFILE='${GUEST_UX_VM_PROFILE}', using default sizes" >&2
             ;;
esac
set_if_unset GUEST_UX_VM_CORES "$_p_cores"
set_if_unset GUEST_UX_VM_MEMORY "$_p_mem"
set_if_unset GUEST_UX_VM_DISK "$_p_disk"

RUN_ID="perf-$(date +%s)-$$"
NAMESPACE="guest-ux-${RUN_ID}"
VM_NAME="perf-vm"
VM_STAGGER_SEC="${GUEST_UX_VM_STAGGER_SEC:-10}"
IMAGE="${GUEST_UX_IMAGE}"
# Multi-SC CSV reserved for later; use first entry today
STORAGE_CLASS="${GUEST_UX_SC%%,*}"
STORAGE_CLASS="${STORAGE_CLASS#"${STORAGE_CLASS%%[![:space:]]*}"}"
STORAGE_CLASS="${STORAGE_CLASS%"${STORAGE_CLASS##*[![:space:]]}"}"
DISK_SIZE="${GUEST_UX_VM_DISK}"
VM_CORES="${GUEST_UX_VM_CORES}"
VM_MEMORY="${GUEST_UX_VM_MEMORY}"
SSH_USER="fedora"
SSH_TIMEOUT=300
VM_READY_TIMEOUT=300
FIO_RUNTIME=15
RESULTS_DIR="/tmp/guest-ux-results-${RUN_ID}"
SSH_KEY_DIR="/tmp/guest-ux-ssh-${RUN_ID}"
CLUSTER_NAME=""

# External bench status: ok | failed | skipped (for scoring)
GIT_STATUS=skipped
PING_STATUS=skipped
DNS_STATUS=skipped
DOWNLOAD_STATUS=skipped

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR" "$SSH_KEY_DIR"
ssh-keygen -t ed25519 -f "$SSH_KEY_DIR/id_ed25519" -N "" -q
SSH_PUB_KEY=$(cat "$SSH_KEY_DIR/id_ed25519.pub")

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FATAL: $*"; cleanup; exit 1; }

declare -A TIMINGS

timer() {
    local label="$1"; shift
    local start end elapsed
    start=$(date +%s%N)
    "$@"
    local rc=$?
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))
    TIMINGS["$label"]="$elapsed"
    log "$label: ${elapsed}ms"
    return $rc
}

secs() { awk "BEGIN{printf \"%.2f\", $1/1000}"; }

# ---------------------------------------------------------------------------
# Detect cluster
# ---------------------------------------------------------------------------
detect_cluster() {
    CLUSTER_NAME=$(oc whoami --show-server 2>/dev/null | sed 's|https://api\.||;s|:.*||' || hostname -f)
    log "Cluster: $CLUSTER_NAME"
}

# ---------------------------------------------------------------------------
# Node selection — busiest | any | <name> | all (every worker under CPU/mem caps)
# ---------------------------------------------------------------------------
TARGET_NODE=""
NODE_MODE="${GUEST_UX_WORKER:-busiest}"
MAX_CPU_PCT=${GUEST_UX_WORKER_MAX_CPU:-80}
MAX_MEM_PCT=${GUEST_UX_WORKER_MAX_MEM:-85}
ELIGIBLE_WORKERS=()
SKIPPED_WORKERS=()   # "node|reason"

node_cpu_mem() {
    # sets _cpup _memp from oc adm top line; returns 1 if missing
    local node="$1" top_output="$2" top_line
    top_line=$(echo "$top_output" | grep "^${node} " || echo "")
    if [[ -z "$top_line" ]]; then
        return 1
    fi
    _cpup=$(echo "$top_line" | awk '{print $3}' | tr -d '%')
    _memp=$(echo "$top_line" | awk '{print $5}' | tr -d '%')
    return 0
}

list_worker_names() {
    local names
    # Prefer worker role; Ready only
    names=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null \
        | awk '$2 ~ /^Ready/ {print $1}')
    if [[ -z "$names" ]]; then
        # Fallback: Ready nodes that are not control-plane/master
        names=$(oc get nodes --no-headers 2>/dev/null \
            | awk '$2 ~ /^Ready/ {print $1}' \
            | while read -r n; do
                oc get node "$n" --show-labels 2>/dev/null \
                    | grep -qE 'node-role.kubernetes.io/(master|control-plane)' && continue
                echo "$n"
              done)
    fi
    echo "$names"
}

# Fill ELIGIBLE_WORKERS / SKIPPED_WORKERS using CPU+mem thresholds.
select_eligible_workers() {
    ELIGIBLE_WORKERS=()
    SKIPPED_WORKERS=()
    local top_output node _cpup _memp
    top_output=$(oc adm top nodes 2>/dev/null || true)

    log "Selecting workers (skip if cpu>=${MAX_CPU_PCT}% or mem>=${MAX_MEM_PCT}%)..."

    while read -r node; do
        [[ -z "$node" ]] && continue
        if ! node_cpu_mem "$node" "$top_output"; then
            log "  $node — skipped, no metrics"
            SKIPPED_WORKERS+=("$node|no metrics")
            continue
        fi
        if (( _cpup >= MAX_CPU_PCT )); then
            log "  $node — skipped, CPU ${_cpup}% >= ${MAX_CPU_PCT}%"
            SKIPPED_WORKERS+=("$node|cpu ${_cpup}%")
            continue
        fi
        if (( _memp >= MAX_MEM_PCT )); then
            log "  $node — skipped, memory ${_memp}% >= ${MAX_MEM_PCT}%"
            SKIPPED_WORKERS+=("$node|mem ${_memp}%")
            continue
        fi
        log "  $node — eligible (cpu=${_cpup}%, mem=${_memp}%)"
        ELIGIBLE_WORKERS+=("$node")
    done <<< "$(list_worker_names)"
}

find_busiest_node() {
    if [[ "$NODE_MODE" == "any" ]]; then
        log "Node selection: any (scheduler decides)"
        TARGET_NODE=""
        return
    fi

    if [[ "$NODE_MODE" == "all" ]]; then
        select_eligible_workers
        return
    fi

    if [[ "$NODE_MODE" != "busiest" ]]; then
        TARGET_NODE="$NODE_MODE"
        log "Node selection: pinned to $TARGET_NODE"
        return
    fi

    log "Finding busiest worker node (max cpu=${MAX_CPU_PCT}%, mem=${MAX_MEM_PCT}%)..."

    local vmi_nodes top_output
    vmi_nodes=$(oc get vmi -A -o jsonpath='{range .items[*]}{.status.nodeName}{"\n"}{end}' 2>/dev/null \
        | sort | uniq -c | sort -rn)

    if [[ -z "$vmi_nodes" ]]; then
        log "WARNING: No running VMs found, letting scheduler decide"
        return
    fi

    top_output=$(oc adm top nodes 2>/dev/null || true)

    local vm_count node _cpup _memp
    while read -r vm_count node; do
        [[ -z "$node" ]] && continue
        if ! node_cpu_mem "$node" "$top_output"; then
            log "  $node ($vm_count VMs) — skipped, no metrics"
            continue
        fi
        if (( _cpup >= MAX_CPU_PCT )); then
            log "  $node ($vm_count VMs, cpu=${_cpup}%) — skipped, CPU too high"
            continue
        fi
        if (( _memp >= MAX_MEM_PCT )); then
            log "  $node ($vm_count VMs, mem=${_memp}%) — skipped, memory too high"
            continue
        fi
        TARGET_NODE="$node"
        log "Target node: $TARGET_NODE ($vm_count VMs, cpu=${_cpup}%, mem=${_memp}%)"
        return
    done <<< "$vmi_nodes"

    log "WARNING: All VM nodes above thresholds, letting scheduler decide"
}

reset_probe_state() {
    local k
    for k in "${!TIMINGS[@]}"; do
        unset "TIMINGS[$k]"
    done
    GIT_STATUS=skipped
    PING_STATUS=skipped
    DNS_STATUS=skipped
    DOWNLOAD_STATUS=skipped
}

# ---------------------------------------------------------------------------
# Download cluster-matched virtctl
# ---------------------------------------------------------------------------
VIRTCTL_BIN="virtctl"

ensure_virtctl() {
    local url
    url=$(oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
        -o jsonpath='{.spec.links[0].href}' 2>/dev/null || echo "")
    if [[ -z "$url" ]]; then
        log "WARNING: Could not find cluster virtctl download, using system virtctl"
        return
    fi
    log "Downloading cluster-matched virtctl ..."
    local tmp_dir="$RESULTS_DIR/virtctl-bin"
    mkdir -p "$tmp_dir"
    if curl -sSL --insecure "$url" | tar xz -C "$tmp_dir" 2>/dev/null; then
        chmod +x "$tmp_dir/virtctl"
        VIRTCTL_BIN="$tmp_dir/virtctl"
        log "virtctl: $($VIRTCTL_BIN version --client 2>/dev/null | grep -oP 'GitVersion:"[^"]+"' || echo 'ok')"
    else
        log "WARNING: Failed to download virtctl, using system version"
    fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log "Cleaning up namespace $NAMESPACE ..."
    oc delete namespace "$NAMESPACE" --wait=false --ignore-not-found=true 2>/dev/null || true
    rm -rf "$SSH_KEY_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# VM Lifecycle
# ---------------------------------------------------------------------------
create_namespace() {
    log "Creating namespace $NAMESPACE"
    oc create namespace "$NAMESPACE"
    oc label namespace "$NAMESPACE" purpose=guest-ux-bench --overwrite
}

# deploy_vm [vm_name] [node_name]
# Uses globals VM_NAME / TARGET_NODE when args omitted.
deploy_vm() {
    local vm="${1:-$VM_NAME}"
    local node="${2:-$TARGET_NODE}"
    local node_msg="" node_spec=""
    if [[ -n "$node" ]]; then
        node_msg=" → node $node"
        node_spec="      nodeName: ${node}"
    fi
    log "Deploying VM $vm (image=$IMAGE, cores=$VM_CORES, mem=$VM_MEMORY, disk=$DISK_SIZE${node_msg})"

    cat <<VMEOF | oc apply -n "$NAMESPACE" -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm}
  labels:
    app: guest-ux-bench
spec:
  running: true
  template:
    metadata:
      labels:
        app: guest-ux-bench
    spec:
${node_spec}
      domain:
        cpu:
          cores: ${VM_CORES}
        memory:
          guest: ${VM_MEMORY}
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: ${VM_MEMORY}
      volumes:
      - name: rootdisk
        dataVolume:
          name: ${vm}-rootdisk
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: ${SSH_USER}
            ssh_authorized_keys:
            - ${SSH_PUB_KEY}
            packages:
            - fio
            - stress-ng
            - gcc
            - bind-utils
            runcmd:
            - [ touch, /tmp/cloud-init-done ]
  dataVolumeTemplates:
  - metadata:
      name: ${vm}-rootdisk
    spec:
      sourceRef:
        kind: DataSource
        name: ${IMAGE}
        namespace: openshift-virtualization-os-images
      storage:
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${DISK_SIZE}
VMEOF
}

wait_vm_running() {
    local vm="${1:-$VM_NAME}"
    log "Waiting for VM $vm Running (timeout=${VM_READY_TIMEOUT}s) ..."
    local waited=0 phase
    while (( waited < VM_READY_TIMEOUT )); do
        phase=$(oc get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Running" ]]; then
            log "VM $vm is Running"
            return 0
        fi
        sleep 5
        (( waited += 5 ))
    done
    fail "VM $vm did not reach Running within ${VM_READY_TIMEOUT}s"
}

wait_ssh() {
    local vm="${1:-$VM_NAME}"
    log "Waiting for SSH on $vm (timeout=${SSH_TIMEOUT}s) ..."
    local waited=0
    while (( waited < SSH_TIMEOUT )); do
        if vm_exec "echo ssh-ok" "$vm" 2>/dev/null | grep -q "ssh-ok"; then
            log "SSH ready on $vm"
            return 0
        fi
        sleep 5
        (( waited += 5 ))
    done
    fail "SSH not accessible on $vm within ${SSH_TIMEOUT}s"
}

wait_cloud_init() {
    local vm="${1:-$VM_NAME}"
    log "Waiting for cloud-init on $vm ..."
    local waited=0
    while (( waited < 300 )); do
        if vm_exec "test -f /tmp/cloud-init-done && echo done" "$vm" 2>/dev/null | grep -q "done"; then
            log "cloud-init complete on $vm"
            return 0
        fi
        sleep 5
        (( waited += 5 ))
    done
    log "WARNING: cloud-init marker not found on $vm, proceeding"
}

# vm_exec "<command>" [vm_name]
vm_exec() {
    local cmd="$1"
    local vm="${2:-$VM_NAME}"
    $VIRTCTL_BIN ssh "$SSH_USER@vmi/${vm}" -n "$NAMESPACE" \
        --identity-file="$SSH_KEY_DIR/id_ed25519" \
        --command="$cmd" \
        --known-hosts=/dev/null \
        --local-ssh-opts="-o StrictHostKeyChecking=no" \
        --local-ssh-opts="-o ConnectTimeout=10" 2>/dev/null || true
}

destroy_vm() {
    local vm="${1:-$VM_NAME}"
    log "Destroying VM $vm"
    oc delete vm "$vm" -n "$NAMESPACE" --wait=true --timeout=120s 2>/dev/null || true
}

# ===========================================================================
# BENCHMARKS — user experience focused
# ===========================================================================

bench_system_info() {
    log "--- System Info ---"
    vm_exec "cat /etc/os-release | head -3; echo '---'; nproc; free -h | head -2; lsblk -d -o NAME,SIZE,ROTA,TYPE | head -5" \
        | tee "$RESULTS_DIR/sysinfo.txt"
}

# --- SSH responsiveness: what the user feels typing commands ---------------
bench_ssh_latency() {
    log "--- SSH: round-trip latency (10 commands) ---"
    local total=0
    for i in $(seq 1 10); do
        local s e
        s=$(date +%s%N)
        vm_exec "echo ok" >/dev/null
        e=$(date +%s%N)
        local ms=$(( (e - s) / 1000000 ))
        total=$(( total + ms ))
    done
    local avg=$(( total / 10 ))
    log "SSH avg round-trip: ${avg}ms"
    TIMINGS["ssh_roundtrip_avg_ms"]="$avg"
}

# --- Command responsiveness -----------------------------------------------
bench_cmd_responsiveness() {
    log "--- Command responsiveness ---"
    local s e

    s=$(date +%s%N)
    vm_exec "ls -laR /etc >/dev/null 2>&1"
    e=$(date +%s%N)
    TIMINGS["cmd_ls_etc_ms"]="$(( (e - s) / 1000000 ))"

    s=$(date +%s%N)
    vm_exec "find / -name '*.conf' 2>/dev/null | wc -l"
    e=$(date +%s%N)
    TIMINGS["cmd_find_conf_ms"]="$(( (e - s) / 1000000 ))"

    s=$(date +%s%N)
    vm_exec "ps auxww | wc -l"
    e=$(date +%s%N)
    TIMINGS["cmd_ps_ms"]="$(( (e - s) / 1000000 ))"

    log "  ls -laR /etc: ${TIMINGS[cmd_ls_etc_ms]}ms"
    log "  find *.conf:  ${TIMINGS[cmd_find_conf_ms]}ms"
    log "  ps auxww:     ${TIMINGS[cmd_ps_ms]}ms"
}

# --- Package install (real-world: setting up your environment) -------------
bench_dnf_install() {
    log "--- DNF: install httpd ---"
    local out
    out=$(vm_exec "sudo dnf install -y httpd 2>&1 | tail -3")
    echo "$out" | tee "$RESULTS_DIR/dnf_install.txt"
}

# --- Git clone (network + disk stand-in; not installing the repo) ---------
bench_git_clone() {
    if [[ -z "${GUEST_UX_GIT_URL}" ]]; then
        log "--- Git: skipped (GUEST_UX_GIT_URL empty) ---"
        GIT_STATUS=skipped
        TIMINGS["bench_git_clone"]=0
        return 0
    fi
    log "--- Git: clone ${GUEST_UX_GIT_URL} ---"
    local out
    out=$(vm_exec "rm -rf /tmp/guest-ux-git && git clone --depth 1 '${GUEST_UX_GIT_URL}' /tmp/guest-ux-git 2>&1 | tail -5")
    echo "$out" | tee "$RESULTS_DIR/git_clone.txt"
    if echo "$out" | grep -qiE 'fatal|error|failed|could not|denied'; then
        GIT_STATUS=failed
        log "  git clone FAILED (soft — continues; scores if configured)"
    elif [[ -z "$out" ]]; then
        # vm_exec can swallow output; probe the dir
        if vm_exec "test -d /tmp/guest-ux-git/.git && echo ok" 2>/dev/null | grep -q ok; then
            GIT_STATUS=ok
        else
            GIT_STATUS=failed
            log "  git clone FAILED (soft)"
        fi
    else
        GIT_STATUS=ok
    fi
}

# --- File operations (filesystem metadata perf) ---------------------------
bench_file_ops() {
    log "--- File ops: create 1000 files, tar, extract ---"
    local s e

    s=$(date +%s%N)
    vm_exec "mkdir -p /tmp/filetest && for i in \$(seq 1 1000); do echo 'test content \$i' > /tmp/filetest/file_\$i.txt; done"
    e=$(date +%s%N)
    TIMINGS["fileops_create_1000_ms"]="$(( (e - s) / 1000000 ))"

    s=$(date +%s%N)
    vm_exec "tar czf /tmp/filetest.tar.gz -C /tmp filetest"
    e=$(date +%s%N)
    TIMINGS["fileops_tar_create_ms"]="$(( (e - s) / 1000000 ))"

    s=$(date +%s%N)
    vm_exec "tar xzf /tmp/filetest.tar.gz -C /tmp/filetest-extracted 2>/dev/null; mkdir -p /tmp/filetest-extracted && tar xzf /tmp/filetest.tar.gz -C /tmp/filetest-extracted"
    e=$(date +%s%N)
    TIMINGS["fileops_tar_extract_ms"]="$(( (e - s) / 1000000 ))"

    log "  Create 1000 files: ${TIMINGS[fileops_create_1000_ms]}ms"
    log "  Tar create:        ${TIMINGS[fileops_tar_create_ms]}ms"
    log "  Tar extract:       ${TIMINGS[fileops_tar_extract_ms]}ms"
}

# --- Compile a C program (CPU + disk) -------------------------------------
bench_compile() {
    log "--- Compile: build a C program ---"
    vm_exec "cat > /tmp/bench.c << 'CEOF'
#include <stdio.h>
#include <math.h>
int main() {
    double sum = 0;
    for (long i = 0; i < 10000000; i++) {
        sum += sin(i) * cos(i);
    }
    printf(\"Result: %f\\n\", sum);
    return 0;
}
CEOF"

    local s e
    s=$(date +%s%N)
    vm_exec "gcc -O2 -o /tmp/bench /tmp/bench.c -lm 2>&1"
    e=$(date +%s%N)
    TIMINGS["compile_gcc_ms"]="$(( (e - s) / 1000000 ))"

    s=$(date +%s%N)
    vm_exec "/tmp/bench"
    e=$(date +%s%N)
    TIMINGS["compile_run_ms"]="$(( (e - s) / 1000000 ))"

    log "  gcc compile: ${TIMINGS[compile_gcc_ms]}ms"
    log "  Run binary:  ${TIMINGS[compile_run_ms]}ms"
}

# --- Disk I/O (actual Ceph perf, iodepth=4, no rate limit) ----------------
bench_fio_randread() {
    log "--- Disk: fio random read (4k, iodepth=4, ${FIO_RUNTIME}s) ---"
    local out
    out=$(vm_exec "fio --name=randread --ioengine=libaio --direct=1 --bs=4k --iodepth=4 \
        --size=512M --rw=randread --runtime=${FIO_RUNTIME} --time_based \
        --group_reporting --filename=/tmp/fio-test 2>/dev/null" || echo "fio not available")
    echo "$out" > "$RESULTS_DIR/fio_randread.txt"
    TIMINGS["fio_randread_iops"]=$(echo "$out" | grep -oP 'IOPS=[\d.kKmM]+' | head -1 || echo "N/A")
    TIMINGS["fio_randread_lat"]=$(echo "$out" | grep -A2 'clat' | grep -oP 'avg=[\d.]+' | head -1 || echo "N/A")
    log "  ${TIMINGS[fio_randread_iops]} / ${TIMINGS[fio_randread_lat]}"
}

bench_fio_randwrite() {
    log "--- Disk: fio random write (4k, iodepth=4, ${FIO_RUNTIME}s) ---"
    local out
    out=$(vm_exec "fio --name=randwrite --ioengine=libaio --direct=1 --bs=4k --iodepth=4 \
        --size=512M --rw=randwrite --runtime=${FIO_RUNTIME} --time_based \
        --group_reporting --filename=/tmp/fio-test 2>/dev/null" || echo "fio not available")
    echo "$out" > "$RESULTS_DIR/fio_randwrite.txt"
    TIMINGS["fio_randwrite_iops"]=$(echo "$out" | grep -oP 'IOPS=[\d.kKmM]+' | head -1 || echo "N/A")
    TIMINGS["fio_randwrite_lat"]=$(echo "$out" | grep -A2 'clat' | grep -oP 'avg=[\d.]+' | head -1 || echo "N/A")
    log "  ${TIMINGS[fio_randwrite_iops]} / ${TIMINGS[fio_randwrite_lat]}"
}

bench_fio_seqwrite() {
    log "--- Disk: fio sequential write (1M, iodepth=4, ${FIO_RUNTIME}s) ---"
    local out
    out=$(vm_exec "fio --name=seqwrite --ioengine=libaio --direct=1 --bs=1M --iodepth=4 \
        --size=512M --rw=write --runtime=${FIO_RUNTIME} --time_based \
        --group_reporting --filename=/tmp/fio-seq-test 2>/dev/null" || echo "fio not available")
    echo "$out" > "$RESULTS_DIR/fio_seqwrite.txt"
    TIMINGS["fio_seqwrite_bw"]=$(echo "$out" | grep -oP 'BW=[\d.]+[GMKT]iB/s' | head -1 || echo "N/A")
    log "  ${TIMINGS[fio_seqwrite_bw]}"
}

bench_fio_seqread() {
    log "--- Disk: fio sequential read (1M, iodepth=4, ${FIO_RUNTIME}s) ---"
    vm_exec "echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true"
    local out
    out=$(vm_exec "fio --name=seqread --ioengine=libaio --direct=1 --bs=1M --iodepth=4 \
        --size=512M --rw=read --runtime=${FIO_RUNTIME} --time_based \
        --group_reporting --filename=/tmp/fio-seq-test 2>/dev/null" || echo "fio not available")
    echo "$out" > "$RESULTS_DIR/fio_seqread.txt"
    TIMINGS["fio_seqread_bw"]=$(echo "$out" | grep -oP 'BW=[\d.]+[GMKT]iB/s' | head -1 || echo "N/A")
    log "  ${TIMINGS[fio_seqread_bw]}"
}

# --- CPU (stress-ng with yaml output for reliable parsing) -----------------
bench_cpu() {
    log "--- CPU: stress-ng matrix (${VM_CORES} workers, 30s) ---"
    local out
    out=$(vm_exec "stress-ng --matrix ${VM_CORES} --timeout 30s --metrics 2>&1")
    echo "$out" > "$RESULTS_DIR/cpu.txt"
    # Match only the data row: "matrix" followed by digits (not "dispatching hogs" or "passed" lines)
    TIMINGS["cpu_matrix_bogo_ops"]=$(echo "$out" | grep -E 'matrix\s+[0-9]' | awk '{print $(NF-1)}' || echo "N/A")
    log "  matrix bogo ops/s: ${TIMINGS[cpu_matrix_bogo_ops]}"
}

# --- Memory ----------------------------------------------------------------
bench_memory() {
    log "--- Memory: stress-ng memcpy (30s) ---"
    local out
    out=$(vm_exec "stress-ng --memcpy 1 --timeout 30s --metrics 2>&1")
    echo "$out" > "$RESULTS_DIR/memory.txt"
    TIMINGS["mem_memcpy_bogo_ops"]=$(echo "$out" | grep -E 'memcpy\s+[0-9]' | awk '{print $(NF-1)}' || echo "N/A")
    log "  memcpy bogo ops/s: ${TIMINGS[mem_memcpy_bogo_ops]}"
}

# --- Network (external — soft; empty URL/target = skip) --------------------
bench_network_latency() {
    if [[ -z "${GUEST_UX_PING_TARGET}" ]]; then
        log "--- Network: ping skipped (GUEST_UX_PING_TARGET empty) ---"
        PING_STATUS=skipped
        TIMINGS["net_ping_avg"]="skipped"
        return 0
    fi
    log "--- Network: ping ${GUEST_UX_PING_TARGET} (10 pings) ---"
    local out
    out=$(vm_exec "ping -c 10 -q '${GUEST_UX_PING_TARGET}' 2>&1")
    echo "$out" > "$RESULTS_DIR/net_latency.txt"
    TIMINGS["net_ping_avg"]=$(echo "$out" | grep -oP '[\d.]+/[\d.]+/[\d.]+/[\d.]+' | head -1 | cut -d/ -f2 || echo "")
    if [[ -z "${TIMINGS[net_ping_avg]}" ]] || echo "$out" | grep -qiE '100% packet loss|Network unreachable|unknown host'; then
        PING_STATUS=failed
        TIMINGS["net_ping_avg"]="failed"
        log "  ping FAILED (soft)"
    else
        PING_STATUS=ok
        log "  avg RTT: ${TIMINGS[net_ping_avg]}ms"
    fi
}

bench_network_dns() {
    if [[ -z "${GUEST_UX_DNS_NAME}" ]]; then
        log "--- Network: DNS skipped (GUEST_UX_DNS_NAME empty) ---"
        DNS_STATUS=skipped
        TIMINGS["net_dns_ms"]=0
        return 0
    fi
    log "--- Network: DNS resolution (${GUEST_UX_DNS_NAME}) ---"
    local out s e
    s=$(date +%s%N)
    out=$(vm_exec "timeout 10 nslookup '${GUEST_UX_DNS_NAME}' >/tmp/guest-ux-dns.out 2>&1; if grep -qE 'Address:|Name:' /tmp/guest-ux-dns.out; then echo DNSOK; else echo DNSFAIL; tail -5 /tmp/guest-ux-dns.out; fi")
    e=$(date +%s%N)
    echo "$out" > "$RESULTS_DIR/net_dns.txt"
    TIMINGS["net_dns_ms"]="$(( (e - s) / 1000000 ))"
    if echo "$out" | grep -q DNSOK; then
        DNS_STATUS=ok
        log "  DNS resolve: ${TIMINGS[net_dns_ms]}ms"
    else
        DNS_STATUS=failed
        log "  DNS FAILED (soft)"
    fi
}

bench_network_throughput() {
    if [[ -z "${GUEST_UX_DOWNLOAD_URL}" ]]; then
        log "--- Network: download skipped (GUEST_UX_DOWNLOAD_URL empty) ---"
        DOWNLOAD_STATUS=skipped
        TIMINGS["net_download_mbps"]="skipped"
        TIMINGS["net_ttfb_ms"]="skipped"
        return 0
    fi
    log "--- Network: download ${GUEST_UX_DOWNLOAD_URL} ---"
    local out speed_bps
    out=$(vm_exec "curl -so /dev/null -w '%{speed_download} %{time_total} %{time_starttransfer} %{http_code}' \
        '${GUEST_UX_DOWNLOAD_URL}' 2>/dev/null" || echo "0 0 0 000")
    speed_bps=$(echo "$out" | awk '{print $1}')
    TIMINGS["net_download_mbps"]=$(awk "BEGIN{printf \"%.2f\", ${speed_bps:-0}/1048576}" 2>/dev/null || echo "0.00")
    TIMINGS["net_ttfb_ms"]=$(echo "$out" | awk '{printf "%.0f", $3*1000}' 2>/dev/null || echo "0")
    TIMINGS["net_total_s"]=$(echo "$out" | awk '{printf "%.2f", $2}' 2>/dev/null || echo "0")
    local http_code
    http_code=$(echo "$out" | awk '{print $4}')
    if [[ "${TIMINGS[net_download_mbps]}" == "0.00" || "${TIMINGS[net_download_mbps]}" == "0" ]] \
        || [[ "$http_code" != "200" && "$http_code" != "000" && -n "$http_code" ]]; then
        # 000 often means curl failed entirely; treat zero speed as fail
        if [[ "${TIMINGS[net_download_mbps]}" == "0.00" || "${TIMINGS[net_download_mbps]}" == "0" ]]; then
            DOWNLOAD_STATUS=failed
            log "  Download FAILED (soft)"
        else
            DOWNLOAD_STATUS=ok
            log "  Download: ${TIMINGS[net_download_mbps]} MB/s, TTFB: ${TIMINGS[net_ttfb_ms]}ms"
        fi
    else
        DOWNLOAD_STATUS=ok
        log "  Download: ${TIMINGS[net_download_mbps]} MB/s, TTFB: ${TIMINGS[net_ttfb_ms]}ms"
    fi
}

# ===========================================================================
# Results
# ===========================================================================
print_results() {
    local total_end
    total_end=$(date +%s%N)
    local total_ms=$(( (total_end - TOTAL_START) / 1000000 ))

    cat <<RESULTS

================================================================================
  GUEST UX BENCH RESULTS
  Cluster:   ${CLUSTER_NAME}
  Node:      ${TARGET_NODE:-scheduler-assigned}
  Image:     ${IMAGE}
  VM Spec:   ${VM_CORES} cores, ${VM_MEMORY} RAM, ${DISK_SIZE} disk
  Storage:   ${STORAGE_CLASS}
  Date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
  Run ID:    ${RUN_ID}
================================================================================

  VM LIFECYCLE
  ─────────────────────────────────────────────────
  Namespace create .......... $(secs "${TIMINGS[create_namespace]:-0}")s
  VM deploy (apply) ......... $(secs "${TIMINGS[deploy_vm]:-0}")s
  VM boot → Running ......... $(secs "${TIMINGS[wait_vm_running]:-0}")s
  VM Running → SSH ready .... $(secs "${TIMINGS[wait_ssh]:-0}")s
  Cloud-init packages ....... $(secs "${TIMINGS[wait_cloud_init]:-0}")s
  VM destroy ................ $(secs "${TIMINGS[destroy_vm]:-0}")s
  Total test time ........... $(secs "$total_ms")s

  USER EXPERIENCE — RESPONSIVENESS
  ─────────────────────────────────────────────────
  SSH round-trip (avg) ...... ${TIMINGS[ssh_roundtrip_avg_ms]:-N/A}ms
  ls -laR /etc .............. ${TIMINGS[cmd_ls_etc_ms]:-N/A}ms
  find *.conf ............... ${TIMINGS[cmd_find_conf_ms]:-N/A}ms
  ps auxww .................. ${TIMINGS[cmd_ps_ms]:-N/A}ms

  USER EXPERIENCE — REAL TASKS
  ─────────────────────────────────────────────────
  dnf install httpd ......... $(secs "${TIMINGS[bench_dnf_install]:-0}")s
  git clone (small repo) .... $(secs "${TIMINGS[bench_git_clone]:-0}")s
  gcc compile ............... ${TIMINGS[compile_gcc_ms]:-N/A}ms
  Run compiled binary ....... ${TIMINGS[compile_run_ms]:-N/A}ms
  Create 1000 files ......... ${TIMINGS[fileops_create_1000_ms]:-N/A}ms
  Tar create ................ ${TIMINGS[fileops_tar_create_ms]:-N/A}ms
  Tar extract ............... ${TIMINGS[fileops_tar_extract_ms]:-N/A}ms

  DISK I/O (direct, iodepth=4, no rate limit)
  ─────────────────────────────────────────────────
  Seq write (1M) ............ ${TIMINGS[fio_seqwrite_bw]:-N/A}
  Seq read (1M) ............. ${TIMINGS[fio_seqread_bw]:-N/A}
  Rand read (4k) ............ ${TIMINGS[fio_randread_iops]:-N/A}  lat ${TIMINGS[fio_randread_lat]:-N/A}
  Rand write (4k) ........... ${TIMINGS[fio_randwrite_iops]:-N/A}  lat ${TIMINGS[fio_randwrite_lat]:-N/A}

  CPU / MEMORY
  ─────────────────────────────────────────────────
  stress-ng matrix (bogo/s) . ${TIMINGS[cpu_matrix_bogo_ops]:-N/A}
  stress-ng memcpy (bogo/s) . ${TIMINGS[mem_memcpy_bogo_ops]:-N/A}

  NETWORK (external — soft)
  ─────────────────────────────────────────────────
  Git clone .................. ${GIT_STATUS}
  Ping (${GUEST_UX_PING_TARGET:-none}) .......... ${TIMINGS[net_ping_avg]:-N/A} [${PING_STATUS}]
  DNS (${GUEST_UX_DNS_NAME:-none}) .............. ${TIMINGS[net_dns_ms]:-N/A}ms [${DNS_STATUS}]
  Download ................... ${TIMINGS[net_download_mbps]:-N/A} MB/s [${DOWNLOAD_STATUS}]
  Time to first byte ........ ${TIMINGS[net_ttfb_ms]:-N/A}ms

  ANALYSIS
  ─────────────────────────────────────────────────
$(
    ssh_rtt=${TIMINGS[ssh_roundtrip_avg_ms]:-0}
    boot_total=$(( ${TIMINGS[wait_vm_running]:-0} + ${TIMINGS[wait_ssh]:-0} ))

    # Boot experience
    if (( boot_total < 30000 )); then
        echo "  VM provisioning: FAST — usable shell in under 30s."
    elif (( boot_total < 60000 )); then
        echo "  VM provisioning: OK — usable shell in under a minute."
    else
        echo "  VM provisioning: SLOW — over a minute to get a shell."
    fi

    # Interactive feel
    if (( ssh_rtt < 200 )); then
        echo "  Interactive feel: EXCELLENT — commands feel instant (${ssh_rtt}ms RTT)."
    elif (( ssh_rtt < 300 )); then
        echo "  Interactive feel: GOOD — responsive, minor lag (${ssh_rtt}ms RTT)."
    elif (( ssh_rtt < 400 )); then
        echo "  Interactive feel: FAIR — noticeable delay on each command (${ssh_rtt}ms RTT)."
    else
        echo "  Interactive feel: SLUGGISH — users will notice lag (${ssh_rtt}ms RTT)."
    fi

    # Network (soft / skip-aware)
    dl=${TIMINGS[net_download_mbps]:-0}
    if [[ "$DOWNLOAD_STATUS" == "skipped" ]]; then
        echo "  Network download: skipped (GUEST_UX_DOWNLOAD_URL empty)."
    elif [[ "$DOWNLOAD_STATUS" == "failed" || "$dl" == "0.00" || "$dl" == "0" ]]; then
        echo "  Network: WARNING — configured download failed (counts toward score)."
    elif (( $(awk "BEGIN{print ($dl < 3)}" 2>/dev/null) )); then
        echo "  Network: SLOW downloads (${dl} MB/s) — package installs will drag."
    elif (( $(awk "BEGIN{print ($dl < 8)}" 2>/dev/null) )); then
        echo "  Network: OK download speed (${dl} MB/s)."
    else
        echo "  Network: GOOD download speed (${dl} MB/s)."
    fi
    [[ "$GIT_STATUS" == "failed" ]] && echo "  Git clone: FAILED (counts toward score)."
    [[ "$PING_STATUS" == "failed" ]] && echo "  Ping: FAILED (counts toward score)."
    [[ "$DNS_STATUS" == "failed" ]] && echo "  DNS: FAILED (counts toward score)."

    # DNF as proxy for overall experience
    dnf_ms=${TIMINGS[bench_dnf_install]:-0}
    if (( dnf_ms > 0 && dnf_ms < 4000 )); then
        echo "  Setting up environment: FAST — dnf install in under 4s."
    elif (( dnf_ms > 0 && dnf_ms < 6000 )); then
        echo "  Setting up environment: OK — dnf install in $(secs "$dnf_ms")s."
    elif (( dnf_ms > 0 )); then
        echo "  Setting up environment: SLOW — dnf install took $(secs "$dnf_ms")s."
    fi
)

================================================================================
RESULTS

    local out_json="${1:-$RESULTS_DIR/results.json}"
    local workers_json="${WORKERS_JSON_EXTRA:-}"

    cat > "$out_json" <<JSONEOF
{
  "cluster": "${CLUSTER_NAME}",
  "node": "${TARGET_NODE:-scheduler-assigned}",
  "node_mode": "${NODE_MODE}",
  "image": "${IMAGE}",
  "vm_cores": ${VM_CORES},
  "vm_memory": "${VM_MEMORY}",
  "disk_size": "${DISK_SIZE}",
  "storage_class": "${STORAGE_CLASS}",
  "profile": "${GUEST_UX_VM_PROFILE}",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_id": "${RUN_ID}",
  "lifecycle_ms": {
    "namespace_create": ${TIMINGS[create_namespace]:-0},
    "vm_deploy": ${TIMINGS[deploy_vm]:-0},
    "vm_boot": ${TIMINGS[wait_vm_running]:-0},
    "ssh_ready": ${TIMINGS[wait_ssh]:-0},
    "cloud_init": ${TIMINGS[wait_cloud_init]:-0},
    "vm_destroy": ${TIMINGS[destroy_vm]:-0},
    "total": ${total_ms}
  },
  "responsiveness_ms": {
    "ssh_roundtrip_avg": ${TIMINGS[ssh_roundtrip_avg_ms]:-0},
    "cmd_ls_etc": ${TIMINGS[cmd_ls_etc_ms]:-0},
    "cmd_find_conf": ${TIMINGS[cmd_find_conf_ms]:-0},
    "cmd_ps": ${TIMINGS[cmd_ps_ms]:-0}
  },
  "real_tasks_ms": {
    "dnf_install": ${TIMINGS[bench_dnf_install]:-0},
    "git_clone": ${TIMINGS[bench_git_clone]:-0},
    "gcc_compile": ${TIMINGS[compile_gcc_ms]:-0},
    "run_binary": ${TIMINGS[compile_run_ms]:-0},
    "create_1000_files": ${TIMINGS[fileops_create_1000_ms]:-0},
    "tar_create": ${TIMINGS[fileops_tar_create_ms]:-0},
    "tar_extract": ${TIMINGS[fileops_tar_extract_ms]:-0}
  },
  "disk_io": {
    "fio_seqwrite_bw": "${TIMINGS[fio_seqwrite_bw]:-N/A}",
    "fio_seqread_bw": "${TIMINGS[fio_seqread_bw]:-N/A}",
    "fio_randread_iops": "${TIMINGS[fio_randread_iops]:-N/A}",
    "fio_randread_lat": "${TIMINGS[fio_randread_lat]:-N/A}",
    "fio_randwrite_iops": "${TIMINGS[fio_randwrite_iops]:-N/A}",
    "fio_randwrite_lat": "${TIMINGS[fio_randwrite_lat]:-N/A}"
  },
  "cpu": {
    "matrix_bogo_ops": "${TIMINGS[cpu_matrix_bogo_ops]:-N/A}"
  },
  "memory": {
    "memcpy_bogo_ops": "${TIMINGS[mem_memcpy_bogo_ops]:-N/A}"
  },
  "network": {
    "ping_avg_ms": "${TIMINGS[net_ping_avg]:-N/A}",
    "dns_ms": ${TIMINGS[net_dns_ms]:-0},
    "download_mbps": "${TIMINGS[net_download_mbps]:-N/A}",
    "ttfb_ms": "${TIMINGS[net_ttfb_ms]:-N/A}",
    "git_status": "${GIT_STATUS}",
    "ping_status": "${PING_STATUS}",
    "dns_status": "${DNS_STATUS}",
    "download_status": "${DOWNLOAD_STATUS}"
  }${workers_json}
}
JSONEOF

    log "Results saved to: $out_json"
}

emit_json_block() {
    local f="${1:-$RESULTS_DIR/results.json}"
    echo "===JSON_START==="
    cat "$f"
    echo "===JSON_END==="
}

# Guest-side benches only (VM already Running / SSH / cloud-init).
run_guest_benches() {
    reset_probe_state

    bench_system_info

    timer bench_ssh_latency        bench_ssh_latency
    timer bench_cmd_responsiveness bench_cmd_responsiveness
    timer bench_dnf_install        bench_dnf_install
    timer bench_git_clone          bench_git_clone
    timer bench_compile            bench_compile
    timer bench_file_ops           bench_file_ops
    timer bench_fio_seqwrite       bench_fio_seqwrite
    timer bench_fio_seqread        bench_fio_seqread
    timer bench_fio_randread       bench_fio_randread
    timer bench_fio_randwrite      bench_fio_randwrite
    timer bench_cpu                bench_cpu
    timer bench_memory             bench_memory
    timer bench_network_latency    bench_network_latency
    timer bench_network_dns        bench_network_dns
    timer bench_network_throughput bench_network_throughput
}

# Single-node (or busiest/any/pinned): one NS, one VM, full lifecycle.
run_one_probe() {
    timer create_namespace  create_namespace
    timer deploy_vm         deploy_vm
    timer wait_vm_running   wait_vm_running
    timer wait_ssh          wait_ssh
    timer wait_cloud_init   wait_cloud_init

    run_guest_benches

    timer destroy_vm destroy_vm
}

# All-workers: one NS, one VM per eligible worker, stagger deploys, then bench each.
# $1 = wall-clock start (ns) for final aggregate total
run_all_workers() {
    local main_start="${1}"
    local node safe_node vm node_dir probe_start first=1 w
    local worst_ssh=0 worst_dnf=0 worst_files=0 worst_boot=0
    local worst_dl="skipped" agg_git=skipped agg_ping=skipped agg_dns=skipped agg_dl=skipped
    local workers_tested=()
    local -a vm_names=()
    local -a vm_nodes=()
    local i=0

    log "All-workers: 1 namespace, ${#ELIGIBLE_WORKERS[@]} VMs, stagger ${VM_STAGGER_SEC}s"

    timer create_namespace create_namespace

    for node in "${ELIGIBLE_WORKERS[@]}"; do
        safe_node=$(echo "$node" | tr ':/.' '---' | tr '[:upper:]' '[:lower:]')
        vm="perf-${safe_node}"
        vm="${vm:0:63}"
        TARGET_NODE="$node"
        VM_NAME="$vm"

        if (( i > 0 )); then
            log "Stagger ${VM_STAGGER_SEC}s before next VM ..."
            sleep "$VM_STAGGER_SEC"
        fi
        deploy_vm "$vm" "$node"
        vm_names+=("$vm")
        vm_nodes+=("$node")
        (( i++ )) || true
    done

    # Wait until every VM is usable (boot overlaps after stagger)
    i=0
    for vm in "${vm_names[@]}"; do
        TARGET_NODE="${vm_nodes[$i]}"
        VM_NAME="$vm"
        wait_vm_running "$vm"
        wait_ssh "$vm"
        wait_cloud_init "$vm"
        (( i++ )) || true
    done

    i=0
    for vm in "${vm_names[@]}"; do
        node="${vm_nodes[$i]}"
        safe_node=$(echo "$node" | tr ':/.' '---' | tr '[:upper:]' '[:lower:]')
        VM_NAME="$vm"
        TARGET_NODE="$node"
        node_dir="$RESULTS_DIR/nodes/${safe_node}"
        mkdir -p "$node_dir"

        log "======== Bench on $node ($vm) ========"
        probe_start=$(date +%s%N)
        TOTAL_START=$probe_start
        run_guest_benches
        print_results "$node_dir/results.json"
        workers_tested+=("$node")

        worst_ssh=$(num_max "$worst_ssh" "${TIMINGS[ssh_roundtrip_avg_ms]:-0}")
        worst_dnf=$(num_max "$worst_dnf" "${TIMINGS[bench_dnf_install]:-0}")
        worst_files=$(num_max "$worst_files" "${TIMINGS[fileops_create_1000_ms]:-0}")
        worst_boot=$(num_max "$worst_boot" "$(( ${TIMINGS[wait_vm_running]:-0} + ${TIMINGS[wait_ssh]:-0} ))")
        agg_git=$(worse_status "$agg_git" "$GIT_STATUS")
        agg_ping=$(worse_status "$agg_ping" "$PING_STATUS")
        agg_dns=$(worse_status "$agg_dns" "$DNS_STATUS")
        agg_dl=$(worse_status "$agg_dl" "$DOWNLOAD_STATUS")
        if [[ "$DOWNLOAD_STATUS" == "ok" ]]; then
            if [[ "$worst_dl" == "skipped" || "$worst_dl" == "failed" ]]; then
                worst_dl="${TIMINGS[net_download_mbps]:-0}"
            else
                worst_dl=$(awk -v a="$worst_dl" -v b="${TIMINGS[net_download_mbps]:-0}" 'BEGIN{printf (a<b)?a:b}')
            fi
        elif [[ "$DOWNLOAD_STATUS" == "failed" ]]; then
            worst_dl=0
        fi
        (( i++ )) || true
    done

    log "Deleting shared namespace $NAMESPACE (all worker VMs) ..."
    oc delete namespace "$NAMESPACE" --wait=false --ignore-not-found=true 2>/dev/null || true

    reset_probe_state
    TIMINGS[ssh_roundtrip_avg_ms]="$worst_ssh"
    TIMINGS[bench_dnf_install]="$worst_dnf"
    TIMINGS[fileops_create_1000_ms]="$worst_files"
    TIMINGS[wait_vm_running]=$(( worst_boot / 2 ))
    TIMINGS[wait_ssh]=$(( worst_boot - worst_boot / 2 ))
    TIMINGS[net_download_mbps]="$worst_dl"
    TIMINGS[net_dns_ms]=0
    GIT_STATUS=$agg_git
    PING_STATUS=$agg_ping
    DNS_STATUS=$agg_dns
    DOWNLOAD_STATUS=$agg_dl
    TARGET_NODE="all-workers(${#workers_tested[@]} tested)"
    VM_NAME="perf-vm"
    TOTAL_START=$main_start

    local skipped_json="[" tested_json="["
    first=1
    for w in "${SKIPPED_WORKERS[@]+"${SKIPPED_WORKERS[@]}"}"; do
        [[ -z "$w" ]] && continue
        local sn="${w%%|*}" sr="${w#*|}"
        if [[ $first -eq 1 ]]; then first=0; else skipped_json+=","; fi
        skipped_json+=$(printf '{"node":"%s","reason":"%s"}' "$sn" "$sr")
    done
    skipped_json+="]"
    first=1
    for w in "${workers_tested[@]}"; do
        if [[ $first -eq 1 ]]; then first=0; else tested_json+=","; fi
        tested_json+=$(printf '"%s"' "$w")
    done
    tested_json+="]"

    WORKERS_JSON_EXTRA=$(printf ',\n  "workers_tested": %s,\n  "workers_skipped": %s,\n  "vm_stagger_sec": %s,\n  "per_node_results": "nodes/<worker>/results.json"' \
        "$tested_json" "$skipped_json" "$VM_STAGGER_SEC")
}

# max of numeric strings; ignores non-numeric
num_max() {
    local a="${1:-0}" b="${2:-0}"
    [[ "$a" =~ ^[0-9]+([.][0-9]+)?$ ]] || a=0
    [[ "$b" =~ ^[0-9]+([.][0-9]+)?$ ]] || b=0
    awk -v a="$a" -v b="$b" 'BEGIN{printf (a>b)?a:b}'
}

# Pick worse external status: failed > ok > skipped
worse_status() {
    local a="$1" b="$2"
    [[ "$a" == "failed" || "$b" == "failed" ]] && { echo failed; return; }
    [[ "$a" == "ok" || "$b" == "ok" ]] && { echo ok; return; }
    echo skipped
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    local main_start base_run_id
    main_start=$(date +%s%N)
    TOTAL_START=$main_start
    base_run_id="$RUN_ID"
    WORKERS_JSON_EXTRA=""

    log "=== Guest UX Bench Starting ==="
    log "Run ID: $RUN_ID"
    log "Profile: ${GUEST_UX_VM_PROFILE} (${VM_CORES} cores, ${VM_MEMORY}, ${DISK_SIZE})"
    log "Image: ${IMAGE}  StorageClass: ${STORAGE_CLASS}"
    log "Node mode: ${NODE_MODE}"
    [[ -f "$ENV_FILE" ]] && log "Env file: $ENV_FILE"

    if ! command -v oc &>/dev/null; then
        fail "oc is required on PATH"
    fi

    detect_cluster
    ensure_virtctl
    find_busiest_node

    if [[ "$NODE_MODE" == "all" ]]; then
        if [[ ${#ELIGIBLE_WORKERS[@]} -eq 0 ]]; then
            fail "No eligible workers under cpu<${MAX_CPU_PCT}% mem<${MAX_MEM_PCT}% (or no metrics)"
        fi
        RUN_ID="$base_run_id"
        NAMESPACE="guest-ux-${RUN_ID}"
        run_all_workers "$main_start"
    else
        run_one_probe
    fi

    TOTAL_START=$main_start
    print_results "$RESULTS_DIR/results.json"
    emit_json_block "$RESULTS_DIR/results.json"

    log "=== Guest UX Bench Complete ==="
}

main "$@"
