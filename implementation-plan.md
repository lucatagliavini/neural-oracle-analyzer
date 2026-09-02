# Implementation Plan — Neural Oracle Analyzer

## Overview

Trasformare il runbook diagnostico manuale del team DBA in una libreria di tool bash/awk (tool primitivi) orchestrati da un server MCP Python/FastAPI, esposto via HTTP su `lxprworkerlana01` (RHEL 9.8, `ppc64le`).

**Architettura target:**
- **Livello 2 — Tool primitivi** (`tools/`, `lib/`): script bash/awk, uno per responsabilità, output JSON su stdout, testabili in isolamento via SSH.
- **Livello 1 — Orchestrazione** (`mcp/`): server FastAPI Python che invoca i primitivi come subprocessi, aggrega i risultati e li espone come tool MCP HTTP.

**Riferimenti:** `docs/specs/architettura.md`, `docs/specs/contratto-json.md`, `docs/specs/infrastruttura.md`

**Server di lavoro:** `lxprworkerlana01` — directory `/product/lana-bot/neural-oracle-analyzer/`
**SSH verso DB:** `ssh -i /product/lana-bot/neural-oracle-analyzer/ssh_keys/oracle/.ssh/id_rsa oracle@<hostname>`
**Server di test:** `axnporadb41` (9 CDB: NP41CDB0-2, NP42CDB0-1, NP43CDB0-1, NP44CDB0-1), `axnporadb51`

---

## Struttura directory target

```
/product/lana-bot/neural-oracle-analyzer/
├── lib/
│   └── oracle_conn.sh          # libreria condivisa: SSH + sqlplus + CSV→JSON
├── tools/                      # tool primitivi (Livello 2)
│   ├── list_instances_on_host.sh
│   ├── identify_instance.sh
│   ├── list_pdbs.sh
│   ├── get_diag_home.sh
│   ├── check_fra_usage.sh
│   ├── scan_alert_log.sh
│   ├── tail_alert_log.sh
│   ├── check_resource_limits.sh
│   ├── sessions_by_user.sh
│   ├── sessions_by_machine.sh
│   ├── pga_sga_by_pdb.sh
│   ├── pga_by_pdb_session.sh
│   └── top_pga_sessions.sh
├── mcp/                        # server MCP FastAPI (Livello 1)
│   ├── main.py
│   ├── tools/                  # tool orchestrati ad alto livello
│   └── requirements.txt
├── tests/                      # test di contratto e integrazione
│   ├── test_contract.sh        # verifica envelope JSON di ogni tool
│   └── fixtures/               # output JSON attesi per confronto
├── deploy.sh                   # deploy su lxprworkerlana01
└── ssh_keys/oracle/.ssh/id_rsa # chiave SSH per oracle@<host>
```

---

## Milestone 0 — Esplorazione ambiente e validazione assunzioni

**Obiettivo:** Prima di scrivere una riga di codice produttivo, validare sul campo le assunzioni architetturali. Questa milestone produce solo script esplorativi usa-e-getta e aggiornamenti alle specs.

**Risultati attesi al completamento:**
- Contenuto di un file `.env` CDB noto e struttura confermata
- Meccanismo di connessione sqlplus validato end-to-end
- Struttura NFS alert log confermata (anomalia `np41cdb0/NP41CDB1` spiegata)
- `INSTANCE_NAME` vs `ORACLE_SID` chiariti (coincidono sempre?)
- Pattern `ls ~/NP*.env` validato anche su `axnporadb51`

**Todo:**
- [ ] Leggere il contenuto di un env file CDB (es. `NP41CDB0.env`) via SSH per capire esattamente cosa setta (`ORACLE_HOME`, `ORACLE_SID`, `ORACLE_BASE`, altro?)
- [ ] Eseguire manualmente `source NP41CDB0.env && sqlplus -s / as sysdba <<< "select instance_name, version from v\$instance;"` via SSH e verificare l'output CSV
- [ ] Verificare se `ORACLE_SID` = `INSTANCE_NAME` (es. `NP41CDB0`) — se coincidono, il contratto è semplice
- [ ] Chiarire l'anomalia NFS: perché `np41cdb0/NP41CDB1/` esiste? (via `get_diag_home` manuale o chiedendo al team DBA)
- [ ] Verificare struttura e chiave SSH su `axnporadb51` con stesso pattern
- [ ] Aggiornare `docs/specs/architettura.md` e `docs/specs/contratto-json.md` con i risultati
- [ ] Aggiornare la sessione in `docs/sessions/`

