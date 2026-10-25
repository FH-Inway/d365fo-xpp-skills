# D365 ERP MCP server on a local VHD (onebox), without an Entra app

How to make the **Dynamics 365 ERP MCP server** that is built into the AOS (`/mcp`) work on a local
development VHD (onebox, AOS in IIS), and how Claude or GitHub Copilot in Visual Studio Code can use it through
a signed-in browser session. No Entra app registration, client secret or tenant admin consent is needed.

This page is written so that an assistant on a new VHD can follow it: point Claude or GitHub Copilot in Visual
Studio Code at this folder and ask it to "install the D365 MCP route from this page and use it".

| File | Purpose |
|------|---------|
| [`route/DEVMcpRouteConfigurator.cs`](route/DEVMcpRouteConfigurator.cs) | Small add-in for the AOS web app that maps the `/mcp` route in IIS |
| [`route/build.ps1`](route/build.ps1) | Compiles the add-in, deploys it (DLL + `web.config` mapping + performance counters), `-Status`, `-Remove` |
| [`mcp-helper.js`](mcp-helper.js) | Browser-side helper: load it in a signed-in D365 page to call `/mcp` from Claude in Chrome or VS Code browser tools |
| [`mcp-run.mjs`](mcp-run.mjs) | Command-line runner: a JSON list of tool calls in one fresh MCP session, Azure CLI token (CHE, cloud) |

For the cloud version (a real `*.operations.dynamics.com` environment with an Entra app and client
credentials) see [../d365mcp-proxy](../d365mcp-proxy/README.md). Its
[MCP-REFERENCE.md](../d365mcp-proxy/MCP-REFERENCE.md) describes every MCP tool in detail; the tools are the
same here.

---

## 1. How it works

```
Claude in Chrome ──┐
                   ├──► Signed-in D365 page ──fetch('/mcp'), same-origin POST JSON-RPC──► AOS in IIS: /mcp
VS Code Copilot ───┘                                                               McpServerController
```

- The MCP server runs **as the signed-in browser user**, with that user's security roles. Nothing is elevated.
- Every call is an ordinary same-origin request from the D365 page to its own `/mcp` URL, so the browser's
  existing sign-in cookie authenticates it. No tokens are created, copied or stored.
- `/mcp` keeps the normal D365 sign-in: an anonymous request is redirected to the sign-in page like any
  other D365 URL.

## 2. Why `/mcp` does not work on a VHD out of the box

The MCP server code ships with the platform (`McpServerController` in
`webroot\bin\Microsoft.Dynamics.AX.Framework.Services.Platform.dll`, feature
**Dynamics 365 ERP Model Context Protocol server**, enabled by default). On a VHD, four things stand in the way.
`route/build.ps1 -Deploy` fixes all four:

| # | Problem | Symptom | Fix |
|---|---------|---------|-----|
| 1 | Only the cloud self-host startup (`webroot\Microsoft.Dynamics.AX.Owin.dll`, used by `AxHost.exe`) maps the `/mcp` route. The IIS startup (`ApplicationPlatform.WebApplication.Startup`) only adds CORS headers for it. | `POST /mcp` → D365 "We can't find that page" (404) | `DEVMcpRouteConfigurator` is an `IWebApiConfigurator` (MEF export). The IIS startup loads every one it finds in `webroot\bin\Controllers`. It maps `/mcp` with the same handler pipeline as AxHost: `McpServerThrottlingManager` throttling + `EnsureServicesRequestSessionHandler`. |
| 2 | Each configurator gets a `WebApiAssembliesResolver` that only returns the OData assemblies and the DLLs in `bin\Controllers`, so Web API can't find `McpServerController`. | still 404 | The configurator replaces the resolver (for its own configuration only) with one that returns the controller's assembly. |
| 3 | `web.config` removes the ExtensionlessUrlHandler and hands only `data`, `metadata`, `api`, `probe`... to managed code (`TransferRequestHandler`). | IIS log: `404 0 2` (static file handler, file not found) | `build.ps1` adds `<add name="DEV-MCP" path="mcp" ... TransferRequestHandler>` next to the `WebAPI` mapping. Authentication settings are not changed. |
| 4 | The controller's `[ServiceApiCounterFilter]` writes to the performance counter category **Microsoft Dynamics AX MCP Server**. Some VHD platform versions may not have this category. | HTTP 500 "The requested Performance Counter is not a custom counter, it has to be initialized as ReadOnly" | `build.ps1` creates the category with the platform's own `McpServerPerformanceCounters.Instance.CreatePerformanceCounters()` if it is missing |

