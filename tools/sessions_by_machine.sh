#!/usr/bin/env bash
# tools/sessions_by_machine.sh — sessioni Oracle raggruppate per macchina client e stato
#
# Uso: sessions_by_machine.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {machine, status, session_count}
#   Ordinato per session_count decrescente.
#   Include tutte le sessioni (anche quelle di sistema senza username).
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).

set -uo pipefail

TOOL="sessions_by_machine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

QUERY="SELECT machine, status, count(*) AS session_count \
FROM v\$session \
GROUP BY machine, status \
ORDER BY session_count DESC"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
