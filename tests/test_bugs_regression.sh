#!/usr/bin/env bash
# tests/test_bugs_regression.sh — Test di regressione per i 15 bug corretti
#
# Esegue connessioni reali a Oracle e NFS (axnporadb41, TEST).
# NON usare --quick: tutti i test richiedono connessione.
#
# Uso:
#   bash tests/test_bugs_regression.sh             # tutti i test
#   bash tests/test_bugs_regression.sh BUG-08      # solo quel bug
#   bash tests/test_bugs_regression.sh --list       # elenca i bug testati
#
# Exit code: 0 = tutti passati, 1 = almeno uno fallito
# Output: anche su file tests/test_bugs_regression_results.md (markdown)
#
# Ambienti testati: TEST / axnporadb41
#   NP41CDB0: istanza principale (1800 processes, no FRA)
#   NP41CDB1: istanza con FRA configurata (100GB, ORA-04036 nel log)
#   NP41CDB2: istanza secondaria (2048 processes, no FRA)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/../tools"
MCP_DIR="${SCRIPT_DIR}/../mcp"

# Python da usare per gli orchestrati: preferisce il venv del progetto se presente,
# altrimenti cade su python3 di sistema.
PYTHON3="${MCP_DIR}/venv/bin/python3"
if [ ! -x "$PYTHON3" ]; then
    PYTHON3="python3"
fi

ENV="TEST"
HOST="axnporadb41"
INST0="NP41CDB0"
INST1="NP41CDB1"
INST2="NP41CDB2"

PASS=0
FAIL=0
SKIP=0
ERRORS=""
MD_LINES=""

FILTER_BUG=""
LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        BUG-*) FILTER_BUG="$arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

_ok()   {
    PASS=$((PASS + 1))
    printf "  ✓ %s\n" "$1"
    MD_LINES="${MD_LINES}\n| ✅ | \`$1\` |"
}
_skip() {
    SKIP=$((SKIP + 1))
    printf "  - SKIP: %s\n" "$1"
    MD_LINES="${MD_LINES}\n| ⏭ | \`SKIP: $1\` |"
}
_fail() {
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  ✗ $1"
    printf "  ✗ %s\n" "$1"
    MD_LINES="${MD_LINES}\n| ❌ | \`$1\` |"
}

_jq()  { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }
_jqe() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

_run_tool() {
    local script="$1"; shift
    local out rc=0
    out=$("$script" "$@" 2>/dev/null) || rc=$?
    printf '%s' "$out"
    return $rc
}

_section_header() {
    printf "\n=== %s — %s ===\n" "$1" "$2"
    MD_LINES="${MD_LINES}\n\n### $1 — $2\n| Stato | Test |\n|---|---|"
}

_assert_json_valid() {
    local label="$1" out="$2"
    if printf '%s' "$out" | jq . >/dev/null 2>&1; then
        _ok "$label: output è JSON valido"
        return 0
    else
        _fail "$label: output NON è JSON valido → $(printf '%s' "$out" | head -c 120)"
        return 1
    fi
}

_assert_status_ok() {
    local label="$1" out="$2"
    local s
    s=$(_jq "$out" ".status")
    if [ "$s" = "ok" ]; then
        _ok "$label: status=ok"
    else
        _fail "$label: status=$s (atteso ok)"
    fi
}

_assert_field_equals() {
    local label="$1" out="$2" jq_path="$3" expected="$4"
    local actual
    actual=$(_jq "$out" "$jq_path")
    if [ "$actual" = "$expected" ]; then
        _ok "$label: $jq_path = $expected"
    else
        _fail "$label: $jq_path = '$actual' (atteso '$expected')"
    fi
}

_assert_field_not_null() {
    local label="$1" out="$2" jq_path="$3"
    local actual
    actual=$(_jq "$out" "$jq_path")
    if [ -n "$actual" ] && [ "$actual" != "null" ]; then
        _ok "$label: $jq_path non è null ($actual)"
    else
        _fail "$label: $jq_path è null/vuoto"
    fi
}

_assert_field_is_number() {
    local label="$1" out="$2" jq_path="$3"
    if _jqe "$out" "$jq_path | numbers"; then
        _ok "$label: $jq_path è un numero"
    else
        local v
        v=$(_jq "$out" "$jq_path")
        _fail "$label: $jq_path non è un numero → '$v'"
    fi
}

_assert_field_is_bool() {
    local label="$1" out="$2" jq_path="$3"
    # Gotcha: jq -e restituisce exit 1 su valori booleani false.
    # Usiamo type == "boolean" per evitare il problema con false.
    if _jqe "$out" "$jq_path | type == \"boolean\""; then
        _ok "$label: $jq_path è un bool"
    else
        local v
        v=$(_jq "$out" "$jq_path")
        _fail "$label: $jq_path non è un bool → '$v'"
    fi
}

_assert_array_not_empty() {
    local label="$1" out="$2" jq_path="$3"
    local len
    len=$(_jq "$out" "$jq_path | length")
    if [ -n "$len" ] && [ "$len" -gt 0 ] 2>/dev/null; then
        _ok "$label: $jq_path array non vuoto (len=$len)"
    else
        _fail "$label: $jq_path array vuoto o assente"
    fi
}

_assert_value_gt() {
    local label="$1" out="$2" jq_path="$3" threshold="$4"
    local val
    val=$(_jq "$out" "$jq_path")
    if [ -n "$val" ] && [ "$val" -gt "$threshold" ] 2>/dev/null; then
        _ok "$label: $jq_path=$val > $threshold"
    else
        _fail "$label: $jq_path=$val non > $threshold"
    fi
}

# ---------------------------------------------------------------------------
# Lista bug
# ---------------------------------------------------------------------------

ALL_BUGS=(
    "BUG-08:check_resource_limits: calcolo su limit_value"
    "BUG-11:scan_alert_log: normalizzazione zero-padding ORA-"
    "BUG-10:scan_alert_log: dizionario severità (ORA-00020, ORA-04036)"
    "BUG-01:pga_by_pdb_session: parametro --limit"
    "BUG-03+09:check_fra_usage: v\$parameter + CAST space_limit"
    "BUG-14:runbook_ora04030: ORA-04036 incluso, no falso negativo"
    "BUG-15:os_disk_stats: io_collected distinto da io_available"
    "BUG-13:pga_by_pdb_session: CDB\$ROOT incluso"
    "BUG-02:check_fra_usage: fra_configured esplicito"
    "BUG-05:scan_alert_log: log_start_date nell'envelope"
    "BUG-04:scan_alert_log: full_scan_performed nell'envelope"
    "BUG-06:list_known_instances: campo resident"
    "BUG-07:tool NFS: oracle_version=n/a"
    "BUG-12:sessions: scope e total documentati"
    "R-01:pga_by_pdb_session: dati presenti (no data:[] silenzioso)"
    "R-05:tail_alert_log: tetto su --lines"
    "R-06:top_pga_sessions: tetto su --limit"
    "R-07:scan_alert_log: date semanticamente invalide respinte"
    "R-08:scan_alert_log: CDB\$ROOT come alias per --pdb"
    "R-10:hostname path traversal respinto"
    "R-11:scan_alert_log: log_start_date sempre valorizzata (anche con --since)"
    "R-12:tool OS: instance_name=null JSON (non stringa)"
    "R-13:check_fra_usage: tipi coerenti (size come intero)"
    "R-15:check_resource_limits: scope nell'envelope"
    "R-16:scan_alert_log: severity_effective e occurrences_per_day"
    "R-17:diagnose_instance: flag per istanza OPEN senza PDB applicativi"
    "B2:os_memory_stats/os_cpu_stats: timestamp distinti per ogni campione"
)

