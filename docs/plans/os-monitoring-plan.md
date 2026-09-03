# Piano: Espansione MCP con Tool di Monitoraggio OS

## Top-Level Overview

### Obiettivo
Aggiungere al sistema una famiglia di tool primitivi bash che raccolgano metriche OS (CPU, memoria, swap, disco, rete) dai server Oracle via SSH, con un'astrazione cross-platform (AIX / Linux) e un'integrazione in runbook orchestrati che correlino lo stato OS con quello Oracle già osservabile.

### Approccio
Tre strati di lavoro:
1. **Libreria OS** (`lib/os_cmd.sh`) — astrazione cross-platform che seleziona i comandi giusti per AIX vs Linux, gestisce il campionamento temporale e segnala i comandi mancanti.
2. **Tool primitivi OS** (4 script bash in `tools/`) — uno per categoria metrica (cpu, memory, disk, network), ognuno con campionamento configurabile e output JSON standard con statistiche aggregate (min, max, avg, p95, p99).
3. **Runbook orchestrato** (`diagnose_os_pressure` in Python) — chiama i primitivi OS in parallelo, li correla con i tool Oracle esistenti (`check_memory_pressure`, `check_resource_limits`, `sessions_by_user`) e produce un summary interpretato.

### Scope
- 3 nuovi tool primitivi bash (CPU, memoria, disco) — primo round
- 1 libreria di supporto bash (`lib/os_cmd.sh`)
- 1 nuovo orchestrato Python (`diagnose_os_pressure`)
- Esposizione MCP in `mcp/main.py` e `mcp/orchestration.py`
- Test contract per i nuovi primitivi
- Aggiornamento docs/specs

### Non-obiettivi (primo round)
- Monitoraggio continuo / streaming (incompatibile con il modello request/response MCP)
- Alert proattivi o notifiche
- Analisi di serie storiche (questo è un singolo snapshot multi-campione)
- Accesso `root` — solo comandi disponibili all'utente `oracle`
- Tool di rete `os_network_stats.sh` — rimandato al **secondo round** (vedi BACKLOG)

---

## Sub-Task 1 — Libreria `lib/os_cmd.sh`

### Intent
Creare una libreria bash centralizzata che:
- Rileva il sistema operativo remoto via SSH (`uname -s`) — AIX o Linux
- Fornisce funzioni per eseguire il set corretto di comandi per ogni OS
- Implementa il campionamento temporale (N campioni, intervallo configurabile)
- Segnala via errore JSON standardizzato (`command_not_available`) se un comando richiesto non è presente sul target
- Espone le funzioni ssh_sample e ssh_detect_os che i tool primitivi useranno

### Expected Outcomes
- File `lib/os_cmd.sh` presente e sourceable da ogni tool bash
- Funzione `os_detect HOST` che restituisce `aix` o `linux` (o `unknown`)
- Funzione `os_sample HOST SAMPLES INTERVAL CMD_AIX CMD_LINUX` che esegue N volte il comando corretto, raccoglie l'output grezzo e lo restituisce
- Funzione `os_check_cmd HOST CMD` che verifica disponibilità di un comando (`which CMD`) e restituisce `available` o `missing`
- In caso di comando mancante: output JSON con `"error": {"code": "command_not_available", "context": {"command": "vmstat", "os": "aix"}}` — così possiamo sistemare a posteriori

### Todo List
1. Aggiungere in `docs/specs/contratto-json.md` il nuovo codice di errore `command_not_available` con context `command` e `os`
2. Creare `lib/os_cmd.sh` con:
   - Variabile `OS_MAX_SAMPLE_DURATION` (default 30s) — limite massimo per samples × interval; se superato il tool usa il max consentito e non fallisce
   - Funzione `os_detect HOST` — esegue `ssh oracle@HOST uname -s` con timeout breve (5s), restituisce `aix`/`linux`/`unknown`
   - Funzione `os_check_cmd HOST CMD` — esegue `ssh oracle@HOST "which CMD 2>/dev/null"`, controlla exit code
   - Funzione `os_sample HOST SAMPLES INTERVAL CMD_AIX CMD_LINUX` — rileva OS, seleziona il comando corretto, loop SSH con sleep tra campioni; raccoglie stdout riga per riga con separatore `\001` tra campioni
   - Riutilizza `ORACLE_SSH_KEY` e `ORACLE_SSH_USER` da `lib/oracle_conn.sh` (sourceable in cascata)
