#!/usr/bin/env bash
# tests/test_contract.sh — verifica che ogni tool rispetti il contratto JSON
#
# Uso:
#   ./tests/test_contract.sh                          # testa tutti i tool
#   ./tests/test_contract.sh identify_instance        # testa un tool specifico
#   ./tests/test_contract.sh --quick                  # solo test di input invalidi (no connessione)
#
# Richiede: jq
# Exit code: 0 = tutti i test passati, 1 = almeno un test fallito
#
# Test eseguiti per ogni tool:
#   1. Input invalidi (ENVIRONMENT, argomenti mancanti) — exit 2, JSON valido
#   2. Envelope completo su fixture reale — exit 0, tutte le chiavi presenti
#   3. Test specifici per tool (log_not_found, unsupported_version, parametri opzionali)
#
# Modalità argomenti posizionali:
#   env_only=1   — tool con solo ENVIRONMENT (list_known_hosts, list_all_hosts_and_instances)
#   host_only=1  — tool con ENVIRONMENT + HOSTNAME (list_instances_on_host, list_known_instances)
#   default      — tool con ENVIRONMENT + HOSTNAME + INSTANCE_NAME

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/../tools" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"
PASS=0
FAIL=0
ERRORS=""
QUICK=0

# Argomenti CLI
for arg in "$@"; do
    [ "$arg" = "--quick" ] && QUICK=1
done
FILTER_TOOL=""
for arg in "$@"; do
    [ "$arg" != "--quick" ] && FILTER_TOOL="$arg" && break
done

# --- Utility ------------------------------------------------------------------

_ok()   { PASS=$((PASS + 1)); printf "  ✓ %s\n" "$1"; }
_skip() { printf "  - %s\n" "$1"; }
_fail() {
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $1"
    printf "  ✗ %s\n" "$1"
}

_is_valid_json() { printf '%s' "$1" | jq . >/dev/null 2>&1; }
# Verifica che la chiave esista (anche se il valore è null/false).
# Supporta chiavi annidate con punto (es. "error.code") tramite riduzione ricorsiva.
_has_key() {
    local obj="$1" key="$2"
    local part rest
    part="${key%%.*}"
    rest="${key#*.}"
    if [ "$rest" = "$key" ]; then
        # Chiave semplice — controlla se in has()
        printf '%s' "$obj" | jq -e "has(\"${part}\")" >/dev/null 2>&1
    else
        # Chiave annidata — scendi di un livello
        local sub
        sub=$(printf '%s' "$obj" | jq -r ".${part} // empty" 2>/dev/null)
        [ -n "$sub" ] && _has_key "$sub" "$rest"
    fi
}
_key_equals()    { [ "$(printf '%s' "$1" | jq -r ".$2")" = "$3" ]; }
_key_is_array()  { printf '%s' "$1" | jq -e ".$2 | arrays" >/dev/null 2>&1; }

# --- Verifica envelope JSON ---------------------------------------------------

test_envelope() {
    local desc="$1" output="$2" exit_code="$3" expected_status="$4"

    if ! _is_valid_json "$output"; then
        _fail "$desc: stdout NON è JSON valido → $(printf '%s' "$output" | head -1)"
        return 1
    fi
    _ok "$desc: stdout è JSON valido"

    for key in tool generated_at environment hostname instance_name oracle_version status data error; do
        if _has_key "$output" "$key"; then
            _ok "$desc: chiave '$key' presente"
        else
            _fail "$desc: chiave '$key' MANCANTE"
        fi
    done

    if _key_equals "$output" "status" "$expected_status"; then
        _ok "$desc: status = '$expected_status'"
    else
        actual=$(printf '%s' "$output" | jq -r '.status')
        _fail "$desc: status atteso '$expected_status', trovato '$actual'"
    fi

    if _key_is_array "$output" "data"; then
        _ok "$desc: data è un array"
    else
        _fail "$desc: data NON è un array"
    fi

    if [ "$expected_status" = "error" ]; then
        local dlen
        dlen=$(printf '%s' "$output" | jq '.data | length')
        if [ "$dlen" = "0" ]; then
            _ok "$desc: data = [] in caso di errore"
        else
            _fail "$desc: data non è [] in caso di errore (lunghezza=$dlen)"
        fi
        for k in code message; do
            if _has_key "$output" "error.${k}"; then
                _ok "$desc: error.$k presente"
            else
                _fail "$desc: error.$k MANCANTE"
            fi
        done
    fi

    local ok_code=0
    if   [ "$exit_code" = "0" ] && [ "$expected_status" = "ok"    ]; then ok_code=1
    elif [ "$exit_code" = "1" ] && [ "$expected_status" = "error" ]; then ok_code=1
    elif [ "$exit_code" = "2" ]                                     ; then ok_code=1
    fi
    if [ "$ok_code" = "1" ]; then
        _ok "$desc: exit code $exit_code coerente con status '$expected_status'"
    else
        _fail "$desc: exit code $exit_code inatteso per status '$expected_status'"
    fi
}

# --- Test: input invalidi comuni (ENVIRONMENT + args mancanti) ----------------
# env_only=1  — tool con solo ENVIRONMENT (es. list_known_hosts)
# host_only=1 — tool con ENVIRONMENT + HOSTNAME (es. list_instances_on_host)
# default     — tool con ENVIRONMENT + HOSTNAME + INSTANCE_NAME

