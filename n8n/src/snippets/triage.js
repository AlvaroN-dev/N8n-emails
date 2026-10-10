// ---- Triage: validacion de la salida de la IA, reglas de fallback y clasificacion de errores (snippets/triage.js) ----
// Requiere snippets/shared.js (errorText) y snippets/redact.js (redactPii) incluidos ANTES.
//
// REGLA CENTRAL: la salida de un modelo es DATO NO CONFIABLE. Solo se usa si cumple el contrato exacto;
// si no, se aplican reglas deterministas. El modelo nunca elige destinatarios, URLs ni acciones.

const CATEGORIES = ['billing', 'technical', 'account', 'feature_request', 'other'];
const PRIORITIES = ['low', 'medium', 'high', 'urgent'];

// Una sola linea, sin caracteres de control, maximo 280 caracteres (limite de Django).
const normalizeSummary = (value) => {
  const flat = String(value).replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
  return flat.length > 280 ? `${flat.slice(0, 277)}...` : flat;
};

// Devuelve { ok: true, triage } o { ok: false, reason }. Acepta JSON puro o dentro de un bloque ```json.
// NO extrae JSON de entre prosa: una respuesta que no es exactamente el contrato se rechaza.
const parseAiOutput = (raw) => {
  if (typeof raw !== 'string' || raw.trim() === '') return { ok: false, reason: 'ai_empty' };

  let text = raw.trim();
  const fenced = /^```(?:json)?\s*([\s\S]*?)\s*```$/i.exec(text);
  if (fenced) text = fenced[1].trim();

  let data;
  try {
    data = JSON.parse(text);
  } catch (e) {
    return { ok: false, reason: 'ai_invalid_json' };
  }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'ai_invalid_json' };

  const category = typeof data.category === 'string' ? data.category.trim().toLowerCase() : '';
  if (!CATEGORIES.includes(category)) return { ok: false, reason: 'ai_invalid_category' };

  const priority = typeof data.priority === 'string' ? data.priority.trim().toLowerCase() : '';
  if (!PRIORITIES.includes(priority)) return { ok: false, reason: 'ai_invalid_priority' };

  const summary = typeof data.summary === 'string' ? normalizeSummary(data.summary) : '';
  if (summary === '') return { ok: false, reason: 'ai_invalid_summary' };

  // Lista blanca: cualquier otra clave del modelo (send_email_to, action...) se IGNORA.
  return { ok: true, triage: { category, priority, summary } };
};

// Reglas deterministas del modo degradado (la IA no esta disponible o devolvio algo invalido).
const RULES = {
  categories: [
    ['billing', ['invoice', 'charge', 'refund', 'payment', 'billing', 'factura', 'cobro', 'reembolso', 'pago']],
    ['account', ['password', 'login', 'log in', 'sign in', 'account', 'contrasena', 'cuenta', 'acceso', 'sesion']],
    ['technical', ['error', 'bug', 'crash', 'not working', 'fails', 'failure', 'broken', 'falla', 'no funciona']],
    ['feature_request', ['feature', 'suggestion', 'would be nice', 'sugerencia', 'funcionalidad', 'mejora']],
  ],
  urgent: ['urgent', 'asap', 'immediately', 'outage', 'urgente', 'inmediato'],
  high: ['cannot', "can't", 'unable', 'blocked', 'no puedo', 'not working', 'no funciona'],
  low: ['question', 'how to', 'pregunta', 'duda', 'consulta'],
};

const fallbackTriage = (subject, message) => {
  const text = `${subject} ${message}`.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  const has = (words) => words.some((w) => text.includes(w));
  const match = RULES.categories.find(([, words]) => has(words));
  const priority = has(RULES.urgent) ? 'urgent' : has(RULES.high) ? 'high' : has(RULES.low) ? 'low' : 'medium';
  return {
    category: match ? match[0] : 'other',
    priority,
    summary: normalizeSummary(`Rules-based summary: ${subject}`),
  };
};

// Motivo (vocabulario cerrado) por el que la llamada a la IA fallo. Se guarda en el ticket.
const classifyAiError = (err) => {
  const text = errorText(err).toLowerCase();
  const http = Number(err && typeof err === 'object' ? err.httpCode || err.statusCode || err.status : NaN) || leadingStatus(text);
  if (http === 429 || /rate.?limit|\b429\b|quota|too many requests/.test(text)) return 'ai_rate_limited';
  // Incluye los textos con que n8n reescribe los errores HTTP (STATUS_CODE_MESSAGES en n8n-workflow).
  if (http === 401 || http === 403 || /\b401\b|\b403\b|unauthorized|forbidden|api key|authentication|authorization failed|check your credentials|permission/.test(text)) {
    return 'ai_auth_error';
  }
  // 400/404 del PROVEEDOR: nuestra peticion es incorrecta (clave invalida, modelo retirado o URL base erronea).
  // Gemini devuelve 400 con una clave invalida y 404 con un modelo retirado; n8n oculta el detalle del proveedor bajo
  // "Bad request..." / "The resource ... could not be found", asi que el texto no basta: es un problema de CONFIGURACION.
  if (http === 400 || http === 402 || http === 404 || http === 405
    || /bad request|could not be found|payment required|method not allowed|request is invalid/.test(text)) {
    return 'ai_config_error';
  }
  if (/timeout|timed out|etimedout|econnaborted|aborted|gateway timed out/.test(text)) return 'ai_timeout';
  if (http >= 500 || /\b5\d\d\b|server error|overloaded|unavailable|not able to process your request|failed to process your request|bad gateway/.test(text)) {
    return 'ai_provider_error';
  }
  return 'ai_error';
};
