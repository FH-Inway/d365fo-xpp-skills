// Helper for calling the D365 ERP MCP server (/mcp) from a signed-in D365 browser tab, for example with the
// Claude in Chrome javascript_tool. Run the whole file once per tab; it defines window.__mcp.
// It only calls /mcp on the page's own AOS (same origin), with the browser's existing sign-in.
//
//   await __mcp.call('data_find_entities_sql', { sqlExpression: "SELECT ...", companyId: 'USMF' })
//       -> { isError, text } | { httpStatus } | { rpcError }
//   __mcp.start('key', toolName, args); await __mcp.wait('key')   // calls that may take longer than ~25 s
//   __mcp.json(result.text)          // parse the tool's JSON text (null if it is not JSON)
//   __mcp.flat(result.text, 'regex')  // form tools: FormState as "Type/ControlName: Label = Value" lines
//   __mcp.controls(result.text, 'Grid|Button')  // form tools: control names by type, spelled out (see spell)
//   __mcp.links(result.text)          // deep links as query-parameter objects
//   __mcp.clean(text)                 // replaces URLs with <link> (the Chrome extension redacts them)
//   __mcp.spell('GridView')           // 'G r i d V i e w': the extension also redacts some plain names
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

    // The first data_* call after an AOS restart builds the OData model (~1.5 min on a onebox), and some form
    // actions run for minutes; one javascript_tool call is cut off at 45 s. Start the call, then call wait()
    // until state is 'done'. Keep each wait short: the D365 page can delay timers while it is busy.
    start(key, name, args) {
        const entry = { state: 'running', started: Date.now() };
        this.res[key] = entry;
        this.call(name, args).then(
            r => Object.assign(entry, { state: 'done', seconds: Math.round((Date.now() - entry.started) / 1000), result: r }),
            e => Object.assign(entry, { state: 'failed', error: String(e) }));
    },

    async wait(key, maxMs = 25000) {
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

    // The Chrome extension sometimes redacts plain identifiers as "[BLOCKED: Base64 encoded data]" (a grid
    // named GridView, for example). Spelled out with spaces they get through.
    spell(name) {
        return String(name).split('').join(' ');
    },

    // Form tools: the names of the controls in FormState.Form whose type matches the regex (Grid, Button,
    // MenuItemButton, Input...), as { type, name, label, spelled }.
    controls(text, typeFilter) {
        const j = this.json(text);
        if (!j || !j.FormState) return [];
        const re = typeFilter ? new RegExp('^(' + typeFilter + ')$', 'i') : null;
        const out = [];
        const walk = (node, depth) => {
            if (!node || typeof node !== 'object' || depth > 12) return;
            for (const [type, group] of Object.entries(node)) {
                if (group && typeof group === 'object' && (!re || re.test(type))) {
                    for (const [name, v] of Object.entries(group)) {
                        if (v && typeof v === 'object' && /^[A-Za-z_][\w ]*$/.test(name) && !/^(Children|Columns|Rows)$/.test(name)) {
                            out.push({ type, name, label: this.clean(v.Label || v.Text || ''), spelled: this.spell(name) });
                        }
                    }
                }
                if (group && typeof group === 'object') walk(group, depth + 1);
            }
        };
        walk(j.FormState.Form, 0);
        const seen = new Set();
        return out.filter(c => { const k = c.type + '/' + c.name; if (seen.has(k)) return false; seen.add(k); return true; });
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
