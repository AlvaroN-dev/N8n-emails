// WF3 - "Describe failure"
// Entrada: el payload del nodo Error Trigger. Salida: el evento SANEADO que se registra en Django.
// Responde a: que workflow fallo, en que etapa, de que tipo, que se puede registrar sin riesgo y si conviene reintentar.
// @include redact.js
// @include shared.js

const input = $input.first().json;
const wf = input.workflow || {};
const exec = input.execution || null; // ejecucion que fallo
const trig = input.trigger || null; // el fallo fue al ACTIVAR el trigger: la ejecucion nunca llego a existir

const ERROR_TYPES = ['http_4xx', 'http_5xx', 'timeout', 'connection', 'validation', 'ai_output', 'smtp', 'unknown'];
const RETRYABLE = ['no', 'yes', 'manual'];
const AI_NODES = ['Prepare AI input', 'Triage with AI', 'OpenAI Chat Model', 'Validate AI output', 'AI call failed'];

const rawMessage = String(
  (exec && exec.error && exec.error.message)
  || (trig && trig.error && (trig.error.message || (trig.error.cause && trig.error.cause.message)))
  || '',
);
const lastNode = String((exec && exec.lastNodeExecuted) || (trig && trig.error && trig.error.node && trig.error.node.name) || '');

// 1) Fallo GESTIONADO por el propio workflow (mensaje HANDLED_FAILURE codificado): trae tipo, ticket y detalle fiables.
const handled = decodeFailure(rawMessage);

// 2) Fallo NO gestionado: se deduce de la etapa (ultimo nodo) y del texto del error.
const classifyRaw = () => {
  if (/^VALIDATION:/.test(rawMessage) || lastNode === 'Validate input') return { type: 'validation', retryable: 'no' };
  if (/execution.*(timed out|timeout)|timed out after \d+/i.test(rawMessage)) return { type: 'timeout', retryable: 'manual' };
  if (lastNode === 'Send notification email') return { type: 'smtp', retryable: 'manual' };
  if (AI_NODES.includes(lastNode)) return { type: 'ai_output', retryable: 'manual' };
  const c = classifyError({ message: rawMessage });
  return { type: c.type, retryable: c.retryable };
};

const info = handled
  ? {
    type: ERROR_TYPES.includes(handled.type) ? handled.type : 'unknown',
    retryable: RETRYABLE.includes(handled.retryable) ? handled.retryable : 'manual',
    node: String(handled.node || lastNode),
    detail: handled.detail,
    ticketId: handled.ticket_id,
    externalId: handled.ticket_external_id,
  }
  : { ...classifyRaw(), node: lastNode, detail: rawMessage, ticketId: null, externalId: '' };

// SANEADO: nunca se registra el payload ni datos personales; solo ids, etapa, tipo y un detalle corto y redactado.
const event = {
  workflow_id: String(wf.id || ''),
  workflow_name: String(wf.name || 'unknown workflow').slice(0, 200),
  execution_id: exec && exec.id !== undefined && exec.id !== null ? String(exec.id) : '',
  failed_node: info.node.slice(0, 200),
  error_type: info.type,
  retryable: info.retryable,
  message: redactPii(shortDetail(info.detail)).slice(0, 500),
  ticket_id: Number.isInteger(info.ticketId) && info.ticketId > 0 ? info.ticketId : null,
  ticket_external_id: safeExternalId(info.externalId),
};

const url = exec && typeof exec.url === 'string' && /^https?:\/\/\S+$/.test(exec.url) ? exec.url : '';
return [{ json: { event, execution_url: url, handled: handled !== null } }];
