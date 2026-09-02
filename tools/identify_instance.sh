#!/usr/bin/env bash
# tools/identify_instance.sh — identifica un'istanza Oracle CDB
#
# Uso: identify_instance.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array con un oggetto contenente i campi di v$instance
#   (instance_name, host_name, version, status, database_status, instance_role, startup_time)
#
# Questo tool è il punto di partenza del runbook DBA: verifica che la connessione
# SYSDBA funzioni e restituisce le informazioni di base sull'istanza.

set -uo pipefail
# Nota: set -e non usato — run_tool gestisce i propri errori e restituisce
# exit code significativo che deve essere propagato esplicitamente.

TOOL="identify_instance"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

QUERY="select instance_name, host_name, version, status, \
database_status, instance_role, \
to_char(startup_time,'YYYY-MM-DD HH24:MI:SS') as startup_time \
from v\$instance"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
