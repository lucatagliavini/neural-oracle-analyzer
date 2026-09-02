#!/usr/bin/env bash
# tools/scan_alert_log.sh — scansiona l'alert log Oracle cercando errori ORA-
#
# Uso: scan_alert_log.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--code=ORA-XXXXX] [--since=YYYY-MM-DD] [--pdb=NAME]
#
# Output JSON:
#   data: array di oggetti {code, pdb_name, description, category, severity, count, first_seen, last_seen, samples[]}
#   Ordine: per count decrescente.
#   pdb_name: nome del PDB che ha generato l'errore (es. "AIMELA"), oppure null se CDB root
#             (riga senza prefisso "PDBNAME(con_id):")
#   Se --code= specificato: filtra solo quel codice ORA-.
#   Se --since= specificato: considera solo righe dal timestamp >= YYYY-MM-DD.
#   Se --pdb= specificato: filtra solo gli errori del PDB indicato (case-insensitive).
#             Usare --pdb=CDB per vedere solo gli errori del container root (pdb_name null).
#
# Formato riga alert log Oracle 12c+:
#   Con contesto PDB:  "PDBNAME(con_id):ORA-XXXXX: ..."  → pdb_name = "PDBNAME"
#   Senza contesto:    "ORA-XXXXX: ..."                  → pdb_name = null (CDB root)
#
# Note tecniche:
#   - Legge l'alert log dal mount NFS locale (lxprworkerlana01), senza connessione SSH a Oracle.
#   - usa find_alert_log() dalla libreria per trovare il path.
#   - Se path non trovato: restituisce log_not_found con il path tentato.
#   - Arricchisce ogni codice ORA- con description/category/severity da data/ora_errors.json
#     se disponibile; altrimenti usa valori null.
#   - Timestamp in alert log formato: "YYYY-MM-DDTHH:MM:SS.microseconds+TZ"
#     es. "2026-09-01T08:16:43.043810+02:00"
#   - La riga con il timestamp precede il messaggio di errore nella stessa finestra temporale.

set -uo pipefail
# Nota: set -e non usato — exit code gestito esplicitamente.

TOOL="scan_alert_log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/oracle_conn.sh
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

# --- Argomenti ----------------------------------------------------------------

ENV="${1:-}"
HOST="${2:-}"
INST="${3:-}"

# Filtri opzionali
FILTER_CODE=""
FILTER_SINCE=""
FILTER_PDB=""
for arg in "${@:4}"; do
    case "$arg" in
        --code=*)   FILTER_CODE="${arg#--code=}"  ;;
        --since=*)  FILTER_SINCE="${arg#--since=}" ;;
        --pdb=*)    FILTER_PDB="${arg#--pdb=}"    ;;
    esac
done

# --- Validazioni --------------------------------------------------------------

# 1. Argomenti standard (ENVIRONMENT, HOSTNAME, INSTANCE_NAME)
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?

# 2. Validazione filtri opzionali
if [ -n "$FILTER_CODE" ] && ! echo "$FILTER_CODE" | grep -qE '^ORA-[0-9]+$'; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "invalid_argument" "--code deve essere nel formato ORA-NNNNN" \
        "{\"param\":\"code\",\"received\":\"$FILTER_CODE\"}"
    exit 2
