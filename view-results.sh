#!/bin/bash
#
# View results from a previous guest UX bench run.
#
# Usage:
#   ./view-results.sh                          # latest run
#   ./view-results.sh results/20310512-184750  # specific run
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -gt 0 ]]; then
    RESULTS_DIR="$1"
    # Allow relative paths
    [[ "$RESULTS_DIR" != /* ]] && RESULTS_DIR="$SCRIPT_DIR/$RESULTS_DIR"
else
    RESULTS_DIR=$(ls -td "$SCRIPT_DIR"/results/*/ 2>/dev/null | head -1)
    if [[ -z "$RESULTS_DIR" ]]; then
        echo "No results found in $SCRIPT_DIR/results/"
        echo "Run ./dispatch.sh first."
        exit 1
    fi
    RESULTS_DIR="${RESULTS_DIR%/}"
fi

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "Results directory not found: $RESULTS_DIR"
    exit 1
fi

# Discover which clusters have results
CLUSTERS=()
for d in "$RESULTS_DIR"/*/; do
    [[ -f "$d/results.json" ]] && CLUSTERS+=("$(basename "$d")")
done

if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
    echo "No results.json files found in $RESULTS_DIR/"
    exit 1
fi

echo ""
echo "  Guest UX Bench Results — $(basename "$RESULTS_DIR")"
echo "  $(date -r "$RESULTS_DIR" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "")"
echo "  Clusters: ${#CLUSTERS[@]}"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
jval() { grep -o "\"$1\": *[\"]*[^,\"]*" "$2" | head -1 | sed 's/.*: *"*//;s/"$//' || echo "?"; }
ms2s() { awk "BEGIN{printf \"%.1fs\", ${1:-0}/1000}" 2>/dev/null || echo "?"; }

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------
echo "  LIFECYCLE"
printf "  %-14s  %8s  %8s  %8s  %8s  %8s\n" \
    "CLUSTER" "BOOT" "SSH" "CLOUD" "DESTROY" "TOTAL"
printf '  %.0s─' {1..62}; echo
for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$vm_short" "FAILED"; continue
    fi
    printf "  %-14s  %8s  %8s  %8s  %8s  %8s\n" "$vm_short" \
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
for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$vm_short" "FAILED"; continue
    fi
    printf "  %-14s  %8s  %8s  %8s  %8s\n" "$vm_short" \
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
for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$vm_short" "FAILED"; continue
    fi
    printf "  %-14s  %10s  %10s  %8s  %8s  %10s\n" "$vm_short" \
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
for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$vm_short" "FAILED"; continue
    fi
    printf "  %-14s  %15s  %15s  %15s  %15s\n" "$vm_short" \
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
for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        printf "  %-14s  %s\n" "$vm_short" "FAILED"; continue
    fi
    printf "  %-14s  %10s  %8s  %10s  %8s\n" "$vm_short" \
        "$(jval ping_avg_ms "$json")" \
        "$(jval dns_ms "$json")" \
        "$(jval download_mbps "$json")" \
        "$(jval ttfb_ms "$json")"
done

# ---------------------------------------------------------------------------
# Per-cluster analysis
# ---------------------------------------------------------------------------
echo ""
echo "  ============================================================================"
echo "  ANALYSIS — PER-CLUSTER USER EXPERIENCE"
echo "  ============================================================================"

for vm_short in "${CLUSTERS[@]}"; do
    json="$RESULTS_DIR/$vm_short/results.json"
    if grep -q '"error"' "$json" 2>/dev/null; then
        echo ""
        echo "  $vm_short — FAILED (no results)"
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
    echo "  ┌─ $cname ($vm_short)"
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
    if [[ "$dl_v" == "0.00" || "$dl_v" == "0" ]]; then
        net_verdict="download FAILED (blocked?), ping ${ping_v}ms"
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