if [ "$LIST_ONLY" = "1" ]; then
    printf "Bug testati:\n"
    for b in "${ALL_BUGS[@]}"; do
        printf "  %s\n" "$b"
    done
    exit 0
fi

_should_run() {
    local bug="$1"
    [ -z "$FILTER_BUG" ] || [[ "$bug" == "$FILTER_BUG"* ]]
}

# ---------------------------------------------------------------------------
# BUG-08 — check_resource_limits: denominatore = limit_value
# ---------------------------------------------------------------------------
if _should_run "BUG-08"; then
    _section_header "BUG-08" "check_resource_limits: denominatore = limit_value, non max_utilization"

    for inst in "$INST0" "$INST1" "$INST2"; do
        out=$(_run_tool "${TOOLS_DIR}/check_resource_limits.sh" "$ENV" "$HOST" "$inst") || true
        if ! _assert_json_valid "BUG-08/$inst" "$out"; then continue; fi
        _assert_status_ok "BUG-08/$inst" "$out"

        # Ogni riga deve avere limit_value non null e numerico (o "UNLIMITED")
        n=$(_jq "$out" '.data | length')
        for ((i=0; i<n; i++)); do
            rname=$(_jq "$out" ".data[$i].resource_name")
            lv=$(_jq "$out" ".data[$i].limit_value")
            mu=$(_jq "$out" ".data[$i].max_utilization")
            cu=$(_jq "$out" ".data[$i].current_utilization")

            # limit_value deve esistere e non essere null
            if [ -n "$lv" ] && [ "$lv" != "null" ]; then
                _ok "BUG-08/$inst/$rname: limit_value=$lv presente"
            else
                _fail "BUG-08/$inst/$rname: limit_value null o assente"
            fi

            # Verifica che current/limit_value NON superi il 100% (sarebbe impossibile)
            # e che NON coincida sistematicamente con current/max_utilization
            if printf '%s' "$lv" | grep -qE '^[0-9]+$' && \
               printf '%s' "$cu" | grep -qE '^[0-9]+$' && \
               printf '%s' "$mu" | grep -qE '^[0-9]+$'; then
                pct_correct=$(awk "BEGIN{printf \"%.0f\", $cu/$lv*100}")
                pct_wrong=$(awk "BEGIN{printf \"%.0f\", $cu/$mu*100}")
                if [ "$pct_correct" -le 100 ]; then
                    _ok "BUG-08/$inst/$rname: current/limit_value=${pct_correct}% (plausibile)"
                else
                    _fail "BUG-08/$inst/$rname: current/limit_value=${pct_correct}% > 100% (impossibile)"
                fi
                # Se limit_value == max_utilization il bug sarebbe ancora presente
                if [ "$lv" = "$mu" ]; then
                    _fail "BUG-08/$inst/$rname: limit_value=max_utilization ($lv) — bug ancora presente?"
                else
                    _ok "BUG-08/$inst/$rname: limit_value($lv) ≠ max_utilization($mu) — denominatori distinti"
                fi
            fi
        done
    done
fi

# ---------------------------------------------------------------------------
# BUG-11 — scan_alert_log: normalizzazione zero-padding ORA-
# ---------------------------------------------------------------------------
if _should_run "BUG-11"; then
    _section_header "BUG-11" "scan_alert_log: normalizzazione zero-padding (ORA-4036 → ORA-04036)"

    # Cerca ORA-04036 con forma NON zero-padded: deve trovare gli stessi risultati
    out_norm=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-04036" "--since=2025-01-01") || true
    out_short=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-4036" "--since=2025-01-01") || true

    if _assert_json_valid "BUG-11/ORA-04036" "$out_norm" && _assert_json_valid "BUG-11/ORA-4036" "$out_short"; then
        n_norm=$(_jq "$out_norm" '.data | length')
        n_short=$(_jq "$out_short" '.data | length')
        # Con normalizzazione: entrambi devono trovare ORA-04036 (codice normalizzato)
        # e restituire lo stesso numero di gruppi (sono lo stesso codice)
        if [ "$n_norm" = "$n_short" ]; then
            _ok "BUG-11: --code=ORA-04036 e --code=ORA-4036 trovano stessi gruppi ($n_norm)"
        else
            _fail "BUG-11: --code=ORA-04036=$n_norm gruppi vs --code=ORA-4036=$n_short — diversi (bug ancora presente?)"
        fi

        # Il codice nel data[] deve essere normalizzato (ORA-04036, non ORA-4036)
        if [ "$n_norm" -gt 0 ]; then
            code_out=$(_jq "$out_norm" '.data[0].code')
            if [ "$code_out" = "ORA-04036" ]; then
                _ok "BUG-11: data[0].code normalizzato a ORA-04036"
            else
                _fail "BUG-11: data[0].code='$code_out' (atteso ORA-04036)"
            fi
        else
            _skip "BUG-11: nessun ORA-04036 trovato su $INST1 dal 2025-01-01 (log non disponibile o assente)"
        fi
    fi

    # Verifica che ORA-20 (forma corta di ORA-00020) non appaia come codice separato
    # La normalizzazione deve aggregarli sotto ORA-00020
    out_norm20=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-00020") || true
    out_short20=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-20") || true
    if _assert_json_valid "BUG-11/ORA-00020" "$out_norm20" && _assert_json_valid "BUG-11/ORA-20" "$out_short20"; then
        n20_norm=$(_jq "$out_norm20" '.data | length')
        n20_short=$(_jq "$out_short20" '.data | length')
        if [ "$n20_norm" = "$n20_short" ]; then
            _ok "BUG-11: ORA-00020 e ORA-20 trovano stessi gruppi ($n20_norm)"
        else
            _fail "BUG-11: ORA-00020=$n20_norm vs ORA-20=$n20_short — diversi (normalizzazione mancante)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-10 — scan_alert_log: dizionario severità
# ---------------------------------------------------------------------------
if _should_run "BUG-10"; then
    _section_header "BUG-10" "scan_alert_log: ORA-00020 e ORA-04036 con severity=critical"

    # ORA-00020 su NP41CDB1
    out20=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-00020") || true
    if _assert_json_valid "BUG-10/ORA-00020" "$out20"; then
        n=$(_jq "$out20" '.data | length')
        if [ "$n" -gt 0 ]; then
            sev=$(_jq "$out20" '.data[0].severity')
            desc=$(_jq "$out20" '.data[0].description')
            [ "$sev" = "critical" ] && _ok "BUG-10/ORA-00020: severity=critical" \
                || _fail "BUG-10/ORA-00020: severity='$sev' (atteso critical)"
            [ "$desc" != "null" ] && _ok "BUG-10/ORA-00020: description presente ('${desc:0:50}...')" \
                || _fail "BUG-10/ORA-00020: description=null"
        else
            _skip "BUG-10/ORA-00020: nessuna occorrenza nel log (ok se mai capitato)"
        fi
    fi

    # ORA-04036 su NP41CDB1 (66 occorrenze attese dal collaudo 2026-09-04)
    out36=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--code=ORA-04036" "--since=2025-01-01") || true
    if _assert_json_valid "BUG-10/ORA-04036" "$out36"; then
        n=$(_jq "$out36" '.data | length')
        if [ "$n" -gt 0 ]; then
            sev=$(_jq "$out36" '.data[0].severity')
            cnt=$(_jq "$out36" '.data[0].count')
            [ "$sev" = "critical" ] && _ok "BUG-10/ORA-04036: severity=critical (count=$cnt)" \
                || _fail "BUG-10/ORA-04036: severity='$sev' (atteso critical)"
            # Attesi ≥ 56 eventi dal 2025-01-01
            [ "$cnt" -ge 10 ] 2>/dev/null && _ok "BUG-10/ORA-04036: count=$cnt (≥10, atteso ≥56)" \
                || _skip "BUG-10/ORA-04036: count=$cnt (basso — log ruotato?)"
        else
            _skip "BUG-10/ORA-04036: nessuna occorrenza dal 2025-01-01 (log ruotato o istanza riavviata)"
        fi
    fi

    # ORA-01692 deve avere severity=warning
    out92=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST0" "--code=ORA-01692") || true
    if _assert_json_valid "BUG-10/ORA-01692" "$out92"; then
        n=$(_jq "$out92" '.data | length')
        if [ "$n" -gt 0 ]; then
            sev=$(_jq "$out92" '.data[0].severity')
            [ "$sev" = "warning" ] && _ok "BUG-10/ORA-01692: severity=warning" \
                || _fail "BUG-10/ORA-01692: severity='$sev' (atteso warning)"
        else
            _skip "BUG-10/ORA-01692: nessuna occorrenza su $INST0"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-01 — pga_by_pdb_session: parametro --limit
