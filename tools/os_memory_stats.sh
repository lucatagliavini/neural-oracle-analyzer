#!/usr/bin/env bash
# tools/os_memory_stats.sh — metriche RAM e swap dal server OS via SSH
#
# Uso: os_memory_stats.sh ENVIRONMENT HOSTNAME [--samples=N] [--interval=S]
#
# Argomenti posizionali:
#   ENVIRONMENT  — enum: EURO, TEST, CERT, INTE, COLL, PROD
#   HOSTNAME     — hostname fisico del server Oracle
#
# Parametri opzionali:
#   --samples=N   — numero di campioni (default: 5)
#   --interval=S  — secondi tra campioni (default: 2)
#
# Output JSON:
#   data: {
#     os_type: "aix" | "linux",
#     samples: [ {ts, ram_total_bytes, ram_used_bytes, ram_free_bytes,
#                 swap_total_bytes, swap_used_bytes, page_in_per_sec, page_out_per_sec} ],
#     summary: { ram_used_bytes: {min,max,avg,p95,p99}, swap_used_bytes: {...},
#                page_in_per_sec: {...}, page_out_per_sec: {...} }
#   }
#   instance_name: null
#   oracle_version: null
#
# Comandi usati sul target:
#   AIX:
#     RAM:  svmon -G -O unit=byte   → frame size + memory lines (bytes)
#     Swap: lsps -s                 → percentuale swap utilizzata (poi derive from vmstat)
#     Page: vmstat 1 1              → colonne pi/po (page in/out per second)
#   Linux:
#     RAM+Swap: free -b             → una chiamata sola per RAM e swap in bytes
#     Page:     vmstat -n 1 1       → colonne si/so (swap-in/out = page in/out proxy)
#
# Nota AIX: svmon richiede il pacchetto bos.perf.tools. Se mancante → command_not_available.
#           lsps è sempre disponibile su AIX.

set -uo pipefail

TOOL="os_memory_stats"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/oracle_conn.sh
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"
# shellcheck source=../lib/os_cmd.sh
source "${SCRIPT_DIR}/../lib/os_cmd.sh"

# --- Argomenti ----------------------------------------------------------------

ENV="${1:-}"
HOST="${2:-}"
SAMPLES=5
INTERVAL=2

for arg in "${@:3}"; do
    case "$arg" in
        --samples=*)  SAMPLES="${arg#--samples=}"  ;;
        --interval=*) INTERVAL="${arg#--interval=}" ;;
    esac
done

# --- Validazione argomenti ----------------------------------------------------

