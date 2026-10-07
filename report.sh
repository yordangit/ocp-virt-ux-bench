#!/bin/bash
#
# Generate a performance report across all runs.
# Ingests every results.json, outputs CSV + terminal trend graph.
#
# Usage:
#   ./report.sh                  # all runs, terminal + CSV
#   ./report.sh --csv-only       # just generate CSV, no terminal output
#   ./report.sh --cluster clu01  # filter to one cluster
#

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_BASE="$SCRIPT_DIR/results"
CSV_FILE="$RESULTS_BASE/performance-report.csv"
FILTER_CLUSTER=""
CSV_ONLY=false
EXPORT_SHEETS=false
# Optional default: set GUEST_UX_SHEET_ID or pass --sheet-id / --new-sheet
DEFAULT_SHEET_ID="${GUEST_UX_SHEET_ID:-}"
SHEET_ID=""
NEW_SHEET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv-only)      CSV_ONLY=true; shift ;;
        --csv)           CSV_FILE="$2"; shift 2 ;;
        --cluster)       FILTER_CLUSTER="$2"; shift 2 ;;
        --sheets)        EXPORT_SHEETS=true; shift ;;
        --sheet-id)      SHEET_ID="$2"; EXPORT_SHEETS=true; shift 2 ;;
        --new-sheet)     NEW_SHEET=true; EXPORT_SHEETS=true; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --csv-only          Generate CSV only, no terminal output"
            echo "  --csv FILE          Set CSV output path (default: results/performance-report.csv)"
            echo "  --cluster NAME      Filter to a specific cluster short name"
            echo "  --sheets            Update Google Sheet (requires gws CLI + --sheet-id or GUEST_UX_SHEET_ID)"
            echo "  --sheet-id ID       Spreadsheet ID to update"
            echo "  --new-sheet         Create a new spreadsheet"
            echo "  --help              Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$RESULTS_BASE" ]]; then
    echo "No results directory found at $RESULTS_BASE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
jval() { grep -o "\"$1\": *[\"]*[^,\"]*" "$2" | head -1 | sed 's/.*: *"*//;s/"$//' || echo "0"; }

# Optional args 6–9: download_status git_status ping_status dns_status (ok|failed|skipped)
calc_score() {
    local ssh_rtt=$1 dnf_ms=$2 files_ms=$3 dl_v=$4 boot_total=$5
    local dl_status=${6:-} git_status=${7:-} ping_status=${8:-} dns_status=${9:-}
    local score=0
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
    # External: skipped = no score impact; set+failed = penalty
    if [[ "$dl_status" != "skipped" && "$dl_v" != "skipped" ]]; then
        if [[ "$dl_status" == "failed" || "$dl_v" == "0.00" || "$dl_v" == "0" || "$dl_v" == "failed" ]]; then
            score=$((score + 2))
        elif [[ "$dl_v" != "N/A" && "$dl_v" != "?" ]] && (( $(awk "BEGIN{print ($dl_v < 3 && $dl_v > 0)}" 2>/dev/null) )); then
            score=$((score + 1))
        fi
    fi
    [[ "$git_status" == "failed" ]] && score=$((score + 1))
    [[ "$ping_status" == "failed" ]] && score=$((score + 1))
    [[ "$dns_status" == "failed" ]] && score=$((score + 1))
    (( boot_total > 50000 )) && score=$((score + 1))
    echo $score
}

verdict_for() {
    local s=$1
    if (( s <= 1 )); then echo "Excellent";
    elif (( s <= 3 )); then echo "Good";
    elif (( s <= 5 )); then echo "Fair";
    elif (( s <= 7 )); then echo "Below avg";
    else echo "Poor"; fi
}

# ---------------------------------------------------------------------------
# Ingest all results
# ---------------------------------------------------------------------------
# Temp file: run_date vm_short cluster ssh_rtt ls_etc find_conf dnf_ms gcc_ms files_ms boot_total ping dl score verdict
DATA_FILE=$(mktemp)
trap "rm -f $DATA_FILE" EXIT

