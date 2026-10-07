#!/bin/bash
#
# Dispatch — run bench.sh against many clusters.
#   Bastion mode (default): SCP/SSH to each bastion.
#   Local mode (--local): run on this machine with KUBECONFIG per cluster.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/bench.sh"
RESULTS_DIR="$SCRIPT_DIR/results/$(date -u +%Y%m%d-%H%M%SZ)"
PARALLEL="${GUEST_UX_PARALLEL:-false}"
HOSTS_FILE="${GUEST_UX_HOSTS_FILE:-$SCRIPT_DIR/hosts}"
CLUSTERS_FILE="${GUEST_UX_CLUSTERS_FILE:-$SCRIPT_DIR/clusters}"
ENV_FILE="${GUEST_UX_ENV_FILE:-$SCRIPT_DIR/env.sh}"
MODE="bastion"
TARGETS=()      # SSH hosts or kubeconfig paths
TARGET_IDS=()   # short names → results/<stamp>/<id>/

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Apply env.sh without clobbering already-exported GUEST_UX_* (CLI wins later via EXTRA_ENV).
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
        key="${line%%=*}"; val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"; key="${key#"${key%%[![:space:]]*}"}"
        [[ "$key" == GUEST_UX_* ]] || continue
        if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
        if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        set_if_unset "$key" "$val"
    done < "$file"
}

# Appends cleaned lines from FILE into the global TARGETS array.
load_targets_file() {
    local file="$1"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | xargs 2>/dev/null || true)"
        [[ -z "$line" ]] && continue
        if [[ "$line" == ~* ]]; then
            line="${line/#\~/$HOME}"
        fi
        TARGETS+=("$line")
    done < "$file"
}

short_from_host() { echo "${1%%.*}"; }

short_from_kubeconfig() {
    local base
    base=$(basename "$1")
    echo "$base"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Modes:
  (default)           Bastion mode — SSH targets from ./hosts or --bastions
  --local             Localhost mode — kubeconfigs from ./clusters or --kubeconfigs
                      Requires oc on PATH; virtctl soft (bench may download)

Options:
  --bastions HOST1,HOST2,...     Bastion SSH targets
  --hosts FILE                   Bastion list file (default: ./hosts)
  --local                        Run benches on this machine (no SCP/SSH)
  --kubeconfigs PATH1,PATH2,...  Kubeconfig paths (implies --local)
  --clusters FILE                Kubeconfig list file (default: ./clusters)
  --parallel                     Run all targets simultaneously
  --image IMAGE                  Guest DataSource name (default: fedora)
  --cores N                      vCPU count (default: 2)
  --memory SIZE                  Memory (default: 4Gi)
  --disk SIZE                    Disk size (default: 30Gi)
  --profile NAME                 VM profile: default | small
  --env FILE                     Env file (default: ./env.sh)
  --help                         Show this help

Environment variables:
  GUEST_UX_IMAGE           VM image (same as --image)
  GUEST_UX_VM_CORES           vCPU count (same as --cores)
  GUEST_UX_VM_MEMORY          Memory (same as --memory)
  GUEST_UX_VM_DISK            Disk size (same as --disk)
  GUEST_UX_SC              StorageClass override
  GUEST_UX_VM_PROFILE         default | small
  GUEST_UX_PARALLEL        Set to "true" for parallel execution
  GUEST_UX_HOSTS_FILE      Path to bastion hosts file
  GUEST_UX_CLUSTERS_FILE   Path to kubeconfigs file (local mode)
  GUEST_UX_ENV_FILE        Path to env.sh
See env.example for external URL vars (soft; empty = skip).
EOF
    exit 0
}

# Parse args
CUSTOM_BASTIONS=""
CUSTOM_KUBECONFIGS=""
EXTRA_ENV=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bastions)     CUSTOM_BASTIONS="$2"; shift 2 ;;
        --hosts)        HOSTS_FILE="$2"; shift 2 ;;
        --local)        MODE=local; shift ;;
        --kubeconfigs)  CUSTOM_KUBECONFIGS="$2"; MODE=local; shift 2 ;;
        --clusters)     CLUSTERS_FILE="$2"; MODE=local; shift 2 ;;
        --parallel)     PARALLEL=true; shift ;;
        --image)        EXTRA_ENV+=("GUEST_UX_IMAGE=$2"); shift 2 ;;
        --cores)        EXTRA_ENV+=("GUEST_UX_VM_CORES=$2"); shift 2 ;;
        --memory)       EXTRA_ENV+=("GUEST_UX_VM_MEMORY=$2"); shift 2 ;;
        --disk)         EXTRA_ENV+=("GUEST_UX_VM_DISK=$2"); shift 2 ;;
        --profile)      EXTRA_ENV+=("GUEST_UX_VM_PROFILE=$2"); shift 2 ;;
        --env)          ENV_FILE="$2"; shift 2 ;;
        --help)         usage ;;
        *)              log "Unknown option: $1"; usage ;;
    esac
