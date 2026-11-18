/// The `omc` API, in JavaScript, on top of a few native functions (`__omcNative`): every call
/// into the app goes through `call` (answered right away) or `callAsync` (answered later
/// through `__omcResolve`), with JSON arguments and results.
enum ExtensionPrelude {
    static let apiVersion = "0.3.0"

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
    get uri() { return { scheme: "file", path: this.path, fsPath: this.path, toString: () => uriOf(this.path) }; }
    /// The word at `position` (letters, digits, _ and $, or what `regex` matches on its line).
    getWordRangeAtPosition(position, regex) {
      const text = this.lineAt(position.line).text;
      const pattern = new RegExp(regex ? regex.source : "[A-Za-z0-9_$]+", "g");
      let match;
      while ((match = pattern.exec(text)) !== null) {
        if (match[0].length === 0) { pattern.lastIndex++; continue; }
        if (match.index <= position.character && position.character <= match.index + match[0].length) {
          return new Range(position.line, match.index, position.line, match.index + match[0].length);
        }
      }
      return undefined;
    }
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
    didChangeWorkspaceFolders: new EventEmitter(),
  };
  global.__omcEmit = (name, json) => {
    if (name === "languageServerNotification") { serverNotification(JSON.parse(json)); return; }
    const emitter = events[name];
    if (!emitter) return;
    const data = JSON.parse(json);
    if (name === "didChangeActiveTextEditor") emitter.fire(data ? new TextEditor(data) : undefined);
    else if (name === "didChangeConfiguration") emitter.fire({ affectsConfiguration: (section) => data.key === section || data.key.startsWith(section + ".") });
    else if (name === "didChangeTextDocument") emitter.fire({ document: new TextDocument(data) });
    else if (name === "didChangeWorkspaceFolders") emitter.fire({ added: data.added, removed: data.removed });
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

  // Language features: providers live here, the app asks through __omcProvide (with a token
  // it can cancel through __omcCancel), and their answers go back in the protocol's shapes.
  class CancellationTokenSource {
    constructor() {
      const listeners = new EventEmitter();
      let cancelled = false;
      this._fire = () => { if (!cancelled) { cancelled = true; listeners.fire(undefined); } };
      this.token = {
        get isCancellationRequested() { return cancelled; },
        onCancellationRequested: (listener, thisArg, disposables) => {
          if (cancelled) { try { listener.call(thisArg); } catch (e) { report(e); } return new Disposable(() => {}); }
          return listeners.event(listener, thisArg, disposables);
        },
      };
    }
    cancel() { this._fire(); }
    dispose() {}
  }
  class CancellationError extends Error { constructor() { super("Canceled"); this.name = "Canceled"; } }

  /// "file:///…" for a path (relative paths are from the first workspace folder), a URI, a
  /// document or a { path } / { fsPath }.
  function uriOf(target) {
    if (target === undefined || target === null) return undefined;
    if (typeof target === "object") {
      if (typeof target.fsPath === "string") target = target.fsPath;
      else if (typeof target.path === "string") target = target.path;
      else target = String(target);
    }
    const text = String(target);
    if (/^[a-zA-Z][\w+.-]*:/.test(text)) return text;
    const path = text.startsWith("/") ? text : (call("workspace.root", null) || "") + "/" + text;
    return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F");
  }
  function pathOfURI(uri) {
    return uri.startsWith("file://") ? decodeURI(uri.slice(7)).replace(/%23/g, "#").replace(/%3F/g, "?") : uri;
  }
  class Location {
    constructor(uri, rangeOrPosition) {
      this.uri = uri;
      this.range = rangeOrPosition instanceof Position ? new Range(rangeOrPosition, rangeOrPosition) : rangeOrPosition;
    }
  }
  class TextEdit {
    constructor(range, newText) { this.range = range; this.newText = newText; }
    static replace(range, newText) { return new TextEdit(range, newText); }
    static insert(position, newText) { return new TextEdit(new Range(position, position), newText); }
    static delete(range) { return new TextEdit(range, ""); }
  }
  class WorkspaceEdit {
    constructor() { this._edits = new Map(); }
    _list(uri) { const key = uriOf(uri); if (!this._edits.has(key)) this._edits.set(key, []); return this._edits.get(key); }
    replace(uri, range, newText) { this._list(uri).push(new TextEdit(range, newText)); }
    insert(uri, position, newText) { this._list(uri).push(TextEdit.insert(position, newText)); }
    delete(uri, range) { this._list(uri).push(TextEdit.delete(range)); }
    set(uri, edits) { this._edits.set(uriOf(uri), (edits || []).slice()); }
    get(uri) { return (this._edits.get(uriOf(uri)) || []).slice(); }
    has(uri) { return this._edits.has(uriOf(uri)); }
    entries() { return [...this._edits.entries()].map(([uri, edits]) => [uri, edits.slice()]); }
    get size() { return this._edits.size; }
  }
  class SnippetString {
    constructor(value) { this.value = value || ""; this._tabstop = 1; }
    static _escape(text) { return String(text).replace(/[$}\\]/g, "\\$&"); }
    appendText(text) { this.value += SnippetString._escape(text); return this; }
    appendTabstop(number) { this.value += "$" + (number === undefined ? this._tabstop++ : number); return this; }
    appendPlaceholder(text, number) {
      const n = number === undefined ? this._tabstop++ : number;
      this.value += "${" + n + ":" + (typeof text === "function" ? (() => { const inner = new SnippetString(); inner._tabstop = this._tabstop; text(inner); this._tabstop = inner._tabstop; return inner.value; })() : SnippetString._escape(text)) + "}";
      return this;
    }
    appendChoice(values, number) {
      const n = number === undefined ? this._tabstop++ : number;
      this.value += "${" + n + "|" + values.map((v) => String(v).replace(/[,|\\]/g, "\\$&")).join(",") + "|}";
      return this;
    }
    appendVariable(name, defaultValue) {
      this.value += defaultValue === undefined ? "${" + name + "}" : "${" + name + ":" + SnippetString._escape(defaultValue) + "}";
      return this;
    }
  }
  class MarkdownString {
    constructor(value, supportThemeIcons) { this.value = value || ""; this.supportThemeIcons = !!supportThemeIcons; this.isTrusted = false; }
    appendText(text) { this.value += String(text).replace(/[\\`*_{}[\]()#+\-.!|<>]/g, "\\$&"); return this; }
    appendMarkdown(text) { this.value += String(text); return this; }
    appendCodeblock(code, language) { this.value += "\n```" + (language || "") + "\n" + code + "\n```\n"; return this; }
  }
  class Hover { constructor(contents, range) { this.contents = Array.isArray(contents) ? contents : [contents]; this.range = range; } }
  class CompletionItem { constructor(label, kind) { this.label = label; this.kind = kind; } }
  class CompletionList { constructor(items, isIncomplete) { this.items = items || []; this.isIncomplete = !!isIncomplete; } }
  class CodeActionKind {
    constructor(value) { this.value = value; }
    append(part) { return new CodeActionKind(this.value ? this.value + "." + part : part); }
    contains(other) { return this.value === "" || other.value === this.value || other.value.startsWith(this.value + "."); }
    intersects(other) { return this.contains(other) || other.contains(this); }
  }
  CodeActionKind.Empty = new CodeActionKind("");
  CodeActionKind.QuickFix = new CodeActionKind("quickfix");
  CodeActionKind.Refactor = new CodeActionKind("refactor");
  CodeActionKind.RefactorExtract = new CodeActionKind("refactor.extract");
  CodeActionKind.RefactorInline = new CodeActionKind("refactor.inline");
  CodeActionKind.RefactorRewrite = new CodeActionKind("refactor.rewrite");
  CodeActionKind.Source = new CodeActionKind("source");
  CodeActionKind.SourceOrganizeImports = new CodeActionKind("source.organizeImports");
  CodeActionKind.SourceFixAll = new CodeActionKind("source.fixAll");
  class CodeAction { constructor(title, kind) { this.title = title; this.kind = kind; } }
  class CodeLens {
    constructor(range, command) { this.range = range; this.command = command; }
    get isResolved() { return !!this.command; }
  }
  class ParameterInformation { constructor(label, documentation) { this.label = label; this.documentation = documentation; } }
  class SignatureInformation {
    constructor(label, documentation) { this.label = label; this.documentation = documentation; this.parameters = []; }
  }
  class SignatureHelp { constructor() { this.signatures = []; this.activeSignature = 0; this.activeParameter = 0; } }
  const SignatureHelpTriggerKind = { Invoke: 1, TriggerCharacter: 2, ContentChange: 3 };
  const SymbolKind = { File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7, Constructor: 8,
    Enum: 9, Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18,
    Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25 };
  class DocumentSymbol {
    constructor(name, detail, kind, range, selectionRange) {
      this.name = name; this.detail = detail; this.kind = kind; this.range = range; this.selectionRange = selectionRange; this.children = [];
    }
  }
  class SymbolInformation {
    constructor(name, kind, containerName, location) { this.name = name; this.kind = kind; this.containerName = containerName; this.location = location; }
  }
  const DocumentHighlightKind = { Text: 0, Read: 1, Write: 2 };
  class DocumentHighlight { constructor(range, kind) { this.range = range; this.kind = kind === undefined ? DocumentHighlightKind.Text : kind; } }
  class DocumentLink { constructor(range, target) { this.range = range; this.target = target; } }
  const FoldingRangeKind = { Comment: 1, Imports: 2, Region: 3 };
  class FoldingRange { constructor(start, end, kind) { this.start = start; this.end = end; this.kind = kind; } }
  const InlayHintKind = { Type: 1, Parameter: 2 };
  class InlayHint { constructor(position, label, kind) { this.position = position; this.label = label; this.kind = kind; } }
  class SemanticTokensLegend { constructor(tokenTypes, tokenModifiers) { this.tokenTypes = tokenTypes || []; this.tokenModifiers = tokenModifiers || []; } }
  class SemanticTokens { constructor(data, resultId) { this.data = data; this.resultId = resultId; } }
  class SemanticTokensBuilder {
    constructor(legend) { this._legend = legend; this._tokens = []; }
    push(a, b, c, d, e) {
      if (typeof a === "number") { this._tokens.push([a, b, c, d, e || 0]); return; }
      const range = a, legend = this._legend;
      const type = legend ? legend.tokenTypes.indexOf(b) : -1;
      if (type < 0) throw new Error("Unknown token type " + b);
      let modifiers = 0;
      for (const m of c || []) { const i = legend.tokenModifiers.indexOf(m); if (i >= 0) modifiers |= 1 << i; }
      this._tokens.push([range.start.line, range.start.character, range.end.character - range.start.character, type, modifiers]);
    }
    build() {
      const sorted = this._tokens.slice().sort((x, y) => x[0] - y[0] || x[1] - y[1]);
      const data = [];
      let line = 0, character = 0;
      for (const [l, c, length, type, modifiers] of sorted) {
        data.push(l - line, l === line ? c - character : c, length, type, modifiers);
        line = l; character = c;
      }
      return new SemanticTokens(data);
    }
  }

  // To the protocol's shapes.
  function plainMarkup(value) {
    if (value === undefined || value === null) return undefined;
    if (typeof value === "string") return value;
    if (value.value !== undefined) return { kind: "markdown", value: String(value.value) };
    return String(value);
  }
  function markdownText(value) {
    if (value === undefined || value === null) return undefined;
    return typeof value === "string" ? value : value.value !== undefined ? String(value.value) : String(value);
  }
  function plainPosition(p) { return { line: p.line, character: p.character }; }
  function plainEdit(e) { return { range: plainRange(e.range), newText: String(e.newText) }; }
  function plainLocation(l) {
    if (!l) return undefined;
    if (l.targetUri !== undefined) return { uri: uriOf(l.targetUri), range: plainRange(l.targetSelectionRange || l.targetRange) };
    if (l.uri === undefined || !l.range) return undefined;
    const range = l.range.start ? l.range : new Range(l.range, l.range);
    return { uri: uriOf(l.uri), range: plainRange(range) };
  }
  function plainLocations(value) {
    if (!value) return [];
    return (Array.isArray(value) ? value : [value]).map(plainLocation).filter((l) => l);
  }
  function plainWorkspaceEdit(edit) {
    if (!edit) return undefined;
    const changes = {};
    const entries = typeof edit.entries === "function" ? edit.entries() : Object.entries(edit.changes || {});
    for (const [uri, edits] of entries) changes[uriOf(uri)] = edits.map(plainEdit);
    return { changes };
  }
  function plainCommand(command) {
    if (!command) return undefined;
    const out = { title: String(command.title || ""), command: String(command.command || "") };
    if (command.arguments !== undefined) out.arguments = command.arguments;
    if (command.tooltip !== undefined) out.tooltip = String(command.tooltip);
    return out;
  }
  function kindValue(kind) { return kind === undefined || kind === null ? undefined : typeof kind === "string" ? kind : kind.value; }
  function plainDiagnostic(d) {
    const out = { range: plainRange(d.range), message: String(d.message), severity: (typeof d.severity === "number" ? d.severity : 0) + 1 };
    if (d.source !== undefined) out.source = String(d.source);
    if (d.code !== undefined) out.code = typeof d.code === "object" ? d.code.value : d.code;
    return out;
  }
  function apiDiagnostic(d) {
    return { range: toRange(d.range), message: d.message, severity: (d.severity || 1) - 1, source: d.source, code: d.code };
  }
  function plainSymbol(s) {
    if (s.location !== undefined) {
      const out = { name: String(s.name), kind: (s.kind || 0) + 1, location: plainLocation(s.location) };
      if (s.containerName) out.containerName = String(s.containerName);
      return out;
    }
    const out = { name: String(s.name), kind: (s.kind || 0) + 1, range: plainRange(s.range), selectionRange: plainRange(s.selectionRange || s.range) };
    if (s.detail) out.detail = String(s.detail);
    if (s.children && s.children.length) out.children = s.children.map(plainSymbol);
    return out;
  }

  const providers = new Map();
  const cancellations = new Map();
  /// What each completion provider listed last, for resolving an item.
  const completionLists = new Map();
  const codeLensLists = new Map();
  const linkLists = new Map();
  function selectorOf(selector) {
    const list = Array.isArray(selector) ? selector : [selector];
    return list.map((s) => typeof s === "string" ? s
      : { language: s && s.language, scheme: s && s.scheme, pattern: s && (typeof s.pattern === "string" ? s.pattern : s.pattern && s.pattern.pattern) });
  }
  function registerProvider(kind, selector, provider, metadata) {
    if (!provider || typeof provider !== "object") throw new TypeError("The provider must be an object");
    const id = nextId++;
    providers.set(id, { kind, provider });
    call("languages.register", { id, kind, selector: selectorOf(selector === undefined ? "*" : selector), metadata: metadata || {} });
    return new Disposable(() => { providers.delete(id); completionLists.delete(id); codeLensLists.delete(id); linkLists.delete(id); call("languages.unregister", { id }); });
  }
  function plainItem(item, providerId, index) {
    if (typeof item === "string") return { label: item, data: { __omcProvider: providerId, __omcItem: index } };
    const label = typeof item.label === "object" && item.label !== null ? String(item.label.label) : String(item.label);
    const out = { label, data: { __omcProvider: providerId, __omcItem: index } };
    if (item.detail !== undefined) out.detail = String(item.detail);
    else if (typeof item.label === "object" && item.label && item.label.description) out.detail = String(item.label.description);
    if (item.documentation !== undefined) out.documentation = plainMarkup(item.documentation);
    if (typeof item.kind === "number") out.kind = item.kind + 1; // LSP numbers kinds from 1
    let text;
    if (item.insertText instanceof SnippetString || (item.insertText && typeof item.insertText === "object" && item.insertText.value !== undefined)) {
      text = String(item.insertText.value);
      out.insertTextFormat = 2;
    } else if (item.insertText !== undefined) {
      text = String(item.insertText);
    }
    if (text !== undefined) out.insertText = text;
    if (item.filterText !== undefined) out.filterText = String(item.filterText);
    if (item.sortText !== undefined) out.sortText = String(item.sortText);
    if (item.preselect) out.preselect = true;
    if (item.range) {
      const newText = text !== undefined ? text : label;
      if (item.range.inserting && item.range.replacing) {
        out.textEdit = { newText, insert: plainRange(item.range.inserting), replace: plainRange(item.range.replacing) };
      } else {
        out.textEdit = { range: plainRange(item.range), newText };
      }
    }
    if (item.additionalTextEdits) out.additionalTextEdits = item.additionalTextEdits.map(plainEdit);
    if (item.commitCharacters) out.commitCharacters = item.commitCharacters.map(String);
    if (item.command) out.command = plainCommand(item.command);
    return out;
  }
  function hoverText(result) {
    if (result === undefined || result === null) return [];
    const contents = typeof result === "string" || Array.isArray(result) || result instanceof MarkdownString ? result : result.contents;
    return (Array.isArray(contents) ? contents : [contents]).filter((c) => c !== undefined && c !== null)
      .map((c) => typeof c === "string" ? c : c.language !== undefined && c.value !== undefined
        ? "```" + c.language + "\n" + c.value + "\n```" : c.value !== undefined ? String(c.value) : String(c));
  }
  function plainSignatureHelp(help) {
    if (!help) return null;
    return {
      signatures: (help.signatures || []).map((s) => {
        const out = { label: String(s.label), parameters: (s.parameters || []).map((p) => {
          const param = { label: Array.isArray(p.label) ? p.label : String(p.label) };
          if (p.documentation !== undefined) param.documentation = plainMarkup(p.documentation);
          return param;
        }) };
        if (s.documentation !== undefined) out.documentation = plainMarkup(s.documentation);
        if (typeof s.activeParameter === "number") out.activeParameter = s.activeParameter;
        return out;
      }),
      activeSignature: help.activeSignature || 0,
      activeParameter: help.activeParameter || 0,
    };
  }
  function plainCodeAction(action, providerId, index) {
    if (typeof action.command === "string") return plainCommand(action); // a bare Command
    const out = { title: String(action.title) };
    const kind = kindValue(action.kind);
    if (kind !== undefined) out.kind = kind;
    if (action.diagnostics) out.diagnostics = action.diagnostics.map(plainDiagnostic);
    if (action.isPreferred) out.isPreferred = true;
    if (action.disabled) out.disabled = { reason: String(action.disabled.reason || action.disabled) };
    if (action.edit) out.edit = plainWorkspaceEdit(action.edit);
    if (action.command) out.command = plainCommand(action.command);
    out.data = { __omcProvider: providerId, __omcItem: index };
    return out;
  }
  function plainHint(hint) {
    const out = { position: plainPosition(hint.position) };
    out.label = typeof hint.label === "string" ? hint.label
      : (hint.label || []).map((part) => { const p = { value: String(part.value) }; if (part.tooltip !== undefined) p.tooltip = markdownText(part.tooltip); return p; });
    if (hint.kind !== undefined) out.kind = hint.kind;
    if (hint.tooltip !== undefined) out.tooltip = markdownText(hint.tooltip);
    if (hint.paddingLeft) out.paddingLeft = true;
    if (hint.paddingRight) out.paddingRight = true;
    return out;
  }
  const foldingKinds = { 1: "comment", 2: "imports", 3: "region" };

  /// What each kind's method is called and how its answer is put.
  function answer(entry, id, args, document, position, token) {
    const p = entry.provider;
    const options = args.options;
    switch (entry.kind) {
      case "completion":
        if (args.method === "resolve") {
          const list = completionLists.get(id) || [];
          const original = list[args.item];
          if (!original || typeof p.resolveCompletionItem !== "function") return [null, null];
          return [p.resolveCompletionItem(typeof original === "string" ? new CompletionItem(original) : original, token), (value) => value ? plainItem(value, id, args.item) : null];
        }
        // The third argument is the token and (as the first API had it) the context too.
        const context = { triggerKind: args.triggerCharacter ? 1 : 0, triggerCharacter: args.triggerCharacter || undefined };
        const tokenAndContext = Object.assign({ get isCancellationRequested() { return token.isCancellationRequested; },
          onCancellationRequested: token.onCancellationRequested }, context);
        return [p.provideCompletionItems(document, position, tokenAndContext, context), (value) => {
          if (!value) return null;
          const items = Array.isArray(value) ? value : value.items || [];
          completionLists.set(id, items);
          return { items: items.map((item, index) => plainItem(item, id, index)), isIncomplete: !Array.isArray(value) && !!value.isIncomplete };
        }];
      case "hover": return [p.provideHover(document, position, token), hoverText];
      case "formatting": return [p.provideDocumentFormattingEdits(document, options, token), (v) => v ? v.map(plainEdit) : null];
      case "rangeFormatting": return [p.provideDocumentRangeFormattingEdits(document, toRange(args.range), options, token), (v) => v ? v.map(plainEdit) : null];
      case "onTypeFormatting": return [p.provideOnTypeFormattingEdits(document, position, args.ch, options, token), (v) => v ? v.map(plainEdit) : null];
      case "definition": return [p.provideDefinition(document, position, token), plainLocations];
      case "typeDefinition": return [p.provideTypeDefinition(document, position, token), plainLocations];
      case "implementation": return [p.provideImplementation(document, position, token), plainLocations];
      case "references": return [p.provideReferences(document, position, { includeDeclaration: args.includeDeclaration !== false }, token), plainLocations];
      case "documentSymbol": return [p.provideDocumentSymbols(document, token), (v) => v ? v.map(plainSymbol) : null];
      case "workspaceSymbol": return [p.provideWorkspaceSymbols(String(args.query || ""), token), (v) => v ? v.map(plainSymbol) : null];
      case "codeAction": {
        const context = { diagnostics: (args.diagnostics || []).map(apiDiagnostic), only: args.only ? new CodeActionKind(args.only[0]) : undefined, triggerKind: 1 };
        return [p.provideCodeActions(document, toRange(args.range), context, token), (v) => v ? v.map((a, i) => plainCodeAction(a, id, i)) : null];
      }
      case "codeLens":
        if (args.method === "resolve") {
          const lens = (codeLensLists.get(id) || [])[args.item];
          if (!lens || typeof p.resolveCodeLens !== "function") return [null, null];
          return [p.resolveCodeLens(lens, token), (v) => v ? { range: plainRange(v.range), command: plainCommand(v.command), data: { __omcProvider: id, __omcItem: args.item } } : null];
        }
        return [p.provideCodeLenses(document, token), (v) => {
          if (!v) return null;
          codeLensLists.set(id, v);
          return v.map((lens, i) => ({ range: plainRange(lens.range), command: plainCommand(lens.command), data: { __omcProvider: id, __omcItem: i } }));
        }];
      case "signatureHelp": {
        const context = { triggerKind: args.triggerCharacter ? 2 : args.isRetrigger ? 3 : 1, triggerCharacter: args.triggerCharacter || undefined,
          isRetrigger: !!args.isRetrigger, activeSignatureHelp: undefined };
        return [p.provideSignatureHelp(document, position, token, context), plainSignatureHelp];
      }
      case "rename":
        if (args.method === "prepare") {
          if (typeof p.prepareRename !== "function") return [{ defaultBehavior: true }, (v) => v];
          return [p.prepareRename(document, position, token), (v) => {
            if (!v) return null;
            if (v.start) return { range: plainRange(v) };
            if (v.defaultBehavior) return v;
            return { range: plainRange(v.range), placeholder: v.placeholder !== undefined ? String(v.placeholder) : undefined };
          }];
        }
        return [p.provideRenameEdits(document, position, String(args.newName), token), plainWorkspaceEdit];
      case "documentHighlight": return [p.provideDocumentHighlights(document, position, token), (v) => v ? v.map((h) => ({ range: plainRange(h.range), kind: (h.kind || 0) + 1 })) : null];
      case "documentLink":
        if (args.method === "resolve") {
          const link = (linkLists.get(id) || [])[args.item];
          if (!link || typeof p.resolveDocumentLink !== "function") return [null, null];
          return [p.resolveDocumentLink(link, token), (v) => v && v.target ? { range: plainRange(v.range), target: uriOf(v.target) } : null];
        }
        return [p.provideDocumentLinks(document, token), (v) => {
          if (!v) return null;
          linkLists.set(id, v);
          return v.map((link, i) => {
            const out = { range: plainRange(link.range), data: { __omcProvider: id, __omcItem: i } };
            if (link.target) out.target = uriOf(link.target);
            if (link.tooltip) out.tooltip = String(link.tooltip);
            return out;
          });
        }];
      case "foldingRange": return [p.provideFoldingRanges(document, {}, token), (v) => v ? v.map((r) => {
        const out = { startLine: r.start, endLine: r.end };
        if (foldingKinds[r.kind]) out.kind = foldingKinds[r.kind];
        return out;
      }) : null];
      case "inlayHint": return [p.provideInlayHints(document, toRange(args.range), token), (v) => v ? v.map(plainHint) : null];
      case "semanticTokens": return [p.provideDocumentSemanticTokens(document, token), (v) => v ? { data: Array.from(v.data || []) } : null];
    }
    return [null, null];
  }
  global.__omcProvide = (id, token, argsJSON) => {
    const entry = providers.get(id);
    if (!entry) { native.commandDone(token, null, null); return; }
    const args = JSON.parse(argsJSON);
    const document = args.document ? new TextDocument(args.document) : undefined;
    const position = args.position ? new Position(args.position.line, args.position.character) : undefined;
    const source = new CancellationTokenSource();
    cancellations.set(token, source);
    const done = (error, json) => { cancellations.delete(token); native.commandDone(token, error, json); };
    let result, convert;
    try {
      [result, convert] = answer(entry, id, args, document, position, source.token);
    } catch (e) { done(errorText(e), null); return; }
    Promise.resolve(result).then((value) => {
      if (source.token.isCancellationRequested) { done(null, null); return; }
      let out = null;
      try { out = convert && value !== undefined && value !== null ? convert(value) : null; } catch (e) { done(errorText(e), null); return; }
      done(null, toJSON(out === undefined ? null : out));
    }, (e) => done(source.token.isCancellationRequested ? null : errorText(e), null));
  };
  global.__omcCancel = (token) => {
    const source = cancellations.get(token);
    if (source) { cancellations.delete(token); source.cancel(); }
  };

  // Language servers: requests and notifications in their own protocol.
  const serverHandlers = new Map();
  function serverKey(server, method, request) { return (request ? "request:" : "") + server + "\n" + method; }
  function languageServer(server) {
    const listen = (method, handler, request) => {
      if (typeof handler !== "function") throw new TypeError("The handler must be a function");
      const key = serverKey(server, method, request);
      serverHandlers.set(key, handler);
      call("languageServer.listen", { id: server, method, request });
      return new Disposable(() => {
        if (serverHandlers.get(key) !== handler) return;
        serverHandlers.delete(key);
        call("languageServer.listen", { id: server, method, request, remove: true });
      });
    };
    return {
      id: server,
      sendRequest(method, params) { return callAsync("languageServer.request", { id: server, method: String(method), params: params === undefined ? null : params }); },
      sendNotification(method, params) { call("languageServer.notify", { id: server, method: String(method), params: params === undefined ? null : params }); },
      onNotification(method, handler) { return listen(String(method), handler, false); },
      onRequest(method, handler) { return listen(String(method), handler, true); },
    };
  }
  global.__omcServerRequest = (token, json) => {
    const data = JSON.parse(json);
    const handler = serverHandlers.get(serverKey(data.server, data.method, true));
    if (!handler) { native.commandDone(token, null, toJSON({ __omcNoHandler: true })); return; }
    let result;
    try { result = handler(data.params); } catch (e) { native.commandDone(token, errorText(e), null); return; }
    Promise.resolve(result).then((value) => native.commandDone(token, null, toJSON({ result: value === undefined ? null : value })),
      (e) => native.commandDone(token, errorText(e), null));
  };
  function serverNotification(data) {
    const handler = serverHandlers.get(serverKey(data.server, data.method, false));
    if (handler) { try { handler(data.params); } catch (e) { report(e); } }
  }
  function registerLanguageServer(definition) {
    if (!definition || typeof definition !== "object") throw new TypeError("The definition must be an object");
    call("languages.registerServer", definition);
    return new Disposable(() => call("languages.unregisterServer", { id: definition.id }));
  }

  const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
  const CompletionItemKind = { Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7,
    Module: 8, Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15, File: 16, Reference: 17,
    Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24 };
  function createDiagnosticCollection(name) {
    const id = nextId++;
    const label = name || "extension";
    const pathOf = (target) => typeof target === "string" ? target : target.path;
    return {
      name: label,
      set(target, diagnostics) {
        call("diagnostics.set", { id, name: label, path: pathOf(target), diagnostics: (diagnostics || []).map((d) => ({
          range: plainRange(d.range), message: String(d.message),
          severity: typeof d.severity === "number" ? d.severity : DiagnosticSeverity.Error,
          source: d.source !== undefined ? String(d.source) : label,
        })) });
      },
      delete(target) { call("diagnostics.set", { id, name: label, path: pathOf(target), diagnostics: [] }); },
      clear() { call("diagnostics.clear", { id }); },
      dispose() { call("diagnostics.clear", { id }); },
    };
  }

  const omc = {
    version: native.version,
    DiagnosticSeverity, CompletionItemKind, SymbolKind, DocumentHighlightKind, FoldingRangeKind, InlayHintKind,
    SignatureHelpTriggerKind, CodeActionKind,
    languages: {
      registerCompletionItemProvider(selector, provider, ...triggerCharacters) {
        return registerProvider("completion", selector, provider, { triggerCharacters: triggerCharacters.map(String),
          resolves: typeof (provider && provider.resolveCompletionItem) === "function" });
      },
      registerHoverProvider(selector, provider) { return registerProvider("hover", selector, provider); },
      registerDocumentFormattingEditProvider(selector, provider) { return registerProvider("formatting", selector, provider); },
      registerDocumentRangeFormattingEditProvider(selector, provider) { return registerProvider("rangeFormatting", selector, provider); },
      registerOnTypeFormattingEditProvider(selector, provider, firstTriggerCharacter, ...moreTriggerCharacters) {
        return registerProvider("onTypeFormatting", selector, provider, { triggerCharacters: [firstTriggerCharacter, ...moreTriggerCharacters].map(String) });
      },
      registerDefinitionProvider(selector, provider) { return registerProvider("definition", selector, provider); },
      registerTypeDefinitionProvider(selector, provider) { return registerProvider("typeDefinition", selector, provider); },
      registerImplementationProvider(selector, provider) { return registerProvider("implementation", selector, provider); },
      registerReferenceProvider(selector, provider) { return registerProvider("references", selector, provider); },
      registerDocumentSymbolProvider(selector, provider) { return registerProvider("documentSymbol", selector, provider); },
      registerWorkspaceSymbolProvider(provider) { return registerProvider("workspaceSymbol", "*", provider); },
      registerCodeActionsProvider(selector, provider, metadata) {
        const kinds = ((metadata && metadata.providedCodeActionKinds) || []).map(kindValue);
        return registerProvider("codeAction", selector, provider, { providedCodeActionKinds: kinds });
      },
      registerCodeLensProvider(selector, provider) {
        return registerProvider("codeLens", selector, provider, { resolves: typeof provider.resolveCodeLens === "function" });
      },
      registerSignatureHelpProvider(selector, provider, ...rest) {
        // (…, "(", ",") or (…, { triggerCharacters, retriggerCharacters }).
        const metadata = rest.length === 1 && typeof rest[0] === "object" ? rest[0] : { triggerCharacters: rest };
        return registerProvider("signatureHelp", selector, provider, {
          triggerCharacters: (metadata.triggerCharacters || []).map(String), retriggerCharacters: (metadata.retriggerCharacters || []).map(String) });
      },
      registerRenameProvider(selector, provider) {
        return registerProvider("rename", selector, provider, { prepares: typeof provider.prepareRename === "function" });
      },
      registerDocumentHighlightProvider(selector, provider) { return registerProvider("documentHighlight", selector, provider); },
      registerDocumentLinkProvider(selector, provider) {
        return registerProvider("documentLink", selector, provider, { resolves: typeof provider.resolveDocumentLink === "function" });
      },
      registerFoldingRangeProvider(selector, provider) { return registerProvider("foldingRange", selector, provider); },
      registerInlayHintsProvider(selector, provider) { return registerProvider("inlayHint", selector, provider); },
      registerDocumentSemanticTokensProvider(selector, provider, legend) {
        if (!legend || !Array.isArray(legend.tokenTypes)) throw new TypeError("A SemanticTokensLegend is needed");
        return registerProvider("semanticTokens", selector, provider, { legend: { tokenTypes: legend.tokenTypes.map(String), tokenModifiers: (legend.tokenModifiers || []).map(String) } });
      },
      registerLanguageServer,
      getLanguageServer(id) { return languageServer(String(id)); },
      getLanguages() { return callAsync("languages.list", null); },
      setTextDocumentLanguage(document, languageId) {
        return callAsync("languages.setDocumentLanguage", { path: typeof document === "string" ? document : document.path, languageId: String(languageId) })
          .then((info) => new TextDocument(info));
      },
      createDiagnosticCollection,
    },
    Disposable, EventEmitter, Position, Range, StatusBarAlignment, Location, TextEdit, WorkspaceEdit, SnippetString, MarkdownString,
    Hover, CompletionItem, CompletionList, CodeAction, CodeLens, ParameterInformation, SignatureInformation, SignatureHelp,
    DocumentSymbol, SymbolInformation, DocumentHighlight, DocumentLink, FoldingRange, InlayHint, SemanticTokensLegend,
    SemanticTokens, SemanticTokensBuilder, CancellationTokenSource, CancellationError,
    Uri: { file: (path) => ({ scheme: "file", path: String(path), fsPath: String(path), toString: () => uriOf(String(path)) }),
           parse: (text) => { const path = pathOfURI(String(text)); return { scheme: "file", path, fsPath: path, toString: () => String(text) }; } },
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
      get folders() { return call("workspace.folders", null); },
      getWorkspaceFolder(path) { return call("workspace.getWorkspaceFolder", { path: String(path) }) || undefined; },
      get textDocuments() { return call("workspace.documents", null).map((info) => new TextDocument(info)); },
      openTextDocument(path) { return callAsync("workspace.openTextDocument", { path }).then((info) => new TextDocument(info)); },
      getConfiguration: configuration,
      onDidOpenTextDocument: events.didOpenTextDocument.event,
      onDidCloseTextDocument: events.didCloseTextDocument.event,
      onDidSaveTextDocument: events.didSaveTextDocument.event,
      onDidChangeTextDocument: events.didChangeTextDocument.event,
      onDidChangeConfiguration: events.didChangeConfiguration.event,
      onDidChangeWorkspaceFolders: events.didChangeWorkspaceFolders.event,
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