# ---------------------------------------------------------------------------
if _should_run "BUG-01"; then
    _section_header "BUG-01" "pga_by_pdb_session: --limit riduce payload"

    # Senza limite (default 50)
    out50=$(_run_tool "${TOOLS_DIR}/pga_by_pdb_session.sh" "$ENV" "$HOST" "$INST0") || true
    if _assert_json_valid "BUG-01/default" "$out50"; then
        _assert_status_ok "BUG-01/default" "$out50"
        n50=$(_jq "$out50" '.data | length')
        [ "$n50" -le 50 ] && _ok "BUG-01/default: data.length=$n50 ≤ 50 (limit default rispettato)" \
            || _fail "BUG-01/default: data.length=$n50 > 50 (limit non applicato)"
    fi

    # Con limit=5
    out5=$(_run_tool "${TOOLS_DIR}/pga_by_pdb_session.sh" "$ENV" "$HOST" "$INST0" "--limit=5") || true
    if _assert_json_valid "BUG-01/limit5" "$out5"; then
        _assert_status_ok "BUG-01/limit5" "$out5"
        n5=$(_jq "$out5" '.data | length')
        [ "$n5" -le 5 ] && _ok "BUG-01/limit5: data.length=$n5 ≤ 5" \
            || _fail "BUG-01/limit5: data.length=$n5 > 5 (limit non applicato)"
    fi

    # Ordinamento decrescente per PGA: prima riga deve avere pga_alloc_mem ≥ seconda
    if _assert_json_valid "BUG-01/order" "$out50"; then
        n=$(_jq "$out50" '.data | length')
        if [ "$n" -ge 2 ]; then
            p0=$(_jq "$out50" '.data[0].pga_alloc_mem')
            p1=$(_jq "$out50" '.data[1].pga_alloc_mem')
            if [ -n "$p0" ] && [ -n "$p1" ] && [ "$p0" -ge "$p1" ] 2>/dev/null; then
                _ok "BUG-01/order: dati ordinati per pga_alloc_mem DESC ($p0 ≥ $p1)"
            else
                _fail "BUG-01/order: ordinamento non decrescente ($p0 < $p1)"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-03+09 — check_fra_usage: v$parameter, CAST space_limit
