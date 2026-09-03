#!/usr/bin/env bash
# tools/os_disk_stats.sh — utilizzo filesystem e I/O disco dal server OS via SSH
#
# Uso: os_disk_stats.sh ENVIRONMENT HOSTNAME [--samples=N] [--interval=S] [--fs=PATH]
#
# Argomenti posizionali:
#   ENVIRONMENT  — enum: EURO, TEST, CERT, INTE, COLL, PROD
#   HOSTNAME     — hostname fisico del server Oracle
#
# Parametri opzionali:
#   --samples=N   — numero di campioni I/O (default: 5)
#   --interval=S  — secondi tra campioni I/O (default: 2)
#   --fs=PATH     — filtra filesystem per mount point (es. /oracle/data)
#
# Output JSON:
#   data: {
#     os_type: "aix" | "linux",
#     filesystems: [ {mount_point, total_bytes, used_bytes, free_bytes, use_pct} ],
#     io_samples:  [ {ts, device, reads_per_sec, writes_per_sec,
#                     read_kb_per_sec, write_kb_per_sec, await_ms} ],
#     io_available: true | false,   # false se iostat non trovato
#     summary: {
#       io: { <device>: { reads_per_sec: {min,max,avg,p95,p99}, ... } }
#     }
#   }
#   instance_name: null
#   oracle_version: null
#
# Comandi usati sul target:
#   df:    df -k (POSIX, entrambi gli OS); filtra per --fs se specificato
#   iostat:
#     AIX:   iostat -d 1 1   → Kbps read/write per device (bos.acct)
#     Linux: iostat -xd 1 1  → r/s, w/s, rkB/s, wkB/s, await per device
#   Se iostat non disponibile: io_samples=[], io_available=false, no errore.

set -uo pipefail

TOOL="os_disk_stats"
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
FS_FILTER=""

for arg in "${@:3}"; do
    case "$arg" in
        --samples=*)  SAMPLES="${arg#--samples=}"  ;;
        --interval=*) INTERVAL="${arg#--interval=}" ;;
        --fs=*)       FS_FILTER="${arg#--fs=}"     ;;
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
TS_NOW=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

# --- Raccolta df (sempre disponibile) -----------------------------------------

# df -k POSIX; filtro su mount point se --fs specificato
if [ -n "$FS_FILTER" ]; then
    DF_CMD="df -k 2>/dev/null | awk 'NR==1 || \$6==\"${FS_FILTER}\"'"
else
    DF_CMD="df -k 2>/dev/null"
fi

DF_RAW=$(ssh $SSH_OPTS "${ORACLE_SSH_USER}@${HOST}" "$DF_CMD" 2>/dev/null) || {
    build_error_json "$TOOL" "$ENV" "$HOST" "null" \
        "connection_failed" "df fallito su $HOST" \
        "{\"detail\":\"SSH exit non-zero per df\"}"
    exit 1
}

