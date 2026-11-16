# TASKS.md — Panel de Control y Seguimiento del Orquestador

> **Documento Rector:** [`ORCHESTRATOR.md`](./ORCHESTRATOR.md)  
> **Administrado por:** Agente Orquestador (Lead Architect & Integration Manager)

---

## Estado General de Módulos

| Módulo | Directorio Objetivo | Contratos Asociados | Estado | Bloqueos / Observaciones |
| :--- | :--- | :--- | :--- | :--- |
| **Módulo 0** | `/SCInsta` (Raíz del repo) | Contrato A, Contrato D | ✅ Auditado / Listo | Listo para compilar (`./build.sh sideload`) y probar en dispositivo. |
| **Fase 1** | `/home/<usuario>/scinsta-infra` | Base Debian Server | ⏳ Pendiente | Requiere provisión en servidor Debian (o generación local en carpetas). |
| **Módulo 1** | `/push-server` | Contrato A, Contrato B | ⏳ Pendiente | Depende de Fase 1. |
| **Módulo 2** | `/dm-listener` | Contrato B, Contrato C | ⏳ Pendiente | Depende de Módulo 1 (`POST /api/notify`). |
| **Módulo 3** | `/ios-signer` | Contrato B, Contrato D | ⏳ Pendiente | Depende de IPA de Módulo 0 y webhook de Módulo 1. |

---

## Fase 0: Módulo 0 — Empaquetado IPA (`com.scinsta.app`), Bundle ID Spoofer y Keychain Sanitizer
**Contratos aplicables:** `Contrato A`, `Contrato D`

- [x] Hook nativo `%hook NSBundle` (`-bundleIdentifier` -> `@"com.burbn.instagram"` para `mainBundle`) en [`src/Features/General/BundleSpoof.xm`](./src/Features/General/BundleSpoof.xm).
- [x] Interceptores `MSHookFunction` en `%ctor` (`SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`) en [`src/Features/General/BundleSpoof.xm`](./src/Features/General/BundleSpoof.xm):
  - Eliminación dinámica de `kSecAttrAccessGroup` mediante `CFDictionaryCreateMutableCopy` para redirigir al Keychain privado local de `com.scinsta.app`.
  - Sanitización en `SecItemCopyMatching` cuando `status == errSecSuccess` pero `*result` es `NULL` o `kCFNull` (retornando `errSecItemNotFound` para evitar crash en `igd.mdcore.orchestrator` / `String._unconditionallyBridgeFromObjectiveC`).
- [x] Normalización en memoria `scinsta://` -> `instagram://` en `IGInstagramAppDelegate` (`-application:openURL:options:`) en [`src/Tweak.x`](./src/Tweak.x).
- [x] Actualización de [`build.sh`](./build.sh) y [`Makefile`](./Makefile):
  - `Security` incluido en `SCInsta_FRAMEWORKS`.
  - Exclusión de `FLEXing.dylib` / `libflex.dylib` en modo producción (`./build.sh sideload` sin `--dev`).
  - Limpieza de `PlugIns` con flag `-due`, Bundle ID `-b com.scinsta.app` e inyección de `url_scheme.plist`.
- [x] Creación y validación de [`url_scheme.plist`](./url_scheme.plist) en la raíz del repositorio (`CFBundleURLName = com.scinsta.urlscheme`, `CFBundleURLRole = Editor`, `CFBundleURLSchemes = ["scinsta"]`).
- **Estado:** ✅ **Auditado por el Orquestador — Listo para compilar y probar en dispositivo.**

---

## Fase 1: Preparación del Entorno Base en Debian Server
- [ ] Instalación de dependencias de sistema (`nodejs`, `npm`, `docker.io`, `usbmuxd`, `libimobiledevice6`, `libimobiledevice-utils`, `avahi-daemon`, `cloudflared`, etc.).
- [ ] Creación de estructura de directorios `/home/<usuario>/scinsta-infra/{push-server,dm-listener,ios-signer}`.

---

## Fase 2: Módulo 1 — Servidor Receptor Web Push y PWA para iOS (`/push-server`)
**Contratos aplicables:** `Contrato A`, `Contrato B`

- [ ] Inicialización del proyecto Node.js/Express, generación de llaves VAPID, configuración de `.env` (`PORT=3000`, `WEBHOOK_SECRET`, llaves VAPID) y persistencia en `subscriptions.json`.
- [ ] Implementación de `POST http://127.0.0.1:3000/api/notify`:
  - Validación estricta de cabecera `Authorization: Bearer <WEBHOOK_SECRET>`.
  - Recepción del payload `{ messageId, senderName, text, threadId, timestamp }`.
  - Regla de construcción de `targetUrl`:
    - Si `threadId` es un string no vacío → `scinsta://direct-thread?id=${threadId}`
    - Si `threadId` es `null` o vacío → `scinsta://direct-inbox`
- [ ] Implementación de Frontend PWA (`manifest.json`, `sw.js`, `index.html`) con apertura automática del `targetUrl` al tocar la notificación en iOS.
- [ ] Configuración de unidades `systemd`: `scinsta-push.service` y `scinsta-tunnel.service` (`cloudflared`).

---

## Fase 3: Módulo 2 — Listener Pasivo Ultra-Ligero de DMs (`/dm-listener`)
**Contratos aplicables:** `Contrato B`, `Contrato C`

- [ ] Configuración de Playwright Chromium *headless* con persistencia de sesión y bloqueo de recursos pesados/telemetría.
- [ ] Cumplimiento estricto del **Contrato C (Seguridad Pasiva)**:
  - **Cero llamadas HTTP activas** (`fetch`, `axios`, `XHR`) hacia `i.instagram.com` o `www.instagram.com/api/...`.
  - Resolución de identidad exclusivamente mediante intercepción pasiva `page.on('response')` de `/api/v1/direct_v2/inbox` o lectura del DOM renderizado (`div[role="list"] div[role="listitem"]`), persistiendo en `users_cache.json`.
- [ ] Interceptor de *frames* WebSocket/MQTT (`edge-chat.instagram.com` / `/ig_message_sync`) con buffer circular en memoria de los últimos **500 `item_id`** procesados.
- [ ] Despacho de eventos nuevos hacia `POST http://127.0.0.1:3000/api/notify` y unidad `systemd` (`scinsta-listener.service`).

---

## Fase 4: Módulo 3 — Auto-Signer Inalámbrico iOS (`/ios-signer`)
**Contratos aplicables:** `Contrato B`, `Contrato D`

- [ ] Despliegue del contenedor Docker `anisette-v3-server` escuchando en `127.0.0.1:6969`.
- [ ] Configuración del servicio `netmuxd.service` (`127.0.0.1:27015`) e integración con `AltServer-Linux`.
- [ ] Creación del script `resign.sh` cumpliendo el **Contrato D**:
  - Artefacto de entrada: `/home/<usuario>/scinsta-infra/ios-signer/SCInsta.ipa` (sin `FLEXing.dylib`/`libflex.dylib` y sin `PlugIns`).
  - Variables de entorno: `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` y `ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969`.
  - Hasta 4 reintentos; en caso de fallo total, disparo de alerta a `POST http://127.0.0.1:3000/api/notify` con `threadId: null`.
- [ ] Programación en `cron`: `0 4 */5 * *` (cada 5 días a las 04:00 AM).
