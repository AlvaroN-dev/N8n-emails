'use strict';
// Ayudas para definir workflows de n8n como codigo. Los esquemas (typeVersion y nombres de parametros)
// se han leido de las definiciones reales de los nodos en la imagen n8nio/n8n:2.42.6.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const SRC = __dirname;

// IDs deterministas: regenerar el JSON no cambia los ids de los nodos (diffs limpios en Git).
const stableId = (seed) => {
  const h = crypto.createHash('sha1').update(seed).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};

// Lee n8n/src/code/<file> e inlinea las lineas `// @include <snippet>` con n8n/src/snippets/<snippet>.
function loadCode(file, vars = {}) {
  let raw = fs.readFileSync(path.join(SRC, 'code', file), 'utf8');
  // Plantillas: __CLAVE__ se sustituye por vars.CLAVE (p. ej. el nombre de la etapa en los nodos de fallo).
  raw = raw.replace(/__([A-Z_]+)__/g, (m, key) => {
    if (!(key in vars)) throw new Error(`Falta la variable ${key} para ${file}`);
    return vars[key];
  });
  return raw.replace(/^\/\/ @include (\S+)[ \t]*$/gm, (_, snippet) =>
    fs.readFileSync(path.join(SRC, 'snippets', snippet), 'utf8').trimEnd());
}

// Credenciales: se referencian por id (las crea scripts/import-n8n.ps1 con estos mismos ids).
const CREDENTIALS = {
  djangoApiKey: { id: 'credDjangoApiKey1', name: 'Django API Key' },
  intakeWebhookToken: { id: 'credIntakeWebhk01', name: 'Intake Webhook Token' },
  internalWebhookToken: { id: 'credInternalWebh1', name: 'Internal Webhook Token' },
  smtp: { id: 'credSmtpMailpit01', name: 'Mailpit SMTP' },
  // Una sola credencial para el LLM: scripts/import-n8n.ps1 la rellena con el proveedor elegido en LLM_PROVIDER
  // (mock | gemini). Cambiar de proveedor NO requiere tocar el workflow.
  llm: { id: 'credLlmProvider01', name: 'LLM provider (OpenAI-compatible)' },
};

class Workflow {
  constructor({ id, name, settings = {} }) {
    this.id = id;
    this.name = name;
    this.settings = { executionOrder: 'v1', ...settings };
    this.nodes = [];
    this.connections = {};
  }

  add(name, type, typeVersion, position, parameters, extra = {}) {
    if (this.nodes.some((n) => n.name === name)) throw new Error(`Nodo duplicado: ${name}`);
    this.nodes.push({ parameters, id: stableId(`${this.id}:${name}`), name, type, typeVersion, position, ...extra });
    return this;
  }

  webhook(name, position, { path: urlPath, credential, responseMode, options = {} }) {
    return this.add(name, 'n8n-nodes-base.webhook', 2.2, position,
      { httpMethod: 'POST', path: urlPath, authentication: 'headerAuth', responseMode, options },
      { webhookId: stableId(`${this.id}:${name}:webhook`), credentials: { httpHeaderAuth: credential } });
  }

  code(name, position, file, vars = {}) {
    return this.add(name, 'n8n-nodes-base.code', 2, position,
      { language: 'javaScript', mode: 'runOnceForAllItems', jsCode: loadCode(file, vars) });
  }

  errorTrigger(name, position) {
    return this.add(name, 'n8n-nodes-base.errorTrigger', 1, position, {});
  }

