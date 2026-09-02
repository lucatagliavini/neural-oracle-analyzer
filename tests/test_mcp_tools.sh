#!/usr/bin/env bash
# tests/test_mcp_tools.sh — testa i tool MCP (orchestrati Python + NFS) via JSON-RPC 2.0
#
# Uso:
#   ./tests/test_mcp_tools.sh                          # testa tutti i tool MCP
#   ./tests/test_mcp_tools.sh diagnose_instance        # testa un tool specifico
#
# Richiede: jq, curl, server MCP in ascolto su MCP_URL con MCP_API_KEY
# Variabili d'ambiente:
#   MCP_URL     — URL base del server (default: http://localhost:8420)
#                 Se eseguito da remoto: MCP_URL=http://lxprworkerlana01:8420
#   MCP_API_KEY — API key (default: letto da mcp/.env)
#
# Exit code: 0 = tutti i test passati, 1 = almeno un test fallito
#
# Tool testati (non hanno .sh, esposti solo via MCP wire protocol):
#   list_all_instances_status  — orchestrato Python
#   diagnose_instance          — orchestrato Python
#   check_memory_pressure      — orchestrato Python
#   runbook_ora04030           — orchestrato Python
#
# Tool NFS primitivi già coperti da test_contract.sh ma verificati anche qui
# via wire protocol per validare il path MCP end-to-end:
#   list_known_hosts, list_known_instances, list_all_hosts_and_instances

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0
ERRORS=""

# Configurazione — default localhost (il server gira su questa macchina)
MCP_URL="${MCP_URL:-http://localhost:8420}"

# Carica API key da mcp/.env se non già nell'environment
if [ -z "${MCP_API_KEY:-}" ]; then
    ENV_FILE="${PROJECT_ROOT}/mcp/.env"
    if [ -f "$ENV_FILE" ]; then
        MCP_API_KEY=$(grep "^MCP_API_KEY=" "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
    fi
fi
MCP_API_KEY="${MCP_API_KEY:-}"

# Argomento filtro tool
FILTER_TOOL=""
for arg in "$@"; do
    FILTER_TOOL="$arg" && break
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

_has_key() {
    local obj="$1" key="$2"
    local part rest
    part="${key%%.*}"
    rest="${key#*.}"
    if [ "$rest" = "$key" ]; then
        printf '%s' "$obj" | jq -e "has(\"${part}\")" >/dev/null 2>&1
    else
        local sub
        sub=$(printf '%s' "$obj" | jq -r ".${part} // empty" 2>/dev/null)
        [ -n "$sub" ] && _has_key "$sub" "$rest"
    fi
}

_key_equals() { [ "$(printf '%s' "$1" | jq -r ".$2")" = "$3" ]; }
_key_is_array() { printf '%s' "$1" | jq -e ".$2 | arrays" >/dev/null 2>&1; }

# --- Chiamata MCP via JSON-RPC 2.0 --------------------------------------------

mcp_call() {
    local tool_name="$1"
    local args_json="$2"
    local payload
    payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}' \
        "$tool_name" "$args_json")

    curl -s -X POST "${MCP_URL}/mcp" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${MCP_API_KEY}" \
        --max-time 90 \
        -d "$payload" 2>/dev/null
}

# Estrae il tool result dal wrapper JSON-RPC → content[0].text (già JSON)
extract_result() {
    local rpc_response="$1"
    printf '%s' "$rpc_response" | jq -r '.result.content[0].text' 2>/dev/null
}

# --- Verifica envelope tool result --------------------------------------------

test_tool_result() {
    local desc="$1" rpc_response="$2"

    if ! _is_valid_json "$rpc_response"; then
        _fail "$desc: risposta JSON-RPC non valida → $(printf '%s' "$rpc_response" | head -c 120)"
        return 1
    fi

    # Verifica assenza di errore JSON-RPC
    if printf '%s' "$rpc_response" | jq -e '.error' >/dev/null 2>&1; then
        local rpc_err
        rpc_err=$(printf '%s' "$rpc_response" | jq -r '.error.message // "sconosciuto"')
        _fail "$desc: errore JSON-RPC — $rpc_err"
        return 1
    fi
    _ok "$desc: risposta JSON-RPC valida"

    local result
    result=$(extract_result "$rpc_response")

    if ! _is_valid_json "$result"; then
        _fail "$desc: content[0].text non è JSON valido"
        return 1
    fi
    _ok "$desc: tool result è JSON valido"

    # Verifica chiavi envelope
    for key in tool generated_at environment hostname instance_name oracle_version status data error; do
        if _has_key "$result" "$key"; then
            _ok "$desc: chiave '$key' presente"
        else
            _fail "$desc: chiave '$key' MANCANTE"
        fi
    done

    if _key_is_array "$result" "data"; then
        _ok "$desc: data è un array"
    else
        _fail "$desc: data NON è un array"
    fi
}

# --- Verifica chiavi extra per tool orchestrati (summary) ---------------------

test_orchestrated_result() {
    local desc="$1" rpc_response="$2"
    test_tool_result "$desc" "$rpc_response"

    local result
    result=$(extract_result "$rpc_response")
    [ -z "$result" ] && return 1

    if _has_key "$result" "summary"; then
        _ok "$desc: chiave 'summary' presente (tool orchestrato)"
    else
        _fail "$desc: chiave 'summary' MANCANTE (attesa nei tool orchestrati)"
    fi
}