3. Aggiungere test in `tests/test_contract.sh` per validazione argomenti dei nuovi tool (modalità `--quick`)

### Relevant Context
- `lib/oracle_conn.sh` righe 67-69: variabili SSH già definite (`ORACLE_SSH_KEY`, `ORACLE_SSH_USER`)
- `tools/list_instances_on_host.sh` righe 42-52: pattern SSH senza sqlplus — riferimento canonico
- `docs/specs/architettura.md` righe 12-18: vincoli AIX (ksh, no bash, no gawk)
- `docs/specs/contratto-json.md` righe 45-57: tabella codici errore da estendere
- `TOOL_TIMEOUT` in `mcp/config.py` = 120s (default). Il campionamento con OS_MAX_SAMPLE_DURATION=30s è abbondantemente sotto. Il proxy Apache `ProxyTimeout 300` è il limite superiore esterno. Non serve alzare nessun timeout.

### Status
[ ] pending

---

## Sub-Task 2 — Tool primitivo `os_cpu_stats.sh`

### Intent
Raccogliere metriche CPU e run queue dal server via `vmstat` (AIX e Linux), con campionamento multiplo e aggregazione statistica. Output: CPU user%, sys%, idle%, wait%, run queue length — per campione e statistiche aggregate.

### Expected Outcomes
- `tools/os_cpu_stats.sh ENV HOSTNAME [--samples=N] [--interval=S]`
- Default: 5 campioni, 2 secondi di intervallo (totale 10s — ben sotto il limite di 30s)
- Parametro `--samples` e `--interval` opzionali; se samples × interval > OS_MAX_SAMPLE_DURATION il tool li riduce automaticamente
- Firma: solo `ENV HOSTNAME` — nessun `INSTANCE_NAME` (tool OS-level)
- Output JSON conforme al contratto standard con:
  - `data`: array di campioni con timestamp, `cpu_user_pct`, `cpu_sys_pct`, `cpu_idle_pct`, `cpu_wait_pct`, `run_queue`
  - `summary`: oggetto con `min`, `max`, `avg`, `p95`, `p99` per ogni metrica
  - `cpu_count`: numero di CPU logiche dell'host (rilevato nel medesimo SSH call — `nproc` su Linux, `bindprocessor -q | wc -w` su AIX); usato internamente per classificare la run queue, esposto nell'output per trasparenza
  - `os_type`: `aix` o `linux`
- In caso di comando mancante: JSON error `command_not_available`
- `instance_name`: `null` (tool OS non conosce le istanze Oracle)

### Todo List
1. Identificare il formato esatto di output `vmstat` su AIX e su Linux (column mapping); documentare nel Relevant Context di questo sub-task
2. Creare `tools/os_cpu_stats.sh` che:
   - Sourcia `lib/oracle_conn.sh` e `lib/os_cmd.sh`
   - Valida ENV e HOST (no INST); usa validazione manuale (no `validate_args` che richiede INST)
   - Chiama `os_detect` per sapere AIX vs Linux
   - Rileva `cpu_count` nello stesso SSH call (`nproc` su Linux, `bindprocessor -q` su AIX)
   - Chiama `os_check_cmd` per verificare `vmstat` disponibile
   - Chiama `os_sample` con il comando `vmstat` corretto per l'OS
   - Parsa l'output con awk POSIX (no gawk extensions) — il parsing gira sull'host MCP (RHEL), ma teniamo POSIX per coerenza
   - Calcola statistiche (min, max, avg, p95, p99) in awk
   - Produce envelope JSON standard con `build_envelope`
3. Aggiungere fixture test in `tests/fixtures/os_cpu_stats.ok.json`
4. Aggiungere caso di validazione argomenti in `tests/test_contract.sh`

### Relevant Context
- `vmstat` AIX: colonne `kthr` (run queue `r`, blocked `b`), `cpu` (`us`, `sy`, `id`, `wa`)
- `vmstat` Linux: colonne `procs` (`r`, `b`), `cpu` (`us`, `sy`, `id`, `wa`)
- Il parsing avviene sull'host MCP (ppc64le RHEL) — gawk disponibile — ma è buona pratica restare POSIX
- `docs/specs/architettura.md` riga 14: "evitare estensioni GNU-only (gawk); preferire POSIX awk portabile"
- Pattern argomenti opzionali: vedi `tools/scan_alert_log.sh` per parsing `--key=value`

