# ticket-triage-n8n

Triage automático de tickets de soporte con **n8n** + **Django REST Framework** + **PostgreSQL** + una capa de **IA** (simulada por defecto, Gemini opcional) y correo de notificación, todo en **Docker Compose**.

> **Proyecto personal de aprendizaje y portfolio.** No es un producto ni se ha usado con clientes ni con datos reales. Todas las pruebas usan datos sintéticos. Qué está probado, qué no y con qué evidencia: [`docs/testing.md`](docs/testing.md).

Un cliente envía una solicitud; el sistema la **valida**, la **guarda** de forma idempotente, la **clasifica** (categoría, prioridad, resumen) con un modelo de IA cuya salida se trata como dato no confiable, **avisa al equipo por correo** y, si algo falla, lo **registra** sin exponer datos personales.

```
 Cliente ──POST /webhook/tickets──► n8n  WF1 intake ──► Django + DRF ──► PostgreSQL
 (X-Webhook-Token)                  │  valida, guarda,        ▲
                                    │  responde 201/400/50x   │ X-API-Key
                                    ▼                         │
                                   WF2 triage ── redacta PII ─► LLM (simulado | Gemini) ─► valida estrictamente
                                    │              └─ si falla/invalida: fallback por reglas (se declara)
                                    ├──► guarda triage ─► correo (SMTP → Mailpit) ─► marca "notificado"
                                    ▼
                                   WF3 errors ──► POST /api/error-events/  (o alerta por correo si Django cae)
```

## Qué demuestra

- **Orquestación con n8n**: 3 workflows (recepción, triage con IA + correo, monitorización de errores), definidos **como código** (`n8n/src`) y generados a JSON versionado, con detección de deriva.
- **Fiabilidad**: idempotencia por `external_id` (también con 5 peticiones simultáneas), sin reintentos automáticos donde habría efectos laterales, tiempo máximo por ejecución, fallos *gestionados* que no se disfrazan de éxito y quedan registrados.
- **IA con control de daños**: la salida del modelo se valida contra un contrato estricto (listas cerradas, claves permitidas, longitud); si no cumple se aplica un *fallback* por reglas y el correo **dice** que es modo degradado. Probado con respuestas vacías, JSON roto, categorías inventadas, 429, lentitud e **inyección de instrucciones**.
- **Seguridad y privacidad**: webhooks con token, API con clave, puertos solo en `127.0.0.1`, secretos fuera de Git, redacción de correos y teléfonos antes del LLM y en los registros de error, protección SSRF de n8n activada con lista mínima de excepciones.
- **Calidad**: 84 tests de Django, 115 unitarios de los nodos Code, más de 160 comprobaciones de integración con **fallos reales** (contenedores parados/pausados, clave errónea), pruebas de las propias pruebas (mutaciones, controles positivos) y una **instalación limpia** automatizada en un proyecto desechable.

## Requisitos

- **Windows 10/11** con **Docker Desktop** (WSL2). Probado en Windows 11 Home, Docker 29.8, Compose v5.5, Windows PowerShell 5.1.
- **Docker Desktop no arranca solo** al encender el equipo: ábrelo y espera a que diga *Engine running* antes de cualquier comando (`docker info` debe responder).
- Puertos libres en tu equipo: **5678** (n8n), **8000** (API), **8025** (Mailpit). Se pueden cambiar en `.env`.
- Unos 3 GB libres de disco (las cuatro imágenes ocupan ~2,5 GB). La primera vez se descargan (varios minutos).
- Si PowerShell bloquea los scripts: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` (solo afecta a esa ventana).

No necesitas Python ni Node en tu equipo: todo corre dentro de contenedores.

## Inicio rápido

Desde la raíz del repositorio, en PowerShell:

```powershell
# 1) Crea .env con secretos aleatorios (nunca sobrescribe uno existente; .env NO se sube a Git)
.\scripts\setup.ps1

# 2) Construye y arranca los 4 servicios; espera a que estén "healthy"
docker compose up -d --build --wait
docker compose ps

# 3) Carga las credenciales y los 3 workflows en n8n (los importa, publica, reinicia n8n y espera a que estén en marcha)
.\scripts\import-n8n.ps1
```

Opcional, para ver el editor de n8n: abre <http://localhost:5678> y crea la cuenta *owner* (es local; los webhooks funcionan sin ella).

### Probarlo

```powershell
# El token se lee de .env sin mostrarlo. Select-String devuelve un TEXTO (no uses -match sobre Get-Content: devuelve un array).
$token = (Select-String -Path .env -Pattern '^INTAKE_WEBHOOK_TOKEN=(.*)$').Matches[0].Groups[1].Value

