# Progetto: Tool Diagnostici Oracle via MCP

## Obiettivo

Trasformare il runbook diagnostico manuale del team DBA (verifiche su istanza, PDB, FRA, alert log, sessioni, PGA/SGA) in una libreria di tool bash/awk indipendenti, invocabili singolarmente, con output JSON strutturato. Questi tool costituiscono il primo step: la loro interfaccia deve essere pensata fin da subito per essere esposta successivamente come server MCP su una macchina interna.

Requisito trasversale: i tool devono essere agnostici rispetto alla macchina target, applicabili a tutte le istanze Oracle interne tramite parametrizzazione su `ENVIRONMENT` / `HOSTNAME` / `DB_NAME`.

---

## Convenzioni di ambiente

### Path standard dei log (da validare)

```
/unipol/logs/farmlog/oracle/${ENVIRONMENT}/${HOSTNAME}/${DB_NAME}/<logs>
```

Punti da chiarire prima dell'implementazione dei tool di log analysis:

- Modalità di popolamento: mount NFS centralizzato (letto in locale dalla macchina MCP) oppure log locali per-host (richiede SSH anche per la lettura)?
- Corrispondenza tra `<logs>` e la struttura ADR reale. La `diagnostic_dest` restituita da Oracle (`show parameters diag`) segue lo schema:
  ```
  <diagnostic_dest>/diag/rdbms/<db_name_minuscolo>/<INSTANCE_NAME_MAIUSCOLO>/trace/alert_<INSTANCE_NAME_MAIUSCOLO>.log
  ```
  Da verificare se il mount standard replica fedelmente questo schema o introduce un livello di astrazione diverso.
- Normalizzazione rigida dei valori di `ENVIRONMENT`: EURO / TEST / CERT / INTE / COLL / PROD (enum fisso, case-sensitive, da validare in input in tutti i tool).

### Accesso remoto

- Scambio di chiavi SSH con utente privilegiato `oracle` verso i server destinazione.
- Proposta di hardening: `authorized_keys` con `command=` forzato sul server di destinazione, per limitare la chiave proveniente dalla macchina MCP a comandi specifici invece di una shell libera.
- Valutare SSH ControlMaster/multiplexing per ridurre l'overhead di connessione, data la frequenza di invocazione attesa in un contesto MCP.
- Valutare restrizione per IP sorgente, se la rete lo consente.

### Da chiarire con il team DBA

1. Modalità di costruzione della stringa di connessione: alias TNS centralizzati vs Easy Connect costruito da `HOSTNAME` + porta + service name.
2. Versioni Oracle in uso (11g / 12c / 19c, o miste): alcune query (es. `v$rsrcpdbmetric`) richiedono un Resource Manager PDB plan attivo e potrebbero non essere disponibili su tutte le versioni.
3. Utente/livello di connessione richiesto per ciascuna query: CDB vs PDB, sempre SYSDBA o esistono casi con utente applicativo.

---

## Architettura dei tool

### Libreria condivisa (prerequisito)

`lib/oracle_conn.sh` — punto unico che centralizza:

- costruzione della stringa di connessione a partire da `ENVIRONMENT` / `HOSTNAME` / `DB_NAME`
- gestione del livello di connessione (`--level=cdb` oppure `--level=pdb`)
- funzione `run_sqlplus_query()`: lancia `sqlplus -s / as sysdba`, imposta `SET MARKUP CSV ON`, cattura l'output e lo converte in JSON tramite awk

Ogni tool richiama questa libreria e si occupa solo della query specifica e della formattazione dell'output. Questo isola in un solo punto eventuali cambi futuri nella modalità di autenticazione o connessione.

### Contratto comune dei tool

- Input: parametri named o posizionali `ENVIRONMENT`, `HOSTNAME`, `DB_NAME` (mai hardcoded).
- Output: JSON strutturato su stdout.
- Un tool = una responsabilità (niente script monolitici con flag multipli), coerente con il modello di dichiarazione tool di MCP (nome, descrizione, scopo singolo).

