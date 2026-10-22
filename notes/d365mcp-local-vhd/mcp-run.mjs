// Runs a list of D365 MCP tool calls in one fresh MCP session (form tools are stateful per session).
// Token: Azure CLI login (az account get-access-token --resource <envUrl>).
// Usage: node mcp-run.mjs <envUrl> <calls.json> <out.json> [NAME=value ...]
//   calls.json: [{ "tool": "form_open_menu_item", "args": { ... } }, ...]
//   out.json:   the full text result of every call
//   NAME=value: replaces __NAME__ in calls.json, e.g. SALESID=000123
import { execSync } from 'child_process';
import { readFileSync, writeFileSync } from 'fs';

const [envUrl, callsFile, outFile, ...vars] = process.argv.slice(2);
let callsText = readFileSync(callsFile, 'utf-8').replace(/^﻿/, '');
for (const v of vars) {
  const [name, ...rest] = v.split('=');
  callsText = callsText.split(`__${name}__`).join(rest.join('='));
}
const calls = JSON.parse(callsText);
const token = execSync(`az account get-access-token --resource "${envUrl}" --query accessToken -o tsv`, { encoding: 'utf-8' }).trim();
let sessionId = null;
let nextId = 1;

async function post(message) {
  const headers = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream', 'Authorization': `Bearer ${token}` };
  if (sessionId) headers['mcp-session-id'] = sessionId;
  const r = await fetch(`${envUrl}/mcp`, { method: 'POST', headers, body: JSON.stringify(message) });
  const sid = r.headers.get('mcp-session-id');
  if (sid) sessionId = sid;
  let text = await r.text();
  if (text.startsWith('event:') || text.startsWith('data:')) {
    text = text.split('\n').filter(l => l.startsWith('data: ')).map(l => l.slice(6)).join('');
  }
  return { status: r.status, text };
}

const init = await post({ jsonrpc: '2.0', id: nextId++, method: 'initialize',
  params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'mcp-run', version: '1' } } });
if (init.status !== 200) { console.error(`initialize: HTTP ${init.status} ${init.text.slice(0, 300)}`); process.exit(1); }
await post({ jsonrpc: '2.0', method: 'notifications/initialized' });

const results = [];
for (const c of calls) {
  const t0 = Date.now();
  const r = await post({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: c.tool, arguments: c.args || {} } });
  let text = r.text, isError = r.status !== 200;
  try {
    const j = JSON.parse(r.text);
    if (j.error) { text = j.error.message; isError = true; }
    else { text = (j.result.content || []).map(x => x.text || (x.resource && x.resource.text) || '').join('\n'); isError = isError || !!j.result.isError; }
  } catch { }
  results.push({ tool: c.tool, args: c.args, status: r.status, isError, seconds: Math.round((Date.now() - t0) / 1000), text });
  console.log(`${c.tool}: HTTP ${r.status}${isError ? ' ERROR' : ''}, ${text.length} chars, ${results.at(-1).seconds}s`);
  if (isError) break;
}
writeFileSync(outFile, JSON.stringify(results, null, 2), 'utf-8');