$ticket = @{
    external_id    = 'DEMO-1'
    customer_email = 'ana@example.com'
    subject        = 'No puedo pagar mi factura'
    message        = 'Me sale un error al pagar mi factura y necesito ayuda cuanto antes.'
} | ConvertTo-Json

Invoke-RestMethod http://localhost:5678/webhook/tickets -Method Post `
    -Headers @{ 'X-Webhook-Token' = $token } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($ticket))
# -> status: accepted, ticket_id: N, external_id: DEMO-1
```

> **Tildes y eñes en PowerShell 5.1**: envía el cuerpo como bytes UTF-8 (como arriba). Si pasas `-Body $ticket` como texto, 5.1 lo codifica mal y `sesión` llega corrupta (comprobado). Con `curl.exe --data-binary "@archivo.json"` (archivo UTF-8) también funciona.

A los pocos segundos:

- **Correo**: <http://localhost:8025> (Mailpit). Asunto de la forma `[HIGH] Ticket #N (DEMO-1): …`, de `triage@tickets.local` a `support-team@example.test`.
- **Ticket clasificado** (`status: notified`, con categoría, prioridad y resumen):

  ```powershell
  $key = (Select-String -Path .env -Pattern '^DJANGO_API_KEY=(.*)$').Matches[0].Groups[1].Value
  Invoke-RestMethod http://127.0.0.1:8000/api/tickets/1/ -Headers @{ 'X-API-Key' = $key }   # cambia 1 por el ticket_id recibido
  ```

- **Ejecuciones**: en el editor de n8n, pestaña *Executions*.

Lo que pasa con entradas incorrectas (todo comprobado en `docs/evidence/`):

| Envío | Respuesta |
|---|---|
| Mismo `external_id` otra vez | `200` `duplicate` (sin segundo ticket ni segundo correo) |
| Falta un campo o un tipo es incorrecto | `400` `validation_error` con el detalle del campo |
| Token ausente o incorrecto | `403` |
| Django caído / lento / con error | `503` / `504` / `502`, y el fallo queda registrado por WF3 |

Contrato completo: [`docs/api.md`](docs/api.md).

### Probar los fallos tú mismo

Con `QA_TOOLS_ENABLED=true` (valor por defecto del `.env.example`, **solo para desarrollo**), un `external_id` que empiece por `QA-500-` hace que Django responda 500, y `QA-SLOW-` lo hace tardar 15 s (timeout). Para el LLM simulado puedes añadir al mensaje marcadores como `[[MOCK:EMPTY]]` o `[[MOCK:NOT_JSON]]` (ver [`docs/wf02-ai-triage.md`](docs/wf02-ai-triage.md)).

```powershell
# Provoca un fallo de Django y mira cómo lo registra WF3
$h = @{ 'X-Webhook-Token' = $token }
try { Invoke-RestMethod http://localhost:5678/webhook/tickets -Method Post -Headers $h -ContentType 'application/json' `
      -Body (@{ external_id='QA-500-1'; customer_email='ana@example.com'; subject='Prueba de fallo'; message='Provocando un error de Django a proposito.' } | ConvertTo-Json) } catch { $_.Exception.Message }
Invoke-RestMethod "http://127.0.0.1:8000/api/error-events/?limit=1" -Headers @{ 'X-API-Key' = $key }
```

## Usar IA real (Gemini, opcional)

Por defecto la IA es un **modelo simulado local**: sin cuentas, sin coste, determinista. Para probar IA real:

1. Crea una clave en Google AI Studio y ponla en `.env` como `GEMINI_API_KEY=...` y `LLM_PROVIDER=gemini`.
2. Ejecuta `.\scripts\import-n8n.ps1` (actualiza la credencial y reinicia n8n).
3. Vuelve a `LLM_PROVIDER=mock` + `import-n8n.ps1` para regresar al modo simulado.

> **La capa gratuita de Gemini usa el contenido que envías para mejorar productos de Google. Usa solo datos sintéticos.** Los nombres de modelo se retiran con el tiempo (aquí se usa `gemini-3.5-flash-lite`; si responde 404, cambia la línea `model:` de `n8n/src/workflows/02-ai-triage-notify.js`, ejecuta `.\scripts\build-workflows.ps1` y `.\scripts\import-n8n.ps1`). Esta prueba está en `tests/integration/wf02-gemini.ps1`.

## Variables de entorno (`.env`)

`.\scripts\setup.ps1` lo crea desde [`.env.example`](.env.example). Los `CHANGE_ME` se sustituyen por secretos aleatorios de 64 caracteres.

| Variable | Para qué |
|---|---|
| `N8N_HOST_PORT`, `API_HOST_PORT`, `MAILPIT_HOST_PORT` | Puertos en `127.0.0.1` (5678, 8000, 8025) |
| `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | Base de datos de la API |
| `DJANGO_SECRET_KEY`, `DJANGO_API_KEY` | Firma interna de Django; clave `X-API-Key` que usa n8n (la API **no arranca** sin ellas) |
| `DJANGO_ALLOWED_HOSTS`, `DJANGO_DEBUG`, `DJANGO_LOG_LEVEL` | Mantén `DJANGO_DEBUG=false` |
| `QA_TOOLS_ENABLED` | Inyección de fallos y LLM simulado. `true` solo en desarrollo; si no se define vale `false` |
| `INTAKE_WEBHOOK_TOKEN`, `INTERNAL_WEBHOOK_TOKEN` | Tokens del webhook público y del interno (distintos) |
| `LLM_PROVIDER`, `GEMINI_API_KEY` | `mock` o `gemini`; clave de Gemini (opcional) |
| `N8N_ENCRYPTION_KEY` | Cifra las credenciales dentro de n8n. **Si la pierdes, las credenciales guardadas no se pueden recuperar**: guarda una copia fuera del repositorio |

