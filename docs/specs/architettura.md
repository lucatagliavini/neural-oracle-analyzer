# Specs: Architettura dei tool diagnostici Oracle

Questo file contiene i principi architetturali stabiliti per il progetto. Ogni implementazione (script, refactor, nuovo tool) deve rispettarli. Quando emerge un principio nuovo o ne viene rivisto uno esistente, questo file va aggiornato di conseguenza — non solo applicato "a memoria" nella sessione corrente.

## Obiettivo del progetto

Trasformare il runbook diagnostico manuale del team DBA (istanza, PDB, FRA, alert log, sessioni, PGA/SGA) in una libreria di tool bash/awk/python3 indipendenti con output JSON strutturato, esposti come server MCP per analisi e monitoraggio dei server Oracle. Il server MCP costituisce l'orchestrazione che invoca questi tool e ne espone il contratto al client.

## Piattaforme target e vincoli di compatibilità

- **Host del server MCP**: RHEL 9.8 Linux on Power, architettura `ppc64le` (macchina `lxprworkerlana01`, vedi `infrastruttura.md`).
- **Target Oracle da diagnosticare**: sia server Linux sia server **AIX**. Gli script possono quindi essere eseguiti (via SSH) anche su AIX, non solo sull'host MCP.
- Vincolo trasversale: bash, awk e python3 usati nel progetto devono restare compatibili sia con RHEL 9.8 ppc64le sia con AIX, per qualunque logica che possa finire per girare su un target AIX. In pratica, se in futuro un tool dovesse eseguire awk/bash/python3 direttamente su un target AIX (non solo `sqlplus`), valgono questi vincoli:
  - **awk**: evitare estensioni GNU-only (gawk); preferire sintassi POSIX awk portabile.
  - **bash**: la shell di login di default su AIX è tipicamente `ksh`, non bash — non assumerla disponibile senza verifica.
  - **python3**: non incluso di default su AIX (richiede tipicamente IBM AIX Toolbox for Linux Applications) — disponibilità/versione da validare per target.
- **Decisione (log analysis)**: i tool di log analysis (`scan_alert_log.sh`, `tail_alert_log.sh`) leggono l'alert log da un **mount NFS locale sull'host MCP**, non via SSH+awk remoto sul target. Questo significa che l'awk per questa categoria gira sempre su ppc64le (gawk disponibile), bypassando il problema di compatibilità awk/AIX per questi tool. Se il path del mount per un dato target (vedi «Convenzioni di ambiente») non esiste o non è raggiungibile, il tool **non deve tentare fallback via SSH**: deve restituire un JSON di errore esplicito (es. `{"error": "log_not_found", "path": "..."}`), lasciando che sia l'operatore/orchestratore a decidere il passo successivo.
- Conseguenza pratica attuale: con questa decisione, l'unica cosa che esegue realmente *su* un target AIX è `sqlplus` stesso (invocato via SSH) — un binario Oracle, non codice nostro. La logica di parsing/JSON del suo output può quindi girare sull'host MCP dopo che l'output torna sul canale SSH, non sul target. Il vincolo di portabilità awk/bash/python3 sopra resta come principio generale (nel caso servisse in futuro un tool che deve eseguire logica nostra direttamente su AIX), ma **non è oggi un blocco attivo** per nessuno dei tool pianificati.

## Esposizione del server MCP

- Trasporto: **HTTP** (non stdio) — uso interno.
- **Runtime**: Python 3 + **FastAPI** (su `lxprworkerlana01`, architettura `ppc64le` — verificare disponibilità pacchetti prima del deploy).
- Autenticazione: **API key fissa e specifica**, inserita nella configurazione MCP lato client per autenticare le richieste.
- Raccomandazione di sicurezza: la API key non va mai committata in chiaro nel repository; va gestita come variabile d'ambiente o file di configurazione escluso dal versionamento. Anche trattandosi di uso interno, valgono le stesse considerazioni di hardening già previste per l'accesso SSH (restrizione per IP sorgente dove la rete lo consente).

## Librerie condivise

Il progetto ha due librerie condivise. Ogni tool deve usarle — mai duplicarne la logica inline.

### `lib/oracle_conn.sh` — connessione, validazione, envelope JSON

Punto unico per tutto ciò che riguarda SSH, sqlplus, validazione argomenti e costruzione dell'envelope JSON:

### Funzioni della libreria (aggiornato post-refactor 2026-09-02)

