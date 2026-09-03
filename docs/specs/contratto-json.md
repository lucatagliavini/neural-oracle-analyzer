# Specs: Contratto JSON dei tool

Definisce il contratto di input/output comune a tutti i tool, prima di qualsiasi implementazione. Ogni tool nuovo deve rispettare questo contratto; ogni scostamento va registrato qui.

## Input

- Parametri standard: `ENVIRONMENT`, `HOSTNAME`, `INSTANCE_NAME` — mai hardcoded.
  - `INSTANCE_NAME`: nome del CDB (es. `NP41CDB0`) — corrisponde al nome del file env da sourcare (`~/<INSTANCE_NAME>.env`) e al nome dell'istanza Oracle. **Non** usare il generico `DB_NAME` per evitare ambiguità tra CDB e PDB.
  - `HOSTNAME`: nome dell'host OS su cui gira l'istanza — corrisponde alla directory sotto `prod|noprod` nel mount NFS.
- `ENVIRONMENT` è un enum fisso e case-sensitive: `EURO`, `TEST`, `CERT`, `INTE`, `COLL`, `PROD`. Validato per primo, prima di ogni altra operazione.
- Filtri opzionali per-tool con sintassi `--nomeparam=valore` (es. `--code=ORA-04030` per `scan_alert_log.sh`).

## Envelope comune di output (stdout)

Un unico oggetto JSON valido su stdout, sempre con queste chiavi di primo livello:

```json
{
  "tool": "identify_instance",
  "generated_at": "2026-08-31T15:04:22+02:00",
  "environment": "TEST",
  "hostname": "axnporadb41",
  "instance_name": "NP41CDB0",
  "oracle_version": "19.0.0.0.0",
  "status": "ok",
  "data": [ ... ],
  "error": null
}
```

- `tool`: nome del tool (stesso nome dello script senza `.sh`).
- `generated_at`: timestamp ISO 8601 con timezone, generato sull'host MCP.
- `environment`, `hostname`, `instance_name`: echo dell'input.
- `oracle_version`: popolato dalla libreria comune; può essere `null` se la query di versione non è arrivata a eseguirsi (es. `connection_failed`).
- `status`: `ok` | `error`.
- `data`: sempre un array di oggetti, una per riga risultato — anche vuoto (`[]`), che è un esito valido. Le chiavi degli oggetti sono i nomi delle colonne Oracle in minuscolo.
- `error`: `null` in caso di ok, altrimenti oggetto errore (vedi sotto).

## Oggetto errore

```json
"error": { "code": "unsupported_version", "message": "...", "context": { "required": "12c+", "actual": "11.2.0.4" } }
```

Codici standard (lista chiusa; aggiunte solo via update di questa spec):

| Codice | Significato | `context` tipico |
|---|---|---|
| `invalid_environment` | `ENVIRONMENT` non nell'enum | `received` |
| `invalid_argument` | altro parametro mancante/malformato | `param` |
| `missing_env_file` | env file del target non trovato/non leggibile | `path` |
| `connection_failed` | SSH o sqlplus non raggiungibili / login fallito | `detail` |
| `query_failed` | ORA-xxxx durante l'esecuzione della query | `ora_error` |
| `unsupported_version` | feature non disponibile sulla versione del target | `required`, `actual` |
| `log_not_found` | path alert log assente sul mount NFS | `path` |
| `command_not_available` | comando OS richiesto non presente sul target | `command`, `os` |

In caso di errore, `data` è `[]` e `status` è `"error"`. Nessun fallback automatico: è l'operatore/orchestratore a decidere il passo successivo.

## Exit code

