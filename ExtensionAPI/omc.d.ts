// Type definitions for the Oh My Code extension API (`require("omc")`), version 0.2.0.
//
// Extensions run in JavaScriptCore, one isolated context each, off the main thread. JavaScript
// that runs 5 seconds without returning (an endless loop) is stopped. The main
// file is CommonJS: export `activate(context)` (and optionally `deactivate()`). Write
// TypeScript and compile it (tsc with "module": "commonjs", or esbuild --format=cjs); only
// "omc" can be required, so bundle any other dependency into the main file.

declare module "omc" {
  export const version: string;

  export class Disposable {
    constructor(callOnDispose: () => void);
    dispose(): void;
    static from(...disposables: { dispose(): unknown }[]): Disposable;
  }

  export type Event<T> = (listener: (e: T) => unknown, thisArg?: unknown, disposables?: Disposable[]) => Disposable;

  export class EventEmitter<T> {
    readonly event: Event<T>;
    fire(data: T): void;
    dispose(): void;
  }

  /** Zero-based line, and character as a UTF-16 offset in the line (like the LSP). */
  export class Position {
    constructor(line: number, character: number);
    readonly line: number;
    readonly character: number;
  }

  export class Range {
    constructor(start: Position, end: Position);
    constructor(startLine: number, startCharacter: number, endLine: number, endCharacter: number);
    readonly start: Position;
    readonly end: Position;
    readonly isEmpty: boolean;
  }

  export interface ExtensionContext {
    readonly extensionId: string;
    readonly extensionPath: string;
    /** Disposed when the extension stops. */
    readonly subscriptions: { dispose(): unknown }[];
    /** Values kept across restarts (JSON). */
    readonly storage: {
      get<T>(key: string, defaultValue?: T): T | undefined;
      update(key: string, value: unknown): Promise<void>;
    };
  }

  /** A snapshot of an open document: read it again after changes. */
  export interface TextDocument {
    readonly path: string;
    readonly fileName: string;
    readonly languageId: string;
    readonly isDirty: boolean;
    readonly lineCount: number;
    readonly version: number;
    getText(range?: Range): string;
    lineAt(line: number | Position): { lineNumber: number; text: string };
    save(): Promise<boolean>;
  }

  export interface TextEditorEdit {
    replace(range: Range, text: string): void;
    insert(position: Position, text: string): void;
    delete(range: Range): void;
  }

  /** A snapshot of the active editor: `omc.window.activeTextEditor` gives a fresh one. */
  export interface TextEditor {
    readonly document: TextDocument;
    readonly selection: Range;
    readonly selections: Range[];
    /** Applies the edits as one undoable step. */
    edit(callback: (edit: TextEditorEdit) => void): Promise<boolean>;
    edit(edits: { range: Range; text: string }[]): Promise<boolean>;
    select(range: Range | Range[]): void;
  }

  export interface QuickPickItem {
    label: string;
    description?: string;
    detail?: string;
  }

  export enum StatusBarAlignment { Left = 1, Right = 2 }

  export interface StatusBarItem {
    /** "$(symbol)" shows an SF Symbol, e.g. "$(clock) 3 min". */
    text: string;
    tooltip?: string;
    /** A command id run on click. */
    command?: string;
    show(): void;
    hide(): void;
    dispose(): void;
  }

  export interface Configuration {
    get<T>(key: string, defaultValue?: T): T | undefined;
    update(key: string, value: unknown): Promise<void>;
  }

  export namespace commands {
    function registerCommand(command: string, callback: (...args: any[]) => unknown, thisArg?: unknown): Disposable;
    /** Runs an extension's command or a built-in one (as listed by getCommands). */
    function executeCommand<T = unknown>(command: string, ...args: unknown[]): Promise<T>;
    function getCommands(): Promise<string[]>;
  }

  export namespace window {
    const activeTextEditor: TextEditor | undefined;
    const onDidChangeActiveTextEditor: Event<TextEditor | undefined>;
    /** Resolves with the item clicked, or undefined when dismissed. */
    function showInformationMessage(message: string, ...items: string[]): Promise<string | undefined>;
    function showWarningMessage(message: string, ...items: string[]): Promise<string | undefined>;
    function showErrorMessage(message: string, ...items: string[]): Promise<string | undefined>;
    function showInputBox(options?: { prompt?: string; value?: string; placeHolder?: string }): Promise<string | undefined>;
    function showQuickPick<T extends string | QuickPickItem>(items: T[] | Promise<T[]>, options?: { placeHolder?: string }): Promise<T | undefined>;
    function showTextDocument(document: TextDocument | string): Promise<TextEditor | undefined>;
    function createStatusBarItem(alignment?: StatusBarAlignment, priority?: number): StatusBarItem;
  }

  /** One of the window's folders. */
  export interface WorkspaceFolder {
    /** Absolute. */
    readonly path: string;
    /** Its label in the Explorer (unique among the window's folders). */
    readonly name: string;
    /** Its place in `workspace.folders`. */
    readonly index: number;
  }