done

load_env_file "$ENV_FILE"
[[ -f "$ENV_FILE" ]] && log "Loaded env: $ENV_FILE"

# Resolve targets
if [[ "$MODE" == "local" ]]; then
    if [[ -n "$CUSTOM_KUBECONFIGS" ]]; then
        IFS=',' read -ra TARGETS <<< "$CUSTOM_KUBECONFIGS"
        for i in "${!TARGETS[@]}"; do
            t="${TARGETS[$i]}"
            t="$(echo "$t" | xargs 2>/dev/null || true)"
            [[ "$t" == ~* ]] && t="${t/#\~/$HOME}"
            TARGETS[$i]="$t"
        done
    elif [[ -f "$CLUSTERS_FILE" ]]; then
        TARGETS=()
        load_targets_file "$CLUSTERS_FILE"
    else
        log "ERROR: no kubeconfigs configured for --local."
        log "Copy clusters.example to clusters and edit, or pass --kubeconfigs / --clusters."
        exit 1
    fi
    for t in "${TARGETS[@]}"; do
        TARGET_IDS+=("$(short_from_kubeconfig "$t")")
    done
    if ! command -v oc &>/dev/null; then
        log "ERROR: oc is required on PATH for --local mode"
        exit 1
    fi
else
    if [[ -n "$CUSTOM_BASTIONS" ]]; then
        IFS=',' read -ra TARGETS <<< "$CUSTOM_BASTIONS"
    elif [[ -f "$HOSTS_FILE" ]]; then
        TARGETS=()
        load_targets_file "$HOSTS_FILE"
    else
        log "ERROR: no bastions configured."
        log "Copy hosts.example to hosts and edit it, or pass --bastions / --hosts."
        log "For localhost kubeconfigs, use: ./dispatch.sh --local ..."
        exit 1
    fi
    for t in "${TARGETS[@]}"; do
        TARGET_IDS+=("$(short_from_host "$t")")
    done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    log "ERROR: target list is empty"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

if [[ ! -f "$TEST_SCRIPT" ]]; then
    log "ERROR: $TEST_SCRIPT not found"
    exit 1
fi

log "Mode: $MODE — ${#TARGETS[@]} target(s)"

# ---------------------------------------------------------------------------
# Bastion: SCP + SSH
# ---------------------------------------------------------------------------
run_on_bastion() {
    local host="$1"
    local id="$2"
    local dest="$RESULTS_DIR/$id"
    local logf="$dest/run.log"
    mkdir -p "$dest"

    log "[$id] Starting (bastion $host) ..."

    if ! scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -q \
        "$TEST_SCRIPT" "${host}:/tmp/bench.sh" 2>/dev/null; then
        log "[$id] FAILED: could not SCP bench.sh"
        echo '{"error": "SCP failed"}' > "$dest/results.json"
        return 1
    fi

    local remote_env=""
    if [[ -f "$ENV_FILE" ]]; then
        if scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -q \
            "$ENV_FILE" "${host}:/tmp/guest-ux-env.sh" 2>/dev/null; then
            remote_env="GUEST_UX_ENV_FILE=/tmp/guest-ux-env.sh "
        fi
    fi

    local env_prefix="$remote_env"
    local e
    for e in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do
        env_prefix+="$e "
    done

    if ! ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o ServerAliveInterval=60 \
        "$host" "chmod +x /tmp/bench.sh && ${env_prefix}/tmp/bench.sh" \
        > "$logf" 2>&1; then
        log "[$id] FAILED: bench exited with error (see $logf)"
        echo '{"error": "test script failed"}' > "$dest/results.json"
        return 1
    fi

    sed -n '/===JSON_START===/,/===JSON_END===/{ /===JSON/d; p; }' "$logf" > "$dest/results.json" 2>/dev/null || true

    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$host" 'rm -rf /tmp/bench.sh /tmp/guest-ux-env.sh /tmp/guest-ux-results-*' 2>/dev/null || true

    log "[$id] Done. Results in $dest/"
}

