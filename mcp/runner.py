"""runner.py — invocazione dei tool primitivi bash come subprocess.

Espone un'unica funzione pubblica:
    run_primitive_tool(script_name, *args) -> dict

Il dict restituito è sempre l'envelope JSON del tool (parsed).
In caso di errore subprocess (timeout, file non trovato, output non JSON)
viene costruito un envelope sintetico con status="error".
"""
import json
import subprocess
from pathlib import Path

from config import TOOLS_DIR, TOOL_TIMEOUT


def run_primitive_tool(script_name: str, *args: str) -> dict:
    """Esegue tools/<script_name>.sh con gli argomenti forniti.

    Args:
        script_name: nome dello script senza estensione (es. "identify_instance")
        *args:        argomenti posizionali e opzionali passati allo script

    Returns:
        Il dict corrispondente all'envelope JSON emesso dallo script su stdout.
        In caso di errore subprocess restituisce un envelope sintetico con
        status="error" e error.code appropriato.
    """
    script_path = TOOLS_DIR / f"{script_name}.sh"

    if not script_path.is_file():
        return _error_envelope(
            tool=script_name,
            code="invalid_argument",
            message=f"Script non trovato: {script_path}",
            context={"path": str(script_path)},
        )

    cmd = ["bash", str(script_path)] + list(args)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=TOOL_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return _error_envelope(
            tool=script_name,
            code="query_failed",
            message=f"Timeout dopo {TOOL_TIMEOUT}s",
            context={"timeout_seconds": TOOL_TIMEOUT},
        )
    except OSError as exc:
        return _error_envelope(
            tool=script_name,
            code="connection_failed",
            message=f"Impossibile avviare il processo: {exc}",
            context={"detail": str(exc)},
        )

    stdout = result.stdout.strip()

    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        # Lo script ha prodotto output non JSON — segnalare come errore
        return _error_envelope(
            tool=script_name,
            code="query_failed",
            message="Output dello script non è JSON valido",
            context={
                "stdout_excerpt": stdout[:500] if stdout else "(vuoto)",
                "stderr_excerpt": result.stderr.strip()[:500],
                "exit_code": result.returncode,
            },
        )


def _error_envelope(tool: str, code: str, message: str, context: dict) -> dict:
    """Costruisce un envelope di errore sintetico (senza timestamp né oracle_version)."""
    from datetime import datetime, timezone

    return {
        "tool": tool,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "environment": None,
        "hostname": None,
        "instance_name": None,
        "oracle_version": None,
        "status": "error",
        "data": [],
        "error": {
            "code": code,
            "message": message,
            "context": context,
        },
    }
