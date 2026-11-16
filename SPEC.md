# SPEC.md — Especificación Técnica Integral: Ecosistema Autónomo SCInsta

## 0. Visión General de la Arquitectura
Sistema desacoplado de 4 módulos diseñado para ejecutar **SCInsta** (Instagram iOS `455.0.0`) en un iPhone sin cuenta de desarrollador de pago ($99/año) ni APIs oficiales de Meta, manteniendo convivencia dual con la app oficial de Instagram, notificaciones *Calm Tech* con *Deep Linking* directo al hilo de mensajes y refirma inalámbrica automática cada 5 días desde un servidor Debian.

### Estructura del Workspace / Servidor
- `/SCInsta` (macOS / GitHub Actions): Código fuente del tweak Logos/Objective-C, `url_scheme.plist`, `Makefile` y `build.sh`.
- `/push-server` (Debian Server): Backend Node.js/Express con *Web Push* (VAPID), túnel HTTPS (`cloudflared`) y PWA instalable en Safari iOS.
- `/dm-listener` (Debian Server): Agente Playwright *headless* pasivo que intercepta *frames* MQTT/WebSocket (`edge-chat.instagram.com`) sin peticiones HTTP activas a Meta.
- `/ios-signer` (Debian Server): Pipeline de firma inalámbrica mediante Docker `Anisette V3`, `netmuxd` y `AltServer-Linux` orquestado por `cron`.

---

## Fase 0: Módulo 0 — Parche Nativo SCInsta y Empaquetado IPA (`/SCInsta`)

### 1. Hooks Nativos de Estabilidad y Spoofing (`BundleSpoof.xm`)
Compilado síncronamente dentro de `SCInsta.dylib` (enlazando `Security.framework` en `Makefile`) para eliminar condiciones de carrera al arrancar y evitar crashes en `igd.mdcore.orchestrator` bajo certificados gratuitos de 7 días:
- **Spoofing de `NSBundle`:** Interceptar `- (NSString *)bundleIdentifier` en `NSBundle`. Cuando `self == [NSBundle mainBundle]`, retornar explícitamente `@"com.burbn.instagram"`; para cualquier otro bundle delegar en `%orig`. Esto permite que `MobileConfig` descargue los activos de interfaz (íconos de barra inferior) correctamente desde el primer milisegundo.
- **Sanitización de Keychain (`Security.framework` vía `fishhook` `rebind_symbols` en `%ctor`):**
  - En dispositivos sin jailbreak (*sideloaded*), `MSHookFunction` sobre funciones del `dyld_shared_cache` provoca `EXC_BAD_ACCESS / SIGKILL (CODESIGNING: Invalid Page)`. Por ello se utiliza `fishhook` (`src/fishhook.h` y `src/fishhook.c`, incluidos en `$(TWEAK_NAME)_FILES` de `Makefile`) para reescribir punteros únicamente en las secciones escribibles `__DATA` / `__DATA_CONST` (`__la_symbol_ptr` y `__nl_symbol_ptr`).
  - Interceptar `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate` y `SecItemDelete`.
  - Crear una copia mutable (`CFDictionaryCreateMutableCopy`) de los diccionarios de consulta/atributos cuando contengan `kSecAttrAccessGroup`, eliminar `kSecAttrAccessGroup` para redirigir al Keychain privado local de `com.scinsta.app` (permitido en firmas gratuitas), invocar la función original y liberar memoria con `CFRelease`.
  - En `SecItemCopyMatching`, si `status == errSecSuccess` pero `*result == NULL` o `*result == kCFNull`, limpiar `*result = NULL` y retornar `errSecItemNotFound` (`-25300`) para evitar el crash `-[... length]: unrecognized selector` en `String._unconditionallyBridgeFromObjectiveC` dentro de `igd.mdcore.orchestrator`.
  - Ejecutar explícitamente `%init` dentro de `%ctor` junto con `rebind_symbols(rebindings, 4)`.

### 2. Normalización Interna de Deep Links (`Tweak.x`)
- En `%hook IGInstagramAppDelegate`, interceptar `application:openURL:options:`.
- Si la URL entrante usa el esquema `scinsta://` (ej. `scinsta://direct-thread?id=<threadId>` o `scinsta://direct-inbox`), reescribir en memoria el esquema a `instagram://` antes de entregarla a `%orig`, garantizando que el enrutador interno de Meta procese la navegación profunda sin rechazar el esquema personalizado.

### 3. Esquema URL Exclusivo (`url_scheme.plist`)
Archivo XML `PropertyList` en la raíz del repositorio:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>CFBundleURLName</key>
			<string>com.scinsta.urlscheme</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>scinsta</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

