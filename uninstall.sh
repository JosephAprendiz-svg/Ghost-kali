#!/usr/bin/env bash
set -euo pipefail

DEST=/usr/local/bin/joseph-trio
echo "Desinstalando ${DEST} ..."
sudo rm -f "$${DEST}"
echo "Hecho."