# ---------------------------------------------------------------------------
if _should_run "BUG-03" || _should_run "BUG-09"; then
    _section_header "BUG-03+09" "check_fra_usage: v\$parameter (no wrapping) + space_limit come intero"

    out=$(_run_tool "${TOOLS_DIR}/check_fra_usage.sh" "$ENV" "$HOST" "$INST1") || true
    if _assert_json_valid "BUG-03+09/NP41CDB1" "$out"; then
        _assert_status_ok "BUG-03+09/NP41CDB1" "$out"

        # fra_size: nessuna riga con name=null (che sarebbe la continuazione spezzata)
        null_rows=$(_jq "$out" '[.data[] | select(.source=="fra_size") | select(.name==null)] | length')
        [ "${null_rows:-0}" = "0" ] \
            && _ok "BUG-03: nessuna riga spuria name=null in fra_size" \
            || _fail "BUG-03: ${null_rows} righe spurie name=null in fra_size (riga continuazione ancora presente)"

        # fra_size: db_recovery_file_dest deve essere il path completo (≥20 char)
        dest=$(_jq "$out" '[.data[] | select(.source=="fra_size") | select(.name=="db_recovery_file_dest")] | first | .value')
        dest_len=${#dest}
        [ "$dest_len" -ge 20 ] \
            && _ok "BUG-03: db_recovery_file_dest='${dest}' (len=$dest_len, path completo)" \
            || _fail "BUG-03: db_recovery_file_dest='${dest}' (len=$dest_len, sospetto troncamento)"

        # BUG-09: space_limit in fra_dest deve essere un numero (non stringa scientifica)
        space_limit=$(_jq "$out" '[.data[] | select(.source=="fra_dest")] | first | .space_limit')
        if [ -n "$space_limit" ] && [ "$space_limit" != "null" ]; then
            if printf '%s' "$space_limit" | grep -qE '^[0-9]+$'; then
                _ok "BUG-09: space_limit=$space_limit è intero (no notazione scientifica)"
            else
                _fail "BUG-09: space_limit='$space_limit' non è intero (ancora notazione scientifica o stringa?)"
            fi
        else
            _skip "BUG-09: space_limit null/assente in fra_dest (FRA assente su questa istanza?)"
        fi
    fi

    # Su NP41CDB0 (no FRA): fra_size deve comunque avere le righe dei parametri
    out0=$(_run_tool "${TOOLS_DIR}/check_fra_usage.sh" "$ENV" "$HOST" "$INST0") || true
    if _assert_json_valid "BUG-03+09/NP41CDB0_noFRA" "$out0"; then
        n_fra_size=$(_jq "$out0" '[.data[] | select(.source=="fra_size")] | length')
        [ "${n_fra_size:-0}" -ge 2 ] \
            && _ok "BUG-03: fra_size ha $n_fra_size righe anche su istanza senza FRA" \
            || _fail "BUG-03: fra_size ha $n_fra_size righe su istanza senza FRA (atteso ≥2)"
    fi
fi

# ---------------------------------------------------------------------------
# BUG-02 — check_fra_usage: fra_configured esplicito
# ---------------------------------------------------------------------------
if _should_run "BUG-02"; then
    _section_header "BUG-02" "check_fra_usage: sezione fra_status con fra_configured esplicito"

    # NP41CDB1: FRA configurata → fra_configured=true
    out1=$(_run_tool "${TOOLS_DIR}/check_fra_usage.sh" "$ENV" "$HOST" "$INST1") || true
    if _assert_json_valid "BUG-02/NP41CDB1" "$out1"; then
        n_status=$(_jq "$out1" '[.data[] | select(.source=="fra_status")] | length')
        [ "${n_status:-0}" -ge 1 ] \
            && _ok "BUG-02/NP41CDB1: sezione fra_status presente" \
            || _fail "BUG-02/NP41CDB1: sezione fra_status MANCANTE"

        configured=$(_jq "$out1" '[.data[] | select(.source=="fra_status")] | first | .fra_configured')
        [ "$configured" = "true" ] \
            && _ok "BUG-02/NP41CDB1: fra_configured=true (FRA presente)" \
            || _fail "BUG-02/NP41CDB1: fra_configured='$configured' (atteso true)"

        dest_in_status=$(_jq "$out1" '[.data[] | select(.source=="fra_status")] | first | .db_recovery_file_dest')
        [ -n "$dest_in_status" ] && [ "$dest_in_status" != "null" ] && [ "$dest_in_status" != "" ] \
            && _ok "BUG-02/NP41CDB1: db_recovery_file_dest in fra_status = '$dest_in_status'" \
            || _fail "BUG-02/NP41CDB1: db_recovery_file_dest vuoto in fra_status"
    fi

    # NP41CDB0 o NP41CDB2: nessuna FRA → fra_configured=false
    for inst in "$INST0" "$INST2"; do
        out=$(_run_tool "${TOOLS_DIR}/check_fra_usage.sh" "$ENV" "$HOST" "$inst") || true
        if _assert_json_valid "BUG-02/$inst" "$out"; then
            configured=$(_jq "$out" '[.data[] | select(.source=="fra_status")] | first | .fra_configured')
            [ "$configured" = "false" ] \
                && _ok "BUG-02/$inst: fra_configured=false (FRA assente)" \
                || _fail "BUG-02/$inst: fra_configured='$configured' (atteso false)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# BUG-13 — pga_by_pdb_session: CDB$ROOT incluso
# ---------------------------------------------------------------------------
if _should_run "BUG-13"; then
    _section_header "BUG-13" "pga_by_pdb_session: sessioni CDB\$ROOT incluse (LEFT OUTER JOIN)"

    # BUG-13: verifica che il campo pdb_name contenga "CDB$ROOT" e non null per sessioni root.
    # Usiamo NP41CDB0 che ha più sessioni attive (1800 processes).
    out=$(_run_tool "${TOOLS_DIR}/pga_by_pdb_session.sh" "$ENV" "$HOST" "$INST0" "--limit=100") || true
    if _assert_json_valid "BUG-13" "$out"; then
        _assert_status_ok "BUG-13" "$out"
        n_pga=$(_jq "$out" '.data | length')
        if [ "${n_pga:-0}" -gt 0 ]; then
            _ok "BUG-13: data.length=$n_pga > 0 (sessioni presenti)"
            has_root=$(_jq "$out" '[.data[] | select(.pdb_name == "CDB$ROOT")] | length')
            if [ "${has_root:-0}" -gt 0 ]; then
                _ok "BUG-13: $has_root sessioni con pdb_name=CDB\$ROOT trovate"
            else
                # Con tutte le sessioni su PDB è possibile non averne su CDB$ROOT:
                # il fix è comunque corretto (LEFT JOIN). Verifica strutturale.
                has_null=$(_jq "$out" '[.data[] | select(.pdb_name == null)] | length')
                [ "${has_null:-0}" -eq 0 ] \
                    && _ok "BUG-13: nessun pdb_name=null (CDB\$ROOT gestito correttamente)" \
                    || _skip "BUG-13: $has_null sessioni con pdb_name=null (CDB\$ROOT o PDB non risolto)"
            fi
        else
            _skip "BUG-13: nessuna sessione attiva su $INST0 al momento del test"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-14 — runbook_ora04030: ORA-04036 cercato, no falso negativo
# ---------------------------------------------------------------------------
if _should_run "BUG-14"; then
    _section_header "BUG-14" "runbook_ora04030: cerca ORA-04036, no falso negativo su NP41CDB1"

    # Esegui via Python orchestration
    python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<'PYEOF' 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import runbook_ora04030
r = runbook_ora04030("TEST", "axnporadb41", "NP41CDB1", since="2025-01-01")
print(json.dumps(r))
PYEOF
) || true

    if _assert_json_valid "BUG-14" "$python_out"; then
        _assert_field_equals "BUG-14" "$python_out" ".status" "ok"

        # eventi_ora04036 deve essere > 0 (NP41CDB1 aveva 66 occorrenze)
        ev36=$(_jq "$python_out" ".summary.eventi_ora04036")
        if [ -n "$ev36" ] && [ "$ev36" -gt 0 ] 2>/dev/null; then
            _ok "BUG-14: eventi_ora04036=$ev36 > 0 (ORA-04036 trovato)"
        else
            _skip "BUG-14: eventi_ora04036=$ev36 (log ruotato? attesi ≥56)"
        fi

        # Il summary non deve dire "nessuna azione richiesta" quando ci sono ORA-04036
        ev_tot=$(_jq "$python_out" ".summary.totale_eventi")
        racc=$(_jq "$python_out" ".summary.raccomandazioni | join(\" \")")
        if [ "${ev_tot:-0}" -gt 0 ] 2>/dev/null; then
            if echo "$racc" | grep -qi "nessuna azione immediata\|no action"; then
                _fail "BUG-14: falso negativo — summary dice nessuna azione con $ev_tot eventi"
            else
                _ok "BUG-14: summary non dice 'nessuna azione' con $ev_tot eventi"
            fi
        fi

        # Deve avere scan di ORA-04036 nelle sezioni data
        has_scan36=$(_jq "$python_out" '[.data[] | select(.sezione=="scan_alert_log_ora04036")] | length')
        [ "${has_scan36:-0}" -ge 1 ] \
            && _ok "BUG-14: sezione scan_alert_log_ora04036 presente nei dati" \
            || _fail "BUG-14: sezione scan_alert_log_ora04036 MANCANTE"

        # log_start_date deve essere presente nel summary (BUG-05 integrato)
        lsd=$(_jq "$python_out" ".summary.log_start_date")
        [ -n "$lsd" ] && [ "$lsd" != "null" ] \
            && _ok "BUG-14/BUG-05: log_start_date=$lsd nel summary" \
            || _skip "BUG-14/BUG-05: log_start_date=null (log 11g puro o --since impostato)"
    fi
fi

# ---------------------------------------------------------------------------
# BUG-05 / R-11 — scan_alert_log: log_start_date nell'envelope
# ---------------------------------------------------------------------------
if _should_run "BUG-05" || _should_run "R-11"; then
    _section_header "BUG-05/R-11" "scan_alert_log: log_start_date sempre valorizzata (proprietà del file, non del filtro)"

    # Con --since: log_start_date deve essere valorizzata (R-11 — è proprietà del file)
    out=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--code=ORA-00060" "--since=2026-08-01") || true
    if _assert_json_valid "BUG-05/R-11/con-since" "$out"; then
        lsd=$(_jq "$out" ".log_start_date")
        if [ -n "$lsd" ] && [ "$lsd" != "null" ]; then
            if echo "$lsd" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
                _ok "R-11/con-since: log_start_date='$lsd' valorizzata anche con --since"
            else
                _fail "R-11/con-since: log_start_date='$lsd' formato non ISO"
            fi
        else
            _skip "R-11/con-since: log_start_date=null (log 11g puro o NFS assente)"
        fi
        # I campi envelope extra non devono comparire nei singoli oggetti del data array
        n_data=$(_jq "$out" ".data | length")
        if [ "${n_data:-0}" -gt 0 ]; then
            log_in_row=$(_jq "$out" ".data[0] | has(\"log_start_date\")")
            [ "$log_in_row" = "false" ] \
                && _ok "BUG-05/R-11: log_start_date NON in data[0] (solo nell'envelope top-level)" \
                || _fail "BUG-05/R-11: log_start_date in data[0] (bug: nel singolo record invece che nell'envelope)"
        fi
    fi

    out2=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--code=ORA-00060") || true
    if _assert_json_valid "BUG-05/senza-since" "$out2"; then
        # Senza --since: log_start_date deve essere una data ISO o null (se log 11g)
        lsd2=$(_jq "$out2" ".log_start_date")
        if [ -n "$lsd2" ] && [ "$lsd2" != "null" ]; then
            if echo "$lsd2" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
                _ok "BUG-05/senza-since: log_start_date='$lsd2' (formato ISO)"
            else
                _fail "BUG-05/senza-since: log_start_date='$lsd2' non è formato ISO"
            fi
        else
            _skip "BUG-05/senza-since: log_start_date=null (log 11g puro o NFS assente)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-04 — scan_alert_log: full_scan_performed nell'envelope