for run_dir in "$RESULTS_BASE"/*/; do
    run_name=$(basename "$run_dir")
    # Extract date from directory name (YYYYMMDD-HHMMSS)
    # Handle both old (YYYYMMDD-HHMMSS) and new UTC (YYYYMMDD-HHMMSSZ) folder names
    run_date=$(echo "$run_name" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)Z\{0,1\}/\1-\2-\3 \4:\5 UTC/')

    for cluster_dir in "$run_dir"/*/; do
        vm_short=$(basename "$cluster_dir")
        json="$cluster_dir/results.json"
        [[ ! -f "$json" ]] && continue
        grep -q '"error"' "$json" 2>/dev/null && continue
        [[ -n "$FILTER_CLUSTER" && "$vm_short" != "$FILTER_CLUSTER" ]] && continue

        cluster=$(jval cluster "$json")
        ssh_rtt=$(jval ssh_roundtrip_avg "$json")
        ls_etc=$(jval cmd_ls_etc "$json")
        find_conf=$(jval cmd_find_conf "$json")
        dnf_ms=$(jval dnf_install "$json")
        gcc_ms=$(jval gcc_compile "$json")
        run_bin=$(jval run_binary "$json")
        files_ms=$(jval create_1000_files "$json")
        tar_cr=$(jval tar_create "$json")
        tar_ex=$(jval tar_extract "$json")
        boot_ms=$(jval vm_boot "$json")
        ssh_ms=$(jval ssh_ready "$json")
        cloud_ms=$(jval cloud_init "$json")
        destroy_ms=$(jval vm_destroy "$json")
        boot_total=$(( boot_ms + ssh_ms ))
        ping_v=$(jval ping_avg_ms "$json")
        dl_v=$(jval download_mbps "$json")
        dns_ms=$(jval dns_ms "$json")
        ttfb=$(jval ttfb_ms "$json")
        total_ms=$(jval total "$json")
        dl_st=$(jval download_status "$json")
        git_st=$(jval git_status "$json")
        ping_st=$(jval ping_status "$json")
        dns_st=$(jval dns_status "$json")
        [[ "$dl_st" == "0" ]] && dl_st=""
        [[ "$git_st" == "0" ]] && git_st=""
        [[ "$ping_st" == "0" ]] && ping_st=""
        [[ "$dns_st" == "0" ]] && dns_st=""

        score=$(calc_score "$ssh_rtt" "$dnf_ms" "$files_ms" "$dl_v" "$boot_total" "$dl_st" "$git_st" "$ping_st" "$dns_st")
        verdict=$(verdict_for "$score")

        # Write to temp data file (tab-separated for easy awk processing)
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$run_date" "$vm_short" "$cluster" \
            "$ssh_rtt" "$ls_etc" "$find_conf" \
            "$dnf_ms" "$gcc_ms" "$run_bin" "$files_ms" "$tar_cr" "$tar_ex" \
            "$boot_ms" "$ssh_ms" "$cloud_ms" "$destroy_ms" "$total_ms" \
            "$ping_v" "$dl_v" "$dns_ms" "$ttfb" \
            "$dl_st" "$git_st" "$ping_st" "$dns_st" \
            >> "$DATA_FILE"
        # Also store score/verdict in a separate line-format for graph
        echo "SCORE|$run_date|$vm_short|$score|$verdict" >> "$DATA_FILE"
    done
done

if [[ ! -s "$DATA_FILE" ]]; then
    echo "No valid results found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Generate CSV
# ---------------------------------------------------------------------------
echo "date,cluster,cluster_name,ssh_rtt_ms,ls_etc_ms,find_conf_ms,dnf_install_ms,gcc_compile_ms,run_binary_ms,create_1000_files_ms,tar_create_ms,tar_extract_ms,vm_boot_ms,ssh_ready_ms,cloud_init_ms,vm_destroy_ms,total_ms,ping_avg_ms,download_mbps,dns_ms,ttfb_ms,score,verdict" > "$CSV_FILE"

