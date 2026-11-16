# TASKS.md — Panel de Control y Seguimiento del Orquestador

> **Documentos Rectores:** [`ORCHESTRATOR.md`](./ORCHESTRATOR.md) | [`SPEC.md`](./SPEC.md)  
> **Administrado por:** Agente Orquestador (Lead Architect & Integration Manager)

---

## Estado General de Módulos

| Módulo | Directorio Objetivo | Contratos Asociados | Estado | Bloqueos / Observaciones |
| :--- | :--- | :--- | :--- | :--- |
| **Módulo 0** | `/SCInsta` (Raíz del repo) | Contrato A, Contrato D | ✅ Auditado / Pushed | `git push origin main` completado. |
| **Fase 1** | `/ios-signer/setup-debian-infra.sh` | Base Debian Server | ✅ Auditado / Pushed | Script de aprovisionamiento Debian validado. |
| **Módulo 1** | `/push-server` | Contrato A, Contrato B | ✅ Auditado / Pushed | `server.js`, `sw.js`, `manifest.json`, `index.html` y servicios `systemd` auditados. |
| **Módulo 2** | `/dm-listener` | Contrato B, Contrato C | ✅ Auditado / Pushed | `listener.js`, plantillas JSON y `scinsta-listener.service` auditados. |
| **Módulo 3** | `/ios-signer` | Contrato B, Contrato D | ✅ Auditado / Pushed | `resign.sh`, `netmuxd.service`, `signer.env.example` y `crontab.txt` auditados. |

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
- [x] Creación y validación de [`url_scheme.plist`](./url_scheme.plist) en la raíz del repositorio (`CFBundleURLName = com.scinsta.urlscheme`, `CFBundleTypeRole = Editor`, `CFBundleURLSchemes = ["scinsta"]`).
- **Estado:** ✅ **Auditado por el Orquestador — Listo para compilar y probar en dispositivo.**

---

## Fase 1: Preparación del Entorno Base en Debian Server
- [x] Script de instalación de dependencias de sistema (`nodejs`, `npm`, `docker.io`, `usbmuxd`, `libimobiledevice6`, `libimobiledevice-utils`, `avahi-daemon`, `cloudflared`, etc.) en [`ios-signer/setup-debian-infra.sh`](./ios-signer/setup-debian-infra.sh).
- [x] Automatización de estructura de directorios `/home/<usuario>/scinsta-infra/{push-server,dm-listener,ios-signer}` en [`ios-signer/setup-debian-infra.sh`](./ios-signer/setup-debian-infra.sh).

---

## Fase 2: Módulo 1 — Servidor Receptor Web Push y PWA para iOS (`/push-server`)
**Contratos aplicables:** `Contrato A`, `Contrato B`

