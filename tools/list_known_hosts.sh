#!/usr/bin/env bash
# tools/list_known_hosts.sh — elenca gli host Oracle noti dal mount NFS locale
#
# Uso: list_known_hosts.sh ENVIRONMENT
#
# Output JSON:
#   data: array di oggetti {hostname, tier}
#   Ogni elemento corrisponde a una directory host sotto il mount NFS
#   /unipol/logs/database/oracle/<prod|noprod>/.
#   tier: "prod" o "noprod" in base al percorso.
#
# Note:
#   - Non esegue connessioni SSH né sqlplus: legge solo il filesystem NFS locale.
#   - Se il mount NFS non è raggiungibile: restituisce log_not_found.
#   - L'ENVIRONMENT determina quale tier mostrare:
#       PROD         → solo tier "prod"
#       tutti gli altri (TEST, EURO, CERT, INTE, COLL) → solo tier "noprod"
#   - Gli host sono ordinati alfabeticamente.

set -uo pipefail

TOOL="list_known_hosts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"

# Valida ENVIRONMENT (solo 1 argomento — validazione manuale senza validate_args)
if ! validate_environment "$ENV"; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '${ENV}'. Valori accettati: EURO, TEST, CERT, INTE, COLL, PROD" \
        "{\"received\":\"${ENV}\"}"
    exit 2
fi

TIER=$(get_prod_noprod "$ENV")
NFS_BASE="/unipol/logs/database/oracle/${TIER}"

# Verifica che il mount NFS esista
if [ ! -d "$NFS_BASE" ]; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "log_not_found" \
        "Path NFS non esistente o non raggiungibile: ${NFS_BASE}" \
        "{\"path\":\"${NFS_BASE}\"}"
    exit 1
fi

# Enumera le directory host (un livello sotto prod/noprod)
HOSTS=$(find "$NFS_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | xargs -I{} basename {})

if [ -z "$HOSTS" ]; then
    # Mount presente ma vuoto
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
    printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":null,"instance_name":null,"oracle_version":"n/a","status":"ok","data":[],"error":null}\n' \
        "$TOOL" "$TS" "$ENV"
    exit 0
fi

# Costruisce array JSON
DATA=$(echo "$HOSTS" | awk -v tier="$TIER" '
BEGIN { printf "[" }
NR > 1 { printf "," }
{ printf "{\"hostname\":\"%s\",\"tier\":\"%s\"}", $1, tier }
END { printf "]" }
')

TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":null,"instance_name":null,"oracle_version":"n/a","status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$DATA"
exit 0
