// Helper for calling the D365 ERP MCP server (/mcp) from a signed-in D365 browser tab, for example with the
// Claude in Chrome javascript_tool. Run the whole file once per tab; it defines window.__mcp.
// It only calls /mcp on the page's own AOS (same origin), with the browser's existing sign-in.
//
//   await __mcp.call('data_find_entities_sql', { sqlExpression: "SELECT ...", companyId: 'USMF' })
//       -> { isError, text } | { httpStatus } | { rpcError }
//   __mcp.start('key', toolName, args); await __mcp.wait('key')   // calls that may take longer than ~40 s
//   __mcp.json(result.text)          // parse the tool's JSON text (null if it is not JSON)
//   __mcp.flat(result.text, 'regex')  // form tools: FormState as "Type/ControlName: Label = Value" lines
//   __mcp.links(result.text)          // deep links as query-parameter objects
//   __mcp.clean(text)                 // replaces URLs with <link> (the Chrome extension redacts them)
window.__mcp = {
    sid: null,
    nextId: 10,
    last: null,
    res: {},

    async post(message) {
        const headers = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream' };
        if (this.sid) headers['mcp-session-id'] = this.sid;
        const r = await fetch('/mcp', { method: 'POST', credentials: 'same-origin', redirect: 'manual', headers, body: JSON.stringify(message) });
        if (r.type === 'opaqueredirect') throw new Error('Not signed in: /mcp redirected to the sign-in page. Sign in to D365 in this browser.');
        return { status: r.status, sessionId: r.headers.get('mcp-session-id'), text: await r.text() };
    },

    async init() {
        this.sid = null;
        const r = await this.post({ jsonrpc: '2.0', id: 1, method: 'initialize',
            params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'claude-in-chrome', version: '1' } } });
        if (r.status !== 200) throw new Error(`initialize returned HTTP ${r.status} (is /mcp deployed? run route\\build.ps1 -Status)`);
        this.sid = r.sessionId;
        await this.post({ jsonrpc: '2.0', method: 'notifications/initialized' });
        return JSON.parse(r.text).result;
    },

    async rpc(method, params) {
        if (!this.sid) await this.init();
        let r = await this.post({ jsonrpc: '2.0', id: this.nextId++, method, params });
        if (r.status === 404) {
            // Session unknown (AOS restarted): start a new one and retry once.
            await this.init();
            r = await this.post({ jsonrpc: '2.0', id: this.nextId++, method, params });
        }
        return r;
    },

    async tools() {
        const r = await this.rpc('tools/list', {});
        return JSON.parse(r.text).result.tools;
    },

    async call(name, args) {
        const r = await this.rpc('tools/call', { name, arguments: args || {} });
        if (r.status !== 200) return { httpStatus: r.status };
        const j = JSON.parse(r.text);
        if (j.error) return { rpcError: j.error.message };
        const text = (j.result.content || []).map(c => c.text || (c.resource && c.resource.text) || '').join('\n');
        this.last = { isError: !!j.result.isError, text };
        return this.last;
    },

    // The first data_* call after an AOS restart builds the OData model (~1.5 min on a onebox), longer than
    // one javascript_tool call allows. Start it, then call wait() until state is 'done'.
    start(key, name, args) {
        const entry = { state: 'running', started: Date.now() };
        this.res[key] = entry;
        this.call(name, args).then(
            r => Object.assign(entry, { state: 'done', seconds: Math.round((Date.now() - entry.started) / 1000), result: r }),
            e => Object.assign(entry, { state: 'failed', error: String(e) }));
    },

    async wait(key, maxMs = 38000) {
        const t0 = Date.now();
        while (this.res[key] && this.res[key].state === 'running' && Date.now() - t0 < maxMs) {
            await new Promise(r => setTimeout(r, 1000));
        }
        return this.res[key];
    },

    json(text) {
        try { return JSON.parse(text); } catch (e) { return null; }
    },

    clean(text) {
        return String(text || '').replace(/https?:\/\/\S+/g, '<link>');
    },

    links(text) {
        const j = this.json(text) || {};
        const list = j.DeepLinks || (j.Result && j.Result.DeepLinks) || [];
        return list.map(l => ({ label: l.Label, params: Object.fromEntries(new URL(l.Url).searchParams) }));
    },

    // Form tools return FormState.Form as nested { <ControlType>: { <ControlName>: { Label, Value, ... } } }.
    flat(text, filter) {
        const j = this.json(text);
        if (!j) return { raw: this.clean(text).slice(0, 800) };
        const fs = j.FormState || {};
        const lines = [];
        const walk = (node, type, depth) => {
            if (!node || typeof node !== 'object' || depth > 10) return;
            for (const [k, v] of Object.entries(node)) {
                if (v && typeof v === 'object' && ('Label' in v || 'Value' in v)) {
                    const value = typeof v.Value === 'object' ? JSON.stringify(v.Value).slice(0, 120) : v.Value;
                    lines.push(`${type}/${k}: ${v.Label || ''} = ${value === undefined ? '' : value}`);
                }
                if (v && typeof v === 'object') walk(v, k, depth + 1);
            }
        };
        walk(fs.Form, 'Form', 0);
        const re = filter ? new RegExp(filter, 'i') : null;
        return {
            result: typeof j.Result === 'string' ? this.clean(j.Result).slice(0, 400) : j.Result,
            form: fs.Name, caption: fs.Caption, company: fs.Company,
            lines: (re ? lines.filter(l => re.test(l)) : lines).slice(0, 100).map(l => this.clean(l))
        };
    }
};
'window.__mcp is ready';
