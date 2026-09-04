#!/usr/bin/env bash
# tools/os_cpu_stats.sh — metriche CPU e run queue dal server OS via SSH
#
# Uso: os_cpu_stats.sh ENVIRONMENT HOSTNAME [--samples=N] [--interval=S]
#
# Argomenti posizionali:
#   ENVIRONMENT  — enum: EURO, TEST, CERT, INTE, COLL, PROD
#   HOSTNAME     — hostname fisico del server Oracle
#
# Parametri opzionali:
#   --samples=N   — numero di campioni (default: 5)
#   --interval=S  — secondi tra campioni (default: 2)
#                   Se samples × interval > OS_MAX_SAMPLE_DURATION, samples viene ridotto.
#
# Output JSON:
#   data: {
#     os_type: "aix" | "linux",
#     cpu_count: N,
#     samples: [ {ts, cpu_user_pct, cpu_sys_pct, cpu_idle_pct, cpu_wait_pct, run_queue} ],
#     summary: { cpu_user_pct: {min,max,avg,p95,p99}, ... (stesse metriche) }
#   }
#   instance_name: null  (tool OS-level, non conosce le istanze Oracle)
#   oracle_version: null
#
# Comandi usati sul target:
#   AIX:   vmstat 1 1       → colonne: kthr(r,b,...) memory(...) page(...) ... cpu(us,sy,id,wa)
#   Linux: vmstat -n 1 1    → colonne: procs(r,b) ... cpu(us,sy,id,wa)
#   CPU count:
#     AIX:   bindprocessor -q 2>/dev/null | tr ' ' '\n' | grep -c '^[0-9]'
#     Linux: nproc
#
# Nota: il parsing gira sull'host MCP (ppc64le RHEL) — awk POSIX per coerenza.

set -uo pipefail
# Nota: set -e non usato — exit code gestito esplicitamente.

TOOL="os_cpu_stats"
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

