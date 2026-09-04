#!/usr/bin/env bash
# tools/list_known_instances.sh — elenca le istanze Oracle note dal mount NFS per un host
#
# Uso: list_known_instances.sh ENVIRONMENT HOSTNAME
#
# Output JSON:
#   data: array di oggetti {instance_name, volume, alert_log_path, resident}
#
#   resident: true  — l'istanza è attiva su questo host: il suo alert log è stato
#                     modificato di recente (entro RESIDENT_MAX_AGE_DAYS giorni).
#                     Oracle scrive nell'alert log almeno ogni pochi minuti su istanze
#                     operative; un log fermo da mesi appartiene a un'istanza che non
#                     è più residente qui (migrata, shutdown definitivo, cross-mount RAC).
#   resident: false — il log è assente oppure è vecchio (fermo da > RESIDENT_MAX_AGE_DAYS).
#
#   Deduplicazione per duplicati: quando un'istanza appare sotto più volumi (caso
#   comune durante/dopo migrazioni — es. np41cdb0/NP41CDB1 e np41cdb1/NP41CDB1 coesistono)
#   viene mantenuto il volume con il log PIÙ RECENTE (stesso criterio di find_alert_log).
#   Il log vecchio non viene esposto, evitando di mostrare resident=true su log storici.
#
# Note:
#   - Non esegue connessioni SSH né sqlplus: legge solo il filesystem NFS locale.
#   - Se il mount NFS per l'host non è raggiungibile: restituisce log_not_found.
#   - Utile anche quando l'host Oracle è down (SSH non disponibile).

set -uo pipefail

TOOL="list_known_instances"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"

# Soglia di residenza: log non modificato da più di N giorni → resident=false.
# 30 giorni è conservativo: copre manutenzioni estese (patch, vacanze) ma esclude
# i log storici da migrazioni (tipicamente fermi da mesi/anni).
RESIDENT_MAX_AGE_DAYS=30

ENV="${1:-}"
HOST="${2:-}"

# Validazione argomenti
if ! validate_environment "$ENV"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '${ENV}'. Valori accettati: EURO, TEST, CERT, INTE, COLL, PROD" \
        "{\"received\":\"${ENV}\"}"
    exit 2
fi

if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "" "" \
        "invalid_argument" \
        "HOSTNAME obbligatorio" \
        "{\"param\":\"hostname\"}"
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

TIER=$(get_prod_noprod "$ENV")
NFS_HOST_BASE="/unipol/logs/database/oracle/${TIER}/${HOST}"

if [ ! -d "$NFS_HOST_BASE" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "" \
        "log_not_found" \
        "Path NFS non esistente o non raggiungibile: ${NFS_HOST_BASE}" \
        "{\"path\":\"${NFS_HOST_BASE}\"}"
    exit 1
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
NOW_EPOCH=$(date +%s)
RESIDENT_MAX_AGE_SEC=$(( RESIDENT_MAX_AGE_DAYS * 86400 ))

# BUG-06 / R-02: soluzione strutturale basata sull'età del log.
#
# Perché realpath/symlink non funziona:
#   La struttura NFS non usa symlink — ogni istanza ha un path fisico distinto sotto
#   ogni host. Il mount NFS è per VOLUME STORAGE, non per host fisico: i volumi di
#   più istanze vengono montati su tutti gli host del cluster. I log "non residenti"
#   (es. NP43CDB0 sotto axnporadb41) sono file reali, fermi alla data in cui
#   l'istanza era ancora configurata/attiva su quell'host.
#
# Soluzione: età del log come proxy di attività.
#   Oracle scrive nell'alert log ogni pochi minuti (checkpoint, audit, heartbeat).
#   Un log aggiornato di recente → istanza attiva qui → resident=true.
#   Un log fermo da mesi → istanza non più residente → resident=false.
#
# Deduplicazione per log più recente:
#   Quando un'istanza compare sotto più volumi (migrazione: il log vecchio rimane
#   nel volume sorgente, quello nuovo va nel volume destinazione), si sceglie il
#   volume con il log PIÙ RECENTE. Questo evita di esporre il log storico come
#   "residente" quando quello corrente è sotto un altro volume.
#   Implementazione: awk legge il mtime di ogni log via "stat -c %Y" e confronta.

DATA=$(find "$NFS_HOST_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | sort \
    | awk -F'/' -v base="$NFS_HOST_BASE" '
{
    volume  = $(NF-1)
    inst    = $NF
    logfile = base "/" volume "/" inst "/trace/alert_" inst ".log"

    # Legge il mtime del log (epoch) con stat -c %Y (POSIX su Linux/RHEL).
    # Se il file non esiste o stat fallisce: mtime=0.
    mtime = 0
    cmd = "stat -c %Y \"" logfile "\" 2>/dev/null"
    if ((cmd | getline mtime_str) > 0) {
        mtime = mtime_str + 0
    }
    close(cmd)

    # Deduplicazione: per ogni istanza mantiene il volume con il log piu recente.
    if (!(inst in seen) || mtime > best_mtime[inst]) {
        seen[inst]       = 1
        volumes[inst]    = volume
        logs[inst]       = logfile
        mtimes[inst]     = mtime
        best_mtime[inst] = mtime
        if (!(inst in ordered)) {
            order[++n]    = inst
            ordered[inst] = 1
        }
    }
}
END {
    printf "["
    for (i = 1; i <= n; i++) {
        inst  = order[i]
        lf    = logs[inst]
        mtime = mtimes[inst]
        printf "%s{\"instance_name\":\"%s\",\"volume\":\"%s\",\"alert_log_path\":\"%s\",\"log_mtime\":%d}",
            (i > 1 ? "," : ""), inst, volumes[inst], lf, mtime
    }
    printf "]"
}
')

# Post-processing: calcola resident dalla differenza (now - log_mtime).
# resident=true  se log_mtime > 0 E (now - log_mtime) <= RESIDENT_MAX_AGE_SEC.
# resident=false altrimenti (log assente, mtime=0, o troppo vecchio).
# Aggiunge anche log_age_days per trasparenza (utile per diagnostica).
if command -v jq >/dev/null 2>&1; then
    DATA_NEW="["
    first_item=1
    while IFS= read -r row; do
        mtime=$(printf '%s' "$row" | jq -r '.log_mtime // 0')
        if [ "${mtime:-0}" -gt 0 ]; then
            age_sec=$(( NOW_EPOCH - mtime ))
            if [ "$age_sec" -le "$RESIDENT_MAX_AGE_SEC" ]; then
                resident="true"
            else
                resident="false"
            fi
            age_days=$(( age_sec / 86400 ))
        else
            resident="false"
            age_days=-1
        fi
        # Rimuove log_mtime (campo interno) e aggiunge resident + log_age_days
        row=$(printf '%s' "$row" \
            | jq -c --argjson r "$resident" --argjson a "$age_days" \
                'del(.log_mtime) | . + {resident: $r, log_age_days: $a}')
        [ "$first_item" = "1" ] && DATA_NEW="${DATA_NEW}${row}" || DATA_NEW="${DATA_NEW},${row}"
        first_item=0
    done < <(printf '%s\n' "$DATA" | jq -c '.[]' 2>/dev/null)
    DATA_NEW="${DATA_NEW}]"
    DATA="$DATA_NEW"
fi

printf '{"tool":"%s","generated_at":"%s","environment":"%s","hostname":"%s","instance_name":null,"oracle_version":"n/a","status":"ok","data":%s,"error":null}\n' \
    "$TOOL" "$TS" "$ENV" "$HOST" "$DATA"
exit 0
