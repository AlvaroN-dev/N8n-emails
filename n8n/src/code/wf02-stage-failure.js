// WF2 - "Stage failure" (plantilla: el builder sustituye los marcadores STAGE y KIND de abajo en cada nodo)
// Salida de ERROR de un nodo tecnico de WF2 (Django o SMTP). Se gestiona de forma explicita, y no se deja caer el
// error crudo de n8n, para que el registro de fallos sepa DE QUE TICKET se trataba y asi se pueda reprocesar.
//   KIND http  -> se clasifica por el error (red, timeout, 4xx, 5xx); reintentable si la operacion es idempotente
//   KIND smtp  -> tipo smtp, SIEMPRE reintento MANUAL (repetir un envio podria duplicar el correo)
// @include shared.js

const STAGE = '__STAGE__';
const KIND = '__KIND__';

const err = $input.first().json.error;
const ticketId = $('Validate input').first().json.ticket_id; // siempre disponible: es el primer nodo tras el webhook

// external_id solo existe si Get ticket llego a responder.
let externalId = '';
try {
  externalId = safeExternalId($('Get ticket').first().json.external_id);
} catch (e) {
  externalId = '';
}

const c = KIND === 'smtp' ? { type: 'smtp', retryable: 'manual' } : classifyError(err);
const failure = {
  node: STAGE,
  type: c.type,
  retryable: c.retryable,
  ticket_id: ticketId,
  ticket_external_id: externalId,
  detail: shortDetail(errorText(err)),
};

return [{ json: { failure, failure_message: encodeFailure(failure) } }];
