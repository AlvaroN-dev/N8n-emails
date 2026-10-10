// WF1 - "Triage not started"
// Salida de error del nodo "Start triage (WF2)": el ticket YA esta guardado, pero no se pudo lanzar su
// procesamiento. No se oculta: se responde 502 y se registra el fallo. Reenviar la misma solicitud lo
// reprocesa pasado el periodo de gracia, y nunca duplica el ticket.
// @include shared.js

const prev = $('Interpret Django response').first().json;
const err = $input.first().json.error;
const c = classifyError(err);
const info = prev.respond && prev.respond.body ? prev.respond.body : {};

return [{
  json: withFailureMessage({
    respond: {
      statusCode: 502,
      body: {
        status: 'error',
        code: 'triage_not_started',
        message: 'The ticket was stored but its processing could not be started. Resend the same request later to reprocess it.',
        ticket_id: prev.ticket_id,
        external_id: safeExternalId(info.external_id),
      },
    },
    failure: {
      node: 'Start triage (WF2)',
      type: c.type,
      retryable: 'yes',
      ticket_id: prev.ticket_id,
      ticket_external_id: safeExternalId(info.external_id),
      detail: shortDetail(errorText(err)),
    },
  }),
}];