## Pruebas

```powershell
docker compose exec -T api python manage.py test --noinput   # 84 tests de Django
.\scripts\test-workflows.ps1                                 # 115 unitarios de los nodos Code + JSON al día
.\scripts\smoke-api.ps1                                      # 14 comprobaciones de la API
.\tests\integration\wf01-intake.ps1                          # WF1 (51)
.\tests\integration\wf02-triage.ps1                          # WF2 (46), IA simulada
.\tests\integration\wf03-errors.ps1                          # WF3 (22)
.\scripts\scan-secrets.ps1                                   # busca secretos en lo que entraría en Git
.\scripts\clean-install-test.ps1                             # instalación desde cero en un proyecto desechable (~7 min)
```

Las suites de integración **paran y pausan contenedores** y dejan el entorno como estaba; úsalas solo con este proyecto. La matriz completa (T01–T21, E1–E9…) con su estado real y la evidencia de cada una está en [`docs/testing.md`](docs/testing.md) y [`docs/evidence/`](docs/evidence/).

### Modificar los workflows

Los workflows se escriben en JavaScript en `n8n/src/` y se **generan** a `n8n/workflows/*.json`:

```powershell
.\scripts\build-workflows.ps1          # regenera los JSON
.\scripts\test-workflows.ps1           # comprueba que el JSON está al día y pasa los tests
.\scripts\import-n8n.ps1               # los carga en n8n
```

## Estructura

```
backend/            API Django (tickets, errores) + qa_tools (solo desarrollo: fallos inyectados, LLM simulado)
n8n/src/            workflows como código: builder, nodos Code, herramientas de prueba
n8n/workflows/      JSON generado de los 3 workflows (se importa con import-n8n.ps1)
n8n/credentials/    plantillas SIN secretos; import-n8n.ps1 las rellena desde .env
n8n/tests/          tests unitarios (node --test, dentro de la imagen de n8n)
scripts/            setup, import, build, tests, smoke, escaneo de secretos, instalación limpia
tests/integration/  suites de integración PowerShell con inyección real de fallos
docs/               api, arquitectura, WF2, WF3, seguridad, pruebas, CV y evidencias
```

## Documentación

| Documento | Contenido |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Diagramas, decisiones de diseño y alternativas descartadas |
| [`docs/api.md`](docs/api.md) | API Django y contrato del webhook |
| [`docs/wf02-ai-triage.md`](docs/wf02-ai-triage.md) | Triage con IA: contrato, fallback, defensas |
| [`docs/wf03-error-monitoring.md`](docs/wf03-error-monitoring.md) | Registro y alertas de fallos |
| [`docs/security.md`](docs/security.md) | Controles, riesgos aceptados y lista previa a exponerlo |
| [`docs/testing.md`](docs/testing.md) | Matriz de pruebas con estado real, defectos encontrados, limitaciones |
| [`docs/cv.md`](docs/cv.md) | Cómo describir este proyecto con honestidad |

## Capturas de pantalla (las haces tú)

**El repositorio no incluye capturas**: no se fabrican. Hazlas desde tu propia instancia, guárdalas en `docs/screenshots/` y enlázalas aquí si quieres. Usa solo datos sintéticos y **no captures `.env`, tokens ni claves**.