# ---------------------------------------------------------------------------
# Local: KUBECONFIG + bench.sh on this machine
# ---------------------------------------------------------------------------
run_local() {
    local kubeconfig="$1"
    local id="$2"
    local dest="$RESULTS_DIR/$id"
    local logf="$dest/run.log"
    mkdir -p "$dest"

    log "[$id] Starting (local KUBECONFIG=$kubeconfig) ..."

    if [[ ! -f "$kubeconfig" ]]; then
        log "[$id] FAILED: kubeconfig not found: $kubeconfig"
        echo '{"error": "kubeconfig not found"}' > "$dest/results.json"
        return 1
    fi

    if ! (
        export KUBECONFIG="$kubeconfig"
        export GUEST_UX_ENV_FILE="$ENV_FILE"
        local e
        for e in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do
            export "${e?}"
        done
        bash "$TEST_SCRIPT"
    ) > "$logf" 2>&1; then
        log "[$id] FAILED: bench exited with error (see $logf)"
        # still try to salvage JSON if present
        sed -n '/===JSON_START===/,/===JSON_END===/{ /===JSON/d; p; }' "$logf" > "$dest/results.json" 2>/dev/null || true
        if [[ ! -s "$dest/results.json" ]]; then
            echo '{"error": "test script failed"}' > "$dest/results.json"
        fi
        return 1
    fi

    sed -n '/===JSON_START===/,/===JSON_END===/{ /===JSON/d; p; }' "$logf" > "$dest/results.json" 2>/dev/null || true

    log "[$id] Done. Results in $dest/"
}

run_one() {
    local target="$1"
    local id="$2"
    if [[ "$MODE" == "local" ]]; then
        run_local "$target" "$id"
    else
        run_on_bastion "$target" "$id"
    fi
}

# ---------------------------------------------------------------------------
# Run all targets
# ---------------------------------------------------------------------------
PIDS=()
FAILED=0
i=0
for target in "${TARGETS[@]}"; do
    id="${TARGET_IDS[$i]}"
    if [[ "$PARALLEL" == "true" ]]; then
        run_one "$target" "$id" &
        PIDS+=($!)
    else
        run_one "$target" "$id" || (( FAILED++ )) || true
    fi
    (( i++ )) || true
done

if [[ "$PARALLEL" == "true" ]]; then
    for pid in "${PIDS[@]}"; do
        wait "$pid" || (( FAILED++ )) || true
    done
fi

# ---------------------------------------------------------------------------
# Comparative summary
# ---------------------------------------------------------------------------
jval() { grep -o "\"$1\": *[\"]*[^,\"]*" "$2" | head -1 | sed 's/.*: *"*//;s/"$//' || echo "?"; }
ms2s() { awk "BEGIN{printf \"%.1fs\", ${1:-0}/1000}" 2>/dev/null || echo "?"; }

log "=== Comparative Summary ==="
echo ""

echo "  LIFECYCLE"
printf "  %-14s  %8s  %8s  %8s  %8s  %8s\n" \
    "CLUSTER" "BOOT" "SSH" "CLOUD" "DESTROY" "TOTAL"
printf '  %.0s─' {1..62}; echo
for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$id" "FAILED"; continue
    fi
    printf "  %-14s  %8s  %8s  %8s  %8s  %8s\n" "$id" \
        "$(ms2s "$(jval vm_boot "$json")")" \
        "$(ms2s "$(jval ssh_ready "$json")")" \
        "$(ms2s "$(jval cloud_init "$json")")" \
        "$(ms2s "$(jval vm_destroy "$json")")" \
        "$(ms2s "$(jval total "$json")")"
done

echo ""
echo "  USER EXPERIENCE — RESPONSIVENESS (ms)"
printf "  %-14s  %8s  %8s  %8s  %8s\n" \
    "CLUSTER" "SSH_RTT" "LS_ETC" "FIND" "PS"
printf '  %.0s─' {1..50}; echo
for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$id" "FAILED"; continue
    fi
    printf "  %-14s  %8s  %8s  %8s  %8s\n" "$id" \
        "$(jval ssh_roundtrip_avg "$json")" \
        "$(jval cmd_ls_etc "$json")" \
        "$(jval cmd_find_conf "$json")" \
        "$(jval cmd_ps "$json")"
done

echo ""
echo "  USER EXPERIENCE — REAL TASKS (ms)"
printf "  %-14s  %10s  %10s  %8s  %8s  %10s\n" \
    "CLUSTER" "DNF_INST" "GIT_CLONE" "GCC" "RUN" "1000_FILES"
