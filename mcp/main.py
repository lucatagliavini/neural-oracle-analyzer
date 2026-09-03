"""main.py — FastAPI MCP server per Neural Oracle Analyzer.

Espone i 13 tool primitivi bash in due modi:
  1. Protocollo MCP wire (JSON-RPC 2.0, Streamable HTTP) — per client MCP come Bob/Claude Code
  2. Endpoint REST custom — per test/debug diretti

Avvio (gestito dal systemd unit):
    uvicorn main:app --host 0.0.0.0 --port 8420 --no-access-log

Autenticazione:
    Header obbligatorio: X-API-Key: <valore di MCP_API_KEY nel .env>

Endpoint MCP (protocollo wire):
    POST /mcp                             — JSON-RPC 2.0 (initialize / tools/list / tools/call)

Endpoint REST (debug):
    GET  /health                          — healthcheck (no auth)
    GET  /tools                           — lista tool disponibili (no auth)
    POST /tools/{tool_name}               — invoca un tool primitivo
"""
from __future__ import annotations

import asyncio
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Annotated, Any, Optional

from fastapi import Depends, FastAPI, HTTPException, Request, Security, status
from fastapi.responses import JSONResponse
from fastapi.security import APIKeyHeader
from pydantic import BaseModel, Field

import config
from orchestration import diagnose_instance, check_memory_pressure, runbook_ora04030, diagnose_os_pressure
from runner import run_primitive_tool

# Semaforo globale che limita il numero di tools/call concorrenti.
# Inizializzato in startup per poter usare il loop asyncio corretto.
_call_semaphore: asyncio.Semaphore | None = None


def _get_semaphore() -> asyncio.Semaphore:
    global _call_semaphore
    if _call_semaphore is None:
        _call_semaphore = asyncio.Semaphore(config.MCP_MAX_CONCURRENT)
    return _call_semaphore

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Neural Oracle Analyzer — MCP Server",
    description="Tool diagnostici Oracle esposti come server MCP HTTP.",
    version="1.0.0",
    docs_url="/docs",
    redoc_url=None,
)

# ---------------------------------------------------------------------------
# Autenticazione
# ---------------------------------------------------------------------------

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


def _require_api_key(key: Annotated[Optional[str], Security(_api_key_header)] = None) -> str:
    if not config.API_KEY:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="MCP_API_KEY non configurata sul server.",
        )
    if key != config.API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key mancante o non valida.",
            headers={"WWW-Authenticate": "ApiKey"},
        )
    return key


AuthDep = Annotated[str, Depends(_require_api_key)]

# ---------------------------------------------------------------------------
# Modelli request/response
# ---------------------------------------------------------------------------


class ToolResponse(BaseModel):
    """Envelope JSON restituito da ogni tool primitivo."""

    model_config = {"extra": "allow"}

    tool: str
    generated_at: str
    environment: Optional[str]
    hostname: Optional[str]
    instance_name: Optional[str]
    oracle_version: Optional[str]
    status: str
    data: list[Any]
    error: Optional[Any]


# Parametri comuni a quasi tutti i tool
class _BaseRequest(BaseModel):
    environment: str = Field(..., description="Enum: EURO, TEST, CERT, INTE, COLL, PROD")
    hostname: str = Field(..., description="Hostname fisico del server Oracle (es. axnporadb41)")
    instance_name: str = Field(..., description="Nome CDB (es. NP41CDB0)")


# ---------------------------------------------------------------------------
# Descrizioni tool (usate da GET /tools)
# ---------------------------------------------------------------------------

