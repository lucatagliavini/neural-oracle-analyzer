# Project Documentation Rules (Non-Obvious Only)

## Structure
- `docs/specs/` is **living spec** (not history) — it must be kept internally consistent and updated when principles change.
- `docs/sessions/` is **append-only history** — never rewrite or clean existing entries; add a new file per session.
- Multiple sessions same day: use suffix `-2`, `-3` (e.g., `2026-09-01-2.md`).
- `oracle-mcp-tools-PROJECT.md` is **historical only** — design has since evolved; `docs/specs/` supersedes it.

## Session summaries
- A session summary must be written **automatically at end of every session** without waiting for explicit request.
- Required content: what was done, decisions and rationale, current state, next steps.
- Read the latest `docs/sessions/` file at the start of a new session to resume context.

## Open questions (as of 2026-08-31)
Four items still unresolved that block implementation of several tools — see `AGENTS.md` "Open points" section.
