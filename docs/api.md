# Referencia de la API Django

API REST (Django 5.2 LTS + Django REST Framework 3.18) que persiste los tickets y los fallos de los workflows de n8n.

- **URL base (host):** `http://127.0.0.1:8000` · **URL base (desde n8n, red de Docker):** `http://api:8000`
- **Formato:** solo JSON (`Content-Type: application/json`). Otros tipos devuelven `415`.
- **Autenticación:** cabecera `X-API-Key: <DJANGO_API_KEY>` en todos los endpoints **excepto** `GET /api/health/`. Sin clave o con clave incorrecta → `401`. Si el servidor no tiene clave configurada, no arranca (falla cerrado).
- **Idioma de los mensajes de error:** inglés (son códigos de máquina estables; los códigos de la columna `code` no cambian).

## Formato de errores

Todos los errores tienen la misma forma:

```json
{ "status": "error", "code": "validation_error", "message": "Invalid request data.", "details": { "subject": ["This field is required."] } }
```

| HTTP | `code` | Cuándo |
|---|---|---|
| 400 | `validation_error` | Falta un campo, tipo incorrecto, valor fuera de rango. `details` indica cada campo |
| 400 | `parse_error` | JSON malformado |
| 401 | `unauthorized` | Falta la API key o es incorrecta (con cabecera `WWW-Authenticate`) |
| 404 | `not_found` | Ticket o ruta inexistente |
| 405 | `method_not_allowed` | Método HTTP no soportado |
| 409 | `not_triaged` | Se intenta marcar como notificado un ticket sin triage |
| 415 | `unsupported_media_type` | El cuerpo no es JSON |
| 500 | `internal_error` | Error inesperado. **El mensaje de la excepción nunca se devuelve ni se registra** (podría contener datos personales) |
| 503 | — | Solo en `/api/health/`: la base de datos no responde |

## Endpoints

### `GET /api/health/` — sin autenticación

```json
{ "status": "ok", "database": "ok" }
```
`503 {"status":"error","database":"unavailable"}` si PostgreSQL no responde. Tras volver PostgreSQL, la API se recupera sola (sin reiniciarse).

### `POST /api/tickets/` — alta idempotente

Cuerpo:

| Campo | Tipo | Reglas |
|---|---|---|
| `external_id` | string | Obligatorio. 1–64 caracteres, solo `A-Z a-z 0-9 . _ -`. **Clave de idempotencia** |
| `customer_email` | string | Obligatorio. Email válido, máx. 254 |
| `subject` | string | Obligatorio. 3–200, una sola línea (sin caracteres de control) |
| `message` | string | Obligatorio. 10–5000. Admite saltos de línea y tabulaciones |
| `source` | string | Opcional: `web`, `email` o `api` (por defecto `api`) |

Los números u otros tipos donde se espera texto se **rechazan** (`subject: 12345` → `400`).

- `201` ticket creado, `duplicate: false`.
- `200` ya existía un ticket con ese `external_id`: se devuelve el existente con `duplicate: true` y **no se crea nada**. Es seguro con peticiones simultáneas (restricción `UNIQUE` en la base de datos; probado con 5 peticiones en paralelo → 1 ticket).

### `GET /api/tickets/{id}/`

Respuesta real de un ticket ya clasificado y notificado:

```json
{
  "id": 2,
  "external_id": "SMOKE-20261009120023-a",
  "customer_email": "smoke.test@example.com",
  "subject": "Smoke test: cannot log in",
  "message": "This is a synthetic smoke test message to verify the API end to end.",
  "source": "api",
  "status": "notified",
  "category": "technical",
  "priority": "high",
  "summary": "Customer cannot log in (synthetic smoke test).",
  "triage_source": "ai",
  "triage_reason": "",
  "triaged_at": "2026-10-09T17:00:23.975872Z",
  "notified_at": "2026-10-09T17:00:24.000492Z",
  "created_at": "2026-10-09T17:00:23.899595Z"
}
```
`status` avanza `received → triaged → notified` y nunca retrocede.

### `PATCH /api/tickets/{id}/triage/` — guarda el triage

| Campo | Valores |
|---|---|
| `category` | `billing`, `technical`, `account`, `feature_request`, `other` |
| `priority` | `low`, `medium`, `high`, `urgent` |
| `summary` | string, 1–280, una línea |
| `source` | `ai` o `fallback` (clasificación por reglas cuando la IA falla o devuelve algo inválido) |
| `reason` | Opcional, máx. 200. Motivo del *fallback* |