printf '  %.0s─' {1..66}; echo
for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$id" "FAILED"; continue
    fi
    printf "  %-14s  %10s  %10s  %8s  %8s  %10s\n" "$id" \
        "$(ms2s "$(jval dnf_install "$json")")" \
        "$(ms2s "$(jval git_clone "$json")")" \
        "$(jval gcc_compile "$json")" \
        "$(jval run_binary "$json")" \
        "$(jval create_1000_files "$json")"
done

echo ""
echo "  DISK I/O (iodepth=4, no rate limit)"
printf "  %-14s  %15s  %15s  %15s  %15s\n" \
    "CLUSTER" "SEQ_WRITE" "SEQ_READ" "RAND_RD_IOPS" "RAND_WR_IOPS"
printf '  %.0s─' {1..78}; echo
for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$id" "FAILED"; continue
    fi
    printf "  %-14s  %15s  %15s  %15s  %15s\n" "$id" \
        "$(jval fio_seqwrite_bw "$json")" \
        "$(jval fio_seqread_bw "$json")" \
        "$(jval fio_randread_iops "$json")" \
        "$(jval fio_randwrite_iops "$json")"
done

echo ""
echo "  NETWORK"
printf "  %-14s  %10s  %8s  %10s  %8s\n" \
    "CLUSTER" "PING_AVG" "DNS_MS" "DL_MB/S" "TTFB_MS"
printf '  %.0s─' {1..56}; echo
for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$id" "FAILED"; continue
    fi
    printf "  %-14s  %10s  %8s  %10s  %8s\n" "$id" \
        "$(jval ping_avg_ms "$json")" \
        "$(jval dns_ms "$json")" \
        "$(jval download_mbps "$json")" \
        "$(jval ttfb_ms "$json")"
done

# ---------------------------------------------------------------------------
# Per-cluster user experience analysis
# ---------------------------------------------------------------------------
echo ""
echo "  ============================================================================"
echo "  ANALYSIS — PER-CLUSTER USER EXPERIENCE"
echo "  ============================================================================"

