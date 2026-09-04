#!/usr/bin/env bash
# tools/os_network_stats.sh — metriche di rete dal server OS via SSH
#
# Uso: os_network_stats.sh ENVIRONMENT HOSTNAME [--samples=N] [--interval=S] [--iface=NAME]
#
# Argomenti posizionali:
#   ENVIRONMENT  — enum: EURO, TEST, CERT, INTE, COLL, PROD
#   HOSTNAME     — hostname fisico del server Oracle
#
# Parametri opzionali:
#   --samples=N    — numero di campioni (default: 5)
#   --interval=S   — secondi tra campioni (default: 2)
#   --iface=NAME   — filtra per una singola interfaccia (es. en0, eth0)
#                    senza filtro: tutte le interfacce attive (no loopback)
#
# Output JSON:
#   data: {
#     os_type: "aix" | "linux",
#     interfaces: [ { iface, rx_bytes_per_sec, tx_bytes_per_sec,
#                     rx_errors, tx_errors, rx_drops, tx_drops } ],
#     samples: [ { ts, iface, rx_bytes_per_sec, tx_bytes_per_sec,
#                  rx_errors, tx_errors, rx_drops, tx_drops } ],
#     summary: { <iface>: { rx_bytes_per_sec: {min,max,avg,p95,p99},
#                            tx_bytes_per_sec: {min,max,avg,p95,p99} } }
#   }
#   instance_name: null
#   oracle_version: null
#
# Comandi usati sul target:
#   AIX:
#     netstat -i            → contatori cumulativi per interfaccia
#     Colonne: Name Mtu Network Address Ipkts Ierrs Opkts Oerrs Coll
#     Nota: ogni interfaccia compare una volta per ogni indirizzo (link#, IP, ...);
#           il parser prende solo la riga con Network ~ /link#/ per evitare duplicati.
#   Linux:
#     cat /proc/net/dev     → contatori cumulativi per interfaccia
#     Colonne: iface: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop ...
#
# Strategia: due chiamate SSH distanziate di INTERVAL secondi per campione,
# calcolo delta bytes/s tramite awk.
# Se INTERVAL=0: un solo campione con bytes/s=0 (solo errori/drop cumulativi).
#
# Nota: loopback (lo, lo0) e interfacce con 0 byte in + out sono escluse.
# Se un'interfaccia non ha dati in nessun campione viene omessa dal summary.

set -uo pipefail

TOOL="os_network_stats"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/oracle_conn.sh
source "${SCRIPT_DIR}/../lib/oracle_conn.sh"
# shellcheck source=../lib/os_cmd.sh
source "${SCRIPT_DIR}/../lib/os_cmd.sh"

# --- Argomenti ----------------------------------------------------------------

ENV="${1:-}"
HOST="${2:-}"
SAMPLES=5
INTERVAL=2
IFACE=""

for arg in "${@:3}"; do
    case "$arg" in
        --samples=*)  SAMPLES="${arg#--samples=}"  ;;
        --interval=*) INTERVAL="${arg#--interval=}" ;;
        --iface=*)    IFACE="${arg#--iface=}"       ;;
    esac
done

# --- Validazione argomenti ----------------------------------------------------

