#!/usr/bin/env bash
# lib/oracle_conn.sh — libreria condivisa per tutti i tool primitivi Oracle
#
# Funzioni pubbliche:
#
#   validate_environment ENVIRONMENT
#       → 0 se valido, 1 se invalido (messaggio su stderr)
#
#   get_prod_noprod ENVIRONMENT
#       → stampa "prod" o "noprod"
#
#   validate_args TOOL ENV HOST INST
#       → 0 se tutti gli argomenti sono validi
#       → stampa envelope JSON di errore su stdout + return 2 se non valido
#         Sostituisce il blocco di validazione boilerplate nei tool.
#         Uso: validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?
#
#   classify_error STDERR_TEXT
#       → stampa uno dei codici: "connection_failed" | "missing_env_file" | "query_failed"
#         Analizza il testo catturato da stderr di run_sqlplus_raw/run_sqlplus_query.
#
#   build_error_json TOOL ENV HOST INST CODE MSG CTX_JSON [VERSION]
#       → stampa envelope JSON di errore su stdout
#         VERSION opzionale (default null) — utile per unsupported_version
#
#   build_envelope TOOL ENV HOST INST VERSION STATUS DATA_JSON ERROR_JSON
#       → stampa envelope JSON completo su stdout
#         VERSION può essere stringa vuota o "null" → oracle_version: null
#
#   run_sqlplus_raw HOSTNAME INSTANCE_NAME SQL_BLOCK
#       → esegue SQL_BLOCK su Oracle remoto via SSH, stdout = output grezzo sqlplus
#         Non impone struttura al SQL_BLOCK: marker, WHENEVER, HEADING sono
#         responsabilità del chiamante.
#         exit 0 = successo, exit 1 = errore SSH/connessione/sqlplus
#         Diagnostica su stderr (prefissata con connection_failed:/missing_env_file:/query_failed:)
#
#   run_sqlplus_query HOSTNAME INSTANCE_NAME QUERY
#       → output su stdout: riga 1 = versione (o "null"), righe 2+ = array JSON
#         Wrapper di run_sqlplus_raw per il caso a query singola.
#         exit 0 = successo, exit 1 = errore
#
#   run_tool TOOL ENV HOST INST QUERY
#       → esegue la query e stampa direttamente l'envelope JSON completo su stdout
#         Gestisce tutti i casi di errore (connection_failed, missing_env_file,
#         query_failed) producendo il JSON corretto. Exit 0 = ok, 1 = errore.
#         È il punto di ingresso standard per i tool primitivi a query singola.
#
#   find_alert_log HOSTNAME INSTANCE_NAME ENVIRONMENT
#       → stampa il path dell'alert log sul mount NFS; stringa vuota se non trovato
#         In caso di duplicati (migrazione), restituisce il file più recente.
#
# Uso: source lib/oracle_conn.sh  (da ogni tool primitivo)
#
# Note architetturali:
#   - stdout = JSON puro; tutta la diagnostica va su stderr.
#   - Shell remota = ksh: usare '.' non 'source' per env file Oracle.
#   - run_sqlplus_raw/query usa 1 sola connessione SSH per invocazione.
#   - printf 'format' "$var" espande \n; printf '%s' "$var" non lo fa.
#   - ORAMARKER in sqlplus: riga blank dopo PROMPT obbligatoria (sqlplus concatena
#     altrimenti PROMPT con il comando successivo sulla stessa riga di output).
#   - I tool NON devono usare set -e: run_tool restituisce exit code significativo
#     (0/1/2) che set -e intercetterebbe come errore fatale prima che lo script
#     possa propagarlo. Usare set -uo pipefail + exit $? esplicitamente.

# --- Configurazione -----------------------------------------------------------

ORACLE_SSH_KEY="${ORACLE_SSH_KEY:-/product/lana-bot/neural-oracle-analyzer/ssh_keys/oracle/.ssh/id_rsa}"
ORACLE_SSH_USER="${ORACLE_SSH_USER:-oracle}"
ORACLE_NFS_BASE="${ORACLE_NFS_BASE:-/unipol/logs/database/oracle}"

# --- Validazione ENVIRONMENT --------------------------------------------------

validate_environment() {
    local env="$1"
    case "$env" in
        EURO|TEST|CERT|INTE|COLL|PROD) return 0 ;;
        *)
            echo "ENVIRONMENT non valido: '$env'. Valori ammessi: EURO TEST CERT INTE COLL PROD" >&2
            return 1
            ;;
    esac
}

