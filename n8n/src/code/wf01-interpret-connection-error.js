// WF1 - "Interpret connection error"
// Salida de error del nodo "Create ticket in Django": no hubo respuesta HTTP (API caida, DNS, timeout...).
// @include shared.js

const sent = $('Validate payload').first().json.ticket;
const err = $input.first().json.error;
const c = classifyError(err);

const message = c.type === 'timeout'
  ? 'The ticket service did not respond in time. Retry the same request: it is safe to repeat.'
  : c.type === 'connection'
    ? 'The ticket service is unavailable. Retry the same request later: it is safe to repeat.'
    : 'The ticket service request failed.';

return [{
  json: withFailureMessage({
    respond: { statusCode: c.status, body: { status: 'error', code: c.code, message } },
    trigger: false,
    failure: {
      node: 'Create ticket in Django',
      type: c.type,
      retryable: c.retryable,
      ticket_external_id: safeExternalId(sent.external_id),
      detail: shortDetail(errorText(err)),
    },
  }),
}];
