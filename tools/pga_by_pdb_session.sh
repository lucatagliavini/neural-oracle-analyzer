#!/usr/bin/env bash
# tools/pga_by_pdb_session.sh — utilizzo PGA per sessione, raggruppato per PDB
#
# Uso: pga_by_pdb_session.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--limit=N]
#
# Output JSON:
#   data: array di oggetti {con_id, pdb_name, username, status,
#                           pga_used_mem, pga_alloc_mem}
#   Ordinato per pga_alloc_mem DESC.
#   Esclude le sessioni di sistema (username IS NOT NULL).
#   Richiede Oracle 12c+ (cdb_pdbs non disponibile su 11g).
#
# Parametri opzionali:
#   --limit=N  — numero massimo di sessioni restituite (default: 50)
#               Coerente con top_pga_sessions (default 20) e tail_alert_log (default 100).
#               Riduce drasticamente il payload su istanze con molte sessioni attive.
#
# Note tecniche:
#   - cdb_pdbs non esiste su Oracle 11g → unsupported_version
#   - Usa ROWNUM nella subquery per limitare a sessioni utente rilevanti

set -uo pipefail

TOOL="pga_by_pdb_session"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"
LIMIT=50
MAX_LIMIT=500

for arg in "${@:4}"; do
    case "$arg" in
        --limit=*) LIMIT="${arg#--limit=}" ;;
    esac
done

if ! printf '%s' "$LIMIT" | grep -qE '^[0-9]+$' || [ "$LIMIT" -lt 1 ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "invalid_argument" "--limit deve essere un intero >= 1" '{"param":"limit"}'
    exit 2
fi
# R3-02: tetto massimo per prevenire payload fuori controllo (coerente con top_pga_sessions).
if [ "$LIMIT" -gt "$MAX_LIMIT" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "invalid_argument" "--limit non può superare ${MAX_LIMIT}" \
        "{\"param\":\"limit\",\"max\":${MAX_LIMIT},\"received\":${LIMIT}}"
    exit 2
fi

validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# Unica connessione SSH: versione + dati
# BUG-01: aggiunto ROWNUM <= N per limitare le righe restituite e ridurre il payload.
# Su istanze con 1000+ sessioni, senza limite l'output era >100 KB e saturava il context.
# R-01/R-14: la stringa SQL 'CDB$ROOT' non può stare dentro single-quoted printf perché
# il $ROOT verrebbe espanso da bash (a stringa vuota) nella parte unquoted.
# Soluzione: passare la stringa come variabile separata che printf sostituisce con %s.
_CDB_ROOT="'CDB\$ROOT'"
sql_block=$(printf \
'SET COLSEP ","
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
select version from v$instance;
PROMPT ORAMARKER

SET HEADING ON
SET PAGESIZE 9999
SELECT * FROM (
  SELECT s.con_id,
         NVL(p.pdb_name, %s) AS pdb_name,
         s.username, s.status,
         pr.pga_used_mem, pr.pga_alloc_mem
  FROM v$session s
  JOIN v$process pr ON pr.addr = s.paddr
  LEFT OUTER JOIN cdb_pdbs p ON p.con_id = s.con_id
  WHERE s.username IS NOT NULL
  ORDER BY pr.pga_alloc_mem DESC
) WHERE ROWNUM <= %d;
EXIT
' "$_CDB_ROOT" "$LIMIT")

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

# Verifica versione: cdb_pdbs richiede Oracle 12c+
major=$(printf '%s' "$version" | cut -d. -f1)
if [ -n "$major" ] && [ "$major" != "null" ] && [ "$major" -lt 12 ] 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "unsupported_version" \
        "cdb_pdbs non disponibile su Oracle ${version}: richiede 12c+" \
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