---

## Elenco dei tool

### Discovery

| Tool | Query/comando sorgente | Note |
|---|---|---|
| `identify_instance.sh` | `select * from v$instance;` | Verifica anche l'accesso SYSDBA |
| `list_pdbs.sh` | `show pdbs` | |
| `get_diag_home.sh` | `show parameters diag` | Usato per costruire dinamicamente il path dell'alert log |

### Spazio e FRA

| Tool | Query/comando sorgente | Note |
|---|---|---|
| `check_fra_usage.sh` | `v$recovery_file_dest`, `v$flash_recovery_area_usage`, `show parameters DB_RECOVERY_FILE_DEST_SIZE` | Accorpa le tre query in un unico output |

### Log analysis (locale, sul mount standard)

| Tool | Comportamento | Note |
|---|---|---|
| `scan_alert_log.sh` | Awk su pattern `ORA-\d+` nell'alert log | Raggruppa per codice errore e timestamp; parametro opzionale `--code=ORA-04030` per filtro mirato |
| `tail_alert_log.sh` | Equivalente strutturato del `tail -f` | Invocazione puntuale e bounded, non streaming continuo (incompatibile con un'invocazione MCP request/response) |

### Sessioni e limiti

| Tool | Query sorgente | Note |
|---|---|---|
| `check_resource_limits.sh` | `v$resource_limit` (sessions, processes) | |
| `sessions_by_user.sh` | `v$session` raggruppato per utente/stato | |
| `sessions_by_machine.sh` | `v$session` raggruppato per macchina/stato | |

### Memoria e PGA

| Tool | Query sorgente | Note |
|---|---|---|
| `pga_sga_by_pdb.sh` | `v$rsrcpdbmetric` + `cdb_pdbs` | Richiede Resource Manager PDB plan attivo |
| `pga_by_pdb_session.sh` | join `v$session` / `v$process` / `cdb_pdbs` | |
| `top_pga_sessions.sh` | `v$process` + `v$session` ordinato per PGA | |

### Fuori perimetro (step attuale)

- Analisi grafici OEM (query eseguite "sotto le coperte" dall'Enterprise Manager, non ancora ricostruite).
- Access plan delle query lente, wait event, uso CPU/I/O da OEM.

---

## Proposta: orchestratore a albero decisionale (step successivo)

Il runbook originale ha una struttura logica ad albero: discovery → controllo FRA → scan alert log → se `ORA-04030` allora catena di verifiche sulla memoria/PGA. Una volta stabilizzati i tool singoli, ha senso costruire un orchestratore che replichi questo ragionamento:

1. Esegue `scan_alert_log.sh`.
2. Se rileva un codice `ORA-04030` (o altri codici mappati), invoca automaticamente la catena di tool sulla PGA (`pga_sga_by_pdb.sh`, `pga_by_pdb_session.sh`, `top_pga_sessions.sh`).
3. Produce un report consolidato.

Questo trasformerebbe il runbook manuale in una diagnosi automatica di primo livello, lasciando all'operatore umano solo l'interpretazione finale e l'eventuale passaggio a OEM per i grafici.

---

## Roadmap

1. Validare con il team DBA i punti aperti (stringa di connessione, versioni Oracle, corrispondenza path log/ADR).
2. Implementare `lib/oracle_conn.sh`.
3. Implementare i tool di discovery (`identify_instance.sh`, `list_pdbs.sh`, `get_diag_home.sh`) come base per validare il contratto comune (input/output JSON).
4. Implementare i tool di spazio/FRA e sessioni.
5. Implementare i tool di log analysis (awk su alert log).
6. Implementare i tool di memoria/PGA.
7. Progettare l'orchestratore a albero decisionale.
8. Wrappare i tool come server MCP, con mapping 1:1 tra script e tool MCP dichiarato (nome, descrizione, parametri).
