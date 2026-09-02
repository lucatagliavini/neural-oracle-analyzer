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
        list_instances_on_host|list_known_instances)
            host_only=1
            ;;
        list_known_hosts|list_all_hosts_and_instances)
            env_only=1
            ;;
    esac

    # Test input invalidi (non richiedono connessione)
    test_invalid_inputs "$script" "$tool_name" "$host_only" "$env_only"

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
            list_instances_on_host)
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
