#!/usr/bin/env bash
set -euo pipefail

DEST=/usr/local/bin/joseph-trio
echo "Instalando joseph-trio en $${DEST} ..."
sudo mkdir -p /usr/local/bin
sudo cp ./joseph-trio "$${DEST}"
sudo chmod +x "${DEST}"
echo "Instalado. Puedes ejecutar: sudo joseph-trio"