- `0` — successo (anche `data: []`).
- `1` — errore applicativo: stdout contiene comunque l'envelope JSON con `status: "error"`.
- `2` — uso errato della riga di comando (l'output JSON può essere ridotto al minimo).

## Regole trasversali

- Ogni diagnostica non JSON (log di ssh, timing, debug) va su **stderr**, mai su stdout: stdout deve restare parseabile al 100%.
- La conversione CSV→JSON avviene nell'awk della libreria comune (`SET MARKUP CSV ON` in sqlplus), non nei singoli tool.
- Un tool = una responsabilità singola, coerente con la dichiarazione tool MCP (nome, descrizione, scopo).
- **Escape JSON da testo libero**: qualunque campo stringa JSON che contiene testo proveniente da log Oracle, messaggi di errore o output non-strutturato **deve** essere prodotto tramite `json_esc()` da `lib/json_esc.awk`. Non scrivere funzioni di escape inline nei tool — sono invariabilmente incomplete (mancano i byte Latin-1, mancano i backslash nelle descrizioni del dizionario). Vedi la sezione `lib/json_esc.awk` in `architettura.md` per il pattern d'uso corretto.

## Esempi per tool (forma di `data`)

### `identify_instance.sh` — ok

```json
"data": [
  {
    "instance_name": "NP41CDBX",
    "host_name": "axnporadb41",
    "version": "19.0.0.0.0",
    "status": "OPEN",
    "database_status": "ACTIVE",
    "instance_role": "PRIMARY_INSTANCE",
    "startup_time": "2026-08-20 04:11:22"
  }
]
```

### `list_pdbs.sh` — ok (19c)

```json
"data": [
  { "con_id": 2, "pdb_name": "PDB1", "open_mode": "READ WRITE", "restricted": "NO" }
]
```

### `list_pdbs.sh` — errore su 11g

```json
{ "status": "error", "data": [], "oracle_version": "11.2.0.4.0",
  "error": { "code": "unsupported_version", "message": "multitenant non disponibile su questa versione",
             "context": { "required": "12c+", "actual": "11.2.0.4.0" } } }
```

### `scan_alert_log.sh` — ok

```json
"data": [
  { "code": "ORA-04030", "pdb_name": "AIMELA", "description": "...", "category": "memory",
    "severity": "critical", "count": 3, "first_seen": "2026-08-30T22:14:01", "last_seen": "2026-08-30T23:02:47",
    "samples": ["...riga log...", "...riga log..."] },
  { "code": "ORA-04030", "pdb_name": null, "description": "...", "category": "memory",
    "severity": "critical", "count": 1, "first_seen": "2026-08-20T10:00:00", "last_seen": "2026-08-20T10:00:00",
    "samples": ["ORA-04030: out of process memory..."] }
]
```

`pdb_name`: nome del PDB che ha generato l'errore (es. `"AIMELA"`), o `null` se l'errore viene dal CDB root (riga senza prefisso `PDBNAME(con_id):`). Lo stesso codice ORA- può apparire più volte con `pdb_name` diversi — ogni coppia `(code, pdb_name)` è un item separato nell'array.

Filtri opzionali (aggiuntivi rispetto a `--code=` e `--since=`):
- `--pdb=NAME` — filtra solo gli errori del PDB specificato (case-insensitive).
- `--pdb=CDB` — filtra solo gli errori del container root (`pdb_name: null`).

### `scan_alert_log.sh` — errore mount assente

```json
{ "status": "error", "data": [],
  "error": { "code": "log_not_found", "message": "path non esistente o non raggiungibile sul mount NFS",
             "context": { "path": "/unipol/logs/database/oracle/noprod/axnporadb41/np41cdbX/NP41CDBX/trace/alert_NP41CDBX.log" } } }
```

### Tool OS (`os_cpu_stats`, `os_memory_stats`, `os_disk_stats`) — note sul contratto

- `instance_name`: sempre `null` — i tool OS non operano a livello di istanza Oracle.
- `oracle_version`: sempre `null` — non applicabile.
- `os_type`: `"aix"` o `"linux"` — rilevato da `uname -s` tramite `lib/os_cmd.sh`.
- Il campo `data` contiene due chiavi di primo livello: `samples` (array campioni) e `summary` (statistiche aggregate min/max/avg/p95/p99).
- Firma CLI: `TOOL ENV HOSTNAME [--samples=N] [--interval=S]` — nessun `INSTANCE_NAME`.

### `os_cpu_stats.sh` — ok

```json
{
  "tool": "os_cpu_stats", "environment": "PROD", "hostname": "axproradb01",
  "instance_name": null, "oracle_version": null, "status": "ok",
  "data": {
    "os_type": "aix",
    "cpu_count": 16,
    "samples": [
      { "ts": "2026-09-07T10:00:01+02:00", "cpu_user_pct": 12, "cpu_sys_pct": 5,
        "cpu_idle_pct": 78, "cpu_wait_pct": 5, "run_queue": 2 }
    ],
    "summary": {
      "cpu_user_pct": { "min": 10, "max": 15, "avg": 12.2, "p95": 14.5, "p99": 15 },
      "cpu_sys_pct":  { "min": 4,  "max": 7,  "avg": 5.4,  "p95": 6.8,  "p99": 7  },
      "cpu_idle_pct": { "min": 73, "max": 81, "avg": 77.8, "p95": 80.5, "p99": 81 },
      "cpu_wait_pct": { "min": 3,  "max": 8,  "avg": 4.6,  "p95": 7.0,  "p99": 8  },
      "run_queue":    { "min": 1,  "max": 4,  "avg": 2.1,  "p95": 3.8,  "p99": 4  }
    }
  },
  "error": null
}
```

### `os_cpu_stats.sh` — errore comando mancante

```json
{ "status": "error", "data": [],
  "error": { "code": "command_not_available", "message": "vmstat non trovato sul target",
             "context": { "command": "vmstat", "os": "aix" } } }
```

### `os_memory_stats.sh` — ok (forma `data`)

```json
"data": {
  "os_type": "linux",
  "samples": [
    { "ts": "...", "ram_total_bytes": 137438953472, "ram_used_bytes": 98765432100,
      "ram_free_bytes": 38673521372, "swap_total_bytes": 8589934592,
      "swap_used_bytes": 1073741824, "page_in_per_sec": 0, "page_out_per_sec": 0 }
  ],
  "summary": {
    "ram_used_bytes":    { "min": 98000000000, "max": 99000000000, "avg": 98500000000, "p95": 98900000000, "p99": 99000000000 },
    "swap_used_bytes":   { "min": 1073741824,  "max": 1073741824,  "avg": 1073741824,  "p95": 1073741824,  "p99": 1073741824  },
    "page_in_per_sec":   { "min": 0, "max": 2, "avg": 0.4, "p95": 1.9, "p99": 2 },
    "page_out_per_sec":  { "min": 0, "max": 1, "avg": 0.2, "p95": 0.9, "p99": 1 }
  }
}
```
