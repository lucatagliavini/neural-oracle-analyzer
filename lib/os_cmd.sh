#!/usr/bin/env bash
# lib/os_cmd.sh — libreria OS-level per tool di monitoraggio cross-platform (AIX / Linux)
#
# Funzioni pubbliche:
#
#   os_detect HOST
#       → stampa "aix" | "linux" | "unknown"
#         Rileva il sistema operativo remoto via SSH (uname -s). Timeout 5s.
#
#   os_check_cmd HOST CMD
#       → stampa "available" | "missing"
#         Verifica disponibilità di un comando sul target via SSH (which CMD).
#
#   os_sample HOST SAMPLES INTERVAL CMD_AIX CMD_LINUX
#       → stampa le righe di output dei campioni separate da SOH (\001) tra un campione e l'altro
#         Rileva OS, seleziona il comando corretto, esegue N volte con INTERVAL secondi
#         tra un'esecuzione e la successiva, raccoglie stdout.
#         Se SAMPLES × INTERVAL > OS_MAX_SAMPLE_DURATION riduce SAMPLES automaticamente.
#         In caso di errore SSH: stampa su stderr e restituisce exit 1.
#
# Prerequisiti: source lib/oracle_conn.sh prima (riutilizza ORACLE_SSH_KEY e ORACLE_SSH_USER).
#
# Uso: source lib/os_cmd.sh  (da ogni tool OS primitivo)
#
# Note:
#   - I tool NON devono usare set -e. Usare set -uo pipefail + exit $? esplicito.
#   - I comandi da campionare (vmstat, free, df, iostat) girano sul target remoto via SSH;
#     il parsing avviene sempre sull'host MCP (ppc64le RHEL) — awk POSIX per coerenza.
#   - SSH usa le stesse chiavi di oracle_conn.sh (ORACLE_SSH_KEY, ORACLE_SSH_USER).

# --- Configurazione -----------------------------------------------------------

# Durata massima totale campionamento: samples × interval <= OS_MAX_SAMPLE_DURATION
OS_MAX_SAMPLE_DURATION="${OS_MAX_SAMPLE_DURATION:-30}"

# --- Helper SSH ---------------------------------------------------------------

_os_ssh_opts() {
    printf '%s' "-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
}

# --- os_detect ----------------------------------------------------------------

# Rileva il sistema operativo remoto.
# Argomenti: HOST
# Stampa: "aix" | "linux" | "unknown"
# Exit: 0 sempre (unknown se SSH fallisce)
os_detect() {
    local host="$1"
    local ssh_opts
    ssh_opts=$(_os_ssh_opts)
    local uname
    uname=$(ssh $ssh_opts "${ORACLE_SSH_USER}@${host}" "uname -s" 2>/dev/null) || true
    case "$uname" in
        AIX)   echo "aix"   ;;
        Linux) echo "linux" ;;
        *)     echo "unknown" ;;
    esac
}

# --- os_check_cmd -------------------------------------------------------------

# Verifica disponibilità di un comando sul target.
# Argomenti: HOST CMD
# Stampa: "available" | "missing"
# Exit: 0 sempre
os_check_cmd() {
    local host="$1" cmd="$2"
    local ssh_opts
    ssh_opts=$(_os_ssh_opts)
    if ssh $ssh_opts "${ORACLE_SSH_USER}@${host}" "which ${cmd} 2>/dev/null" >/dev/null 2>&1; then
        echo "available"
    else
        echo "missing"
    fi
}

# --- os_sample ----------------------------------------------------------------

# Campiona un comando sul target N volte con intervallo INTERVAL secondi.
# Argomenti: HOST SAMPLES INTERVAL CMD_AIX CMD_LINUX
#
# Stampa su stdout: righe di output dei campioni con \001 come separatore inter-campione.
# Exit: 0 = successo, 1 = errore SSH
#
# Nota: se SAMPLES × INTERVAL > OS_MAX_SAMPLE_DURATION, SAMPLES viene ridotto al massimo
# consentito (floor(OS_MAX_SAMPLE_DURATION / INTERVAL), minimo 1).
os_sample() {
    local host="$1"
    local samples="$2"
    local interval="$3"
    local cmd_aix="$4"
    local cmd_linux="$5"

    # Clamp samples × interval <= OS_MAX_SAMPLE_DURATION
    local max_samples
    if [ "$interval" -gt 0 ]; then
        max_samples=$(( OS_MAX_SAMPLE_DURATION / interval ))
        [ "$max_samples" -lt 1 ] && max_samples=1
        if [ "$samples" -gt "$max_samples" ]; then
            samples="$max_samples"
        fi
    fi

    # Rileva OS
    local os_type
    os_type=$(os_detect "$host")

    local cmd
    case "$os_type" in
        aix)   cmd="$cmd_aix"   ;;
        linux) cmd="$cmd_linux" ;;
        *)
            printf 'os_sample: OS non rilevato su %s\n' "$host" >&2
            return 1
            ;;
    esac

    local ssh_opts
    ssh_opts=$(_os_ssh_opts)

    local i output rc=0
    for i in $(seq 1 "$samples"); do
        # Separatore inter-campione (SOH \001) — non emesso prima del primo campione
        [ "$i" -gt 1 ] && printf '\001'

        output=$(ssh $ssh_opts "${ORACLE_SSH_USER}@${host}" "$cmd" 2>&1) || rc=$?
        if [ $rc -ne 0 ]; then
            printf 'os_sample: SSH/comando fallito su %s (exit %d): %s\n' \
                "$host" "$rc" "$output" >&2
            return 1
        fi
        printf '%s' "$output"

        # Pausa tra campioni (non dopo l'ultimo)
        if [ "$i" -lt "$samples" ] && [ "$interval" -gt 0 ]; then
            sleep "$interval"
        fi
    done

    return 0
}
