// WF1 - "Interpret Django response"
// Convierte la respuesta HTTP de Django en: (a) la respuesta para el cliente, (b) si hay que lanzar WF2
// y (c) el fallo a registrar, si lo hay. El nodo HTTP anterior usa "fullResponse" + "neverError",
// asi que recibimos { statusCode, headers, body } tambien con 4xx/5xx.
// @include shared.js

// Un duplicado que sigue sin procesar pasado este tiempo se considera ATASCADO (p. ej. el cliente se
// rindio por un timeout pero Django termino) y se reprocesa. Debe ser mayor que la duracion maxima de
// WF2 para que dos ejecuciones nunca coincidan.
const STALLED_AFTER_MS = 120000;

const res = $input.first().json;
const sent = $('Validate payload').first().json.ticket;
const status = Number(res.statusCode);
const body = res.body !== null && typeof res.body === 'object' ? res.body : {};
const externalId = safeExternalId(sent.external_id);

const reply = (statusCode, payload, extra = {}) => [{
  json: withFailureMessage({ respond: { statusCode, body: payload }, trigger: false, failure: null, ...extra }),
}];
const failed = (statusCode, code, message, failure) => reply(
  statusCode,
  { status: 'error', code, message },
  { failure: { node: 'Create ticket in Django', ticket_external_id: externalId, ...failure } },
);

// Alta correcta (201) o ticket ya existente (200). Se comprueba la forma de la respuesta: no se asume.
if ((status === 201 || status === 200) && Number.isInteger(body.id)) {
  const info = { ticket_id: body.id, external_id: externalId };
  if (status === 201) {
    return reply(201, { status: 'accepted', ...info }, { trigger: true, ticket_id: body.id });
  }
  const ageMs = Date.now() - Date.parse(body.created_at);
  const stalled = body.status !== 'notified' && Number.isFinite(ageMs) && ageMs > STALLED_AFTER_MS;
  return reply(200, { status: 'duplicate', ...info, reprocessing: stalled }, { trigger: stalled, ticket_id: body.id });
}

// Datos invalidos segun Django: es un error del CLIENTE, no un fallo del workflow (no se registra).
if (status === 400) {
  return reply(400, {
    status: 'error',
    code: 'validation_error',
    message: 'Invalid request data.',
    details: body.details !== undefined ? body.details : {},
  });
}

// El resto son fallos del servicio o de configuracion: se responde 502 y se registra.
if (status >= 400 && status < 500) {
  return failed(502, 'upstream_rejected',
    'The ticket service rejected the request. This is a configuration problem, not a problem with your data.',
    { type: 'http_4xx', retryable: 'no', detail: `HTTP ${status}` });
}
if (status >= 500) {
  return failed(502, 'upstream_error', 'The ticket service failed to process the request.',
    { type: 'http_5xx', retryable: 'yes', detail: `HTTP ${status}` });
}
return failed(502, 'upstream_error', 'The ticket service returned an unexpected response.',
  { type: 'unknown', retryable: 'manual', detail: `HTTP ${status}, unexpected body` });
