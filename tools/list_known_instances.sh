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
# R-10: validazione formato hostname
if ! validate_hostname "$HOST"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_argument" \
        "HOSTNAME non valido: deve contenere solo lettere minuscole, cifre e trattini" \
        "{\"param\":\"hostname\",\"received\":\"$HOST\"}"
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

# BUG-06 / R-02: campo resident (bool).
# resident=true  → l'alert log esiste ed è fisicamente sotto NFS_HOST_BASE
#                  (path reale con prefisso dell'host, non un symlink verso un altro host).
# resident=false → la directory istanza è visibile via NFS ma il log è assente o è un
#                  symlink che punta fuori dall'albero dell'host (struttura RAC).
#
# Il test usa `realpath -m` (o `readlink -f` come fallback) per risolvere i symlink:
# se il path reale ha come prefisso NFS_HOST_BASE, l'istanza è residente su questo host.
# Zero SSH: solo operazioni locali sul mount NFS.

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

# Sostituisce "log_exists":"CHECK" con resident:true/false controllando il filesystem.
# R-02: resident usa realpath per rilevare symlink verso altri host (struttura RAC).
# Un log che esiste ma è un symlink che punta fuori da NFS_HOST_BASE → resident=false.
# Preferisce realpath; fallback a readlink -f se realpath non è disponibile.
if command -v jq >/dev/null 2>&1; then
    DATA=$(printf '%s\n' "$DATA" | jq -c '[.[] | del(.log_exists)]' 2>/dev/null) || true
    DATA_NEW="["
    first_item=1
    while IFS= read -r row; do
        lf=$(printf '%s' "$row" | jq -r '.alert_log_path // ""')
        resident="false"
        if [ -f "$lf" ]; then
            # Risolve il path reale (segue symlink)
            if command -v realpath >/dev/null 2>&1; then
                real_lf=$(realpath -m "$lf" 2>/dev/null || printf '%s' "$lf")
            else
                real_lf=$(readlink -f "$lf" 2>/dev/null || printf '%s' "$lf")
            fi
            # resident=true solo se il path reale è ancora sotto NFS_HOST_BASE
            case "$real_lf" in
                "${NFS_HOST_BASE}/"*) resident="true" ;;
                *)                   resident="false" ;;
            esac
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