| Archivo sugerido | Qué mostrar |
|---|---|
| `01-compose-ps.png` | `docker compose ps` con los 4 servicios *healthy* |
| `02-n8n-workflows.png` | Lista de workflows en n8n, los 3 publicados |
| `03-wf01-canvas.png` | Lienzo de *01 - Ticket intake* |
| `04-wf02-canvas.png` | Lienzo de *02 - AI triage and notification* |
| `05-wf03-canvas.png` | Lienzo de *03 - Error monitoring* |
| `06-respuesta-201.png` | PowerShell: alta válida (`accepted`) y duplicado (`duplicate`) |
| `07-validacion-400.png` | PowerShell: respuesta `400 validation_error` |
| `08-mailpit.png` | Correo de triage recibido en Mailpit |
| `09-ticket-notified.png` | `GET /api/tickets/{id}/` con categoría, prioridad y resumen |
| `10-ejecuciones-ok.png` | Pestaña *Executions* de n8n con WF1 y WF2 en verde |
| `11-fallo-y-wf3.png` | Una ejecución en error (p. ej. `QA-500-1`) y la ejecución de WF3 que la registra |
| `12-error-events.png` | `GET /api/error-events/` con el evento registrado |
| `13-tests.png` | Salida de los tests de Django y de una suite de integración |

## Limitaciones conocidas

- **Entorno de desarrollo local**: HTTP en loopback, sin TLS ni *rate limiting*, Mailpit sin autenticación, n8n sobre SQLite con *task runner* interno. [`docs/security.md`](docs/security.md) lista lo que habría que cambiar antes de exponerlo.
- **Correo *at-least-once***: si el proceso muere justo entre enviar el correo y marcar el ticket como notificado, reprocesarlo enviaría un segundo correo.
- **No hay reintento automático del correo ni de la creación del ticket** (a propósito: tienen efectos laterales). Un ticket atascado se recupera reenviándolo o reprocesándolo (`docs/api.md`).
- **El registro de errores depende de Django**: si sigue caído tras los reintentos de WF3, queda la alerta por correo y el historial de n8n. Las alertas no se deduplican.
- **n8n responde 422** (JSON malformado) y un **500 genérico** (cuerpo mayor de 1 MiB) en lugar de un 413: es comportamiento de n8n.
- **El historial de ejecuciones de n8n guarda los payloads** (168 h): no uses datos reales sin reducirlo.
- **Gemini real solo se probó con datos sintéticos** y en capa gratuita; **no se probó contra un SMTP real**; **sin pruebas de carga**.
- Pendiente de validación humana: que otra persona siga este README en otra máquina, y las capturas de pantalla.

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| `error during connect … dockerDesktopLinuxEngine` | Docker Desktop no está arrancado. Ábrelo y espera a *Engine running* |
| `port is already allocated` | Otro programa usa 5678/8000/8025. Cambia el puerto en `.env` y `docker compose up -d` |
| `403` al enviar el ticket | Token incorrecto, o lo leíste con `-match` (array). Usa el `Select-String` del ejemplo. Si cambiaste `.env`, ejecuta `import-n8n.ps1` |
| La API no arranca | Faltan `DJANGO_SECRET_KEY`/`DJANGO_API_KEY` en `.env` (falla cerrado a propósito): `docker compose logs api` |
| Resultado raro justo tras importar workflows | n8n tarda unos segundos (~15 s) en poner en marcha una versión recién importada y mientras tanto puede servir la anterior; `import-n8n.ps1` ya espera a que esté lista |
| Credenciales de n8n ilegibles tras reinstalar | Cambió `N8N_ENCRYPTION_KEY`. Restaura la clave original, o vuelve a ejecutar `import-n8n.ps1` (las recrea) |
| Gemini devuelve 404 | Modelo retirado: cambia el nombre del modelo (ver arriba) |
| Quiero empezar de cero | `docker compose down -v` **borra tus tickets y la configuración de n8n** (los volúmenes). Después: `up -d --build --wait` y `import-n8n.ps1` |

## Mejoras futuras

- n8n sobre PostgreSQL, *task runners* externos y modo cola para escalar; revisar la retención de ejecuciones.
- Proxy inverso con TLS y *rate limiting* delante del webhook; ocultar el editor.
- Patrón *outbox* para el correo (entrega *exactly-once* aparente) y reintentos con *dead-letter*.
- Deduplicación de alertas y métricas (Prometheus/Grafana) sobre `error-events`.
- Un conjunto fijo de tickets de evaluación para medir la calidad de la clasificación y comparar modelos/prompts.
- CI (GitHub Actions) con los tests de Django y los unitarios; las suites de integración requieren Docker y fallos reales.
- SMTP real con credenciales propias (la plantilla ya está), panel de tickets y envío de adjuntos.

## Seguridad: antes de publicar el repositorio

1. `.\scripts\scan-secrets.ps1` debe terminar con `0 hallazgos`.
2. Si en algún momento pegaste una clave (p. ej. de Gemini) en un chat, un correo o un terminal compartido, **revócala y crea otra** antes de publicar.
3. `.env` está en `.gitignore`; comprueba con `git status` que no aparece.

## Licencia

[Apache-2.0](LICENSE).