On newer platform versions, the **Microsoft Dynamics AX MCP Server** performance-counter category may already
exist. `build.ps1` checks only whether the category exists before creating it; `-Status` reporting
`Performance counters : True` does not verify that the category can be used by MCP write requests. On a local
VHD updated from 10.0.48 to the 10.0.49 preview (platform `7.0.8199.3`), the category existed before deployment
and contained counters, but a later purchase-order create failed with "The requested Performance Counter is not
a custom counter, it has to be initialized as ReadOnly." This error does not identify the failing category;
do not delete or recreate the MCP category on this evidence alone.
Read-only diagnostics found the registry category registered through `netfxperf.dll` as multi-instance, and
the AOS IIS application pool runs as `NetworkService`. A temporary diagnostic task under that identity could
read all category counters, classified the category as custom, and constructed writable `PerformanceCounter`
objects for each counter. A separate reversible test under that identity incremented `Requests Total` for
instance `handlemcprequestasync` from 8 to 9 and decremented it back to 8. This confirms that a real counter
write succeeds for that counter and instance under `NetworkService`; it does not reproduce the MCP failure.
Initializing other application counter categories subsequently resolved the header-create failure (see section
7), without recreating the MCP category. The specific missing or unusable category was not isolated.
No business data was changed by the diagnostic counter test.

Not a problem on a VHD:
- The "Allowed MCP clients" table is empty, but that check is behind the flight
  `EnableMcpTokenAppIdValidation`, which is off by default.
- The `mcp.tools` scope check only applies to bearer tokens.

**Some platform builds list only the form tools.** On platform `7.0.7996.33`, `tools/list` returned the 13 `form_*`
tools only: the data and API tools are behind flights (`McpFlightsODataTools`, `McpSqlDataToolsFlight`,
`McpActionsFlight`). Calling `data_find_entities_sql` by name still worked, but clients that build their tool list
from `tools/list` (Claude Code, Copilot Studio) never offer it. On a development box, enable the flights in the AOS
database and restart IIS; `tools/list` then returns all 21 tools:

```sql
INSERT INTO SYSFLIGHTING (FLIGHTNAME, ENABLED, FLIGHTSERVICEID)
SELECT f.NAME, 1, 12719367
FROM (VALUES ('McpFlightsODataTools'), ('McpSqlDataToolsFlight'), ('McpActionsFlight')) f(NAME)
WHERE NOT EXISTS (SELECT 1 FROM SYSFLIGHTING s WHERE s.FLIGHTNAME = f.NAME AND s.FLIGHTSERVICEID = 12719367);
```

The flight names come from the platform's `McpFlights` class and the `McpSqlDataToolsFlight` class in
`Microsoft.Dynamics.AX.Framework.Services.Platform.dll`. To undo, delete the three rows and restart IIS.
This was also tested on a local VHD updated from 10.0.48 to the 10.0.49 preview (platform `7.0.8199.3`):
before enabling the rows, `tools/list` returned only 13 form tools; after enabling them and restarting IIS,
it returned 21 tools, including the data and API tools. A read-only `data_find_entities_sql` query succeeded
after the restart.

Why the "standard" sign-in fails: MCP clients (VS Code, Copilot Studio) discover OAuth through
`/.well-known/oauth-protected-resource`. On a VHD, IIS sends anonymous requests to the WS-Fed sign-in, and the
metadata endpoint is behind a flight that is off. The `onebox.dynamics.com` host is also not a resource in
Entra ID.

## 3. Requirements

- A onebox / VHD or a cloud-hosted Tier1 (CHE) with the AOS in IIS. `build.ps1` finds the webroot in
  `C:`, `J:` or `K:\AOSService\webroot`; pass `-Webroot` otherwise. Tested on platform `7.0.8199.55`
  (ApplicationSuite `10.40.3825`) on a onebox and on platform `7.0.7996.33` on a CHE (see the flights note in
  section 2). `build.ps1` stops with a clear message if the platform has no MCP server.
- Feature management: **Dynamics 365 ERP Model Context Protocol server** enabled (it is by default). If it is
  off, `/mcp` returns 403.
- An elevated PowerShell. The script uses Visual Studio's C# compiler (found with `vswhere`) or falls back to
  the .NET Framework `csc.exe`.