# --- Mapping ENVIRONMENT → prod|noprod ----------------------------------------

get_prod_noprod() {
    if [ "$1" = "PROD" ]; then echo "prod"; else echo "noprod"; fi
}

# --- Validazione formato hostname (R-10) ---------------------------------------
# Restituisce 0 se valido, 1 se non valido.
# Formato: solo lettere minuscole, cifre, trattini (DNS hostname label).
# Previene path traversal tipo "../../etc" nei path NFS e nel target SSH.
validate_hostname() {
    printf '%s' "$1" | grep -qE '^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$'
}

# --- Validazione argomenti standard dei tool ----------------------------------

# Valida ENVIRONMENT, HOSTNAME e INSTANCE_NAME in un'unica chiamata.
# In caso di errore: stampa envelope JSON su stdout e restituisce 2.
# Uso: validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?
#
# Argomenti: TOOL ENV HOST INST
validate_args() {
    local tool="$1" env="$2" host="$3" inst="$4"

    if ! validate_environment "$env" 2>/dev/null; then
        build_error_json "$tool" "$env" "$host" "$inst" \
            "invalid_environment" \
            "ENVIRONMENT non valido: '$env'. Valori ammessi: EURO TEST CERT INTE COLL PROD" \
            "{\"received\":\"$env\"}"
        return 2
    fi

    if [ -z "$host" ]; then
        build_error_json "$tool" "$env" "$host" "$inst" \
            "invalid_argument" "HOSTNAME obbligatorio" '{"param":"hostname"}'
        return 2
    fi

    # R-10: validazione formato hostname per prevenire path traversal.
    # Formato atteso: solo lettere minuscole, cifre, trattini (DNS-safe).
    # Esempi validi: axnporadb41, axceoradb02, lxprworkerlana01
    if ! validate_hostname "$host"; then
        build_error_json "$tool" "$env" "$host" "$inst" \
            "invalid_argument" \
            "HOSTNAME non valido: deve contenere solo lettere minuscole, cifre e trattini" \
            "{\"param\":\"hostname\",\"received\":\"$host\"}"
        return 2
    fi

    if [ -z "$inst" ]; then
        build_error_json "$tool" "$env" "$host" "$inst" \
            "invalid_argument" "INSTANCE_NAME obbligatorio" '{"param":"instance_name"}'
        return 2
    fi

    return 0
}

# --- Classificazione errori SSH/sqlplus ---------------------------------------

# Analizza il testo stderr prodotto da run_sqlplus_raw e restituisce il codice
# errore appropriato: "connection_failed" | "missing_env_file" | "query_failed"
# Stampa il codice su stdout (non su stderr).
#
# Argomenti: STDERR_TEXT
# Uso: err_code=$(classify_error "$stderr_text")
classify_error() {
    local text="$1"
    if printf '%s' "$text" | grep -q "^query_failed:"; then
        echo "query_failed"
    elif printf '%s' "$text" | grep -q "^missing_env_file:"; then
        echo "missing_env_file"
    else
        echo "connection_failed"
    fi
}

# --- Costruzione envelope JSON ------------------------------------------------

# Stampa un envelope JSON di errore su stdout.
# Argomenti: TOOL ENV HOST INST CODE MSG CTX_JSON [VERSION]
# VERSION è opzionale (default: null). Utile per unsupported_version dove la versione è nota.
build_error_json() {
    local tool="$1" env="$2" host="$3" inst="$4"
    local code="$5" msg="$6" ctx="$7"
    local version="${8:-null}"
    local ts
    # R3-04: UTC normalizzato (+00:00) su tutti i tool.
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
    local msg_esc
    msg_esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local ver_json
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        ver_json="null"
    else
        ver_json="\"$version\""
    fi
    printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":"%s","oracle_version":%s,"status":"error","data":[],"error":{"code":"%s","message":"%s","context":%s}}\n' \
        "$tool" "$ts" "$env" "$host" "$inst" "$ver_json" "$code" "$msg_esc" "$ctx"
}