grep -v '^SCORE|' "$DATA_FILE" | sort | while IFS=$'\t' read -r run_date vm_short cluster ssh_rtt ls_etc find_conf dnf_ms gcc_ms run_bin files_ms tar_cr tar_ex boot_ms ssh_ms cloud_ms destroy_ms total_ms ping_v dl_v dns_ms ttfb dl_st git_st ping_st dns_st; do
    score=$(calc_score "$ssh_rtt" "$dnf_ms" "$files_ms" "$dl_v" "$(( boot_ms + ssh_ms ))" "$dl_st" "$git_st" "$ping_st" "$dns_st")
    verdict=$(verdict_for "$score")
    echo "$run_date,$vm_short,$cluster,$ssh_rtt,$ls_etc,$find_conf,$dnf_ms,$gcc_ms,$run_bin,$files_ms,$tar_cr,$tar_ex,$boot_ms,$ssh_ms,$cloud_ms,$destroy_ms,$total_ms,$ping_v,$dl_v,$dns_ms,$ttfb,$score,$verdict"
done >> "$CSV_FILE"

row_count=$(wc -l < "$CSV_FILE" | tr -d ' ')
echo "CSV saved: $CSV_FILE ($((row_count - 1)) data rows)"

if $CSV_ONLY; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Terminal: score trend graph per cluster
# ---------------------------------------------------------------------------
echo ""
echo "  ============================================================================"
echo "  PERFORMANCE TREND — SCORE OVER TIME (lower is better)"
echo "  ============================================================================"
echo "  0=Excellent  1-3=Good  4-5=Fair  6-7=Below avg  8+=Poor"
echo ""

# Get unique clusters
clusters_list=$(grep '^SCORE|' "$DATA_FILE" | cut -d'|' -f3 | sort -u)

for cl in $clusters_list; do
    # Get all scores for this cluster, sorted by date
    cl_data=$(grep "^SCORE|" "$DATA_FILE" | grep "|${cl}|" | sort -t'|' -k2)
    cl_name=$(grep -v '^SCORE|' "$DATA_FILE" | grep "$cl" | head -1 | cut -f3)

    echo "  ┌─ ${cl_name:-$cl} ($cl)"
    echo "  │"

    # Header: date labels
    dates=""
    scores=""
    while IFS='|' read -r _ run_date vm sc vd; do
        short_date=$(echo "$run_date" | sed 's/^[0-9]\{4\}-//' | sed 's/ /,/')
        dates="$dates $short_date"
        scores="$scores $sc"
    done <<< "$cl_data"

    # Draw horizontal bar chart per run
    while IFS='|' read -r _ run_date vm sc vd; do
        short_date=$(echo "$run_date" | sed 's/^[0-9]\{4\}-//' | sed 's/ /,/')
        bar=""
        for i in $(seq 1 "$sc"); do bar="${bar}#"; done
        # Color hint in the label
        printf "  │  %-12s [%2d] %-15s  %s\n" "$short_date" "$sc" "$bar" "$vd"
    done <<< "$cl_data"

    # Trend
    first_score=$(echo "$cl_data" | head -1 | cut -d'|' -f4)
    last_score=$(echo "$cl_data" | tail -1 | cut -d'|' -f4)
    num_runs=$(echo "$cl_data" | wc -l | tr -d ' ')

    echo "  │"
    if (( num_runs < 2 )); then
        echo "  │  Trend: only 1 run, need more data"
    elif (( last_score < first_score )); then
        echo "  │  Trend: IMPROVING ($first_score → $last_score)"
    elif (( last_score > first_score )); then
        echo "  │  Trend: DEGRADING ($first_score → $last_score)"
    else
        echo "  │  Trend: STABLE (score $first_score)"
    fi
    echo "  └──"
    echo ""
done

# ---------------------------------------------------------------------------
# Terminal: summary table — latest score per cluster
# ---------------------------------------------------------------------------
echo "  ============================================================================"
echo "  LATEST SCORES"
echo "  ============================================================================"
echo ""
printf "  %-14s  %6s  %10s  %8s  %8s  %8s  %10s\n" \
    "CLUSTER" "SCORE" "VERDICT" "SSH_RTT" "DNF" "PING" "DOWNLOAD"