# 1. ENVIRONMENT
if ! validate_environment "$ENV" 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '$ENV'. Valori ammessi: EURO TEST CERT INTE COLL PROD" \
        "{\"received\":\"$ENV\"}"
    exit 2
fi

# 2. HOSTNAME
if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "" "null" \
        "invalid_argument" "HOSTNAME obbligatorio" '{"param":"hostname"}'
    exit 2
fi
# R-10: validazione formato hostname
if ! validate_hostname "$HOST"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" \
        "HOSTNAME non valido: deve contenere solo lettere minuscole, cifre e trattini" \
        "{\"param\":\"hostname\",\"received\":\"$HOST\"}"
    exit 2
fi

# 3. --samples e --interval devono essere interi positivi
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

# --- Verifica disponibilità vmstat --------------------------------------------

VMSTAT_STATUS=$(os_check_cmd "$HOST" "vmstat")
if [ "$VMSTAT_STATUS" = "missing" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "command_not_available" "vmstat non trovato sul target $HOST" \
        "{\"command\":\"vmstat\",\"os\":\"$OS_TYPE\"}"
    exit 1
fi

# --- Raccolta CPU count + campioni --------------------------------------------

SSH_OPTS="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

# Comando per cpu_count
case "$OS_TYPE" in
    aix)
        CMD_CPU_COUNT="bindprocessor -q 2>/dev/null | tr ' ' '\n' | grep -c '^[0-9]'"
        CMD_VMSTAT="vmstat 1 1"
        ;;
    linux)
        CMD_CPU_COUNT="nproc"
        CMD_VMSTAT="vmstat -n 1 1"
        ;;
esac

# Recupera cpu_count con lo stesso SSH call del primo campione
CPU_COUNT_RAW=$(ssh $SSH_OPTS "${ORACLE_SSH_USER}@${HOST}" "$CMD_CPU_COUNT" 2>/dev/null) || true
CPU_COUNT=$(printf '%s' "$CPU_COUNT_RAW" | tr -d ' \n')
if ! printf '%s' "$CPU_COUNT" | grep -qE '^[0-9]+$'; then
    CPU_COUNT=0
fi

# --- Campionamento vmstat -----------------------------------------------------

# Clamping samples × interval <= OS_MAX_SAMPLE_DURATION (già fatto in os_sample,
# ma ripetiamo qui per poter comunicare il valore effettivo nell'output)
if [ "$INTERVAL" -gt 0 ]; then
    MAX_S=$(( OS_MAX_SAMPLE_DURATION / INTERVAL ))
    [ "$MAX_S" -lt 1 ] && MAX_S=1
    [ "$SAMPLES" -gt "$MAX_S" ] && SAMPLES="$MAX_S"
fi

RAW_SAMPLES=$(os_sample "$HOST" "$SAMPLES" "$INTERVAL" "$CMD_VMSTAT" "$CMD_VMSTAT") || {
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "connection_failed" "Campionamento vmstat fallito su $HOST" \
        "{\"detail\":\"os_sample ha restituito errore\"}"
    exit 1
}

# --- Parsing e aggregazione in awk -------------------------------------------

TS_NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

JSON=$(printf '%s' "$RAW_SAMPLES" | awk -v os_type="$OS_TYPE" -v ts_base="$TS_NOW" \
    -v cpu_count="$CPU_COUNT" '
BEGIN {
    sample_idx = 0
    sep = "\001"

    # Indici delle colonne (0-based, impostati al parsing header)
    col_us = -1; col_sy = -1; col_id = -1; col_wa = -1; col_rq = -1

    # Array metriche
    split("", us); split("", sy); split("", id_); split("", wa); split("", rq)
}

# Separatore inter-campione: reset header parser per il prossimo campione
$0 == sep || $0 == "\001" {
    col_us = -1
    next
}

# Riga header vmstat (contiene "us" o "id")
/us/ && /sy/ {
    # Mappa le colonne cercando i nomi tipici di vmstat
    for (i = 1; i <= NF; i++) {
        f = $i
        if (f == "us") col_us = i
        else if (f == "sy") col_sy = i
        else if (f == "id") col_id = i
        else if (f == "wa") col_wa = i
        else if (f == "r")  col_rq = i
    }
    next
}

# Riga dati vmstat: skip righe di soli trattini o righe non numeriche in pos 1
/^[[:space:]]*[0-9]/ {
    if (col_us < 0) next   # header non ancora trovato per questo campione

    sample_idx++
    us[sample_idx]  = ($col_us  + 0)
    sy[sample_idx]  = ($col_sy  + 0)
    id_[sample_idx] = ($col_id  + 0)
    wa[sample_idx]  = ($col_wa  + 0)
    rq[sample_idx]  = (col_rq > 0 ? ($col_rq + 0) : 0)
}

END {
    n = sample_idx

    # Costruzione array samples
    samples_json = "["
    for (i = 1; i <= n; i++) {
        if (i > 1) samples_json = samples_json ","
        entry = "{\"ts\":\"" ts_base "\",\"cpu_user_pct\":" us[i] ",\"cpu_sys_pct\":" sy[i] ",\"cpu_idle_pct\":" id_[i] ",\"cpu_wait_pct\":" wa[i] ",\"run_queue\":" rq[i] "}"
        samples_json = samples_json entry
    }
    samples_json = samples_json "]"

    # Statistiche aggregate
    if (n > 0) {
        printf "{\"os_type\":\"%s\",\"cpu_count\":%s,\"samples\":%s,\"summary\":{", \
            os_type, cpu_count, samples_json
        printf "\"cpu_user_pct\":%s,", stats_json(us, n)
        printf "\"cpu_sys_pct\":%s,",  stats_json(sy, n)
        printf "\"cpu_idle_pct\":%s,", stats_json(id_, n)
        printf "\"cpu_wait_pct\":%s,", stats_json(wa, n)
        printf "\"run_queue\":%s",     stats_json(rq, n)
        printf "}}"
    } else {
        printf "{\"os_type\":\"%s\",\"cpu_count\":%s,\"samples\":[],\"summary\":{}}", \
            os_type, cpu_count
    }
}

# Calcola min/max/avg/p95/p99 e restituisce oggetto JSON
function stats_json(arr, n,    sorted, i, j, tmp, sum, mn, mx, avg, p95, p99) {
    # Copia in array da ordinare
    for (i = 1; i <= n; i++) sorted[i] = arr[i]

    # Bubble sort (n <= 30, trascurabile)
    for (i = 1; i < n; i++) {
        for (j = i+1; j <= n; j++) {
            if (sorted[j] < sorted[i]) {
                tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp
            }
        }
    }

    sum = 0; mn = sorted[1]; mx = sorted[n]
    for (i = 1; i <= n; i++) sum += sorted[i]
    avg = sum / n

    # Percentili: interpolazione lineare
    p95 = percentile(sorted, n, 0.95)
    p99 = percentile(sorted, n, 0.99)

    return sprintf("{\"min\":%.2f,\"max\":%.2f,\"avg\":%.2f,\"p95\":%.2f,\"p99\":%.2f}",
        mn, mx, avg, p95, p99)
}

function percentile(arr, n, p,    idx, frac, lo, hi) {
    if (n == 1) return arr[1]
    idx  = p * (n - 1) + 1
    lo   = int(idx)
    frac = idx - lo
    hi   = lo + 1
    if (hi > n) hi = n
    return arr[lo] + frac * (arr[hi] - arr[lo])
}
')

build_envelope "$TOOL" "$ENV" "$HOST" "null" "null" "ok" "[$JSON]" "null"
exit 0
