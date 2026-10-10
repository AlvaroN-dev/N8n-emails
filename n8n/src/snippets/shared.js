// ---- Utilidades compartidas (el builder las inlinea en cada nodo Code que hace `// @include shared.js`) ----
// Fuente unica: n8n/src/snippets/shared.js. No editar la copia dentro del JSON del workflow.

// external_id llega del cliente SIN validar: solo se propaga si tiene el formato permitido.
const safeExternalId = (value) => (typeof value === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(value) ? value : '');

// Texto corto y en una linea, apto para registrar. Nunca se vuelca un payload completo.
const shortDetail = (value) =>
  String(value === undefined || value === null ? '' : value).replace(/\s+/g, ' ').trim().slice(0, 200);

// El error de un nodo HTTP puede llegar como texto o como objeto.
const errorText = (err) => {
  if (err === undefined || err === null) return '';
  if (typeof err === 'string') return err;
  return [err.message, err.description, err.code, err.httpCode ? `HTTP ${err.httpCode}` : '']
    .filter(Boolean)
    .join(' | ');
};

// Mensaje del nodo "Stop and Error" que lee WF3. n8n SUSTITUYE el mensaje de un error si contiene (sin
// distinguir mayusculas) codigos como ECONNREFUSED, EAI_AGAIN o ENOENT. Un external_id elegido por el cliente
// o el texto de un error de red pueden contenerlos, asi que la carga va en HEXADECIMAL: ninguno de esos
// codigos puede aparecer en un texto 0-9a-f (todos incluyen alguna letra fuera de a-f).
// `type` y `retryable` son vocabulario controlado y se dejan en claro para leerlos en la interfaz.
const encodeFailure = (failure) => {
  const ascii = JSON.stringify(failure).replace(/[^\x00-\x7f]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  const hex = ascii.split('').map((ch) => ch.charCodeAt(0).toString(16).padStart(2, '0')).join('');
  return `HANDLED_FAILURE type=${failure.type} retryable=${failure.retryable} data=${hex}`;
};

// Inversa de encodeFailure (la usa WF3). Devuelve null si el mensaje no es un fallo gestionado.
const decodeFailure = (message) => {
  const m = /data=([0-9a-f]+)/.exec(String(message || ''));
  if (!m || m[1].length % 2 !== 0) return null;
  try {
    return JSON.parse(m[1].match(/../g).map((h) => String.fromCharCode(parseInt(h, 16))).join(''));
  } catch (e) {
    return null;
  }
};

// Anade `failure_message` (lo que lanzara "Stop and Error") a un item que lleve un `failure`.
const withFailureMessage = (json) => (json.failure ? { ...json, failure_message: encodeFailure(json.failure) } : json);

// Traduce un fallo de red/HTTP a: tipo de error (para el registro), respuesta al cliente y si es reintentable.
//   retryable: 'yes' = repetir es seguro (operacion idempotente) | 'no' = hay que corregir algo | 'manual' = decide una persona
// Algunos errores HTTP de n8n llegan como TEXTO que empieza por el codigo (p. ej. `404 - "{...cuerpo...}"`), sin httpCode.
const leadingStatus = (text) => {
  const m = /^\s*(\d{3})\b/.exec(text);
  return m ? Number(m[1]) : NaN;
};

const classifyError = (err) => {
  const text = errorText(err).toLowerCase();
  const http = Number(err && typeof err === 'object' ? err.httpCode || err.statusCode : NaN) || leadingStatus(text);
  // Se reconocen tanto los codigos crudos (ECONNABORTED...) como los textos "amigables" con que n8n los reescribe
  // (STATUS_CODE_MESSAGES y COMMON_ERRORS en n8n-workflow).
  if (/timeout|timed out|etimedout|econnaborted|connection was aborted|gateway timed out/.test(text)) {
    return { type: 'timeout', status: 504, code: 'upstream_timeout', retryable: 'yes' };
  }
  if (/econnrefused|enotfound|eai_again|ehostunreach|econnreset|socket hang up|getaddrinfo|network|perhaps the server is offline|perhaps it is offline|refused the connection|dns server|connection cannot be established|closed unexpectedly/.test(text)) {
    return { type: 'connection', status: 503, code: 'upstream_unavailable', retryable: 'yes' };
  }
  if (http >= 500 || /not able to process your request|failed to process your request|bad gateway|service unavailable/.test(text)) {
    return { type: 'http_5xx', status: 502, code: 'upstream_error', retryable: 'yes' };
  }
  if (http >= 400 || /authorization failed|check your credentials|forbidden|bad request|could not be found|method not allowed|payment required|request is invalid/.test(text)) {
    return { type: 'http_4xx', status: 502, code: 'upstream_rejected', retryable: 'no' };
  }
  return { type: 'unknown', status: 502, code: 'upstream_error', retryable: 'manual' };
};
