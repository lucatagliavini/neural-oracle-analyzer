#!/usr/bin/env bash
# tools/top_pga_sessions.sh — top sessioni Oracle per utilizzo PGA
#
# Uso: top_pga_sessions.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--limit=N]
#
# Output JSON:
#   data: array di oggetti {pid, spid, username, status, machine,
#                           pga_used_mem, pga_alloc_mem, pga_freeable_mem, pga_max_mem}
#   Ordinato per pga_alloc_mem DESC. Default --limit=20.
#   Esclude le sessioni di sistema (username IS NOT NULL).
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c) — nessuna vista multitenant.
#   Valori PGA in bytes.

set -uo pipefail

TOOL="top_pga_sessions"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

LIMIT=20
# R-06: tetto massimo per evitare output da 230 KB con limit=999999.
MAX_LIMIT=500
for arg in "${@:4}"; do
    case "$arg" in
        --limit=*)
            val="${arg#--limit=}"
            if ! printf '%s' "$val" | grep -qE '^[0-9]+$' || [ "$val" -eq 0 ]; then
                build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
                    "invalid_argument" "--limit deve essere un intero positivo" \
                    "{\"param\":\"limit\",\"received\":\"$val\"}"
                exit 2
            fi
            if [ "$val" -gt "$MAX_LIMIT" ]; then
                build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
                    "invalid_argument" "--limit non può superare ${MAX_LIMIT}" \
                    "{\"param\":\"limit\",\"received\":\"$val\",\"max\":${MAX_LIMIT}}"
                exit 2
            fi
            LIMIT="$val"
            ;;
    esac
done

validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# Nota: ROWNUM viene assegnato prima di ORDER BY in Oracle.
# La subquery garantisce l'ordinamento corretto prima del limite.
QUERY="SELECT pid, spid, username, status, machine, \
pga_used_mem, pga_alloc_mem, pga_freeable_mem, pga_max_mem \
FROM ( \
  SELECT p.pid, p.spid, s.username, s.status, s.machine, \
         p.pga_used_mem, p.pga_alloc_mem, p.pga_freeable_mem, p.pga_max_mem \
  FROM v\$process p JOIN v\$session s ON p.addr = s.paddr \
  WHERE s.username IS NOT NULL \
  ORDER BY p.pga_alloc_mem DESC \
) WHERE ROWNUM <= ${LIMIT}"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