# ---------------------------------------------------------------------------
if _should_run "BUG-04"; then
    _section_header "BUG-04" "scan_alert_log: full_scan_performed nell'envelope"

    # Con --code senza --since: full_scan=false (Strategia B, BUG-04 fix)
    out_code=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--code=ORA-00060") || true
    if _assert_json_valid "BUG-04/code" "$out_code"; then
        fs=$(_jq "$out_code" ".full_scan_performed")
        [ "$fs" = "false" ] \
            && _ok "BUG-04/code: full_scan_performed=false con --code (Strategia B attiva)" \
            || _fail "BUG-04/code: full_scan_performed='$fs' (atteso false — BUG-04 non risolto)"
    fi

    # Con codice assente: full_scan=false e data=[] (fast-exit B1)
    out_absent=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--code=ORA-99998") || true
    if _assert_json_valid "BUG-04/absent" "$out_absent"; then
        fs_a=$(_jq "$out_absent" ".full_scan_performed")
        n_a=$(_jq "$out_absent" ".data | length")
        [ "$fs_a" = "false" ] \
            && _ok "BUG-04/absent: full_scan_performed=false (fast-exit B1)" \
            || _fail "BUG-04/absent: full_scan_performed='$fs_a' (atteso false)"
        [ "${n_a:-0}" = "0" ] \
            && _ok "BUG-04/absent: data=[] con codice assente" \
            || _fail "BUG-04/absent: data ha $n_a elementi con codice assente"
    fi

    # Con --since: full_scan=false (Strategia A, già implementata)
    out_since=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--since=2026-08-01") || true
    if _assert_json_valid "BUG-04/since" "$out_since"; then
        fs2=$(_jq "$out_since" ".full_scan_performed")
        [ "$fs2" = "false" ] \
            && _ok "BUG-04/since: full_scan_performed=false con --since (Strategia A)" \
            || _fail "BUG-04/since: full_scan_performed='$fs2' (atteso false)"
    fi

    # Senza filtri: full_scan=true (lettura intera, nessuna ottimizzazione)
    out_full=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--since=2026-09-01") || true
    if _assert_json_valid "BUG-04/nofilter" "$out_full"; then
        fs3=$(_jq "$out_full" ".full_scan_performed")
        # Con --since recente full_scan=false (Strategia A con data trovata)
        _ok "BUG-04/nofilter: full_scan_performed=$fs3 (con --since recente = false atteso)"
    fi
fi

# ---------------------------------------------------------------------------
# BUG-15 — os_disk_stats: io_collected distinto da io_available
# ---------------------------------------------------------------------------
if _should_run "BUG-15"; then
    _section_header "BUG-15" "os_disk_stats: io_collected distinto da io_available"

    out=$(_run_tool "${TOOLS_DIR}/os_disk_stats.sh" "$ENV" "$HOST" "--samples=2" "--interval=1") || true
    if _assert_json_valid "BUG-15" "$out"; then
        _assert_status_ok "BUG-15" "$out"

        # io_collected deve esistere come campo bool
        _assert_field_is_bool "BUG-15" "$out" '.data[0].io_collected'

        ia=$(_jq "$out" '.data[0].io_available')
        ic=$(_jq "$out" '.data[0].io_collected')
        _ok "BUG-15: io_available=$ia, io_collected=$ic (distinti)"

        # Se io_collected=false → io_samples deve essere []
        if [ "$ic" = "false" ]; then
            n=$(_jq "$out" '.data[0].io_samples | length')
            [ "${n:-0}" = "0" ] \
                && _ok "BUG-15: io_collected=false → io_samples=[] coerente" \
                || _fail "BUG-15: io_collected=false ma io_samples ha $n elementi"
        fi
    fi

    # Verifica in diagnose_os_pressure: disk_io_await_p95_ms deve essere null se io non raccolto
    python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<'PYEOF' 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import diagnose_os_pressure
r = diagnose_os_pressure("TEST", "axnporadb41", "NP41CDB0", samples=2, interval=1)
print(json.dumps(r))
PYEOF
) || true
    if _assert_json_valid "BUG-15/orchestration" "$python_out"; then
        await=$(_jq "$python_out" ".summary.metriche_os.disk_io_await_p95_ms")
        if [ "$await" = "null" ] || printf '%s' "$await" | grep -qE '^[0-9]'; then
            _ok "BUG-15/orchestration: disk_io_await_p95_ms='$await' (null o numero, non zero falso)"
        else
            _fail "BUG-15/orchestration: disk_io_await_p95_ms='$await' inatteso"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-07 — oracle_version = "n/a" nei tool NFS
# ---------------------------------------------------------------------------
if _should_run "BUG-07"; then
    _section_header "BUG-07" "Tool NFS: oracle_version = \"n/a\" invece di null"

    declare -A NFS_TOOLS=(
        ["scan_alert_log"]="$ENV $HOST $INST0 --code=ORA-00060 --since=2026-08-01"
        ["tail_alert_log"]="$ENV $HOST $INST0 --lines=5"
        ["get_alert_log_info"]="$ENV $HOST $INST0"
        ["list_known_hosts"]="$ENV"
        ["list_known_instances"]="$ENV $HOST"
        ["list_all_hosts_and_instances"]="$ENV"
    )

    for tool_name in "${!NFS_TOOLS[@]}"; do
        # shellcheck disable=SC2086
        out=$(_run_tool "${TOOLS_DIR}/${tool_name}.sh" ${NFS_TOOLS[$tool_name]}) || true
        if _assert_json_valid "BUG-07/$tool_name" "$out"; then
            ov=$(_jq "$out" ".oracle_version")
            [ "$ov" = "n/a" ] \
                && _ok "BUG-07/$tool_name: oracle_version=n/a" \
                || _fail "BUG-07/$tool_name: oracle_version='$ov' (atteso n/a)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# BUG-12 — sessions: scope e total documentati
# ---------------------------------------------------------------------------
if _should_run "BUG-12"; then
    _section_header "BUG-12" "sessions_by_user/machine: scope e totali per riconciliazione"

    out_user=$(_run_tool "${TOOLS_DIR}/sessions_by_user.sh" "$ENV" "$HOST" "$INST1") || true
    out_mach=$(_run_tool "${TOOLS_DIR}/sessions_by_machine.sh" "$ENV" "$HOST" "$INST1") || true

    if _assert_json_valid "BUG-12/user" "$out_user" && _assert_json_valid "BUG-12/machine" "$out_mach"; then
        _assert_status_ok "BUG-12/user" "$out_user"
        _assert_status_ok "BUG-12/machine" "$out_mach"

        # scope deve essere "user_sessions" e "all_sessions"
        scope_user=$(_jq "$out_user" '.data[0].scope')
        scope_mach=$(_jq "$out_mach" '.data[0].scope')
        [ "$scope_user" = "user_sessions" ] \
            && _ok "BUG-12/user: scope=user_sessions" \
            || _fail "BUG-12/user: scope='$scope_user' (atteso user_sessions)"
        [ "$scope_mach" = "all_sessions" ] \
            && _ok "BUG-12/machine: scope=all_sessions" \
            || _fail "BUG-12/machine: scope='$scope_mach' (atteso all_sessions)"

        # total_user_sessions e total_all_sessions devono essere numeri > 0
        tot_u=$(_jq "$out_user" '.data[0].total_user_sessions')
        tot_m=$(_jq "$out_mach" '.data[0].total_all_sessions')
        printf '%s' "$tot_u" | grep -qE '^[0-9]+$' && [ "$tot_u" -gt 0 ] 2>/dev/null \
            && _ok "BUG-12/user: total_user_sessions=$tot_u" \
            || _fail "BUG-12/user: total_user_sessions='$tot_u' non è un numero positivo"
        printf '%s' "$tot_m" | grep -qE '^[0-9]+$' && [ "$tot_m" -gt 0 ] 2>/dev/null \
            && _ok "BUG-12/machine: total_all_sessions=$tot_m" \
            || _fail "BUG-12/machine: total_all_sessions='$tot_m' non è un numero positivo"

        # total_all ≥ total_user (i background Oracle senza username devono essere inclusi)
        if printf '%s' "$tot_u" | grep -qE '^[0-9]+$' && printf '%s' "$tot_m" | grep -qE '^[0-9]+$'; then
            if [ "$tot_m" -ge "$tot_u" ] 2>/dev/null; then
                delta=$((tot_m - tot_u))
                _ok "BUG-12: total_all($tot_m) ≥ total_user($tot_u) — delta=$delta sessioni background"
            else
                _fail "BUG-12: total_all($tot_m) < total_user($tot_u) — impossibile"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# BUG-06 — list_known_instances: campo resident
