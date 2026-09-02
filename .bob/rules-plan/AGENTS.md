# Project Architecture Rules (Non-Obvious Only)

## Hard architectural constraints
- `lib/oracle_conn.sh` is the **only** place for connection logic and CSV→JSON conversion. All tools are thin wrappers over it. Any future auth change touches exactly one file.
- The MCP server is an orchestration wrapper over the bash scripts — mapping is 1:1 (one MCP tool = one script). Design scripts with this in mind from the start.
- MCP transport: **HTTP** (not stdio). API key must never be committed.

## Platform
- MCP host: RHEL 9.8 `ppc64le` (`lxprworkerlana01`). `gawk` is available here.
- Targets: Linux and AIX Oracle servers. Our code never runs directly on AIX today (only `sqlplus` binary does via SSH). The POSIX awk constraint is a future reserve, not active.

## Data flow for log tools
- Alert log arrives via **NFS mount** on MCP host, not SSH+remote awk.
- Path pattern: `/unipol/logs/database/oracle/<prod|noprod>/<hostname>/<db_lowercase>/<INSTANCE_NAME>/trace/alert_<INSTANCE_NAME>.log`
- If the mount is absent: JSON error, no fallback. The orchestrator decides what to do next.

## Versioning / degradation
- Oracle 11g targets: all multitenant tools (`list_pdbs.sh`, `pga_sga_by_pdb.sh`, `pga_by_pdb_session.sh`) must degrade gracefully with `unsupported_version`, not crash.
- The envelope includes `oracle_version` so the orchestrator can branch without re-querying.

## Orchestrator (not started)
- Build the decision-tree orchestrator only **after** all individual tools are stable.
- Runbook logic: `scan_alert_log.sh` → if `ORA-04030` detected → invoke PGA chain → consolidated report.

## Unresolved blockers affecting design
1. `ENVIRONMENT` → `prod|noprod` mapping affects every log tool path.
2. RAC topology: `INSTANCE_NAME` ≠ `DB_NAME` may require an additional input parameter.
3. Env file location/format drives the `lib/oracle_conn.sh` implementation entirely.
