#!/usr/bin/env bash
# tools/sessions_by_user.sh — sessioni Oracle raggruppate per utente e stato
#
# Uso: sessions_by_user.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {username, status, session_count, scope, total_user_sessions}
#   scope: sempre "user_sessions" — indica che sono escluse le sessioni senza username
#          (sessioni di background: DBWR, LGWR, PMON, ecc.)
#   total_user_sessions: totale sessioni utente (somma di tutti i session_count)
#   Ordinato per session_count decrescente.
#   Esclude le sessioni di sistema (username IS NOT NULL).
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).
#
# BUG-12: aggiunto scope e total_user_sessions per permettere riconciliazione
#   con sessions_by_machine (scope="all_sessions") e check_resource_limits.

set -uo pipefail

TOOL="sessions_by_user"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

# Aggiunge 'user_sessions' come colonna scope e il totale come total_user_sessions
# tramite subquery con COUNT(*) OVER() — funziona su 11g, 12c, 19c.
QUERY="SELECT username, status, session_count, \
'user_sessions' AS scope, \
total_user_sessions \
FROM ( \
  SELECT username, status, count(*) AS session_count, \
         SUM(count(*)) OVER () AS total_user_sessions \
  FROM v\$session \
  WHERE username IS NOT NULL \
  GROUP BY username, status \
) \
ORDER BY session_count DESC"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