fi
if [ -n "$FILTER_SINCE" ] && ! echo "$FILTER_SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "invalid_argument" "--since deve essere nel formato YYYY-MM-DD" \
        "{\"param\":\"since\",\"received\":\"$FILTER_SINCE\"}"
    exit 2
fi

# --- Trova alert log ----------------------------------------------------------

LOG_PATH=$(find_alert_log "$HOST" "$INST" "$ENV")
if [ -z "$LOG_PATH" ]; then
    prod_noprod=$(get_prod_noprod "$ENV")
    attempted="${ORACLE_NFS_BASE}/${prod_noprod}/${HOST}/.../${INST}/trace/alert_${INST}.log"
    build_error_json "$TOOL" "$ENV" "$HOST" "$INST" \
        "log_not_found" \
        "Alert log non trovato sul mount NFS: ${attempted}" \
        "{\"path\":\"${attempted}\"}"
    exit 1
fi

# --- Pre-filtraggio I/O quando --since è specificato --------------------------
#
# Strategia: quando FILTER_SINCE è impostato, usiamo grep -n per trovare la
# prima riga che inizia con la data ISO richiesta, poi passiamo ad awk solo
# la coda del file con tail -n +N. Questo riduce drasticamente l'I/O NFS su
# file grandi (es. 388 MB → ~20 MB per un filtro "ultime 2 settimane").
#
# Prerequisito: il log deve usare il formato timestamp ISO 8601 (Oracle 12c+):
#   "2026-09-01T08:16:43.043810+02:00"
# I log con formato testuale puro 11g ("Tue Sep 01 08:16:43 2022") non hanno
# righe che iniziano con YYYY-MM-DD e il pre-filtraggio verrebbe saltato.
# Un log "misto" (startup 11g + body 12c+) è gestito correttamente: grep -m1
# trova la prima riga ISO (anche se non è nelle primissime righe).
#
# Casi gestiti:
#   1. FILTER_SINCE non impostato        → AWK_PREFILTER=0, awk legge LOG_PATH intero
#   2. FILTER_SINCE impostato, ISO check OK, data trovata nel log
#                                        → AWK_PREFILTER=1, awk legge tail -n +N
#   3. FILTER_SINCE impostato, ISO check OK, data NON trovata (since oltre fine log)
#                                        → data: [] diretto, senza passare per awk
#   4. FILTER_SINCE impostato, nessuna riga ISO nel file (log 11g puro)
#                                        → AWK_PREFILTER=0, awk legge file intero (fallback)

AWK_PREFILTER=0
AWK_SINCE_START_LINE=""

if [ -n "$FILTER_SINCE" ]; then
    # Verifica che il log contenga almeno una riga in formato ISO (12c+).
    # grep -m1 si ferma alla prima hit → istantaneo anche su file da 400 MB.
    has_iso=$(grep -m1 -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$LOG_PATH" 2>/dev/null || true)
    if [ "${has_iso:-0}" -gt 0 ]; then
        # Trova la prima riga che inizia con la data richiesta (YYYY-MM-DD)
        AWK_SINCE_START_LINE=$(grep -n "^${FILTER_SINCE}" "$LOG_PATH" 2>/dev/null \
            | head -1 | cut -d: -f1)
        if [ -n "$AWK_SINCE_START_LINE" ]; then
            AWK_PREFILTER=1
        else
            # Nessuna riga con quella data: il log non ha dati nel range richiesto.
            # Restituiamo data: [] senza passare per awk (che non troverebbe nulla).
            build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "null" "ok" "[]" "null"
            exit 0
        fi
    fi
    # Se has_iso=0 (log 11g puro): AWK_PREFILTER rimane 0, awk filtra in-flight come prima.
fi

# --- Scansione ORA- con awk ---------------------------------------------------

# Carica il dizionario ora_errors.json se disponibile
ORA_ERRORS_FILE="${SCRIPT_DIR}/../data/ora_errors.json"

# awk scansiona l'alert log:
# - tiene traccia dell'ultimo timestamp ISO 8601 visto nella riga precedente
# - quando trova ORA-NNNNN: estrae il PDB dal prefisso "PDBNAME(N):" se presente
#   (null = CDB root se riga senza prefisso)
# - aggrega per coppia (code, pdb_name), accumula count, first_seen, last_seen, 2 sample
# - filtra per FILTER_CODE, FILTER_SINCE, FILTER_PDB se impostati
#
# Output: linee con separatore \x01 (non può apparire in log Oracle):
#   CODE \x01 PDB_NAME \x01 COUNT \x01 FIRST_SEEN \x01 LAST_SEEN \x01 N_SAMPLES \x01 SAMPLE1 \x01 SAMPLE2
# PDB_NAME = nome PDB oppure stringa vuota (= CDB root / null nel JSON).
# I sample sono già JSON-escaped (senza "" wrapping).
# LC_ALL=C garantisce che awk veda ogni byte come carattere singolo (modalità byte),
# necessario per gestire correttamente i log Oracle che possono contenere
# byte non-ASCII (Latin-1/ISO-8859-1) nei messaggi localizzati in italiano.
# json_esc() è definita in lib/json_esc.awk (inclusa via @include).
AWK_LIB="${SCRIPT_DIR}/../lib/json_esc.awk"
_awk_tmp=$(mktemp /tmp/scan_alert_XXXXXX.awk)
cat > "$_awk_tmp" << 'AWK'

# Estrae il nome PDB dal prefisso "PDBNAME(con_id):" di una riga.
# Restituisce il nome PDB in maiuscolo, o "" se la riga non ha prefisso PDB.
# Formato Oracle: "VITAWFST(13):messaggio" oppure "PDB$SEED(2):messaggio"
function extract_pdb(line,    m) {
    if (match(line, /^([A-Z][A-Z0-9_$#]*)\([0-9]+\):/, m))
        return m[1]
    return ""
}

# Riconosce timestamp ISO 8601 stile Oracle alert log:
#   "2026-09-01T08:16:43.043810+02:00" oppure "2026-09-01 08:16:43.043810"
# Prende solo la parte YYYY-MM-DDTHH:MM:SS (troncando microsecondi e tz per semplicità)
/^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    ts = $0
    sub(/\.[0-9]+.*/, "", ts)  # rimuove microsecondi e timezone
    gsub(/ /, "T", ts)         # normalizza spazio → T
    last_ts = ts
    next
}

# Righe contenenti ORA-NNNNN (almeno 2 cifre: esclude "ORA-0" = success code Oracle)
/ORA-[0-9][0-9]+/ {
    pdb  = extract_pdb($0)
    line = $0

    # Filtro per PDB: "--pdb=CDB" mostra solo righe senza prefisso PDB (CDB root)
    if (filter_pdb != "") {
        fp = toupper(filter_pdb)
        if (fp == "CDB") {
            if (pdb != "") next
        } else {
            if (toupper(pdb) != fp) next
        }
    }

    # Trova tutti i codici ORA- sulla riga (≥2 cifre: ORA-0 è success code, non un errore)
    while (match(line, /ORA-[0-9][0-9]+/)) {
        raw_code = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)

        # Filtro per codice specifico
        if (filter_code != "" && raw_code != filter_code) continue

        # Filtro per data
        if (filter_since != "" && last_ts != "" && last_ts < filter_since) continue

        # Chiave composita: codice + pdb (lo stesso codice da CDB root e da un PDB
        # sono occorrenze distinte)
        key = raw_code SUBSEP pdb

        # Prima occorrenza per questa coppia (code, pdb)
        if (!(key in counts)) {
            counts[key] = 0
            first_seen[key] = (last_ts != "" ? last_ts : "unknown")
            last_seen[key]  = first_seen[key]
            sample_count[key] = 0
            samples[key, 0] = ""
            samples[key, 1] = ""
        }

        counts[key]++
        if (last_ts != "") last_seen[key] = last_ts

        # Accumula fino a 2 sample (riga originale, già JSON-escaped)
        if (sample_count[key] < 2) {
            samp = json_esc($0)
            if (length(samp) > 200) samp = substr(samp, 1, 200) "..."
            samples[key, sample_count[key]] = samp
            sample_count[key]++
        }
    }
}

END {
    SEP = "\001"
    for (key in counts) {
        split(key, parts, SUBSEP)
        code = parts[1]
        pdb  = parts[2]
        s0 = samples[key, 0]; s1 = samples[key, 1]
        n  = sample_count[key]
        printf "%s%s%s%s%d%s%s%s%s%s%d%s%s%s%s\n", \
            code, SEP, pdb, SEP, counts[key], SEP, \
            first_seen[key], SEP, last_seen[key], SEP, n, SEP, s0, SEP, s1
    }
}
AWK
# Due branch espliciti per evitare il gotcha bash della process substitution
# in variabile (<(cmd) salvato come stringa non funziona all'espansione).
if [ "$AWK_PREFILTER" = "1" ]; then
    scan_output=$(LC_ALL=C awk \
        -v filter_code="$FILTER_CODE" \
        -v filter_since="$FILTER_SINCE" \
        -v filter_pdb="$FILTER_PDB" \
        -f "${AWK_LIB}" \
        -f "$_awk_tmp" \
        <(tail -n +"$AWK_SINCE_START_LINE" "$LOG_PATH"))
else
    scan_output=$(LC_ALL=C awk \
        -v filter_code="$FILTER_CODE" \
        -v filter_since="$FILTER_SINCE" \
        -v filter_pdb="$FILTER_PDB" \
        -f "${AWK_LIB}" \
        -f "$_awk_tmp" \
        "$LOG_PATH")
fi
rm -f "$_awk_tmp"

# --- Arricchimento con ora_errors.json + costruzione array JSON ---------------

# Pre-processa ora_errors.json con jq (parser JSON corretto) in formato tabellare
# CODE\x01DESC\x01CAT\x01SEV — una riga per codice, valori già senza virgolette.
# jq gestisce correttamente i caratteri speciali (backslash, virgolette) nelle descrizioni.
ora_lookup=""
if [ -f "$ORA_ERRORS_FILE" ]; then
    ora_lookup=$(jq -r '.[] | [.code, (.description//""), (.category//""), (.severity//"")]
                              | join("\u0001")' "$ORA_ERRORS_FILE" 2>/dev/null)
fi

# Costruisce il data array JSON a partire dall'output \x01-separato di awk.
# Il dizionario viene passato come stringa pre-tabulata — nessun parsing JSON in awk.
data_json=$(printf '%s\n' "$scan_output" | sort -t$'\001' -k3 -rn | awk \
    -F'\001' \
    -v ora_lookup="$ora_lookup" \
    '
BEGIN {
    # Carica lookup CODE → desc/cat/sev dalla stringa tabulata prodotta da jq
    n = split(ora_lookup, lines, "\n")
    for (i = 1; i <= n; i++) {
        if (split(lines[i], f, "\001") >= 1 && f[1] != "") {
            descriptions[f[1]] = (length(f) >= 2 ? f[2] : "")
            categories[f[1]]   = (length(f) >= 3 ? f[3] : "")
            severities[f[1]]   = (length(f) >= 4 ? f[4] : "")
        }
    }
    print "["
    first = 1
}

# Escape JSON per stringhe provenienti dal dizionario (già ASCII-safe tramite jq,
# ma possono contenere backslash o virgolette nelle descrizioni).
function jesc(s,    out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if      (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else                out = out c
    }
    return out
}

# Normalizza ORA-N → ORA-NNNNN (5 cifre, zero-padded) per lookup nel dizionario
function normalize_code(c,    num) {
    num = substr(c, 5)
    while (length(num) < 5) num = "0" num
    return "ORA-" num
}

NF >= 5 {
    code  = $1
    pdb   = $2
    cnt   = $3
    fs    = $4
    ls    = $5
    n_smp = (NF >= 6 ? $6 + 0 : 0)
    s0    = (NF >= 7 ? $7 : "")
    s1    = (NF >= 8 ? $8 : "")

    norm = normalize_code(code)
    desc = (norm in descriptions && descriptions[norm] != "" ? "\"" jesc(descriptions[norm]) "\"" : "null")
    cat  = (norm in categories   && categories[norm]   != "" ? "\"" jesc(categories[norm])   "\"" : "null")
    sev  = (norm in severities   && severities[norm]   != "" ? "\"" jesc(severities[norm])   "\"" : "null")

    pdb_json = (pdb == "" ? "null" : "\"" pdb "\"")
    fs_json  = (fs == "unknown" || fs == "" ? "null" : "\"" fs "\"")
    ls_json  = (ls == ""                    ? "null" : "\"" ls "\"")

    samp_arr = "["
    if (n_smp >= 1 && s0 != "") samp_arr = samp_arr "\"" s0 "\""
    if (n_smp >= 2 && s1 != "") samp_arr = samp_arr ",\"" s1 "\""
    samp_arr = samp_arr "]"

    if (!first) printf ","
    first = 0
    printf "{\"code\":\"%s\",\"pdb_name\":%s,\"description\":%s,\"category\":%s,\"severity\":%s,\"count\":%d,\"first_seen\":%s,\"last_seen\":%s,\"samples\":%s}\n",
        code, pdb_json, desc, cat, sev, cnt, fs_json, ls_json, samp_arr
}
END {
    print "]"
}
')

build_envelope "$TOOL" "$ENV" "$HOST" "$INST" "null" "ok" "$data_json" "null"
