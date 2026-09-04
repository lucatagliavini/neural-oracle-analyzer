#!/usr/bin/env bash
# tools/list_known_instances.sh — elenca le istanze Oracle note dal mount NFS per un host
#
# Uso: list_known_instances.sh ENVIRONMENT HOSTNAME
#
# Output JSON:
#   data: array di oggetti {instance_name, volume, alert_log_path}
#   Ogni elemento corrisponde a una directory istanza trovata nel mount NFS.
#   Le istanze duplicate (presenti sotto più volumi) sono deuplicate per nome:
#   viene mantenuta quella con l'alert log più recente (stessa logica di find_alert_log).
#   volume: nome del volume/filesystem NFS (es. "np41cdb0")
#   alert_log_path: path completo dell'alert log trovato, o null se assente
#
# Note:
#   - Non esegue connessioni SSH né sqlplus: legge solo il filesystem NFS locale.
#   - Se il mount NFS per l'host non è raggiungibile: restituisce log_not_found.
#   - Utile anche quando l'host Oracle è down (SSH non disponibile).

set -uo pipefail

TOOL="list_known_instances"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"

# Validazione argomenti
if ! validate_environment "$ENV"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '${ENV}'. Valori accettati: EURO, TEST, CERT, INTE, COLL, PROD" \
        "{\"received\":\"${ENV}\"}"
    exit 2
fi

if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "invalid_argument" \
        "HOSTNAME obbligatorio" \
        "{\"param\":\"hostname\"}"
    exit 2
fi

TIER=$(get_prod_noprod "$ENV")
NFS_HOST_BASE="/unipol/logs/database/oracle/${TIER}/${HOST}"

if [ ! -d "$NFS_HOST_BASE" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "log_not_found" \
        "Path NFS non esistente o non raggiungibile: ${NFS_HOST_BASE}" \
        "{\"path\":\"${NFS_HOST_BASE}\"}"
    exit 1
fi

# BUG-06: aggiunto campo resident (bool).
# resident=true  → il volume NFS contiene un alert log reale per questa istanza.
#                  Indica che l'istanza è fisica su questo host (o almeno il suo log è qui).
# resident=false → la directory istanza esiste nel mount NFS ma il log è assente:
#                  l'istanza è visibile via NFS (struttura RAC/symlink) ma non risiede qui.
# Zero SSH: la verifica usa solo test -f sul mount NFS locale.

TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

DATA=$(find "$NFS_HOST_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | sort \
    | awk -F'/' -v base="$NFS_HOST_BASE" '
{
    volume   = $(NF-1)
    inst     = $NF
    logfile  = base "/" volume "/" inst "/trace/alert_" inst ".log"
    # Tiene traccia delle coppie (inst -> volume,logfile)
    # In caso di duplicato, preferisce quello già noto
    if (!(inst in seen)) {
        seen[inst]    = 1
        volumes[inst] = volume
        logs[inst]    = logfile
        order[++n]    = inst
    }
}
END {
    printf "["
    for (i = 1; i <= n; i++) {
        inst = order[i]
        lf   = logs[inst]
        printf "%s{\"instance_name\":\"%s\",\"volume\":\"%s\",\"alert_log_path\":\"%s\",\"log_exists\":\"CHECK\"}",
            (i > 1 ? "," : ""), inst, volumes[inst], lf
    }
    printf "]"
}
')

# Sostituisce "log_exists":"CHECK" con resident:true/false controllando il filesystem
# Awk inline non può fare test -f → post-processing in bash con jq + loop
if command -v jq >/dev/null 2>&1; then
    DATA=$(printf '%s\n' "$DATA" | jq -c \
        '[.[] | . + {"resident": (if .alert_log_path != "" then true else false end)} | del(.log_exists)]' \
        2>/dev/null) || true
    # Verifica effettiva esistenza file per ogni record
    DATA_NEW="["
    first_item=1
    while IFS= read -r row; do
        lf=$(printf '%s' "$row" | jq -r '.alert_log_path // ""')
        if [ -f "$lf" ]; then
            resident="true"
        else
            resident="false"
        fi
        row=$(printf '%s' "$row" | jq -c --argjson r "$resident" '. + {resident: $r}')
        [ "$first_item" = "1" ] && DATA_NEW="${DATA_NEW}${row}" || DATA_NEW="${DATA_NEW},${row}"
        first_item=0
    done < <(printf '%s\n' "$DATA" | jq -c '.[]' 2>/dev/null)
    DATA_NEW="${DATA_NEW}]"
    DATA="$DATA_NEW"
fi

printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":null,"oracle_version":"n/a","status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$HOST" "$DATA"
exit 0
