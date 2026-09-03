#!/usr/bin/env bash
# tools/check_fra_usage.sh — verifica utilizzo Flash Recovery Area (FRA) Oracle
#
# Uso: check_fra_usage.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti di tre tipi distinti, identificati dal campo "source":
#     source="fra_dest"  → {source, name, space_limit, space_used, space_reclaimable, number_of_files}
#                          (da v$recovery_file_dest; space_* in bytes)
#     source="fra_usage" → {source, file_type, percent_space_used, percent_space_reclaimable, number_of_files}
#                          (da v$flash_recovery_area_usage; solo righe con almeno un file)
#     source="fra_size"  → {source, name, type, value}
#                          (da show parameters db_recovery_file_dest*)
#
#   Se la FRA non è configurata (db_recovery_file_dest_size=0) le sezioni fra_dest
#   e fra_usage restano vuote — il tool restituisce comunque status=ok con data parziale.
#   Funziona su tutte le versioni Oracle (11g, 12c, 19c).
#
# Strategia multi-query:
#   Unica connessione SSH con run_sqlplus_raw; tre sezioni separate da MARKER2/MARKER3.
#   Struttura output: versione → MARKER2 → fra_dest → MARKER3 → fra_usage → MARKER4 → fra_size
#   Il campo "source" viene iniettato via awk dopo il parsing CSV.

set -uo pipefail

TOOL="check_fra_usage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

# 1. Valida argomenti standard
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# 2. Costruisce il blocco SQL con 4 sezioni separate da marker:
#    versione → MARKER2 (fra_dest) → MARKER3 (fra_usage) → MARKER4 (fra_size)
#
#    Note:
#    - WHENEVER SQLERROR EXIT 1 precede tutte le query SQL
#    - "show parameters" non è SQL: non è coperto da WHENEVER, ma non può fallire
#      su versioni supportate — restituisce al massimo zero righe
#    - La riga blank dopo ogni PROMPT è obbligatoria (gotcha sqlplus)
sql_block=$(printf \
'SET COLSEP ","
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 32767
SET TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
select version from v$instance;
PROMPT MARKER2

SET HEADING ON
SET PAGESIZE 9999
SELECT name, space_limit, space_used, space_reclaimable, number_of_files
FROM v$recovery_file_dest;
PROMPT MARKER3

SELECT file_type, percent_space_used, percent_space_reclaimable, number_of_files
FROM v$flash_recovery_area_usage;
PROMPT MARKER4

show parameters db_recovery_file_dest
EXIT
')

# 3. Esegui l'unica connessione SSH
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

# 4. Estrai versione (prima riga non vuota)
version=$(printf '%s\n' "$raw_output" | grep -v '^[[:space:]]*$' | head -1 | tr -d '"' | tr -d ' ')
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]'; then
    version="null"
fi

# 5. Splitta le tre sezioni e converti ciascuna in array JSON con campo "source" iniettato.
#
#    _section_to_json SOURCE MARKER_START MARKER_END:
#      Estrae le righe tra i due marker, parsifica come CSV e aggiunge "source":"SOURCE"
#      come primo campo di ogni oggetto.
_section_to_json() {
    local source_tag="$1" marker_start="$2" marker_end="$3"
    printf '%s\n' "$raw_output" \
        | awk -v start="$marker_start" -v end="$marker_end" \
              'found && end!="" && $0==end{exit} $0==start{found=1; next} found{print}' \
        | grep -v '^[[:space:]]*$' \
        | _csv_to_json_array \
        | awk -v src="$source_tag" '
            # Inietta "source":"<tag>" come primo campo di ogni oggetto JSON
            /^\[/{print; next}
            /^\]/{print; next}
            /^\{/{
                sub(/^\{/, "{\"source\":\"" src "\",")
                print
                next
            }
            /^,\{/{
                sub(/^,\{/, ",{\"source\":\"" src "\",")
                print
                next
            }
            {print}
        '
}

fra_dest=$(_section_to_json  "fra_dest"  "MARKER2" "MARKER3")
fra_usage=$(_section_to_json "fra_usage" "MARKER3" "MARKER4")
fra_size=$(_section_to_json  "fra_size"  "MARKER4" "")

# 6. Concatena i tre array in un unico array data[].
#    Ogni sezione è già un array JSON valido (può essere []); li mergiamo
#    estraendo il contenuto interno e separandoli con virgola solo se non vuoti.
_merge_arrays() {
    # Estrae il contenuto tra [ e ] di ogni array, filtra gli array vuoti
    awk '
BEGIN { out = ""; sep = "" }
{
    # Rimuove [ iniziale e ] finale, trim whitespace
    s = $0
    gsub(/^\[[[:space:]]*/, "", s)
    gsub(/[[:space:]]*\]$/, "", s)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    if (s != "") {
        out = out sep s
        sep = ","
    }
}
END { print "[" out "]" }
' << EOF
$( printf '%s\n' "$fra_dest"  | tr -d '\n' )
$( printf '%s\n' "$fra_usage" | tr -d '\n' )
$( printf '%s\n' "$fra_size"  | tr -d '\n' )
EOF
}

data=$(_merge_arrays)

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "$version" "ok" "$data" "null"
