# HTML and JavaScript inside X++ forms (extensible controls)

How to put your own HTML, CSS and JavaScript UI into a Dynamics 365 Finance and Operations form, and how
to make it talk to X++ in both directions. The rules come from building a working control end to end and
from the problems hit along the way.

This page is written so that Claude can follow it: point Claude at it when you ask for a custom HTML
control on a form.

| Reference | What it is |
|-----------|------------|
| [X++ Arcade Games](https://github.com/TrudAX/XppTools#devtutorial-model) (XppTools, model DEVTutorial) | Complete example: a form with an extensible control that runs HTML5 games, saves sessions and scores to a table and builds a quiz from X++ selects. The code samples below are taken from it |
| [Control extensibility](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/user-interface/control-extensibility) | Microsoft: architecture overview |
| [Build extensible controls](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/user-interface/build-extensible-control) | Microsoft: tutorial (build class, runtime class, HTML bindings) |
| [Extensible control programming reference](https://learn.microsoft.com/en-us/dynamics365/fin-ops-core/dev-itpro/user-interface/extensible-control-programming-reference) | Microsoft: properties, commands, bindings, the `$dyn` API |
| [Copy Text to Clipboard in D365FO](https://ax.docentric.com/copy-text-to-clipboard-in-d365fo/) | Docentric: a small practical control |

Standard controls worth reading in `PackagesLocalDirectory`: `StarRatingControl` (properties and HTML
bindings), `TimerControl` (command, form override, delegate), `ClockCardControl` (minimal template),
`FileUpload` (delegates used by forms).

---

## 1. How it works

```
 Form (buttons, fields, grids) ── calls methods ──► Runtime class (X++, FormTemplateControl)
          ▲                                              │  properties          ▲  commands
          │ delegates                                     ▼  (X++ -> JS)         │  (JS -> X++)
          └────────────────────────────────── JavaScript view model + HTML/CSS in the browser
```

- **Properties (X++ to JavaScript).** Every runtime class method marked with `[FormPropertyAttribute]`
  becomes an observable in the generated JavaScript view model. Setting it in X++ updates the browser.
- **Commands (JavaScript to X++).** Every method marked with `[FormCommandAttribute]` can be called from
  JavaScript with `$dyn.callFunction`. Its return value comes back to a JavaScript callback.
- **Form code** talks to the control like to any other control: it calls the runtime class methods and
  subscribes to the control's delegates.

## 2. The pieces

| Piece | Object | Rule |
|-------|--------|------|
| Runtime class | `AxClass\<Ctl>.xml` | Extends `FormTemplateControl`. `[FormControlAttribute('<TemplateId>', '/resources/html/<HtmFileName>', classStr(<Ctl>Build))]` |
| Build class | `AxClass\<Ctl>Build.xml` | Extends `FormBuildControl`. `[FormDesignControlAttribute("Name in the form designer")]`. Design-time properties use `[FormDesignPropertyAttribute("Name", "Category")]` |
| HTML template | `AxResource\ResourceContent\Html\<Ctl>.htm` | Root element `id="<TemplateId>"` |
| JavaScript | `AxResource\ResourceContent\Scripts\<Ctl>.js` | Defines `$dyn.controls.<TemplateId>` |
| CSS | `AxResource\ResourceContent\Styles\<Ctl>.css` | Prefix every class with the control name so nothing leaks into the D365 page |
| Images | `AxResource\ResourceContent\Images\<file>` | Served as `/resources/images/<file>` |
| Resource descriptors | `AxResource\<ResourceName>.xml` | One per file, see below |

Resource descriptor (`TypeOfResource` and the folder are `Html`, `Scripts`, `Styles`, `Images` or `Data`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<AxResource xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
	<Name>DEVTutorialArcadeJS</Name>
	<FileName>DEVTutorialArcade.js</FileName>
	<RelativeUriInModelStore>DEVTutorial/DEVTutorial/AxResource/ResourceContent/Scripts/DEVTutorialArcade.js</RelativeUriInModelStore>
	<TypeOfResource>Scripts</TypeOfResource>
</AxResource>
```

URLs use the **file name**, not the resource name: `/resources/html/DEVTutorialArcadeControl`,
`/resources/scripts/DEVTutorialArcade.js`, `/resources/styles/DEVTutorialArcade.css`.

## 3. Runtime class

Simplified from the reference implementation:

```xpp
[FormControlAttribute('DEVTutorialArcadeControl', '/resources/html/DEVTutorialArcadeControl', classStr(DEVTutorialArcadeControlBuild))]
class DEVTutorialArcadeControl extends FormTemplateControl
{
    FormProperty gameIdProperty;
    FormProperty gameCommandProperty;
    int          commandSeq;
}

public void new(FormBuildControl _build, FormRun _formRun)
{
    super(_build, _formRun);

    this.setTemplateId('DEVTutorialArcadeControl');
    this.setResourceBundleName('/resources/html/DEVTutorialArcadeControl');

    gameIdProperty      = this.addProperty(methodStr(DEVTutorialArcadeControl, parmGameId), Types::String);
    gameCommandProperty = this.addProperty(methodStr(DEVTutorialArcadeControl, parmGameCommand), Types::String);
}

// copy the values set in the form designer (build class) to the runtime control
public void applyBuild()
{
    DEVTutorialArcadeControlBuild build;

    super();

    build = this.build();
    this.parmGame(build ? build.game() : DEVTutorialArcadeGame::Tank);
}

// X++ -> JS. 2nd argument = name in the JavaScript view model, 3rd argument true = read only on the client
[FormPropertyAttribute(FormPropertyKind::Value, 'GameId', true)]
public str parmGameId(str _gameId = gameIdProperty.parmValue())
{
    if (!prmIsDefault(_gameId))
    {
        gameIdProperty.setValueOrBinding(_gameId);
    }
    return gameIdProperty.parmValue();
}

// actions for the browser (start, pause, stop) go through a "command" property: "action|sequence".
// The sequence makes the same action sent twice a new value, so JavaScript sees it again.
protected void sendCommand(str _action)
{
    commandSeq++;
    this.parmGameCommand(strFmt('%1|%2', _action, commandSeq));
}

public void startGame()   // called from a form button
{
    this.sendCommand('start');
}

// JS -> X++. Arguments always arrive as strings
[FormCommandAttribute('GameOver')]
public str gameOver(str _score, str _details)
{
    int score = DEVTutorialArcadeControl::parseScore(_score);   // validate: it comes from the browser
    // ... save to a table
    this.onSessionEnded(sessionRecId, score, newBest);           // let the form react
    return newBest ? 'NEWBEST' : '';                              // goes back to the JavaScript callback
}

delegate void onSessionEnded(RecId _sessionRecId, int _score, boolean _newBest)
{
}
```

- Give properties and commands specific names (`GameCommand`, not `Command` or `Value`), so they cannot
  clash with members the generated view model already has.
- `FormPropertyKind::BindableValue` with `FormBindingUtil::initBinding(...)` binds a property to a data
  source field instead (see `Tutorial_PersonCardControl`).
- `[FormCommandAttribute('Name', false)]`: the second argument is `executeImmediate` (default `true`).
  With `false` the call is not sent at once but goes with the next server interaction. It suits chatty
  updates. The reference implementation instead throttles in JavaScript and sends immediately.
- **Treat every command argument as untrusted input.** It comes from the browser: clamp numbers, map
  strings to enums, and never build queries from it. Anything that decides an outcome (a quiz answer, a
  score) should be checked or calculated in X++.

## 4. Build class

```xpp
[FormDesignControlAttribute("DEV Tutorial Arcade")]
class DEVTutorialArcadeControlBuild extends FormBuildControl
{
    DEVTutorialArcadeGame game;
}

[FormDesignPropertyAttribute("Game", "Data")]
public DEVTutorialArcadeGame game(DEVTutorialArcadeGame _game = game)
{
    if (!prmIsDefault(_game))
    {
        game = _game;
    }
    return game;
}
```

The property appears in the Visual Studio property sheet when the control is on a form, and the runtime
class reads it in `applyBuild()`.

## 5. HTML template

**Variant A: the DOM is built by JavaScript** (canvas apps, charts, anything rendered by a library). The
root element must be **completely empty** and marked with `data-dyn-container="true"`:

```html
<link href="/resources/styles/DEVTutorialArcade.css" rel="stylesheet" type="text/css" />
<script src="/resources/scripts/DEVTutorialArcade.js"></script>
<div id="DEVTutorialArcadeControl" class="devtutorialarcade" data-dyn-container="true"
     data-dyn-bind="visible: $data.Visible, sizing: $dyn.layout.sizing($data)"></div>
```

**Variant B: HTML with bindings** (simple display controls):

```html
<link href="/resources/styles/DEVGameControl.css" rel="stylesheet" type="text/css" />
<div id="DEVGameControl" class="devgamecontrol" data-dyn-bind="visible: $data.Visible, sizing: $dyn.layout.sizing($data)">
    <span data-dyn-bind="text: $dyn.format('Best score: {0}', $dyn.value($data.HighScore))"></span>
</div>
<script src="/resources/scripts/DEVGameControl.js"></script>
```

- `$data` is the JavaScript control. Put `visible` and `sizing` on the root element.
- Common bindings: `text` (strings only, use `$dyn.format`), `attr`, `css`, `click`, `event`, `if`,
  `foreach`, `visible`.

## 6. JavaScript

```js
(function () {
    'use strict';

    // run a callback after the current server interaction (see rule 3 below)
    function afterInteraction(callback) {
        return function (result) {
            window.setTimeout(function () { callback(result); }, 0);
        };
    }

    $dyn.controls.DEVTutorialArcadeControl = function (props, element) {
        var self = this;
        $dyn.ui.Control.apply(self, arguments);

        // keep all own state in one object with a unique name, so nothing collides with $dyn.ui.Control
        var st = self.devArcade = { props: props, root: element, lastSeq: null };

        // X++ -> JS: $dyn.observe also fires once immediately with the current value
        self.usingDisposable($dyn.observe(props.GameId, function (gameId) {
            self.devArcadeLoad(gameId);
        }));

        // X++ -> JS commands: remember the first value only, so a re-created control does not replay it
        self.usingDisposable($dyn.observe(props.GameCommand, function (value) {
            var parts = (value || '').split('|'), seq = parts[1] || '';
            if (st.lastSeq === null) { st.lastSeq = seq; return; }
            if (!value || seq === st.lastSeq) { return; }
            st.lastSeq = seq;
            window.setTimeout(function () { self.devArcadeRun(parts[0]); }, 0);
        }));
    };

    $dyn.controls.DEVTutorialArcadeControl.prototype = $dyn.extendPrototype($dyn.ui.Control.prototype, {
        devArcadeGameOver: function (score, details, callback) {
            // JS -> X++: arguments as strings; the callback receives the X++ return value
            $dyn.callFunction(this.devArcade.props.GameOver, this, [String(score), JSON.stringify(details)],
                afterInteraction(callback));
        },
        dispose: function () {
            // stop timers and animation frames, remove DOM listeners, then call the base
            $dyn.ui.Control.prototype.dispose.apply(this, arguments);
        }
    });
})();
```

Rules:

1. **`$dyn.observe` fires immediately** when it is registered. For "command" properties remember that
   first value and act only on later changes, otherwise a re-created control repeats the last action.
2. **Read values** with `$dyn.value(observable)`, or `$dyn.peek(observable)` inside observers to avoid
   creating a dependency.
3. **Never call `$dyn.callFunction` from inside the callback of another `$dyn.callFunction`**, or from an
   observer while the server interaction is still running. The nested call is silently lost. Defer it with
   `setTimeout(fn, 0)` (the `afterInteraction` wrapper above).
4. **Override `dispose` in the prototype** and chain to the base. Assigning `self.dispose = ...` in the
   constructor hides the base implementation.
5. **Keyboard:** make the element focusable (`tabindex="0"`) and call `preventDefault()` /
   `stopPropagation()` only for the keys you use, so the D365 shortcuts keep working.
6. **Catch your own errors** and show them inside the control. An uncaught exception in a control can
   break the whole D365 client with "An unexpected client error has occurred".
7. Several files (a library plus your code) can be bundled into one script resource. Keep the sources
   outside the model and generate the bundle, rather than editing the deployed file.

## 7. Form

Add the control to the design (`FormControlExtension/Name` is the runtime class; the extension property
names are the build class methods):

```xml
<AxFormControl>
	<Name>GameControl</Name>
	<AutoDeclaration>Yes</AutoDeclaration>
	<WidthMode>SizeToAvailable</WidthMode>
	<FormControlExtension>
		<Name>DEVTutorialArcadeControl</Name>
		<ExtensionComponents />
		<ExtensionProperties>
			<AxFormControlExtensionProperty>
				<Name>game</Name>
				<Type>Enum</Type>
				<TypeName>DEVTutorialArcadeGame</TypeName>
				<Value>Tank</Value>
			</AxFormControlExtensionProperty>
		</ExtensionProperties>
	</FormControlExtension>
</AxFormControl>
```

The auto-declared variable is typed as the runtime class, so form code calls its methods and subscribes
to its delegates:

```xpp
public void init()
{
    super();
    GameControl.onSessionStarted += eventhandler(element.sessionStarted);
    GameControl.onSessionEnded   += eventhandler(element.sessionEnded);
}

public void close()
{
    GameControl.onSessionEnded -= eventhandler(element.sessionEnded);
    GameControl.stopSession();   // save what is still running
    super();
}

// action pane button
public void clicked()
{
    super();
    GameControl.startGame();
}
```

Three ways to get a JavaScript call into form code:

- **Delegates** (used above): the command raises a delegate, the form subscribes in `init()`. The handler
  signature must match the delegate exactly. To return a value to JavaScript, pass an `EventHandlerResult`.
- **Override the command method** on the form control (in `DataControls`, `<Type>Custom</Type>`, call
  `super()`). The method must be `public`; its return value goes back to JavaScript.
- **Store and read:** the command stores the value in a member, and form code reads it later through a
  getter.

Form settings that matter:

- `Pattern` `Custom` on the design avoids pattern validation errors for a free layout.
- A form with data sources opens in view mode and locks unbound controls (a selector, a filter). Set
  `ViewEditMode` to `Edit` on the design if the user must change them.
- Reloading the browser page does not run the form's `close()`. If you keep "running" records, clean them
  up when the next one starts.

## 8. Build and deploy

1. **Web resources are served as static files** from `C:\AOSService\webroot\Resources\{Html,Scripts,Styles,Images}`.
   A Visual Studio build of the project copies them there. A command-line `xppc` build does **not**: copy
   the files yourself. The template is requested as `/resources/html/<Name>.htm`.
2. Changing only HTML, JavaScript, CSS or images needs no restart, just a browser reload that bypasses
   the cache (Ctrl+F5).
3. After an `xppc` build of X++ changes, restart the AOS (`iisreset` on a VHD) so it loads the new code.
4. New or changed tables need a database synchronization, as usual.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "An unexpected client error has occurred"; console: `Failed to load HtmlImport` or 404 for `/resources/html/...htm` | The web resources are not in the AOS webroot | Build in Visual Studio, or copy the files to `webroot\Resources\<Type>` |
| The control stays empty or the DOM built by JavaScript disappears | The template root has children, or is not marked as a container | Empty root element with `data-dyn-container="true"` (section 5, variant A) |
| Console: "The data-dyn-container needs to be set when both the template and the target have children" | Platform message, also logged on standard forms | Ignore it if the control works |
| A JavaScript call to X++ does nothing and shows no error | `$dyn.callFunction` called inside another call's callback or during an interaction | `setTimeout(fn, 0)` before the call |
| Opening the form or switching tabs repeats the last action | `$dyn.observe` fires with the current value on registration | Remember the first value, act only on later changes |
| A form button works only the first time | The property value did not change | Send `action\|sequence` and increase the sequence every time |
| Unbound controls on the form are read only | The form opened in view mode | `ViewEditMode` = `Edit` on the design |
| X++ changes have no effect after `xppc` | The AOS still runs the old code | `iisreset` |
| "Invalid column name" after a restart | A table change was compiled but not synchronized | Run the database synchronization |
| D365 keyboard shortcuts stop working while the control has focus | `preventDefault` on every key | Handle only the keys you use |

## 10. Testing

- **Build the UI stand-alone first.** Write the HTML/JavaScript part against a small "host" interface
  (start, score changed, game over, request data) and test it on a local page with a fake host. Then write
  the D365 control script as an adapter from that interface to `$dyn` properties and commands. Most of the
  work can then be tested without the AOS.
- **Test the control script in Node** with a mocked `$dyn`:
  - `$dyn.ui.Control`: a constructor that adds `usingDisposable`; its prototype has `dispose`.
  - `$dyn.extendPrototype(base, ext)`: `Object.assign(Object.create(base), ext)`.
  - `$dyn.observe(obs, fn)`: call `fn(value)` at once, subscribe, return `{ dispose }`. `$dyn.value` and
    `$dyn.peek` unwrap the observable.
  - `$dyn.callFunction(fn, ctx, args, cb)`: record the call, invoke `cb` with a fake X++ return value.
  - `setTimeout` and `requestAnimationFrame`: queues that the test pumps by hand.

  Then assert the X++ -> JS reactions, the command names and arguments (all strings), no replay when the
  control is re-created, and the cleanup in `dispose`.
- **Test in D365** with Claude in Chrome on a signed-in tab: read the console, run JavaScript against the
  control and take screenshots. Browsers throttle `requestAnimationFrame` and timers in background tabs,
  so animations may look frozen or slow while the tab is not visible.

## 11. Checklist for Claude

1. Copy the structure of the reference implementation: runtime class, build class, HTML, JavaScript, CSS,
   resource descriptors, form. Use the model's prefix for every object name.
2. Decide the contract first: which properties go X++ -> JS, which commands go JS -> X++, with what string
   arguments and return values, and which delegates the form needs.
3. Write the HTML/JavaScript stand-alone and test it with a fake host; then write the control adapter.
4. Add all objects to the Visual Studio project, build, and make sure the resources reach the webroot.
5. Restart the AOS after `xppc` builds, synchronize new tables, and open the form with `/?mi=<MenuItem>`.
6. Check the browser console. Use the troubleshooting table before changing the design.