**Contesto:** `docs/specs/architettura.md` sezioni "Libreria condivisa" e "Convenzioni di ambiente"

**Status:** [x] done

---

## Milestone 1 — Scaffolding e libreria condivisa (`lib/oracle_conn.sh`)

**Obiettivo:** Creare la struttura di directory del progetto su `lxprworkerlana01` e implementare `lib/oracle_conn.sh` — il pezzo più critico dell'architettura. Tutto il resto dipende da questo.

**Risultati attesi al completamento:**
- Struttura directory creata su `lxprworkerlana01`
- `lib/oracle_conn.sh` implementata con `run_sqlplus_query()` funzionante
- Validazione manuale: output JSON corretto per una query semplice su `NP41CDB0`
- `deploy.sh` iniziale (copia file sul server)

**Todo:**
- [ ] Inizializzare la struttura directory (`lib/`, `tools/`, `tests/`, `mcp/`)
- [ ] Implementare `lib/oracle_conn.sh`:
  - `validate_environment()`: valida enum ENVIRONMENT, exit 2 se invalido
  - `get_prod_noprod()`: mappa ENVIRONMENT → `prod|noprod`
  - `find_alert_log()`: `find` sul mount NFS dato HOSTNAME + INSTANCE_NAME
  - `run_sqlplus_query()`: SSH + source env + sqlplus -s + SET MARKUP CSV ON + awk CSV→JSON
  - Gestione errori: `connection_failed`, `missing_env_file`, `query_failed` come JSON su stdout + exit 1
- [ ] Implementare `build_envelope()`: costruisce l'envelope JSON comune (tool, generated_at, environment, hostname, instance_name, oracle_version, status, data, error)
- [ ] Scrivere `tests/test_contract.sh`: script che verifica che ogni tool rispetti il contratto (valid JSON, chiavi obbligatorie presenti, exit code corretto)
- [ ] Creare `deploy.sh` v1: rsync dei file su `lxprworkerlana01:/product/lana-bot/neural-oracle-analyzer/`
- [ ] **Validazione su server reale**: eseguire `run_sqlplus_query()` su `NP41CDB0` con query `select instance_name from v$instance` e verificare output JSON

**Contesto:** `docs/specs/architettura.md` sezione "Libreria condivisa", `docs/specs/contratto-json.md`

**Status:** [x] done

**Note tecniche acquisite (per le milestone successive):**
- Shell remota = ksh: usare `.` non `source` per gli env file
- Quoting: query costruita localmente con `printf`, inviata via pipe a `ssh` — evita espansione su shell remota
- `run_sqlplus_query` emette: riga 1 = versione, righe 2+ = array JSON. Usare `_extract_version` / `_extract_data`
- Marker `PROMPT ORAMARKER` + riga blank obbligatoria per separare i due blocchi output
- `WHENEVER SQLERROR EXIT 1` deve precedere le query, non il marker

---

## Milestone 2 — Tool di discovery (Livello 2)

**Obiettivo:** Implementare i 4 tool di discovery. Sono i più semplici e servono come fondamenta per tutti gli altri — in particolare `get_diag_home.sh` è prerequisito dei tool di log.

**Risultati attesi al completamento:**
- 4 tool funzionanti e validati su `axnporadb41` in ambiente noprod
- Output JSON conforme al contratto per tutti i casi (ok, errore, 11g)
- `test_contract.sh` aggiornato con fixture per questi tool

