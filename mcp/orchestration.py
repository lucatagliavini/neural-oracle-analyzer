"""orchestration.py — tool orchestrati di livello 1 per Neural Oracle Analyzer.

Ogni funzione pubblica combina più tool primitivi in sequenza o in parallelo,
applica la logica del runbook DBA e restituisce un envelope arricchito con:
  - summary: interpretazione in italiano dei risultati
  - details: risultati raw di ogni primitivo invocato

Convenzioni:
  - Valori che provengono da Oracle (stati, codici, ruoli) restano in inglese.
  - Campi interpretativi scritti da noi (summary, raccomandazioni, interpretazione) in italiano.
  - Ogni funzione restituisce sempre un dict conforme all'envelope JSON del progetto.
  - status="ok" anche se alcuni primitivi hanno fallito: il fallimento parziale è
    rappresentato nei details e nel summary, non come errore dell'orchestrato.

Tool esposti:
    diagnose_instance(env, host, inst)      → discovery completa istanza
    check_memory_pressure(env, host, inst)  → analisi pressione memoria/PGA
    runbook_ora04030(env, host, inst, **kw) → runbook completo per ORA-04030
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Any, Optional

from runner import run_primitive_tool


# ---------------------------------------------------------------------------
# Helpers interni
# ---------------------------------------------------------------------------

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _envelope(tool: str, env: str, host: str, inst: Optional[str],
              data: list, summary: dict) -> dict:
    """Costruisce l'envelope orchestrato con summary + details."""
    return {
        "tool": tool,
        "generated_at": _now_iso(),
        "environment": env,
        "hostname": host,
        "instance_name": inst,
        "oracle_version": None,   # non applicabile agli orchestrati
        "status": "ok",
        "summary": summary,
        "data": data,
        "error": None,
    }


def _run_parallel(tasks: list[tuple]) -> dict[str, dict]:
    """Esegue più chiamate run_primitive_tool in parallelo.

    tasks: lista di (label, script_name, *args)
    Restituisce dict {label: result}.
    """
    results: dict[str, dict] = {}
    with ThreadPoolExecutor(max_workers=min(len(tasks), 8)) as executor:
        future_map = {
            executor.submit(run_primitive_tool, script, *args): label
            for label, script, *args in tasks
        }
        for future in as_completed(future_map):
            label = future_map[future]
            try:
                results[label] = future.result()
            except Exception as exc:
                results[label] = {
                    "status": "error",
                    "data": [],
                    "error": {"code": "query_failed", "message": str(exc)},
                }
    return results


def _ok(r: dict) -> bool:
    return r.get("status") == "ok"


def _data(r: dict) -> list:
    return r.get("data", [])


def _first(r: dict) -> Optional[dict]:
    d = _data(r)
    return d[0] if d else None


# ---------------------------------------------------------------------------
# diagnose_instance
# ---------------------------------------------------------------------------

