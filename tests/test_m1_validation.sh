#!/usr/bin/env bash
# tests/test_m1_validation.sh — validazione lib/oracle_conn.sh su server reale
# Eseguire su lxprworkerlana01: bash tests/test_m1_validation.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/oracle_conn.sh"
source "$LIB"

HOST="axnporadb41"
INST="NP41CDB0"
ENV="TEST"
PASS=0; FAIL=0

_ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
_chk()  { [ "$1" = "$2" ] && _ok "$3" || _fail "$3 (got: '$1', want: '$2')"; }

echo "=== M1 Validation — lib/oracle_conn.sh ==="
echo ""

# ------------------------------------------------------------------
echo "[1] validate_environment"
validate_environment "TEST"    && _ok "TEST valido"    || _fail "TEST valido"
validate_environment "PROD"    && _ok "PROD valido"    || _fail "PROD valido"
validate_environment "EURO"    && _ok "EURO valido"    || _fail "EURO valido"
validate_environment "INVALID" 2>/dev/null \
    && _fail "INVALID doveva essere rifiutato" \
    || _ok "INVALID rifiutato"

# ------------------------------------------------------------------
echo ""
echo "[2] get_prod_noprod"
_chk "$(get_prod_noprod PROD)" "prod"    "PROD → prod"
_chk "$(get_prod_noprod TEST)" "noprod"  "TEST → noprod"
_chk "$(get_prod_noprod EURO)" "noprod"  "EURO → noprod"
_chk "$(get_prod_noprod COLL)" "noprod"  "COLL → noprod"

# ------------------------------------------------------------------
echo ""
echo "[3] find_alert_log"
log=$(find_alert_log "$HOST" "$INST" "$ENV")
echo "  NP41CDB0: $log"
[ -f "$log" ] && _ok "file esiste" || _fail "file non trovato"

log2=$(find_alert_log "$HOST" "NP41CDB1" "$ENV")
echo "  NP41CDB1: $log2"
[ -f "$log2" ] && _ok "file esiste (più recente scelto)" || _fail "file non trovato"

log3=$(find_alert_log "nonexistent-host-xyz" "NP41CDB0" "$ENV")
[ -z "$log3" ] && _ok "host inesistente → stringa vuota" || _fail "host inesistente doveva dare vuoto"

# ------------------------------------------------------------------
echo ""
echo "[4] build_error_json — oracle_version null (default)"
out=$(build_error_json "mytool" "TEST" "$HOST" "$INST" \
    "connection_failed" "SSH non raggiungibile" '{"detail":"test"}')
echo "  $out"
echo "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert d['oracle_version'] is None, 'oracle_version deve essere null'
assert d['status']=='error'
assert d['error']['code']=='connection_failed'
print('  JSON valido')
" 2>/dev/null && _ok "build_error_json versione null" || _fail "build_error_json versione null"

echo ""
echo "[4b] build_error_json — oracle_version nota (unsupported_version)"
out2=$(build_error_json "mytool" "TEST" "$HOST" "$INST" \
    "unsupported_version" "richiede 12c+" '{"required":"12c+","actual":"11.2.0.4"}' "11.2.0.4.0")
echo "  $out2"
echo "$out2" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert d['oracle_version']=='11.2.0.4.0', f'oracle_version atteso 11.2.0.4.0, got {d[\"oracle_version\"]}'
assert d['error']['code']=='unsupported_version'
print('  JSON valido')
" 2>/dev/null && _ok "build_error_json con versione nota" || _fail "build_error_json con versione nota"

# ------------------------------------------------------------------
echo ""
echo "[5] run_sqlplus_query — query reale su $INST"
raw=$(run_sqlplus_query "$HOST" "$INST" \
    "select instance_name, host_name, version, status from v\$instance")
rc=$?
version=$(printf '%s\n' "$raw" | head -1)
data=$(printf '%s\n' "$raw" | tail -n +2)
echo "  exit: $rc | version: $version"
echo "  data: $data"
[ "$rc" -eq 0 ]                                 && _ok "exit 0"           || _fail "exit 0"
echo "$version" | grep -qE '^[0-9]+\.[0-9]'    && _ok "versione estratta: $version" \
                                                 || _fail "versione non estratta"
echo "$data" | grep -q '"instance_name"'        && _ok "chiave instance_name" \
                                                 || _fail "chiave instance_name mancante"
echo "$data" | grep -q '"NP41CDB0"'             && _ok "valore NP41CDB0"  || _fail "valore NP41CDB0 mancante"

# ------------------------------------------------------------------
echo ""
echo "[6] run_sqlplus_query — host inesistente → exit non-zero"
run_sqlplus_query "nonexistent-host-xyz" "$INST" "select 1 from dual" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && _ok "exit non-zero (got $rc)" || _fail "doveva fallire"

# ------------------------------------------------------------------
echo ""
echo "[7] run_tool — query reale (flusso completo)"
out=$(run_tool "test_tool" "TEST" "$HOST" "$INST" \
    "select instance_name, version from v\$instance")
rc=$?
echo "  exit: $rc"
echo "  output: $out"
[ "$rc" -eq 0 ] && _ok "exit 0" || _fail "exit 0"
echo "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert d['status']=='ok', f'status={d[\"status\"]}'
assert isinstance(d['data'],list) and len(d['data'])>0
assert d['oracle_version'] is not None
assert d['error'] is None
print('  JSON valido, status=ok, data non vuoto, versione presente')
" 2>/dev/null && _ok "envelope run_tool ok" || _fail "envelope run_tool ok"

# ------------------------------------------------------------------
echo ""
echo "[8] run_tool — ENVIRONMENT invalido → invalid_environment, exit 2"
out=$(run_tool "test_tool" "INVALID" "$HOST" "$INST" "select 1 from dual")
rc=$?
echo "  exit: $rc | output: $out"
[ "$rc" -eq 2 ] && _ok "exit 2" || _fail "exit 2 (got $rc)"
echo "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert d['error']['code']=='invalid_environment'
" 2>/dev/null && _ok "error.code=invalid_environment" || _fail "error.code=invalid_environment"

# ------------------------------------------------------------------
echo ""
echo "[9] run_tool — host inesistente → connection_failed, exit 1"
out=$(run_tool "test_tool" "TEST" "nonexistent-host-xyz" "$INST" "select 1 from dual")
rc=$?
echo "  exit: $rc"
[ "$rc" -eq 1 ] && _ok "exit 1" || _fail "exit 1 (got $rc)"
echo "$out" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert d['error']['code']=='connection_failed', f'got {d[\"error\"][\"code\"]}'
assert d['data']==[]
assert d['status']=='error'
" 2>/dev/null && _ok "envelope connection_failed" || _fail "envelope connection_failed"

# ------------------------------------------------------------------
echo ""
echo "================================================"
echo "Risultati: $PASS passati, $FAIL falliti"
[ $FAIL -eq 0 ] && exit 0 || exit 1