printf '  %.0s─' {1..76}; echo

for cl in $clusters_list; do
    latest_line=$(grep "^SCORE|" "$DATA_FILE" | grep "|${cl}|" | sort -t'|' -k2 | tail -1)
    latest_date=$(echo "$latest_line" | cut -d'|' -f2)
    sc=$(echo "$latest_line" | cut -d'|' -f4)
    vd=$(echo "$latest_line" | cut -d'|' -f5)

    # Get metrics from the data line
    metrics_line=$(grep -v '^SCORE|' "$DATA_FILE" | grep "$latest_date" | grep "$cl" | tail -1)
    ssh_rtt=$(echo "$metrics_line" | cut -f4)
    dnf_ms=$(echo "$metrics_line" | cut -f7)
    ping_v=$(echo "$metrics_line" | cut -f18)
    dl_v=$(echo "$metrics_line" | cut -f19)
    dnf_s=$(awk "BEGIN{printf \"%.1fs\", $dnf_ms/1000}")

    printf "  %-14s  %6s  %10s  %6sms  %8s  %6sms  %8sMB/s\n" \
        "$cl" "$sc" "$vd" "$ssh_rtt" "$dnf_s" "$ping_v" "$dl_v"
done

echo ""
echo "  ============================================================================"
echo ""

