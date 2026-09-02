# Project Coding Rules (Non-Obvious Only)

## Before writing any code
- Read [`docs/specs/contratto-json.md`](../../docs/specs/contratto-json.md) fully — the JSON envelope and error codes are a closed contract, deviations must be registered there.
- Read [`docs/specs/architettura.md`](../../docs/specs/architettura.md) — the tool list, library boundaries, and platform constraints are defined here.

## Script structure
- Every tool must source `lib/oracle_conn.sh`; no tool may contain its own connection logic or CSV→JSON conversion.
- `run_sqlplus_query()` in `lib/oracle_conn.sh` handles `SET MARKUP CSV ON` + awk parsing — do not parse sqlplus output inline in tool scripts.
- `ENVIRONMENT` must be validated as the **first** thing every script does, before touching env files or SSH.

## Output rules (gotchas)
- stdout must be **one valid JSON object** and nothing else — even debug/timing output breaks MCP client parsing.
- `data` must always be an array, even when empty (`[]`) — never omit the key or make it null.
- `oracle_version` can be `null` only if the version query itself failed to execute (e.g., `connection_failed`).

## Error handling
- Tools that use multitenant views (`cdb_pdbs`, `v$rsrcpdbmetric`, `show pdbs`) must detect Oracle 11g and return `unsupported_version` error with `context: {required: "12c+", actual: "..."}`.
- Log tools (`scan_alert_log.sh`, `tail_alert_log.sh`) must return `log_not_found` JSON error if the NFS path is absent — no fallback to SSH.

## AIX / portability
- Today, no tool runs our own awk/bash/python3 on an AIX target (only `sqlplus` binary runs there via SSH). The portability constraint in the specs is a future safeguard, not an active blocker.

## Deploy
- Create/update `deploy.sh` (targeting `root@lxprworkerlana01.servizi.gr-u.it`) whenever there is deployable code — do not deploy manually.
