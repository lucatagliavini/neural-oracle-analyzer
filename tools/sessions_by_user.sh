#!/usr/bin/env bash
# tools/sessions_by_user.sh — sessioni Oracle raggruppate per utente e stato
#
# Uso: sessions_by_user.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {username, status, session_count}
#   Ordinato per session_count decrescente.
#   Esclude le sessioni di sistema (username IS NOT NULL).
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).

set -uo pipefail

TOOL="sessions_by_user"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

QUERY="SELECT username, status, count(*) AS session_count \
FROM v\$session \
WHERE username IS NOT NULL \
GROUP BY username, status \
ORDER BY session_count DESC"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
