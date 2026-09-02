# Neural Oracle Analyzer

Libreria di tool bash/awk per diagnostica Oracle Database, esposta come server MCP (FastAPI HTTP) su `lxprworkerlana01`.

## Architettura

```
Livello 1 — mcp/           FastAPI MCP server (HTTP) — invoca i primitivi come subprocessi
Livello 2 — tools/         13 tool bash/awk — output JSON su stdout, testabili in isolamento
            lib/            oracle_conn.sh — libreria condivisa: SSH, sqlplus, CSV→JSON
```

## Tool disponibili

| Tool | Descrizione |
|---|---|
| `list_instances_on_host` | SSH + `ls ~/NP*.env` — CDB presenti su un host |
| `identify_instance` | `v$instance` — info sull'istanza corrente |
| `list_pdbs` | `show pdbs` — PDB del CDB (12c+) |
| `get_diag_home` | `v$parameter diagnostic_dest` |
| `scan_alert_log` | Scansione alert log ORA- da NFS, con filtri `--code`, `--since`, `--pdb` |
| `tail_alert_log` | Ultime N righe alert log da NFS (default 2000) |
| `check_resource_limits` | `v$resource_limit` per sessions/processes |
| `sessions_by_user` | `v$session` raggruppato per (username, status) |
| `sessions_by_machine` | `v$session` raggruppato per (machine, status) |
| `check_fra_usage` | FRA: `v$recovery_file_dest` + `v$flash_recovery_area_usage` + `show parameters` |
| `top_pga_sessions` | Top sessioni per PGA (`v$process` + `v$session`), `--limit=N` (default 20) |
| `pga_sga_by_pdb` | PGA/SGA per PDB via `v$rsrcpdbmetric` (12c+) |
| `pga_by_pdb_session` | PGA per sessione raggruppato per PDB (12c+) |

## Uso diretto di un tool

```bash
./tools/identify_instance.sh TEST axnporadb41 NP41CDB0
./tools/scan_alert_log.sh TEST axnporadb41 NP41CDB0 --code=ORA-00060
./tools/tail_alert_log.sh TEST axnporadb41 NP41CDB0 --lines=500
./tools/top_pga_sessions.sh TEST axnporadb41 NP41CDB0 --limit=10
./tools/list_instances_on_host.sh TEST axnporadb41
```

Output: un singolo oggetto JSON su stdout. Diagnostica (SSH, timing) su stderr.

## Test

```bash
# Solo validazione input — non richiede connessione Oracle (38 test, locale)
bash tests/test_contract.sh --quick

# Tool specifico — solo input invalidi
bash tests/test_contract.sh --quick identify_instance

# Suite completa — richiede connessione Oracle + NFS mount
# Eseguire su lxprworkerlana01
bash tests/test_contract.sh

# Tool specifico — suite completa con fixture reale
bash tests/test_contract.sh identify_instance
```

I test `--quick` si eseguono in locale (nessuna connessione al DB). La suite completa richiede:
- Accesso SSH a `axnporadb41` con la chiave in `ssh_keys/oracle/.ssh/id_rsa`
- Mount NFS attivo su `/unipol/logs/database/oracle/noprod/axnporadb41/` (per i tool di log)

### Struttura test

| Test | Descrizione | Connessione? |
|---|---|---|
| Input invalidi | ENVIRONMENT errato, HOST/INST vuoti → exit 2 | No |
| Host inesistente | SSH fail → `connection_failed`, exit 1 | SSH (fallisce subito) |
| Log not found | NFS assente → `log_not_found`, exit 1 | No |
| `--limit` invalido | `top_pga_sessions --limit=0/abc` → `invalid_argument` | No |
| Fixture ok | Esegue sul target reale, verifica envelope completo | Oracle completo |

### Fixture

Le fixture in `tests/fixtures/<tool>.ok.json` specificano i parametri di connessione:

```
#ENV=TEST
#HOST=axnporadb41
#INST=NP41CDB0
```

Per `list_instances_on_host` (solo 2 argomenti) si omette `#INST=`.

## Deploy

```bash
./deploy.sh   # rsync → root@lxprworkerlana01:/product/lana-bot/neural-oracle-analyzer
```

Non effettuare deploy manuali — usare sempre `deploy.sh`.

## Contratto JSON

Ogni tool produce su stdout **un solo oggetto JSON** con struttura:

```json
{
  "tool": "identify_instance",
  "generated_at": "2026-09-03T10:00:00+02:00",
  "environment": "TEST",
  "hostname": "axnporadb41",
  "instance_name": "NP41CDB0",
  "oracle_version": "19.0.0.0.0",
  "status": "ok",
  "data": [...],
  "error": null
}
```

- `status`: `"ok"` (exit 0) o `"error"` (exit 1) o errore argomenti (exit 2)
- `data`: sempre un array (mai `null`)
- In caso di errore: `data: []`, `error: {code, message, context}`
- Exit code 2: argomenti CLI non validi (JSON comunque presente)

Codici errore standard: `invalid_environment`, `invalid_argument`, `missing_env_file`,
`connection_failed`, `query_failed`, `unsupported_version`, `log_not_found`.

## Documentazione

- [`docs/specs/architettura.md`](docs/specs/architettura.md) — design libreria, lista tool, pattern
- [`docs/specs/contratto-json.md`](docs/specs/contratto-json.md) — contratto JSON completo
- [`docs/specs/infrastruttura.md`](docs/specs/infrastruttura.md) — target deploy, infrastruttura
- [`docs/sessions/`](docs/sessions/) — log delle sessioni di lavoro
- [`implementation-plan.md`](implementation-plan.md) — milestones M0–M9