  export namespace workspace {
    /** The open folder; with several, the first. */
    const rootPath: string | undefined;
    /** The window's folders, in order (empty with none open). */
    const folders: WorkspaceFolder[];
    /** The folder a file is in (the innermost); relative paths are from the first folder. */
    function getWorkspaceFolder(path: string): WorkspaceFolder | undefined;
    const textDocuments: TextDocument[];
    /** Paths are relative to the first folder, or absolute. */
    function openTextDocument(path: string): Promise<TextDocument>;
    /** Settings the extension declares in "contributes.configuration". */
    function getConfiguration(section?: string): Configuration;
    const onDidOpenTextDocument: Event<TextDocument>;
    const onDidCloseTextDocument: Event<TextDocument>;
    const onDidSaveTextDocument: Event<TextDocument>;
    /** Shortly after edits settle. */
    const onDidChangeTextDocument: Event<{ document: TextDocument }>;
    const onDidChangeConfiguration: Event<{ affectsConfiguration(section: string): boolean }>;
    /** Folders added to or removed from the window. */
    const onDidChangeWorkspaceFolders: Event<{ added: WorkspaceFolder[]; removed: WorkspaceFolder[] }>;
    /**
     * Files in any of the window's folders (relative paths are from the first folder);
     * elsewhere needs the "fileSystem" permission.
     */
    namespace fs {
      function readFile(path: string): Promise<string>;
      function writeFile(path: string, text: string): Promise<void>;
      function readDirectory(path: string): Promise<{ name: string; isDirectory: boolean }[]>;
      function exists(path: string): Promise<boolean>;
    }
  }

  /** A language id ("swift", "typescript", "plaintext"…), "*" for all, or a list. */
  export type DocumentSelector = string | { language: string } | (string | { language: string })[];

  export enum CompletionItemKind {
    Text = 0, Method = 1, Function = 2, Constructor = 3, Field = 4, Variable = 5, Class = 6, Interface = 7,
    Module = 8, Property = 9, Unit = 10, Value = 11, Enum = 12, Keyword = 13, Snippet = 14, Color = 15, File = 16,
    Reference = 17, Folder = 18, EnumMember = 19, Constant = 20, Struct = 21, Event = 22, Operator = 23, TypeParameter = 24,
  }

  export interface CompletionItem {
    label: string;
    detail?: string;
    kind?: CompletionItemKind;
    /** Inserted instead of the label. */
    insertText?: string;
    filterText?: string;
    sortText?: string;
    /** What the item replaces (by default the word before the cursor). */
    range?: Range;
  }

  type ProviderResult<T> = T | undefined | null | Promise<T | undefined | null>;

  export interface CompletionItemProvider {
    provideCompletionItems(document: TextDocument, position: Position, context: { triggerCharacter?: string }):
      ProviderResult<(CompletionItem | string)[] | { items: (CompletionItem | string)[]; isIncomplete?: boolean }>;
  }

  export interface HoverProvider {
    /** Markdown: one string, several, or { contents }. */
    provideHover(document: TextDocument, position: Position): ProviderResult<string | string[] | { contents: string | string[] }>;
  }

  export interface DocumentFormattingEditProvider {
    provideDocumentFormattingEdits(document: TextDocument, options: { tabSize: number; insertSpaces: boolean }):
      ProviderResult<{ range: Range; newText: string }[]>;
  }

  export enum DiagnosticSeverity { Error = 0, Warning = 1, Information = 2, Hint = 3 }

  export interface Diagnostic {
    range: Range;
    message: string;
    severity?: DiagnosticSeverity;
    /** Shown with the message; the collection's name by default. */
    source?: string;
  }

  export interface DiagnosticCollection {
    readonly name: string;
    /** Replaces the file's diagnostics from this collection (a path relative to the open folder, or absolute). */
    set(document: TextDocument | string, diagnostics: Diagnostic[]): void;
    delete(document: TextDocument | string): void;
    clear(): void;
    dispose(): void;
  }

  /**
   * Language features, shown together with the language server's. Each provider has 1.5
   * seconds to answer; a formatter from an extension is used before the server's.
   */
  export namespace languages {
    function registerCompletionItemProvider(selector: DocumentSelector, provider: CompletionItemProvider, ...triggerCharacters: string[]): Disposable;
    function registerHoverProvider(selector: DocumentSelector, provider: HoverProvider): Disposable;
    function registerDocumentFormattingEditProvider(selector: DocumentSelector, provider: DocumentFormattingEditProvider): Disposable;
    /** Diagnostics are removed when the extension stops. */
    function createDiagnosticCollection(name?: string): DiagnosticCollection;
  }

  /** Needs the "process" permission. Programs are found on the login shell's PATH. */
  export namespace process {
    function run(command: string, args?: string[], options?: { cwd?: string; input?: string; timeout?: number }):
      Promise<{ code: number; stdout: string; stderr: string }>;
  }

  /** Needs the "network" permission. */
  export namespace net {
    function fetch(url: string, options?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<{
      status: number; ok: boolean; headers: Record<string, string>; text(): Promise<string>; json<T = unknown>(): Promise<T>;
    }>;
  }
}

declare function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
declare function clearTimeout(id: number): void;
declare function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: any[]): number;
declare function clearInterval(id: number): void;
declare const console: {
  log(...data: unknown[]): void; info(...data: unknown[]): void; debug(...data: unknown[]): void;
  warn(...data: unknown[]): void; error(...data: unknown[]): void;
};