Idempotente: repetirlo sobrescribe con los mismos datos. Valores fuera de la lista → `400` y el ticket **no se modifica**.

### `POST /api/tickets/{id}/notified/` — guardia anti-duplicados del correo

Sin cuerpo. Marca el ticket como notificado **una sola vez** con un `UPDATE` atómico:

- Primera llamada: `200 {"already_notified": false, "notified_at": "..."}`.
- Siguientes: `200 {"already_notified": true, "notified_at": "<la misma fecha>"}` (la fecha no se pisa).
- Ticket sin triage previo: `409 not_triaged`.

### `POST /api/error-events/` y `GET /api/error-events/`

Registro de fallos de workflows (lo usa WF3, ver `docs/wf03-error-monitoring.md`). Ya vienen saneados, pero Django **vuelve a redactar** correos y teléfonos del `message` antes de guardar (defensa en profundidad) y lo trunca a 500 caracteres en vez de rechazarlo.

| Campo | Reglas |
|---|---|
| `workflow_name` | Obligatorio |
| `error_type` | Obligatorio: `http_4xx`, `http_5xx`, `timeout`, `connection`, `validation`, `ai_output`, `smtp`, `unknown` |
| `retryable` | `no` (por defecto: corregir dato/config), `yes` (idempotente, reprocesable), `manual` (tiene efectos laterales, decide una persona) |
| `ticket_id` | Opcional. Entero ≥ 1 (o `null`): el ticket afectado, para poder reprocesarlo. Cualquier otro valor → `400` |
| `workflow_id`, `execution_id`, `failed_node`, `message`, `ticket_external_id` | Opcionales |

**Idempotente por ejecución de n8n.** La clave es `(workflow_id, execution_id)` (cuando `execution_id` no está vacío; restricción `UNIQUE` en PostgreSQL). `201` si el evento es nuevo; si ya existía, `200` con `"duplicate": true` y **no se modifica** el registro original. Así WF3 puede reintentar el `POST` sin duplicar eventos (probado con 5 peticiones simultáneas → 1 fila).

`GET` admite filtros `error_type`, `workflow_name`, `ticket_external_id`, `ticket_id` y paginación `limit`/`offset` (50 por defecto, máx. 200). Los más recientes primero. Evento real (fallo de Django al crear un ticket, registrado por WF3):

```json
{
  "count": 1, "next": null, "previous": null,
  "results": [{
    "id": 3, "workflow_id": "wfTicketIntake01", "workflow_name": "01 - Ticket intake", "execution_id": "362",
    "failed_node": "Create ticket in Django", "error_type": "http_5xx", "retryable": "yes", "message": "HTTP 500",
    "ticket_id": null, "ticket_external_id": "QA-500-P5-172741", "created_at": "2026-10-09T22:27:42.111274Z"
  }]
}
```

## Probar la API a mano (PowerShell)

```powershell
# La clave se lee de .env sin mostrarla. Select-String devuelve un TEXTO; con
# `(Get-Content .env) -match ... -replace ...` se obtendria un ARRAY y la cabecera iria mal (401).
$key = (Select-String -Path .env -Pattern '^DJANGO_API_KEY=(.*)$').Matches[0].Groups[1].Value
$h   = @{ 'X-API-Key' = $key }

Invoke-RestMethod http://127.0.0.1:8000/api/health/

$body = @{ external_id='DEMO-1'; customer_email='ana@example.com'; subject='No puedo entrar'; message='No puedo iniciar sesion desde esta manana.' } | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:8000/api/tickets/ -Method Post -Headers $h -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
```

> **Tildes y eñes en Windows PowerShell 5.1:** si pasas `-Body $body` como *texto*, PowerShell 5.1 lo codifica con la página de códigos de Windows y `sesión` llega corrupta. Se comprobó con datos reales: enviando el cuerpo como texto, el mensaje se guardó sin las tildes correctas; enviándolo como bytes UTF-8 (como arriba) se guardó íntegro. PowerShell 7 no tiene este problema. Con `curl.exe` y un archivo UTF-8 (`--data-binary "@ticket.json"`) tampoco.

Prueba automática completa contra el servidor real: `.\scripts\smoke-api.ps1`.

---

# Webhook de entrada de n8n (WF1 · `01 - Ticket intake`)