def diagnose_instance(env: str, host: str, inst: str) -> dict:
    """Discovery completa di una istanza Oracle.

    Esegue in parallelo:
      - identify_instance   → stato e versione
      - list_pdbs           → PDB aperti (12c+)
      - check_fra_usage     → stato Flash Recovery Area
      - check_resource_limits → limiti sessioni/processi

    Produce un summary con:
      - stato generale dell'istanza
      - PDB aperti/chiusi (se disponibili)
      - eventuali criticità su FRA o limiti di risorsa
    """
    TOOL = "diagnose_instance"

    tasks = [
        ("instance",  "identify_instance",    env, host, inst),
        ("pdbs",      "list_pdbs",             env, host, inst),
        ("fra",       "check_fra_usage",       env, host, inst),
        ("resources", "check_resource_limits", env, host, inst),
    ]
    res = _run_parallel(tasks)

    # --- Analisi identify_instance ---
    inst_row = _first(res["instance"])
    if not _ok(res["instance"]) or not inst_row:
        # Istanza non raggiungibile — interrompi con errore
        return {
            "tool": TOOL,
            "generated_at": _now_iso(),
            "environment": env,
            "hostname": host,
            "instance_name": inst,
            "oracle_version": None,
            "status": "error",
            "summary": {},
            "data": [],
            "error": res["instance"].get("error") or {
                "code": "connection_failed",
                "message": "Impossibile raggiungere l'istanza Oracle.",
            },
        }

    oracle_version = res["instance"].get("oracle_version")
    instance_status = inst_row.get("status")          # OPEN / MOUNTED
    db_status = inst_row.get("database_status")        # ACTIVE / SUSPENDED
    instance_role = inst_row.get("instance_role")      # PRIMARY_INSTANCE
    startup_time = inst_row.get("startup_time")

    # --- Analisi PDB ---
    pdbs_available = _ok(res["pdbs"])
    pdbs_open = [p for p in _data(res["pdbs"]) if p.get("open_mode") == "READ WRITE"]
    pdbs_restricted = [p for p in _data(res["pdbs"]) if p.get("restricted") == "YES"]
    pdbs_closed = [p for p in _data(res["pdbs"])
                   if p.get("open_mode") not in ("READ WRITE", "READ ONLY")]

    # --- Analisi FRA ---
    fra_criticita = []
    if _ok(res["fra"]):
        for row in _data(res["fra"]):
            pct = row.get("pct_space_used", 0) or 0
            if float(pct) >= 90:
                fra_criticita.append(
                    f"FRA al {pct}% — rischio blocco archivelog"
                )
            elif float(pct) >= 75:
                fra_criticita.append(
                    f"FRA al {pct}% — monitorare utilizzo"
                )

    # --- Analisi resource limits ---
    resource_criticita = []
    if _ok(res["resources"]):
        for row in _data(res["resources"]):
            name = row.get("resource_name", "")
            current = row.get("current_utilization")
            limit = row.get("max_utilization") or row.get("limit_value")
            try:
                if limit and int(limit) > 0:
                    pct = int(current or 0) / int(limit) * 100
                    if pct >= 90:
                        resource_criticita.append(
                            f"{name}: {current}/{limit} ({pct:.0f}%) — vicino al limite"
                        )
            except (ValueError, TypeError):
                pass

    # --- Costruzione summary ---
    criticita = fra_criticita + resource_criticita
    if instance_status == "OPEN" and db_status == "ACTIVE":
        stato_generale = "L'istanza è operativa e accessibile."
    elif instance_status == "MOUNTED":
        stato_generale = "L'istanza è in stato MOUNTED — il database non è aperto."
    else:
        stato_generale = f"L'istanza è in stato {instance_status}/{db_status}."

    summary = {
        "stato_generale": stato_generale,
        "instance_status": instance_status,
        "database_status": db_status,
        "instance_role": instance_role,
        "oracle_version": oracle_version,
        "startup_time": startup_time,
        "pdbs": {
            "disponibili": pdbs_available,
            "totale": len(_data(res["pdbs"])),
            "aperti_read_write": len(pdbs_open),
            "in_restricted": len(pdbs_restricted),
            "chiusi_o_mounted": len(pdbs_closed),
        } if pdbs_available else {"disponibili": False, "motivo": "non supportato (Oracle 11g) o errore"},
        "criticita": criticita if criticita else ["Nessuna criticità rilevata."],
    }

    data = [
        {"sezione": "instance",  "result": res["instance"]},
        {"sezione": "pdbs",      "result": res["pdbs"]},
        {"sezione": "fra",       "result": res["fra"]},
        {"sezione": "resources", "result": res["resources"]},
    ]

    env_out = _envelope(TOOL, env, host, inst, data, summary)
    env_out["oracle_version"] = oracle_version
    return env_out


# ---------------------------------------------------------------------------
# check_memory_pressure
# ---------------------------------------------------------------------------

