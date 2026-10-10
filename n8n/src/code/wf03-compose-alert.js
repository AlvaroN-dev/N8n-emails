// WF3 - "Compose alert email"
// Salida de ERROR de "Register event in Django": el fallo NO pudo registrarse (p. ej. Django caido, justo lo que suele
// fallar). Para que no se pierda en silencio se avisa por correo con el mismo evento SANEADO. Si el SMTP tambien
// estuviera caido, el unico rastro seria el historial de ejecuciones de n8n.
// @include shared.js

const item = $input.first().json; // el item de entrada del nodo HTTP + `error`
const e = item.event;
const why = shortDetail(errorText(item.error));

const subject = `[ALERT] ${e.workflow_name}: ${e.error_type} at ${e.failed_node || 'unknown node'}`.slice(0, 200);
const ticket = e.ticket_id || e.ticket_external_id
  ? `#${e.ticket_id || '?'} (${e.ticket_external_id || 'external_id unknown'})`
  : 'not identified';
const advice = e.retryable === 'yes'
  ? 'Safe to reprocess (the operation is idempotent).'
  : e.retryable === 'manual' ? 'A person must decide: retrying may have side effects.' : 'Do NOT just retry: fix the configuration or the data first.';

const text = [
  'A workflow failed and the failure could NOT be registered in the ticket service.',
  `Registration error: ${why}`,
  '',
  `Workflow:   ${e.workflow_name} (${e.workflow_id})`,
  `Stage:      ${e.failed_node || 'unknown'}`,
  `Type:       ${e.error_type}`,
  `Retryable:  ${e.retryable}. ${advice}`,
  `Ticket:     ${ticket}`,
  `Execution:  ${e.execution_id || 'n/a'}${item.execution_url ? ` (${item.execution_url})` : ''}`,
  '',
  `Detail: ${e.message || 'n/a'}`,
  '',
  'Apart from this email, the only record is the n8n execution history.',
].join('\n');

return [{ json: { email: { from: 'Ticket Triage Monitor <monitor@tickets.local>', to: 'ops-alerts@example.test', subject, text } } }];