- For Claude: the **Claude in Chrome** extension, with the user signed in to D365 in that Chrome.
- For GitHub Copilot: VS Code agent mode with the built-in browser tools enabled, and the user signed in to
  D365 in VS Code's integrated browser (see section 5).

## 4. Install

1. **Get the files** into a local folder, for example `C:\Temp\d365mcp-local-vhd` (keep the `route` subfolder):

   ```powershell
   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
   $base = 'https://raw.githubusercontent.com/TrudAX/d365fo-xpp-skills/main/notes/d365mcp-local-vhd'
   $dir = 'C:\Temp\d365mcp-local-vhd'
   New-Item -ItemType Directory -Force "$dir\route" | Out-Null
   foreach ($f in 'route/build.ps1', 'route/DEVMcpRouteConfigurator.cs', 'mcp-helper.js') {
       Invoke-WebRequest "$base/$f" -OutFile (Join-Path $dir $f) -UseBasicParsing
   }
   ```

   Read both scripts before running them.

2. **Check the current state** (read-only):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Temp\d365mcp-local-vhd\route\build.ps1 -Status
   ```

3. **Deploy.** This stops IIS for a few seconds, copies `DEVMcpRoute.dll` to `webroot\bin\Controllers`, adds the
   `web.config` mapping (a backup is kept as `web.config.DEVMcpBridge.bak`), creates the performance counters
   and starts IIS:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Temp\d365mcp-local-vhd\route\build.ps1 -Deploy
   ```

   **Claude Code in auto mode** may refuse to change the AOS webroot and `web.config` itself (the safety
   classifier treats it as a new remote surface). In that case give the user the command above and let them
   run it in an elevated terminal. Don't look for a way around the refusal.

4. **Verify.** Open the AOS once (the first request after an IIS restart is slow), then run `build.ps1 -Status`.
   Every line should say `True`, and the route log should contain
   `Mapped /mcp to ...McpServerController`.

## 5. Using it from Claude or GitHub Copilot

### Claude in Chrome

Claude calls the MCP tools from a D365 tab with the **Claude in Chrome** `javascript_tool`:

1. Open a new tab on the AOS root, e.g. `https://usnconeboxax1aos.cloud.onebox.dynamics.com/`, and let it load
   (the user must be signed in).
2. Run the content of [`mcp-helper.js`](mcp-helper.js) in the tab once. It defines `window.__mcp`.
3. Call tools:

   ```js
   const r = await __mcp.call('data_find_entities_sql', {
       sqlExpression: "SELECT TOP 1 v.VendorAccountNumber AS Acc, v.VendorOrganizationName AS Name FROM VendorsV2 v WHERE v.VendorAccountNumber = '1001'",
       companyId: 'USMF' });
   __mcp.clean(r.text)
   ```

   `await __mcp.tools()` lists the 21 tools: `api_find_actions`, `api_invoke_action`, `data_create_entities`,
   `data_delete_entities`, `data_find_entities_sql`, `data_find_entity_type`, `data_get_entity_metadata`,
   `data_update_entities`, and `form_click_control`, `form_close_form`, `form_filter_form`, `form_filter_grid`,
   `form_find_controls`, `form_find_menu_item`, `form_open_lookup`, `form_open_menu_item`,
   `form_open_or_close_tab`, `form_save_form`, `form_select_grid_row`, `form_set_control_values`,
   `form_sort_grid_column`.

### GitHub Copilot in Visual Studio Code

VS Code's built-in browser tools can use the signed-in page to call `/mcp`. This is a browser-based approach,
not a direct HTTP MCP connection from Copilot: a direct MCP client does not automatically share the browser's
D365 sign-in cookie. Do not copy or forward the cookie to a local proxy.