for id in "${TARGET_IDS[@]}"; do
    json="$RESULTS_DIR/$id/results.json"
    if [[ ! -f "$json" ]] || grep -q '"error"' "$json" 2>/dev/null; then
        echo ""
        echo "  $id — FAILED (no results)"
        continue
    fi

    cname=$(jval cluster "$json")
    ssh_rtt=$(jval ssh_roundtrip_avg "$json")
    boot_ms=$(jval vm_boot "$json")
    ssh_ms=$(jval ssh_ready "$json")
    dnf_ms=$(jval dnf_install "$json")
    gcc_ms=$(jval gcc_compile "$json")
    files_ms=$(jval create_1000_files "$json")
    ping_v=$(jval ping_avg_ms "$json")
    dl_v=$(jval download_mbps "$json")

    boot_total=$(( boot_ms + ssh_ms ))

    echo ""
    echo "  ┌─ $cname ($id)"
    echo "  │"

    if (( boot_total < 30000 )); then
        echo "  │  Provisioning: VM ready in $(ms2s $boot_total) — fast."
    elif (( boot_total < 60000 )); then
        echo "  │  Provisioning: VM ready in $(ms2s $boot_total) — acceptable."
    else
        echo "  │  Provisioning: VM ready in $(ms2s $boot_total) — slow, users will wait."
    fi

    if (( ssh_rtt < 200 )); then
        echo "  │  Interactive:  ${ssh_rtt}ms SSH round-trip — excellent, feels instant."
    elif (( ssh_rtt < 280 )); then
        echo "  │  Interactive:  ${ssh_rtt}ms SSH round-trip — good, responsive."
    elif (( ssh_rtt < 350 )); then
        echo "  │  Interactive:  ${ssh_rtt}ms SSH round-trip — fair, slight delay on commands."
    else
        echo "  │  Interactive:  ${ssh_rtt}ms SSH round-trip — sluggish, users will notice lag."
    fi

    if (( dnf_ms > 0 && dnf_ms < 4000 )); then
        echo "  │  Tasks:        dnf install $(ms2s $dnf_ms), gcc $(ms2s $gcc_ms) — fast."
    elif (( dnf_ms > 0 && dnf_ms < 6000 )); then
        echo "  │  Tasks:        dnf install $(ms2s $dnf_ms), gcc $(ms2s $gcc_ms) — OK."
    elif (( dnf_ms > 0 )); then
        echo "  │  Tasks:        dnf install $(ms2s $dnf_ms), gcc $(ms2s $gcc_ms) — slow."
    fi

    if (( files_ms > 0 && files_ms < 250 )); then
        echo "  │  Filesystem:   1000 files in ${files_ms}ms — snappy."
    elif (( files_ms > 0 && files_ms < 350 )); then
        echo "  │  Filesystem:   1000 files in ${files_ms}ms — OK."
    elif (( files_ms > 0 )); then
        echo "  │  Filesystem:   1000 files in ${files_ms}ms — sluggish disk metadata."
    fi

    net_verdict=""
    if [[ "$dl_v" == "0.00" || "$dl_v" == "0" || "$dl_v" == "N/A" || "$dl_v" == "?" ]]; then
        net_verdict="download FAILED or skipped, ping ${ping_v}ms"
    else
        if (( $(awk "BEGIN{print ($dl_v < 3)}" 2>/dev/null) )); then
            net_verdict="${dl_v} MB/s download (slow), ping ${ping_v}ms"
        elif (( $(awk "BEGIN{print ($dl_v < 8)}" 2>/dev/null) )); then
            net_verdict="${dl_v} MB/s download, ping ${ping_v}ms — OK."
        else
            net_verdict="${dl_v} MB/s download, ping ${ping_v}ms — good."
        fi
    fi
    echo "  │  Network:      $net_verdict"

    score=0
    if (( ssh_rtt < 200 )); then score=$((score + 0));
    elif (( ssh_rtt < 250 )); then score=$((score + 1));
    elif (( ssh_rtt < 300 )); then score=$((score + 2));
    elif (( ssh_rtt < 350 )); then score=$((score + 3));
    else score=$((score + 5)); fi
    if (( dnf_ms > 0 && dnf_ms < 3500 )); then score=$((score + 0));
    elif (( dnf_ms < 5000 )); then score=$((score + 1));
    elif (( dnf_ms < 6500 )); then score=$((score + 2));
    else score=$((score + 3)); fi
    if (( files_ms > 0 && files_ms < 250 )); then score=$((score + 0));
    elif (( files_ms < 320 )); then score=$((score + 1));
    else score=$((score + 2)); fi
    dl_st=$(jval download_status "$json"); [[ "$dl_st" == "0" || "$dl_st" == "?" ]] && dl_st=""
    git_st=$(jval git_status "$json"); [[ "$git_st" == "0" || "$git_st" == "?" ]] && git_st=""
    ping_st=$(jval ping_status "$json"); [[ "$ping_st" == "0" || "$ping_st" == "?" ]] && ping_st=""
    dns_st=$(jval dns_status "$json"); [[ "$dns_st" == "0" || "$dns_st" == "?" ]] && dns_st=""
    if [[ "$dl_st" != "skipped" && "$dl_v" != "skipped" ]]; then
        if [[ "$dl_st" == "failed" || "$dl_v" == "0.00" || "$dl_v" == "0" || "$dl_v" == "failed" ]]; then
            score=$((score + 2))
        elif [[ "$dl_v" != "N/A" && "$dl_v" != "?" ]] && (( $(awk "BEGIN{print ($dl_v < 3 && $dl_v > 0)}" 2>/dev/null) )); then
            score=$((score + 1))
        fi
    fi
    [[ "$git_st" == "failed" ]] && score=$((score + 1))
    [[ "$ping_st" == "failed" ]] && score=$((score + 1))
    [[ "$dns_st" == "failed" ]] && score=$((score + 1))
    if (( boot_total > 50000 )); then score=$((score + 1)); fi

    echo "  │"
    if (( score <= 1 )); then
        echo "  │  Verdict:      Excellent. Snappy and responsive — great user experience."
    elif (( score <= 3 )); then
        echo "  │  Verdict:      Good. Smooth experience, no complaints expected."
    elif (( score <= 5 )); then
        echo "  │  Verdict:      Fair. Usable but users may notice occasional sluggishness."
    elif (( score <= 7 )); then
        echo "  │  Verdict:      Below average. Noticeable delays — users will feel friction."
    else
        echo "  │  Verdict:      Poor. Sluggish experience — likely to generate complaints."
    fi
    echo "  └──"
done

echo ""
echo "  ============================================================================"

echo ""
log "Full results: $RESULTS_DIR/"
log "Failed: $FAILED / ${#TARGETS[@]}"