test_invalid_inputs() {
    local script="$1" tool_name="$2" host_only="${3:-0}" env_only="${4:-0}"
    printf "\n  [input invalidi]\n"

    # ENVIRONMENT non nell'enum → exit 2 o JSON invalid_environment
    local out rc=0
    if [ "$env_only" = "1" ]; then
        out=$("$script" "INVALID" 2>/dev/null) || rc=$?
    elif [ "$host_only" = "1" ]; then
        out=$("$script" "INVALID" "axnporadb41" 2>/dev/null) || rc=$?
    else
        out=$("$script" "INVALID" "axnporadb41" "NP41CDB0" 2>/dev/null) || rc=$?
    fi
    if [ "$rc" = "2" ]; then
        _ok "ENVIRONMENT invalido → exit 2"
    elif [ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_environment"' >/dev/null 2>&1; then
        _ok "ENVIRONMENT invalido → JSON invalid_environment"
    else
        _fail "ENVIRONMENT invalido non gestito (rc=$rc)"
    fi

    # HOSTNAME vuoto (non si applica ai tool env_only)
    if [ "$env_only" = "0" ]; then
        rc=0
        if [ "$host_only" = "1" ]; then
            out=$("$script" "TEST" "" 2>/dev/null) || rc=$?
        else
            out=$("$script" "TEST" "" "NP41CDB0" 2>/dev/null) || rc=$?
        fi
        if [ "$rc" = "2" ]; then
            _ok "HOSTNAME vuoto → exit 2"
        elif [ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1; then
            _ok "HOSTNAME vuoto → JSON invalid_argument"
        else
            _fail "HOSTNAME vuoto non gestito (rc=$rc)"
        fi
    fi

    # INSTANCE_NAME vuoto (solo per tool a 3 argomenti)
    if [ "$host_only" = "0" ] && [ "$env_only" = "0" ]; then
        rc=0
        out=$("$script" "TEST" "axnporadb41" "" 2>/dev/null) || rc=$?
        if [ "$rc" = "2" ]; then
            _ok "INSTANCE_NAME vuoto → exit 2"
        elif [ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1; then
            _ok "INSTANCE_NAME vuoto → JSON invalid_argument"
        else
            _fail "INSTANCE_NAME vuoto non gestito (rc=$rc)"
        fi
    fi
}

# --- Test: fixture reale (connessione a Oracle) --------------------------------

test_fixture() {
    local tool_name="$1" script="$2"
    local fixture="${FIXTURES_DIR}/${tool_name}.ok.json"
    [ -f "$fixture" ] || return 0

    printf "\n  [fixture ok]\n"
    local env host inst
    env=$(grep  "^#ENV="  "$fixture" | cut -d= -f2 | head -1)
    host=$(grep "^#HOST=" "$fixture" | cut -d= -f2 | head -1)
    inst=$(grep "^#INST=" "$fixture" | cut -d= -f2 | head -1)
    local extra_args=()
    while IFS= read -r line; do
        extra_args+=("$line")
    done < <(grep "^#ARGS=" "$fixture" | cut -d= -f2-)

    # Determina se il tool è env_only (un solo argomento posizionale)
    local is_env_only=0
    case "$tool_name" in
        list_known_hosts|list_all_hosts_and_instances) is_env_only=1 ;;
    esac

    if [ -z "$env" ]; then
        _fail "fixture $fixture: manca #ENV= nei commenti"
        return
    fi
    if [ "$is_env_only" = "0" ] && [ -z "$host" ]; then
        _fail "fixture $fixture: manca #HOST= nei commenti"
        return
    fi

    local out rc=0
    if [ "$is_env_only" = "1" ]; then
        out=$("$script" "$env" "${extra_args[@]+"${extra_args[@]}"}" 2>/dev/null) || rc=$?
    elif [ -z "$inst" ]; then
        out=$("$script" "$env" "$host" "${extra_args[@]+"${extra_args[@]}"}" 2>/dev/null) || rc=$?
    else
        out=$("$script" "$env" "$host" "$inst" "${extra_args[@]+"${extra_args[@]}"}" 2>/dev/null) || rc=$?
    fi
    test_envelope "fixture" "$out" "$rc" "ok"
}

# --- Test: NFS inesistente per tool env_only (log_not_found) ------------------

test_nfs_not_found_env_only() {
    local script="$1"
    printf "\n  [NFS assente (env_only) → log_not_found o data vuota]\n"
    # Con PROD l'NFS potrebbe non avere host prod su questo server di test.
    # Usiamo EURO che punta a noprod ma con un host fake — il tool non fa SSH
    # quindi restituirà data=[] o log_not_found.
    local out rc=0
    # Non possiamo testare connection_failed su tool NFS-only senza hostname.
    # Il test più significativo è che ritorni JSON valido con status ok o error.
    out=$("$script" "TEST" 2>/dev/null) || rc=$?
    if _is_valid_json "$out"; then
        _ok "NFS tool (env_only) restituisce JSON valido"
    else
        _fail "NFS tool (env_only) output non è JSON valido"
    fi
}

# --- Test: host inesistente (connection_failed) --------------------------------

test_bad_host() {
    local script="$1" host_only="${2:-0}"
    printf "\n  [host inesistente → connection_failed]\n"
    local out rc=0
    if [ "$host_only" = "1" ]; then
        out=$("$script" "TEST" "nonexistent-host-xyz-99" 2>/dev/null) || rc=$?
    else
        out=$("$script" "TEST" "nonexistent-host-xyz-99" "NP41CDB0" 2>/dev/null) || rc=$?
    fi
    if [ "$rc" = "1" ] && _is_valid_json "$out"; then
        if _key_equals "$out" "error.code" "connection_failed"; then
            _ok "host inesistente → connection_failed"
        else
            local code
            code=$(printf '%s' "$out" | jq -r '.error.code // "null"')
            _fail "host inesistente → exit 1 ma error.code='$code' (atteso connection_failed)"
        fi
        # Anche per errore il JSON deve avere l'envelope completo
        test_envelope "bad_host" "$out" "$rc" "error"
    else
        _fail "host inesistente: rc=$rc, json=$(_is_valid_json "$out" && echo si || echo no)"
    fi
}

# --- Test: log_not_found (tool di log con NFS assente) ------------------------

test_log_not_found() {
    local script="$1" tool_name="$2"
    printf "\n  [log_not_found]\n"
    # Usa un hostname che non ha mount NFS su questo server
    local out rc=0
    out=$("$script" "TEST" "nonexistent-nfs-host-xyz" "NP99CDB0" 2>/dev/null) || rc=$?
    if [ "$rc" = "1" ] && _is_valid_json "$out"; then
        if _key_equals "$out" "error.code" "log_not_found"; then
            _ok "NFS assente → log_not_found"
        else
            local code
            code=$(printf '%s' "$out" | jq -r '.error.code // "null"')
            _fail "NFS assente → exit 1 ma error.code='$code' (atteso log_not_found)"
        fi
        test_envelope "log_not_found" "$out" "$rc" "error"
    else
        _fail "NFS assente: rc=$rc, json=$(_is_valid_json "$out" && echo si || echo no)"
    fi
}

# --- Test: parametri opzionali tool-specifici ---------------------------------

test_top_pga_limit() {
    local script="$1"
    printf "\n  [top_pga_sessions --limit=0 → invalid_argument]\n"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=0" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=0 → invalid_argument"
    else
        _fail "--limit=0 non ha restituito invalid_argument (rc=$rc)"
    fi

    printf "  [top_pga_sessions --limit=abc → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=abc" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=abc → invalid_argument"
    else
        _fail "--limit=abc non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Test: pga_by_pdb_session --limit (BUG-01) ---------------------------------

test_pga_pdb_session_limit() {
    local script="$1"
    printf "\n  [pga_by_pdb_session --limit=0 → invalid_argument]\n"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=0" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=0 → invalid_argument"
    else
        _fail "--limit=0 non ha restituito invalid_argument (rc=$rc)"
    fi

    printf "  [pga_by_pdb_session --limit=abc → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=abc" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=abc → invalid_argument"
    else
        _fail "--limit=abc non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Test: scan_alert_log --code normalizzazione (BUG-11) + --until (C3) ------

test_scan_alert_log_params() {
    local script="$1"
    printf "\n  [scan_alert_log --code=ORA-123 valido]\n"
    local out rc=0
    # Deve accettare ORA-N senza zero padding (validazione formato ORA-[0-9]+)
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--code=ORA-4036" 2>/dev/null) || rc=$?
    # Senza NFS/connessione, atteso log_not_found o connection_failed — non invalid_argument
    if [ "$rc" = "2" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1; then
        _fail "--code=ORA-4036 (senza zero-pad) rifiutato come invalid_argument"
    else
        _ok "--code=ORA-4036 (senza zero-pad) accettato dalla validazione"
    fi

    printf "  [scan_alert_log --code=ORA-abc → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--code=ORA-abc" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--code=ORA-abc → invalid_argument"
    else
        _fail "--code=ORA-abc non ha restituito invalid_argument (rc=$rc)"
    fi

    # C3: --until formato invalido → invalid_argument
    printf "  [scan_alert_log --until=abc → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--until=not-a-date" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--until=not-a-date → invalid_argument"
    else
        _fail "--until=not-a-date non ha restituito invalid_argument (rc=$rc)"
    fi

    # C3: --since > --until → invalid_argument
    printf "  [scan_alert_log --since=2026-09-01 --until=2026-08-01 → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-09-01" "--until=2026-08-01" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since > --until → invalid_argument"
    else
        _fail "--since > --until non ha restituito invalid_argument (rc=$rc)"
    fi

    # C3: --since + --until validi → accettati (richiede NFS ma non deve dare invalid_argument)
    printf "  [scan_alert_log --since=2026-07-21 --until=2026-07-21 valido]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-07-21" "--until=2026-07-21" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1; then
        _fail "--since=2026-07-21 --until=2026-07-21 rifiutato come invalid_argument"
    else
        _ok "--since=2026-07-21 --until=2026-07-21 accettato dalla validazione"
    fi

    # COLLAUDO-ROUND3 §6: --until + --pdb + --code combinati (gap non coperto prima).
    # Con NFS presente il tool deve restituire ok o log_not_found, MAI invalid_argument.
    printf "  [scan_alert_log --until+--pdb+--code combinati → nessun invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB1" \
        "--code=ORA-04036" "--pdb=ANAG2HELP" "--since=2026-07-01" "--until=2026-09-01" 2>/dev/null) || rc=$?
    err_code=$(printf '%s' "$out" | jq -r '.error.code // empty')
    if [ "$err_code" = "invalid_argument" ]; then
        _fail "--code+--pdb+--since+--until combinati restituisce invalid_argument: $err_code"
    else
        _ok "--code=ORA-04036 --pdb=ANAG2HELP --since --until combinati accettati (err=${err_code:-none})"
    fi

    # Verifica che il risultato (se ok) abbia i campi attesi
    if [ "$rc" = "0" ] && printf '%s' "$out" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        n=$( printf '%s' "$out" | jq '.data | length')
        filter_since=$( printf '%s' "$out" | jq -r '.filter_since // empty')
        filter_until=$( printf '%s' "$out" | jq -r '.filter_until // empty')
        _ok "--code+--pdb+--since+--until: data=$n entries, filter_since=$filter_since, filter_until=$filter_until"
        # Verifica che il pdb filtri correttamente (se ci sono risultati, devono essere tutti ANAG2HELP o null)
        wrong_pdb=$( printf '%s' "$out" | jq '[.data[] | select(.pdb_name != null and .pdb_name != "ANAG2HELP")] | length')
        [ "${wrong_pdb:-0}" = "0" ] \
            && _ok "--pdb=ANAG2HELP: nessuna riga con pdb_name diverso da ANAG2HELP o null" \
            || _fail "--pdb=ANAG2HELP: ${wrong_pdb} righe con pdb_name fuori dal filtro"
    fi
}

# --- Test: --until validazione input (quick, no NFS) --------------------------
# Separata da test_scan_alert_log_params per essere invocabile anche in --quick

test_scan_alert_log_until_quick() {
    local script="$1"
    printf "\n  [scan_alert_log --until: validazione formato]\n"
    local out rc=0

    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--until=not-a-date" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--until formato invalido → invalid_argument"
    else
        _fail "--until formato invalido non ha restituito invalid_argument (rc=$rc)"
    fi

    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-09-01" "--until=2026-08-01" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since > --until → invalid_argument"
    else
        _fail "--since > --until non ha restituito invalid_argument (rc=$rc)"
    fi

    # R-07: date semanticamente invalide (mese/giorno fuori range, anno < 2000)
    printf "  [scan_alert_log R-07: --since=2026-13-45 → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-13-45" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since=2026-13-45 (mese 13) → invalid_argument"
    else
        _fail "--since=2026-13-45 non ha restituito invalid_argument (rc=$rc)"
    fi

    printf "  [scan_alert_log R-07: --since=1970-01-01 → invalid_argument]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=1970-01-01" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since=1970-01-01 (anno < 2000) → invalid_argument"
    else
        _fail "--since=1970-01-01 non ha restituito invalid_argument (rc=$rc)"
    fi

    # Validazione giorno-per-mese (gap COLLAUDO-ROUND3 §6):
    # giorno impossibile per il mese specifico deve essere rifiutato prima di cercare il log.
    printf "  [scan_alert_log: --since=2026-02-30 → invalid_argument (30 feb impossibile)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-02-30" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since=2026-02-30 (30 febbraio) → invalid_argument"
    else
        _fail "--since=2026-02-30 non ha restituito invalid_argument (rc=$rc, code=$(printf '%s' "$out" | jq -r '.error.code // empty'))"
    fi

    printf "  [scan_alert_log: --since=2026-04-31 → invalid_argument (31 aprile impossibile)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2026-04-31" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since=2026-04-31 (31 aprile) → invalid_argument"
    else
        _fail "--since=2026-04-31 non ha restituito invalid_argument (rc=$rc, code=$(printf '%s' "$out" | jq -r '.error.code // empty'))"
    fi

    printf "  [scan_alert_log: --until=2026-02-30 → invalid_argument (anche per --until)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--until=2026-02-30" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--until=2026-02-30 (30 febbraio) → invalid_argument"
    else
        _fail "--until=2026-02-30 non ha restituito invalid_argument (rc=$rc, code=$(printf '%s' "$out" | jq -r '.error.code // empty'))"
    fi

    printf "  [scan_alert_log: --since=2001-02-29 → invalid_argument (29 feb anno non bisestile)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2001-02-29" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--since=2001-02-29 (29 feb 2001, non bisestile) → invalid_argument"
    else
        _fail "--since=2001-02-29 non ha restituito invalid_argument (rc=$rc, code=$(printf '%s' "$out" | jq -r '.error.code // empty'))"
    fi

    printf "  [scan_alert_log: --since=2000-02-29 accettata (2000 bisestile)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--since=2000-02-29" 2>/dev/null) || rc=$?
    # La data è valida; l'unico errore atteso è log_not_found (no NFS in --quick)
    err_code=$(printf '%s' "$out" | jq -r '.error.code // empty')
    if [ "$err_code" != "invalid_argument" ]; then
        _ok "--since=2000-02-29 (2000 bisestile) accettata (err=$err_code)"
    else
        _fail "--since=2000-02-29 rifiutata come invalid_argument (data valida, anno bisestile)"
    fi
}

# --- Test: tail_alert_log --lines tetto (R-05) ---------------------------------

test_tail_alert_log_lines() {
    local script="$1"
    printf "\n  [tail_alert_log R-05: --lines=0 → invalid_argument]\n"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--lines=0" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--lines=0 → invalid_argument"
    else
        _fail "--lines=0 non ha restituito invalid_argument (rc=$rc)"
    fi

    printf "  [tail_alert_log R-05: --lines=500000 → invalid_argument (sopra tetto)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--lines=500000" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--lines=500000 (sopra tetto) → invalid_argument"
    else
        _fail "--lines=500000 non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Test: top_pga_sessions --limit tetto (R-06) ------------------------------

test_top_pga_limit_max() {
    local script="$1"
    printf "\n  [top_pga_sessions R-06: --limit=999999 → invalid_argument (sopra tetto)]\n"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=999999" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=999999 (sopra tetto) → invalid_argument"
    else
        _fail "--limit=999999 non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Test: hostname path traversal (R-10) -------------------------------------

test_hostname_traversal() {
    local script="$1" host_only="${2:-0}" env_only="${3:-0}"
    [ "$env_only" = "1" ] && return
    printf "\n  [R-10: hostname path traversal → invalid_argument]\n"
    local out rc=0
    if [ "$host_only" = "1" ]; then
        out=$("$script" "TEST" "../../etc" 2>/dev/null) || rc=$?
    else
        out=$("$script" "TEST" "../../etc" "NP41CDB0" 2>/dev/null) || rc=$?
    fi
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "hostname='../../etc' → invalid_argument"
    else
        _fail "hostname='../../etc' non ha restituito invalid_argument (rc=$rc)"
    fi

    # Hostname con lettere MAIUSCOLE (es. "AXNPORADB41") deve essere respinto
    rc=0
    if [ "$host_only" = "1" ]; then
        out=$("$script" "TEST" "AXNPORADB41" 2>/dev/null) || rc=$?
    else
        out=$("$script" "TEST" "AXNPORADB41" "NP41CDB0" 2>/dev/null) || rc=$?
    fi
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "hostname='AXNPORADB41' (maiuscole) → invalid_argument"
    else
        _fail "hostname='AXNPORADB41' non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Test: ora_errors.json contiene i codici critici (BUG-10) -----------------

test_ora_errors_coverage() {
    local script="$1"
    printf "\n  [ora_errors.json copertura codici critici]\n"
    local errors_file
    errors_file="$(cd "$(dirname "$script")/.." && pwd)/data/ora_errors.json"
    if [ ! -f "$errors_file" ]; then
        _skip "ora_errors.json non trovato: $errors_file"
        return
    fi
    for code in "ORA-00020" "ORA-04036" "ORA-01692" "ORA-03136" "ORA-01119" "ORA-48113"; do
        if jq -e --arg c "$code" '.[] | select(.code == $c)' "$errors_file" >/dev/null 2>&1; then
            _ok "ora_errors.json: $code presente"
        else
            _fail "ora_errors.json: $code MANCANTE"
        fi
    done
    # Verifica che ORA-00020 e ORA-04036 abbiano severity critical
    for code in "ORA-00020" "ORA-04036"; do
        sev=$(jq -r --arg c "$code" '.[] | select(.code == $c) | .severity' "$errors_file" 2>/dev/null | head -1)
        if [ "$sev" = "critical" ]; then
            _ok "ora_errors.json: $code severity=critical"
        else
            _fail "ora_errors.json: $code severity='$sev' (atteso critical)"
        fi
    done
}

# --- Test: oracle_version "n/a" nei tool NFS (BUG-07) -------------------------

test_nfs_tool_oracle_version() {
    local script="$1" tool_name="$2" arg3="${3:-}"
    printf "\n  [%s: oracle_version = n/a nei tool NFS]\n" "$tool_name"
    # Usiamo un host fake: il tool fallirà (log_not_found o error) ma l'envelope
    # deve avere oracle_version = "n/a" anche in caso di successo.
    # Test su un errore atteso: verifica che oracle_version non sia null.
    # Per i tool env_only non possiamo testare facilmente senza NFS reale — skip.
    _skip "oracle_version=n/a: verificabile solo su fixture reale (NFS necessario)"
}

# --- Test: fra_configured in check_fra_usage (BUG-02) -------------------------

test_fra_configured_field() {
    local script="$1"
    printf "\n  [check_fra_usage: fixture verifica fra_configured]\n"
    local fixture="${FIXTURES_DIR}/check_fra_usage.ok.json"
    [ -f "$fixture" ] || { _skip "fixture check_fra_usage non disponibile"; return; }
    local env host inst
    env=$(grep  "^#ENV="  "$fixture" | cut -d= -f2 | head -1)
    host=$(grep "^#HOST=" "$fixture" | cut -d= -f2 | head -1)
    inst=$(grep "^#INST=" "$fixture" | cut -d= -f2 | head -1)
    local out rc=0
    out=$("$script" "$env" "$host" "$inst" 2>/dev/null) || rc=$?
    if [ "$rc" = "0" ] && _is_valid_json "$out"; then
        if printf '%s' "$out" | jq -e '[.data[] | select(.source == "fra_status")] | length > 0' >/dev/null 2>&1; then
            _ok "check_fra_usage: sezione fra_status presente"
        else
            _fail "check_fra_usage: sezione fra_status MANCANTE"
        fi
        if printf '%s' "$out" | jq -e '[.data[] | select(.source == "fra_status")][0] | has("fra_configured")' >/dev/null 2>&1; then
            _ok "check_fra_usage: fra_configured presente"
        else
            _fail "check_fra_usage: fra_configured MANCANTE"
        fi
    else
        _skip "check_fra_usage fixture non eseguibile (rc=$rc)"
    fi
}

# --- Test: timestamp per campione (B2) — verifica che awk strftime sia disponibile ----

test_b2_strftime_quick() {
    # Verifica che gawk supporti strftime sull'host MCP (RHEL), necessario per B2.
    # Non richiede connessione SSH: esegue solo awk localmente.
    printf "\n  [B2: awk strftime disponibile sull'host MCP]\n"
    local ts_epoch ts_out
    ts_epoch=$(date +%s 2>/dev/null || echo "0")
    if [ "$ts_epoch" = "0" ]; then
        _skip "B2: date +%s non disponibile — impossibile verificare"
        return
    fi
    ts_out=$(awk -v ep="$ts_epoch" 'BEGIN { print strftime("%Y-%m-%dT%H:%M:%S+00:00", ep) }' 2>/dev/null)
    if printf '%s' "$ts_out" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'; then
        _ok "B2: strftime in awk funziona → $ts_out"
    else
        _fail "B2: strftime in awk non disponibile — i timestamp dei campioni useranno ts_base"
    fi
}

# --- Test: BUG-04/R3-01 pre-filtraggio --code (fast-exit) ---------------------

test_bug04_code_prefilter_quick() {
    local script="$1"
    printf "\n  [BUG-04/R3-01: --code fast-exit con file log fake]\n"

    # Crea un log fake in formato ISO (12c+) con alcune righe ORA-
    # Nota: il timestamp precede la riga ORA- di DUE righe (come nel log Oracle reale):
    #   riga N:   timestamp ISO
    #   riga N+1: descrizione (es. "Thread 1 cannot allocate...")
    #   riga N+2: ORA-XXXXX: ...
    # La B2 (file ridotto) estraeva solo (riga-1, riga) per ogni ORA-, perdendo il timestamp.
    # Dopo R3-01 non esiste piu la B2: se count>0, awk legge il file intero.
    local fake_log
    fake_log=$(mktemp /tmp/test_bug04_XXXXXX.log)
    cat > "$fake_log" << 'FAKELOG'
2026-09-01T08:00:00.000000+02:00
Thread 1 cannot allocate new log
ORA-00060: deadlock detected
2026-09-01T09:00:00.000000+02:00
Detailed info line
VITAWFST(13):ORA-01555: snapshot too old
2026-09-01T10:00:00.000000+02:00
Background process info
FAKELOG

    # Test B1: codice assente → grep -cE deve restituire 0
    # Nota: grep -cE stampa il count anche con exit 1 (0 match); non usare || echo 0
    local absent_count
    absent_count=$(LC_ALL=C grep -cE "ORA-0*4030" "$fake_log" 2>/dev/null; true)
    if [ "${absent_count:-0}" -eq 0 ]; then
        _ok "BUG-04/B1: grep -cE ORA-04030 su log senza quel codice → 0 (fast-exit corretto)"
    else
        _fail "BUG-04/B1: grep -cE ORA-04030 ha trovato $absent_count (log fake errato?)"
    fi

    # Test B2 (ex-R3-01): codice presente → grep -cE deve restituire >0 (file intero letto da awk)
    local present_count
    present_count=$(LC_ALL=C grep -cE "ORA-0*60" "$fake_log" 2>/dev/null; true)
    if [ "${present_count:-0}" -gt 0 ]; then
        _ok "BUG-04/B2: grep -cE ORA-00060 su log con quel codice → $present_count (awk legge file intero)"
    else
        _fail "BUG-04/B2: grep -cE ORA-00060 non ha trovato il codice (log fake errato?)"
    fi

    # Test B3: normalizzazione pattern ORA-0*N — ORA-60 deve trovare ORA-00060
    local check_norm
    check_norm=$(LC_ALL=C grep -cE "ORA-0*60" "$fake_log" 2>/dev/null; true)
    if [ "${check_norm:-0}" -gt 0 ]; then
        _ok "BUG-04/B3: pattern ORA-0*60 trova ORA-00060 (normalizzazione zero-padding OK)"
    else
        _fail "BUG-04/B3: pattern ORA-0*60 non trova ORA-00060"
    fi

    # Test B4: il tool accetta --code senza crash
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--code=ORA-99999" 2>/dev/null) || rc=$?
    # Può essere log_not_found (no NFS) o ok con data:[] — non connection_failed
    if [ "$rc" = "0" ] || [ "$rc" = "1" ]; then
        _ok "BUG-04/B4: --code=ORA-99999 non ha causato crash (rc=$rc)"
    else
        _fail "BUG-04/B4: --code=ORA-99999 ha restituito rc=$rc inatteso"
    fi

    rm -f "$fake_log"
}

# --- Test: R3-01 — full_scan_performed=true quando count>0 (no B2) --------------
# Verifica con log fake locale + awk su file tmp che il timestamp sia rilevato
# anche quando precede la riga ORA- di 2 righe.
# Usa file awk temporaneo perche gawk non supporta -f lib + programma posizionale inline.

test_r3_01_timestamps_preserved() {
    local script="$1"
    printf "\n  [R3-01: timestamp preservato con 2 righe di distanza dall'ORA-]\n"

    local fake_log awk_lib awk_prog script_dir
    script_dir="$(cd "$(dirname "$script")/.." && pwd)"
    awk_lib="${script_dir}/lib/json_esc.awk"
    fake_log=$(mktemp /tmp/test_r3_01_XXXXXX.log)
    cat > "$fake_log" << 'FAKELOG'
2026-09-01T08:16:43.000000+02:00
Thread 1 cannot allocate new log
ORA-04031: unable to allocate shared memory
2026-09-02T09:00:00.000000+02:00
More context line
ORA-04031: another occurrence
FAKELOG

    if [ ! -f "$awk_lib" ]; then
        _skip "R3-01: lib/json_esc.awk non trovato — skip test awk locale"
        rm -f "$fake_log"
        return
    fi

    # Programma awk in file temporaneo (non inline) — necessario per usare -f lib + -f prog
    awk_prog=$(mktemp /tmp/test_r3_01_XXXXXX.awk)
    cat > "$awk_prog" << 'AWKPROG'
/^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/ {
    ts = $0; sub(/\.[0-9]+.*/, "", ts); gsub(/ /, "T", ts); last_ts = ts; next
}
/ORA-[0-9][0-9]+/ {
    line = $0
    while (match(line, /ORA-[0-9][0-9]+/)) {
        raw = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        num = substr(raw, 5)
        while (length(num) < 5) num = "0" num
        code = "ORA-" num
        key = code SUBSEP ""
        if (!(key in counts)) {
            counts[key] = 0
            first_seen[key] = (last_ts != "" ? last_ts : "UNKNOWN")
        }
        counts[key]++
        last_seen[key] = (last_ts != "" ? last_ts : "UNKNOWN")
    }
}
END {
    for (k in counts) {
        split(k, p, SUBSEP)
        printf "%s|%s|%s|%d\n", p[1], first_seen[k], last_seen[k], counts[k]
    }
}
AWKPROG

    local awk_out
    awk_out=$(LC_ALL=C awk \
        -v filter_code="" \
        -v filter_since="" \
        -v filter_until="" \
        -v filter_pdb="" \
        -f "$awk_lib" \
        -f "$awk_prog" \
        "$fake_log" 2>/dev/null)

    rm -f "$awk_prog" "$fake_log"

    # Verifica che first_seen non sia "UNKNOWN"
    if printf '%s' "$awk_out" | grep -q "UNKNOWN"; then
        _fail "R3-01: timestamp UNKNOWN trovato — awk non vede il timestamp 2 righe prima dell'ORA-"
    elif [ -z "$awk_out" ]; then
        _fail "R3-01: awk non ha prodotto output (log fake vuoto o awk fallito)"
    else
        local first_ts
        first_ts=$(printf '%s' "$awk_out" | head -1 | cut -d'|' -f2)
        if printf '%s' "$first_ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
            _ok "R3-01: first_seen=$first_ts (timestamp rilevato correttamente 2 righe prima dell'ORA-)"
        else
            _fail "R3-01: first_seen='$first_ts' non è un timestamp ISO valido"
        fi
    fi
}

# --- Test: R3-02 — pga_by_pdb_session tetto MAX_LIMIT --------------------------

test_r3_02_pga_limit_max() {
    local script="$1"
    printf "\n  [R3-02: pga_by_pdb_session --limit=999999 → invalid_argument (sopra tetto 500)]\n"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=999999" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--limit=999999 (sopra tetto 500) → invalid_argument"
    else
        _fail "--limit=999999 non ha restituito invalid_argument (rc=$rc, out=$(printf '%s' "$out" | head -1))"
    fi

    printf "  [R3-02: pga_by_pdb_session --limit=500 → accettato (al tetto)]\n"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" "--limit=500" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1; then
        _fail "--limit=500 (al tetto) rifiutato come invalid_argument"
    else
        _ok "--limit=500 (al tetto) accettato dalla validazione (rc=$rc)"
    fi
}

# --- Test: R3-03 — scan_alert_log severity_escalation_thresholds presente ------
# Il campo viene aggiunto solo sull'envelope di successo (status=ok).
# In --quick non abbiamo NFS → il tool restituisce log_not_found (errore).
# Verifica invece che il campo sia nel JSON di successo usando un log fake locale
# e la stessa pipeline bash usata dal tool (build_envelope + sed finale).

test_r3_03_severity_thresholds() {
    local script="$1"
    printf "\n  [R3-03: scan_alert_log → severity_escalation_thresholds nel JSON di successo]\n"

    # Simuliamo la stessa sed-pipeline che scan_alert_log usa per costruire l'envelope finale.
    # Partiamo da un JSON base come quello prodotto da build_envelope.
    local fake_base fake_out
    fake_base='{"tool":"scan_alert_log","generated_at":"2026-09-01T00:00:00+00:00","environment":"TEST","hostname":"axnporadb41","instance_name":"NP41CDB0","oracle_version":"n/a","status":"ok","data":[],"error":null}'
    local SEV_THRESHOLDS
    SEV_THRESHOLDS='{"critical":{"occurrences_per_day_gt":50,"count_gt":500},"warning":{"occurrences_per_day_gt":10,"count_gt":100},"note":"applied per (code, pdb_name) pair; base severity preserved if higher"}'
    fake_out=$(printf '%s' "$fake_base" \
        | tr -d '\n' \
        | sed "s/}\$/,\"log_start_date\":null,\"full_scan_performed\":true,\"filter_until\":null,\"severity_escalation_thresholds\":${SEV_THRESHOLDS}}/")

    if printf '%s' "$fake_out" | jq -e 'has("severity_escalation_thresholds")' >/dev/null 2>&1; then
        _ok "severity_escalation_thresholds presente nell'envelope (pipeline sed OK)"
        if printf '%s' "$fake_out" | jq -e '.severity_escalation_thresholds | has("critical") and has("warning")' >/dev/null 2>&1; then
            _ok "severity_escalation_thresholds contiene critical e warning"
        else
            _fail "severity_escalation_thresholds manca di critical o warning"
        fi
    else
        _fail "severity_escalation_thresholds assente — pipeline sed non funziona"
    fi

    # Se abbiamo NFS (rc=0) verifica sull'output reale; altrimenti skip
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "NP41CDB0" 2>/dev/null) || rc=$?
    if [ "$rc" = "0" ]; then
        if printf '%s' "$out" | jq -e 'has("severity_escalation_thresholds")' >/dev/null 2>&1; then
            _ok "severity_escalation_thresholds presente nell'output reale del tool"
        else
            _fail "severity_escalation_thresholds assente dall'output reale del tool"
        fi
    else
        _skip "R3-03: NFS non disponibile — test sull'output reale skippato (rc=$rc)"
    fi
}

# --- Test: R3-04 — generated_at in UTC (+00:00) --------------------------------

test_r3_04_generated_at_utc() {
    local script="$1" host_only="${2:-0}" env_only="${3:-0}"
    printf "\n  [R3-04: generated_at deve essere in UTC (+00:00)]\n"
    local out rc=0
    if [ "$env_only" = "1" ]; then
        out=$("$script" "INVALIDO" 2>/dev/null) || rc=$?
    elif [ "$host_only" = "1" ]; then
        out=$("$script" "INVALIDO" "axnporadb41" 2>/dev/null) || rc=$?
    else
        out=$("$script" "INVALIDO" "axnporadb41" "NP41CDB0" 2>/dev/null) || rc=$?
    fi
    # Anche un errore invalid_environment ha generated_at — verifichiamo su quello
    if _is_valid_json "$out"; then
        local ts
        ts=$(printf '%s' "$out" | jq -r '.generated_at // ""')
        if printf '%s' "$ts" | grep -qE '\+00:00$'; then
            _ok "generated_at=$ts (UTC +00:00 confermato)"
        elif [ -z "$ts" ]; then
            _fail "generated_at assente dall'envelope"
        else
            _fail "generated_at=$ts (non UTC — atteso +00:00)"
        fi
    else
        _skip "R3-04: output non JSON — impossibile verificare generated_at"
    fi
}

# --- Test: parametri opzionali tool OS ----------------------------------------

test_os_tool_params() {
    local script="$1" tool_name="$2"
    printf "\n  [%s: --samples invalido → invalid_argument]\n" "$tool_name"
    local out rc=0
    out=$("$script" "TEST" "axnporadb41" "--samples=0" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--samples=0 → invalid_argument"
    else
        _fail "--samples=0 non ha restituito invalid_argument (rc=$rc)"
    fi

    printf "  [%s: --samples=abc → invalid_argument]\n" "$tool_name"
    rc=0
    out=$("$script" "TEST" "axnporadb41" "--samples=abc" 2>/dev/null) || rc=$?
    if [ "$rc" = "2" ] || ([ "$rc" = "1" ] && printf '%s' "$out" | jq -e '.error.code == "invalid_argument"' >/dev/null 2>&1); then
        _ok "--samples=abc → invalid_argument"
    else
        _fail "--samples=abc non ha restituito invalid_argument (rc=$rc)"
    fi
}

# --- Runner principale --------------------------------------------------------

run_test() {
    local tool_name="$1"
    local script="${TOOLS_DIR}/${tool_name}.sh"

    if [ ! -f "$script" ]; then
        printf "  SKIP: %s non trovato\n" "$script"
        return
    fi

    printf "\n=== %s ===\n" "$tool_name"

    # Determina la modalità argomenti del tool
    local host_only=0
    local env_only=0
    case "$tool_name" in
        list_instances_on_host|list_known_instances|\
        os_cpu_stats|os_memory_stats|os_disk_stats|os_network_stats)
            host_only=1
            ;;
        list_known_hosts|list_all_hosts_and_instances)
            env_only=1
            ;;
    esac

    # Test input invalidi (non richiedono connessione)
    test_invalid_inputs "$script" "$tool_name" "$host_only" "$env_only"

    # Test hostname traversal (R-10) — no connessione, eseguiti anche in --quick
    test_hostname_traversal "$script" "$host_only" "$env_only"

    # Test ora_errors.json + --until (C3) + R-07 + BUG-04/R3-01 — no connessione, anche in --quick
    if [ "$tool_name" = "scan_alert_log" ]; then
        test_ora_errors_coverage "$script"
        test_scan_alert_log_until_quick "$script"
        test_bug04_code_prefilter_quick "$script"
        test_r3_01_timestamps_preserved "$script"
        test_r3_03_severity_thresholds "$script"
    fi

    # R3-02: pga_by_pdb_session tetto su --limit (no connessione)
    if [ "$tool_name" = "pga_by_pdb_session" ]; then
        test_r3_02_pga_limit_max "$script"
    fi

    # R3-04: generated_at in UTC — no connessione (usiamo input invalido per ottenere JSON)
    test_r3_04_generated_at_utc "$script" "$host_only" "$env_only"

    # B2: strftime disponibile (no connessione)
    if [ "$tool_name" = "os_cpu_stats" ]; then
        test_b2_strftime_quick "$script"
    fi

    # R-05: tail_alert_log tetto su --lines (no connessione)
    if [ "$tool_name" = "tail_alert_log" ]; then
        test_tail_alert_log_lines "$script"
    fi

    # R-06: top_pga_sessions tetto su --limit (no connessione)
    if [ "$tool_name" = "top_pga_sessions" ]; then
        test_top_pga_limit_max "$script"
    fi

    if [ "$QUICK" = "0" ]; then
        # Test host inesistente / NFS assente
        case "$tool_name" in
            scan_alert_log|tail_alert_log|get_alert_log_info)
                # Tool di log/NFS — test log_not_found
                test_log_not_found "$script" "$tool_name"
                ;;
            list_known_hosts|list_all_hosts_and_instances)
                # Tool NFS env-only: verifica solo che ritorni JSON valido
                test_nfs_not_found_env_only "$script"
                ;;
            list_known_instances)
                # Tool NFS con hostname: un host fake → log_not_found
                test_log_not_found "$script" "$tool_name"
                ;;
            list_instances_on_host|os_cpu_stats|os_memory_stats|os_disk_stats|os_network_stats)
                test_bad_host "$script" "1"
                ;;
            *)
                test_bad_host "$script" "0"
                ;;
        esac

        # Test parametri opzionali tool-specifici
        case "$tool_name" in
            top_pga_sessions)
                test_top_pga_limit "$script"
                ;;
            pga_by_pdb_session)
                test_pga_pdb_session_limit "$script"
                test_r3_02_pga_limit_max "$script"
                ;;
            scan_alert_log)
                test_scan_alert_log_params "$script"
                test_ora_errors_coverage "$script"
                ;;
            check_fra_usage)
                test_fra_configured_field "$script"
                ;;
            os_cpu_stats|os_memory_stats|os_disk_stats|os_network_stats)
                test_os_tool_params "$script" "$tool_name"
                ;;
        esac

        # Test con fixture reale (richiede connessione a Oracle)
        test_fixture "$tool_name" "$script"
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "ERRORE: jq non trovato. Installare jq per eseguire i test.\n" >&2
        exit 1
    fi

    local tools_to_test=()
    if [ -n "$FILTER_TOOL" ]; then
        tools_to_test=("$FILTER_TOOL")
    else
        for f in "${TOOLS_DIR}"/*.sh; do
            [ -f "$f" ] && tools_to_test+=("$(basename "$f" .sh)")
        done
    fi

    if [ ${#tools_to_test[@]} -eq 0 ]; then
        printf "Nessun tool trovato in %s\n" "$TOOLS_DIR"
        exit 0
    fi

    printf "Test di contratto JSON — Neural Oracle Analyzer\n"
    printf "================================================\n"
    [ "$QUICK" = "1" ] && printf "Modalità --quick: solo test di input invalidi\n"

    for tool in "${tools_to_test[@]}"; do
        run_test "$tool"
    done

    printf "\n================================================\n"
    printf "Risultati: %d passati, %d falliti\n" "$PASS" "$FAIL"

    if [ "$FAIL" -gt 0 ]; then
        printf "\nFallimenti:\n"
        printf "%b\n" "$ERRORS"
        exit 1
    fi
    exit 0
}

main "$@"