1. Use VS Code agent mode with its built-in browser tools enabled (`workbench.browser.enableChatTools`; enabled
   by default in VS Code versions that support these tools). Open the AOS root in VS Code's **integrated
   browser** and sign in. A page opened by the agent is available to it; if you opened the page yourself, use
   **Share with Agent** in the browser toolbar. A regular Chrome tab is not automatically shared with Copilot.
   See [VS Code browser tools](https://code.visualstudio.com/docs/agents/run/browser-tools).
2. Ask Copilot to load [`mcp-helper.js`](mcp-helper.js) into that page using the built-in browser Playwright
   tool, with the file's absolute local path, for example:

   ```js
   await page.addScriptTag({ path: '<absolute-repo-path>\\notes\\d365mcp-local-vhd\\mcp-helper.js' });
   await page.evaluate(() => typeof window.__mcp === 'object');
   ```

   This only defines `window.__mcp`; it does not contact `/mcp` until a helper method is called.
3. List the tools and make calls from the page context. For example, to list tool names without opening a form:

   ```js
   await page.evaluate(async () => (await window.__mcp.tools()).map(tool => tool.name));
   ```

   To call a tool, use `window.__mcp.call(name, args)` inside `page.evaluate`. Start with read-only calls and
   return only the fields needed. The MCP server acts as the signed-in D365 user and has that user's security
   roles; get confirmation before any call that creates, updates, deletes, posts, or saves business data.
4. The helper maintains its MCP session in the page. After an AOS restart or an expired session, it initializes
   a new one. Long operations can use `window.__mcp.start(key, name, args)` and poll with
   `window.__mcp.wait(key)`; browser-tool time limits vary by host and are not necessarily Claude in Chrome's
   45-second limit.

On a local VHD updated from 10.0.48 to the 10.0.49 preview (platform `7.0.8199.3`), the Copilot browser test
successfully listed tools and called the read-only `form_find_menu_item` tool. `tools/list` returned 13
`form_*` tools only, with no `data_*` or `api_*` tools. The `form_set_control_value` tool appeared in singular
form, unlike the `form_set_control_values` name in the list above. Tool visibility depends on platform flights
and version; do not assume every build lists the 21 tools above. Before enabling the three flights listed in
section 2, a direct read-only `data_find_entities_sql` call by name succeeded even though it was not returned
by `tools/list`. After enabling the flights and restarting IIS, `tools/list` returned 21 tools and the same
read-only query succeeded.

Things to know:

- **Long-running calls:** the first `data_*` call after an AOS restart builds the OData model and takes about
  80-90 s on a onebox; later calls take milliseconds. Some form actions run much longer (cancelling the work of
  a large wave took 2.5 minutes). Use `__mcp.start('k', tool, args)` and then call `await __mcp.wait('k')`
  (25 s by default) until `state` is `done`. Keep each wait short: while the D365 page is busy it can delay
  timers.
- **Claude in Chrome has a 45-second limit per `javascript_tool` call.** In testing, a 35-second wait was cut
  off at 45 s. The server finishes the action even when the browser call is cut off; for long actions it is
  often simpler to watch the result in the database. VS Code browser-tool limits vary by host and version.
- **The Claude in Chrome extension redacts tool output** that looks like URLs with query strings, base64 or session
  keys ("[BLOCKED: ...]"), and sometimes plain identifiers too (a grid named `GridView`). Return only the fields
  you need, use `__mcp.clean()` for text, `__mcp.controls(text, 'Grid|Button')` or `__mcp.spell(name)` for
  control names, and rebuild deep links yourself (section 6).
- **Buttons on action pane tabs that aren't open** aren't in the form state that `form_open_menu_item`
  returns (for example **Process** on the Waves form). Find them with `form_find_controls` and click them by
  name.
- **Form tools are stateful** per MCP session: one form call at a time, and finish with `form_close_form`.
  `form_save_form` says "Persistence could not be independently verified", so confirm the result with a
  `data_find_entities_sql` query.
- After an `iisreset` the MCP session is gone (404); `__mcp.call` starts a new one and retries once.
- If a Claude in Chrome call is cut off by its 45 s limit, the server still finishes it. Check the IIS log
  (`C:\inetpub\logs\LogFiles\W3SVC*\u_ex*.log`, field `time-taken`).

**On a CHE, use a bearer token instead.** A CHE host (`*.axcloud.dynamics.com`) is a real Entra resource, so after
`build.ps1 -Deploy` its `/mcp` also accepts an Azure CLI token
(`az account get-access-token --resource https://<env>.axcloud.dynamics.com`; scope `user_impersonation` is enough).
Claude Code can then use it as a normal stdio MCP server, without Chrome or the 45 s limit, through a token proxy
such as [claude-code-d365fo-mcp](https://github.com/axpolik/claude-code-d365fo-mcp) (`D365_MCP_URL` =
`https://<env>/mcp`, `D365_RESOURCE` = `https://<env>`). Tested with the Azure CLI app
`04b07795-8ddb-461a-bbee-02f9e1bf7b46` in **System administration > Setup > Allowed MCP clients**, and on a
second CHE (platform `7.0.7996.33`) also without that row. The same proxy works for cloud sandboxes, where the row
is required (403 without it).

Setting it up on a CHE:

- **Sign in to Azure CLI as the D365 user:** `az login --tenant <your-domain> --allow-no-subscriptions`. D365 users
  often have no Azure subscription, and without `--allow-no-subscriptions` the login stops there. On Windows the
  sign-in uses an account picker window; if it doesn't appear (for example in a terminal embedded in an app), run
  the command in a normal PowerShell window or add `--use-device-code`. Check with
  `az account get-access-token --resource https://<env> --query expiresOn -o tsv`.
- **Register the proxy with an explicit `PATH`:** a client started before Node.js or Azure CLI was installed
  doesn't see them on its `PATH`, and the proxy then fails to start ("Connection closed"). For example:
  `claude mcp add d365 --scope user -e D365_MCP_URL=https://<env>/mcp -e D365_RESOURCE=https://<env>
  -e "PATH=C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;C:\Program Files\nodejs;C:\Windows\system32;C:\Windows"
  -- "C:\Program Files\nodejs\node.exe" C:\Tools\claude-code-d365fo-mcp\mcp-dynamics365fo-proxy.mjs`.
  `claude mcp get d365` should then report **Connected**.
- **If form calls through the proxy hang,** use the browser approach above for that work: it calls the same
  server. On one CHE the first `form_open_menu_item` through the proxy never returned, while the same call from
  the browser took 1 second.

The server drops an idle MCP session. A proxy that keeps the first `mcp-session-id` then fails every call with
"MCP session with ID ... could not be found" until Claude Code restarts, unless it re-initializes on that error.
For a scripted sequence of form calls, [`mcp-run.mjs`](mcp-run.mjs) runs a JSON list of tool calls in one fresh
session: `node mcp-run.mjs https://<env> calls.json out.json SALESID=000123` (`__SALESID__` in calls.json is replaced).

## 6. Deep links

MCP returns deep links in `DeepLinks[].Url` with this format (built by `McpDeepLinkUrlBuilder`):

```
https://<host>/?mi=action:McpDeepLinkNavigator&nav=<target>&nt=<entity|mi>&filters=[{"f":"<field>","op":"Is","v":"<value>"}]&cmp=<company>
```

- `nt=entity`: `nav` is the data entity's AOT name (from data tools, e.g. `PurchPurchaseOrderHeaderV2Entity`).
- `nt=mi`: `nav` is a display menu item (from form tools, e.g. `PurchTable`).

The Chrome extension may redact parts of the link, so read the parameters with `__mcp.links(text)` and
rebuild the URL with the same .NET encoding MCP uses:

```powershell
Add-Type -AssemblyName System.Web
$q = [System.Web.HttpUtility]::ParseQueryString('')
$q['mi'] = 'action:McpDeepLinkNavigator'; $q['nav'] = 'PurchTable'; $q['nt'] = 'mi'
$q['filters'] = '[{"f":"PurchId","op":"Is","v":"00000276"}]'; $q['cmp'] = 'USMF'
$u = New-Object UriBuilder('https://usnconeboxax1aos.cloud.onebox.dynamics.com'); $u.Query = $q.ToString(); $u.Uri.AbsoluteUri
```

On a local VHD updated from 10.0.48 to the 10.0.49 preview (platform `7.0.8199.3`), the sample purchase order
`00000276` was not found. A form-tools test found vendor account `1001` in `USMF`; rebuilding the link for
`nav=VendTableListPage`, `nt=mi`, with an `AccountNum` filter opened that vendor successfully. The filter field
must match the target form's underlying field; a generic "Open All vendors" link does not include a record filter.

## 7. Worked examples (USMF demo data)

**Create a purchase order with data tools** (vendor 1001, item M0007, quantity 10):

1. Check the master data with `data_find_entities_sql` on `VendorsV2` and `ReleasedProductsV2` (field
   `SearchName`; `ProductName` does not exist on that entity).
2. `data_create_entities` with `odataPath: 'PurchaseOrderHeadersV2'`,
   `entityDefinitionsJson: '[{"dataAreaId":"USMF","OrderVendorAccountNumber":"1001"}]'`, `companyId: 'USMF'`.
   The PO number comes from the number sequence and is in the returned deep link filter (`PurchId`).
3. `data_create_entities` with `odataPath: 'PurchaseOrderLinesV2'`,
   `[{"dataAreaId":"USMF","PurchaseOrderNumber":"<PO>","LineNumber":1,"ItemNumber":"M0007","OrderedPurchaseQuantity":10}]`.
   `LineNumber` is required ("Field 'Line number' must be filled in" otherwise).
4. Verify with a `data_find_entities_sql` join of `PurchaseOrderHeadersV2` and `PurchaseOrderLinesV2`.
   Deep link: `nav=PurchPurchaseOrderHeaderV2Entity`, `nt=entity`, filter `PurchId`.

In a local VHD test on platform `7.0.8199.3`, the read-only checks confirmed vendor `1001` and item `M0007`
in `USMF`. The purchase-order header create attempt then failed with "The requested Performance Counter is not
a custom counter, it has to be initialized as ReadOnly" (`SuccessCount: 0`, `FailureCount: 1`); no header was
created. After confirming that `NetworkService` could increment and restore the `Requests Total` performance
counter, a retry failed with the same error and `SuccessCount: 0`. No header was created in either attempt.
After restarting the local VHD environment, browser discovery still returned 21 tools, but another header
creation attempt failed after about 99 seconds with the same error (`SuccessCount: 0`, `FailureCount: 1`).
The failing performance-counter category and call path have not been identified; the error alone does not
establish that the MCP counter filter is responsible.

A subsequent environment-repair test ran an adapted
[PerformanceCounterFix.ps1](https://gist.github.com/FH-Inway/6d4c902909df93b112ee564b3748e16f) using this VHD's
packages directory. Subledger, Tax, SourceDocumentation, and AxShared counter initializers completed.
ProductConfiguration was explicitly skipped because its instrumentation assembly was unavailable. An initial
copy attempt encountered a locked SourceDocumentation DLL; comparing SHA-256 hashes showed the shared-bin
copy was identical, so the adapted script skipped identical copies before running the initializers. A subsequent
data-tool header creation succeeded (`SuccessCount: 1`, `FailureCount: 0`), and a read-only query verified the
generated purchase-order number and vendor in `USMF`. No IIS restart was needed after running the repair script.
The specific application counter category responsible was not isolated; the MCP category was not recreated.
The next data-tool step also succeeded: line `1` with item `M0007` and ordered quantity `10` was created on the
new header in `USMF` (`SuccessCount: 1`, `FailureCount: 0`). A separate read-only query confirmed the saved
line number, item, and quantity. No confirmation, receipt, or invoice was performed.
Opening the returned header deep link in the integrated browser displayed the created purchase order and its
line with item `M0007`, quantity `10`, confirming the entity deep-link navigation as well.

**Create the same purchase order through the form** (what a user would click):

On platform `7.0.8199.3`, a form-tool header creation test also failed: after setting vendor `1001` and
clicking `OK`, the server returned the same performance-counter error for both `PurchCreateOrder_form` and
`PurchTable_form`. The create dialog was cancelled and the MCP forms were closed. This failure is not limited
to the data-entity create tool. This build exposes `form_set_control_value` with `controlName` and
`controlValue` arguments, rather than the plural setter used in the example below.

After the application-counter repair, a second form-tool test successfully created a separate purchase order
for vendor `1001`, added item `M0007` with quantity `10`, and saved it. A read-only header/line join verified
the result, and the MCP forms were closed. No confirmation, receipt, or invoice was performed. On this build,
clicking `OK` returned a closed form state and the new order's deep link. To add the line, the test reopened
`PurchTable`, filtered `PurchTable_PurchIdAdvanced` by the generated PO number, clicked that control to open
details, opened `LineView` with `form_open_or_close_tab`, and clicked `LineStripNew`. The item and quantity were
then set in separate `form_set_control_value` calls. Hidden line controls cannot be clicked until the Lines
tab is open. The save response reported success, but persistence was still checked independently.

| Step | Tool | Arguments |
|------|------|-----------|
| Open the form | `form_open_menu_item` | `name: 'PurchTable', type: 'Display', companyId: 'USMF'` |
| New → "Create purchase order" dialog (`PurchCreateOrder`, PO number already reserved) | `form_click_control` | `controlName: 'SystemDefinedNewButton'` |
| Vendor (fills invoice account, currency, delivery name) | `form_set_control_values` | `setControlValues: [{controlName: 'PurchTable_OrderAccount', value: '1001'}]` |
| Create the header | `form_click_control` | `controlName: 'OK'` |
| Fill the empty line the form adds (grid `LineSpec`; use `LineStripNew` for more lines) | `form_set_control_values` | `[{controlName: 'PurchLine_ItemId', value: 'M0007'}, {controlName: 'PurchLine_PurchQtyGrid', value: '10'}]` |
| Save | `form_save_form` | |
| Close the form session | `form_close_form` | |

The save response contains the deep link (`nav=PurchTable`, `nt=mi`, filter `PurchId`). Use
`__mcp.flat(text, 'regex')` to list control names; in the form state, the lines grid is at
`Tab.TabPageDetails.Children.Tab.LineView.Children.Tab.LineViewLines.Children.Grid.LineSpec` (`Columns`, `Rows`).

**Form tool tips** (seen on sales order posting, 2026-10):
- Buttons inside a menu button (e.g. line **Inventory > Reservation**) appear in the form state only after the
  menu button is clicked. Searching by label can miss controls; search by control name.
- `form_select_grid_row` uses 0-based rows. On some list grids it fails even when rows exist; filtering the grid
  on a key column (a RecId column works too) makes the match the current record.
- Dialogs can't be closed with `form_close_form`; click their buttons (`OK` / `Cancel` on posting dialogs).
  Posting dialogs are followed by a "post without printing" message box (`SysBoxForm`, buttons `Ok` / `Cancel`).
- Postings run in the background ("Processing operation"): read the result from the data a little later before
  retrying, and note that closing the message box can still post.
- A sales order in a WHS warehouse can still use picking lists: registration needs a location per line, and the
  invoice needs quantity **Picked** when no packing slip was posted.

## 8. Troubleshooting

IIS replaces the bodies of 4xx/5xx responses with its error page. The add-in therefore logs every `/mcp`
response with status >= 400, including the real error text, to `DEVMcpRoute.log` in the app pool user's
`%TEMP%` (usually `C:\Windows\Temp\DEVMcpRoute\`). `build.ps1 -Status` prints the last lines.

| Symptom | Cause / fix |
|---------|-------------|
| 404 HTML page, IIS log `404 0 2` | `web.config` mapping missing: run `build.ps1 -Deploy` |
| 404 HTML page, IIS log `404 0 0`, log has no `Mapped /mcp` | DLL not in `webroot\bin\Controllers`, or IIS not restarted |
| 500, log: "...is not a custom counter..." | If the category is missing, run `build.ps1 -Deploy`. If `-Status` says it exists but the error persists, the category may be unusable or incompatible; `-Deploy` skips creation when the category already exists, so investigate before deleting or recreating it. |
| 403 | Feature **Dynamics 365 ERP Model Context Protocol server** is off in Feature management |
| `tools/list` returns only the 13 `form_*` tools | Platform flights and version control tool visibility. See section 2; on some builds, data tools may still work when called by name |
| `opaqueredirect` / "Not signed in" | The browser session expired: sign in to D365 again in that Chrome |
| `Copy-Item ... being used by another process` | Old script version: IIS must be stopped before the DLL is replaced (current `build.ps1` does this) |
| A Claude in Chrome call is cut off at 45 s | First OData model build after an AOS restart: use `__mcp.start` / `__mcp.wait` |
| "MCP session with ID ... could not be found" | The server dropped an idle session: restart the client (proxy), or run calls with `mcp-run.mjs` |
| Everything stopped working after a platform update, or after `web.config` was replaced (e.g. to point the AOS at another database) | The `DEV-MCP` mapping is gone: run `build.ps1 -Deploy` again |

## 9. Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File C:\Temp\d365mcp-local-vhd\route\build.ps1 -Remove
```

This deletes the DLL and removes the `web.config` mapping (IIS is stopped and started). The performance
counter category stays; it is harmless.

## 10. Notes on scope

- This is for **development VHDs and CHEs**. Cloud sandboxes already host `/mcp` but only accept bearer
  tokens (`mcp-helper.js` gets 401 there); use a token proxy as in section 5.
- `build.ps1` changes nothing about authentication: no anonymous access, no CORS changes, no token
  settings.
- Don't relay the browser session to other local programs (a localhost "bridge" or proxy that sends
  requests through the signed-in tab). The VS Code built-in browser approach in section 5 keeps each request
  inside the shared D365 page; it does not export or forward the cookie.
