# Backlog — Problemi rilevati dall'analisi diagnostica

Questo file raccoglie i problemi identificati durante le sessioni di analisi con il Neural Oracle Analyzer.
Ogni issue ha una priorità, un'area tecnica, il contesto di scoperta e i passi suggeriti.

---

## Legenda priorità
- 🔴 **P1 — Critico**: errore attivo in produzione, potenziale impatto su dati o disponibilità
- 🟠 **P2 — Alto**: errore ricorrente o anomalia che richiede indagine entro breve
- 🟡 **P3 — Medio**: problema noto, da pianificare nel ciclo di manutenzione
- 🟢 **P4 — Basso**: miglioramento o ottimizzazione non urgente

---

## Issue aperte

### [DB-001] ORA-00600 `[rworupo.1]` ricorrente su PPBPROD1 🔴 P1

| Campo | Valore |
|---|---|
| **Host/Istanza** | axprracdb03 / PPBPROD1 (PROD) |
| **Occorrenze** | 102 dal 2026-07-29, ultima 2026-09-02 06:49 |
| **Tool** | `scan_alert_log` |

**Descrizione**: Internal error Oracle con argomento `[rworupo.1], [6], [5]`. Questo codice è associato a operazioni di sort/hash join che non trovano abbastanza memoria di processo (PGA). Con 102 occorrenze in ~5 settimane e l'ultima stamattina, il problema è attivo e ricorrente.

**Azione suggerita**:
1. Recuperare il trace file `.trc` associato alle occorrenze recenti in `/unipol/logs/.../axprracdb03/ppbprod/PPBPROD1/trace/`
2. Aprire una Service Request Oracle con il trace file e la versione esatta (19.0.0.0.0)
3. Valutare aumento di `PGA_AGGREGATE_TARGET` o `PGA_AGGREGATE_LIMIT`

---

### [DB-002] ORA-01555 "Snapshot too old" cronico su PPBPROD1 🟠 P2

| Campo | Valore |
|---|---|
| **Host/Istanza** | axprracdb03 / PPBPROD1 (PROD) |
| **Occorrenze** | 306 dal 2026-01-07, ultima 2026-09-02 09:45 |
| **Tool** | `scan_alert_log` |

**Descrizione**: Query di lunga durata (campioni: 10-12 sec) trovano l'undo già sovrascritto. Il medesimo SQL ID `dp1634gf6r4f0` appare in più campioni — è una query specifica dell'applicazione PPB che legge snapshot lunghi. Il volume di occorrenze (306 in 8 mesi, ~1,3/giorno) indica un problema strutturale.

**Azione suggerita**:
1. Verificare `UNDO_RETENTION` attuale e dimensione undo tablespace
2. Identificare la query `dp1634gf6r4f0` e valutare ottimizzazione (hint `FLASHBACK`, riduzione durata, o aumento undo retention)
3. Valutare `UNDO_RETENTION` >= durata massima delle query più lunghe del workload

---

### [DB-003] ORA-16401 Data Guard — archivelog rejected by RFS su PPBPROD1 🟠 P2

| Campo | Valore |
|---|---|
| **Host/Istanza** | axprracdb03 / PPBPROD1 (PROD) |
| **Occorrenze** | 46 dal 2026-01-26, ultima 2026-09-02 09:00 |
| **Tool** | `scan_alert_log` |

**Descrizione**: Il Remote File Server dello standby Data Guard rifiuta gli archivelog. L'errore è attivo oggi e ricorrente durante tutto l'anno. Se lo standby non riceve i log, il gap di recovery cresce silenziosamente.

**Azione suggerita**:
1. Verificare stato Data Guard: `SELECT * FROM V$DATAGUARD_STATUS` su primario e standby
2. Controllare `V$ARCHIVE_DEST_STATUS` per il dest corrispondente allo standby
3. Verificare connettività e spazio su standby

---

### [DB-004] ORA-00600 massivo e ORA-3136 su SDC1 🔴 P1

| Campo | Valore |
|---|---|
| **Host/Istanza** | axprracdb03 / SDC1 (PROD) |
| **Occorrenze** | ORA-00600: 441 totali; ORA-3136: 3090 totali |
| **Tool** | `scan_alert_log` (grep diretto — bug encoding JSON) |

**Descrizione**: SDC1 mostra un volume di errori significativamente più alto di PPBPROD1. ORA-3136 ("inbound connection timed out") con 3090 occorrenze indica un problema di rete/listener o sovraccarico delle connessioni in ingresso. ORA-00600 con 441 occorrenze supera PPBPROD1 (102). Presenti anche ORA-19511/ORA-19509/ORA-19502 (errori backup RMAN) e ORA-1652 (temp tablespace esaurita).

