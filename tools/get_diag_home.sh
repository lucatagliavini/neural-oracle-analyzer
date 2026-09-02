#!/usr/bin/env bash
# tools/get_diag_home.sh — recupera il diagnostic_dest dell'istanza Oracle
#
# Uso: get_diag_home.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array con un oggetto {name, type, value}
#   Il campo "value" contiene il path base della ADR (es. /product/oracle).
#   Il path completo dell'alert log è:
#     <value>/diag/rdbms/<db_lowercase>/<INSTANCE_NAME>/trace/alert_<INSTANCE_NAME>.log
#
# Questo tool è prerequisito per i tool di log analysis: fornisce il diagnostic_dest
# che permette di costruire il path dell'alert log in modo preciso invece di usare find.

set -uo pipefail
# Nota: set -e non usato — run_tool gestisce i propri errori e restituisce
# exit code significativo che deve essere propagato esplicitamente.

TOOL="get_diag_home"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

QUERY="select name, type, value from v\$parameter where name = 'diagnostic_dest'"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