FS_JSON=$(printf '%s' "$DF_RAW" | awk '
BEGIN { printf "["; first=1 }
NR == 1 { next }  # salta header
/^Filesystem/ { next }
NF < 5 { next }   # righe malformate / continuazioni
{
    # df -k su Linux: Filesystem  1K-blocks  Used  Available  Use%  Mountpoint
    #   $2=1K-blocks $3=Used $4=Available $5=Use% $6=Mountpoint
    # df -k su AIX:   Filesystem  1024-blocks  Free  %Used  Iused  %Iused  Mounted on
    #   $2=1024-blocks $3=Free $4=%Used $5=Iused $6=%Iused $7=Mounted
    # Heuristica: se $5 contiene "%" → Linux (Use%=$5, mount=$6)
    # altrimenti AIX (%Used=$4, mount=$NF)
    if ($5 ~ /%/) {
        # Linux
        total_kb = $2 + 0
        used_kb  = $3 + 0
        free_kb  = $4 + 0
        use_pct  = $5; sub(/%/, "", use_pct)
        mount    = $6
    } else {
        # AIX: 1024-blocks=$2 (già in KB), Free=$3 (KB), %Used=$4, Mounted=$NF
        total_kb = $2 + 0
        free_kb  = $3 + 0
        used_kb  = total_kb - free_kb
        use_pct  = $4; sub(/%/, "", use_pct)
        mount    = $NF
    }
    # Sanity: use_pct deve essere numerico
    if (use_pct !~ /^[0-9]+$/) use_pct = 0
    if (!first) printf ","
    first = 0
    printf "{\"mount_point\":\"%s\",\"total_bytes\":%d,\"used_bytes\":%d,\"free_bytes\":%d,\"use_pct\":%s}",
        mount, total_kb*1024, used_kb*1024, free_kb*1024, use_pct
}
END { printf "]" }
')

# --- iostat (opzionale) -------------------------------------------------------

IO_AVAILABLE="true"
IO_JSON="[]"
SUMMARY_IO="{}"

IOSTAT_STATUS=$(os_check_cmd "$HOST" "iostat")
if [ "$IOSTAT_STATUS" = "missing" ]; then
    IO_AVAILABLE="false"
else
    case "$OS_TYPE" in
        aix)   CMD_IOSTAT="iostat -d 1 1"   ;;
        linux) CMD_IOSTAT="iostat -xd 1 1"  ;;
    esac

    RAW_IO=$(os_sample "$HOST" "$SAMPLES" "$INTERVAL" \
        "$CMD_IOSTAT" "$CMD_IOSTAT") || {
        # iostat fallito — trattato come non disponibile, non errore fatale
        IO_AVAILABLE="false"
        RAW_IO=""
    }

    if [ "$IO_AVAILABLE" = "true" ] && [ -n "$RAW_IO" ]; then
        IO_PARSE=$(printf '%s' "$RAW_IO" | awk \
            -v os_type="$OS_TYPE" -v ts_base="$TS_NOW" '
BEGIN {
    sample_idx = 0
    hdr_seen = 0
    io_count = 0
    # Col indices (Linux)
    col_dev=-1; col_rs=-1; col_ws=-1; col_rkb=-1; col_wkb=-1; col_await=-1
}

$0 == "\001" { hdr_seen = 0; col_dev=-1; col_rs=-1; col_ws=-1; col_rkb=-1; col_wkb=-1; col_await=-1; sample_idx++; next }
/^$/ { next }
/^Linux/ { next }       # Linux iostat header line
/^Device/ {
    hdr_seen = 1
    if (os_type == "linux") {
        for (i=1; i<=NF; i++) {
            if ($i=="Device")  col_dev=i
            if ($i=="r/s")     col_rs=i
            if ($i=="w/s")     col_ws=i
            if ($i=="rkB/s")   col_rkb=i
            if ($i=="wkB/s")   col_wkb=i
            if ($i=="await")   col_await=i
        }
    }
    next
}

# AIX iostat: "Device: Blks/s Kb/s"
/^Device:/ {
    hdr_seen = 1
    next
}

hdr_seen && /^[a-zA-Z]/ {
    io_count++
    device = $1
    if (os_type == "linux") {
        rs    = (col_rs    > 0 ? $col_rs    : 0)
        ws    = (col_ws    > 0 ? $col_ws    : 0)
        rkb   = (col_rkb   > 0 ? $col_rkb   : 0)
        wkb   = (col_wkb   > 0 ? $col_wkb   : 0)
        await = (col_await > 0 ? $col_await  : 0)
    } else {
        # AIX iostat -d: Device  Kb/s  tps  Kb_read  Kb_written
        rs    = 0; ws = 0
        rkb   = ($2 + 0); wkb = 0
        await = 0
    }
    # Accumula per campione/device
    key = sample_idx "_" device
    data_rs[key]    = rs
    data_ws[key]    = ws
    data_rkb[key]   = rkb
    data_wkb[key]   = wkb
    data_await[key] = await
    devices[device] = 1
}

END {
    # Costruzione samples array
    printf "["
    first_item = 1
    n = sample_idx + 1
    for (i = 0; i < n; i++) {
        for (dev in devices) {
            key = i "_" dev
            if (key in data_rs) {
                if (!first_item) printf ","
                first_item = 0
                printf "{\"ts\":\"%s\",\"device\":\"%s\",\"reads_per_sec\":%.2f,\"writes_per_sec\":%.2f,\"read_kb_per_sec\":%.2f,\"write_kb_per_sec\":%.2f,\"await_ms\":%.2f}",
                    ts_base, dev, data_rs[key], data_ws[key], data_rkb[key], data_wkb[key], data_await[key]
            }
        }
    }
    printf "]"
}
')
        # Estrai array e costruisci summary per device
        IO_JSON=$(printf '%s' "$IO_PARSE" | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Summary I/O per device in awk
        SUMMARY_IO=$(printf '%s' "$RAW_IO" | awk \
            -v os_type="$OS_TYPE" '
BEGIN {
    hdr_seen = 0
    col_dev=-1; col_rs=-1; col_ws=-1; col_rkb=-1; col_wkb=-1; col_await=-1
    sample_idx = 0
}
$0 == "\001" { hdr_seen = 0; col_dev=-1; col_rs=-1; col_ws=-1; col_rkb=-1; col_wkb=-1; col_await=-1; sample_idx++; next }
/^$/ || /^Linux/ { next }
/^Device/ {
    hdr_seen=1
    if (os_type == "linux") {
        for (i=1; i<=NF; i++) {
            if ($i=="Device")  col_dev=i
            if ($i=="r/s")     col_rs=i
            if ($i=="w/s")     col_ws=i
            if ($i=="rkB/s")   col_rkb=i
            if ($i=="wkB/s")   col_wkb=i
            if ($i=="await")   col_await=i
        }
    }
    next
}
/^Device:/ { hdr_seen=1; next }
hdr_seen && /^[a-zA-Z]/ {
    dev = $1
    n_dev[dev]++
    idx = n_dev[dev]
    rs_arr[dev][idx] = (os_type=="linux" && col_rs>0) ? $col_rs+0 : 0
    ws_arr[dev][idx] = (os_type=="linux" && col_ws>0) ? $col_ws+0 : 0
    rkb_arr[dev][idx]= (os_type=="linux" && col_rkb>0) ? $col_rkb+0 : ($2+0)
    wkb_arr[dev][idx]= (os_type=="linux" && col_wkb>0) ? $col_wkb+0 : 0
    aw_arr[dev][idx] = (os_type=="linux" && col_await>0) ? $col_await+0 : 0
    devices[dev]=1
}
END {
    printf "{"
    first_dev=1
    for (dev in devices) {
        n = n_dev[dev]
        if (!first_dev) printf ","
        first_dev=0
        printf "\"%s\":{", dev
        printf "\"reads_per_sec\":%s,",   stats_json(rs_arr[dev], n)
        printf "\"writes_per_sec\":%s,",  stats_json(ws_arr[dev], n)
        printf "\"read_kb_per_sec\":%s,", stats_json(rkb_arr[dev], n)
        printf "\"write_kb_per_sec\":%s,",stats_json(wkb_arr[dev], n)
        printf "\"await_ms\":%s",         stats_json(aw_arr[dev], n)
        printf "}"
    }
    printf "}"
}
function stats_json(arr, n,    sorted, i, j, tmp, sum, mn, mx, avg, p95, p99) {
    if (n == 0) return "{}"
    for (i=1; i<=n; i++) sorted[i]=arr[i]+0
    for (i=1; i<n; i++) for (j=i+1; j<=n; j++) if (sorted[j]<sorted[i]) {tmp=sorted[i];sorted[i]=sorted[j];sorted[j]=tmp}
    sum=0; mn=sorted[1]; mx=sorted[n]
    for (i=1; i<=n; i++) sum+=sorted[i]
    avg=sum/n
    p95=percentile(sorted,n,0.95); p99=percentile(sorted,n,0.99)
    return sprintf("{\"min\":%.2f,\"max\":%.2f,\"avg\":%.2f,\"p95\":%.2f,\"p99\":%.2f}",mn,mx,avg,p95,p99)
}
function percentile(arr,n,p,   idx,frac,lo,hi) {
    if(n==1) return arr[1]
    idx=p*(n-1)+1; lo=int(idx); frac=idx-lo; hi=lo+1; if(hi>n) hi=n
    return arr[lo]+frac*(arr[hi]-arr[lo])
}
')
    fi
fi

# --- Costruzione JSON finale --------------------------------------------------

JSON=$(printf '{"os_type":"%s","filesystems":%s,"io_samples":%s,"io_available":%s,"summary":{"io":%s}}' \
    "$OS_TYPE" "$FS_JSON" "$IO_JSON" "$IO_AVAILABLE" "$SUMMARY_IO")

build_envelope "$TOOL" "$ENV" "$HOST" "null" "null" "ok" "$JSON" "null"
exit 0