def check_memory_pressure(env: str, host: str, inst: str) -> dict:
    """Analisi pressione memoria/PGA su una istanza Oracle.

    Esegue:
      - top_pga_sessions (top 20) → sessioni più costose in memoria
      - pga_by_pdb_session        → distribuzione PGA per PDB (12c+)
      - pga_sga_by_pdb            → utilizzo PGA/SGA aggregato per PDB (12c+)

    Produce un summary con:
      - sessione con PGA più alta e relativo utente
      - distribuzione della memoria tra PDB
      - valutazione della pressione complessiva
    """
    TOOL = "check_memory_pressure"

    # top_pga_sessions è sequenziale (serve per capire versione e dati base)
    top_res = run_primitive_tool("top_pga_sessions", env, host, inst)

    # Gli altri due in parallelo
    tasks = [
        ("pga_pdb_sess", "pga_by_pdb_session", env, host, inst),
        ("pga_sga",      "pga_sga_by_pdb",     env, host, inst),
    ]
    par = _run_parallel(tasks)

    oracle_version = top_res.get("oracle_version")

    # --- Analisi top PGA sessions ---
    top_sessions = _data(top_res)
    if top_sessions:
        top1 = top_sessions[0]
        top_pga_mb = round(int(top1.get("pga_alloc_mem", 0)) / 1024 / 1024, 1)
        total_pga_mb = round(
            sum(int(s.get("pga_alloc_mem", 0)) for s in top_sessions) / 1024 / 1024, 1
        )
        sessione_top = (
            f"{top1.get('username', 'SYS')} (SID non disponibile)"
            f" — {top_pga_mb} MB PGA allocata"
        )
    else:
        top_pga_mb = 0
        total_pga_mb = 0
        sessione_top = "Nessuna sessione rilevata."

    # --- Analisi distribuzione PDB ---
    pdb_distribuzione = []
    if _ok(par["pga_pdb_sess"]):
        pdb_totals: dict[str, int] = {}
        for row in _data(par["pga_pdb_sess"]):
            pdb = row.get("pdb_name") or "CDB$ROOT"
            pdb_totals[pdb] = pdb_totals.get(pdb, 0) + int(row.get("pga_used_mem", 0) or 0)
        for pdb, total in sorted(pdb_totals.items(), key=lambda x: -x[1]):
            pdb_distribuzione.append({
                "pdb": pdb,
                "pga_mb": round(total / 1024 / 1024, 1),
            })

    # --- Valutazione pressione ---
    if top_pga_mb >= 2048:
        livello_pressione = "alta"
        valutazione = (
            f"La sessione con maggior consumo usa {top_pga_mb} MB di PGA. "
            "Verificare query con large sort o hash join; considerare PGA_AGGREGATE_TARGET."
        )
    elif top_pga_mb >= 512:
        livello_pressione = "media"
        valutazione = (
            f"Utilizzo PGA nella norma per carichi intensivi ({top_pga_mb} MB sulla sessione top). "
            "Monitorare in caso di degradazione delle performance."
        )
    else:
        livello_pressione = "bassa"
        valutazione = (
            f"Nessuna pressione rilevante sulla memoria di processo ({top_pga_mb} MB sulla sessione top)."
        )

    summary = {
        "livello_pressione": livello_pressione,
        "valutazione": valutazione,
        "sessione_top_pga": sessione_top,
        "totale_pga_top20_mb": total_pga_mb,
        "distribuzione_per_pdb": pdb_distribuzione,
        "pga_sga_per_pdb_disponibile": _ok(par["pga_sga"]),
    }

    data = [
        {"sezione": "top_pga_sessions",  "result": top_res},
        {"sezione": "pga_by_pdb_session","result": par["pga_pdb_sess"]},
        {"sezione": "pga_sga_by_pdb",    "result": par["pga_sga"]},
    ]

    env_out = _envelope(TOOL, env, host, inst, data, summary)
    env_out["oracle_version"] = oracle_version
    return env_out


# ---------------------------------------------------------------------------
# runbook_ora04030
# ---------------------------------------------------------------------------

