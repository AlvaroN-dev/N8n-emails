// WF1 - "Triage accepted"
// WF2 acepto el trabajo: se devuelve al cliente la respuesta ya preparada ("Interpret Django response").
const prev = $('Interpret Django response').first().json;
return [{ json: { respond: prev.respond, failure: null } }];
