# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Session recovery (leggere PRIMA di tutto il resto)

**Modalità da usare per riprendere una sessione**: `agent` (modalità corrente, con accesso a tutti i tool di scrittura e comandi).

**Procedura di boot obbligatoria all'inizio di ogni nuova sessione:**
1. Leggere [`docs/sessions/`](docs/sessions/) — identificare il file più recente e leggerlo per intero.
2. Leggere questo file (`AGENTS.md`) — stato del progetto, gotcha tecnici, contratto JSON.
3. Solo se necessario per la milestone da avviare: leggere il file specs rilevante in [`docs/specs/`](docs/specs/).
4. Non scrivere codice prima di aver completato i passi 1–2.

**Ultimo file di sessione**: [`docs/sessions/2026-09-05.md`](docs/sessions/2026-09-05.md)
— Stato: M0–M8 ✅ completate | M9 (git + hardening) ⬜ prossima milestone
— 21 tool MCP attivi su `lxprworkerlana01:8420` | fix RAC env loader + fix find_alert_log NFS

## Project state

M0–M8 completate. 17 tool primitivi bash + 4 Python orchestrati (`list_all_instances_status`, `diagnose_instance`, `check_memory_pressure`, `runbook_ora04030`) attivi su `lxprworkerlana01:8420`. 430/430 test suite passati (suite copre i 13 tool originali; estensione ai nuovi tool prevista in M9).
`docs/specs/` è la fonte autoritativa — leggerla prima di scrivere codice.

## Goal

Convertire il runbook diagnostico manuale DBA in tool bash/awk con output JSON strutturato, esposti come server MCP (FastAPI HTTP) su `lxprworkerlana01` (RHEL 9.8, `ppc64le`).

## Documentation workflow

- **`docs/specs/`** — principi architetturali viventi; leggere prima di implementare, aggiornare quando emerge un principio nuovo.
  - [`docs/specs/architettura.md`](docs/specs/architettura.md) — piattaforme, vincoli, lista tool, design libreria
  - [`docs/specs/contratto-json.md`](docs/specs/contratto-json.md) — **contratto JSON completo (leggere prima di ogni script)**
  - [`docs/specs/infrastruttura.md`](docs/specs/infrastruttura.md) — deploy target, piano git
- **`docs/sessions/`** — log cronologico sessioni (`YYYY-MM-DD[-N].md`). **Scrivere sempre il riassunto a fine sessione automaticamente.** Non riscrivere la storia. Leggere l'ultimo file all'inizio di ogni nuova sessione.

## Critical architectural decisions

- **Connessione**: sempre CDB, sempre SYSDBA. Stringa da env file sourciato per `ENVIRONMENT`/`HOSTNAME`/istanza — mai costruita dal codice.
- **Log tools**: leggono alert log da mount NFS su `lxprworkerlana01` — `/unipol/logs/database/oracle/<prod|noprod>/<hostname>/`. Se mount assente → `log_not_found`, **nessun fallback SSH**.
- **`find_alert_log()`** gestisce i duplicati da migrazione (file più recente per `ls -t`).
- **Versioni Oracle**: miste 11g/12c/19c. Tool multitenant → `unsupported_version` su 11g, non fallire silenziosamente.

## JSON output contract (ogni script deve rispettare)

- stdout: un solo oggetto JSON valido. Chiavi: `tool`, `generated_at` (ISO 8601 con tz), `environment`, `hostname`, `instance_name`, `oracle_version`, `status` (`ok`|`error`), `data` (sempre array), `error` (null o oggetto).
- stderr: tutta la diagnostica non-JSON — mai su stdout.
- Exit code: `0` = successo, `1` = errore applicativo (JSON presente), `2` = uso errato CLI.
- `ENVIRONMENT` enum (case-sensitive, validato **primo**): `EURO`, `TEST`, `CERT`, `INTE`, `COLL`, `PROD`.
- Codici errore standard: `invalid_environment`, `invalid_argument`, `missing_env_file`, `connection_failed`, `query_failed`, `unsupported_version`, `log_not_found`.

## Shared library (`lib/oracle_conn.sh`)

Punto unico per connessione/parsing. I tool forniscono solo la query e formattano `data`.
- `run_tool TOOL ENV HOST INST QUERY` — entry point standard per tool semplici (valida tutto, chiama sqlplus, costruisce envelope).
- `run_sqlplus_query HOST INST QUERY` — riga 1 output = versione, righe 2+ = array JSON. Usare per tool con logica aggiuntiva.
- `run_sqlplus_raw HOST INST SQL_BLOCK` — trasporto SSH puro; il chiamante controlla l'intero blocco SQL.
- `validate_args TOOL ENV HOST INST` — valida argomenti, emette JSON di errore su stdout e restituisce 2 se invalido.
- `classify_error STDERR_TEXT` — analizza stderr prefissato → `connection_failed`|`missing_env_file`|`query_failed`.
- `find_alert_log HOST INST ENV` — path NFS alert log; stringa vuota se non trovato.
- **I tool NON devono usare `set -e`**: `run_tool` restituisce exit code significativo che `set -e` intercetterebbe come fatale. Usare `set -uo pipefail` + `exit $?` esplicito.

## Test

```bash
# Locale (no connessione Oracle) — 38 test, validazione input invalidi per tutti i 13 tool
bash tests/test_contract.sh --quick

# Server (richiede Oracle + NFS) — 430 test, suite completa
bash tests/test_contract.sh

# Tool specifico
bash tests/test_contract.sh identify_instance
```