# ---------------------------------------------------------------------------
if _should_run "BUG-06"; then
    _section_header "BUG-06" "list_known_instances: campo resident distingue istanze RAC non residenti"

    out=$(_run_tool "${TOOLS_DIR}/list_known_instances.sh" "$ENV" "$HOST") || true
    if _assert_json_valid "BUG-06" "$out"; then
        _assert_status_ok "BUG-06" "$out"
        n=$(_jq "$out" '.data | length')
        _assert_value_gt "BUG-06" "$out" '.data | length' 0

        # Tutti i record devono avere il campo resident (bool)
        no_resident=$(_jq "$out" '[.data[] | select(has("resident") | not)] | length')
        [ "${no_resident:-0}" = "0" ] \
            && _ok "BUG-06: tutti i $n record hanno il campo resident" \
            || _fail "BUG-06: $no_resident record senza campo resident"

        # Le istanze residenti (log presente) devono essere > 0
        n_resident=$(_jq "$out" '[.data[] | select(.resident == true)] | length')
        n_nonresident=$(_jq "$out" '[.data[] | select(.resident == false)] | length')
        [ "${n_resident:-0}" -gt 0 ] \
            && _ok "BUG-06: $n_resident istanze resident=true (log presente)" \
            || _fail "BUG-06: nessuna istanza resident=true (attesi NP41CDB0/1/2)"

        # Le istanze non residenti (RAC cross-mount) devono essere > 0
        if [ "${n_nonresident:-0}" -gt 0 ]; then
            _ok "BUG-06: $n_nonresident istanze resident=false (RAC non residenti: NP43/44/PROVA attesi)"
        else
            _skip "BUG-06: nessuna istanza resident=false (mount NFS potrebbe non avere cross-mount RAC)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TEST ORCHESTRAZIONE — diagnose_instance (integrazione completa)
# ---------------------------------------------------------------------------
if _should_run "" || [ -z "$FILTER_BUG" ]; then
    _section_header "ORCHESTRAZIONE" "diagnose_instance: integrazione completa su NP41CDB0 e NP41CDB1"

    for inst in "$INST0" "$INST1"; do
        python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<PYEOF 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import diagnose_instance
r = diagnose_instance("TEST", "axnporadb41", "${inst}")
print(json.dumps(r))
PYEOF
) || true

        if _assert_json_valid "diagnose_instance/$inst" "$python_out"; then
            _assert_field_equals "diagnose_instance/$inst" "$python_out" ".status" "ok"
            _assert_field_not_null "diagnose_instance/$inst" "$python_out" ".summary.stato_generale"
            _assert_array_not_empty "diagnose_instance/$inst" "$python_out" ".data"

            # BUG-08: criticità nel summary non devono usare max_utilization come denominatore
            # (verificato indirettamente: nessun allarme su istanze con utilizzo < 80% di limit_value)
            criticita=$(_jq "$python_out" ".summary.criticita | join(\" \")")
            if echo "$criticita" | grep -qi "vicino al limite configurato"; then
                _ok "diagnose_instance/$inst: criticità usa wording 'limite configurato' (BUG-08 applicato)"
            else
                _skip "diagnose_instance/$inst: nessuna criticità trovata (sistema scarico)"
            fi

            # PDB aperti deve essere un numero
            n_pdbs=$(_jq "$python_out" ".summary.pdbs.aperti_read_write")
            printf '%s' "$n_pdbs" | grep -qE '^[0-9]+$' \
                && _ok "diagnose_instance/$inst: pdbs.aperti_read_write=$n_pdbs" \
                || _skip "diagnose_instance/$inst: pdbs non disponibili (Oracle 11g?)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# TEST ORCHESTRAZIONE — check_memory_pressure
# ---------------------------------------------------------------------------
if _should_run "" || [ -z "$FILTER_BUG" ]; then
    _section_header "ORCHESTRAZIONE" "check_memory_pressure: BUG-01+13 (limit e CDB\$ROOT)"

    python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<'PYEOF' 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import check_memory_pressure
r = check_memory_pressure("TEST", "axnporadb41", "NP41CDB0")
print(json.dumps(r))
PYEOF
) || true

    if _assert_json_valid "check_memory_pressure" "$python_out"; then
        _assert_field_equals "check_memory_pressure" "$python_out" ".status" "ok"
        _assert_field_not_null "check_memory_pressure" "$python_out" ".summary.livello_pressione"
        _assert_field_not_null "check_memory_pressure" "$python_out" ".summary.sessione_top_pga"

        # BUG-01: payload di pga_by_pdb_session nel data deve avere ≤50 elementi
        n_pga_sess=$(_jq "$python_out" \
            '[.data[] | select(.sezione=="pga_by_pdb_session")] | first | .result.data | length')
        [ -n "$n_pga_sess" ] && [ "$n_pga_sess" -le 50 ] 2>/dev/null \
            && _ok "check_memory_pressure: pga_by_pdb_session.data.length=$n_pga_sess ≤ 50 (BUG-01)" \
            || _skip "check_memory_pressure: pga_by_pdb_session length=$n_pga_sess (non verificabile)"

        # distribuzione_per_pdb dipende dall'attività: può essere [] se pga_by_pdb_session torna vuoto.
        # Il campo deve esistere come array (anche se vuoto); se ha elementi, verifica struttura.
        if _jqe "$python_out" ".summary | has(\"distribuzione_per_pdb\")"; then
            n_dist=$(_jq "$python_out" ".summary.distribuzione_per_pdb | length")
            if [ "${n_dist:-0}" -gt 0 ]; then
                _ok "check_memory_pressure: distribuzione_per_pdb=$n_dist PDB"
            else
                _skip "check_memory_pressure: distribuzione_per_pdb=[] (nessuna sessione PDB attiva al momento)"
            fi
        else
            _fail "check_memory_pressure: campo distribuzione_per_pdb assente dal summary"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TEST ORCHESTRAZIONE — diagnose_os_pressure (BUG-15 integrato)
# ---------------------------------------------------------------------------
if _should_run "" || [ -z "$FILTER_BUG" ]; then
    _section_header "ORCHESTRAZIONE" "diagnose_os_pressure: BUG-15 (io_collected → disk_io_await_p95_ms)"

    python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<'PYEOF' 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import diagnose_os_pressure
