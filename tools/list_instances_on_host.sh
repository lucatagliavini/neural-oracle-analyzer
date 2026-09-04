#!/usr/bin/env bash
# tools/list_instances_on_host.sh — lista le istanze Oracle (CDB) presenti su un host
#
# Uso: list_instances_on_host.sh ENVIRONMENT HOSTNAME
#
# Output JSON:
#   data: array di oggetti {instance_name, env_path}
#   Ogni elemento corrisponde a un file <INSTANCE>.env CDB nella home oracle dell'host.
#
# Note:
#   - Non esegue sqlplus: usa solo SSH + ls+grep per elencare gli env file CDB.
#   - Elenca tutti i *.env, poi esclude quelli con ORACLE_PDB_SID non vuoto (= PDB).
#   - Funziona su tutti gli ambienti (noprod: NP*.env, prod: BPMSPROD.env, PP*.env, ...)

set -uo pipefail
# Nota: set -e non usato — la gestione degli errori avviene esplicitamente
# con build_error_json e codici di uscita gestiti manualmente.

TOOL="list_instances_on_host"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

ENV="${1:-}"
HOST="${2:-}"

# 1. Valida ENVIRONMENT
if ! validate_environment "$ENV" 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '$ENV'. Valori ammessi: EURO TEST CERT INTE COLL PROD" \
        "{\"received\":\"$ENV\"}"
    exit 2
fi

# 2. Valida argomenti
if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_argument" "HOSTNAME obbligatorio" '{"param":"hostname"}'
    exit 2
fi
# R-10: validazione formato hostname
if ! validate_hostname "$HOST"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_argument" \
        "HOSTNAME non valido: deve contenere solo lettere minuscole, cifre e trattini" \
        "{\"param\":\"hostname\",\"received\":\"$HOST\"}"
    exit 2
fi

# 3. Recupera lista env file CDB via SSH (non richiede sqlplus)
#    Logica remota (ksh-compatibile):
#      - ls $HOME/*.env elenca tutti gli env file Oracle
#      - per ciascuno, se ORACLE_PDB_SID è vuoto o assente → è un CDB, lo stampa
#      - i PDB env file hanno ORACLE_PDB_SID impostato al nome del PDB
#    Note ksh/AIX:
#      - grep senza -s (opzione non supportata su AIX)
#      - glob $HOME/*.env senza virgolette (le virgolette inibiscono l'espansione su ksh)
ssh_opts="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

raw_list=$(ssh $ssh_opts "${ORACLE_SSH_USER}@${HOST}" '
for f in $(ls $HOME/*.env 2>/dev/null); do
    [ -f "$f" ] || continue
    pdb_sid=$(grep "^ORACLE_PDB_SID=" "$f" 2>/dev/null | cut -d= -f2 | tr -d " \t\r")
    [ -z "$pdb_sid" ] && printf "%s\n" "$f"
done
' 2>/dev/null) || {
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "connection_failed" \
        "SSH non raggiungibile: ${ORACLE_SSH_USER}@${HOST}" \
        "{\"detail\":\"SSH exit non-zero\"}"
    exit 1
}

# Se SSH è andato ma non ci sono env file (host Oracle senza istanze NP*)
if [ -z "$raw_list" ]; then
    build_envelope "$TOOL" "$ENV" "$HOST" "" "" "ok" "[]" "null"
    exit 0
fi

# 4. Costruisci array JSON da lista di path
# Ogni riga: /home/oracle/BPMSPROD.env → {instance_name: "BPMSPROD", env_path: "/home/oracle/BPMSPROD.env"}
data=$(printf '%s\n' "$raw_list" | awk '
BEGIN { first=1; print "[" }
/\.env$/ {
    path = $0
    # estrai nome file senza directory e senza .env
    n = split(path, parts, "/")
    filename = parts[n]
    sub(/\.env$/, "", filename)
    if (!first) printf ","
    first = 0
    printf "{\"instance_name\":\"%s\",\"env_path\":\"%s\"}", filename, path
}
END { print "]" }
')

build_envelope "$TOOL" "$ENV" "$HOST" "" "" "ok" "$data" "null"