| Funzione | Uso |
|---|---|
| `validate_environment ENV` | valida enum ENVIRONMENT, return 1 se invalido |
| `get_prod_noprod ENV` | stampa `prod`/`noprod` |
| `validate_args TOOL ENV HOST INST` | valida i 3 argomenti standard, stampa JSON errore se fallisce — usare con `\|\| exit $?` |
| `classify_error STDERR_TEXT` | stampa `connection_failed`/`missing_env_file`/`query_failed` dall'output stderr di `run_sqlplus_raw` |
| `build_error_json TOOL ENV HOST INST CODE MSG CTX [VER]` | costruisce envelope JSON di errore su stdout |
| `build_envelope TOOL ENV HOST INST VER STATUS DATA ERR` | costruisce envelope JSON su stdout |
| `run_sqlplus_raw HOST INST SQL_BLOCK` | trasporto SSH puro; struttura SQL interamente libera; exit 1 + stderr prefissato in caso di errore |
| `run_sqlplus_query HOST INST QUERY` | wrapper `run_sqlplus_raw` per query singola — stdout = riga versione + array JSON |
| `run_tool TOOL ENV HOST INST QUERY` | entry point completo per tool a query singola semplice |
| `find_alert_log HOST INST ENV` | path NFS alert log (gestisce duplicati da migrazione) |

**Pattern per tool con logica aggiuntiva** (versione check, multi-query, filtri opzionali):
```bash
validate_args "$TOOL" "$ENV" "$HOST" "$INST" || exit $?
stderr_tmp=$(mktemp)
raw=$(run_sqlplus_raw "$HOST" "$INST" "$sql_block" 2>"$stderr_tmp")
rc=$?; err_detail=$(cat "$stderr_tmp"); rm -f "$stderr_tmp"
if [ $rc -ne 0 ]; then
    err_code=$(classify_error "$err_detail")
    # build_error_json con err_code + exit 1
fi
# build_envelope
```



### `lib/json_esc.awk` — escape JSON per testo libero in awk

Ogni tool awk che inserisce testo libero (log Oracle, messaggi di errore, output non-strutturato) in un valore stringa JSON **deve** usare questa libreria. Non scrivere inline una funzione di escape JSON in un tool.

**Quando usarla**: ogni volta che un programma awk scrive `"campo":"` + valore che può contenere caratteri speciali o proviene da un file di log Oracle.

**Come includerla**:
```bash
AWK_LIB="${SCRIPT_DIR}/../lib/json_esc.awk"
_awk_tmp=$(mktemp /tmp/toolname_XXXXXX.awk)
cat > "$_awk_tmp" << 'AWK'
# ... programma awk del tool ...
# usa json_esc($0) o json_esc(variabile) dove serve
AWK
LC_ALL=C awk -f "${AWK_LIB}" -f "$_awk_tmp" "$INPUT_FILE"
rm -f "$_awk_tmp"
```

**Perché il file temporaneo**: `-f /dev/stdin` non funziona quando stdin è già occupato da una pipe di dati; gawk `-f` con due file è l'alternativa portabile.

**Perché `LC_ALL=C`**: i log Oracle possono contenere messaggi in italiano/francese con encoding Latin-1 (es. byte `0xe8` per "è"). Con `LC_ALL=C` gawk tratta ogni byte come carattere singolo, permettendo alla libreria di rilevare e sostituire i byte non-ASCII con `?` invece di produrre JSON invalido.

**Cosa gestisce `json_esc()`**:
- `\` → `\\`, `"` → `\"`, tab/CR/BS/FF → sequenze `\x`
- Caratteri di controllo ASCII `< 0x20` → `\uXXXX`
- Byte non-ASCII `>= 0x80` (Latin-1 Oracle) → `?`

**Nota**: il dizionario `data/ora_errors.json` (description, category, severity) contiene valori con backslash e virgolette. Non parsarlo con regex awk — usare `jq` per pre-processarlo in formato tabulare `\x01`-separato prima di passarlo ad awk. Vedi `scan_alert_log.sh` come riferimento.

### Regole Oracle RAC per env file

Le istanze Oracle RAC hanno un suffisso numerico nel nome (`PPBPROD1`, `PPBPROD2`) ma condividono un singolo env file senza numero (`PPBPROD.env`). `run_sqlplus_raw()` in `lib/oracle_conn.sh` gestisce già questo fallback — non replicare la logica nei tool.

**Regola**: la shell remota è **ksh**. Su ksh, `. ~/FILE.env` su file inesistente **termina la shell immediatamente** (exit 1), anche con `2>/dev/null` — il `||` non scatta. Per verificare l'esistenza prima di sourciare usare `[ -f ~/FILE.env ] && . ~/FILE.env || ...`, non `. ~/FILE.env 2>/dev/null || ...`.