TOOL_CATALOG: list[dict] = [
    # --- Inventario infrastruttura (NFS locale, no SSH, no sqlplus) ---
    {
        "name": "list_known_hosts",
        "description": (
            "INVENTARIO — Elenca gli host Oracle fisici noti dal mount NFS locale. "
            "Non verifica se gli host sono raggiungibili: restituisce ciò che è configurato. "
            "Usare come primo passo per scoprire quali hostname esistono."
        ),
        "params": ["environment"],
    },
    {
        "name": "list_known_instances",
        "description": (
            "INVENTARIO — Elenca le istanze Oracle configurate su un host leggendo il mount NFS, "
            "senza SSH né sqlplus. Non indica se le istanze sono accese o spente. "
            "Funziona anche se l'host Oracle è irraggiungibile. "
            "Usare per sapere quali istanze esistono, non quale sia il loro stato."
        ),
        "params": ["environment", "hostname"],
    },
    {
        "name": "list_all_hosts_and_instances",
        "description": (
            "INVENTARIO — Inventario completo di tutti gli host e le istanze Oracle configurate, "
            "in una sola chiamata dal mount NFS locale. Zero SSH, zero sqlplus. "
            "Non indica se le istanze sono accese o spente. "
            "Usare per esplorare l'intera infrastruttura configurata."
        ),
        "params": ["environment"],
    },
    # --- Stato operativo in tempo reale (richiede connessione Oracle) ---
    {
        "name": "list_all_instances_status",
        "description": (
            "STATO OPERATIVO — Verifica in tempo reale lo stato di tutte le istanze Oracle "
            "di un host interrogando Oracle in parallelo. "
            "Indica se ogni istanza è OPEN, MOUNTED o irraggiungibile (spenta/errore). "
            "Usare quando si vuole sapere quali istanze sono accese su un host."
        ),
        "params": ["environment", "hostname"],
    },
    {
        "name": "list_instances_on_host",
        "description": (
            "INVENTARIO VIA SSH — Elenca le istanze Oracle configurate su un host "
            "leggendo gli env file Oracle via SSH (ls ~/NP*.env). "
            "Non indica se le istanze sono accese o spente. "
            "Preferire list_known_instances (più veloce, no SSH) salvo necessità di dati SSH-freschi."
        ),
        "params": ["environment", "hostname"],
    },
    {
        "name": "identify_instance",
        "description": (
            "STATO OPERATIVO — Interroga Oracle (v$instance) per una singola istanza nota. "
            "Restituisce versione, stato (OPEN/MOUNTED), ruolo, startup time. "
            "Fallisce se l'istanza è spenta o irraggiungibile. "
            "Usare list_all_instances_status per verificare più istanze contemporaneamente."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    # --- Diagnostica log (NFS locale) ---
    {
        "name": "get_alert_log_info",
        "description": (
            "METADATI LOG — Restituisce path, dimensione e data ultima modifica dell'alert log "
            "senza aprirlo. Risposta istantanea dal filesystem NFS. "
            "Usare prima di scan_alert_log per verificare se il log è aggiornato e quanto è grande."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "scan_alert_log",
        "description": (
            "ANALISI LOG — Scansiona l'alert log Oracle cercando tutti gli errori ORA- "
            "raggruppati per codice e PDB. Legge dal mount NFS. "
            "Filtri opzionali: code (es. ORA-04030), since (YYYY-MM-DD), pdb (nome PDB o 'CDB' per il root). "
            "Usare per diagnosticare errori ricorrenti o indagare un incidente."
        ),
        "params": ["environment", "hostname", "instance_name", "code?", "since?", "pdb?"],
    },
    {
        "name": "tail_alert_log",
        "description": (
            "ANALISI LOG — Restituisce le ultime N righe dell'alert log Oracle dal mount NFS. "
            "Usare per vedere gli eventi più recenti senza scansionare l'intero file. "
            "Parametro opzionale: lines (default 100)."
        ),
        "params": ["environment", "hostname", "instance_name", "lines?"],
    },
    # --- Diagnostica istanza (richiede connessione Oracle) ---
    {
        "name": "get_diag_home",
        "description": (
            "DIAGNOSTICA — Restituisce il percorso DIAGNOSTIC_DEST dell'istanza Oracle. "
            "Usare per costruire dinamicamente path di diagnostica non coperti dal mount NFS."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "check_fra_usage",
        "description": (
            "DIAGNOSTICA SPAZIO — Verifica utilizzo e stato della Flash Recovery Area. "
            "Restituisce spazio totale, usato, riciclabile e dettaglio per tipo di file. "
            "Usare quando si sospetta saturazione della FRA o per monitoraggio preventivo."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "check_resource_limits",
        "description": (
            "DIAGNOSTICA RISORSE — Verifica i limiti Oracle di sessioni, processi e locks "
            "(v$resource_limit) con utilizzo corrente vs massimo. "
            "Usare quando si sospetta esaurimento connessioni o processi."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "list_pdbs",
        "description": (
            "STATO OPERATIVO — Elenca i PDB del CDB con stato (OPEN/MOUNTED/RESTRICTED) "
            "e modalità di apertura (show pdbs). Richiede Oracle 12c+. "
            "Usare per verificare quali database applicativi sono aperti all'interno del CDB."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    # --- Sessioni (richiede connessione Oracle) ---
    {
        "name": "sessions_by_user",
        "description": (
            "SESSIONI — Conta le sessioni Oracle attive raggruppate per utente e stato "
            "(ACTIVE/INACTIVE) da v$session. "
            "Usare per capire chi è connesso e quante connessioni ha aperte."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "sessions_by_machine",
        "description": (
            "SESSIONI — Conta le sessioni Oracle attive raggruppate per macchina client e stato "
            "da v$session. "
            "Usare per capire da quali server/applicazioni arrivano le connessioni."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    # --- Memoria/PGA (richiede connessione Oracle) ---
    {
        "name": "pga_sga_by_pdb",
        "description": (
            "MEMORIA — Utilizzo PGA e SGA aggregato per PDB da v$rsrcpdbmetric. "
            "Richiede Oracle 12c+ e Resource Manager con PDB plan attivo. "
            "Usare per confrontare il consumo di memoria tra PDB diversi."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "pga_by_pdb_session",
        "description": (
            "MEMORIA — Utilizzo PGA per singola sessione con dettaglio PDB di appartenenza "
            "(join v$session/v$process/cdb_pdbs). Richiede Oracle 12c+. "
            "Usare per identificare quale sessione/PDB consuma più memoria."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "top_pga_sessions",
        "description": (
            "MEMORIA — Top N sessioni Oracle ordinate per utilizzo PGA decrescente "
            "(v$process + v$session). Funziona su 11g, 12c, 19c. "
            "Usare come primo passo per diagnosticare pressione sulla memoria di processo. "
            "Parametro opzionale: limit (default 20)."
        ),
        "params": ["environment", "hostname", "instance_name", "limit?"],
    },
    # --- OS Monitoring ---
    {
        "name": "os_cpu_stats",
        "description": (
            "OS MONITORING — Raccoglie metriche CPU e run queue dal server via vmstat (AIX e Linux). "
            "Campionamento multiplo con statistiche aggregate min/max/avg/p95/p99. "
            "Parametri opzionali: samples (default 5), interval (default 2s). "
            "Firma: ENV HOSTNAME — nessun INSTANCE_NAME (tool OS-level)."
        ),
        "params": ["environment", "hostname", "samples?", "interval?"],
    },
    {
        "name": "os_memory_stats",
        "description": (
            "OS MONITORING — Raccoglie metriche RAM e swap dal server (svmon+lsps su AIX, free su Linux). "
            "Include page in/out da vmstat. Campionamento multiplo con statistiche aggregate. "
            "Parametri opzionali: samples (default 5), interval (default 2s)."
        ),
        "params": ["environment", "hostname", "samples?", "interval?"],
    },
    {
        "name": "os_disk_stats",
        "description": (
            "OS MONITORING — Raccoglie utilizzo filesystem (df) e I/O disco (iostat) dal server. "
            "Parametro opzionale --fs per filtrare un mount point specifico. "
            "Se iostat non disponibile: io_samples=[], io_available=false (nessun errore). "
            "Parametri opzionali: samples (default 5), interval (default 2s), fs (mount point)."
        ),
        "params": ["environment", "hostname", "samples?", "interval?", "fs?"],
    },
    # --- Runbook orchestrati (M8) ---
    {
        "name": "diagnose_instance",
        "description": (
            "RUNBOOK — Discovery completa di una istanza Oracle in una chiamata sola. "
            "Esegue in parallelo: identify_instance, list_pdbs, check_fra_usage, check_resource_limits. "
            "Restituisce un summary interpretato (stato, PDB aperti, criticità FRA/risorse) "
            "e i risultati raw di ogni primitivo nei details. "
            "Usare come punto di partenza per qualsiasi analisi su un'istanza."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "check_memory_pressure",
        "description": (
            "RUNBOOK — Analisi pressione memoria/PGA su una istanza Oracle. "
            "Esegue: top_pga_sessions, pga_by_pdb_session, pga_sga_by_pdb. "
            "Restituisce un summary con livello di pressione (bassa/media/alta), "
            "sessione top e distribuzione PGA per PDB. "
            "Usare quando si sospetta consumo eccessivo di memoria di processo."
        ),
        "params": ["environment", "hostname", "instance_name"],
    },
    {
        "name": "runbook_ora04030",
        "description": (
            "RUNBOOK — Diagnosi completa per errore ORA-04030 (out of process memory). "
            "Esegue: scan_alert_log (filtra ORA-04030), check_memory_pressure, get_alert_log_info. "
            "Restituisce presenza/frequenza dell'errore, pressione memoria attuale e raccomandazioni. "
            "Filtri opzionali: since (YYYY-MM-DD), pdb. "
            "Usare quando viene segnalato o rilevato un ORA-04030."
        ),
        "params": ["environment", "hostname", "instance_name", "since?", "pdb?"],
    },
    {
        "name": "diagnose_os_pressure",
        "description": (
            "RUNBOOK — Analisi pressione OS correlata con stato Oracle in una chiamata sola. "
            "Esegue in parallelo: os_cpu_stats, os_memory_stats, os_disk_stats, "
            "check_memory_pressure, check_resource_limits, sessions_by_user. "
            "Restituisce livello_pressione_os (bassa/media/alta), livello_pressione_oracle, "
            "correlazioni cross-domain e raccomandazioni. "
            "Usare quando si sospetta che il server stia soffrendo a livello OS."
        ),
        "params": ["environment", "hostname", "instance_name", "samples?", "interval?"],
    },
]

# ---------------------------------------------------------------------------
# Catalogo MCP wire — inputSchema JSON Schema per ogni tool
# ---------------------------------------------------------------------------

# Schema base riutilizzabile per i 3 parametri standard
_BASE_PROPS = {
    "environment": {
        "type": "string",
        "description": "Ambiente Oracle. Valori: EURO, TEST, CERT, INTE, COLL, PROD",
        "enum": ["EURO", "TEST", "CERT", "INTE", "COLL", "PROD"],
    },
    "hostname": {
        "type": "string",
        "description": "Hostname fisico del server Oracle (es. axnporadb41)",
    },
    "instance_name": {
        "type": "string",
        "description": "Nome del CDB Oracle (es. NP41CDB0)",
    },
}

# Schema solo environment
_ENV_ONLY_PROPS = {
    "environment": _BASE_PROPS["environment"],
}

# Schema environment + hostname (no instance_name)
_ENV_HOST_PROPS = {
    "environment": _BASE_PROPS["environment"],
    "hostname": _BASE_PROPS["hostname"],
}

MCP_TOOLS: list[dict] = [
    # --- Inventario infrastruttura (NFS locale, no SSH, no sqlplus) ---
    {
        "name": "list_known_hosts",
        "description": (
            "INVENTARIO — Elenca gli host Oracle fisici noti dal mount NFS locale su lxprworkerlana01. "
            "Non verifica se gli host sono raggiungibili o accesi: restituisce ciò che è configurato. "
            "ENVIRONMENT determina il tier: PROD → host prod, tutti gli altri → noprod. "
            "Usare come primo passo per scoprire quali hostname esistono da passare agli altri tool."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _ENV_ONLY_PROPS,
            "required": ["environment"],
        },
    },
    {
        "name": "list_known_instances",
        "description": (
            "INVENTARIO — Elenca le istanze Oracle configurate su un host leggendo il mount NFS, "
            "senza SSH né sqlplus. NON indica se le istanze sono accese o spente. "
            "Funziona anche se l'host Oracle è irraggiungibile. "
            "Usare per sapere quali istanze esistono (inventario); "
            "per sapere quali sono accese usare list_all_instances_status."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _ENV_HOST_PROPS,
            "required": ["environment", "hostname"],
        },
    },
    {
        "name": "list_all_hosts_and_instances",
        "description": (
            "INVENTARIO — Inventario completo di tutti gli host Oracle e le istanze configurate "
            "in una sola chiamata, leggendo il mount NFS locale. Zero SSH, zero sqlplus. "
            "NON indica se le istanze sono accese o spente. "
            "Usare per una visione globale dell'infrastruttura configurata."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _ENV_ONLY_PROPS,
            "required": ["environment"],
        },
    },
    # --- Stato operativo in tempo reale (richiede connessione Oracle) ---
    {
        "name": "list_all_instances_status",
        "description": (
            "STATO OPERATIVO — Verifica in tempo reale lo stato di tutte le istanze Oracle "
            "di un host interrogando Oracle in parallelo (identify_instance su ciascuna). "
            "Restituisce per ogni istanza: oracle_version, status (OPEN/MOUNTED/null), "
            "database_status, instance_role, startup_time. "
            "status=null significa che l'istanza è spenta o irraggiungibile. "
            "Usare quando la domanda è 'quali istanze sono accese/attive su un host'."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _ENV_HOST_PROPS,
            "required": ["environment", "hostname"],
        },
    },
    {
        "name": "list_instances_on_host",
        "description": (
            "INVENTARIO VIA SSH — Elenca le istanze Oracle configurate su un host "
            "leggendo gli env file Oracle via SSH. NON indica se le istanze sono accese o spente. "
            "Preferire list_known_instances (più veloce, no SSH) salvo necessità di dati aggiornati via SSH. "
            "Usare list_all_instances_status per sapere quali istanze sono operative."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {k: _BASE_PROPS[k] for k in ("environment", "hostname")},
            "required": ["environment", "hostname"],
        },
    },
    {
        "name": "identify_instance",
        "description": (
            "STATO OPERATIVO — Interroga Oracle (v$instance) per una singola istanza. "
            "Restituisce versione, stato (OPEN/MOUNTED), ruolo, startup time. "
            "Fallisce con connection_failed se l'istanza è spenta o irraggiungibile. "
            "Per verificare più istanze contemporaneamente usare list_all_instances_status."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "list_pdbs",
        "description": (
            "STATO OPERATIVO — Elenca i PDB del CDB con stato corrente (OPEN/MOUNTED/RESTRICTED) "
            "e modalità di apertura interrogando Oracle (show pdbs). Richiede Oracle 12c+. "
            "Usare per verificare quali database applicativi sono aperti all'interno del CDB."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    # --- Diagnostica log (NFS locale, no connessione Oracle) ---
    {
        "name": "get_alert_log_info",
        "description": (
            "METADATI LOG — Restituisce path, size_bytes, last_modified e age_hours "
            "dell'alert log Oracle leggendo solo il filesystem NFS, senza aprire il file. "
            "Risposta istantanea. "
            "Usare prima di scan_alert_log per verificare se il log è aggiornato e stimarne il tempo di scansione."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "scan_alert_log",
        "description": (
            "ANALISI LOG — Scansiona l'alert log Oracle cercando tutti gli errori ORA- "
            "raggruppati per codice e PDB, con conteggio, first/last seen e campioni. "
            "Legge dal mount NFS locale. "
            "Filtri opzionali: code (es. ORA-04030), since (YYYY-MM-DD), pdb (nome PDB o 'CDB' per il root). "
            "Usare per diagnosticare errori ricorrenti o indagare un incidente."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_BASE_PROPS,
                "code": {"type": "string", "description": "Filtra per codice ORA- (es. ORA-04030)"},
                "since": {"type": "string", "description": "Considera solo righe dal timestamp >= YYYY-MM-DD"},
                "pdb": {"type": "string", "description": "Filtra per nome PDB (es. AIMELA). Usa 'CDB' per il container root."},
            },
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "tail_alert_log",
        "description": (
            "ANALISI LOG — Restituisce le ultime N righe dell'alert log Oracle dal mount NFS. "
            "Usare per vedere gli eventi più recenti senza scansionare l'intero file. "
            "Parametro opzionale: lines (default 100)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_BASE_PROPS,
                "lines": {"type": "integer", "description": "Numero di righe da restituire (default: 100)", "minimum": 1},
            },
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    # --- Diagnostica istanza (richiede connessione Oracle) ---
    {
        "name": "get_diag_home",
        "description": (
            "DIAGNOSTICA — Restituisce il percorso DIAGNOSTIC_DEST dell'istanza Oracle. "
            "Usare per costruire dinamicamente path di diagnostica non coperti dal mount NFS."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "check_fra_usage",
        "description": (
            "DIAGNOSTICA SPAZIO — Verifica utilizzo e stato della Flash Recovery Area "
            "(v$recovery_file_dest, v$flash_recovery_area_usage). "
            "Restituisce spazio totale, usato, riciclabile e dettaglio per tipo di file. "
            "Usare quando si sospetta saturazione della FRA o per monitoraggio preventivo."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "check_resource_limits",
        "description": (
            "DIAGNOSTICA RISORSE — Verifica i limiti Oracle di sessioni, processi e locks "
            "(v$resource_limit) con utilizzo corrente vs massimo consentito. "
            "Usare quando si sospetta esaurimento connessioni o processi Oracle."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    # --- Sessioni (richiede connessione Oracle) ---
    {
        "name": "sessions_by_user",
        "description": (
            "SESSIONI — Conta le sessioni Oracle attive raggruppate per utente e stato "
            "(ACTIVE/INACTIVE) da v$session. "
            "Usare per capire chi è connesso e quante connessioni ha aperte."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "sessions_by_machine",
        "description": (
            "SESSIONI — Conta le sessioni Oracle attive raggruppate per macchina client e stato "
            "da v$session. "
            "Usare per capire da quali server o applicazioni arrivano le connessioni."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    # --- Memoria/PGA (richiede connessione Oracle) ---
    {
        "name": "pga_sga_by_pdb",
        "description": (
            "MEMORIA — Utilizzo PGA e SGA aggregato per PDB da v$rsrcpdbmetric. "
            "Richiede Oracle 12c+ e Resource Manager con PDB plan attivo. "
            "Usare per confrontare il consumo di memoria tra PDB diversi."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "pga_by_pdb_session",
        "description": (
            "MEMORIA — Utilizzo PGA per singola sessione con dettaglio PDB di appartenenza "
            "(join v$session/v$process/cdb_pdbs). Richiede Oracle 12c+. "
            "Usare per identificare quale sessione o PDB consuma più memoria."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "top_pga_sessions",
        "description": (
            "MEMORIA — Top N sessioni Oracle ordinate per utilizzo PGA decrescente "
            "(v$process + v$session). Funziona su 11g, 12c, 19c. "
            "Usare come primo passo per diagnosticare pressione sulla memoria di processo. "
            "Parametro opzionale: limit (default 20)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_BASE_PROPS,
                "limit": {"type": "integer", "description": "Numero di sessioni da restituire (default: 20)", "minimum": 1},
            },
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    # --- OS Monitoring ---
    {
        "name": "os_cpu_stats",
        "description": (
            "OS MONITORING — Raccoglie metriche CPU e run queue dal server via vmstat (AIX e Linux). "
            "Campionamento multiplo con statistiche aggregate min/max/avg/p95/p99. "
            "Parametri opzionali: samples (default 5), interval (default 2s). "
            "Firma: ENV HOSTNAME — nessun INSTANCE_NAME (tool OS-level)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_ENV_HOST_PROPS,
                "samples":  {"type": "integer", "description": "Numero di campioni (default: 5)", "minimum": 1},
                "interval": {"type": "integer", "description": "Secondi tra campioni (default: 2)", "minimum": 0},
            },
            "required": ["environment", "hostname"],
        },
    },
    {
        "name": "os_memory_stats",
        "description": (
            "OS MONITORING — Raccoglie metriche RAM e swap dal server (svmon+lsps su AIX, free su Linux). "
            "Include page in/out da vmstat. Campionamento multiplo con statistiche aggregate. "
            "Parametri opzionali: samples (default 5), interval (default 2s)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_ENV_HOST_PROPS,
                "samples":  {"type": "integer", "description": "Numero di campioni (default: 5)", "minimum": 1},
                "interval": {"type": "integer", "description": "Secondi tra campioni (default: 2)", "minimum": 0},
            },
            "required": ["environment", "hostname"],
        },
    },
    {
        "name": "os_disk_stats",
        "description": (
            "OS MONITORING — Raccoglie utilizzo filesystem (df) e I/O disco (iostat) dal server. "
            "Se iostat non disponibile: io_samples=[], io_available=false (nessun errore). "
            "Parametri opzionali: samples (default 5), interval (default 2s), fs (mount point)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_ENV_HOST_PROPS,
                "samples":  {"type": "integer", "description": "Numero di campioni I/O (default: 5)", "minimum": 1},
                "interval": {"type": "integer", "description": "Secondi tra campioni (default: 2)", "minimum": 0},
                "fs":       {"type": "string",  "description": "Filtra per mount point (es. /oracle/data)"},
            },
            "required": ["environment", "hostname"],
        },
    },
    # --- Runbook orchestrati (M8) ---
    {
        "name": "diagnose_instance",
        "description": (
            "RUNBOOK — Discovery completa di una istanza Oracle in una chiamata sola. "
            "Esegue in parallelo: identify_instance, list_pdbs, check_fra_usage, check_resource_limits. "
            "Restituisce un summary interpretato (stato, PDB aperti, criticità FRA/risorse) "
            "e i risultati raw di ogni primitivo nei details. "
            "Usare come punto di partenza per qualsiasi analisi su un'istanza."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "check_memory_pressure",
        "description": (
            "RUNBOOK — Analisi pressione memoria/PGA su una istanza Oracle. "
            "Esegue: top_pga_sessions, pga_by_pdb_session, pga_sga_by_pdb. "
            "Restituisce un summary con livello di pressione (bassa/media/alta), "
            "sessione top e distribuzione PGA per PDB. "
            "Usare quando si sospetta consumo eccessivo di memoria di processo."
        ),
        "inputSchema": {
            "type": "object",
            "properties": _BASE_PROPS,
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "runbook_ora04030",
        "description": (
            "RUNBOOK — Diagnosi completa per errore ORA-04030 (out of process memory). "
            "Esegue: scan_alert_log (filtra ORA-04030), check_memory_pressure, get_alert_log_info. "
            "Restituisce presenza/frequenza dell'errore, pressione memoria attuale e raccomandazioni. "
            "Filtri opzionali: since (YYYY-MM-DD), pdb. "
            "Usare quando viene segnalato o rilevato un ORA-04030."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_BASE_PROPS,
                "since": {"type": "string", "description": "Considera solo errori dal timestamp >= YYYY-MM-DD"},
                "pdb": {"type": "string", "description": "Filtra per nome PDB (es. AIMELA). Usa 'CDB' per il container root."},
            },
            "required": ["environment", "hostname", "instance_name"],
        },
    },
    {
        "name": "diagnose_os_pressure",
        "description": (
            "RUNBOOK — Analisi pressione OS correlata con stato Oracle in una chiamata sola. "
            "Esegue in parallelo: os_cpu_stats, os_memory_stats, os_disk_stats, "
            "check_memory_pressure, check_resource_limits, sessions_by_user. "
            "Restituisce livello_pressione_os (bassa/media/alta), livello_pressione_oracle, "
            "correlazioni cross-domain e raccomandazioni. "
            "Usare quando si sospetta che il server stia soffrendo a livello OS."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                **_BASE_PROPS,
                "samples":  {"type": "integer", "description": "Numero di campioni OS (default: 5)", "minimum": 1},
                "interval": {"type": "integer", "description": "Secondi tra campioni (default: 2)", "minimum": 0},
            },
            "required": ["environment", "hostname", "instance_name"],
        },
    },
]

# Indice per lookup rapido in tools/call
_MCP_TOOLS_BY_NAME: dict[str, dict] = {t["name"]: t for t in MCP_TOOLS}


# ---------------------------------------------------------------------------
# Endpoint MCP wire — JSON-RPC 2.0 (Streamable HTTP transport)
# ---------------------------------------------------------------------------

def _jsonrpc_result(req_id: Any, result: Any) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": req_id, "result": result})


def _jsonrpc_error(req_id: Any, code: int, message: str) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def _check_api_key(request: Request) -> None:
    """Verifica X-API-Key; solleva HTTPException 401 se non valida."""
    if not config.API_KEY:
        raise HTTPException(status_code=500, detail="MCP_API_KEY non configurata.")
    key = request.headers.get("X-API-Key", "")
    if key != config.API_KEY:
        raise HTTPException(status_code=401, detail="API key mancante o non valida.")


@app.post("/mcp", tags=["mcp"])
async def mcp_endpoint(request: Request) -> JSONResponse:
    """Endpoint JSON-RPC 2.0 per il protocollo MCP wire (Streamable HTTP transport)."""
    _check_api_key(request)

    try:
        body = await request.json()
    except Exception:
        return _jsonrpc_error(None, -32700, "Parse error: body non è JSON valido")

    req_id = body.get("id")
    method = body.get("method", "")
    params = body.get("params", {})

    # --- initialize ---
    if method == "initialize":
        return _jsonrpc_result(req_id, {
            "protocolVersion": "2024-11-05",
            "serverInfo": {
                "name": "neural-oracle-analyzer",
                "version": "1.0.0",
            },
            "capabilities": {
                "tools": {},
            },
        })

    # --- notifications/initialized (no response needed per spec) ---
    if method == "notifications/initialized":
        return JSONResponse({})

    # --- tools/list ---
    if method == "tools/list":
        return _jsonrpc_result(req_id, {"tools": MCP_TOOLS})

    # --- tools/call ---
    if method == "tools/call":
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})

        if tool_name not in _MCP_TOOLS_BY_NAME:
            return _jsonrpc_error(req_id, -32602, f"Tool sconosciuto: {tool_name}")

        # _dispatch_tool lancia subprocess bloccanti (SSH/sqlplus).
        # Eseguirlo in un thread del default executor evita di bloccare
        # l'event loop asyncio, rendendo il server responsivo anche durante
        # chiamate lente o parallele.
        # Il semaforo limita le chiamate concorrenti a MCP_MAX_CONCURRENT per
        # evitare che chiamate parallele pesanti saturino le connessioni SSH.
        sem = _get_semaphore()
        loop = asyncio.get_event_loop()
        async with sem:
            result = await loop.run_in_executor(None, _dispatch_tool, tool_name, arguments)

        return _jsonrpc_result(req_id, {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(result, ensure_ascii=False, indent=2),
                }
            ],
            "isError": result.get("status") == "error",
        })

    # --- metodo sconosciuto ---
    return _jsonrpc_error(req_id, -32601, f"Metodo non supportato: {method}")


def _dispatch_tool(name: str, args: dict) -> dict:
    """Traduce la chiamata MCP tools/call negli argomenti del tool primitivo bash."""
    env = args.get("environment", "")
    host = args.get("hostname", "")
    inst = args.get("instance_name", "")

    if name == "list_known_hosts":
        return run_primitive_tool("list_known_hosts", env)

    if name == "list_known_instances":
        return run_primitive_tool("list_known_instances", env, host)

    if name == "get_alert_log_info":
        return run_primitive_tool("get_alert_log_info", env, host, inst)

    if name == "list_all_hosts_and_instances":
        return run_primitive_tool("list_all_hosts_and_instances", env)

    if name == "list_all_instances_status":
        return _list_all_instances_status(env, host)

    if name == "list_instances_on_host":
        return run_primitive_tool("list_instances_on_host", env, host)

    if name == "identify_instance":
        return run_primitive_tool("identify_instance", env, host, inst)

    if name == "list_pdbs":
        return run_primitive_tool("list_pdbs", env, host, inst)

    if name == "get_diag_home":
        return run_primitive_tool("get_diag_home", env, host, inst)

    if name == "check_fra_usage":
        return run_primitive_tool("check_fra_usage", env, host, inst)

    if name == "scan_alert_log":
        extra = []
        if args.get("code"):
            extra.append(f"--code={args['code']}")
        if args.get("since"):
            extra.append(f"--since={args['since']}")
        if args.get("pdb"):
            extra.append(f"--pdb={args['pdb']}")
        return run_primitive_tool("scan_alert_log", env, host, inst, *extra)

    if name == "tail_alert_log":
        extra = []
        if args.get("lines") is not None:
            extra.append(f"--lines={args['lines']}")
        return run_primitive_tool("tail_alert_log", env, host, inst, *extra)

    if name == "check_resource_limits":
        return run_primitive_tool("check_resource_limits", env, host, inst)

    if name == "sessions_by_user":
        return run_primitive_tool("sessions_by_user", env, host, inst)

    if name == "sessions_by_machine":
        return run_primitive_tool("sessions_by_machine", env, host, inst)

    if name == "pga_sga_by_pdb":
        return run_primitive_tool("pga_sga_by_pdb", env, host, inst)

    if name == "pga_by_pdb_session":
        return run_primitive_tool("pga_by_pdb_session", env, host, inst)

    if name == "top_pga_sessions":
        extra = []
        if args.get("limit") is not None:
            extra.append(f"--limit={args['limit']}")
        return run_primitive_tool("top_pga_sessions", env, host, inst, *extra)

    if name == "diagnose_instance":
        return diagnose_instance(env, host, inst)

    if name == "check_memory_pressure":
        return check_memory_pressure(env, host, inst)

    if name == "runbook_ora04030":
        return runbook_ora04030(
            env, host, inst,
            since=args.get("since"),
            pdb=args.get("pdb"),
        )

    if name in ("os_cpu_stats", "os_memory_stats", "os_disk_stats"):
        extra = []
        if args.get("samples") is not None:
            extra.append(f"--samples={args['samples']}")
        if args.get("interval") is not None:
            extra.append(f"--interval={args['interval']}")
        if name == "os_disk_stats" and args.get("fs"):
            extra.append(f"--fs={args['fs']}")
        return run_primitive_tool(name, env, host, *extra)

    if name == "diagnose_os_pressure":
        return diagnose_os_pressure(
            env, host, inst,
            samples=int(args.get("samples") or 5),
            interval=int(args.get("interval") or 2),
        )

    # fallback (non dovrebbe mai arrivare qui grazie al check precedente)
    return {"status": "error", "data": [], "error": {"code": "invalid_argument", "message": f"Tool non gestito: {name}"}}


def _list_all_instances_status(env: str, host: str) -> dict:
    """Tool orchestrato: chiama identify_instance su tutte le istanze dell'host in parallelo.

    Prima ottiene la lista istanze da list_known_instances (NFS, zero SSH),
    poi lancia identify_instance in parallelo con ThreadPoolExecutor.
    """
    # Step 1: lista istanze dal NFS (istantanea, senza SSH)
    instances_result = run_primitive_tool("list_known_instances", env, host)
    if instances_result.get("status") == "error":
        # Fallback: prova via SSH
        instances_result = run_primitive_tool("list_instances_on_host", env, host)

    if instances_result.get("status") == "error":
        return instances_result

    instance_names = [row["instance_name"] for row in instances_result.get("data", [])]

    if not instance_names:
        return {
            "tool": "list_all_instances_status",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "environment": env,
            "hostname": host,
            "instance_name": None,
            "oracle_version": None,
            "status": "ok",
            "data": [],
            "error": None,
        }

    # Step 2: identify_instance in parallelo
    results_map: dict[str, dict] = {}
    with ThreadPoolExecutor(max_workers=min(len(instance_names), 8)) as executor:
        future_to_inst = {
            executor.submit(run_primitive_tool, "identify_instance", env, host, inst): inst
            for inst in instance_names
        }
        for future in as_completed(future_to_inst):
            inst = future_to_inst[future]
            try:
                results_map[inst] = future.result()
            except Exception as exc:
                results_map[inst] = {
                    "status": "error",
                    "data": [],
                    "error": {"code": "query_failed", "message": str(exc)},
                }

    # Step 3: aggrega in un array ordinato per instance_name
    data = []
    for inst in sorted(results_map):
        r = results_map[inst]
        if r.get("status") == "ok" and r.get("data"):
            row = r["data"][0]
            data.append({
                "instance_name": inst,
                "oracle_version": r.get("oracle_version"),
                "status": row.get("status"),
                "database_status": row.get("database_status"),
                "instance_role": row.get("instance_role"),
                "startup_time": row.get("startup_time"),
                "error": None,
            })
        else:
            data.append({
                "instance_name": inst,
                "oracle_version": None,
                "status": None,
                "database_status": None,
                "instance_role": None,
                "startup_time": None,
                "error": r.get("error"),
            })

    return {
        "tool": "list_all_instances_status",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "environment": env,
        "hostname": host,
        "instance_name": None,
        "oracle_version": None,
        "status": "ok",
        "data": data,
        "error": None,
    }


# ---------------------------------------------------------------------------
# Healthcheck e catalogo REST (no auth)
# ---------------------------------------------------------------------------


@app.get("/health", tags=["system"])
def health() -> dict:
    return {"status": "ok", "service": "neural-oracle-mcp"}


@app.get("/tools", tags=["system"])
def list_tools() -> dict:
    return {"tools": TOOL_CATALOG}


# ---------------------------------------------------------------------------
# Tool — Discovery
# ---------------------------------------------------------------------------


class ListInstancesRequest(BaseModel):
    environment: str = Field(..., description="Enum: EURO, TEST, CERT, INTE, COLL, PROD")
    hostname: str = Field(..., description="Hostname fisico del server Oracle")


class EnvOnlyRequest(BaseModel):
    environment: str = Field(..., description="Enum: EURO, TEST, CERT, INTE, COLL, PROD")


@app.post("/tools/list_known_hosts", response_model=ToolResponse, tags=["discovery"])
def list_known_hosts(_: AuthDep, req: EnvOnlyRequest) -> dict:
    return run_primitive_tool("list_known_hosts", req.environment)


@app.post("/tools/list_known_instances", response_model=ToolResponse, tags=["discovery"])
def list_known_instances(_: AuthDep, req: ListInstancesRequest) -> dict:
    return run_primitive_tool("list_known_instances", req.environment, req.hostname)


@app.post("/tools/get_alert_log_info", response_model=ToolResponse, tags=["discovery"])
def get_alert_log_info(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("get_alert_log_info", req.environment, req.hostname, req.instance_name)


@app.post("/tools/list_all_hosts_and_instances", response_model=ToolResponse, tags=["discovery"])
def list_all_hosts_and_instances(_: AuthDep, req: EnvOnlyRequest) -> dict:
    return run_primitive_tool("list_all_hosts_and_instances", req.environment)


@app.post("/tools/list_all_instances_status", response_model=ToolResponse, tags=["discovery"])
def list_all_instances_status_endpoint(_: AuthDep, req: ListInstancesRequest) -> dict:
    return _list_all_instances_status(req.environment, req.hostname)


@app.post("/tools/list_instances_on_host", response_model=ToolResponse, tags=["discovery"])
def list_instances_on_host(_: AuthDep, req: ListInstancesRequest) -> dict:
    return run_primitive_tool("list_instances_on_host", req.environment, req.hostname)


@app.post("/tools/identify_instance", response_model=ToolResponse, tags=["discovery"])
def identify_instance(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("identify_instance", req.environment, req.hostname, req.instance_name)


@app.post("/tools/list_pdbs", response_model=ToolResponse, tags=["discovery"])
def list_pdbs(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("list_pdbs", req.environment, req.hostname, req.instance_name)


@app.post("/tools/get_diag_home", response_model=ToolResponse, tags=["discovery"])
def get_diag_home(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("get_diag_home", req.environment, req.hostname, req.instance_name)


# ---------------------------------------------------------------------------
# Tool — Spazio/FRA
# ---------------------------------------------------------------------------


@app.post("/tools/check_fra_usage", response_model=ToolResponse, tags=["fra"])
def check_fra_usage(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("check_fra_usage", req.environment, req.hostname, req.instance_name)


# ---------------------------------------------------------------------------
# Tool — Log analysis
# ---------------------------------------------------------------------------


class ScanAlertLogRequest(_BaseRequest):
    code: Optional[str] = Field(None, description="Filtra per codice ORA- (es. ORA-04030)")
    since: Optional[str] = Field(None, description="Considera solo righe dal timestamp >= YYYY-MM-DD")
    pdb: Optional[str] = Field(None, description="Filtra per PDB (es. AIMELA). Usa 'CDB' per il container root.")


@app.post("/tools/scan_alert_log", response_model=ToolResponse, tags=["logs"])
def scan_alert_log(_: AuthDep, req: ScanAlertLogRequest) -> dict:
    args = [req.environment, req.hostname, req.instance_name]
    if req.code:
        args.append(f"--code={req.code}")
    if req.since:
        args.append(f"--since={req.since}")
    if req.pdb:
        args.append(f"--pdb={req.pdb}")
    return run_primitive_tool("scan_alert_log", *args)


class TailAlertLogRequest(_BaseRequest):
    lines: Optional[int] = Field(None, description="Numero di righe (default: 100)")


@app.post("/tools/tail_alert_log", response_model=ToolResponse, tags=["logs"])
def tail_alert_log(_: AuthDep, req: TailAlertLogRequest) -> dict:
    args = [req.environment, req.hostname, req.instance_name]
    if req.lines is not None:
        args.append(f"--lines={req.lines}")
    return run_primitive_tool("tail_alert_log", *args)


# ---------------------------------------------------------------------------
# Tool — Sessioni
# ---------------------------------------------------------------------------


@app.post("/tools/check_resource_limits", response_model=ToolResponse, tags=["sessions"])
def check_resource_limits(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("check_resource_limits", req.environment, req.hostname, req.instance_name)


@app.post("/tools/sessions_by_user", response_model=ToolResponse, tags=["sessions"])
def sessions_by_user(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("sessions_by_user", req.environment, req.hostname, req.instance_name)


@app.post("/tools/sessions_by_machine", response_model=ToolResponse, tags=["sessions"])
def sessions_by_machine(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("sessions_by_machine", req.environment, req.hostname, req.instance_name)


# ---------------------------------------------------------------------------
# Tool — Memoria/PGA
# ---------------------------------------------------------------------------


@app.post("/tools/pga_sga_by_pdb", response_model=ToolResponse, tags=["memory"])
def pga_sga_by_pdb(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("pga_sga_by_pdb", req.environment, req.hostname, req.instance_name)


@app.post("/tools/pga_by_pdb_session", response_model=ToolResponse, tags=["memory"])
def pga_by_pdb_session(_: AuthDep, req: _BaseRequest) -> dict:
    return run_primitive_tool("pga_by_pdb_session", req.environment, req.hostname, req.instance_name)


class TopPgaSessionsRequest(_BaseRequest):
    limit: Optional[int] = Field(None, description="Numero di sessioni da restituire (default: 20)")


@app.post("/tools/top_pga_sessions", response_model=ToolResponse, tags=["memory"])
def top_pga_sessions(_: AuthDep, req: TopPgaSessionsRequest) -> dict:
    args = [req.environment, req.hostname, req.instance_name]
    if req.limit is not None:
        args.append(f"--limit={req.limit}")
    return run_primitive_tool("top_pga_sessions", *args)


# ---------------------------------------------------------------------------
# Tool — Runbook orchestrati (M8)
# ---------------------------------------------------------------------------


class RunbookOra04030Request(_BaseRequest):
    since: Optional[str] = Field(None, description="Considera solo errori dal timestamp >= YYYY-MM-DD")
    pdb: Optional[str] = Field(None, description="Filtra per PDB (es. AIMELA). Usa 'CDB' per il container root.")


@app.post("/tools/diagnose_instance", tags=["runbook"])
def diagnose_instance_endpoint(_: AuthDep, req: _BaseRequest) -> dict:
    return diagnose_instance(req.environment, req.hostname, req.instance_name)


@app.post("/tools/check_memory_pressure", tags=["runbook"])
def check_memory_pressure_endpoint(_: AuthDep, req: _BaseRequest) -> dict:
    return check_memory_pressure(req.environment, req.hostname, req.instance_name)


@app.post("/tools/runbook_ora04030", tags=["runbook"])
def runbook_ora04030_endpoint(_: AuthDep, req: RunbookOra04030Request) -> dict:
    return runbook_ora04030(
        req.environment, req.hostname, req.instance_name,
        since=req.since,
        pdb=req.pdb,
    )