# ---------------------------------------------------------------------------
# Google Sheets export
# ---------------------------------------------------------------------------
if $EXPORT_SHEETS; then
    if ! command -v gws &>/dev/null; then
        echo "ERROR: gws CLI not found. Install it first."
        exit 1
    fi

    # Resolve spreadsheet ID: --new-sheet > --sheet-id > GUEST_UX_SHEET_ID
    SPREADSHEET_ID=""
    IS_UPDATE=false

    if $NEW_SHEET; then
        echo "Creating new Google Sheet..."
        SHEET_TITLE="Guest UX Bench Report"
        result=$(gws sheets spreadsheets create --json "{
            \"properties\": {\"title\": \"$SHEET_TITLE\"},
            \"sheets\": [
                {\"properties\": {\"title\": \"Data\", \"sheetId\": 0}},
                {\"properties\": {\"title\": \"Score Trend\", \"sheetId\": 1}},
                {\"properties\": {\"title\": \"Chart\", \"sheetId\": 2}}
            ]
        }" 2>&1)

        SPREADSHEET_ID=$(echo "$result" | grep -o '"spreadsheetId": "[^"]*"' | head -1 | cut -d'"' -f4)

        if [[ -z "$SPREADSHEET_ID" ]]; then
            echo "ERROR: Failed to create spreadsheet"
            echo "$result"
            exit 1
        fi
        echo "Spreadsheet created: $SPREADSHEET_ID"
        echo "Reuse with: ./report.sh --sheet-id $SPREADSHEET_ID"
        echo "Or export GUEST_UX_SHEET_ID=$SPREADSHEET_ID"
    elif [[ -n "$SHEET_ID" ]]; then
        SPREADSHEET_ID="$SHEET_ID"
        IS_UPDATE=true
        echo "Updating spreadsheet: $SPREADSHEET_ID"
    elif [[ -n "$DEFAULT_SHEET_ID" ]]; then
        SPREADSHEET_ID="$DEFAULT_SHEET_ID"
        IS_UPDATE=true
        echo "Updating spreadsheet from GUEST_UX_SHEET_ID: $SPREADSHEET_ID"
    else
        echo "ERROR: no spreadsheet ID. Pass --sheet-id ID, --new-sheet, or set GUEST_UX_SHEET_ID."
        exit 1
    fi

    # When updating, clear existing data and charts first
    if $IS_UPDATE; then
        # Clear data ranges
        gws sheets spreadsheets values clear \
            --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\", \"range\": \"Data!A1:Z10000\"}" \
            --json '{}' > /dev/null 2>&1
        gws sheets spreadsheets values clear \
            --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\", \"range\": \"Score Trend!A1:Z10000\"}" \
            --json '{}' > /dev/null 2>&1

        # Delete existing charts on Score Trend sheet
        existing_charts=$(gws sheets spreadsheets get \
            --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" 2>/dev/null \
            | grep -o '"chartId": [0-9]*' | grep -o '[0-9]*' || true)
        if [[ -n "$existing_charts" ]]; then
            delete_reqs=""
            for cid in $existing_charts; do
                delete_reqs="${delete_reqs}{\"deleteEmbeddedObject\":{\"objectId\":$cid}},"
            done
            delete_reqs="${delete_reqs%,}"
            gws sheets spreadsheets batchUpdate \
                --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" \
                --json "{\"requests\":[$delete_reqs]}" > /dev/null 2>&1
        fi

        # Remove existing filters
        gws sheets spreadsheets batchUpdate \
            --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" \
            --json '{"requests":[{"clearBasicFilter":{"sheetId":0}}]}' > /dev/null 2>&1

        # Ensure Chart sheet exists (older spreadsheets may not have it — ignore error if it does)
        gws sheets spreadsheets batchUpdate \
            --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" \
            --json '{"requests":[{"addSheet":{"properties":{"title":"Chart","sheetId":2}}}]}' > /dev/null 2>&1 || true

        echo "Existing data cleared"
    fi

    # Upload CSV data via temp file
    TMP_JSON=$(mktemp)

    # Build values JSON from CSV
    echo -n '{"values":[' > "$TMP_JSON"
    first_line=true
    while IFS= read -r line; do
        $first_line || echo -n ',' >> "$TMP_JSON"
        first_line=false
        echo -n '[' >> "$TMP_JSON"
        first_col=true
        IFS=',' read -ra cols <<< "$line"
        for col in "${cols[@]}"; do
            $first_col || echo -n ',' >> "$TMP_JSON"
            first_col=false
            if [[ "$col" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
                echo -n "$col" >> "$TMP_JSON"
            else
                echo -n "\"$col\"" >> "$TMP_JSON"
            fi
        done
        echo -n ']' >> "$TMP_JSON"
    done < "$CSV_FILE"
    echo ']}' >> "$TMP_JSON"

    gws sheets spreadsheets values update \
        --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\", \"range\": \"Data!A1\", \"valueInputOption\": \"USER_ENTERED\"}" \
        --json "$(cat "$TMP_JSON")" > /dev/null 2>&1

    echo "Data uploaded to 'Data' sheet"

    # Build Score Trend pivot: date x cluster scores
    CLUSTERS_FILE=$(mktemp)
    DATES_FILE=$(mktemp)
    tail -n +2 "$CSV_FILE" | cut -d',' -f2 | sort -u > "$CLUSTERS_FILE"
    tail -n +2 "$CSV_FILE" | cut -d',' -f1 | sort -u > "$DATES_FILE"

    echo -n '{"values":[["date"' > "$TMP_JSON"
    while IFS= read -r cl; do
        echo -n ",\"${cl}\"" >> "$TMP_JSON"
    done < "$CLUSTERS_FILE"
    echo -n ']' >> "$TMP_JSON"

    while IFS= read -r dt; do
        echo -n ",[\"${dt}\"" >> "$TMP_JSON"
        while IFS= read -r cl; do
            score=$(grep "^${dt},${cl}," "$CSV_FILE" | head -1 | rev | cut -d',' -f2 | rev)
            echo -n ",${score:-null}" >> "$TMP_JSON"
        done < "$CLUSTERS_FILE"
        echo -n ']' >> "$TMP_JSON"
    done < "$DATES_FILE"
    echo ']}' >> "$TMP_JSON"

    gws sheets spreadsheets values update \
        --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\", \"range\": \"Score Trend!A1\", \"valueInputOption\": \"USER_ENTERED\"}" \
        --json "$(cat "$TMP_JSON")" > /dev/null 2>&1

    echo "Score trend data uploaded to 'Score Trend' sheet"

    # Add line chart
    num_dates=$(wc -l < "$DATES_FILE" | tr -d ' ')
    num_clusters=$(wc -l < "$CLUSTERS_FILE" | tr -d ' ')

    # Distinct colors for each cluster (max 10)
    COLORS=(
        '{"red":0.20,"green":0.40,"blue":0.85}'
        '{"red":0.85,"green":0.25,"blue":0.20}'
        '{"red":0.20,"green":0.70,"blue":0.30}'
        '{"red":0.80,"green":0.55,"blue":0.10}'
        '{"red":0.55,"green":0.25,"blue":0.80}'
        '{"red":0.00,"green":0.60,"blue":0.60}'
        '{"red":0.85,"green":0.40,"blue":0.60}'
        '{"red":0.40,"green":0.40,"blue":0.40}'
        '{"red":0.00,"green":0.45,"blue":0.75}'
        '{"red":0.70,"green":0.70,"blue":0.00}'
    )

    # Build chart series with explicit colors
    series_json=""
    ci=0
    while IFS= read -r cl; do
        color="${COLORS[$ci]:-${COLORS[0]}}"
        series_json="${series_json}{\"series\":{\"sourceRange\":{\"sources\":[{\"sheetId\":1,\"startRowIndex\":0,\"endRowIndex\":$((num_dates+1)),\"startColumnIndex\":$((ci+1)),\"endColumnIndex\":$((ci+2))}]}},\"targetAxis\":\"LEFT_AXIS\",\"color\":$color},"
        ci=$((ci + 1))
    done < "$CLUSTERS_FILE"
    series_json="${series_json%,}"

    cat > "$TMP_JSON" <<CHARTEOF
{"requests":[{"addChart":{"chart":{"position":{"overlayPosition":{"anchorCell":{"sheetId":2,"rowIndex":0,"columnIndex":0},"widthPixels":1200,"heightPixels":600}},"spec":{"title":"Guest UX Bench Score Trend (lower is better)","basicChart":{"chartType":"LINE","legendPosition":"RIGHT_LEGEND","headerCount":1,"axis":[{"position":"BOTTOM_AXIS","title":"Date"},{"position":"LEFT_AXIS","title":"Score (lower = better)"}],"domains":[{"domain":{"sourceRange":{"sources":[{"sheetId":1,"startRowIndex":0,"endRowIndex":$((num_dates+1)),"startColumnIndex":0,"endColumnIndex":1}]}}}],"series":[$series_json]}}}}}]}
CHARTEOF

    gws sheets spreadsheets batchUpdate \
        --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" \
        --json "$(cat "$TMP_JSON")" > /dev/null 2>&1

    echo "Chart added to 'Chart' sheet"

    # Add filter view on Data sheet so users can filter by cluster
    num_data_rows=$(tail -n +2 "$CSV_FILE" | wc -l | tr -d ' ')
    num_data_cols=$(head -1 "$CSV_FILE" | awk -F',' '{print NF}')

    cat > "$TMP_JSON" <<FILTEREOF
{"requests":[
    {"setBasicFilter":{"filter":{"range":{"sheetId":0,"startRowIndex":0,"endRowIndex":$((num_data_rows+1)),"startColumnIndex":0,"endColumnIndex":$num_data_cols}}}},
    {"addFilterView":{"filter":{"title":"All clusters","range":{"sheetId":0,"startRowIndex":0,"endRowIndex":$((num_data_rows+1)),"startColumnIndex":0,"endColumnIndex":$num_data_cols}}}}
]}
FILTEREOF

    gws sheets spreadsheets batchUpdate \
        --params "{\"spreadsheetId\": \"$SPREADSHEET_ID\"}" \
        --json "$(cat "$TMP_JSON")" > /dev/null 2>&1

    echo "Filter added to 'Data' sheet (use column B dropdown to filter by cluster)"

    rm -f "$TMP_JSON" "$CLUSTERS_FILE" "$DATES_FILE"

    echo ""
    echo "Google Sheet: https://docs.google.com/spreadsheets/d/$SPREADSHEET_ID"
fi
