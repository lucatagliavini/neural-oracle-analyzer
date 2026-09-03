#!/usr/bin/env bash
# tools/get_alert_log_info.sh — metadati dell'alert log Oracle dal mount NFS (senza leggerlo)
#
# Uso: get_alert_log_info.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array con un oggetto {path, size_bytes, last_modified, age_hours}
#   Restituisce metadati del file (stat) senza aprirlo — risposta istantanea.
#   Utile per verificare: "l'alert log è aggiornato? quanto è grande?"
#   prima di eseguire scan_alert_log (che è più lento).
#
# Note:
#   - Non esegue connessioni SSH né sqlplus: legge solo il filesystem NFS locale.
#   - Se il file non viene trovato: restituisce log_not_found.
#   - age_hours: ore trascorse dall'ultima modifica (arrotondato a 1 decimale).

set -uo pipefail

TOOL="get_alert_log_info"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# Trova il path dell'alert log (usa find_alert_log dalla libreria — gestisce duplicati)
LOG_PATH=$(find_alert_log "$HOST" "$INST" "$ENV")

if [ -z "$LOG_PATH" ]; then
    TIER=$(get_prod_noprod "$ENV")
    SEARCH_BASE="/unipol/logs/database/oracle/${TIER}/${HOST}"
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "log_not_found" \
        "Alert log non trovato per ${INST} su ${HOST}" \
        "{\"path\":\"${SEARCH_BASE}\"}"
    exit 1
fi

# Raccoglie metadati con stat
SIZE=$(stat --printf="%s" "$LOG_PATH" 2>/dev/null)
MTIME_EPOCH=$(stat --printf="%Y" "$LOG_PATH" 2>/dev/null)
MTIME_ISO=$(date -u -d "@${MTIME_EPOCH}" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null)
NOW_EPOCH=$(date -u +%s)
AGE_HOURS=$(awk "BEGIN{printf \"%.1f\", (${NOW_EPOCH} - ${MTIME_EPOCH}) / 3600}")

TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

DATA="[{\"path\":\"${LOG_PATH}\",\"size_bytes\":${SIZE},\"last_modified\":\"${MTIME_ISO}\",\"age_hours\":${AGE_HOURS}}]"

printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":"%s","oracle_version":null,"status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$HOST" "$INST" "$DATA"
exit 0