Es el punto de entrada **público** del sistema: valida, guarda el ticket en Django y lanza el triage. Todos los códigos de esta sección están comprobados por `tests/integration/wf01-intake.ps1` (evidencia en `docs/evidence/fase3-wf01-integration.txt`).

`POST http://localhost:5678/webhook/tickets` · cabecera `X-Webhook-Token: <INTAKE_WEBHOOK_TOKEN>` · `Content-Type: application/json`

Cuerpo: igual que `POST /api/tickets/` de Django (`external_id`, `customer_email`, `subject`, `message`, `source` opcional). Los campos desconocidos se **descartan**.

| HTTP | Cuerpo | Cuándo |
|---|---|---|
| **201** | `{"status":"accepted","ticket_id":N,"external_id":"..."}` | Ticket nuevo guardado y WF2 lanzado |
| **200** | `{"status":"duplicate","ticket_id":N,"external_id":"...","reprocessing":false}` | `external_id` ya existente. **No** se relanza WF2 (evita correos duplicados) |
| **200** | idem con `"reprocessing":true` | Duplicado **atascado** (ver abajo): se relanza WF2 |
| **400** | `{"status":"error","code":"validation_error","details":{campo:[mensajes]}}` | Falta un campo, tipo incorrecto, o Django rechaza el valor. Mismo formato que Django |
| **403** | `Authorization data is wrong!` (lo genera n8n) | Token ausente o incorrecto. **No** crea ejecución |
| **404** | — | Método distinto de POST |
| **422** | `{"code":422,"message":"Failed to parse request body",...}` (lo genera n8n) | JSON malformado. Se rechaza *antes* de ejecutar el workflow |
| **500** | `{"code":0,"message":"There was a problem executing the workflow"}` (lo genera n8n) | Cuerpo mayor que `N8N_PAYLOAD_SIZE_MAX` (1 MiB). El límite **sí** se aplica y no se ejecuta nada, pero n8n usa un 500 genérico en lugar de un 413 *(limitación conocida: no se puede cambiar sin un proxy delante)* |
| **502** | `code: upstream_error` | Django respondió 5xx o algo inesperado |
| **502** | `code: upstream_rejected` | Django respondió 401/403/404/415: problema de **configuración**, no de los datos del cliente |
| **502** | `code: triage_not_started` (incluye `ticket_id`) | El ticket **sí** se guardó pero no se pudo lanzar WF2 |
| **503** | `code: upstream_unavailable` | Django inalcanzable (el DNS interno no resuelve `api`, conexión rechazada...) |
| **504** | `code: upstream_timeout` | Django no respondió en 8 s |

Los fallos 502/503/504 **no se disfrazan de éxito**: se responde el error y además la ejecución de WF1 queda en estado *error* en n8n (mensaje `HANDLED_FAILURE type=… retryable=… data=<hex>`), de modo que el workflow de errores (WF3) lo registre.

## Idempotencia y recuperación

- La clave de idempotencia es `external_id` (restricción `UNIQUE` en PostgreSQL). Probado con 5 peticiones simultáneas: un 201, cuatro 200, **un** ticket y **una** ejecución de WF2.
- **Reintentar es seguro** para los datos: reenviar la misma solicitud nunca crea un segundo ticket.
- **No hay reintento automático** en la llamada de alta. Motivo (hallazgo del diseño): si el `POST` a Django expira pero Django *sí* termina, un reintento recibiría `duplicate` y WF2 no se lanzaría nunca. La idempotencia protege los datos, no el flujo.
- **Ticket atascado.** Un duplicado se considera atascado si **no está notificado** y tiene más de **120 s**. Entonces la respuesta lleva `reprocessing: true` y se relanza WF2. Ese umbral es mayor que la duración máxima de WF2 (90 s), así que dos ejecuciones nunca coinciden. Probado (T06 + T06b): un timeout ambiguo deja el ticket creado y sin procesar; reenviarlo pasados 120 s lo recupera sin duplicarlo.

## Webhook interno de WF2 (no público)

`POST http://localhost:5678/webhook/internal/ticket-triage` · cabecera `X-Webhook-Token: <INTERNAL_WEBHOOK_TOKEN>` · cuerpo `{"ticket_id": N}` → **202**.
Lo llama WF1 y sirve también para **reprocesar a mano** un ticket. Usa un token **distinto** del público: probado que ninguno sirve en el webhook del otro (403).
