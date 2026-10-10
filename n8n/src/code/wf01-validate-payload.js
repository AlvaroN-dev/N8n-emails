// WF1 - "Validate payload"
// Validacion en el BORDE: solo presencia y tipo. Las reglas de negocio (longitudes, formato de email,
// valores permitidos) las aplica Django, que es la fuente de verdad.
// El formato de `details` es el mismo que devuelve Django ({campo: [mensajes]}).
const REQUIRED = ['external_id', 'customer_email', 'subject', 'message'];

const body = $input.first().json.body;
const details = {};
const add = (field, message) => {
  (details[field] = details[field] || []).push(message);
};

if (body === null || typeof body !== 'object' || Array.isArray(body)) {
  add('non_field_errors', 'Request body must be a JSON object.');
} else {
  for (const field of REQUIRED) {
    if (body[field] === undefined || body[field] === null) add(field, 'This field is required.');
    else if (typeof body[field] !== 'string') add(field, 'Not a valid string.');
  }
  if (body.source !== undefined && body.source !== null && typeof body.source !== 'string') {
    add('source', 'Not a valid string.');
  }
}

if (Object.keys(details).length > 0) {
  return [{
    json: {
      ok: false,
      respond: {
        statusCode: 400,
        body: { status: 'error', code: 'validation_error', message: 'Invalid request data.', details },
      },
    },
  }];
}

// Lista blanca: solo se reenvian los campos conocidos; cualquier otro se descarta.
const ticket = {};
for (const field of REQUIRED) ticket[field] = body[field];
if (typeof body.source === 'string') ticket.source = body.source;

return [{ json: { ok: true, ticket } }];