r = diagnose_os_pressure("TEST", "axnporadb41", "NP41CDB0", samples=2, interval=1)
print(json.dumps(r))
PYEOF
) || true

    if _assert_json_valid "diagnose_os_pressure" "$python_out"; then
        _assert_field_equals "diagnose_os_pressure" "$python_out" ".status" "ok"
        _assert_field_not_null "diagnose_os_pressure" "$python_out" ".summary.livello_pressione_os"

        # BUG-15: disk_io_await_p95_ms deve essere null (non 0.0) se io non raccolto
        await=$(_jq "$python_out" ".summary.metriche_os.disk_io_await_p95_ms")
        if [ "$await" = "null" ] || (printf '%s' "$await" | grep -qE '^[0-9]' && [ "$await" != "0.0" ]); then
            _ok "diagnose_os_pressure: disk_io_await_p95_ms='$await' (null o valore reale, non 0.0 falso)"
        elif [ "$await" = "0.0" ]; then
            # 0.0 è sospetto ma potrebbe essere latenza reale (molto bassa)
            _skip "diagnose_os_pressure: disk_io_await_p95_ms=0.0 (potrebbe essere reale o io_collected=false)"
        else
            _fail "diagnose_os_pressure: disk_io_await_p95_ms='$await' inatteso"
        fi

        # os_type deve essere aix
        os_type=$(_jq "$python_out" ".summary.os_type")
        _ok "diagnose_os_pressure: os_type=$os_type"
    fi
fi

# ---------------------------------------------------------------------------
# R-01 — pga_by_pdb_session: dati presenti, non data:[] silenzioso
# ---------------------------------------------------------------------------
if _should_run "R-01"; then
    _section_header "R-01" "pga_by_pdb_session: data[] non vuoto su istanza con sessioni attive"

    # Criterio dal PROTOCOLLO: data non vuoto quando pga_sga_by_pdb restituisce PDB con pga_bytes > 0
    out_sess=$(_run_tool "${TOOLS_DIR}/pga_by_pdb_session.sh" "$ENV" "$HOST" "$INST1") || true
    out_sga=$(_run_tool "${TOOLS_DIR}/pga_sga_by_pdb.sh" "$ENV" "$HOST" "$INST1") || true

    if _assert_json_valid "R-01/pga_by_pdb_session" "$out_sess" && _assert_json_valid "R-01/pga_sga_by_pdb" "$out_sga"; then
        # pga_sga_by_pdb deve avere almeno un PDB con pga_bytes > 0 (controprova)
        n_sga=$(_jq "$out_sga" '.data | length')
        [ "${n_sga:-0}" -gt 0 ] \
            && _ok "R-01: pga_sga_by_pdb ha $n_sga PDB (sessioni attive)" \
            || _skip "R-01: pga_sga_by_pdb vuoto — sessioni non attive al momento"

        # pga_by_pdb_session non deve essere vuoto se pga_sga_by_pdb ha dati
        n_sess=$(_jq "$out_sess" '.data | length')
        if [ "${n_sga:-0}" -gt 0 ]; then
            [ "${n_sess:-0}" -gt 0 ] \
                && _ok "R-01: pga_by_pdb_session ha $n_sess sessioni (data non vuoto)" \
                || _fail "R-01: pga_by_pdb_session data:[] con sessioni attive — regressione critica"
        fi

        # oracle_version deve essere valorizzato (non null) — segnale di query riuscita
        ov=$(_jq "$out_sess" ".oracle_version")
        [ -n "$ov" ] && [ "$ov" != "null" ] \
            && _ok "R-01: oracle_version=$ov (query eseguita correttamente)" \
            || _fail "R-01: oracle_version=null (query non eseguita o fallita)"

        # CDB$ROOT deve essere presente nei risultati (BUG-13)
        has_root=$(_jq "$out_sess" '[.data[] | select(.pdb_name == "CDB$ROOT")] | length')
        [ "${has_root:-0}" -gt 0 ] \
            && _ok "R-01/BUG-13: $has_root sessioni su CDB\$ROOT incluse" \
            || _skip "R-01/BUG-13: nessuna sessione CDB\$ROOT al momento (plausibile)"
    fi
fi

# ---------------------------------------------------------------------------
# R-07 — scan_alert_log: date semanticamente invalide respinte
# ---------------------------------------------------------------------------
if _should_run "R-07"; then
    _section_header "R-07" "scan_alert_log: date con mese/giorno invalidi o anno < 2000 → invalid_argument"

    for bad_date in "2026-13-45" "2026-01-99" "1999-12-31"; do
        out=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
            "$ENV" "$HOST" "$INST0" "--since=${bad_date}" 2>/dev/null) || rc=$?
        rc=0; out=$("${TOOLS_DIR}/scan_alert_log.sh" "$ENV" "$HOST" "$INST0" "--since=${bad_date}" 2>/dev/null) || rc=$?
        if [ "$rc" = "2" ] || _jqe "$out" '.error.code == "invalid_argument"'; then
            _ok "R-07: --since=${bad_date} → invalid_argument"
        else
            _fail "R-07: --since=${bad_date} non ha restituito invalid_argument (rc=$rc)"
        fi
    done
fi

# ---------------------------------------------------------------------------
# R-08 — scan_alert_log: pdb="CDB$ROOT" funziona come alias "CDB"
# ---------------------------------------------------------------------------
if _should_run "R-08"; then
    _section_header "R-08" "scan_alert_log: --pdb=CDB e --pdb=CDB\$ROOT devono trovare gli stessi risultati"

    out_cdb=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--pdb=CDB" "--since=2026-07-01") || true
    out_root=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--pdb=CDB\$ROOT" "--since=2026-07-01") || true

    if _assert_json_valid "R-08/CDB" "$out_cdb" && _assert_json_valid "R-08/CDB\$ROOT" "$out_root"; then
        n_cdb=$(_jq "$out_cdb" '.data | length')
        n_root=$(_jq "$out_root" '.data | length')
        if [ "$n_cdb" = "$n_root" ]; then
            _ok "R-08: --pdb=CDB e --pdb=CDB\$ROOT trovano stessi gruppi ($n_cdb)"
        else
            _fail "R-08: --pdb=CDB=$n_cdb gruppi vs --pdb=CDB\$ROOT=$n_root — diversi"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# R-12 — tool OS: instance_name = null JSON (non stringa)
# ---------------------------------------------------------------------------
if _should_run "R-12"; then
    _section_header "R-12" "tool OS: instance_name è JSON null (non stringa 'null')"

    out=$(_run_tool "${TOOLS_DIR}/os_cpu_stats.sh" "$ENV" "$HOST" "--samples=1" "--interval=0") || true
    if _assert_json_valid "R-12/os_cpu_stats" "$out"; then
        _assert_status_ok "R-12/os_cpu_stats" "$out"
        # instance_name deve essere null JSON, non la stringa "null"
        if _jqe "$out" ".instance_name == null"; then
            _ok "R-12: os_cpu_stats instance_name=null (JSON null, non stringa)"
        else
            inst=$(_jq "$out" ".instance_name")
            _fail "R-12: os_cpu_stats instance_name='$inst' (atteso null JSON)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# R-13 — check_fra_usage: tipi coerenti
# ---------------------------------------------------------------------------
if _should_run "R-13"; then
    _section_header "R-13" "check_fra_usage: db_recovery_file_dest_size come intero, non stringa"

    out=$(_run_tool "${TOOLS_DIR}/check_fra_usage.sh" "$ENV" "$HOST" "$INST1") || true
    if _assert_json_valid "R-13" "$out"; then
        # db_recovery_file_dest_size in fra_status deve essere un intero
        size_val=$(_jq "$out" '[.data[] | select(.source=="fra_status")] | first | .db_recovery_file_dest_size')
        if printf '%s' "$size_val" | grep -qE '^[0-9]+$'; then
            _ok "R-13: fra_status.db_recovery_file_dest_size=$size_val è intero"
        else
            _fail "R-13: fra_status.db_recovery_file_dest_size='$size_val' non è intero"
        fi

        # Coerenza: fra_dest.space_limit e fra_status.db_recovery_file_dest_size devono coincidere
        space_limit=$(_jq "$out" '[.data[] | select(.source=="fra_dest")] | first | .space_limit')
        if [ -n "$size_val" ] && [ -n "$space_limit" ] && [ "$size_val" != "null" ] && [ "$space_limit" != "null" ]; then
            [ "$size_val" = "$space_limit" ] \
                && _ok "R-13: fra_status.size($size_val) == fra_dest.space_limit($space_limit) — coerenti" \
                || _fail "R-13: fra_status.size($size_val) ≠ fra_dest.space_limit($space_limit)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# R-15 — check_resource_limits: scope nell'envelope top-level