**Todo:**
- [ ] `list_instances_on_host.sh ENVIRONMENT HOSTNAME`: SSH + `ls ~/NP*.env` → JSON array di `{instance_name, env_path}`. Nessuna connessione sqlplus.
- [ ] `identify_instance.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`: `select instance_name, host_name, version, status, database_status, instance_role, startup_time from v$instance`
- [ ] `list_pdbs.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`: `show pdbs` — degrada con `unsupported_version` su Oracle 11g
- [ ] `get_diag_home.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`: `show parameters diagnostic_dest` — il valore restituito serve a costruire il path NFS dell'alert log
- [ ] Aggiungere fixture JSON attesi in `tests/fixtures/`
- [ ] **Validazione su server reale** per tutti e 4 i tool: eseguire su almeno 2 CDB diversi (es. `NP41CDB0` e `NP41CDB1`) e confrontare output con fixture
- [ ] Verificare degradazione 11g se disponibile un target 11g in noprod

**Contesto:** `docs/specs/architettura.md` sezione "Elenco tool pianificati", `docs/specs/contratto-json.md` esempi

**Status:** [x] done

**Note tecniche acquisite:**
- `set -e` incompatibile con `run_tool`: usare `set -uo pipefail` + `exit $?` esplicito in ogni tool
- `show pdbs` è un comando sqlplus, non SQL — non supporta `WHENEVER SQLERROR EXIT 1` ma funziona con `SET MARKUP CSV ON`; gestire come `run_sqlplus_query` manuale con blocco SQL custom
- Colonne con spazio (es. `OPEN MODE`) normalizzate a `open_mode` nel parser `_csv_to_json_array` via `gsub(/ /, "_", key)`
- Tool che richiedono logica aggiuntiva (versione check per `unsupported_version`) non usano `run_tool` ma chiamano `run_sqlplus_query` direttamente
- `list_instances_on_host`: non usa sqlplus, solo SSH + `ls ~/NP*.env`; `oracle_version` e `instance_name` nell'envelope sono vuoti (nessuna connessione DB)

---

## Milestone 3 — Tool di log analysis (Livello 2)

**Obiettivo:** Implementare i 2 tool che leggono l'alert log dal mount NFS. Dipendono da `get_diag_home.sh` per il path e dalla struttura NFS confermata in M0.

**Risultati attesi al completamento:**
- `scan_alert_log.sh` e `tail_alert_log.sh` funzionanti sul mount NFS reale
- Gestione corretta del caso `log_not_found`
- Output `scan_alert_log.sh` con raggruppamento per codice ORA-, count, first/last seen, samples

**Todo:**
- [ ] `scan_alert_log.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--code=ORA-XXXXX] [--since=YYYY-MM-DD]`:
  - Trovare il path alert log via `find_alert_log()` dalla libreria
  - awk: scansiona il file, estrae pattern `ORA-[0-9]+`, raggruppa per codice, conta occorrenze, tiene first/last seen e 2 righe di sample
  - JSON: array di `{code, count, first_seen, last_seen, samples[]}`
  - Se `--code=` specificato: filtra solo quel codice
  - Se path non trovato: `log_not_found` error JSON
- [ ] `tail_alert_log.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--lines=N]`:
  - Default `--lines=2000` (come da runbook DBA)
  - Restituisce le ultime N righe come array di stringhe in `data`
  - **Non** streaming continuo — invocazione puntuale bounded
- [ ] **Validazione su server reale**: eseguire entrambi i tool su `NP41CDB0` e verificare output. Cercare ORA- reali nel log.
- [ ] Verificare comportamento con mount NFS assente (simulare con HOSTNAME inesistente)

**Contesto:** `docs/specs/architettura.md` sezioni "Tool di log analysis" e "Convenzioni di ambiente"

**Status:** [x] done

**Note tecniche acquisite:**
- `json_esc()` in awk obbligatoria per l'alert log (tab e caratteri di controllo)
- Codici ORA- nel log senza zero-padding (`ORA-609`) → normalizzare a 5 cifre (`normalize_code()`)
- `ORA-0` = success code Oracle (`Result = ORA-0`) — regex deve essere `ORA-[0-9][0-9]+`
- PDB context nel log: `PDBNAME(con_id):ORA-XXXXX`; riga senza prefisso = CDB root (`pdb_name: null`)
- Separatore inter-awk: `\001` (SOH) non `\t` — log può contenere tab
- `match(line, /pattern/, arr)` a 3 argomenti = gawk-only (ok su lxprworkerlana01, non su AIX)
- `find_alert_log()` usa `xargs ls -t | head -1` per duplicati da migrazione CDB

