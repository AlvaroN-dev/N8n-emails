'use strict';
// Ejecuta el codigo de un nodo Code (tal como queda dentro del JSON, con los @include inlineados)
// con dobles minimos de las variables globales de n8n: $input y $('Nodo').
const { loadCode } = require('../src/builder');

const api = (items) => ({
  first: () => items[0],
  last: () => items[items.length - 1],
  all: () => items,
});
const toItems = (list) => list.map((json) => ({ json }));

/**
 * @param {string} file   archivo en n8n/src/code
 * @param {object} opts   input: [json,...] (items de entrada) · nodes: { 'Nombre del nodo': [json,...] }
 *                        · vars: valores de las variables de plantilla (los marcadores de doble guion bajo)
 * @returns {Array<{json: object}>} lo que devolveria el nodo
 */
function runCode(file, { input = [], nodes = {}, vars = {} } = {}) {
  const $input = api(toItems(input));
  const $ = (name) => {
    if (!(name in nodes)) throw new Error(`El test no define el nodo "${name}"`);
    return api(toItems(nodes[name]));
  };
  // El codigo de un nodo Code usa `return` en el nivel superior: se ejecuta dentro de una funcion.
  return new Function('$input', '$', loadCode(file, vars))($input, $);
}

// Ejecuta una expresion con las utilidades de uno o varios snippets en el ambito, en el orden indicado
// (encodeFailure, classifyError, redactPii, parseAiOutput...). Por defecto solo snippets/shared.js.
function runSnippets(snippets, expression) {
  const fs = require('node:fs');
  const path = require('node:path');
  const code = snippets.map((s) => fs.readFileSync(path.join(__dirname, '..', 'src', 'snippets', s), 'utf8')).join('\n');
  return new Function(`${code}\nreturn (${expression});`)();
}
const runShared = (expression) => runSnippets(['shared.js'], expression);
const runTriage = (expression) => runSnippets(['redact.js', 'shared.js', 'triage.js'], expression);

module.exports = { runCode, runShared, runSnippets, runTriage };