### Status
[ ] pending

---

## Sub-Task 3 — Tool primitivo `os_memory_stats.sh`

### Intent
Raccogliere metriche RAM e swap. Su AIX usare `svmon -G` (memoria globale) e `lsps -s` (swap); su Linux usare `free -b` e `/proc/meminfo` (o `vmstat`). Output: RAM total/used/free/cached, swap total/used/free, memoria paginata (page in/out da vmstat).

### Expected Outcomes
- `tools/os_memory_stats.sh ENV HOSTNAME [--samples=N] [--interval=S]`
- Output JSON con:
  - `data`: campioni con `ram_total_bytes`, `ram_used_bytes`, `ram_free_bytes`, `swap_total_bytes`, `swap_used_bytes`, `page_in_per_sec`, `page_out_per_sec`
  - `summary`: min/max/avg/p95/p99 per le metriche variabili nel tempo (page in/out, ram_used, swap_used)
  - `os_type`: `aix` o `linux`
- Se `svmon` non disponibile su AIX: errore `command_not_available` con contesto — segnala che serve installazione
- Nota: su un host con RAM esaurita e swap al 100%, SSH stesso potrebbe fallire; in questo caso il tool restituisce `connection_failed` che è già un'informazione diagnostica (come discusso)

### Todo List
1. Documentare il formato di output di `svmon -G` (AIX) e `free -b` (Linux)
2. Creare `tools/os_memory_stats.sh` con:
   - Stesso pattern di `os_cpu_stats.sh` per detect OS e check cmd
   - Su AIX: `svmon -G` per RAM, `lsps -s` per swap, `vmstat 1 N` per page in/out
   - Su Linux: `free -b` per RAM/swap, `vmstat 1 N` per page in/out
   - Parsing awk POSIX
   - Calcolo statistiche aggregato
   - Envelope standard
3. Aggiungere fixture test e caso `--quick`

### Relevant Context
- `svmon -G` output AIX: colonne `memory`, `pgspace` (swap), `inuse`, `free`, `pin`, `virtual`
- `lsps -s` output AIX: percentuale swap utilizzata globale
- `free -b` output Linux: standard
- Il fallback `connection_failed` quando SSH non risponde su host con OOM è già diagnostico (come richiesto: "se SSH non risponde ma il server è pingabile, è già un'indicazione")
- In futuro potrebbe valere aggiungere un tool `os_ping_check.sh` (ICMP check da MCP host) per distinguere "host spento" da "host OOM" — non in scope ora

### Status
[ ] pending

---

## Sub-Task 4 — Tool primitivo `os_disk_stats.sh`

### Intent
Raccogliere utilizzo filesystem e I/O disco. `df` per lo spazio; `iostat` per throughput/latenza. Focalizzato sui filesystem rilevanti per Oracle (datafile, FRA, redo log, archivelog).

### Expected Outcomes
- `tools/os_disk_stats.sh ENV HOSTNAME [--samples=N] [--interval=S] [--fs=PATH]`
- Parametro opzionale `--fs=PATH` per filtrare un filesystem specifico (es. `/oracle/data`); senza filtro: tutti i filesystem
- Output JSON con:
  - `data.filesystems`: array con `mount_point`, `total_bytes`, `used_bytes`, `free_bytes`, `use_pct`
  - `data.io_samples`: campioni con `device`, `reads_per_sec`, `writes_per_sec`, `read_kb_per_sec`, `write_kb_per_sec`, `await_ms` (latenza media, se disponibile)
  - `summary.io`: min/max/avg/p95/p99 per throughput e latenza per device
  - `os_type`
- `iostat` su AIX ha formato diverso da Linux — gestito via branch in `lib/os_cmd.sh`
- Se `iostat` non disponibile: `df` viene comunque eseguito, solo `io_samples` sarà vuoto con warning nel JSON

### Todo List
1. Documentare formato `iostat` AIX (opzione `-d`) vs Linux (`iostat -xd`)
2. Creare `tools/os_disk_stats.sh` con:
   - Detect OS + check cmd separato per `df` e `iostat`
   - `df` sempre eseguito (presente su entrambi gli OS)
   - `iostat` opzionale — se mancante: `io_samples: []` + campo `"io_available": false` nel JSON
   - Parsing separato per AIX vs Linux per entrambi i comandi
   - `--fs` filtro applicato in awk durante il parsing di `df`
3. Aggiungere fixture e test