---

## Milestone 4 — Tool di sessioni e FRA (Livello 2)

**Obiettivo:** Implementare i 4 tool di sessioni e il tool FRA. Tutti leggono da viste standard Oracle accessibili su qualsiasi versione (con attenzione alle viste multitenant per FRA su 11g).

**Risultati attesi al completamento:**
- 4 tool sessioni + 1 tool FRA funzionanti e validati
- `check_fra_usage.sh` gestisce correttamente le 3 query in un unico blocco sqlplus

**Todo:**
- [ ] `check_resource_limits.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - Query: `SELECT resource_name, current_utilization, max_utilization, limit_value FROM v$resource_limit WHERE resource_name IN ('sessions','processes')`
- [ ] `sessions_by_user.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - Query: `SELECT username, status, count(*) AS session_count FROM v$session WHERE username IS NOT NULL GROUP BY username, status ORDER BY session_count DESC`
- [ ] `sessions_by_machine.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - Query: `SELECT machine, status, count(*) AS session_count FROM v$session GROUP BY machine, status ORDER BY session_count DESC`
- [ ] `check_fra_usage.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - 3 query in blocco unico sqlplus: `V$RECOVERY_FILE_DEST`, `V$FLASH_RECOVERY_AREA_USAGE`, `show parameters DB_RECOVERY_FILE_DEST_SIZE`
  - `data` contiene 3 oggetti distinti con chiave `source` per distinguerli (`fra_dest`, `fra_usage`, `fra_size`)
  - Verificare compatibilità con versioni miste 11g/12c/19c
- [ ] **Validazione su server reale** per tutti i tool

**Contesto:** `docs/specs/contratto-json.md`, runbook DBA originale

**Status:** [x] done

**Note tecniche acquisite:**
- `run_sqlplus_raw` + 3 marker (`MARKER2/3/4`) per query multiple in un'unica connessione SSH
- La funzione `_section_to_json` taglia il raw output tra due marker e inietta `"source":"<tag>"` come primo campo di ogni oggetto JSON via awk
- Per l'ultima sezione (nessun marker di fine) usare `end!=""` nella condizione awk per non uscire prematuramente su righe vuote
- FRA non configurata (`db_recovery_file_dest_size=0`): `v$recovery_file_dest` e `v$flash_recovery_area_usage` restituiscono zero righe — status ok, `data` contiene solo la sezione `fra_size`
- `space_limit/used/reclaimable` in bytes, notazione scientifica Oracle (es. `1.0737E+11`) — emessa così com'è nel JSON; la conversione in GB è responsabilità del layer Python

---

## Milestone 5 — Tool di memoria e PGA (Livello 2)

**Obiettivo:** Implementare i 3 tool PGA/SGA. Due di questi usano viste multitenant (`cdb_pdbs`, `v$rsrcpdbmetric`) non disponibili su 11g — devono degradare con `unsupported_version`.

**Risultati attesi al completamento:**
- 3 tool PGA funzionanti su 12c/19c, con degradazione corretta su 11g
- Validazione con target reale (verificare che `v$rsrcpdbmetric` richieda Resource Manager PDB plan attivo)

**Todo:**
- [ ] `top_pga_sessions.sh ENVIRONMENT HOSTNAME INSTANCE_NAME [--limit=N]`:
  - Query: join `v$process`/`v$session` ordinato per `pga_alloc_mem DESC`
  - Funziona su tutte le versioni (nessuna vista multitenant)
  - Default `--limit=20`