def runbook_ora04030(env: str, host: str, inst: str,
                     since: Optional[str] = None,
                     pdb: Optional[str] = None) -> dict:
    """Runbook completo per la diagnosi di ORA-04030 (out of process memory).

    Passi:
      1. scan_alert_log filtrando ORA-04030 → verifica presenza e frequenza
      2. Se ORA-04030 presente → check_memory_pressure → analisi PGA
      3. get_alert_log_info → metadati log (età, dimensione)

    Produce un summary con:
      - se ORA-04030 è presente, quante occorrenze e in quali PDB
      - valutazione della pressione memoria al momento della diagnosi
      - raccomandazioni operative
    """
    TOOL = "runbook_ora04030"

    # Step 1: scan alert log per ORA-04030
    scan_args = [env, host, inst, "--code=ORA-04030"]
    if since:
        scan_args.append(f"--since={since}")
    if pdb:
        scan_args.append(f"--pdb={pdb}")
    scan_res = run_primitive_tool("scan_alert_log", *scan_args)

    # Step 2 e 3 in parallelo (indipendenti da step 1)
    tasks = [
        ("memory",   "_orchestrated_check_memory_pressure", env, host, inst),
        ("log_info", "get_alert_log_info",                  env, host, inst),
    ]
    # check_memory_pressure è orchestrato — lo chiamiamo direttamente
    log_info_res = run_primitive_tool("get_alert_log_info", env, host, inst)
    memory_res = check_memory_pressure(env, host, inst)

    oracle_version = scan_res.get("oracle_version") or memory_res.get("oracle_version")

    # --- Analisi ORA-04030 nell'alert log ---
    ora04030_occurrences = _data(scan_res)
    totale_eventi = sum(int(r.get("count", 0)) for r in ora04030_occurrences)
    pdb_coinvolti = [r.get("pdb_name") or "CDB$ROOT" for r in ora04030_occurrences]
    last_seen = max(
        (r.get("last_seen", "") for r in ora04030_occurrences),
        default=None,
    ) or None

    # --- Log info ---
    log_row = _first(log_info_res)
    age_hours = log_row.get("age_hours") if log_row else None

    # --- Costruzione raccomandazioni ---
    raccomandazioni = []
    memory_summary = memory_res.get("summary", {})
    livello = memory_summary.get("livello_pressione", "sconosciuto")

    if totale_eventi == 0:
        presenza = "ORA-04030 non trovato nell'alert log nel periodo analizzato."
        if since:
            presenza += f" (filtro: dal {since})"
    else:
        presenza = (
            f"ORA-04030 rilevato {totale_eventi} volta/e, "
            f"ultimo evento: {last_seen}, "
            f"PDB coinvolti: {', '.join(set(pdb_coinvolti))}."
        )
        raccomandazioni.append(
            "Verificare i parametri PGA_AGGREGATE_TARGET e MEMORY_TARGET — "
            "ORA-04030 indica che un processo Oracle non riesce ad allocare memoria."
        )
        if livello == "alta":
            raccomandazioni.append(
                "La pressione PGA è attualmente ALTA: agire con priorità. "
                "Identificare la sessione top con check_memory_pressure e terminare "
                "le query con consumo anomalo."
            )
        elif livello == "media":
            raccomandazioni.append(
                "La pressione PGA è MEDIA: monitorare. "
                "Valutare incremento di PGA_AGGREGATE_TARGET se gli eventi si ripetono."
            )
        else:
            raccomandazioni.append(
                "La pressione PGA è attualmente BASSA: l'evento potrebbe essere transitorio. "
                "Verificare se il picco era legato a una query specifica (controllare i campioni nell'alert log)."
            )
        if pdb_coinvolti and any(p != "CDB$ROOT" for p in pdb_coinvolti):
            pdb_unici = list({p for p in pdb_coinvolti if p != "CDB$ROOT"})
            raccomandazioni.append(
                f"I PDB {', '.join(pdb_unici)} hanno generato errori ORA-04030: "
                "verificare i limiti di memoria assegnati a ciascun PDB."
            )

    if not raccomandazioni:
        raccomandazioni.append("Nessuna azione immediata richiesta.")

    summary = {
        "presenza_ora04030": presenza,
        "totale_eventi": totale_eventi,
        "pdb_coinvolti": list(set(pdb_coinvolti)) if totale_eventi > 0 else [],
        "ultimo_evento": last_seen,
        "pressione_memoria_attuale": livello,
        "log_age_hours": age_hours,
        "raccomandazioni": raccomandazioni,
    }

    data = [
        {"sezione": "scan_alert_log_ora04030", "result": scan_res},
        {"sezione": "check_memory_pressure",   "result": memory_res},
        {"sezione": "get_alert_log_info",       "result": log_info_res},
    ]

    env_out = _envelope(TOOL, env, host, inst, data, summary)
    env_out["oracle_version"] = oracle_version
    return env_out


