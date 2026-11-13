/// The `omc` API, in JavaScript, on top of a few native functions (`__omcNative`): every call
/// into the app goes through `call` (answered right away) or `callAsync` (answered later
/// through `__omcResolve`), with JSON arguments and results.
enum ExtensionPrelude {
    static let apiVersion = "0.1.0"

    static let source = #"""
(function (global) {
  "use strict";
  const native = global.__omcNative;
  delete global.__omcNative;

  let nextId = 1;
  const pending = new Map();

  function errorText(e) {
    if (e instanceof Error) return e.stack ? e.message + "\n" + e.stack : e.message;
    return String(e);
  }
  function toJSON(value) {
    try { return JSON.stringify(value === undefined ? null : value); } catch (e) { return "null"; }
  }
  function call(method, args) {
    const reply = JSON.parse(native.call(method, toJSON(args)));
    if (reply.error !== undefined && reply.error !== null) throw new Error(reply.error);
    return reply.result === null ? undefined : reply.result;
  }
  function callAsync(method, args) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      native.callAsync(method, toJSON(args), id);
    });
  }
  global.__omcResolve = (id, error, resultJSON) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    if (error !== null && error !== undefined) p.reject(new Error(error));
    else p.resolve(resultJSON === null || resultJSON === undefined ? undefined : JSON.parse(resultJSON));
  };

  // Console and timers.
  function format(args) {
    return args.map((a) => typeof a === "string" ? a : a instanceof Error ? errorText(a) : toJSON(a)).join(" ");
  }
  global.console = {
    log: (...a) => native.log("info", format(a)),
    info: (...a) => native.log("info", format(a)),
    debug: (...a) => native.log("info", format(a)),
    warn: (...a) => native.log("warning", format(a)),
    error: (...a) => native.log("error", format(a)),
  };
  function report(e) { native.log("error", errorText(e)); }

  const timers = new Map();
  function addTimer(fn, ms, args, repeat) {
    if (typeof fn !== "function") throw new TypeError("The callback must be a function");
    const id = nextId++;
    timers.set(id, { fn, args, repeat });
    native.setTimer(id, Math.max(0, Number(ms) || 0), repeat);
    return id;
  }
  global.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, args, false);
  global.setInterval = (fn, ms, ...args) => addTimer(fn, ms, args, true);
  global.clearTimeout = global.clearInterval = (id) => { if (timers.delete(id)) native.clearTimer(id); };
  global.__omcTimer = (id) => {
    const timer = timers.get(id);
    if (!timer) return;
    if (!timer.repeat) timers.delete(id);
    try { timer.fn(...timer.args); } catch (e) { report(e); }
  };

  // Building blocks.
  class Disposable {
    constructor(fn) { this._fn = fn; }
    dispose() { const fn = this._fn; this._fn = undefined; if (fn) fn(); }
    static from(...items) { return new Disposable(() => items.forEach((d) => d && d.dispose && d.dispose())); }
  }
  class EventEmitter {
    constructor() {
      this._listeners = new Set();
      this.event = (listener, thisArg, disposables) => {
        const bound = thisArg ? listener.bind(thisArg) : listener;
        this._listeners.add(bound);
        const d = new Disposable(() => this._listeners.delete(bound));
        if (Array.isArray(disposables)) disposables.push(d);
        return d;
      };
    }
    fire(data) { for (const l of [...this._listeners]) { try { l(data); } catch (e) { report(e); } } }
    dispose() { this._listeners.clear(); }
  }
  class Position {
    constructor(line, character) { this.line = line; this.character = character; }
  }
  class Range {
    constructor(a, b, c, d) {
      if (typeof a === "number") { this.start = new Position(a, b); this.end = new Position(c, d); }
      else { this.start = toPosition(a); this.end = toPosition(b); }
    }
    get isEmpty() { return this.start.line === this.end.line && this.start.character === this.end.character; }
  }
  function toPosition(p) { return new Position(p.line, p.character); }
  function toRange(r) { return new Range(toPosition(r.start), toPosition(r.end)); }
  function plainRange(r) {
    return { start: { line: r.start.line, character: r.start.character }, end: { line: r.end.line, character: r.end.character } };
  }

  class TextDocument {
    constructor(info) { Object.assign(this, info); }
    getText(range) { return call("document.getText", { path: this.path, range: range ? plainRange(range) : null }); }
    lineAt(line) {
      const number = typeof line === "number" ? line : line.line;
      return { lineNumber: number, text: call("document.getLine", { path: this.path, line: number }) };
    }
    save() { return callAsync("document.save", { path: this.path }); }
  }
  class TextEditor {
    constructor(info) {
      this.document = new TextDocument(info.document);
      this.selections = info.selections.map(toRange);
      this.selection = this.selections[0];
    }
    /// edit(builder => builder.replace(range, text)) or edit([{ range, text }]).
    edit(editsOrCallback) {
      let edits = [];
      if (typeof editsOrCallback === "function") {
        const builder = {
          replace: (range, text) => edits.push({ range: plainRange(range), text: String(text) }),
          insert: (position, text) => edits.push({ range: plainRange(new Range(position, position)), text: String(text) }),
          delete: (range) => edits.push({ range: plainRange(range), text: "" }),
        };
        editsOrCallback(builder);
      } else {
        edits = (editsOrCallback || []).map((e) => ({ range: plainRange(e.range), text: String(e.text) }));
      }
      return callAsync("editor.edit", { path: this.document.path, edits });
    }
    select(rangeOrRanges) {
      const ranges = Array.isArray(rangeOrRanges) ? rangeOrRanges : [rangeOrRanges];
      call("editor.setSelections", { path: this.document.path, selections: ranges.map(plainRange) });
    }
  }

  // Events from the app.
  const events = {
    didOpenTextDocument: new EventEmitter(),
    didCloseTextDocument: new EventEmitter(),
    didSaveTextDocument: new EventEmitter(),
    didChangeTextDocument: new EventEmitter(),
    didChangeActiveTextEditor: new EventEmitter(),
    didChangeConfiguration: new EventEmitter(),
  };
  global.__omcEmit = (name, json) => {
    const emitter = events[name];
    if (!emitter) return;
    const data = JSON.parse(json);
    if (name === "didChangeActiveTextEditor") emitter.fire(data ? new TextEditor(data) : undefined);
    else if (name === "didChangeConfiguration") emitter.fire({ affectsConfiguration: (section) => data.key === section || data.key.startsWith(section + ".") });
    else if (name === "didChangeTextDocument") emitter.fire({ document: new TextDocument(data) });
    else emitter.fire(new TextDocument(data));
  };

  // Commands.
  const commands = new Map();
  global.__omcRunCommand = (id, token, argsJSON) => {
    const handler = commands.get(id);
    if (!handler) { native.commandDone(token, "The command " + id + " isn't registered by its extension.", null); return; }
    let result;
    try { result = handler(...JSON.parse(argsJSON)); } catch (e) { native.commandDone(token, errorText(e), null); return; }
    Promise.resolve(result).then(
      (value) => native.commandDone(token, null, value === undefined ? null : toJSON(value)),
      (e) => native.commandDone(token, errorText(e), null));
  };

  const StatusBarAlignment = { Left: 1, Right: 2 };
  function createStatusBarItem(alignment, priority) {
    const id = nextId++;
    let state = { text: "", tooltip: undefined, command: undefined, visible: false };
    const update = () => call("statusBar.update", Object.assign({ id, alignment: alignment === StatusBarAlignment.Left ? "left" : "right", priority: priority || 0 }, state));
    const item = {
      get text() { return state.text; }, set text(v) { state.text = String(v); if (state.visible) update(); },
      get tooltip() { return state.tooltip; }, set tooltip(v) { state.tooltip = v; if (state.visible) update(); },
      get command() { return state.command; }, set command(v) { state.command = v; if (state.visible) update(); },
      show() { state.visible = true; update(); },
      hide() { state.visible = false; update(); },
      dispose() { call("statusBar.remove", { id }); },
    };
    return item;
  }

  function configuration(section) {
    const full = (key) => section ? section + "." + key : key;
    return {
      get(key, defaultValue) { const value = call("config.get", { key: full(key) }); return value === undefined ? defaultValue : value; },
      update(key, value) { return callAsync("config.update", { key: full(key), value: value === undefined ? null : value }); },
    };
  }

  function message(kind) {
    return (text, ...items) => callAsync("window.showMessage", { kind, message: String(text), items: items.map(String) });
  }

  const omc = {
    version: native.version,
    Disposable, EventEmitter, Position, Range, StatusBarAlignment,
    commands: {
      registerCommand(id, handler, thisArg) {
        if (typeof handler !== "function") throw new TypeError("The command handler must be a function");
        if (commands.has(id)) throw new Error("The command " + id + " is already registered");
        commands.set(id, thisArg ? handler.bind(thisArg) : handler);
        call("commands.register", { id });
        return new Disposable(() => { commands.delete(id); call("commands.unregister", { id }); });
      },
      executeCommand(id, ...args) {
        const handler = commands.get(id);
        if (handler) { try { return Promise.resolve(handler(...args)); } catch (e) { return Promise.reject(e); } }
        return callAsync("commands.execute", { id, args });
      },
      getCommands() { return callAsync("commands.list", null); },
    },
    window: {
      showInformationMessage: message("info"),
      showWarningMessage: message("warning"),
      showErrorMessage: message("error"),
      showInputBox(options) {
        const o = options || {};
        return callAsync("window.showInputBox", { prompt: o.prompt, value: o.value, placeHolder: o.placeHolder });
      },
      showQuickPick(items, options) {
        const o = options || {};
        return Promise.resolve(items).then((list) => {
          const shown = list.map((i) => typeof i === "string" ? { label: i } : { label: String(i.label), description: i.description, detail: i.detail });
          return callAsync("window.showQuickPick", { items: shown, placeHolder: o.placeHolder })
            .then((index) => index === undefined ? undefined : list[index]);
        });
      },
      get activeTextEditor() { const info = call("editor.active", null); return info ? new TextEditor(info) : undefined; },
      showTextDocument(documentOrPath) {
        const path = typeof documentOrPath === "string" ? documentOrPath : documentOrPath.path;
        return callAsync("window.showTextDocument", { path }).then((info) => info ? new TextEditor(info) : undefined);
      },
      createStatusBarItem,
      onDidChangeActiveTextEditor: events.didChangeActiveTextEditor.event,
    },
    workspace: {
      get rootPath() { return call("workspace.root", null); },
      get textDocuments() { return call("workspace.documents", null).map((info) => new TextDocument(info)); },
      openTextDocument(path) { return callAsync("workspace.openTextDocument", { path }).then((info) => new TextDocument(info)); },
      getConfiguration: configuration,
      onDidOpenTextDocument: events.didOpenTextDocument.event,
      onDidCloseTextDocument: events.didCloseTextDocument.event,
      onDidSaveTextDocument: events.didSaveTextDocument.event,
      onDidChangeTextDocument: events.didChangeTextDocument.event,
      onDidChangeConfiguration: events.didChangeConfiguration.event,
      fs: {
        readFile(path) { return callAsync("fs.readFile", { path }); },
        writeFile(path, text) { return callAsync("fs.writeFile", { path, text: String(text) }); },
        readDirectory(path) { return callAsync("fs.readDirectory", { path }); },
        exists(path) { return callAsync("fs.exists", { path }); },
      },
    },
    process: {
      run(command, args, options) {
        const o = options || {};
        return callAsync("process.run", { command, args: (args || []).map(String), cwd: o.cwd, input: o.input, timeout: o.timeout });
      },
    },
    net: {
      fetch(url, options) {
        const o = options || {};
        return callAsync("net.fetch", { url: String(url), method: o.method, headers: o.headers, body: o.body }).then((r) => ({
          status: r.status, ok: r.status >= 200 && r.status < 300, headers: r.headers,
          text: () => Promise.resolve(r.body),
          json: () => Promise.resolve(JSON.parse(r.body)),
        }));
      },
    },
  };
  global.omc = omc;

  // The extension's module (CommonJS: exports.activate = ...).
  let exported = {};
  let context;
  global.__omcLoad = (source, filename, dirname) => {
    const module = { exports: {} };
    const require = (name) => {
      if (name === "omc") return omc;
      throw new Error("Cannot find module '" + name + "': only 'omc' is available, bundle other dependencies into the extension.");
    };
    const fn = new Function("exports", "require", "module", "__filename", "__dirname", source + "\n//# sourceURL=" + filename);
    fn(module.exports, require, module, filename, dirname);
    exported = module.exports || {};
  };
  global.__omcActivate = (contextJSON, token) => {
    context = JSON.parse(contextJSON);
    context.subscriptions = [];
    context.storage = {
      get: (key, defaultValue) => { const v = call("storage.get", { key }); return v === undefined ? defaultValue : v; },
      update: (key, value) => { call("storage.set", { key, value: value === undefined ? null : value }); return Promise.resolve(); },
    };
    if (typeof exported.activate !== "function") { native.commandDone(token, null, null); return; }
    try {
      Promise.resolve(exported.activate(context)).then(
        () => native.commandDone(token, null, null),
        (e) => native.commandDone(token, errorText(e), null));
    } catch (e) { native.commandDone(token, errorText(e), null); }
  };
  global.__omcDeactivate = (token) => {
    const finish = () => {
      for (const d of (context && context.subscriptions) || []) { try { d && d.dispose && d.dispose(); } catch (e) { report(e); } }
      for (const id of timers.keys()) native.clearTimer(id);
      timers.clear();
      native.commandDone(token, null, null);
    };
    try {
      Promise.resolve(typeof exported.deactivate === "function" ? exported.deactivate() : undefined).then(finish, (e) => { report(e); finish(); });
    } catch (e) { report(e); finish(); }
  };
})(this);
"""#
}