- **Env file (confermato, validato su axnporadb41 2026-09-01)**: in `/home/oracle/` sul server destinazione esistono symlink a file `.env` di due tipi:
  - `<INSTANCE_NAME>.env` (es. `NP41CDB0.env`) → env del **CDB** — quello da sourcare per le nostre connessioni. Setta: `ORACLE_BASE`, `ORACLE_HOME`, `LD_LIBRARY_PATH`, `PATH`, `ORACLE_SID`, `ORACLE_PDB_SID` (vuoto per CDB), `ORACLE_HOSTNAME` (FQDN nodo logico), `TNS_ADMIN` (wallet path).
  - `<PDB_NAME>.env` (es. `AIMELA.env`) → env dei **PDB** — hanno `ORACLE_SID=<CDB_PADRE>` e `ORACLE_PDB_SID=<NOME_PDB>`. Non usati dai nostri tool (connessione applicativa, non SYSDBA).
  - I symlink puntano a path reali tipo `/np41cdb0/home/NP41CDB0/<NAME>.env`
- **Shell remota**: il server Oracle usa **ksh** (non bash) — usare `.` (dot) invece di `source` per eseguire gli env file. `source` non esiste in ksh e genera errore 127.
- **Meccanismo di connessione (validato)**: `. ~/NP41CDB0.env && sqlplus -s / as sysdba` — il `.` imposta `ORACLE_HOME`, `ORACLE_SID` e le variabili Oracle necessarie; `/ as sysdba` si connette localmente senza password. Output CSV con `SET MARKUP CSV ON` confermato funzionante.
- **Discovery istanze su un host (confermato)**: `ssh oracle@<hostname> "ls ~/NP*.env"` restituisce tutti gli env file CDB disponibili sull'host fisico. Su `axnporadb41`: 9 CDB (`NP41CDB0-2`, `NP42CDB0-1`, `NP43CDB0-1`, `NP44CDB0-1`) — l'host fisico ospita i volumi di più nodi logici (cluster HA). Su `axnporadb51`: 5 CDB (`NP51CDB0-1`, `NP52CDB0`, `NP53CDB0`, `NP54CDB0`).
- `run_sqlplus_query()`: via SSH usa `.` per sourcare l'env del CDB, lancia `sqlplus -s / as sysdba`, imposta `SET MARKUP CSV ON`, cattura l'output e lo converte in JSON via awk.
- **`INSTANCE_NAME` nel contratto** = `ORACLE_SID` = nome del CDB (es. `NP41CDB0`) — confermato: `v$instance.instance_name` restituisce lo stesso valore di `ORACLE_SID`.
- **`ORACLE_HOSTNAME`** nell'env file = FQDN del nodo logico (es. `np41cdb0.servizi.gr-u.it`), diverso dall'host fisico `axnporadb41`. Per i nostri tool usare sempre il nome host fisico (quello su cui fare SSH e quello della directory NFS).

Ogni tool richiama questa libreria e si occupa solo della query specifica e della formattazione dell'output. Eventuali cambi futuri al meccanismo di autenticazione/connessione devono restare isolati in questo unico file.

## Contratto comune dei tool

- Input: parametri `ENVIRONMENT`, `HOSTNAME`, `INSTANCE_NAME` — mai hardcoded. `INSTANCE_NAME` = nome del CDB (es. `NP41CDB0`), non il PDB.
- Output: JSON strutturato su stdout.
- Un tool = una responsabilità singola (niente script monolitici con flag multipli): coerente con il modello di dichiarazione tool MCP (nome, descrizione, scopo singolo).
- `ENVIRONMENT` è un enum fisso e case-sensitive: `EURO`, `TEST`, `CERT`, `INTE`, `COLL`, `PROD`. Validare sempre questo valore in ogni tool.

## Elenco tool pianificati

