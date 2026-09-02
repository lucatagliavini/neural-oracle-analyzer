#!/usr/bin/env bash
# tools/list_pdbs.sh — lista i Pluggable Database (PDB) di un CDB Oracle
#
# Uso: list_pdbs.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {con_id, con_name, open_mode, restricted}
#   Degrada con unsupported_version su Oracle 11g (feature multitenant non disponibile).
#
# Note tecniche:
#   - Usa "show pdbs" (comando sqlplus) invece di una query SQL: non supporta
#     WHENEVER SQLERROR EXIT 1, ma funziona con SET MARKUP CSV ON.
#   - La versione viene recuperata prima con una query separata per poter
#     restituire unsupported_version con la versione nota nell'envelope.

set -uo pipefail
# Nota: set -e non usato — la gestione degli errori avviene esplicitamente.

TOOL="list_pdbs"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

# 1. Valida argomenti standard
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# 2. Recupera versione Oracle e lista PDB in un'unica connessione SSH.
#    Struttura: versione → ORAMARKER → show pdbs output
#    "show pdbs" non supporta WHENEVER SQLERROR EXIT 1 (è un comando sqlplus, non SQL).
sql_block=$(printf \
'SET MARKUP CSV ON
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
select version from v$instance;
PROMPT ORAMARKER

SET HEADING ON
show pdbs
EXIT
')

stderr_tmp=$(mktemp)
raw_output=$(run_sqlplus_raw "$HOST" "$INST" "$sql_block" 2>"$stderr_tmp")
rc=$?
err_detail=$(cat "$stderr_tmp")
rm -f "$stderr_tmp"

if [ $rc -ne 0 ]; then
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
    esac
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" "$err_code" "$err_msg" "$err_ctx"
    exit 1
fi

# 3. Estrai versione (prima riga non vuota)
version=$(printf '%s\n' "$raw_output" | grep -v '^[[:space:]]*$' | head -1 | tr -d '"' | tr -d ' ')
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]'; then
    version="null"
fi

# 4. Verifica versione: show pdbs richiede Oracle 12c+
major=$(printf '%s' "$version" | cut -d. -f1)
if [ -n "$major" ] && [ "$major" != "null" ] && [ "$major" -lt 12 ] 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "unsupported_version" \
        "Multitenant (show pdbs) non disponibile su Oracle ${version}: richiede 12c+" \
        "{\"required\":\"12c+\",\"actual\":\"${version}\"}" \
        "$version"
    exit 1
fi

# 5. Estrai dati PDB (righe dopo ORAMARKER)
data=$(printf '%s\n' "$raw_output" \
    | awk '/^ORAMARKER$/{found=1; next} found{print}' \
    | grep -v '^[[:space:]]*$' \
    | _csv_to_json_array)

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "$version" "ok" "$data" "null"
