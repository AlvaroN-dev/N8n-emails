// WF2 - "Validate input"
// El webhook interno ya respondio 202, asi que una entrada invalida no tiene a quien contestar: se hace fallar
// la ejecucion (queda en rojo y WF3 la registra). Un llamante autenticado que envia basura es un bug, no un caso normal.
const body = $input.first().json.body;
const id = body !== null && typeof body === 'object' ? body.ticket_id : undefined;

if (!Number.isInteger(id) || id <= 0) {
  throw new Error('VALIDATION: ticket_id must be a positive integer');
}
return [{ json: { ticket_id: id } }];