- [ ] `pga_sga_by_pdb.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - Query: join `v$rsrcpdbmetric`/`cdb_pdbs` — richiede 12c+ e Resource Manager PDB plan attivo
  - Degrada con `unsupported_version` su 11g
  - Documentare nel JSON se Resource Manager non è attivo (risultato vuoto vs errore)
- [ ] `pga_by_pdb_session.sh ENVIRONMENT HOSTNAME INSTANCE_NAME`:
  - Query: join `v$session`/`v$process`/`cdb_pdbs` — richiede 12c+
  - Degrada con `unsupported_version` su 11g
- [ ] **Validazione su server reale**: verificare tutti e 3 su target 12c/19c. Se disponibile target 11g, verificare degradazione.

**Contesto:** `docs/specs/architettura.md` sezione "Versioni Oracle target"

**Status:** [x] done

**Note tecniche acquisite:**
- `ROWNUM <= N` con subquery richiesto per top-N corretto (plain ROWNUM+ORDER BY non funziona)
- `v$rsrcpdbmetric` colonne effettive: `pga_bytes`, `sga_bytes`, `buffer_cache_bytes`, `shared_pool_bytes`, `plan_name`
- `cdb_pdbs` colonna: `pdb_name` (non `name`)
- `pga_sga_by_pdb` restituisce `data: []` se Resource Manager non attivo — è un esito valido (non errore)

---

## Milestone 6 — Test di contratto e regressione

**Obiettivo:** Formalizzare la suite di test che verifica il contratto JSON per tutti i 13 tool. Questa milestone trasforma i test manuali fatti nelle milestone precedenti in test automatizzati e ripetibili.

**Risultati attesi al completamento:**
- `tests/test_contract.sh` eseguibile che testa tutti i tool
- Test per ogni caso: ok, errore applicativo (exit 1), uso errato (exit 2)
- Test di regressione eseguibili su `lxprworkerlana01` via `deploy.sh`

**Todo:**
- [x] Formalizzare `tests/test_contract.sh`:
  - Per ogni tool: verifica che stdout sia JSON valido (`jq .`)
  - Verifica presenza chiavi obbligatorie nell'envelope
  - Verifica exit code corretto per ogni scenario
  - Verifica `status: "error"` + `data: []` in caso di errore
- [x] Aggiungere test per input invalidi: ENVIRONMENT non nell'enum, HOSTNAME vuoto, INSTANCE_NAME inesistente
- [x] Aggiungere fixture in `tests/fixtures/` con header `#ENV=` `#HOST=` `#INST=` per i 13 tool
- [x] Modalità `--quick` per test senza connessione (38 test locali, 0 falliti)
- [x] Test specifici per tool: `log_not_found` (log tools), `--limit` invalido (top_pga_sessions)
- [x] Documentare come eseguire i test in `README.md`

**Contesto:** `docs/specs/contratto-json.md` (exit code, envelope, error codes)

**Status:** [x] done

**Note tecniche acquisite:**
- `set -euo pipefail` in `test_contract.sh` → rimosso `set -e` (run_test chiama tool che restituiscono exit 1/2)
- Fixture: file con solo commenti `#ENV=`/`#HOST=`/`#INST=` + `#ARGS=` opzionale per argomenti extra
- `list_instances_on_host` ha solo 2 argomenti posizionali — `host_only=1` nel runner
- `--quick` per CI locale senza dipendenze da Oracle; suite completa su `lxprworkerlana01`

---

## Milestone 7 — Server MCP FastAPI (Livello 1)

**Obiettivo:** Implementare il server MCP HTTP con FastAPI su `lxprworkerlana01`. In questa milestone: infrastruttura del server + tool MCP 1:1 con i primitivi (wrap diretto, senza orchestrazione).

**Risultati attesi al completamento:**
- Server FastAPI avviabile su `lxprworkerlana01` (ppc64le — verificare disponibilità pacchetti Python prima)
- Autenticazione API key funzionante
- Tutti i 13 tool primitivi esposti come tool MCP
- Raggiungibile da Claude Code via HTTP

**Todo:**
- [ ] Verificare disponibilità Python3 e pip su `lxprworkerlana01` (ppc64le); creare virtualenv in `/product/lana-bot/neural-oracle-analyzer/mcp/venv/`
- [ ] Scaffolding `mcp/`: `main.py`, `requirements.txt`, `tools/`, `config.py`
- [ ] Implementare autenticazione API key (header `X-API-Key`); key da variabile d'ambiente, mai hardcoded
- [ ] Implementare runner generico: `run_primitive_tool(script_path, args) → dict` — invoca subprocess, parsa JSON stdout, propaga errori
- [ ] Esporre tutti i 13 tool primitivi come endpoint MCP con descrizioni accurate
- [ ] Aggiornare `deploy.sh`: installa dipendenze Python, copia file, (ri)avvia il server
- [ ] **Validazione**: configurare il server MCP in Claude Code e invocare almeno `identify_instance` e `scan_alert_log` end-to-end