### Relevant Context
- `iostat` su AIX richiede il pacchetto `bos.acct` — potrebbe non essere installato; gestire con `command_not_available` parziale (solo per `iostat`, non per `df`)
- `df -k` è POSIX e funziona su entrambi gli OS; aggiungere `-P` (POSIX output) se disponibile
- I filesystem Oracle critici su AIX tipicamente sono VFS o JFS2 — `df` li elenca normalmente
- Correlazione con `check_fra_usage.sh` (strumento Oracle) già esistente: il nuovo tool fornisce la vista OS, quello Oracle la vista logica FRA — in `diagnose_os_pressure` si possono correlare

### Status
[ ] pending

---

## Sub-Task 5 — [BACKLOG] Tool primitivo `os_network_stats.sh`

> **Rimandato al secondo round.** CPU/memoria/disco hanno utilità immediata maggiore. Questo sub-task è in BACKLOG e non bloccante per Sub-task 6.

### Intent
Raccogliere statistiche di rete: throughput per interfaccia e contatori di errore. Utile per diagnosticare colli di bottiglia tra application server e DB server.

### Expected Outcomes (da definire nel secondo round)
- `tools/os_network_stats.sh ENV HOSTNAME [--samples=N] [--interval=S] [--iface=NAME]`
- Output JSON con campioni per interfaccia: `rx_bytes_per_sec`, `tx_bytes_per_sec`, `rx_errors`, `tx_errors`, `rx_drops`, `tx_drops`
- Su AIX: `netstat -I IFACE` o `entstat -d IFACE`
- Su Linux: diff su `/proc/net/dev`

### Status
[ ] backlog — secondo round

---

## Sub-Task 6 — Runbook orchestrato `diagnose_os_pressure`

### Intent
Creare in `mcp/orchestration.py` un nuovo orchestrato che combina i 3 primitivi OS (CPU, memoria, disco) con i tool Oracle già esistenti, produce un summary correlato che risponde alla domanda "il server sta soffrendo a livello OS? e se sì, è correlato con il carico Oracle?".

### Expected Outcomes
- Funzione `diagnose_os_pressure(env, host, inst, samples, interval)` in `mcp/orchestration.py`
- Esegue in parallelo:
  - `os_cpu_stats` (samples e interval passati come parametri)
  - `os_memory_stats`
  - `os_disk_stats`
  - `check_memory_pressure` (Oracle PGA)
  - `check_resource_limits` (Oracle sessioni/processi)
  - `sessions_by_user` (Oracle)
  - (nota: `os_network_stats` aggiunto in secondo round quando disponibile)
- Produce `summary` con:
  - `livello_pressione_os`: `bassa`/`media`/`alta` basato su CPU runqueue, RAM/swap e I/O wait
  - `livello_pressione_oracle`: come già fatto in `check_memory_pressure`
  - `correlazioni`: lista di osservazioni che incrociano i due domini (es. "CPU wait alto + PGA elevata → probabile I/O da sort su disco", "swap usata > 80% + sessioni Oracle al limite → rischio OOM")
  - `raccomandazioni`: lista ordinata per priorità
  - `details`: risultati raw di ogni primitivo (come negli orchestrati esistenti)

### Logic Correlation Rules (da implementare)
Le regole di correlazione sono euristiche semplici, non ML:

- CPU run queue > (2 × CPU count) + PGA elevata → "bottleneck CPU, non memoria — verificare query CPU-intensive"
- CPU wait% > 30% → "attesa I/O OS significativa — correlare con iostat e check_fra_usage"
- swap_used_pct > 50% → "pressione RAM: OS sta paginando su disco"
- swap_used_pct > 80% + connection_failed Oracle → "probabile OOM — host sotto stress critico"
- RAM free% < 5% → "RAM quasi esaurita — rischio OOM imminente"
- disk io await > 50ms per device Oracle → "latenza disco elevata — correlare con performance query"
- net rx/tx errors > 0 → "errori NIC — possibili timeout connessioni applicative"

### Todo List
1. Aggiungere funzione `diagnose_os_pressure` in `mcp/orchestration.py`:
   - Signature: `def diagnose_os_pressure(env: str, host: str, inst: str, samples: int = 5, interval: int = 2) -> dict`
   - Usa `_run_parallel` (già esistente) per i primitivi OS e Oracle in parallelo
   - Implementa le regole di correlazione come lista di check condizionali (vedi sezione "Logic Correlation Rules")
   - Produce envelope standard (`_envelope`) con campo `summary` esteso
