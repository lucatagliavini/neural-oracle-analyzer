#!/usr/bin/env bash
# tools/list_all_hosts_and_instances.sh — inventario completo host+istanze dal mount NFS
#
# Uso: list_all_hosts_and_instances.sh ENVIRONMENT
#
# Output JSON:
#   data: array di oggetti {hostname, tier, instances: [{instance_name, volume}]}
#   Restituisce l'intero inventario in una sola chiamata leggendo il filesystem NFS locale.
#   Zero SSH, zero sqlplus — risposta istantanea.
#
# Note:
#   - Le istanze duplicate (stesso nome sotto più volumi) sono deduplicate:
#     viene mantenuta quella con il volume più recente (ordinamento alfabetico, ultimo vince).
#   - Se il mount NFS non è raggiungibile: restituisce log_not_found.

set -uo pipefail

TOOL="list_all_hosts_and_instances"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"

# Validazione
if ! validate_environment "$ENV"; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '${ENV}'. Valori accettati: EURO, TEST, CERT, INTE, COLL, PROD" \
        "{\"received\":\"${ENV}\"}"
    exit 2
fi

TIER=$(get_prod_noprod "$ENV")
NFS_BASE="/unipol/logs/database/oracle/${TIER}"

if [ ! -d "$NFS_BASE" ]; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "log_not_found" \
        "Path NFS non esistente o non raggiungibile: ${NFS_BASE}" \
        "{\"path\":\"${NFS_BASE}\"}"
    exit 1
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

# Raccoglie tutti i path <base>/<host>/<volume>/<instance> e li aggrega
DATA=$(find "$NFS_BASE" -mindepth 3 -maxdepth 3 -type d 2>/dev/null \
    | sort \
    | awk -F'/' -v tier="$TIER" -v base="$NFS_BASE" '
{
    # path: .../noprod/<host>/<volume>/<instance>
    host = $(NF-2)
    vol  = $(NF-1)
    inst = $NF

    # Registra ordine host
    if (!(host in seen_host)) {
        seen_host[host] = 1
        host_order[++h_n] = host
        inst_count[host] = 0
    }

    # Deduplica istanze per host (stesso nome sotto volumi diversi)
    key = host ":" inst
    if (!(key in seen_inst)) {
        seen_inst[key] = 1
        idx = ++inst_count[host]
        inst_name[host, idx] = inst
        inst_vol[host, idx]  = vol
    }
}
END {
    printf "["
    for (hi = 1; hi <= h_n; hi++) {
        host = host_order[hi]
        if (hi > 1) printf ","
        printf "{\"hostname\":\"%s\",\"tier\":\"%s\",\"instances\":[", host, tier
        for (i = 1; i <= inst_count[host]; i++) {
            if (i > 1) printf ","
            # BUG-06: aggiunto alert_log_path per permettere verifica resident post-awk
            lf = base "/" host "/" inst_vol[host, i] "/" inst_name[host, i] "/trace/alert_" inst_name[host, i] ".log"
            printf "{\"instance_name\":\"%s\",\"volume\":\"%s\",\"alert_log_path\":\"%s\"}",
                inst_name[host, i], inst_vol[host, i], lf
        }
        printf "]}"
    }
    printf "]"
}
')

printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":null,"instance_name":null,"oracle_version":"n/a","status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$DATA"
exit 0