# --- Test singoli tool --------------------------------------------------------

test_list_all_instances_status() {
    printf "\n=== list_all_instances_status ===\n"
    printf "\n  [fixture: axnporadb41 TEST]\n"
    local resp
    resp=$(mcp_call "list_all_instances_status" '{"environment":"TEST","hostname":"axnporadb41"}')
    test_tool_result "list_all_instances_status" "$resp"

    printf "\n  [host inesistente → JSON con data vuota o error]\n"
    resp=$(mcp_call "list_all_instances_status" '{"environment":"TEST","hostname":"nonexistent-host-xyz-99"}')
    local result
    result=$(extract_result "$resp")
    if _is_valid_json "$result"; then
        _ok "host inesistente → result è JSON valido"
    else
        _fail "host inesistente → result non è JSON valido"
    fi
}

test_diagnose_instance() {
    printf "\n=== diagnose_instance ===\n"
    printf "\n  [fixture: axnporadb41/NP41CDB0 TEST]\n"
    local resp
    resp=$(mcp_call "diagnose_instance" '{"environment":"TEST","hostname":"axnporadb41","instance_name":"NP41CDB0"}')
    test_orchestrated_result "diagnose_instance" "$resp"

    # Verifica struttura summary
    local result
    result=$(extract_result "$resp")
    if [ -n "$result" ] && _is_valid_json "$result"; then
        for skey in stato_generale instance_status oracle_version criticita; do
            if printf '%s' "$result" | jq -e ".summary | has(\"${skey}\")" >/dev/null 2>&1; then
                _ok "summary.$skey presente"
            else
                _fail "summary.$skey MANCANTE"
            fi
        done
    fi
}

test_check_memory_pressure() {
    printf "\n=== check_memory_pressure ===\n"
    printf "\n  [fixture: axnporadb41/NP41CDB0 TEST]\n"
    local resp
    resp=$(mcp_call "check_memory_pressure" '{"environment":"TEST","hostname":"axnporadb41","instance_name":"NP41CDB0"}')
    test_orchestrated_result "check_memory_pressure" "$resp"

    local result
    result=$(extract_result "$resp")
    if [ -n "$result" ] && _is_valid_json "$result"; then
        for skey in livello_pressione valutazione sessione_top_pga totale_pga_top20_mb; do
            if printf '%s' "$result" | jq -e ".summary | has(\"${skey}\")" >/dev/null 2>&1; then
                _ok "summary.$skey presente"
            else
                _fail "summary.$skey MANCANTE"
            fi
        done
    fi
}

test_runbook_ora04030() {
    printf "\n=== runbook_ora04030 ===\n"
    printf "\n  [fixture: axnporadb41/NP41CDB0 TEST]\n"
    local resp
    resp=$(mcp_call "runbook_ora04030" '{"environment":"TEST","hostname":"axnporadb41","instance_name":"NP41CDB0"}')
    test_orchestrated_result "runbook_ora04030" "$resp"

    local result
    result=$(extract_result "$resp")
    if [ -n "$result" ] && _is_valid_json "$result"; then
        for skey in presenza_ora04030 totale_eventi pressione_memoria_attuale raccomandazioni; do
            if printf '%s' "$result" | jq -e ".summary | has(\"${skey}\")" >/dev/null 2>&1; then
                _ok "summary.$skey presente"
            else
                _fail "summary.$skey MANCANTE"
            fi
        done
    fi

    printf "\n  [parametro since opzionale]\n"
    resp=$(mcp_call "runbook_ora04030" '{"environment":"TEST","hostname":"axnporadb41","instance_name":"NP41CDB0","since":"2026-01-01"}')
    result=$(extract_result "$resp")
    if _is_valid_json "$result"; then
        _ok "parametro since accettato"
    else
        _fail "parametro since → result non è JSON valido"
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    if ! command -v jq >/dev/null 2>&1; then
        printf "ERRORE: jq non trovato.\n" >&2; exit 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        printf "ERRORE: curl non trovato.\n" >&2; exit 1
    fi
    if [ -z "$MCP_API_KEY" ]; then
        printf "ERRORE: MCP_API_KEY non trovata (impostare la variabile d'ambiente o creare mcp/.env).\n" >&2
        exit 1
    fi

    # Verifica server raggiungibile
    if ! curl -s --max-time 5 "${MCP_URL}/health" >/dev/null 2>&1; then
        printf "ERRORE: server MCP non raggiungibile su %s\n" "$MCP_URL" >&2
        exit 1
    fi

    printf "Test MCP wire protocol — Neural Oracle Analyzer\n"
    printf "================================================\n"
    printf "Server: %s\n" "$MCP_URL"

    local all_tools=(
        list_all_instances_status
        diagnose_instance
        check_memory_pressure
        runbook_ora04030
    )

    local tools_to_test=()
    if [ -n "$FILTER_TOOL" ]; then
        tools_to_test=("$FILTER_TOOL")
    else
        tools_to_test=("${all_tools[@]}")
    fi

    for tool in "${tools_to_test[@]}"; do
        case "$tool" in
            list_all_instances_status) test_list_all_instances_status ;;
            diagnose_instance)         test_diagnose_instance ;;
            check_memory_pressure)     test_check_memory_pressure ;;
            runbook_ora04030)          test_runbook_ora04030 ;;
            *)
                printf "\n  SKIP: tool '%s' non riconosciuto in questo script\n" "$tool"
                ;;
        esac
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