  // Nodo If con una unica condicion booleana: la expresion debe devolver true/false.
  ifTrue(name, position, expression) {
    return this.add(name, 'n8n-nodes-base.if', 2.3, position, {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{
          id: stableId(`${this.id}:${name}:condition`),
          leftValue: `={{ ${expression} }}`,
          rightValue: '',
          operator: { type: 'boolean', operation: 'true', singleValue: true },
        }],
        combinator: 'and',
      },
      options: {},
    });
  }

  // Peticion HTTP autenticada con una credencial "Header Auth".
  http(name, position, { method, url, credential, bodyExpression, timeout, fullResponse = false, neverError = false,
    onError, retry }) {
    const options = { timeout };
    if (fullResponse || neverError) options.response = { response: { fullResponse, neverError } };
    const parameters = {
      method,
      url,
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      options,
    };
    if (bodyExpression) {
      Object.assign(parameters, { sendBody: true, contentType: 'json', specifyBody: 'json', jsonBody: `={{ ${bodyExpression} }}` });
    }
    const extra = { credentials: { httpHeaderAuth: credential } };
    if (onError) extra.onError = onError;
    if (retry) Object.assign(extra, { retryOnFail: true, maxTries: retry.maxTries, waitBetweenTries: retry.waitMs });
    return this.add(name, 'n8n-nodes-base.httpRequest', 4.5, position, parameters, extra);
  }

  // Responde al cliente con { respond: { statusCode, body } } del item entrante.
  respondFromItem(name, position) {
    return this.add(name, 'n8n-nodes-base.respondToWebhook', 1.5, position, {
      respondWith: 'json',
      responseBody: '={{ JSON.stringify($json.respond.body) }}',
      options: { responseCode: '={{ $json.respond.statusCode }}' },
    });
  }

  noOp(name, position) {
    return this.add(name, 'n8n-nodes-base.noOp', 1, position, {});
  }

  // "Basic LLM Chain" con prompt propio. El mensaje de sistema NO debe llevar llaves: LangChain las interpreta como variables.
  llmChain(name, position, { systemMessage, textExpression, onError }) {
    const extra = onError ? { onError } : {};
    return this.add(name, '@n8n/n8n-nodes-langchain.chainLlm', 1.9, position, {
      promptType: 'define',
      text: `={{ ${textExpression} }}`,
      hasOutputParser: false,
      needsFallback: false,
      messages: { messageValues: [{ type: 'SystemMessagePromptTemplate', message: systemMessage }] },
    }, extra);
  }

  // Modelo de chat OpenAI-compatible. responsesApiEnabled=false: usa Chat Completions (/chat/completions), que es lo
  // que implementan Gemini (modo compatible) y el LLM simulado; la Responses API de OpenAI no.
  openAiChatModel(name, position, { model, credential, timeoutMs, maxRetries, maxTokens, temperature = 0 }) {
    return this.add(name, '@n8n/n8n-nodes-langchain.lmChatOpenAi', 1.3, position, {
      model: { __rl: true, mode: 'id', value: model },
      responsesApiEnabled: false,
      options: { temperature, maxTokens, timeout: timeoutMs, maxRetries },
    }, { credentials: { openAiApi: credential } });
  }

  emailSend(name, position, { credential, fromExpression, toExpression, subjectExpression, textExpression, onError }) {
    const extra = { credentials: { smtp: credential } };
    if (onError) extra.onError = onError;
    return this.add(name, 'n8n-nodes-base.emailSend', 2.1, position, {
      resource: 'email',
      operation: 'send',
      fromEmail: `={{ ${fromExpression} }}`,
      toEmail: `={{ ${toExpression} }}`,
      subject: `={{ ${subjectExpression} }}`,
      emailFormat: 'text',
      text: `={{ ${textExpression} }}`,
      options: { appendAttribution: false },
    }, extra);
  }

  stopAndError(name, position, messageExpression) {
    return this.add(name, 'n8n-nodes-base.stopAndError', 1, position,
      { errorType: 'errorMessage', errorMessage: `={{ ${messageExpression} }}` });
  }

  connect(from, to, outputIndex = 0) {
    const names = new Set(this.nodes.map((n) => n.name));
    if (!names.has(from) || !names.has(to)) throw new Error(`Conexion invalida: ${from} -> ${to}`);
    const main = (this.connections[from] = this.connections[from] || { main: [] }).main;
    while (main.length <= outputIndex) main.push([]);
    main[outputIndex].push({ node: to, type: 'main', index: 0 });
    return this;
  }

  // Conexion de un sub-nodo de IA (p. ej. el modelo) hacia el nodo raiz (la cadena).
  connectAi(subNode, rootNode, type = 'ai_languageModel') {
    const names = new Set(this.nodes.map((n) => n.name));
    if (!names.has(subNode) || !names.has(rootNode)) throw new Error(`Conexion de IA invalida: ${subNode} -> ${rootNode}`);
    this.connections[subNode] = { ...(this.connections[subNode] || {}), [type]: [[{ node: rootNode, type, index: 0 }]] };
    return this;
  }

  toJSON() {
    return {
      id: this.id,
      name: this.name,
      active: false,
      nodes: this.nodes,
      connections: this.connections,
      settings: this.settings,
      pinData: {},
    };
  }
}

module.exports = { Workflow, CREDENTIALS, loadCode, stableId };