### 4. Empaquetado Limpio para Producción y AltServer-Linux (`Makefile` y `build.sh`)
- **`Makefile`:** Excluir el submódulo `modules/FLEXing` en compilaciones de producción (`SIDELOAD=1`), compilándolo únicamente si se pasa `DEV=1`. Asegurar `Security` en `$(TWEAK_NAME)_FRAMEWORKS`.
- **`build.sh`:** Excluir `FLEXing.dylib` y `libflex.dylib` en producción. Invocar `cyan` con:
  - `-b com.scinsta.app` (Bundle ID secundario para instalar en paralelo con la app oficial de la App Store).
  - `-due` (incluyendo `-e` / `--remove-extensions` para eliminar `PlugIns/*.appex` incompatibles con cuentas gratuitas).
  - `-p url_scheme.plist` (o `-l url_scheme.plist` según versión de `pyzule-rw`/`cyan`) para registrar `scinsta://`.

---

## Fase 1: Preparación del Entorno Base en Debian Server
- **Dependencias del sistema:**
  - Instalar: `nodejs`, `npm`, `docker.io`, `usbmuxd`, `libimobiledevice6`, `libimobiledevice-utils`, `avahi-daemon`, `curl`, `wget`, `jq` y el paquete oficial `cloudflared` (`.deb` `amd64`).
  - Habilitar `docker` y `avahi-daemon` mediante `systemctl` y añadir el usuario operador al grupo `docker`.
- **Directorio base en el servidor (`/home/<usuario>/scinsta-infra/`):**
  - `/push-server`
  - `/dm-listener`
  - `/ios-signer`

---

## Fase 2: Módulo 1 — Servidor Web Push y PWA iOS (`/push-server`)

### 1. Backend Express (`server.js` y `.env`)
- **Dependencias:** `express`, `web-push`, `dotenv`.
- **Variables en `.env`:** `PORT=3000`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`, `WEBHOOK_SECRET`, `APP_URL_SCHEME=scinsta`.
- **`GET /api/vapid-public-key`:** Retorna la llave pública VAPID al frontend PWA.
- **`POST /api/subscribe`:** Guarda o actualiza por `endpoint` el objeto `PushSubscription` de Safari iOS en `subscriptions.json`.
- **`POST /api/notify`:**
  - Valida `Authorization: Bearer <WEBHOOK_SECRET>` (responde `401` si es inválido).
  - Recibe JSON: `{ "messageId": "...", "senderName": "...", "text": "...", "threadId": "...|null", "timestamp": 1234567890 }`.
  - Construye `targetUrl`:
    - Si `threadId` es un string no vacío: `scinsta://direct-thread?id=${threadId}`
    - Si `threadId` es `null` o vacío: `scinsta://direct-inbox`
  - Envía notificación Web Push con `{ title: senderName || "SCInsta", body: text, tag: threadId || "system", data: { targetUrl, messageId } }`.
  - Si Apple Push devuelve HTTP `404` o `410`, elimina automáticamente esa suscripción caducada de `subscriptions.json`.

### 2. Frontend PWA Safari iOS (`public/`)
- **`manifest.json`:** `"name": "SCInsta Notifier"`, `"short_name": "SCInsta Push"`, `"display": "standalone"`, `"start_url": "/"`, `"background_color": "#000000"`, `"theme_color": "#000000"`, con ícono PNG de `192x192` y `512x512`.
- **`sw.js`:**
  - Evento `push`: ejecuta `self.registration.showNotification(payload.title, { body: payload.body, tag: payload.tag, icon: '/icon-192.png', data: payload.data })`.
  - Evento `notificationclick`: cierra la notificación (`event.notification.close()`) y abre `clients.openWindow(event.notification.data.targetUrl)`.
- **`index.html`:** Guía visual de 2 pasos para Safari iOS (*"1. Compartir > Agregar a pantalla de inicio"*, *"2. Activar notificaciones"*), conversión Base64URL a `Uint8Array`, llamada a `Notification.requestPermission()` tras clic del usuario y registro en `POST /api/subscribe`.

### 3. Persistencia `systemd`
- **`scinsta-push.service`:** Ejecuta `node server.js` escuchando en `127.0.0.1:3000` (`Restart=always`).
- **`scinsta-tunnel.service`:** Ejecuta `cloudflared tunnel` apuntando a `http://127.0.0.1:3000` para proveer HTTPS válido requerido por Safari iOS Push API.

---

## Fase 3: Módulo 2 — Listener Pasivo de DMs (`/dm-listener`)