**Azione suggerita**:
1. Analizzare ORA-3136: verificare `sqlnet.inbound_connect_timeout` e carico listener
2. Analizzare ORA-00600: recuperare trace file e aprire SR Oracle
3. Verificare backup RMAN (ORA-19511 = errore media management, es. agente backup)
4. Verificare dimensione temp tablespace (ORA-1652)

---

### [DB-005] ORA-00345 + ORA-1092 — crash istanza PPBPROD1 il 2026-04-29 🟡 P3

| Campo | Valore |
|---|---|
| **Host/Istanza** | axprracdb03 / PPBPROD1 (PROD) |
| **Occorrenze** | 2 occorrenze, isolate in data 2026-04-29 13:35 |
| **Tool** | `scan_alert_log` |

**Descrizione**: Il 29 aprile si è verificato un redo log write error (ORA-00345) su `+DATA_PPBPROD/PPBPROD/ONLINELOG/group_3` con conseguente I/O error sul diskgroup ASM (ORA-15080) e crash dell'istanza (ORA-1092). Evento isolato, probabilmente legato a un problema storage transitorio. L'istanza è poi tornata operativa.

**Azione suggerita**:
1. Verificare log ASM e alert log ASM per quella data
2. Confermare con il team storage che non ci siano problemi residui sul diskgroup `DATA_PPBPROD`
3. Monitorare ORA-00345 nei prossimi cicli di scan

---

### [INFRA-001] SSH non raggiungibile su axprracdb03 (intermittente) 🟡 P3

| Campo | Valore |
|---|---|
| **Host** | axprracdb03 (PROD) |
| **Rilevato** | 2026-09-05, durante sessione di analisi |
| **Tool** | `identify_instance`, `check_memory_pressure` |

**Descrizione**: Durante la sessione del 2026-09-05, axprracdb03 era intermittentemente irraggiungibile via SSH dalla macchina `lxprworkerlana01` (connection_failed), mentre axprracdb04 rispondeva regolarmente. Dopo qualche minuto la connessione SSH è tornata disponibile. Potrebbe essere un problema di carico temporaneo, firewall o configurazione sshd.

**Azione suggerita**:
1. Verificare con il team infrastruttura se ci sono manutenzioni pianificate su axprracdb03
2. Monitorare la frequenza del fenomeno nelle prossime sessioni

---

### [TOOL-001] Bug JSON encoding in `scan_alert_log` su testi non-ASCII 🟠 P2

| Campo | Valore |
|---|---|
| **Componente** | `tools/scan_alert_log.sh` |
| **Rilevato** | 2026-09-05, su SDC1/axprracdb03 |

**Descrizione**: L'alert log di SDC1 contiene messaggi Oracle in italiano (es. "ORA-03135: connessione interrotta"). La funzione `json_esc()` in `scan_alert_log.sh` non gestisce correttamente i caratteri non-ASCII (UTF-8 multibyte), producendo un JSON invalido che causa `parse error: Invalid numeric literal` e `Invalid control character`. Il tool restituisce errore HTTP 500 via MCP.

**Azione suggerita**:
1. Estendere `json_esc()` in `scan_alert_log.sh` per escapare o sostituire i byte non-ASCII (iconv to ASCII//TRANSLIT o filtro awk)
2. Aggiungere test di regressione con fixture contenente caratteri non-ASCII

---

### [TOOL-002] `scan_alert_log` supera il timeout MCP su file grandi (>300 MB) 🟡 P3

| Campo | Valore |
|---|---|
| **Componente** | `tools/scan_alert_log.sh` + `mcp/config.py` (TOOL_TIMEOUT) |
| **Rilevato** | 2026-09-05, su SDC1/axprracdb03 (387 MB) |

**Descrizione**: Lo scan dell'alert log di SDC1 (387 MB) supera il timeout del tool (120s default), causando un errore MCP. Il tool funziona correttamente se eseguito direttamente sul server con `timeout 90`, ma richiede più del timeout configurato via MCP.

**Azione suggerita**:
1. Aumentare `TOOL_TIMEOUT` in `mcp/config.py` per i tool di log (es. 300s) o aggiungere un timeout specifico per `scan_alert_log`
2. Considerare uno streaming incrementale o una pre-scansione con `tail` + `grep` per file molto grandi

---

## Issue risolte

| ID | Descrizione | Risolto in |
|---|---|---|
| INFRA-002 | Supporto Oracle RAC: env file senza suffisso numerico (ksh `[ -f ]`) | 2026-09-05 |
| INFRA-003 | `find` ricorsivo NFS bloccato su dir `cdmp_*` RAC → glob a profondità fissa | 2026-09-05 |
| INFRA-004 | Server MCP irresponsivo durante chiamate parallele → `run_in_executor` | 2026-09-05 |
| TOOL-001 | `scan_alert_log.sh` JSON invalido su byte non-ASCII (Latin-1) e backslash nel dizionario | 2026-09-05 |