# Stampa l'envelope JSON completo su stdout.
# Argomenti: TOOL ENV HOST INST VERSION STATUS DATA_JSON ERROR_JSON
# VERSION può essere stringa vuota o "null" → oracle_version: null nel JSON
# INST può essere stringa vuota o "null" → instance_name: null nel JSON
# R-12: i tool OS-level passano "null" come stringa per INST; deve diventare null JSON.
build_envelope() {
    local tool="$1" env="$2" host="$3" inst="$4"
    local version="$5" status="$6" data="$7" error="$8"
    local ts
    # R3-04: UTC normalizzato (+00:00) su tutti i tool.
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
    local ver_json inst_json
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        ver_json="null"
    else
        ver_json="\"$version\""
    fi
    if [ -z "$inst" ] || [ "$inst" = "null" ]; then
        inst_json="null"
    else
        inst_json="\"$inst\""
    fi
    printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":%s,"oracle_version":%s,"status":"%s","data":%s,"error":%s}\n' \
        "$tool" "$ts" "$env" "$host" "$inst_json" "$ver_json" "$status" "$data" "$error"
}

# --- Parsing CSV → array JSON -------------------------------------------------

# Converte output CSV di sqlplus (SET COLSEP "," + SET HEADING ON) in array JSON.
# Legge da stdin, stampa su stdout.
# Prima riga = header con nomi colonne, righe successive = dati.
# Compatibile con Oracle 11g, 12.1, 12.2, 19c (non richiede SET MARKUP CSV ON).
# - Valori vuoti dopo trim → null JSON
# - Valori numerici puri → numero JSON
# - Tutto il resto → stringa JSON
_csv_to_json_array() {
    awk '
BEGIN {
    OFS = ""
    first_data = 1
    print "["
}
NR == 1 {
    ncols = split_csv($0, headers)
    next
}
/^[[:space:]]*$/ { next }
/^[-,[:space:]]+$/ { next }
{
    split_csv($0, values)
    if (!first_data) printf ","
    first_data = 0
    printf "{"
    for (i = 1; i <= ncols; i++) {
        if (i > 1) printf ","
        key = tolower(trim(unquote(headers[i])))
        gsub(/ /, "_", key)   # normalizza spazi in underscore (es. "open mode" → "open_mode")
        val = trim(unquote(values[i]))
        if (val == "") {
            printf "\"%s\":null", key
        } else if (val ~ /^-?[0-9]+(\.[0-9]+)?$/ || val ~ /^-?\.[0-9]+$/) {
            # R-13: valori come ".18" (punto iniziale senza zero) sono numerici.
            # Oracle restituisce percent_space_used come ".18" invece di "0.18".
            printf "\"%s\":%s", key, val
        } else {
            gsub(/\\/, "\\\\", val)
            gsub(/"/, "\\\"", val)
            printf "\"%s\":\"%s\"", key, val
        }
    }
    print "}"
}
END {
    print "]"
}
function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
}
function unquote(s) {
    if (substr(s,1,1) == "\"" && substr(s,length(s),1) == "\"")
        return substr(s, 2, length(s)-2)
    return s
}
function split_csv(line, arr,    n, i, c, inq, field) {
    n = 0; inq = 0; field = ""
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\"") {
            if (inq && substr(line, i+1, 1) == "\"") {
                field = field "\""
                i++
            } else {
                inq = !inq
                field = field c
            }
        } else if (c == "," && !inq) {
            arr[++n] = field
            field = ""
        } else {
            field = field c
        }
    }
    arr[++n] = field
    return n
}
'
}

# --- Trasporto SSH grezzo -----------------------------------------------------

