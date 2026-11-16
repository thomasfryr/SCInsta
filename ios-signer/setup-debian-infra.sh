#!/usr/bin/env bash
# ==============================================================================
# SCInsta — Fase 1 (Entorno Base Debian) y Fase 4 (Módulo 3: /ios-signer)
# Script de aprovisionamiento automatizado para Debian Server (amd64)
# ==============================================================================
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] Ejecuta este script como root o mediante sudo." >&2
  exit 1
fi

OPERATOR_USER="${SUDO_USER:-${1:-$(logname 2>/dev/null || echo "debian")}}"
BASE_DIR="/home/${OPERATOR_USER}/scinsta-infra"
SIGNER_DIR="${BASE_DIR}/ios-signer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/7] Instalando paquetes base vía APT (Fase 1)..."
apt-get update -y
apt-get install -y \
  nodejs \
  npm \
  docker.io \
  usbmuxd \
  libimobiledevice6 \
  libimobiledevice-utils \
  avahi-daemon \
  curl \
  wget \
  jq \
  unzip \
  ca-certificates

echo "[2/7] Instalando paquete oficial cloudflared (.deb amd64)..."
if ! command -v cloudflared >/dev/null 2>&1; then
  TMP_DEB="/tmp/cloudflared-linux-amd64.deb"
  wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -O "${TMP_DEB}"
  dpkg -i "${TMP_DEB}" || apt-get install -f -y
  rm -f "${TMP_DEB}"
fi

echo "[3/7] Habilitando servicios docker y avahi-daemon..."
systemctl enable --now docker
systemctl enable --now avahi-daemon
usermod -aG docker "${OPERATOR_USER}" || true

echo "[4/7] Creando estructura de directorios en ${BASE_DIR}..."
mkdir -p "${BASE_DIR}"/{push-server,dm-listener,ios-signer}

if [[ "${SCRIPT_DIR}" != "${SIGNER_DIR}" ]]; then
  cp -f "${SCRIPT_DIR}/resign.sh" "${SIGNER_DIR}/resign.sh" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/signer.env.example" "${SIGNER_DIR}/signer.env.example" 2>/dev/null || true
  cp -f "${SCRIPT_DIR}/crontab.txt" "${SIGNER_DIR}/crontab.txt" 2>/dev/null || true
fi
chmod +x "${SIGNER_DIR}/resign.sh" 2>/dev/null || true
chown -R "${OPERATOR_USER}:${OPERATOR_USER}" "${BASE_DIR}" || true

echo "[5/7] Desplegando contenedor Docker anisette-v3 en 127.0.0.1:6969..."
if ! docker ps -a --format '{{.Names}}' | grep -q '^anisette-v3$'; then
  docker run -d \
    --name anisette-v3 \
    --restart always \
    -p 127.0.0.1:6969:6969 \
    dadoum/anisette-v3-server
else
  docker start anisette-v3 || true
fi

echo "[6/7] Instalando binarios x86_64-linux-netmuxd y AltServer-x86_64..."
NETMUXD_URL="${NETMUXD_URL:-https://github.com/jkcoxson/netmuxd/releases/latest/download/x86_64-linux-netmuxd}"
ALTSERVER_URL="${ALTSERVER_URL:-https://github.com/NyaMisty/AltServer-Linux/releases/latest/download/AltServer-x86_64}"

wget -q "${NETMUXD_URL}" -O /usr/local/bin/netmuxd
chmod +x /usr/local/bin/netmuxd

wget -q "${ALTSERVER_URL}" -O /usr/local/bin/AltServer
chmod +x /usr/local/bin/AltServer

echo "Instalando servicio systemd /etc/systemd/system/netmuxd.service..."
if [[ -f "${SCRIPT_DIR}/systemd/netmuxd.service" ]]; then
  cp -f "${SCRIPT_DIR}/systemd/netmuxd.service" /etc/systemd/system/netmuxd.service
else
  cat <<'EOF' > /etc/systemd/system/netmuxd.service
[Unit]
Description=netmuxd Wireless iOS Multiplexer Daemon (Port 27015)
After=network-online.target avahi-daemon.service usbmuxd.service
Wants=network-online.target avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/netmuxd --disable-unix --host 127.0.0.1
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
systemctl enable --now netmuxd.service

echo "[7/7] Registrando cronjob del Contrato D (0 4 */5 * *)..."
CRON_CMD="0 4 */5 * * /home/${OPERATOR_USER}/scinsta-infra/ios-signer/resign.sh >> /home/${OPERATOR_USER}/scinsta-infra/ios-signer/sign.log 2>&1"
(crontab -u "${OPERATOR_USER}" -l 2>/dev/null | grep -Fv "/scinsta-infra/ios-signer/resign.sh" || true; echo "${CRON_CMD}") | crontab -u "${OPERATOR_USER}" -

echo "=============================================================================="
echo "Aprovisionamiento completado."
echo "Pasos manuales posteriores:"
echo "  1. Conecta el iPhone por USB una única vez y ejecuta: sudo idevicepair pair"
echo "  2. Copia signer.env.example a ${SIGNER_DIR}/signer.env y aplica: chmod 600 ${SIGNER_DIR}/signer.env"
echo "  3. Coloca SCInsta.ipa en ${SIGNER_DIR}/SCInsta.ipa"
echo "=============================================================================="