if ! validate_environment "$ENV" 2>/dev/null; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_environment" \
        "ENVIRONMENT non valido: '$ENV'. Valori ammessi: EURO TEST CERT INTE COLL PROD" \
        "{\"received\":\"$ENV\"}"
    exit 2
fi

if [ -z "$HOST" ]; then
    build_error_json "$TOOL" "$ENV" "" "null" \
        "invalid_argument" "HOSTNAME obbligatorio" '{"param":"hostname"}'
    exit 2
fi
# R-10: validazione formato hostname
if ! validate_hostname "$HOST"; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" \
        "HOSTNAME non valido: deve contenere solo lettere minuscole, cifre e trattini" \
        "{\"param\":\"hostname\",\"received\":\"$HOST\"}"
    exit 2
fi

if ! printf '%s' "$SAMPLES" | grep -qE '^[0-9]+$' || [ "$SAMPLES" -lt 1 ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" "--samples deve essere un intero >= 1" '{"param":"samples"}'
    exit 2
fi
if ! printf '%s' "$INTERVAL" | grep -qE '^[0-9]+$' || [ "$INTERVAL" -lt 0 ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "invalid_argument" "--interval deve essere un intero >= 0" '{"param":"interval"}'
    exit 2
fi

# --- Rilevamento OS -----------------------------------------------------------

OS_TYPE=$(os_detect "$HOST")
if [ "$OS_TYPE" = "unknown" ]; then
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "connection_failed" "Impossibile rilevare OS su $HOST (SSH fallito o timeout)" \
        "{\"detail\":\"uname -s ha fallito su $HOST\"}"
    exit 1
fi

# --- Clamping campioni --------------------------------------------------------

if [ "$INTERVAL" -gt 0 ]; then
    MAX_S=$(( OS_MAX_SAMPLE_DURATION / INTERVAL ))
    [ "$MAX_S" -lt 1 ] && MAX_S=1
    [ "$SAMPLES" -gt "$MAX_S" ] && SAMPLES="$MAX_S"
fi

SSH_OPTS="-i ${ORACLE_SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
# B2: ts_start_epoch permette all'awk di calcolare il timestamp di ogni campione.
TS_NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
TS_EPOCH=$(date +%s 2>/dev/null || echo "0")

# --- Costruzione comando per OS -----------------------------------------------

# Su AIX: netstat -In — colonne: Name Mtu Network Address Ipkts Ierrs Opkts Oerrs Coll Drop
# Su Linux: cat /proc/net/dev — formato:
#   iface: rx_bytes rx_pkts rx_errs rx_drop rx_fifo rx_frame rx_compressed rx_multicast
#           tx_bytes tx_pkts tx_errs tx_drop tx_fifo tx_colls tx_carrier tx_compressed

case "$OS_TYPE" in
    aix)
        # netstat -i su AIX mostra totali per interfaccia; si esegue due volte per delta
        # Nota: -I richiede nome interfaccia su AIX → usare -i (senza n, l'output è comunque leggibile)
        CMD_RAW="netstat -i 2>/dev/null"
        ;;
    linux)
        CMD_RAW="cat /proc/net/dev 2>/dev/null"
        ;;
esac

# --- Campionamento: N coppie (t1, t2) distanziate di INTERVAL -----------------
# Ogni campione = due letture (t1 e t2); delta calcolato in awk
# Separatore inter-campione: \001 (SOH)
# Separatore tra t1 e t2 nello stesso campione: __T2__

collect_samples() {
    local i
    for i in $(seq 1 "$SAMPLES"); do
        [ "$i" -gt 1 ] && printf '\001'

        # Prima lettura
        local out1
        out1=$(ssh $SSH_OPTS "${ORACLE_SSH_USER}@${HOST}" "$CMD_RAW" 2>/dev/null) || {
            printf 'os_network_stats: SSH fallito su %s\n' "$HOST" >&2
            return 1
        }
        printf '%s' "$out1"

        # Pausa + seconda lettura (solo se INTERVAL > 0)
        if [ "$INTERVAL" -gt 0 ]; then
            sleep "$INTERVAL"
            local out2
            out2=$(ssh $SSH_OPTS "${ORACLE_SSH_USER}@${HOST}" "$CMD_RAW" 2>/dev/null) || {
                printf 'os_network_stats: SSH fallito su %s (t2)\n' "$HOST" >&2
                return 1
            }
            printf '\n__T2__\n'
            printf '%s' "$out2"
        fi
    done
    return 0
}

RAW_SAMPLES=$(collect_samples) || {
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "connection_failed" "Campionamento rete fallito su $HOST" \
        "{\"detail\":\"collect_samples ha restituito errore\"}"
    exit 1
}

# --- Parsing e aggregazione in awk -------------------------------------------

IFACE_FILTER="$IFACE"
INTERVAL_VAL="$INTERVAL"

JSON=$(printf '%s' "$RAW_SAMPLES" | awk \
    -v os_type="$OS_TYPE" \
    -v ts_base="$TS_NOW" \
    -v ts_epoch="$TS_EPOCH" \
    -v iface_filter="$IFACE_FILTER" \
    -v interval="$INTERVAL_VAL" \
'
BEGIN {
    sample_idx = 0
    section = "t1"   # t1 | t2

    # Per ogni campione accumula t1/t2 per interfaccia
    # Struttura: t1_rx[sample_idx][iface], t1_tx[...], etc.
    # awk non ha array 2D nativi; uso chiave composta "idx:iface"

    nsample_entries = 0   # numero di voci (sample, iface)
    split("", entries)    # entries[n] = "sidx:iface"
    split("", rx_rate)    # rx_rate["sidx:iface"]
    split("", tx_rate)
    split("", rx_err)
    split("", tx_err)
    split("", rx_drp)
    split("", tx_drp)

    # t1 storage per calcolo delta
    split("", t1_rx_b); split("", t1_tx_b)
    split("", t1_rx_e); split("", t1_tx_e)
    split("", t1_rx_d); split("", t1_tx_d)

    split("", seen_ifaces)
    n_ifaces = 0
    # AIX dedup: una riga per iface per campione (link# preferita)
    split("", aix_link_seen)
    split("", aix_ip_seen)
}

# Separatore inter-campione → nuovo campione
$0 == "\001" {
    sample_idx++
    section = "t1"
    next
}

# Separatore t1→t2 nello stesso campione
/^__T2__$/ {
    section = "t2"
    next
}

# ---- AIX: netstat -i ----
os_type == "aix" {
    # Salta righe di intestazione
    if ($1 == "Name" || $1 ~ /^-+$/ || NF < 8) next

    iface = $1
    if (iface ~ /^lo/) next
    if (iface_filter != "" && iface != iface_filter) next

    # AIX netstat -i mostra una riga per ogni indirizzo (link#, IP, ...) della stessa iface.
    # Prendiamo solo la prima occorrenza per campione (riga con link# nel campo Network).
    # Se assente link#, prendiamo la prima riga per la stessa iface in quel campione.
    aix_key_seen = section ":" sample_idx ":" iface
    if ($3 ~ /link#/) {
        # Riga link: contiene i contatori totali hardware — preferita
        aix_link_seen[aix_key_seen] = 1
    } else {
        # Riga IP: se abbiamo già visto la riga link per questa iface, saltiamo
        if (aix_link_seen[aix_key_seen]) next
        # Altrimenti usiamo questa come prima riga disponibile se non già vista
        if (aix_ip_seen[aix_key_seen]) next
        aix_ip_seen[aix_key_seen] = 1
    }

    # Colonne AIX netstat -i:
    # Name Mtu Network Address Ipkts Ierrs Opkts Oerrs Coll
    # $1    $2  $3      $4     $5    $6    $7    $8    $9
    # NOTA: non ha byte-count diretto — usa pacchetti come proxy per delta rate
    rx_p  = $5 + 0
    rx_e  = $6 + 0
    tx_p  = $7 + 0
    tx_e  = $8 + 0
    drp   = 0   # netstat -i AIX non mostra drop separato

    key = sample_idx ":" iface

    if (section == "t1") {
        t1_rx_b[key] = rx_p
        t1_tx_b[key] = tx_p
        t1_rx_e[key] = rx_e
        t1_tx_e[key] = tx_e
        t1_rx_d[key] = drp
        t1_tx_d[key] = drp
    } else {
        # t2: calcola delta
        delta_rx = (rx_p - t1_rx_b[key]) + 0
        delta_tx = (tx_p - t1_tx_b[key]) + 0
        if (delta_rx < 0) delta_rx = 0
        if (delta_tx < 0) delta_tx = 0

        rate_rx = (interval > 0 ? delta_rx / interval : 0)
        rate_tx = (interval > 0 ? delta_tx / interval : 0)

        if (rx_rate[key] == "" ) {
            entries[++nsample_entries] = key
            if (seen_ifaces[iface] == "") { seen_ifaces[iface] = 1; iface_list[++n_ifaces] = iface }
        }
        rx_rate[key] = rate_rx
        tx_rate[key] = rate_tx
        rx_err[key]  = rx_e + 0
        tx_err[key]  = tx_e + 0
        rx_drp[key]  = drp + 0
        tx_drp[key]  = drp + 0
    }
    next
}

# ---- Linux: /proc/net/dev ----
os_type == "linux" {
    # Header: "Inter-| Receive ..." e "face |bytes packets ..."
    if ($0 ~ /^[[:space:]]*Inter/ || $0 ~ /face *\|/) next

    # Formato: "  iface: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop ..."
    if ($0 !~ /:/) next

    split($0, parts, ":")
    iface = parts[1]; gsub(/[[:space:]]/, "", iface)
    if (iface == "" || iface == "lo") next
    if (iface_filter != "" && iface != iface_filter) next

    # Riformatta la parte dati (tutto dopo i ":")
    data_str = parts[2]
    n = split(data_str, cols)
    if (n < 16) next

    # Colonne (1-based nei cols):
    # rx_bytes=1 rx_pkts=2 rx_errs=3 rx_drop=4
    # tx_bytes=9 tx_pkts=10 tx_errs=11 tx_drop=12
    rx_b = cols[1] + 0
    rx_e = cols[3] + 0
    rx_d = cols[4] + 0
    tx_b = cols[9] + 0
    tx_e = cols[11] + 0
    tx_d = cols[12] + 0

    key = sample_idx ":" iface

    if (section == "t1") {
        t1_rx_b[key] = rx_b
        t1_tx_b[key] = tx_b
        t1_rx_e[key] = rx_e
        t1_tx_e[key] = tx_e
        t1_rx_d[key] = rx_d
        t1_tx_d[key] = tx_d
    } else {
        delta_rx = rx_b - t1_rx_b[key]
        delta_tx = tx_b - t1_tx_b[key]
        if (delta_rx < 0) delta_rx = 0
        if (delta_tx < 0) delta_tx = 0

        rate_rx = (interval > 0 ? delta_rx / interval : 0)
        rate_tx = (interval > 0 ? delta_tx / interval : 0)

        if (rx_rate[key] == "") {
            entries[++nsample_entries] = key
            if (seen_ifaces[iface] == "") { seen_ifaces[iface] = 1; iface_list[++n_ifaces] = iface }
        }
        rx_rate[key] = rate_rx
        tx_rate[key] = rate_tx
        rx_err[key]  = rx_e + 0
        tx_err[key]  = tx_e + 0
        rx_drp[key]  = rx_d + 0
        tx_drp[key]  = tx_d + 0
    }
    next
}

# Se interval=0 non ci sono __T2__: usa t1 come unico campione con rate=0
# Aggiunge entry alla fine del file (sezione "t1" finale)
END {
    # Se interval=0 le entry restano in t1_*; le promuoviamo a campioni con rate=0
    if (interval == 0) {
        for (key in t1_rx_b) {
            split(key, kp, ":")
            iface = kp[2]
            if (rx_rate[key] == "") {
                entries[++nsample_entries] = key
                if (seen_ifaces[iface] == "") { seen_ifaces[iface] = 1; iface_list[++n_ifaces] = iface }
            }
            rx_rate[key] = 0
            tx_rate[key] = 0
            rx_err[key]  = t1_rx_e[key] + 0
            tx_err[key]  = t1_tx_e[key] + 0
            rx_drp[key]  = t1_rx_d[key] + 0
            tx_drp[key]  = t1_tx_d[key] + 0
        }
    }

    # Costruzione JSON samples
    samples_json = "["
    first_s = 1
    for (i = 1; i <= nsample_entries; i++) {
        key = entries[i]
        split(key, kp, ":"); sidx = kp[1]; iface = kp[2]
        if (!first_s) samples_json = samples_json ","
        first_s = 0
        # B2: timestamp per campione = start + sidx * interval secondi
        if (ts_epoch > 0) {
            ts_i = strftime("%Y-%m-%dT%H:%M:%S+00:00", ts_epoch + sidx * interval)
        } else {
            ts_i = ts_base
        }
        samples_json = samples_json "{\"ts\":\"" ts_i "\",\"iface\":\"" iface "\""
        samples_json = samples_json ",\"rx_bytes_per_sec\":" sprintf("%.0f", rx_rate[key])
        samples_json = samples_json ",\"tx_bytes_per_sec\":" sprintf("%.0f", tx_rate[key])
        samples_json = samples_json ",\"rx_errors\":" rx_err[key]
        samples_json = samples_json ",\"tx_errors\":" tx_err[key]
        samples_json = samples_json ",\"rx_drops\":" rx_drp[key]
        samples_json = samples_json ",\"tx_drops\":" tx_drp[key] "}"
    }
    samples_json = samples_json "]"

    # Costruzione JSON interfaces (media su tutti i campioni per iface)
    ifaces_json = "["
    first_if = 1
    for (ii = 1; ii <= n_ifaces; ii++) {
        iface = iface_list[ii]
        n_s = 0; sum_rx = 0; sum_tx = 0
        max_rx_e = 0; max_tx_e = 0; max_rx_d = 0; max_tx_d = 0
        for (i = 1; i <= nsample_entries; i++) {
            key = entries[i]
            split(key, kp, ":"); kp_iface = kp[2]
            if (kp_iface != iface) continue
            n_s++
            sum_rx += rx_rate[key]
            sum_tx += tx_rate[key]
            if (rx_err[key] > max_rx_e) max_rx_e = rx_err[key]
            if (tx_err[key] > max_tx_e) max_tx_e = tx_err[key]
            if (rx_drp[key] > max_rx_d) max_rx_d = rx_drp[key]
            if (tx_drp[key] > max_tx_d) max_tx_d = tx_drp[key]
        }
        avg_rx = (n_s > 0 ? sum_rx / n_s : 0)
        avg_tx = (n_s > 0 ? sum_tx / n_s : 0)
        if (!first_if) ifaces_json = ifaces_json ","
        first_if = 0
        ifaces_json = ifaces_json "{\"iface\":\"" iface "\""
        ifaces_json = ifaces_json ",\"rx_bytes_per_sec\":" sprintf("%.0f", avg_rx)
        ifaces_json = ifaces_json ",\"tx_bytes_per_sec\":" sprintf("%.0f", avg_tx)
        ifaces_json = ifaces_json ",\"rx_errors\":" max_rx_e
        ifaces_json = ifaces_json ",\"tx_errors\":" max_tx_e
        ifaces_json = ifaces_json ",\"rx_drops\":" max_rx_d
        ifaces_json = ifaces_json ",\"tx_drops\":" max_tx_d "}"
    }
    ifaces_json = ifaces_json "]"

    # Summary: min/max/avg/p95/p99 per rx_bytes_per_sec e tx_bytes_per_sec per iface
    summary_json = "{"
    first_sum = 1
    for (ii = 1; ii <= n_ifaces; ii++) {
        iface = iface_list[ii]
        n_s = 0
        for (i = 1; i <= nsample_entries; i++) {
            key = entries[i]; split(key, kp, ":")
            if (kp[2] != iface) continue
            n_s++
            rx_arr[n_s] = rx_rate[key]
            tx_arr[n_s] = tx_rate[key]
        }
        if (n_s == 0) continue
        if (!first_sum) summary_json = summary_json ","
        first_sum = 0
        summary_json = summary_json "\"" iface "\":{"
        summary_json = summary_json "\"rx_bytes_per_sec\":" stats_json(rx_arr, n_s) ","
        summary_json = summary_json "\"tx_bytes_per_sec\":" stats_json(tx_arr, n_s) "}"
        delete rx_arr; delete tx_arr
    }
    summary_json = summary_json "}"

    printf "{\"os_type\":\"%s\",\"interfaces\":%s,\"samples\":%s,\"summary\":%s}",
        os_type, ifaces_json, samples_json, summary_json
}

function stats_json(arr, n,    sorted, i, j, tmp, sum, mn, mx, avg, p95, p99) {
    for (i = 1; i <= n; i++) sorted[i] = arr[i] + 0
    for (i = 1; i < n; i++)
        for (j = i+1; j <= n; j++)
            if (sorted[j] < sorted[i]) { tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp }
    sum = 0; mn = sorted[1]; mx = sorted[n]
    for (i = 1; i <= n; i++) sum += sorted[i]
    avg = sum / n
    p95 = percentile(sorted, n, 0.95)
    p99 = percentile(sorted, n, 0.99)
    return sprintf("{\"min\":%.0f,\"max\":%.0f,\"avg\":%.0f,\"p95\":%.0f,\"p99\":%.0f}",
        mn, mx, avg, p95, p99)
}

function percentile(arr, n, p,    idx, frac, lo, hi) {
    if (n == 1) return arr[1]
    idx = p * (n - 1) + 1; lo = int(idx); frac = idx - lo; hi = lo + 1
    if (hi > n) hi = n
    return arr[lo] + frac * (arr[hi] - arr[lo])
}
')

build_envelope "$TOOL" "$ENV" "$HOST" "null" "null" "ok" "[$JSON]" "null"
exit 0