# Esegue un blocco SQL arbitrario su Oracle remoto via SSH.
# Il chiamante è responsabile dell'intera struttura del SQL_BLOCK:
#   SET MARKUP, WHENEVER SQLERROR, PROMPT marker, EXIT, ecc.
#
# Argomenti: HOSTNAME INSTANCE_NAME SQL_BLOCK
#
# Output su stdout: output grezzo di sqlplus (non parsificato).
# Output su stderr: diagnostica prefissata con:
#   "connection_failed: ..."  — SSH non raggiungibile o login fallito
#   "missing_env_file: ..."   — env file non trovato sul server
#   "query_failed: ..."       — sqlplus ha restituito ORA-
#
# Exit code:
#   0 = successo (sqlplus terminato senza errori)
#   1 = errore (SSH, env file mancante, errore ORA-)
#
# Uso tipico per tool multi-query:
#   raw=$(run_sqlplus_raw "$HOST" "$INST" "$sql_block" 2>"$stderr_tmp")
#   rc=$?; err=$(classify_error "$(cat $stderr_tmp)"); rm -f "$stderr_tmp"
run_sqlplus_raw() {
    local hostname="$1" instance="$2" sql_block="$3"
    local ssh_opts="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

    # Determina il nome base RAC dell'env file (es. PPBPROD1 → PPBPROD).
    # Convenzione RAC: l'istanza ha un suffisso numerico ma l'env file è condiviso
    # senza numero. Si prova prima il nome esatto; se non esiste si ritenta senza
    # il suffisso numerico finale (solo se l'ultimo carattere è una cifra).
    #
    # NOTA ksh: su ksh (shell remota), `. file` su file inesistente termina la shell
    # anche con 2>/dev/null — non continua come in bash. Per questo si usa
    # [ -f ~/FILE.env ] prima di sourciare, compatibile ksh e bash.
    local rac_base
    rac_base=$(printf '%s' "$instance" | sed 's/[0-9]*$//')

    local env_loader
    if [ "$rac_base" != "$instance" ]; then
        # Istanza RAC: prova INST.env se esiste, altrimenti BASE.env
        env_loader="f=\${HOME}/${instance}.env; [ -f \"\$f\" ] && . \"\$f\" || . \${HOME}/${rac_base}.env"
    else
        # Nome senza suffisso numerico: solo INST.env
        env_loader=". \${HOME}/${instance}.env"
    fi

    local raw_output
    raw_output=$(printf '%s\n' "$sql_block" | \
        ssh $ssh_opts "${ORACLE_SSH_USER}@${hostname}" \
        "$env_loader && sqlplus -s / as sysdba" 2>&1)
    local ssh_exit=$?

    if [ $ssh_exit -ne 0 ]; then
        if printf '%s' "$raw_output" | grep -q "ORA-[0-9]"; then
            echo "query_failed: $(printf '%s' "$raw_output" | grep 'ORA-[0-9]' | head -1)" >&2
        elif printf '%s' "$raw_output" | grep -qiE "no such file|cannot open|not found|missing_env_file"; then
            echo "missing_env_file: ~/${instance}.env (o base RAC) non trovato su ${hostname}" >&2
        else
            echo "connection_failed: SSH exit ${ssh_exit} per ${ORACLE_SSH_USER}@${hostname}" >&2
        fi
        return 1
    fi

    printf '%s\n' "$raw_output"
    return 0
}

# --- Esecuzione query sqlplus (query singola) ---------------------------------

# Esegue una query SQL su un CDB Oracle remoto via SSH in una singola connessione.
# Wrapper di run_sqlplus_raw per il caso a query singola con struttura fissa.
#
# Argomenti: HOSTNAME INSTANCE_NAME QUERY
#   QUERY: istruzione SQL completa senza punto e virgola finale
#
# Output su stdout — due righe logiche:
#   riga 1:   versione Oracle (es. "19.0.0.0.0") oppure "null"
#   righe 2+: array JSON dei risultati (es. '[{"col":"val"}]')
#
# Exit code: 0 = successo, 1 = errore (diagnostica su stderr)
#
# Struttura SQL interna:
#   versione (HEADING OFF) → ORAMARKER → dati (HEADING ON, WHENEVER SQLERROR EXIT 1)
#   La riga blank dopo PROMPT ORAMARKER è obbligatoria: senza, sqlplus concatena
#   PROMPT con il comando successivo sulla stessa riga di output.
run_sqlplus_query() {
    local hostname="$1" instance="$2" query="$3"

    local sql_block
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
%s;
EXIT
' "$query")

    local raw_output
    raw_output=$(run_sqlplus_raw "$hostname" "$instance" "$sql_block" 2>&1)
    local rc=$?

    if [ $rc -ne 0 ]; then
        # Propaga la diagnostica già prefissata da run_sqlplus_raw
        printf '%s\n' "$raw_output" >&2
        return 1
    fi

    # Riga 1: versione (prima riga non vuota, senza doppi apici)
    local version
    version=$(printf '%s\n' "$raw_output" | grep -v '^[[:space:]]*$' | head -1 | tr -d '"' | tr -d ' ')
    if printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]'; then
        printf '%s\n' "$version"
    else
        printf 'null\n'
    fi

    # Righe 2+: array JSON dei dati (tutto dopo il marker ORAMARKER)
    printf '%s\n' "$raw_output" | awk '/^ORAMARKER$/{found=1; next} found{print}' \
        | grep -v '^[[:space:]]*$' | _csv_to_json_array
}

# --- Parsing dell'output di run_sqlplus_query ---------------------------------

