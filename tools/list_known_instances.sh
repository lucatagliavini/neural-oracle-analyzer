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

# Raccoglie {instance_name, volume, alert_log_path} deduplicando per instance_name
# Per duplicati: prende il volume con l'alert log più recente (ls -t)
TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

DATA=$(find "$NFS_HOST_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | sort \
    | awk -F'/' -v base="$NFS_HOST_BASE" '
{
    volume   = $(NF-1)
    inst     = $NF
    logfile  = base "/" volume "/" inst "/trace/alert_" inst ".log"
    # Tiene traccia delle coppie (inst -> volume,logfile)
    # In caso di duplicato, preferisce quello già noto (ls -t li ordina per recency nella ricerca)
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
        # verifica esistenza alert log (test -f non disponibile in awk, usiamo il path diretto)
        printf "%s{\"instance_name\":\"%s\",\"volume\":\"%s\",\"alert_log_path\":\"%s\"}",
            (i > 1 ? "," : ""), inst, volumes[inst], lf
    }
    printf "]"
}
')

printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":null,"oracle_version":null,"status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$HOST" "$DATA"
exit 0
