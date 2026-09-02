#!/usr/bin/env bash
# tools/list_instances_on_host.sh — lista le istanze Oracle (CDB) presenti su un host
#
# Uso: list_instances_on_host.sh ENVIRONMENT HOSTNAME
#
# Output JSON:
#   data: array di oggetti {instance_name, env_path}
#   Ogni elemento corrisponde a un file <INSTANCE>.env nella home oracle dell'host.
#
# Note:
#   - Non esegue sqlplus: usa solo SSH + ls per elencare gli env file CDB.
#   - Il pattern NP*.env corrisponde ai CDB (non ai PDB, che hanno nomi applicativi).
#   - Validato su axnporadb41: restituisce tutti i CDB fisicamente ospitati sull'host.

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

# 3. Recupera lista env file CDB via SSH (non richiede sqlplus)
ssh_opts="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

raw_list=$(ssh $ssh_opts "${ORACLE_SSH_USER}@${HOST}" \
    'ls ~/NP*.env 2>/dev/null || true' 2>/dev/null) || {
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
# Ogni riga: /home/oracle/NP41CDB0.env → {instance_name: "NP41CDB0", env_path: "/home/oracle/NP41CDB0.env"}
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