### 1. Navegador Headless Ultra-Ligero (`listener.js`)
- Iniciar Chromium con Playwright (`headless: true`, `args`: `--no-sandbox`, `--disable-gpu`, `--disable-dev-shm-usage`, `--disable-extensions`, `--blink-settings=imagesEnabled=false`).
- Cargar cookies de sesión desde `cookies.json` en un `BrowserContext` con User-Agent estándar de escritorio y navegar a `https://www.instagram.com/direct/inbox/`.
- Interceptar todas las peticiones (`page.route('**/*', ...)`) y abortar (`route.abort()`) tipos `image`, `media`, `font`, `stylesheet` y rutas de telemetría (`/logging`, `falco`, `bz`).

### 2. Resolución Pasiva de Identidad (Prohibido hacer peticiones HTTP a Meta)
- **Prohibición absoluta:** Cero llamadas `fetch`, `axios` o `XHR` hacia `i.instagram.com` o `www.instagram.com/api/...`.
- **Captura pasiva de red (`page.on('response')`):** Inspeccionar respuestas JSON naturales de `/api/v1/direct_v2/inbox` y `/api/v1/direct_v2/threads/`, extrayendo el mapeo `user.pk` / `user.id` → `full_name` / `@username` y guardándolo en `users_cache.json`.
- **Fallback pasivo vía DOM:** Si llega un `user_id` ausente en `users_cache.json`, esperar `800ms` a que React actualice la bandeja lateral y leer el texto del primer elemento en `div[role="list"] div[role="listitem"]`. Si no figura (ej. Solicitudes ocultas), usar `"Nueva solicitud de mensaje"`.

### 3. Decodificador WebSocket / MQTT y Filtros Calm Tech
- Escuchar `page.on('websocket')` filtrando `edge-chat.instagram.com`.
- En `framereceived`, decodificar payload binario buscando `/ig_message_sync`, extraer JSON válido entre `{` y `}` limpiando caracteres de control (`[\x00-\x1F]+`).
- Procesar `deltas` filtrando únicamente mensajes nuevos con `delta.message` e `item_id` válido (descartar *typing indicators* y *read receipts*).
- Deduplicar mediante un `Set` circular en memoria de máximo `500` `item_id`.
- Aplicar filtros opcionales `whitelist.json` / `muted_threads.json` y enviar `POST http://127.0.0.1:3000/api/notify` con cabecera `Authorization: Bearer <WEBHOOK_SECRET>`.

### 4. Manejo de Sesión Expirada y `systemd`
- Si el WebSocket se cierra con error de autenticación o la página redirige a `/accounts/login/`, enviar una alerta única a `POST http://127.0.0.1:3000/api/notify` con `threadId: null` (`senderName: "SCInsta Sistema"`, `text: "Sesión expirada: actualiza cookies.json"`) y detener bucles de reconexión.
- Configurar `scinsta-listener.service` en `systemd` (`Restart=always`, `RestartSec=15`).

---

## Fase 4: Módulo 3 — Auto-Signer Inalámbrico iOS (`/ios-signer`)

### 1. Contenedor Anisette V3
- Ejecutar `docker run -d --name anisette-v3 --restart always -p 127.0.0.1:6969:6969 dadoum/anisette-v3-server`.

### 2. Demonio Inalámbrico `netmuxd`
- Instalar `x86_64-linux-netmuxd` en `/usr/local/bin/netmuxd` (`chmod +x`).
- Emparejar iPhone una única vez por USB con `idevicepair pair` (persistiendo registros en `/var/lib/lockdown`).
- Crear `netmuxd.service` en `systemd` ejecutando `/usr/local/bin/netmuxd --disable-unix --host 127.0.0.1` (puerto `27015`).

### 3. Automatización `resign.sh` + `cron`
- Instalar `AltServer-x86_64` en `/usr/local/bin/AltServer`.
- Guardar `UDID`, `APPLE_ID` y `APP_PASSWORD` (contraseña específica de app) en `/ios-signer/signer.env` (`chmod 600`).
- En `resign.sh`, exportar `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015` y `ALTSERVER_ANISETTE_SERVER=http://127.0.0.1:6969`, verificar presencia del iPhone en red con `idevice_id -l` (con hasta 4 reintentos cada 30 minutos) y ejecutar `/usr/local/bin/AltServer -u "$UDID" -a "$APPLE_ID" -p "$APP_PASSWORD" /ios-signer/SCInsta.ipa`.
- Si fallan todos los reintentos, disparar `POST http://127.0.0.1:3000/api/notify` (`threadId: null`) alertando acercar el iPhone al Wi-Fi local.
- Programar en `crontab`: `0 4 */5 * * /home/<usuario>/scinsta-infra/ios-signer/resign.sh >> /home/<usuario>/scinsta-infra/ios-signer/sign.log 2>&1`.
