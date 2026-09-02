"""config.py — configurazione del server MCP Neural Oracle Analyzer.

Legge le variabili d'ambiente (da .env tramite python-dotenv o da environment
di sistema). Il file .env NON è versionato; va creato manualmente sul server.

Variabili riconosciute:
    MCP_API_KEY   — chiave di autenticazione obbligatoria (X-API-Key header)
    MCP_PORT      — porta uvicorn (default: 8420)
    TOOLS_DIR     — path assoluto della directory tools/ (default: auto-detect)
    TOOL_TIMEOUT  — timeout subprocess in secondi (default: 120)
"""
import os
from pathlib import Path

from dotenv import load_dotenv

# Carica .env dalla directory mcp/ (dove risiede questo file)
_HERE = Path(__file__).parent
load_dotenv(_HERE / ".env")

# API key — obbligatoria a runtime, non a import time (per permettere test unitari)
API_KEY: str = os.environ.get("MCP_API_KEY", "")

# Porta uvicorn (usata dal .service per il parametro --port)
PORT: int = int(os.environ.get("MCP_PORT", "8420"))

# Directory dei tool primitivi bash
# Default: ../tools/ relativo alla directory del progetto (un livello sopra mcp/)
_PROJECT_ROOT = _HERE.parent
TOOLS_DIR: Path = Path(os.environ.get("TOOLS_DIR", str(_PROJECT_ROOT / "tools")))

# Timeout per ogni invocazione subprocess (secondi)
TOOL_TIMEOUT: int = int(os.environ.get("TOOL_TIMEOUT", "120"))