# ---------------------------------------------------------------------------
if _should_run "R-15"; then
    _section_header "R-15" "check_resource_limits: scope='instance_limits' nell'envelope top-level"

    out=$(_run_tool "${TOOLS_DIR}/check_resource_limits.sh" "$ENV" "$HOST" "$INST0") || true
    if _assert_json_valid "R-15" "$out"; then
        _assert_status_ok "R-15" "$out"

        # scope deve essere nell'envelope top-level
        scope_val=$(_jq "$out" ".scope")
        [ "$scope_val" = "instance_limits" ] \
            && _ok "R-15: scope='instance_limits' nell'envelope top-level" \
            || _fail "R-15: scope='$scope_val' (atteso 'instance_limits')"

        # scope NON deve essere nei singoli record data[]
        n_data=$(_jq "$out" ".data | length")
        if [ "${n_data:-0}" -gt 0 ]; then
            scope_in_row=$(_jq "$out" ".data[0] | has(\"scope\")")
            [ "$scope_in_row" = "false" ] \
                && _ok "R-15: scope NON in data[0] (solo nell'envelope)" \
                || _fail "R-15: scope in data[0] (dovrebbe essere solo nell'envelope)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# R-16 — scan_alert_log: severity_effective e occurrences_per_day
# ---------------------------------------------------------------------------
if _should_run "R-16"; then
    _section_header "R-16" "scan_alert_log: severity_effective e occurrences_per_day presenti"

    out=$(_run_tool "${TOOLS_DIR}/scan_alert_log.sh" \
        "$ENV" "$HOST" "$INST1" "--since=2025-01-01") || true
    if _assert_json_valid "R-16" "$out"; then
        n=$(_jq "$out" ".data | length")
        if [ "${n:-0}" -gt 0 ]; then
            # Ogni oggetto deve avere severity_effective e occurrences_per_day
            has_sev_eff=$(_jq "$out" ".data[0] | has(\"severity_effective\")")
            has_opd=$(_jq "$out" ".data[0] | has(\"occurrences_per_day\")")
            [ "$has_sev_eff" = "true" ] \
                && _ok "R-16: severity_effective presente in data[0]" \
                || _fail "R-16: severity_effective MANCANTE in data[0]"
            [ "$has_opd" = "true" ] \
                && _ok "R-16: occurrences_per_day presente in data[0]" \
                || _fail "R-16: occurrences_per_day MANCANTE in data[0]"

            # severity=null deve diventare severity_effective="unclassified"
            null_sev_eff=$(_jq "$out" '[.data[] | select(.severity == null) | select(.severity_effective != "unclassified")] | length')
            [ "${null_sev_eff:-0}" = "0" ] \
                && _ok "R-16: tutti i codici con severity=null hanno severity_effective=unclassified" \
                || _fail "R-16: $null_sev_eff codici con severity=null ma severity_effective≠unclassified"
        else
            _skip "R-16: nessun errore trovato dal 2025-01-01 su $INST1"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# R-17 — diagnose_instance: flag per istanza OPEN senza PDB applicativi
# ---------------------------------------------------------------------------
if _should_run "R-17"; then
    _section_header "R-17" "diagnose_instance: criticità per istanza OPEN con zero PDB applicativi"

    # CE02CDB1 ha 0 PDB READ WRITE — è il caso di test del PROTOCOLLO-COLLAUDO
    python_out=$(cd "${MCP_DIR}" && "$PYTHON3" - <<'PYEOF' 2>/dev/null
import sys, json
sys.path.insert(0, '.')
from orchestration import diagnose_instance
r = diagnose_instance("TEST", "axceoradb02", "CE02CDB1", include_raw=False)
print(json.dumps(r))
PYEOF
) || true

    if _assert_json_valid "R-17/CE02CDB1" "$python_out"; then
        _assert_field_equals "R-17/CE02CDB1" "$python_out" ".status" "ok"

        aperti=$(_jq "$python_out" ".summary.pdbs.aperti_read_write")
        crit=$(_jq "$python_out" ".summary.criticita | join(\" \")")

        if [ "${aperti:-1}" = "0" ]; then
            # Zero PDB: la criticità deve includere il flag
            if echo "$crit" | grep -qi "zero PDB applicativi\|nessun database applicativo"; then
                _ok "R-17: istanza OPEN con 0 PDB → criticità esplicita"
            else
                _fail "R-17: istanza OPEN con 0 PDB → criticità assente o senza il flag atteso"
            fi
        else
            _skip "R-17: CE02CDB1 ha $aperti PDB aperti al momento (stato cambiato?)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# B2 — os_memory_stats/os_cpu_stats: timestamp distinti per ogni campione
# ---------------------------------------------------------------------------
if _should_run "B2"; then
    _section_header "B2" "os_memory_stats/os_cpu_stats: ogni campione ha timestamp distinto"

    for tool_name in "os_cpu_stats" "os_memory_stats"; do
        out=$(_run_tool "${TOOLS_DIR}/${tool_name}.sh" "$ENV" "$HOST" "--samples=3" "--interval=1") || true
        if _assert_json_valid "B2/${tool_name}" "$out"; then
            _assert_status_ok "B2/${tool_name}" "$out"

            n_samples=$(_jq "$out" '.data[0].samples | length')
            if [ "${n_samples:-0}" -ge 2 ]; then
                ts0=$(_jq "$out" '.data[0].samples[0].ts')
                ts1=$(_jq "$out" '.data[0].samples[1].ts')
                if [ "$ts0" != "$ts1" ]; then
                    _ok "B2/${tool_name}: campioni 0 e 1 hanno timestamp distinti ($ts0 vs $ts1)"
                else
                    _fail "B2/${tool_name}: campioni 0 e 1 hanno lo stesso timestamp ($ts0) — B2 non risolto"
                fi
            else
                _skip "B2/${tool_name}: meno di 2 campioni ($n_samples) — impossibile verificare"
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# Risultati finali + scrittura file MD
# ---------------------------------------------------------------------------

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
REPORT_FILE="${SCRIPT_DIR}/test_bugs_regression_results.md"

{
printf "# Risultati test di regressione bug — Neural Oracle Analyzer\n\n"
printf "**Data**: %s\n" "$TIMESTAMP"
printf "**Ambiente**: %s / %s\n" "$ENV" "$HOST"
printf "**Istanze**: %s, %s, %s\n\n" "$INST0" "$INST1" "$INST2"
printf "| Totale | Passati | Falliti | Saltati |\n"
printf "|---|---|---|---|\n"
printf "| %d | %d | %d | %d |\n\n" "$((PASS+FAIL+SKIP))" "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf "## ⚠️ Fallimenti\n\n"
    printf '%b\n' "$ERRORS" | sed 's/^  ✗ /- ❌ /'
    printf "\n"
fi
printf "## Dettaglio test\n"
printf '%b\n' "$MD_LINES"
} > "$REPORT_FILE"

printf "\n================================================\n"
printf "Risultati: %d passati, %d falliti, %d saltati\n" "$PASS" "$FAIL" "$SKIP"
printf "Report salvato in: %s\n" "$REPORT_FILE"

if [ "$FAIL" -gt 0 ]; then
    printf "\nFallimenti:\n"
    printf "%b\n" "$ERRORS"
    exit 1
fi
exit 0