- [x] Inicialización del proyecto Node.js/Express ([`push-server/package.json`](./push-server/package.json)), generación de llaves VAPID, configuración de [`.env.example`](./push-server/.env.example) (`PORT=3000`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`, `WEBHOOK_SECRET`, `APP_URL_SCHEME=scinsta`) y persistencia en `subscriptions.json`.
- [x] Implementación de `POST http://127.0.0.1:3000/api/notify` en [`push-server/server.js`](./push-server/server.js):
  - Validación estricta de cabecera `Authorization: Bearer <WEBHOOK_SECRET>`.
  - Recepción del payload `{ messageId, senderName, text, threadId, timestamp }`.
  - Regla de construcción de `targetUrl`:
    - Si `threadId` es un string no vacío → `scinsta://direct-thread?id=${threadId}`
    - Si `threadId` es `null` o vacío → `scinsta://direct-inbox`
  - Purga automática de suscripciones caducadas ante HTTP `404` / `410`.
- [x] Implementación de Frontend PWA ([`manifest.json`](./push-server/public/manifest.json), [`sw.js`](./push-server/public/sw.js), [`index.html`](./push-server/public/index.html), `icon-192.png`, `icon-512.png`) con apertura automática del `targetUrl` al tocar la notificación en iOS.
- [x] Configuración de unidades `systemd`: [`scinsta-push.service`](./push-server/systemd/scinsta-push.service) y [`scinsta-tunnel.service`](./push-server/systemd/scinsta-tunnel.service) (`cloudflared`).
- **Estado:** ✅ **Auditado por el Orquestador — Listo para despliegue en Debian Server.**

---

## Fase 3: Módulo 2 — Listener Pasivo Ultra-Ligero de DMs (`/dm-listener`)
**Contratos aplicables:** `Contrato B`, `Contrato C`

- [x] Configuración de Playwright Chromium *headless* con persistencia de sesión (`cookies.json`) y bloqueo de recursos pesados/telemetría (`image`, `media`, `font`, `stylesheet`, `/logging`, `falco`, `/bz`) en [`dm-listener/listener.js`](./dm-listener/listener.js).
- [x] Cumplimiento estricto del **Contrato C (Seguridad Pasiva)** en [`dm-listener/listener.js`](./dm-listener/listener.js):
  - **Cero llamadas HTTP activas** (`fetch`, `axios`, `XHR`) hacia `i.instagram.com` o `www.instagram.com/api/...` (con bloqueo explícito en runtime).
  - Resolución de identidad exclusivamente mediante intercepción pasiva `page.on('response')` de `/api/v1/direct_v2/inbox` y `/api/v1/direct_v2/threads/`, o lectura pasiva del DOM renderizado (`div[role="list"] div[role="listitem"]` tras `800ms`) con fallback `"Nueva solicitud de mensaje"`, persistiendo en `users_cache.json`.
- [x] Interceptor de *frames* WebSocket/MQTT (`edge-chat.instagram.com` / `/ig_message_sync`) con limpieza de caracteres de control (`[\x00-\x1F]+`) y buffer circular en memoria de los últimos **500 `item_id`** procesados.
- [x] Despacho de eventos nuevos y alerta única de sesión expirada (`threadId: null`) hacia `POST http://127.0.0.1:3000/api/notify` y unidad `systemd` ([`scinsta-listener.service`](./dm-listener/systemd/scinsta-listener.service)).
- **Estado:** ✅ **Auditado por el Orquestador — Listo para despliegue en Debian Server.**

---

## Fase 4: Módulo 3 — Auto-Signer Inalámbrico iOS (`/ios-signer`)
**Contratos aplicables:** `Contrato B`, `Contrato D`

- [x] Despliegue automatizado del contenedor Docker `anisette-v3-server` escuchando en `127.0.0.1:6969` en [`ios-signer/setup-debian-infra.sh`](./ios-signer/setup-debian-infra.sh).
- [x] Configuración del servicio [`ios-signer/systemd/netmuxd.service`](./ios-signer/systemd/netmuxd.service) (`127.0.0.1:27015`) e integración con `AltServer-Linux`.
- [x] Creación del script [`ios-signer/resign.sh`](./ios-signer/resign.sh) cumpliendo el **Contrato D**:
  - Artefacto de entrada: `/home/<usuario>/scinsta-infra/ios-signer/SCInsta.ipa` (con verificación `unzip -l` sin `FLEXing.dylib`/`libflex.dylib` y sin `PlugIns`).
  - Variables de entorno: `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` y `ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969`.
  - Hasta 4 reintentos cada 30 minutos; en caso de fallo total, disparo de alerta a `POST http://127.0.0.1:3000/api/notify` con `threadId: null`.
- [x] Plantilla de configuración [`ios-signer/signer.env.example`](./ios-signer/signer.env.example) y programación en `cron` (`0 4 */5 * *`) en [`ios-signer/crontab.txt`](./ios-signer/crontab.txt).
- **Estado:** ✅ **Auditado por el Orquestador — Listo para despliegue en Debian Server.**