if ! validate_environment "$ENV" 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '$ENV'. Valori ammessi: EURO TEST CERT INTE COLL PROD" \
        "{\"received\":\"$ENV\"}"
    exit 2
fi

if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "" "null" \
        "invalid_argument" "HOSTNAME obbligatorio" '{"param":"hostname"}'
    exit 2
fi

if ! printf '%s' "$SAMPLES" | grep -qE '^[0-9]+$' || [ "$SAMPLES" -lt 1 ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" "--samples deve essere un intero >= 1" '{"param":"samples"}'
    exit 2
fi
if ! printf '%s' "$INTERVAL" | grep -qE '^[0-9]+$' || [ "$INTERVAL" -lt 0 ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" "--interval deve essere un intero >= 0" '{"param":"interval"}'
    exit 2
fi

# --- Rilevamento OS -----------------------------------------------------------

OS_TYPE=$(os_detect "$HOST")
if [ "$OS_TYPE" = "unknown" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "connection_failed" "Impossibile rilevare OS su $HOST (SSH fallito o timeout)" \
        "{\"detail\":\"uname -s ha fallito su $HOST\"}"
    exit 1
fi

# --- Clamping campioni --------------------------------------------------------

if [ "$INTERVAL" -gt 0 ]; then
    MAX_S=$(( OS_MAX_SAMPLE_DURATION / INTERVAL ))
    [ "$MAX_S" -lt 1 ] && MAX_S=1
    [ "$SAMPLES" -gt "$MAX_S" ] && SAMPLES="$MAX_S"
fi

SSH_OPTS="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

# --- Verifica comandi e raccolta dati per OS ----------------------------------

TS_NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

case "$OS_TYPE" in

    # =========================================================================
    aix)
    # =========================================================================

    # Verifica svmon
    if [ "$(os_check_cmd "$HOST" "svmon")" = "missing" ]; then
        build_error_json "$TOOL" "$ENV" "$HOST" "null" \
            "command_not_available" "svmon non trovato sul target $HOST (richiede bos.perf.tools)" \
            "{\"command\":\"svmon\",\"os\":\"aix\"}"
        exit 1
    fi

    # Raccolta in un unico SSH call per campione:
    #   svmon -G               → RAM in pagine (default 4KB/page)
    #   lsps -s                → swap used% (una riga con total e used%)
    #   vmstat 1 1             → page in/out (colonne pi/po)
    CMD_SAMPLE="svmon -G 2>/dev/null; echo __LSPS__; lsps -s 2>/dev/null; echo __VMSTAT__; vmstat 1 1 2>/dev/null"

    RAW_SAMPLES=$(os_sample "$HOST" "$SAMPLES" "$INTERVAL" \
        "$CMD_SAMPLE" "$CMD_SAMPLE") || {
        build_error_json "$TOOL" "$ENV" "$HOST" "null" \
            "connection_failed" "Campionamento memoria fallito su $HOST" \
            "{\"detail\":\"os_sample ha restituito errore\"}"
        exit 1
    }

    JSON=$(printf '%s' "$RAW_SAMPLES" | awk \
        -v os_type="$OS_TYPE" -v ts_base="$TS_NOW" '
BEGIN {
    section = "svmon"
    sample_idx = 0
    svmon_page_kb = 4   # default 4KB page; sovrascritta se "s 4 KB" rilevato
    split("", ram_total); split("", ram_used); split("", ram_free)
    split("", swp_total); split("", swp_used)
    split("", pg_in);     split("", pg_out)

    # vmstat column indices
    col_pi = -1; col_po = -1
    vmstat_hdr_seen = 0
}

# Separatore inter-campione
$0 == "\001" {
    section = "svmon"
    vmstat_hdr_seen = 0
    col_pi = -1; col_po = -1
    next
}

/^__LSPS__$/ { section = "lsps"; next }
/^__VMSTAT__$/ { section = "vmstat"; next }

section == "svmon" {
    # svmon -G: valori in pagine (tipicamente 4KB = 4096 bytes)
    # Riga "memory": size inuse free pin virtual mmode
    # Riga "pg space": size inuse (pagespace = swap)
    # Riga "PageSize": s 4 KB - ... → usata per rilevare la page size (default 4096)
    if ($1 == "PageSize" || ($1 == "s" && $2 ~ /^[0-9]/ && $3 == "KB")) {
        svmon_page_kb = $2 + 0
        if (svmon_page_kb < 1) svmon_page_kb = 4
        next
    }
    if ($1 == "memory") {
        # Colonne: size inuse free pin virtual mmode
        if (NF >= 3) {
            page_bytes = (svmon_page_kb > 0 ? svmon_page_kb : 4) * 1024
            inuse = ($2 + 0) * page_bytes; free_r = ($3 + 0) * page_bytes
            sample_idx++
            ram_total[sample_idx] = inuse + free_r
            ram_used[sample_idx]  = inuse
            ram_free[sample_idx]  = free_r
        }
    }
    # pg space line: swap
    if ($1 == "pg" && $2 == "space") {
        # Colonne: "pg space" size inuse
        if (NF >= 3) {
            page_bytes = (svmon_page_kb > 0 ? svmon_page_kb : 4) * 1024
            swp_total_p = ($3 + 0) * page_bytes
            swp_used_p  = ($4 + 0) * page_bytes
            if (sample_idx > 0 && swp_total[sample_idx] == 0) {
                swp_total[sample_idx] = swp_total_p
                swp_used[sample_idx]  = swp_used_p
            }
        }
    }
    next
}

section == "lsps" {
    # lsps -s output: "Total Paging Space  Percent Used"
    #                 "4096MB               5%"
    # Usiamo solo la % per derivare usato se non già noto da svmon pgspace
    # (backup in caso svmon pgspace non sia presente)
    if ($0 ~ /^[0-9]/) {
        # prima colonna = size (es. "4096MB"), seconda = percent (es. "5%")
        # Se swp_total non ancora impostato per questo campione: stima da %
        if (sample_idx > 0 && swp_total[sample_idx] == 0) {
            size_str = $1; pct_str = $2
            sub(/MB/, "", size_str); sub(/%/, "", pct_str)
            total_bytes = size_str * 1024 * 1024
            used_bytes  = int(total_bytes * pct_str / 100)
            swp_total[sample_idx] = total_bytes
            swp_used[sample_idx]  = used_bytes
        }
    }
    next
}

section == "vmstat" {
    # header vmstat AIX: "kthr ... cpu" / "r b ... us sy id wa"
    if (/us/ && /sy/ && /id/) {
        vmstat_hdr_seen = 1
        for (i = 1; i <= NF; i++) {
            if ($i == "pi") col_pi = i
            if ($i == "po") col_po = i
        }
        next
    }
    if (vmstat_hdr_seen && /^[[:space:]]*[0-9]/) {
        pi = (col_pi > 0 ? ($col_pi + 0) : 0)
        po = (col_po > 0 ? ($col_po + 0) : 0)
        if (sample_idx > 0) {
            pg_in[sample_idx]  = pi
            pg_out[sample_idx] = po
        }
    }
    next
}

END {
    n = sample_idx
    samples_json = "["
    for (i = 1; i <= n; i++) {
        if (i > 1) samples_json = samples_json ","
        entry = "{\"ts\":\"" ts_base "\",\"ram_total_bytes\":" ram_total[i] ",\"ram_used_bytes\":" ram_used[i] ",\"ram_free_bytes\":" ram_free[i] ",\"swap_total_bytes\":" swp_total[i] ",\"swap_used_bytes\":" swp_used[i] ",\"page_in_per_sec\":" pg_in[i] ",\"page_out_per_sec\":" pg_out[i] "}"
        samples_json = samples_json entry
    }
    samples_json = samples_json "]"

    if (n > 0) {
        printf "{\"os_type\":\"%s\",\"samples\":%s,\"summary\":{", os_type, samples_json
        printf "\"ram_used_bytes\":%s,",   stats_json(ram_used, n)
        printf "\"swap_used_bytes\":%s,",  stats_json(swp_used, n)
        printf "\"page_in_per_sec\":%s,",  stats_json(pg_in, n)
        printf "\"page_out_per_sec\":%s",  stats_json(pg_out, n)
        printf "}}"
    } else {
        printf "{\"os_type\":\"%s\",\"samples\":[],\"summary\":{}}", os_type
    }
}

function stats_json(arr, n,    sorted, i, j, tmp, sum, mn, mx, avg, p95, p99) {
    for (i = 1; i <= n; i++) sorted[i] = arr[i] + 0
    for (i = 1; i < n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[j] < sorted[i]) { tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp }
    sum = 0; mn = sorted[1]; mx = sorted[n]
    for (i = 1; i <= n; i++) sum += sorted[i]
    avg = sum / n
    p95 = percentile(sorted, n, 0.95)
    p99 = percentile(sorted, n, 0.99)
    return sprintf("{\"min\":%.0f,\"max\":%.0f,\"avg\":%.0f,\"p95\":%.0f,\"p99\":%.0f}",
        mn, mx, avg, p95, p99)
}
function percentile(arr, n, p,    idx, frac, lo, hi) {
    if (n == 1) return arr[1]
    idx = p * (n - 1) + 1; lo = int(idx); frac = idx - lo; hi = lo + 1
    if (hi > n) hi = n
    return arr[lo] + frac * (arr[hi] - arr[lo])
}
')
    ;;

    # =========================================================================
    linux)
    # =========================================================================

    # free -b restituisce RAM e swap in bytes, vmstat per page activity
    CMD_SAMPLE="free -b 2>/dev/null; echo __VMSTAT__; vmstat -n 1 1 2>/dev/null"

    RAW_SAMPLES=$(os_sample "$HOST" "$SAMPLES" "$INTERVAL" \
        "$CMD_SAMPLE" "$CMD_SAMPLE") || {
        build_error_json "$TOOL" "$ENV" "$HOST" "null" \
            "connection_failed" "Campionamento memoria fallito su $HOST" \
            "{\"detail\":\"os_sample ha restituito errore\"}"
        exit 1
    }

    JSON=$(printf '%s' "$RAW_SAMPLES" | awk \
        -v os_type="$OS_TYPE" -v ts_base="$TS_NOW" '
BEGIN {
    section = "free"
    sample_idx = 0
    split("", ram_total); split("", ram_used); split("", ram_free)
    split("", swp_total); split("", swp_used)
    split("", pg_in);     split("", pg_out)
    col_si = -1; col_so = -1
    vmstat_hdr_seen = 0
}

$0 == "\001" { section = "free"; vmstat_hdr_seen = 0; col_si = -1; col_so = -1; next }
/^__VMSTAT__$/ { section = "vmstat"; next }

section == "free" {
    # Riga "Mem:   total used free shared buff/cache available"
    if ($1 == "Mem:") {
        sample_idx++
        ram_total[sample_idx] = $2 + 0
        ram_used[sample_idx]  = $3 + 0
        ram_free[sample_idx]  = $4 + 0
    }
    # Riga "Swap:  total used free"
    if ($1 == "Swap:") {
        swp_total[sample_idx] = $2 + 0
        swp_used[sample_idx]  = $3 + 0
    }
    next
}

section == "vmstat" {
    # header: "procs ... io ... swap ... cpu"
    # sotto-header: "r b ... si so ..."
    if (/si/ && /so/) {
        vmstat_hdr_seen = 1
        for (i = 1; i <= NF; i++) {
            if ($i == "si") col_si = i
            if ($i == "so") col_so = i
        }
        next
    }
    if (vmstat_hdr_seen && /^[[:space:]]*[0-9]/) {
        si = (col_si > 0 ? ($col_si + 0) : 0)
        so = (col_so > 0 ? ($col_so + 0) : 0)
        if (sample_idx > 0) {
            pg_in[sample_idx]  = si
            pg_out[sample_idx] = so
        }
    }
    next
}

END {
    n = sample_idx
    samples_json = "["
    for (i = 1; i <= n; i++) {
        if (i > 1) samples_json = samples_json ","
        entry = "{\"ts\":\"" ts_base "\",\"ram_total_bytes\":" ram_total[i] ",\"ram_used_bytes\":" ram_used[i] ",\"ram_free_bytes\":" ram_free[i] ",\"swap_total_bytes\":" swp_total[i] ",\"swap_used_bytes\":" swp_used[i] ",\"page_in_per_sec\":" pg_in[i] ",\"page_out_per_sec\":" pg_out[i] "}"
        samples_json = samples_json entry
    }
    samples_json = samples_json "]"

    if (n > 0) {
        printf "{\"os_type\":\"%s\",\"samples\":%s,\"summary\":{", os_type, samples_json
        printf "\"ram_used_bytes\":%s,",   stats_json(ram_used, n)
        printf "\"swap_used_bytes\":%s,",  stats_json(swp_used, n)
        printf "\"page_in_per_sec\":%s,",  stats_json(pg_in, n)
        printf "\"page_out_per_sec\":%s",  stats_json(pg_out, n)
        printf "}}"
    } else {
        printf "{\"os_type\":\"%s\",\"samples\":[],\"summary\":{}}", os_type
    }
}

function stats_json(arr, n,    sorted, i, j, tmp, sum, mn, mx, avg, p95, p99) {
    for (i = 1; i <= n; i++) sorted[i] = arr[i] + 0
    for (i = 1; i < n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[j] < sorted[i]) { tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp }
    sum = 0; mn = sorted[1]; mx = sorted[n]
    for (i = 1; i <= n; i++) sum += sorted[i]
    avg = sum / n
    p95 = percentile(sorted, n, 0.95)
    p99 = percentile(sorted, n, 0.99)
    return sprintf("{\"min\":%.0f,\"max\":%.0f,\"avg\":%.0f,\"p95\":%.0f,\"p99\":%.0f}",
        mn, mx, avg, p95, p99)
}
function percentile(arr, n, p,    idx, frac, lo, hi) {
    if (n == 1) return arr[1]
    idx = p * (n - 1) + 1; lo = int(idx); frac = idx - lo; hi = lo + 1
    if (hi > n) hi = n
    return arr[lo] + frac * (arr[hi] - arr[lo])
}
')
    ;;

esac

build_envelope "$TOOL" "$ENV" "$HOST" "null" "null" "ok" "[$JSON]" "null"
exit 0
