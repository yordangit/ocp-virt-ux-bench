#!/bin/bash
#
# Compare two guest UX bench runs side by side.
# Shows deltas with improvement/regression indicators.
#
# Usage:
#   ./compare-results.sh results/20310512-194600 results/20310513-103000
#   ./compare-results.sh results/20310512-194600   # compares against latest
#

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_dir() {
    local d="$1"
    [[ "$d" != /* ]] && d="$SCRIPT_DIR/$d"
    echo "${d%/}"
}

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <older-run> [newer-run]"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") results/20310512-194600 results/20310513-103000"
    echo "  $(basename "$0") results/20310512-194600   # compare against latest"
    echo ""
    echo "Available runs:"
    ls -1d "$SCRIPT_DIR"/results/*/ 2>/dev/null | while read d; do
        run=$(basename "$d")
        count=$(ls "$d"/*/results.json 2>/dev/null | wc -l | tr -d ' ')
        echo "  $run  ($count clusters)"
    done
    exit 0
fi

RUN_A=$(resolve_dir "$1")

if [[ $# -ge 2 ]]; then
    RUN_B=$(resolve_dir "$2")
else
    RUN_B=$(ls -td "$SCRIPT_DIR"/results/*/ 2>/dev/null | head -1)
    RUN_B="${RUN_B%/}"
fi

[[ ! -d "$RUN_A" ]] && echo "Not found: $RUN_A" && exit 1
[[ ! -d "$RUN_B" ]] && echo "Not found: $RUN_B" && exit 1
[[ "$RUN_A" == "$RUN_B" ]] && echo "Both runs are the same directory." && exit 1

LABEL_A=$(basename "$RUN_A")
LABEL_B=$(basename "$RUN_B")

# Find clusters present in both runs
CLUSTERS=()
for d in "$RUN_A"/*/; do
    vm_short=$(basename "$d")
    if [[ -f "$RUN_A/$vm_short/results.json" && -f "$RUN_B/$vm_short/results.json" ]]; then
        # Skip error results
        grep -q '"error"' "$RUN_A/$vm_short/results.json" 2>/dev/null && continue
        grep -q '"error"' "$RUN_B/$vm_short/results.json" 2>/dev/null && continue
        CLUSTERS+=("$vm_short")
    fi
done

if [[ ${#CLUSTERS[@]} -eq 0 ]]; then
    echo "No overlapping clusters with valid results found between the two runs."
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
jval() { grep -o "\"$1\": *[\"]*[^,\"]*" "$2" | head -1 | sed 's/.*: *"*//;s/"$//' || echo "0"; }

delta_ms() {
    local a="$1" b="$2"
    local diff=$(( b - a ))
    if (( diff < -50 )); then
        printf "%+dms (faster)" "$diff"
    elif (( diff > 50 )); then
        printf "%+dms (slower)" "$diff"
    else
        printf "~same"
    fi
}

delta_s() {
    local a="$1" b="$2"
    local diff=$(( b - a ))
    local secs
    secs=$(awk "BEGIN{printf \"%.1f\", $diff/1000}" 2>/dev/null)
    if (( diff < -500 )); then
        printf "%ss (faster)" "$secs"
    elif (( diff > 500 )); then
        printf "+%ss (slower)" "$secs"
    else
        printf "~same"
    fi
}

delta_float() {
    local a="$1" b="$2" unit="$3" higher_is_better="${4:-true}"
    local diff
    diff=$(awk "BEGIN{printf \"%.2f\", $b - $a}" 2>/dev/null)
    local pct
    pct=$(awk "BEGIN{if($a!=0) printf \"%.0f\", (($b-$a)/$a)*100; else print 0}" 2>/dev/null)
    local dir=""
    if [[ "$higher_is_better" == "true" ]]; then
        if (( pct > 10 )); then dir="(better)";
        elif (( pct < -10 )); then dir="(worse)";
        else dir="(~same)"; fi
    else
        if (( pct < -10 )); then dir="(better)";
        elif (( pct > 10 )); then dir="(worse)";
        else dir="(~same)"; fi
    fi
    printf "%+.2f %s %s%% %s" "$diff" "$unit" "$pct" "$dir"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "  ============================================================================"
echo "  GUEST UX BENCH COMPARISON"
echo "  ============================================================================"
echo "  Run A (before): $LABEL_A"
echo "  Run B (after):  $LABEL_B"
echo "  Clusters:       ${#CLUSTERS[@]} in common"
echo "  ============================================================================"

for vm_short in "${CLUSTERS[@]}"; do
    json_a="$RUN_A/$vm_short/results.json"
    json_b="$RUN_B/$vm_short/results.json"

    cname=$(jval cluster "$json_b")

    # Extract values
    ssh_a=$(jval ssh_roundtrip_avg "$json_a")
    ssh_b=$(jval ssh_roundtrip_avg "$json_b")
    ls_a=$(jval cmd_ls_etc "$json_a")
    ls_b=$(jval cmd_ls_etc "$json_b")
    find_a=$(jval cmd_find_conf "$json_a")
    find_b=$(jval cmd_find_conf "$json_b")
    dnf_a=$(jval dnf_install "$json_a")
    dnf_b=$(jval dnf_install "$json_b")
    gcc_a=$(jval gcc_compile "$json_a")
    gcc_b=$(jval gcc_compile "$json_b")
    files_a=$(jval create_1000_files "$json_a")
    files_b=$(jval create_1000_files "$json_b")
    boot_a=$(( $(jval vm_boot "$json_a") + $(jval ssh_ready "$json_a") ))
    boot_b=$(( $(jval vm_boot "$json_b") + $(jval ssh_ready "$json_b") ))
    ping_a=$(jval ping_avg_ms "$json_a")
    ping_b=$(jval ping_avg_ms "$json_b")
    dl_a=$(jval download_mbps "$json_a")
    dl_b=$(jval download_mbps "$json_b")

    echo ""
    echo "  ┌─ $cname ($vm_short)"
    echo "  │"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "SSH round-trip" "${ssh_a}ms" "${ssh_b}ms" "$(delta_ms "$ssh_a" "$ssh_b")"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "ls -laR /etc" "${ls_a}ms" "${ls_b}ms" "$(delta_ms "$ls_a" "$ls_b")"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "find *.conf" "${find_a}ms" "${find_b}ms" "$(delta_ms "$find_a" "$find_b")"
    echo "  │"
    dnf_a_s=$(awk "BEGIN{printf \"%.1fs\",$dnf_a/1000}")
    dnf_b_s=$(awk "BEGIN{printf \"%.1fs\",$dnf_b/1000}")
    dnf_delta=$(delta_s "$dnf_a" "$dnf_b")
    boot_a_s=$(awk "BEGIN{printf \"%.1fs\",$boot_a/1000}")
    boot_b_s=$(awk "BEGIN{printf \"%.1fs\",$boot_b/1000}")
    boot_delta=$(delta_s "$boot_a" "$boot_b")
    printf "  │  %-22s  %8s  →  %8s    %s\n" "dnf install" "$dnf_a_s" "$dnf_b_s" "$dnf_delta"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "gcc compile" "${gcc_a}ms" "${gcc_b}ms" "$(delta_ms "$gcc_a" "$gcc_b")"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "Create 1000 files" "${files_a}ms" "${files_b}ms" "$(delta_ms "$files_a" "$files_b")"
    echo "  │"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "VM ready" "$boot_a_s" "$boot_b_s" "$boot_delta"
    ping_delta=$(delta_float "$ping_a" "$ping_b" "ms" "false")
    dl_delta=$(delta_float "$dl_a" "$dl_b" "MB/s" "true")
    printf "  │  %-22s  %8s  →  %8s    %s\n" "Ping avg" "${ping_a}ms" "${ping_b}ms" "$ping_delta"
    printf "  │  %-22s  %8s  →  %8s    %s\n" "Download" "${dl_a}MB/s" "${dl_b}MB/s" "$dl_delta"
    echo "  │"

    # Score each run (same logic as view-results.sh)
    score_a=0 score_b=0
    for _ssh in "$ssh_a:score_a" "$ssh_b:score_b"; do
        _v=${_ssh%%:*}; _var=${_ssh##*:}
        if (( _v < 200 )); then eval "$_var=\$((\$$_var + 0))";
        elif (( _v < 250 )); then eval "$_var=\$((\$$_var + 1))";
        elif (( _v < 300 )); then eval "$_var=\$((\$$_var + 2))";
        elif (( _v < 350 )); then eval "$_var=\$((\$$_var + 3))";
        else eval "$_var=\$((\$$_var + 5))"; fi
    done
    for _dnf in "$dnf_a:score_a" "$dnf_b:score_b"; do
        _v=${_dnf%%:*}; _var=${_dnf##*:}
        if (( _v > 0 && _v < 3500 )); then eval "$_var=\$((\$$_var + 0))";
        elif (( _v < 5000 )); then eval "$_var=\$((\$$_var + 1))";
        elif (( _v < 6500 )); then eval "$_var=\$((\$$_var + 2))";
        else eval "$_var=\$((\$$_var + 3))"; fi
    done
    for _f in "$files_a:score_a" "$files_b:score_b"; do
        _v=${_f%%:*}; _var=${_f##*:}
        if (( _v > 0 && _v < 250 )); then eval "$_var=\$((\$$_var + 0))";
        elif (( _v < 320 )); then eval "$_var=\$((\$$_var + 1))";
        else eval "$_var=\$((\$$_var + 2))"; fi
    done
    # External statuses (skipped = no ding)
    for _side in a b; do
        _json_var="json_${_side}"
        _score_var="score_${_side}"
        _dl_var="dl_${_side}"
        _json="${!_json_var}"
        _dl="${!_dl_var}"
        _dl_st=$(jval download_status "$_json"); [[ "$_dl_st" == "0" ]] && _dl_st=""
        _git_st=$(jval git_status "$_json"); [[ "$_git_st" == "0" ]] && _git_st=""
        _ping_st=$(jval ping_status "$_json"); [[ "$_ping_st" == "0" ]] && _ping_st=""
        _dns_st=$(jval dns_status "$_json"); [[ "$_dns_st" == "0" ]] && _dns_st=""
        if [[ "$_dl_st" != "skipped" && "$_dl" != "skipped" ]]; then
            if [[ "$_dl_st" == "failed" || "$_dl" == "0.00" || "$_dl" == "0" || "$_dl" == "failed" ]]; then
                eval "$_score_var=\$((${_score_var} + 2))"
            elif [[ "$_dl" != "N/A" ]] && (( $(awk "BEGIN{print ($_dl < 3 && $_dl > 0)}" 2>/dev/null) )); then
                eval "$_score_var=\$((${_score_var} + 1))"
            fi
        fi
        [[ "$_git_st" == "failed" ]] && eval "$_score_var=\$((${_score_var} + 1))"
        [[ "$_ping_st" == "failed" ]] && eval "$_score_var=\$((${_score_var} + 1))"
        [[ "$_dns_st" == "failed" ]] && eval "$_score_var=\$((${_score_var} + 1))"
    done
    (( boot_a > 50000 )) && score_a=$((score_a + 1))
    (( boot_b > 50000 )) && score_b=$((score_b + 1))

    verdict_for() {
        local s=$1
        if (( s <= 1 )); then echo "Excellent";
        elif (( s <= 3 )); then echo "Good";
        elif (( s <= 5 )); then echo "Fair";
        elif (( s <= 7 )); then echo "Below avg";
        else echo "Poor"; fi
    }

    v_a=$(verdict_for $score_a)
    v_b=$(verdict_for $score_b)
    score_diff=$((score_a - score_b))

    if (( score_diff > 0 )); then
        trend="IMPROVED (score $score_a → $score_b)"
    elif (( score_diff < 0 )); then
        trend="REGRESSED (score $score_a → $score_b)"
    else
        trend="UNCHANGED (score $score_a)"
    fi

    printf "  │  %-22s  %8s  →  %8s    %s\n" "Verdict" "$v_a" "$v_b" "$trend"
    echo "  └──"
done

echo ""
echo "  ============================================================================"
echo ""