**Contesto:** `docs/specs/architettura.md` sezioni "Esposizione del server MCP" e "Architettura a due livelli"

**Status:** [ ] pending

---

## Milestone 8 — Tool orchestrati (Livello 1) e runbook automatico

**Obiettivo:** Aggiungere al server MCP i tool di alto livello che implementano la logica del runbook: sequenze di tool primitivi con logica decisionale in Python.

**Risultati attesi al completamento:**
- Tool `diagnose_instance`: discovery completa di un'istanza (identify + list_pdbs + check_fra + resource_limits)
- Tool `runbook_ora04030`: scan alert log → se ORA-04030 → catena PGA → report consolidato
- Tool `find_instance`: dato solo INSTANCE_NAME, trova su quale host fisico risiede

**Todo:**
- [ ] `find_instance(instance_name, environment)`: cerca il CDB su tutti gli host noti interrogando `list_instances_on_host` in parallelo — utile quando non si conosce l'HOSTNAME fisico
- [ ] `diagnose_instance(environment, hostname, instance_name)`: chiama in sequenza `identify_instance` → `list_pdbs` → `check_fra_usage` → `check_resource_limits` → aggrega in report
- [ ] `runbook_ora04030(environment, hostname, instance_name)`: `scan_alert_log` → se `ORA-04030` trovato → `top_pga_sessions` + `pga_sga_by_pdb` + `pga_by_pdb_session` → report consolidato con raccomandazioni
- [ ] Aggiornare `deploy.sh` e documentazione
- [ ] **Validazione end-to-end** con Claude Code

**Contesto:** `docs/specs/architettura.md` sezione "Orchestratore"

**Status:** [ ] pending

---

## Milestone 9 — Git e hardening

**Obiettivo:** Attivare il repository git interno e applicare le misure di hardening previste.

**Risultati attesi al completamento:**
- Repository git inizializzato con `.gitignore` corretto (no credenziali, no chiavi)
- `deploy.sh` aggiornato per lavorare con git
- Documentazione finale aggiornata

**Todo:**
- [ ] Inizializzare repository git interno (coordinare con utente per URL e accessi)
- [ ] Creare `.gitignore`: escludere `ssh_keys/`, file `*.env`, file di configurazione con API key, `mcp/venv/`
- [ ] Primo commit con tutto il codice stabile
- [ ] Aggiornare `deploy.sh` per usare git pull invece di rsync
- [ ] Valutare `command=` forzato in `authorized_keys` sul server destinazione (hardening SSH)
- [ ] Aggiornare `docs/specs/` e sessione finale

**Contesto:** `docs/specs/infrastruttura.md` sezione "Git"

**Status:** [ ] pending

---

## Note trasversali (valide per tutte le milestone)

- **Ogni milestone finisce con validazione sul server reale** (`lxprworkerlana01` → `axnporadb41`/`axnporadb51`) — non solo test locali.
- **Aggiornare `docs/sessions/`** a fine di ogni sessione di lavoro con riassunto, decisioni, stato, prossimi passi.
- **Aggiornare `docs/specs/`** ogni volta che emerge un principio nuovo o cambia un'assunzione — non solo applicarlo in sessione.
- **Ambiente di test**: sempre noprod prima di toccare prod. La logica è solo in lettura, il rischio è basso ma il principio va rispettato.
- **Nessun comando distruttivo**: non eseguire mai comandi che modificano, cancellano o alterano dati/configurazioni — né in noprod né in prod. In caso di dubbio, chiedere conferma prima di procedere.
- **Un tool = una responsabilità**: non aggiungere flag o logica condizionale ai tool primitivi — ogni nuova esigenza è un nuovo tool o appartiene al layer Python.
