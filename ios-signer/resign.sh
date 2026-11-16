#!/usr/bin/env bash
# ==============================================================================
# SCInsta — Módulo 3 (/ios-signer/resign.sh)
# Pipeline de refirma inalámbrica iOS (Cumplimiento estricto Contrato B y D)
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/signer.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[$(date -Iseconds)] [ERROR] No se encontró ${ENV_FILE} (recuerda aplicar chmod 600 signer.env)." >&2
  exit 1
fi

# Cargar variables de configuración
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Variables de entorno obligatorias del Contrato D
export USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015
export ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969

PUSH_WEBHOOK_URL="${PUSH_WEBHOOK_URL:-http://127.0.0.1:3000/api/notify}"
IPA_PATH="${IPA_PATH:-${SCRIPT_DIR}/SCInsta.ipa}"

if [[ -z "${UDID:-}" || -z "${APPLE_ID:-}" || -z "${APP_PASSWORD:-}" ]]; then
  echo "[$(date -Iseconds)] [ERROR] UDID, APPLE_ID o APP_PASSWORD no están definidos en ${ENV_FILE}." >&2
  exit 1
fi

# 1. Verificación del artefacto de entrada (Contrato D)
if [[ ! -f "${IPA_PATH}" ]]; then
  echo "[$(date -Iseconds)] [ERROR] No existe el artefacto IPA en: ${IPA_PATH}" >&2
  exit 1
fi

if command -v unzip >/dev/null 2>&1; then
  IPA_CONTENTS="$(unzip -l "${IPA_PATH}" 2>/dev/null || true)"
  if echo "${IPA_CONTENTS}" | grep -Eq 'FLEXing\.dylib|libflex\.dylib|PlugIns/'; then
    echo "[$(date -Iseconds)] [ERROR] El archivo ${IPA_PATH} incumple el Contrato D: contiene FLEXing.dylib, libflex.dylib o PlugIns/." >&2
    exit 1
  fi
fi

# 2. Ciclo de refirma inalámbrica con hasta 4 reintentos (cada 30 min = 1800s)
MAX_ATTEMPTS=4
SLEEP_SECONDS=1800

for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
  echo "[$(date -Iseconds)] [INFO] Intento ${attempt}/${MAX_ATTEMPTS}: Buscando iPhone (${UDID}) en red vía netmuxd (${USBMUXD_SOCKET_ADDRESS})..."

  if idevice_id -l 2>/dev/null | grep -Fq "${UDID}"; then
    echo "[$(date -Iseconds)] [INFO] Dispositivo ${UDID} detectado en red. Ejecutando AltServer..."
    if /usr/local/bin/AltServer -u "$UDID" -a "$APPLE_ID" -p "$APP_PASSWORD" "$IPA_PATH"; then
      echo "[$(date -Iseconds)] [OK] Refirma inalámbrica de SCInsta.ipa completada con éxito en el intento ${attempt}."
      exit 0
    else
      echo "[$(date -Iseconds)] [WARN] AltServer falló durante el intento ${attempt}." >&2
    fi
  else
    echo "[$(date -Iseconds)] [WARN] iPhone (${UDID}) no visible en idevice_id -l durante el intento ${attempt}." >&2
  fi

  if (( attempt < MAX_ATTEMPTS )); then
    echo "[$(date -Iseconds)] [INFO] Esperando 30 minutos (${SLEEP_SECONDS}s) antes del siguiente reintento..."
    sleep "${SLEEP_SECONDS}"
  fi
done

# 3. Alerta de fallo al Webhook Interno (Cumplimiento estricto del Contrato B y Contrato D)
echo "[$(date -Iseconds)] [ERROR] Fallaron los ${MAX_ATTEMPTS} intentos de refirma inalámbrica. Enviando alerta a ${PUSH_WEBHOOK_URL}..." >&2

NOW_SEC="$(date +%s)"
MESSAGE_ID="signer-alert-${NOW_SEC}"
TIMESTAMP_MS="${NOW_SEC}000"

PAYLOAD="$(cat <<EOF
{
  "messageId": "${MESSAGE_ID}",
  "senderName": "SCInsta Auto-Signer",
  "text": "Fallo de refirma inalámbrica tras 4 reintentos. Acerca el iPhone al Wi-Fi local.",
  "threadId": null,
  "timestamp": ${TIMESTAMP_MS}
}
EOF
)"

curl -sS -X POST "${PUSH_WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBHOOK_SECRET:-}" \
  -d "${PAYLOAD}" || echo "[$(date -Iseconds)] [ERROR] No se pudo contactar con el webhook ${PUSH_WEBHOOK_URL}." >&2

exit 1
