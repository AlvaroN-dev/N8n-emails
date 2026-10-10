# WF3 · `03 - Error monitoring`

Es el **workflow de errores** de WF1 y WF2 (ajuste `errorWorkflow` de cada uno): cuando una ejecución falla, n8n lanza WF3 con el *Error Trigger*. Responde a las cuatro preguntas del requisito:

| Pregunta | Dónde queda |
|---|---|
| ¿Qué workflow falló y en qué etapa? | `workflow_name`, `failed_node` (la **etapa real**, no el nodo *Stop and Error* que lanzó el error) |
| ¿Qué tipo de error fue? | `error_type`: `http_4xx`, `http_5xx`, `timeout`, `connection`, `validation`, `ai_output`, `smtp`, `unknown` |
| ¿Qué es seguro registrar? | Solo ids (`execution_id`, `ticket_id`, `ticket_external_id`), etapa, tipo y un detalle **corto, de una línea y redactado** (correos y teléfonos → `[email]`/`[phone]`). Nunca el payload, el *stack* ni datos del cliente |
| ¿Reintentar o detener? | `retryable`: `yes` (operación idempotente: reprocesar es seguro) · `manual` (tiene efectos laterales, decide una persona) · `no` (corregir configuración o datos antes) |

## Flujo

```
Error Trigger → Describe failure → Register event in Django ─ok→ fin
                                          └─error (Django caído…)→ Compose alert email → Send alert email
```

- **Describe failure** decodifica el mensaje `HANDLED_FAILURE type= retryable= data=<hex>` (fallos que el propio workflow gestiona, ver abajo) o, si el error es crudo, lo **clasifica por la etapa y por el texto** (que n8n reescribe con textos genéricos: `The service was not able to process your request`, `404 - "{...}"`…).
- **Register event** hace `POST /api/error-events/`. Es **idempotente** por ejecución (`workflow_id` + `execution_id`), así que lleva **3 intentos con 5 s de espera** sin riesgo de duplicar.
- Si el registro falla (lo habitual: Django caído, justo lo que más suele fallar), **se envía un correo de alerta** al buzón de operaciones con el mismo evento saneado, y WF3 acaba en *success*. El fallo no se pierde en silencio.

## Dos formas de fallar en WF1/WF2

1. **Gestionado** (la mayoría): el nodo técnico (Django o SMTP) envía su error a un nodo *Stage failure* que construye un mensaje **codificado en hexadecimal** con la etapa, el tipo, el reintento y **el ticket afectado**, y hace fallar la ejecución con *Stop and Error*. El error crudo de n8n no dice de qué ticket se trataba; sin este paso no se podría reprocesar. Se codifica en hex porque n8n **reescribe** cualquier mensaje de error que contenga códigos como `ECONNREFUSED` o `ENOENT` (un `external_id` elegido por un cliente podría contenerlos).
2. **Crudo**: una excepción inesperada (p. ej. un nodo *Code* que lanza). WF3 la clasifica por el último nodo ejecutado y el texto.

| Etapa | Tipo | `retryable` | Motivo |
|---|---|---|---|
| `Validate input` (WF2) | `validation` | `no` | Un `ticket_id` inválido no se arregla reintentando |
| `Send notification email` | `smtp` | **`manual`** | Repetir un envío podría duplicar el correo |
| Nodos de IA | `ai_output` | `manual` | Decide una persona |
| Nodos de Django (`Get ticket`, `Save triage`, `Mark notified`, `Create ticket`) | `connection` / `timeout` / `http_5xx` → `yes`; `http_4xx` → `no` | | Las operaciones son idempotentes |
| Rechazo de configuración por el proveedor de IA | `http_4xx` | `no` | Clave inválida / modelo retirado: hay que corregirlo |
| Timeout de la ejecución completa | `timeout` | `manual` | |

## Reprocesar a partir de un evento

`GET /api/error-events/?ticket_id=<N>` → si `retryable` es `yes` o `manual` (y una persona lo decide), reprocesar con
`POST /webhook/internal/ticket-triage {"ticket_id": N}`. Es seguro: un ticket ya notificado se detiene en la guardia y uno ya triado reutiliza su triage. Probado (E2): un fallo del SMTP registra el ticket; tras recuperar el servicio, reprocesarlo lo completa con **un solo correo**.

## Comportamientos reales observados (no supuestos)

- **En n8n 2.x el workflow de errores debe estar PUBLICADO.** Si no, n8n registra `Workflow "wfErrorMonitor03" is not active and cannot be executed` y no lo ejecuta (la documentación de 1.x decía que bastaba guardarlo). `scripts/import-n8n.ps1` publica los tres workflows.
- **Sin bucles.** Con Django caído **y** SMTP sin responder, WF3 no puede registrar ni avisar: su propia ejecución queda en *error* (visible en n8n) y **no se encadena** otra (comprobado, E9: 1 ejecución de WF3).
- **Ventana de reintento.** Si Django vuelve durante los reintentos de WF3, el evento se registra y no hay alerta; si no, llega la alerta. Nunca ninguna de las dos (E6).

## Limitaciones conocidas

- **El registro depende de Django.** Si Django está caído más tiempo que los reintentos de WF3, no hay evento en la base de datos: queda la **alerta por correo** y, además, el historial de ejecuciones de n8n (retención de 7 días, `EXECUTIONS_DATA_MAX_AGE=168`).
- Si Django **y** el SMTP fallan a la vez, el único rastro es el historial de n8n.
- No hay desduplicación de alertas: un incidente largo puede enviar una alerta por cada ejecución fallida.
- La clasificación de errores crudos depende de los textos de n8n 2.42.6 (`n8n/src/snippets/shared.js`, con tests); una versión futura podría cambiarlos.