# Estrae la versione Oracle (riga 1) dall'output di run_sqlplus_query.
# Accetta l'output come argomento oppure da stdin.
_extract_version() {
    if [ $# -gt 0 ]; then
        printf '%s\n' "$1" | head -1
    else
        head -1
    fi
}

# Estrae l'array JSON dei dati (righe 2+) dall'output di run_sqlplus_query.
_extract_data() {
    if [ $# -gt 0 ]; then
        printf '%s\n' "$1" | tail -n +2
    else
        tail -n +2
    fi
}

# --- Punto di ingresso standard per i tool primitivi a query singola ----------

# Esegue una query e stampa direttamente l'envelope JSON completo su stdout.
# Gestisce tutti i casi di errore producendo JSON conforme al contratto.
#
# Argomenti: TOOL ENV HOST INST QUERY
#
# Flusso:
#   1. validate_args → se invalido: envelope JSON di errore, exit 2
#   2. run_sqlplus_query → se fallisce: classifica errore con classify_error, exit 1
#   3. build_envelope ok con versione e dati, exit 0
#
# I tool con logica aggiuntiva (versione check, multi-query, parametri opzionali)
# usano direttamente: validate_args + run_sqlplus_raw + classify_error + build_envelope
run_tool() {
    local tool="$1" env="$2" host="$3" inst="$4" query="$5"

    # 1. Validazione argomenti
    validate_args "$tool" "$env" "$host" "$inst" || return $?

    # 2. Esegui la query
    local raw_output stderr_tmp
    stderr_tmp=$(mktemp)
    raw_output=$(run_sqlplus_query "$host" "$inst" "$query" 2>"$stderr_tmp")
    local rc=$?
    local err_detail
    err_detail=$(cat "$stderr_tmp")
    rm -f "$stderr_tmp"

    if [ $rc -ne 0 ]; then
        local err_code err_msg err_ctx
        err_code=$(classify_error "$err_detail")
        case "$err_code" in
            connection_failed)
                err_msg=$(printf '%s' "$err_detail" | sed 's/^connection_failed: //')
                err_ctx="{\"detail\":\"$(printf '%s' "$err_msg" | sed 's/"/\\"/g')\"}"
                ;;
            missing_env_file)
                err_msg=$(printf '%s' "$err_detail" | sed 's/^missing_env_file: //')
                err_ctx="{\"path\":\"~/${inst}.env\"}"
                ;;
            query_failed)
                err_msg=$(printf '%s' "$err_detail" | sed 's/^query_failed: //')
                err_ctx="{\"ora_error\":\"$(printf '%s' "$err_msg" | sed 's/"/\\"/g')\"}"
                ;;
        esac
        build_error_json "$tool" "$env" "$host" "$inst" "$err_code" "$err_msg" "$err_ctx"
        return 1
    fi

    # 3. Estrai versione e dati, costruisci envelope ok
    local version data
    version=$(printf '%s\n' "$raw_output" | head -1)
    data=$(printf '%s\n' "$raw_output" | tail -n +2)
    build_envelope "$tool" "$env" "$host" "$inst" "$version" "ok" "$data" "null"
    return 0
}

# --- Ricerca alert log su NFS -------------------------------------------------

# Trova il path dell'alert log sul mount NFS locale.
# Argomenti: HOSTNAME INSTANCE_NAME ENVIRONMENT
# Stampa il path completo su stdout; stringa vuota se non trovato.
# Se esistono duplicati (caso migrazione), restituisce il file con data di modifica più recente.
#
# NOTA NFS: NON usare `find` con ricorsione — su alcuni host RAC le sottodirectory
# cdmp_* del trace hanno handle NFS problematici che causano blocchi indefiniti.
# La struttura NFS è nota: $base/<volume>/<INSTANCE>/trace/alert_<INSTANCE>.log
# Si usa quindi un glob a profondità fissa: $base/*/<INSTANCE>/trace/alert_<INSTANCE>.log
find_alert_log() {
    local hostname="$1" instance="$2" env="$3"
    local prod_noprod
    prod_noprod=$(get_prod_noprod "$env")
    local base="${ORACLE_NFS_BASE}/${prod_noprod}/${hostname}"

    if [ ! -d "$base" ]; then
        echo ""
        return
    fi

    # Glob a profondità fissa: base/<volume>/<instance>/trace/alert_<instance>.log
    # Gestisce duplicati da migrazione (più volumi con la stessa istanza).
    local target="alert_${instance}.log"
    local matches
    matches=$(ls -t "${base}"/*/"${instance}"/trace/"${target}" 2>/dev/null)
    if [ -z "$matches" ]; then
        echo ""
        return
    fi

    # ls -t già ordina per data di modifica decrescente: il primo è il più recente
    printf '%s\n' "$matches" | head -1
}
