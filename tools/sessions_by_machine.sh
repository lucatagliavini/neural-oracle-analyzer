#!/usr/bin/env bash
# tools/sessions_by_machine.sh — sessioni Oracle raggruppate per macchina client e stato
#
# Uso: sessions_by_machine.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {machine, status, session_count, scope, total_all_sessions}
#   scope: sempre "all_sessions" — include TUTTE le sessioni, compresi i background
#          Oracle (DBWR, LGWR, PMON, ecc.) che hanno username=NULL.
#   total_all_sessions: totale complessivo di tutte le sessioni (incluse quelle NULL)
#   Ordinato per session_count decrescente.
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).
#
# BUG-12: aggiunto scope e total_all_sessions per permettere riconciliazione
#   con sessions_by_user (scope="user_sessions"). La differenza tra i due totali
#   è spiegata dalle sessioni di background Oracle senza username.

set -uo pipefail

TOOL="sessions_by_machine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

# Aggiunge 'all_sessions' come colonna scope e il totale come total_all_sessions.
# Include TUTTE le sessioni (anche quelle senza username = processi di background).
QUERY="SELECT machine, status, session_count, \
'all_sessions' AS scope, \
total_all_sessions \
FROM ( \
  SELECT machine, status, count(*) AS session_count, \
         SUM(count(*)) OVER () AS total_all_sessions \
  FROM v\$session \
  GROUP BY machine, status \
) \
ORDER BY session_count DESC"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
