#!/usr/bin/env bash
# tools/pga_sga_by_pdb.sh — utilizzo PGA e SGA per PDB tramite Resource Manager
#
# Uso: pga_sga_by_pdb.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti {con_id, pdb_name, pga_bytes_used, sga_bytes}
#   Fonte: join v$rsrcpdbmetric + cdb_pdbs.
#   Richiede Oracle 12c+ (viste multitenant non disponibili su 11g).
#   Richiede che il Resource Manager PDB plan sia attivo — se non attivo,
#   v$rsrcpdbmetric restituisce zero righe: status=ok, data=[].
#
# Note tecniche:
#   - v$rsrcpdbmetric non esiste su Oracle 11g → unsupported_version
#   - Se Resource Manager non è attivo → data=[] (esito valido, non un errore)

set -uo pipefail

TOOL="pga_sga_by_pdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# Unica connessione SSH: versione + dati
sql_block=$(printf \
'SET MARKUP CSV ON
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
select version from v$instance;
PROMPT ORAMARKER

SET HEADING ON
SELECT r.con_id, p.pdb_name, r.pga_bytes, r.sga_bytes,
       r.buffer_cache_bytes, r.shared_pool_bytes, r.plan_name
FROM v$rsrcpdbmetric r
JOIN cdb_pdbs p ON p.con_id = r.con_id
ORDER BY r.pga_bytes DESC;
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

# Estrai versione
version=$(printf '%s\n' "$raw_output" | grep -v '^[[:space:]]*$' | head -1 | tr -d '"' | tr -d ' ')
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]'; then
    version="null"
fi

# Verifica versione: viste multitenant richiedono Oracle 12c+
major=$(printf '%s' "$version" | cut -d. -f1)
if [ -n "$major" ] && [ "$major" != "null" ] && [ "$major" -lt 12 ] 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "unsupported_version" \
        "v\$rsrcpdbmetric/cdb_pdbs non disponibili su Oracle ${version}: richiede 12c+" \
        "{\"required\":\"12c+\",\"actual\":\"${version}\"}" \
        "$version"
    exit 1
fi

# Estrai dati (righe dopo ORAMARKER)
data=$(printf '%s\n' "$raw_output" \
    | awk '/^ORAMARKER$/{found=1; next} found{print}' \
    | grep -v '^[[:space:]]*$' \
    | _csv_to_json_array)

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "$version" "ok" "$data" "null"
