#!/usr/bin/env bash
# tools/check_resource_limits.sh — verifica i limiti di sessioni e processi Oracle
#
# Uso: check_resource_limits.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {resource_name, current_utilization, max_utilization, limit_value}
#   Filtra solo le risorse "sessions" e "processes" (le più rilevanti per il runbook DBA).
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).

set -uo pipefail

TOOL="check_resource_limits"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

QUERY="SELECT resource_name, current_utilization, max_utilization, limit_value \
FROM v\$resource_limit \
WHERE resource_name IN ('sessions','processes') \
ORDER BY resource_name"

run_tool "$TOOL" "$ENV" "$HOST" "$INST" "$QUERY"
exit $?
