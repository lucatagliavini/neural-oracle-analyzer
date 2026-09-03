#!/usr/bin/env bash
# deploy.sh — deploy del progetto su lxprworkerlana01
#
# Uso:
#   ./deploy.sh              # deploy completo
#   ./deploy.sh --dry-run    # mostra cosa verrebbe copiato senza eseguire
#
# Prerequisiti:
#   - Accesso SSH a root@lxprworkerlana01 configurato (chiavi scambiate)
#   - rsync disponibile localmente

set -euo pipefail

REMOTE_HOST="lxprworkerlana01"
REMOTE_USER="root"
REMOTE_DIR="/product/lana-bot/neural-oracle-analyzer"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    echo "[dry-run] Simulazione deploy — nessun file verrà copiato"
fi

RSYNC_OPTS="-av --checksum --perms"
if [ $DRY_RUN -eq 1 ]; then
    RSYNC_OPTS="$RSYNC_OPTS --dry-run"
fi

# File e directory da copiare (esclude ssh_keys, venv, file temporanei)
EXCLUDES=(
    "--exclude=ssh_keys/"
    "--exclude=mcp/venv/"
    "--exclude=*.pyc"
    "--exclude=__pycache__/"
    "--exclude=.git/"
    "--exclude=*.log"
    "--exclude=tests/fixtures/*.tmp"
)

echo "Deploy: ${SCRIPT_DIR} → ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"
echo ""

rsync $RSYNC_OPTS "${EXCLUDES[@]}" \
    --include="lib/" \
    --include="lib/*.sh" \
    --include="lib/*.awk" \
    --include="tools/" \
    --include="tools/*.sh" \
    --include="tests/" \
    --include="tests/*.sh" \
    --include="tests/fixtures/" \
    --include="tests/fixtures/*" \
    --include="data/" \
    --include="data/*.json" \
    --include="mcp/" \
    --include="mcp/*.py" \
    --include="mcp/requirements.txt" \
    --include="etc/" \
    --include="etc/httpd/" \
    --include="etc/httpd/*.conf" \
    --include="etc/systemd/" \
    --include="etc/systemd/*.service" \
    --include="deploy.sh" \
    --exclude="*" \
    "${SCRIPT_DIR}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

if [ $DRY_RUN -eq 0 ]; then
    # Rendi eseguibili gli script bash in locale
    find "${SCRIPT_DIR}/lib" "${SCRIPT_DIR}/tools" "${SCRIPT_DIR}/tests" \
         -name '*.sh' -exec chmod 755 {} \; 2>/dev/null
    chmod 755 "${SCRIPT_DIR}/deploy.sh" 2>/dev/null || true

    # Rendi eseguibili gli script bash sul server
    ssh "${REMOTE_USER}@${REMOTE_HOST}" \
        "find ${REMOTE_DIR}/lib ${REMOTE_DIR}/tools ${REMOTE_DIR}/tests \
              -name '*.sh' -exec chmod 755 {} \; 2>/dev/null; \
         chmod 755 ${REMOTE_DIR}/deploy.sh 2>/dev/null; \
         echo 'Permessi impostati.'"

    # Symlink vhost Apache
    VHOST_SRC="${REMOTE_DIR}/etc/httpd/neural-mcp-oracle.conf"
    VHOST_DST="/etc/httpd/conf.d/neural-mcp-oracle.conf"
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "
        if [ ! -L \"${VHOST_DST}\" ]; then
            ln -sfn \"${VHOST_SRC}\" \"${VHOST_DST}\"
            echo \"Symlink vhost creato: ${VHOST_DST} → ${VHOST_SRC}\"
        else
            echo \"Symlink vhost già presente: ${VHOST_DST}\"
        fi
    "

    # Symlink systemd unit
    SVC_SRC="${REMOTE_DIR}/etc/systemd/neural-oracle-mcp.service"
    SVC_DST="/etc/systemd/system/neural-oracle-mcp.service"
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "
        if [ ! -L \"${SVC_DST}\" ]; then
            ln -sfn \"${SVC_SRC}\" \"${SVC_DST}\"
            systemctl daemon-reload
            systemctl enable neural-oracle-mcp.service
            echo \"Systemd unit abilitata: neural-oracle-mcp.service\"
        else
            echo \"Systemd unit già presente: ${SVC_DST}\"
            systemctl daemon-reload
        fi
    "

    # Crea/aggiorna venv Python se requirements.txt è presente
    if ssh "${REMOTE_USER}@${REMOTE_HOST}" "test -f ${REMOTE_DIR}/mcp/requirements.txt"; then
        echo "Aggiornamento venv Python..."
        ssh "${REMOTE_USER}@${REMOTE_HOST}" "
            VENV=${REMOTE_DIR}/mcp/venv
            REQ=${REMOTE_DIR}/mcp/requirements.txt
            # Crea il venv se non esiste
            if [ ! -f \"\$VENV/bin/python\" ]; then
                python3 -m venv \"\$VENV\"
                python3 -m ensurepip --upgrade
                \"\$VENV/bin/python\" -m ensurepip --upgrade
            fi
            # Installa/aggiorna dipendenze (pip.conf nel venv gestisce il proxy)
            \"\$VENV/bin/pip\" install --quiet -r \"\$REQ\"
            echo \"venv OK: \$(\"\$VENV/bin/python\" --version)\"
        "
    fi

    echo ""
    echo "Deploy completato: ${REMOTE_DIR}"
else
    echo ""
    echo "[dry-run] Deploy simulato — nessuna modifica effettuata"
fi