2. Aggiungere in `mcp/main.py`:
   - Entry nel catalogo `TOOL_CATALOG` e `MCP_TOOLS` per i 3 primitivi OS + l'orchestrato
   - Input schema: `samples` (integer, opzionale, default 5) e `interval` (integer, opzionale, default 2)
   - Route REST `/tools/diagnose_os_pressure`
   - Branch in `_dispatch_tool`
3. Esporre anche i 3 primitivi OS in `TOOL_CATALOG`, `MCP_TOOLS` e `_dispatch_tool` come tool chiamabili individualmente
4. Aggiungere test MCP wire per `diagnose_os_pressure` in `tests/`

### Relevant Context
- Pattern orchestrato di riferimento: `diagnose_instance` in `mcp/orchestration.py` righe 96-219
- `_run_parallel` già implementato con `ThreadPoolExecutor` — riutilizzare
- I primitivi OS hanno `instance_name: null` — nell'orchestrato `inst` serve solo per i tool Oracle
- Il campo `oracle_version` nell'envelope orchestrato è `null` (non applicabile al tool OS puro) ma viene popolato dal risultato di `check_memory_pressure`
- `TOOL_TIMEOUT` in `mcp/config.py` = 120s (subprocess timeout); `OS_MAX_SAMPLE_DURATION` = 30s — ampio margine
- Il semaforo `MCP_MAX_CONCURRENT` = 8 (default) limita già le chiamate concorrenti pesanti
- L'orchestrato lancia 6 task in parallelo: 3 OS + `check_memory_pressure` + `check_resource_limits` + `sessions_by_user` — ben dentro il semaforo

### Status
[ ] pending

---

## Sub-Task 7 — Aggiornamento documentazione e specs

### Intent
Mantenere `docs/specs/architettura.md` e `docs/specs/contratto-json.md` allineati con il nuovo dominio OS, in modo che le sessioni future abbiano contesto completo.

### Expected Outcomes
- `docs/specs/architettura.md` aggiornato con:
  - Nuova sezione "Tool OS (monitoring)" nella tabella tool pianificati
  - Principio cross-platform con branch AIX/Linux documentato
  - Riferimento a `lib/os_cmd.sh`
- `docs/specs/contratto-json.md` aggiornato con:
  - Nuovo codice errore `command_not_available`
  - Esempi output per `os_cpu_stats` e `os_memory_stats`
  - Nota su `instance_name: null` per tool OS

### Todo List
1. Aggiornare `docs/specs/contratto-json.md`: aggiungere `command_not_available` in tabella codici errore
2. Aggiornare `docs/specs/architettura.md`: aggiungere sezione tool OS + principio cross-platform
3. Creare file sessione `docs/sessions/YYYY-MM-DD.md` al termine dell'implementazione (come da procedura)

### Status
[ ] pending

---

## Dipendenze tra sub-task

```
Sub-Task 1 (lib/os_cmd.sh)
    ├── Sub-Task 2 (os_cpu_stats.sh)
    ├── Sub-Task 3 (os_memory_stats.sh)
    └── Sub-Task 4 (os_disk_stats.sh)
            ↓ tutti e tre
        Sub-Task 6 (orchestrato Python)
            ↓
        Sub-Task 7 (docs)

Sub-Task 5 (os_network_stats.sh) → BACKLOG secondo round
```

Sub-task 2, 3, 4 sono indipendenti tra loro e possono essere sviluppati in sequenza qualsiasi dopo Sub-task 1. Sub-task 6 può partire non appena Sub-task 2 e 3 sono pronti; Sub-task 4 si aggiunge incrementalmente.

## Decisioni confermate

| Punto | Decisione |
|---|---|
| Timeout campionamento | `OS_MAX_SAMPLE_DURATION=30s` (default); `TOOL_TIMEOUT=120s` in `mcp/config.py` — nessun timeout MCP da alzare |
| Tool di rete | Rimandato al secondo round — inserito in BACKLOG come Sub-task 5 |
| Firma tool OS | `ENV HOSTNAME [--opt...]` — nessun `INSTANCE_NAME` |
| CPU count | Campo `cpu_count` nell'output di `os_cpu_stats.sh`; rilevato nello stesso SSH call con `nproc` (Linux) o `bindprocessor -q` (AIX); usato nelle regole di correlazione per "run queue alta > 2× cpu_count" |
