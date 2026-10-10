'use strict';
// Genera n8n/workflows/*.json a partir de n8n/src/workflows/*.js.
//   node n8n/src/build.js           -> escribe los JSON
//   node n8n/src/build.js --check   -> falla (exit 1) si algun JSON difiere de lo que generaria el codigo
const fs = require('node:fs');
const path = require('node:path');

const checkOnly = process.argv.includes('--check');
const srcDir = path.join(__dirname, 'workflows');
const outDir = path.join(__dirname, '..', 'workflows');

fs.mkdirSync(outDir, { recursive: true });
let drift = 0;

for (const file of fs.readdirSync(srcDir).filter((f) => f.endsWith('.js')).sort()) {
  const wf = require(path.join(srcDir, file));
  const target = path.join(outDir, file.replace(/\.js$/, '.json'));
  const text = `${JSON.stringify(wf, null, 2)}\n`;
  if (checkOnly) {
    const current = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
    if (current !== text) {
      drift += 1;
      console.error(`DESACTUALIZADO: ${path.basename(target)} (ejecuta scripts/build-workflows.ps1)`);
    } else {
      console.log(`ok: ${path.basename(target)}`);
    }
  } else {
    fs.writeFileSync(target, text);
    console.log(`generado: ${path.basename(target)} (${wf.nodes.length} nodos)`);
  }
}
process.exit(drift > 0 ? 1 : 0);
