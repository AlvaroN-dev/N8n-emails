// ---- Redaccion de datos personales (snippets/redact.js) ----
// Se aplica al texto ANTES de enviarlo a cualquier servicio externo (el LLM). Es la misma regla que
// backend/tickets/privacy.py, que Django aplica por su lado al guardar los mensajes de error.
// Pecar de redactar de mas es lo seguro; el correo del cliente nunca viaja al LLM.
const EMAIL_RE = /[\p{L}\p{N}_.+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+/gu;
// 9+ digitos con hasta 2 separadores entre digitos. Sin puntos entre digitos: una IP (172.20.0.3) o una version no son
// telefonos. Un punto FINAL de frase si se admite ("llamame al +34 612 345 678."), pero no un punto seguido de digito
// (decimal): `(?!\w|\.\d)`. Un `(?![\w.])` dejaba SIN redactar los telefonos al final de una frase.
const PHONE_RE = /(?<![\w.])(?:\+|\()?\d(?:[\s()-]{0,2}\d){8,}(?!\w|\.\d)/g;

const redactPii = (text) =>
  String(text === undefined || text === null ? '' : text).replace(EMAIL_RE, '[email]').replace(PHONE_RE, '[phone]');