# ---------------------------------------------------------------------------
# diagnose_os_pressure
# ---------------------------------------------------------------------------

def diagnose_os_pressure(env: str, host: str, inst: str,
                          samples: int = 5, interval: int = 2) -> dict:
    """Analisi pressione OS correlata con stato Oracle.

    Esegue in parallelo:
      - os_cpu_stats     → CPU user/sys/idle/wait%, run queue
      - os_memory_stats  → RAM/swap usage, page in/out
      - os_disk_stats    → filesystem usage, I/O throughput/latenza
      - os_network_stats → rx/tx bytes/sec, errori NIC per interfaccia
      - check_memory_pressure → PGA Oracle
      - check_resource_limits → limiti sessioni/processi Oracle
      - sessions_by_user      → sessioni Oracle attive per utente

    Produce un summary con:
      - livello_pressione_os:     bassa/media/alta
      - livello_pressione_oracle: bassa/media/alta (da check_memory_pressure)
      - correlazioni: osservazioni che incrociano dominio OS e Oracle
      - raccomandazioni: lista ordinata per priorità
      - details: risultati raw di ogni primitivo
    """
    TOOL = "diagnose_os_pressure"

    samples_arg = f"--samples={samples}"
    interval_arg = f"--interval={interval}"

    tasks = [
        ("cpu",     "os_cpu_stats",         env, host, samples_arg, interval_arg),
        ("memory",  "os_memory_stats",      env, host, samples_arg, interval_arg),
        ("disk",    "os_disk_stats",        env, host, samples_arg, interval_arg),
        ("network", "os_network_stats",     env, host, samples_arg, interval_arg),
        ("resources", "check_resource_limits", env, host, inst),
        ("sessions",  "sessions_by_user",      env, host, inst),
    ]
    res = _run_parallel(tasks)

    # check_memory_pressure è già un orchestrato: lo chiamiamo separatamente
    # (non può essere invocato come primitivo via run_primitive_tool)
    mem_pressure = check_memory_pressure(env, host, inst)
    res["mem_pressure"] = mem_pressure

    oracle_version = mem_pressure.get("oracle_version")

    # --- Analisi CPU ---
    cpu_summary = {}
    cpu_count = 0
    os_type = "unknown"
    if _ok(res["cpu"]):
        cpu_data_list = res["cpu"].get("data", [])
        cpu_data = cpu_data_list[0] if isinstance(cpu_data_list, list) and cpu_data_list else {}
        if isinstance(cpu_data, dict):
            cpu_summary = cpu_data.get("summary", {})
            cpu_count = cpu_data.get("cpu_count", 0) or 0
            os_type = cpu_data.get("os_type", "unknown")

    cpu_wait_avg = 0.0
    run_queue_avg = 0.0
    if cpu_summary:
        cpu_wait_avg = float((cpu_summary.get("cpu_wait_pct") or {}).get("avg") or 0)
        run_queue_avg = float((cpu_summary.get("run_queue") or {}).get("avg") or 0)

    # --- Analisi memoria OS ---
    mem_summary = {}
    swap_used_avg = 0
    swap_total = 0
    swap_used_pct = 0.0
    ram_free_pct = 100.0
    page_out_avg = 0.0
    if _ok(res["memory"]):
        mem_data_list = res["memory"].get("data", [])
        mem_data = mem_data_list[0] if isinstance(mem_data_list, list) and mem_data_list else {}
        if isinstance(mem_data, dict):
            mem_summary = mem_data.get("summary", {})
            samples_list = mem_data.get("samples", [])
            if samples_list:
                last_s = samples_list[-1]
                ram_total = float(last_s.get("ram_total_bytes") or 1)
                ram_free = float(last_s.get("ram_free_bytes") or 0)
                swap_total = float(last_s.get("swap_total_bytes") or 0)
                swap_used_s = float(last_s.get("swap_used_bytes") or 0)
                if ram_total > 0:
                    ram_free_pct = ram_free / ram_total * 100
                if swap_total > 0:
                    swap_used_pct = swap_used_s / swap_total * 100
            if mem_summary:
                page_out_avg = float((mem_summary.get("page_out_per_sec") or {}).get("avg") or 0)

    # --- Analisi disco OS ---
    disk_io_await_max = 0.0
    disk_data = {}
    if _ok(res["disk"]):
        disk_data_list = res["disk"].get("data", [])
        disk_data = disk_data_list[0] if isinstance(disk_data_list, list) and disk_data_list else {}
        if isinstance(disk_data, dict):
            disk_summary = disk_data.get("summary", {}).get("io", {})
            for dev_stats in disk_summary.values():
                await_p95 = float((dev_stats.get("await_ms") or {}).get("p95") or 0)
                if await_p95 > disk_io_await_max:
                    disk_io_await_max = await_p95

    # --- Analisi rete OS ---
    net_rx_errors_total = 0
    net_tx_errors_total = 0
    net_rx_drops_total = 0
    net_tx_drops_total = 0
    net_interfaces: list[str] = []
    if _ok(res["network"]):
        net_data_list = res["network"].get("data", [])
        net_data = net_data_list[0] if isinstance(net_data_list, list) and net_data_list else {}
        if isinstance(net_data, dict):
            for iface_row in net_data.get("interfaces", []):
                iface_name = iface_row.get("iface", "")
                net_interfaces.append(iface_name)
                net_rx_errors_total += int(iface_row.get("rx_errors") or 0)
                net_tx_errors_total += int(iface_row.get("tx_errors") or 0)
                net_rx_drops_total  += int(iface_row.get("rx_drops") or 0)
                net_tx_drops_total  += int(iface_row.get("tx_drops") or 0)

    # --- Analisi Oracle resource limits ---
    resource_near_limit = []
    if _ok(res["resources"]):
        for row in _data(res["resources"]):
            name = row.get("resource_name", "")
            current = row.get("current_utilization")
            limit = row.get("max_utilization") or row.get("limit_value")
            try:
                if limit and int(limit) > 0:
                    pct = int(current or 0) / int(limit) * 100
                    if pct >= 80:
                        resource_near_limit.append(
                            f"{name}: {current}/{limit} ({pct:.0f}%)"
                        )
            except (ValueError, TypeError):
                pass

    # --- Analisi Oracle memory pressure ---
    oracle_mem_summary = mem_pressure.get("summary", {})
    livello_pressione_oracle = oracle_mem_summary.get("livello_pressione", "sconosciuto")
    top_pga_mb = float(oracle_mem_summary.get("totale_pga_top20_mb") or 0)

    # --- Calcolo livello pressione OS ---
    # Regole: se ≥2 indicatori in zona rossa → alta; ≥1 → media; else → bassa
    indicatori_rossi = []
    indicatori_gialli = []

    if cpu_count > 0 and run_queue_avg > 2 * cpu_count:
        indicatori_rossi.append(f"run queue media ({run_queue_avg:.1f}) > 2× cpu_count ({cpu_count})")
    elif cpu_count > 0 and run_queue_avg > cpu_count:
        indicatori_gialli.append(f"run queue media ({run_queue_avg:.1f}) > cpu_count ({cpu_count})")

    if cpu_wait_avg > 40:
        indicatori_rossi.append(f"CPU wait% medio ({cpu_wait_avg:.1f}%) > 40%")
    elif cpu_wait_avg > 20:
        indicatori_gialli.append(f"CPU wait% medio ({cpu_wait_avg:.1f}%) > 20%")

    if swap_used_pct > 80:
        indicatori_rossi.append(f"swap utilizzata al {swap_used_pct:.1f}% (>80%)")
    elif swap_used_pct > 50:
        indicatori_gialli.append(f"swap utilizzata al {swap_used_pct:.1f}% (>50%)")

    if ram_free_pct < 5:
        indicatori_rossi.append(f"RAM quasi esaurita: solo {ram_free_pct:.1f}% libera")
    elif ram_free_pct < 10:
        indicatori_gialli.append(f"RAM bassa: {ram_free_pct:.1f}% libera")

    if page_out_avg > 10:
        indicatori_rossi.append(f"page-out medio ({page_out_avg:.1f}/s) — OS sta paginando su disco")
    elif page_out_avg > 1:
        indicatori_gialli.append(f"page-out medio ({page_out_avg:.1f}/s) — attività swap presente")

    if disk_io_await_max > 100:
        indicatori_rossi.append(f"latenza I/O disco p95 ({disk_io_await_max:.1f}ms) > 100ms")
    elif disk_io_await_max > 50:
        indicatori_gialli.append(f"latenza I/O disco p95 ({disk_io_await_max:.1f}ms) > 50ms")

    net_errors_total = net_rx_errors_total + net_tx_errors_total
    if net_errors_total > 100:
        indicatori_rossi.append(
            f"errori NIC totali ({net_errors_total}) > 100 — possibile problema di rete/link"
        )
    elif net_errors_total > 0:
        indicatori_gialli.append(
            f"errori NIC presenti (rx={net_rx_errors_total}, tx={net_tx_errors_total}) — monitorare"
        )

    if len(indicatori_rossi) >= 2:
        livello_pressione_os = "alta"
    elif len(indicatori_rossi) == 1 or len(indicatori_gialli) >= 2:
        livello_pressione_os = "media"
    else:
        livello_pressione_os = "bassa"

    # --- Correlazioni cross-domain ---
    correlazioni = []

    if run_queue_avg > (2 * cpu_count if cpu_count > 0 else 4) and top_pga_mb >= 512:
        correlazioni.append(
            "CPU run queue alta + PGA Oracle elevata: possibile bottleneck CPU da query intensive "
            "con hash join/sort su disco. Verificare query con alto consumo CPU."
        )

    if cpu_wait_avg > 30:
        correlazioni.append(
            f"CPU wait% OS alto ({cpu_wait_avg:.1f}%): attesa I/O significativa a livello OS. "
            "Correlare con check_fra_usage per verificare pressione su disco archivelog/FRA."
        )

    if swap_used_pct > 50 and livello_pressione_oracle in ("alta", "media"):
        correlazioni.append(
            f"Swap OS utilizzata al {swap_used_pct:.1f}% e pressione Oracle {livello_pressione_oracle}: "
            "rischio OOM per processi Oracle. Ridurre PGA_AGGREGATE_TARGET o sessioni concorrenti."
        )

    if swap_used_pct > 80 and not _ok(res["resources"]):
        correlazioni.append(
            "Swap OS >80% e Oracle irraggiungibile: possibile OOM — host sotto stress critico. "
            "Verificare se i processi Oracle sono in stato D (uninterruptible sleep)."
        )

    if disk_io_await_max > 50 and top_pga_mb >= 512:
        correlazioni.append(
            f"Latenza disco p95 {disk_io_await_max:.1f}ms + PGA Oracle elevata ({top_pga_mb:.0f}MB): "
            "probabile I/O da sort/hash su disco. Aumentare PGA_AGGREGATE_TARGET o ottimizzare le query."
        )

    if net_errors_total > 0 and livello_pressione_oracle in ("alta", "media"):
        correlazioni.append(
            f"Errori NIC ({net_errors_total}) e pressione Oracle {livello_pressione_oracle}: "
            "possibili timeout di connessione tra application server e DB. "
            "Verificare l'interfaccia di rete e lo switch di rete."
        )

    if resource_near_limit:
        correlazioni.append(
            "Oracle vicino ai limiti di risorse: " + "; ".join(resource_near_limit) + ". "
            "Ulteriori connessioni potrebbero fallire con ORA-00018 o ORA-00020."
        )

    if not correlazioni:
        correlazioni.append("Nessuna correlazione critica rilevata tra OS e Oracle.")

    # --- Raccomandazioni ---
    raccomandazioni = []
    if livello_pressione_os == "alta":
        raccomandazioni.append(
            "URGENTE: pressione OS alta. Identificare e ridurre i processi che consumano "
            "CPU o memoria prima che si verifichino errori Oracle (ORA-04030, ORA-07445)."
        )
    if swap_used_pct > 80:
        raccomandazioni.append(
            f"Swap al {swap_used_pct:.1f}%: aggiungere RAM o ridurre il numero di sessioni Oracle "
            "per evitare OOM. Considerare di verificare l'impostazione di MEMORY_TARGET."
        )
    if cpu_wait_avg > 30:
        raccomandazioni.append(
            "CPU wait elevato: verificare colli di bottiglia I/O (iostat, check_fra_usage). "
            "Possibile necessità di bilanciare i datafile su più spindle/LUN."
        )
    if disk_io_await_max > 50:
        raccomandazioni.append(
            f"Latenza disco elevata ({disk_io_await_max:.1f}ms p95): verificare saturazione storage. "
            "Considerare la distribuzione dei file Oracle su volumi separati."
        )
    if net_errors_total > 0:
        raccomandazioni.append(
            f"Errori NIC rilevati (rx={net_rx_errors_total}, tx={net_tx_errors_total}, "
            f"drop={net_rx_drops_total + net_tx_drops_total}): controllare lo stato del link "
            "con 'entstat -d' (AIX) o 'ethtool' (Linux) e verificare i log dello switch."
        )
    if livello_pressione_oracle == "alta":
        raccomandazioni.append(
            "Pressione PGA Oracle alta: eseguire check_memory_pressure per identificare le sessioni "
            "con consumo anomalo e valutare il tuning di PGA_AGGREGATE_TARGET."
        )
    if not raccomandazioni:
        raccomandazioni.append("Nessuna azione immediata richiesta. Sistema nella norma.")

    summary = {
        "livello_pressione_os": livello_pressione_os,
        "livello_pressione_oracle": livello_pressione_oracle,
        "os_type": os_type,
        "indicatori_critici_os": indicatori_rossi,
        "indicatori_attenzione_os": indicatori_gialli,
        "correlazioni": correlazioni,
        "raccomandazioni": raccomandazioni,
        "metriche_os": {
            "cpu_wait_pct_avg": round(cpu_wait_avg, 1),
            "run_queue_avg": round(run_queue_avg, 1),
            "cpu_count": cpu_count,
            "ram_free_pct": round(ram_free_pct, 1),
            "swap_used_pct": round(swap_used_pct, 1),
            "page_out_per_sec_avg": round(page_out_avg, 1),
            "disk_io_await_p95_ms": round(disk_io_await_max, 1),
            "net_rx_errors": net_rx_errors_total,
            "net_tx_errors": net_tx_errors_total,
            "net_rx_drops": net_rx_drops_total,
            "net_tx_drops": net_tx_drops_total,
        },
        "pressione_oracle_detail": {
            "livello": livello_pressione_oracle,
            "top_pga_mb": top_pga_mb,
            "resource_near_limit": resource_near_limit,
        },
    }

    data = [
        {"sezione": "os_cpu_stats",          "result": res["cpu"]},
        {"sezione": "os_memory_stats",        "result": res["memory"]},
        {"sezione": "os_disk_stats",          "result": res["disk"]},
        {"sezione": "os_network_stats",       "result": res["network"]},
        {"sezione": "check_memory_pressure",  "result": mem_pressure},
        {"sezione": "check_resource_limits",  "result": res["resources"]},
        {"sezione": "sessions_by_user",       "result": res["sessions"]},
    ]

    env_out = _envelope(TOOL, env, host, inst, data, summary)
    env_out["oracle_version"] = oracle_version
    return env_out

