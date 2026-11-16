# ORCHESTRATOR.md — Guía de Arquitectura y Coordinación Multi-Agente

## 1. Rol del Agente Orquestador
Eres el **Agente Orquestador (Lead Architect & Integration Manager)** de este ecosistema.
Tu responsabilidad **NO** es escribir código de implementación directamente ni desarrollar cada módulo desde cero, sino:
1. **Mantener la coherencia arquitectónica** entre los 4 módulos desacoplados del sistema (`ORCHESTRATOR.md` / especificaciones y `TASKS.md`).
2. **Garantizar el cumplimiento estricto de los Contratos de Interfaz** definidos en este documento (ningún agente trabajador puede cambiar rutas, esquemas URL, puertos o nombres de campos JSON sin actualizar primero este archivo).
3. **Auditar entregas y diagnosticar fallos:** Revisar código generado, logs de compilación (`make`/`cyan`), logs de `systemd` o reportes `.ips` de iOS, identificar la causa raíz y emitir instrucciones precisas de corrección para el agente trabajador correspondiente.
4. **Actualizar `TASKS.md`:** Mantener actualizado el estado de avance, dependencias, auditorías y bloqueos de cada módulo tras cada iteración.
5. **Generar prompts autocontenidos:** Cuando corresponda iniciar un nuevo módulo o corregir uno existente, redactar un prompt cerrado, sin ambigüedades, delimitando exactamente qué carpeta y archivos debe tocar el agente trabajador.

---

## 2. Arquitectura del Sistema (Visión Global)

El proyecto implementa un ecosistema autónomo y *Calm Tech* para mensajería directa de Instagram en iOS sin APIs oficiales de Meta ni cuentas empresariales:

- **Módulo 0 (`/SCInsta` — macOS / Theos + `cyan`):** Tweak Objective-C/Logos + empaquetado `.ipa` modificado (Instagram `455.0.0`) con *Bundle ID* independiente (`com.scinsta.app`), *spoofing* síncrono de `NSBundle` (`com.burbn.instagram`), sanitización de Keychain (`SecItem*`) para cuentas gratuitas y esquema URL propio (`scinsta://`).
- **Módulo 1 (`/push-server` — Debian Server / Node.js + PWA):** Backend Express con *Web Push* nativo (VAPID) para Safari iOS, túnel HTTPS (`cloudflared`) y PWA instalable que abre directamente la conversación específica en SCInsta al tocar la notificación.
- **Módulo 2 (`/dm-listener` — Debian Server / Node.js + Playwright):** Agente *headless* ultra ligero que intercepta pasivamente *frames* MQTT/WebSocket (`edge-chat.instagram.com`) y resuelve nombres desde caché/DOM local **con prohibición absoluta de realizar peticiones HTTP activas a los servidores de Meta**.
- **Módulo 3 (`/ios-signer` — Debian Server / Docker + `netmuxd` + `AltServer-Linux`):** Pipeline automatizado por `cron` (cada 5 días) que firma e instala inalámbricamente `SCInsta.ipa` en el iPhone vía Wi-Fi antes de que caduque el certificado gratuito de 7 días.

---

## 3. Contratos Técnicos Inmutables (Fuente Única de Verdad)

Todos los agentes trabajadores deben respetar estas interfaces exactas:

### Contrato A: Esquema URL y Deep Linking (Módulo 0 ↔ Módulo 1)
- **Bundle ID del IPA empaquetado:** `com.scinsta.app`
- **Bundle ID reportado en tiempo de ejecución (`NSBundle` hook):** `com.burbn.instagram`
- **URL Scheme registrado en `Info.plist` (`url_scheme.plist`):** `scinsta`
- **Rutas Deep Link soportadas por la PWA (`sw.js`):**
  - Hilo específico: `scinsta://direct-thread?id=<threadId>`
  - Bandeja general (fallback / alertas de sistema): `scinsta://direct-inbox`

### Contrato B: Webhook Interno de Notificaciones (Módulo 2 / Módulo 3 → Módulo 1)
- **Endpoint:** `POST http://127.0.0.1:3000/api/notify`
- **Autenticación:** Cabecera obligatoria `Authorization: Bearer <WEBHOOK_SECRET>`
- **Payload JSON esperado:**
  ```json
  {
    "messageId": "string (item_id único para deduplicación)",
    "senderName": "string (Nombre legible o @usuario resuelto pasivamente)",
    "text": "string (Cuerpo del mensaje o resumen de adjunto)",
    "threadId": "string | null (ID del hilo de Instagram; null si es alerta de sistema)",
    "timestamp": 1731750000000
  }
  ```
- **Regla de construcción de `targetUrl` en `/push-server`:**
  - Si `threadId` es un string no vacío → `scinsta://direct-thread?id=${threadId}`
  - Si `threadId` es `null` o vacío → `scinsta://direct-inbox`

### Contrato C: Seguridad Pasiva del Listener (Módulo 2)
- **Prohibición estricta:** Cero llamadas `fetch`, `axios` o `XHR` hacia `i.instagram.com` o `www.instagram.com/api/...` desde el script.
- **Resolución de identidad:** Únicamente interceptando pasivamente `page.on('response')` de la carga natural de `/api/v1/direct_v2/inbox` o leyendo el DOM renderizado (`div[role="list"] div[role="listitem"]`), persistiendo en `users_cache.json`.
- **Deduplicación:** Buffer circular en memoria de los últimos 500 `item_id` procesados.

### Contrato D: Refirma Inalámbrica iOS (Módulo 0 → Módulo 3)
- **Artefacto de entrada:** `/home/<usuario>/scinsta-infra/ios-signer/SCInsta.ipa` (compilado con Módulo 0, sin `FLEXing.dylib`/`libflex.dylib` y sin `PlugIns`).
- **Variables de entorno de ejecución:**
  - `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`
  - `ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969`
- **Frecuencia:** `0 4 */5 * *` (cada 5 días a las 04:00 AM), con alerta a `POST http://127.0.0.1:3000/api/notify` (`threadId: null`) si fallan los 4 reintentos.

---

## 4. Protocolo de Operación del Orquestador

1. **Delegación Autónoma vía Sub-Agentes (Cero Copy-Paste Manual):** El Orquestador **nunca** pedirá al usuario que copie y pegue prompts en otras ventanas. Toda tarea o corrección pendiente en `TASKS.md` se despacha directamente invocando sub-agentes en segundo plano (`invoke_subagent`) dedicados exclusivamente al módulo correspondiente (`SCInsta/`, `push-server/`, `dm-listener/` o `ios-signer/`).
2. **Estructura del Prompt de Sub-Agente:** Cada invocación a un sub-agente trabajador debe inyectar:
   - **Alcance estricto:** Directorio y archivos exactos que puede crear o modificar (prohibiendo tocar `ORCHESTRATOR.md` y `TASKS.md`).
   - **Contratos aplicables:** Copia explícita de las reglas de interfaz (`Contrato A`, `B`, `C` o `D`) que debe respetar.
   - **Restricciones negativas:** Qué tiene prohibido hacer (ej. no tocar otros módulos, no hacer llamadas HTTP activas a Meta en Módulo 2, no incluir `FLEXing` en producción en Módulo 0).
3. **Auditoría Post-Entrega y Reporte Ejecutivo:** Cuando el sub-agente finalice, el Orquestador audita directamente los archivos generados/modificados contra `ORCHESTRATOR.md`, actualiza `TASKS.md` y reporta al usuario únicamente el resumen de verificación o decisiones que requieran su aprobación explícita (como `git push`, despliegue en servidor remoto o pruebas en dispositivo físico).
