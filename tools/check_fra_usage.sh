#!/usr/bin/env bash
# tools/check_fra_usage.sh — verifica utilizzo Flash Recovery Area (FRA) Oracle
#
# Uso: check_fra_usage.sh ENVIRONMENT HOSTNAME INSTANCE_NAME
#
# Output JSON:
#   data: array di oggetti di quattro tipi distinti, identificati dal campo "source":
#     source="fra_status" → {source, fra_configured: bool, db_recovery_file_dest, db_recovery_file_dest_size}
#                           (sempre presente — indica se la FRA è configurata)
#     source="fra_dest"   → {source, name, space_limit, space_used, space_reclaimable, number_of_files}
#                           (da v$recovery_file_dest; space_* in bytes; array vuoto se FRA assente)
#     source="fra_usage"  → {source, file_type, percent_space_used, percent_space_reclaimable, number_of_files}
#                           (da v$flash_recovery_area_usage; array vuoto se FRA assente)
#     source="fra_size"   → {source, name, type, value}
#                           (da v$parameter; sempre presente con i due parametri di configurazione)
#
#   BUG-02: aggiunto fra_status come prima sezione con fra_configured esplicito,
#   così il chiamante non deve inferire lo stato dall'assenza di righe.
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
#    - BUG-03+09: "show parameters" wrappava i valori a 30 caratteri e restituiva
#      space_limit in notazione scientifica; sostituito con query su v$parameter
#      e CAST su space_limit per garantire valori interi in byte.
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
SET NUMWIDTH 20
SELECT name, CAST(space_limit AS NUMBER) AS space_limit,
       CAST(space_used AS NUMBER) AS space_used,
       CAST(space_reclaimable AS NUMBER) AS space_reclaimable,
       number_of_files
FROM v$recovery_file_dest;
PROMPT MARKER3

SELECT file_type, percent_space_used, percent_space_reclaimable, number_of_files
FROM v$flash_recovery_area_usage;
PROMPT MARKER4

SELECT name, type, value
FROM v$parameter
WHERE name IN ('"'"'db_recovery_file_dest'"'"', '"'"'db_recovery_file_dest_size'"'"')
ORDER BY name;
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

# 6. BUG-02: costruisce fra_status — oggetto esplicito con fra_configured bool.
#    Fra configurata = db_recovery_file_dest non vuoto E dest_size > 0.
#    I valori dei due parametri vengono estratti dalla sezione fra_size (v$parameter).
fra_dest_param=$(printf '%s\n' "$fra_size" \
    | jq -r '[.[] | select(.name == "db_recovery_file_dest")] | first | .value // ""' 2>/dev/null || true)
fra_size_param=$(printf '%s\n' "$fra_size" \
    | jq -r '[.[] | select(.name == "db_recovery_file_dest_size")] | first | .value // "0"' 2>/dev/null || true)

# FRA configurata se: dest non vuota E dest_size numerico > 0
if [ -n "$fra_dest_param" ] && [ "$fra_dest_param" != "" ] \
   && printf '%s' "$fra_size_param" | grep -qE '^[0-9]+$' \
   && [ "$fra_size_param" -gt 0 ] 2>/dev/null; then
    fra_configured="true"
else
    fra_configured="false"
fi

# Escaping JSON per il path (può contenere slash e caratteri speciali)
fra_dest_json=$(printf '%s' "$fra_dest_param" | sed 's/\\/\\\\/g; s/"/\\"/g')

# R-13: db_recovery_file_dest_size deve essere un intero (numero JSON), non una stringa.
# Il valore viene da v$parameter.value che restituisce VARCHAR2 (es. "107374182400").
# Se è numerico puro → emetterlo senza virgolette; altrimenti → stringa.
if printf '%s' "$fra_size_param" | grep -qE '^[0-9]+$'; then
    fra_size_json_val="$fra_size_param"
else
    fra_size_esc=$(printf '%s' "$fra_size_param" | sed 's/\\/\\\\/g; s/"/\\"/g')
    fra_size_json_val="\"${fra_size_esc}\""
fi

fra_status_json="{\"source\":\"fra_status\",\"fra_configured\":${fra_configured},\"db_recovery_file_dest\":\"${fra_dest_json}\",\"db_recovery_file_dest_size\":${fra_size_json_val}}"

# 7. Concatena le quattro sezioni in un unico array data[].
#    fra_status è sempre presente come primo elemento.
#    Le altre sezioni sono già array JSON validi (possono essere []).
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
$( printf '%s\n' "$fra_status_json" )
$( printf '%s\n' "$fra_dest"  | tr -d '\n' )
$( printf '%s\n' "$fra_usage" | tr -d '\n' )
$( printf '%s\n' "$fra_size"  | tr -d '\n' )
EOF
}

data=$(_merge_arrays)

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "$version" "ok" "$data" "null"
