#!/usr/bin/env bash
# tools/check_resource_limits.sh — verifica i limiti di sessioni e processi Oracle
#
# Uso: check_resource_limits.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {resource_name, current_utilization, max_utilization, limit_value}
#   scope: "instance_limits" — indica che i dati provengono da v$resource_limit,
#          che conta tutte le sessioni/processi dell'istanza (incluse quelle di background
#          e ricorsive), non solo le sessioni utente.
#          Questo perimetro differisce da sessions_by_user (sole sessioni utente)
#          e sessions_by_machine (sessioni v$session con username NULL incluse).
#          R-15: campo scope aggiunto per rendere il perimetro dichiarato e riconciliabile.
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

# R-15: aggiungiamo scope come campo top-level dell'envelope.
# Usiamo run_sqlplus_query direttamente invece di run_tool per poter post-processare.
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

result=$(run_sqlplus_query "$HOST" "$INST" "$QUERY")
rc=$?

if [ $rc -ne 0 ]; then
    err_detail=$(printf '%s\n' "$result")
    err_code=$(classify_error "$err_detail")
    case "$err_code" in
        connection_failed)
            err_msg=$(printf '%s' "$err_detail" | sed 's/^connection_failed: //')
            err_ctx="{\"detail\":\"$(printf '%s' "$err_msg" | sed 's/"/\\"/g')\"}"
            ;;
        missing_env_file)
            err_msg=$(printf '%s' "$err_detail" | sed 's/^missing_env_file: //')
            err_ctx="{\"path\":\"~/${INST}.env\"}"
            ;;
        query_failed)
            err_msg=$(printf '%s' "$err_detail" | sed 's/^query_failed: //')
            err_ctx="{\"ora_error\":\"$(printf '%s' "$err_msg" | sed 's/"/\\"/g')\"}"
            ;;
        *) err_msg="$err_detail"; err_ctx="{}" ;;
    esac
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" "$err_code" "$err_msg" "$err_ctx"
    exit 1
fi

version=$(printf '%s\n' "$result" | head -1)
data=$(printf '%s\n' "$result" | tail -n +2)

_envelope_base=$(build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "$version" "ok" "$data" "null")
# R-15: aggiunge scope come campo top-level dell'envelope (non nei singoli record del data array).
# tr -d '\n' comprime l'output su una riga prima del sed per evitare di colpire i } interni.
printf '%s' "$_envelope_base" \
    | tr -d '\n' \
    | sed 's/}$/,"scope":"instance_limits"}/'
printf '\n'
exit 0