Fixture in `tests/fixtures/<tool>.ok.json` con header `#ENV=` `#HOST=` `#INST=` (senza `#INST=` per `list_instances_on_host`).

## Critical technical gotchas

1. **Shell remota = ksh**: usare `.` non `source` per env file Oracle. `source` → errore 127 su ksh.
2. **Quoting SSH**: query costruita localmente con `printf`, inviata via pipe a SSH — evita espansione su shell remota.
3. **`PROMPT ORAMARKER` + riga blank obbligatoria**: senza la riga blank, sqlplus concatena PROMPT con il comando successivo.
4. **`WHENEVER SQLERROR EXIT 1`** deve precedere le query dati, non il marker ORAMARKER.
5. **`show pdbs`** è comando sqlplus, non SQL — non supporta `WHENEVER SQLERROR EXIT 1`; usare blocco custom (vedi `list_pdbs.sh`).
6. **Colonne Oracle con spazio** (es. `OPEN MODE`): normalizzate a `open_mode` in `_csv_to_json_array` via `gsub(/ /, "_", key)`.
7. **JSON escape in awk**: alert log può contenere tab `\t` e altri caratteri di controllo. Usare la funzione `json_esc()`.
8. **Codici ORA- senza zero-padding**: Oracle scrive `ORA-609` nel log, ma il dizionario usa `ORA-00609`. Normalizzare a 5 cifre (`normalize_code()` in `scan_alert_log.sh`).
9. **`ORA-0` è un success code Oracle**, non un errore — regex di scansione deve essere `ORA-[0-9][0-9]+` (almeno 2 cifre).
10. **PDB nel log alert**: righe con contesto PDB hanno prefisso `PDBNAME(con_id):` (es. `VITAWFST(13):ORA-00060`). Righe senza prefisso = CDB root → `pdb_name: null`. Aggregazione per coppia `(code, pdb_name)`.
11. **`ORACLE_HOSTNAME`** nell'env file = FQDN nodo logico ≠ host fisico. Per SSH e NFS usare sempre l'hostname fisico.
12. **Cluster HA**: un host fisico (`axnporadb41`) ospita env file di più nodi logici (`NP41*`, `NP42*`, `NP43*`, `NP44*`).
13. **`ORACLE_VERSION` in subshell**: `run_sqlplus_query` emette versione come riga 1 stdout; dati righe 2+.
14. **`v$rsrcpdbmetric` colonne effettive**: `pga_bytes`, `sga_bytes`, `buffer_cache_bytes`, `shared_pool_bytes`, `plan_name` (non `pga_bytes_used`).
15. **`cdb_pdbs` colonna PDB name**: `pdb_name` (non `name`).
16. **`ROWNUM <= N`**: deve avvolgere una subquery con `ORDER BY` — `WHERE ROWNUM <= N ORDER BY col` senza subquery non dà top-N corretto.
17. **`end!=""` in awk**: la condizione `$0==end` con `end=""` matcha le righe vuote — usare `end!="" && $0==end` per l'ultima sezione in tool multi-query.
18. **Separatore inter-awk**: usare `\001` (SOH) non `\t` — l'alert log può contenere tab.
19. **`_has_key` nei test**: `jq -e ".$key"` restituisce non-zero per valori `null` — usare `jq -e "has(\"$key\")"` per verificare presenza chiave indipendentemente dal valore.
20. **ksh: `. file` su file inesistente termina la shell** — anche con `2>/dev/null`, il dot-source su file mancante fa uscire la shell ksh immediatamente (exit 1), il `||` non scatta. Usare `[ -f file ] && . file || fallback` per gestire l'assenza in modo sicuro. Bash non ha questo problema.
21. **`find` ricorsivo su NFS può bloccarsi** — le directory `cdmp_*` nel trace Oracle RAC possono avere handle NFS problematici che bloccano `getdents()` indefinitamente. Quando la struttura del path è nota, usare un glob a profondità fissa (`ls $base/*/$INST/trace/alert_$INST.log`) invece di `find -name`.

## NFS path structure

```
/unipol/logs/database/oracle/<prod|noprod>/<hostname>/<volume>/<INSTANCE_NAME>/trace/alert_<INSTANCE_NAME>.log
```
- `<volume>` ≠ `<INSTANCE_NAME>.lower()` necessariamente — usare `find` per localizzarlo.
- Duplicati da migrazione: `find_alert_log()` prende il file più recente (`xargs ls -t | head -1`).

## Env file Oracle

- `<INSTANCE_NAME>.env` (es. `NP41CDB0.env`) = env del CDB — quello da sourciare.
- Setta: `ORACLE_BASE`, `ORACLE_HOME`, `LD_LIBRARY_PATH`, `PATH`, `ORACLE_SID`, `ORACLE_PDB_SID` (vuoto per CDB), `ORACLE_HOSTNAME`, `TNS_ADMIN`.
- I symlink puntano a path reali tipo `/np41cdb0/home/NP41CDB0/<NAME>.env`.

## Deploy

```bash
./deploy.sh   # rsync → root@lxprworkerlana01:/product/lana-bot/neural-oracle-analyzer
```
Nessun deploy manuale. `deploy.sh` include `data/`, `lib/`, `tools/`, `tests/`, `mcp/`.