| Categoria | Tool | Fonte |
|---|---|---|
| Discovery | `list_instances_on_host.sh` | comandi forniti dal team DBA (es. oratab / processi pmon) via SSH — elenca le istanze presenti su un host (candidato, da confermare comandi esatti) |
| Discovery | `identify_instance.sh` | `select * from v$instance;` |
| Discovery | `list_pdbs.sh` | `show pdbs` |
| Discovery | `get_diag_home.sh` | `show parameters diag` (serve a costruire dinamicamente il path dell'alert log) |
| Spazio/FRA | `check_fra_usage.sh` | `v$recovery_file_dest`, `v$flash_recovery_area_usage`, `DB_RECOVERY_FILE_DEST_SIZE` |
| Log analysis | `scan_alert_log.sh` | awk su pattern `ORA-\d+`, raggruppato per codice/timestamp, filtro opzionale `--code=`. Legge da mount NFS locale sull'host MCP; errore esplicito nel JSON se il path non esiste (no fallback SSH) |
| Log analysis | `tail_alert_log.sh` | invocazione puntuale bounded, **non** streaming continuo (incompatibile con request/response MCP). Stesso mount NFS locale di `scan_alert_log.sh` |
| Sessioni | `check_resource_limits.sh` | `v$resource_limit` |
| Sessioni | `sessions_by_user.sh` | `v$session` per utente/stato |
| Sessioni | `sessions_by_machine.sh` | `v$session` per macchina/stato |
| Memoria/PGA | `pga_sga_by_pdb.sh` | `v$rsrcpdbmetric` + `cdb_pdbs` (richiede Resource Manager PDB plan attivo) |
| Memoria/PGA | `pga_by_pdb_session.sh` | join `v$session`/`v$process`/`cdb_pdbs` |
| Memoria/PGA | `top_pga_sessions.sh` | `v$process` + `v$session` ordinato per PGA |
| OS Monitoring | `os_cpu_stats.sh` | `vmstat` via SSH — CPU user/sys/idle/wait%, run queue; AIX e Linux |
| OS Monitoring | `os_memory_stats.sh` | `svmon -G`+`lsps -s` (AIX) o `free -b` (Linux) + `vmstat` per page in/out |
| OS Monitoring | `os_disk_stats.sh` | `df -k` (filesystem) + `iostat` (I/O) via SSH; `--fs=` per filtro mount point |
| OS Monitoring | `os_network_stats.sh` | `netstat -In` (AIX) o `/proc/net/dev` (Linux) — rx/tx bytes/sec, errori e drop NIC; `--iface=` per filtro |

Fuori perimetro: analisi grafici OEM, access plan, wait event, uso CPU/I/O da OEM.

## Libreria OS (`lib/os_cmd.sh`)

Libreria bash cross-platform per i tool OS-level. Fornisce:

- **`os_detect HOST`** — rileva il sistema operativo via SSH (`uname -s`), restituisce `aix`/`linux`/`unknown`. Timeout 5s.
- **`os_check_cmd HOST CMD`** — verifica disponibilità di un comando sul target (`which CMD`), restituisce `available`/`missing`.
- **`os_sample HOST SAMPLES INTERVAL CMD_AIX CMD_LINUX`** — campiona un comando N volte con INTERVAL secondi di pausa, raccogliendo stdout con separatore `\001` (SOH) tra campioni.
  - Se `SAMPLES × INTERVAL > OS_MAX_SAMPLE_DURATION` (default 30s) riduce SAMPLES automaticamente.
  - Se SSH fallisce: restituisce exit 1 + diagnostica su stderr.

**Principio cross-platform**: i comandi (`vmstat`, `free`, `svmon`, `df`, `iostat`) girano sul target remoto via SSH. Il parsing gira sull'host MCP (ppc64le RHEL) — awk POSIX per coerenza. I due rami AIX/Linux sono gestiti come branch espliciti nei tool, non come astrazione generica.

**Firma CLI dei tool OS**: `ENV HOSTNAME [--samples=N] [--interval=S]` — **nessun `INSTANCE_NAME`** (tool OS-level). La validazione è manuale (no `validate_args` che richiede 3 argomenti).

**Errore `command_not_available`**: restituito se un comando richiesto non è presente sul target (es. `svmon` non installato su AIX). Context: `{command, os}`. Vedi `contratto-json.md` per la tabella codici.

## Versioni Oracle target

- Ambiente **misto: 11g, 12c e 19c** (conferma team DBA, 2026-08-31). Le feature multitenant (`show pdbs`, `cdb_pdbs`, `v$rsrcpdbmetric`) non esistono su 11g.
- Regola: i tool che dipendono da feature non disponibili sulla versione del target devono restituire l'errore JSON esplicito `unsupported_version` (vedi `contratto-json.md`), non fallire in modo oscuro.
- L'output di ogni tool include la versione DB nell'envelope comune, così l'orchestratore può discriminare i casi.

## Architettura a due livelli (confermata)

Il sistema è strutturato in due livelli distinti con responsabilità separate:

### Livello 2 — Tool primitivi (bash/awk)
- Ogni script fa **una cosa sola**: apre un canale SSH verso un host remoto, esegue `sqlplus` o legge un file NFS, restituisce JSON strutturato su stdout.
- Nessuna logica decisionale, nessuna conoscenza degli altri tool.
- Testabili e invocabili in isolamento, direttamente da riga di comando.
- Sono la "lingua franca" del sistema: stabili e immutabili nel contratto.
- Il layer MCP Python li invoca come subprocessi e ne parsa lo stdout JSON.

### Livello 1 — Orchestrazione (Python nel server MCP FastAPI)
- Combina sequenze di tool primitivi, applica la logica del runbook (es. `if ORA-04030 → catena PGA`), produce output arricchiti e interpretati.
- Vive **interamente** nel layer Python del server MCP — nessuno strato bash intermedio di orchestrazione.
- Espone i tool di alto livello all'utente/Claude (es. `diagnose_instance`, `check_memory_pressure`, `runbook_ora04030`).

### Regola di separazione
- Un tool primitivo non sa nulla degli altri tool.
- Tutta la logica condizionale, il sequencing e l'aggregazione di risultati vive **solo** nel layer Python.
- `lib/oracle_conn.sh` è l'unico punto che tocca SSH e sqlplus — i tool primitivi la chiamano senza duplicarne la logica.

## Orchestratore (step successivo, non ancora avviato)

Il runbook originale ha struttura ad albero: discovery → FRA → scan alert log → se rilevato `ORA-04030` allora catena di verifiche PGA/memoria. Solo dopo aver stabilizzato i tool singoli va costruito l'orchestratore Python che replica questa logica ed emette un report consolidato.

## Convenzioni di ambiente

- **Mount NFS dei log (struttura reale confermata)**: path completo su `lxprworkerlana01`:
  ```
  /unipol/logs/database/oracle/<prod|noprod>/<hostname>/<volume>/<INSTANCE_NAME>/trace/alert_<INSTANCE_NAME>.log
  ```
  - `<hostname>` = server fisico che esporta il volume NFS (es. `axnporadb41`) — è il nome OS del server, non derivato dal nome CDB.
  - `<volume>` = nome del volume/filesystem (es. `np41cdb0`, `np41cdb1`) — in **minuscolo**, corrisponde approssimativamente al nome CDB ma **non** è necessariamente uguale. Un volume può contenere più istanze CDB (es. `np41cdb0` contiene sia `NP41CDB0` che `NP41CDB1`).
  - `<INSTANCE_NAME>` = nome CDB in **maiuscolo** (es. `NP41CDB0`).
  - Esempio reale: `/unipol/logs/database/oracle/noprod/axnporadb41/np41cdb0/NP41CDB0/trace/alert_NP41CDB0.log`
  - Anomalia spiegata (2026-09-01): `NP41CDB1` appare sia sotto `np41cdb0` che sotto `np41cdb1` — il volume `np41cdb0` era l'home originale di `NP41CDB1` prima della migrazione su `np41cdb1`. Il file in `np41cdb0` è fermo al 2025-03-19; quello in `np41cdb1` è aggiornato. Strategia: prendere il file con **data di modifica più recente** (`ls -t ... | head -1`).
  - CDB di nodi logici diversi appaiono sotto lo stesso hostname NFS fisico (es. `NP43CDB0` sotto `axnporadb41`) — **HOSTNAME nel mount è il server fisico esportatore**, non il nodo logico del CDB.
  - `<technology>` è `oracle` oggi; il layout è pensato per ospitare in futuro anche altri RDBMS (`db2`, `postgres`).
- **Ricerca del path alert log (strategia definitiva)**: glob a profondità fissa, **non** `find` ricorsivo:
  ```bash
  ls -t /unipol/logs/database/oracle/<prod|noprod>/<hostname>/*/<INSTANCE_NAME>/trace/alert_<INSTANCE_NAME>.log 2>/dev/null | head -1
  ```
  `find` ricorsivo è proibito su questi path: su host RAC le sottodirectory `cdmp_*` del trace possono avere handle NFS problematici che causano `getdents()` indefinitamente bloccato. Il glob a profondità fissa sfrutta la struttura nota del path ed è istantaneo. La funzione `find_alert_log()` in `lib/oracle_conn.sh` implementa questa logica — usarla sempre, non reinventarla nei tool.
- **Mapping ENVIRONMENT → prod|noprod (confermato)**: `PROD` → `prod`; tutti gli altri (`TEST`, `EURO`, `CERT`, `INTE`, `COLL`) → `noprod`.
- Accesso remoto via SSH: utente `oracle`, chiave in `/product/lana-bot/neural-oracle-analyzer/ssh_keys/oracle/.ssh/id_rsa` su `lxprworkerlana01`. Directory di lavoro sul server: `/product/lana-bot/neural-oracle-analyzer/`.
