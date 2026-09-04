#!/usr/bin/env bash
# tools/tail_alert_log.sh — restituisce le ultime N righe dell'alert log Oracle
#
# Uso: tail_alert_log.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--lines=N]
#
# Output JSON:
#   data: array di oggetti {line_number, text}
#   line_number: numero di riga nel file originale (1-based dalla fine del file)
#   Default N = 2000 (come da runbook DBA).
#   Invocazione puntuale bounded — non streaming continuo.
#
# Note tecniche:
#   - Legge l'alert log dal mount NFS locale (lxprworkerlana01), senza connessione SSH.
#   - Usa find_alert_log() dalla libreria per trovare il path.
#   - Se path non trovato: restituisce log_not_found.
#   - oracle_version è null: questo tool non apre connessioni a Oracle.

set -uo pipefail
# Nota: set -e non usato — exit code gestito esplicitamente.

TOOL="tail_alert_log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/oracle_conn.sh
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

# --- Argomenti ----------------------------------------------------------------

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

LINES=2000
for arg in "${@:4}"; do
    case "$arg" in
        --lines=*)
            val="${arg#--lines=}"
            if ! echo "$val" | grep -qE '^[0-9]+$' || [ "$val" -eq 0 ]; then
                build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
                    "invalid_argument" "--lines deve essere un intero positivo" \
                    "{\"param\":\"lines\",\"received\":\"$val\"}"
                exit 2
            fi
            LINES="$val"
            ;;
    esac
done

# --- Validazioni --------------------------------------------------------------

# 1. Argomenti standard (ENVIRONMENT, HOSTNAME, INSTANCE_NAME)
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# --- Trova alert log ----------------------------------------------------------

LOG_PATH=$(find_alert_log "$HOST" "$INST" "$ENV")
if [ -z "$LOG_PATH" ]; then
    prod_noprod=$(get_prod_noprod "$ENV")
    attempted="${ORACLE_NFS_BASE}/${prod_noprod}/${HOST}/.../${INST}/trace/alert_${INST}.log"
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "log_not_found" \
        "Alert log non trovato sul mount NFS: ${attempted}" \
        "{\"path\":\"${attempted}\"}"
    exit 1
fi

# --- Costruzione data array ---------------------------------------------------

# Conta il totale righe per calcolare il line_number assoluto (partendo dalla fine)
total_lines=$(wc -l < "$LOG_PATH")
start_line=$(( total_lines - LINES + 1 ))
if [ "$start_line" -lt 1 ]; then
    start_line=1
fi

# tail + awk: emette array JSON [{line_number:N, text:"..."}]
# LC_ALL=C + lib/json_esc.awk gestiscono correttamente byte non-ASCII (Latin-1)
# che Oracle può scrivere nei log con messaggi localizzati in italiano/francese.
AWK_LIB="${SCRIPT_DIR}/../lib/json_esc.awk"
_awk_tmp=$(mktemp /tmp/tail_alert_XXXXXX.awk)
cat > "$_awk_tmp" << 'AWK'
BEGIN {
    print "["
    first = 1
}
{
    if (!first) printf ","
    first = 0
    printf "{\"line_number\":%d,\"text\":\"%s\"}\n", start + NR - 1, json_esc($0)
}
END {
    print "]"
}
AWK
data_json=$(tail -n "$LINES" "$LOG_PATH" | LC_ALL=C awk \
    -v start="$start_line" \
    -f "${AWK_LIB}" \
    -f "$_awk_tmp")
rm -f "$_awk_tmp"

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "n/a" "ok" "$data_json" "null"
