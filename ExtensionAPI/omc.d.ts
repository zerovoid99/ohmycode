// Type definitions for the Oh My Code extension API (`require("omc")`), version 0.1.0.
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

  export namespace workspace {
    /** The open folder. */
    const rootPath: string | undefined;
    const textDocuments: TextDocument[];
    /** Paths are relative to the open folder, or absolute. */
    function openTextDocument(path: string): Promise<TextDocument>;
    /** Settings the extension declares in "contributes.configuration". */
    function getConfiguration(section?: string): Configuration;
    const onDidOpenTextDocument: Event<TextDocument>;
    const onDidCloseTextDocument: Event<TextDocument>;
    const onDidSaveTextDocument: Event<TextDocument>;
    /** Shortly after edits settle. */
    const onDidChangeTextDocument: Event<{ document: TextDocument }>;
    const onDidChangeConfiguration: Event<{ affectsConfiguration(section: string): boolean }>;
    /** Files in the open folder; elsewhere needs the "fileSystem" permission. */
    namespace fs {
      function readFile(path: string): Promise<string>;
      function writeFile(path: string, text: string): Promise<void>;
      function readDirectory(path: string): Promise<{ name: string; isDirectory: boolean }[]>;
      function exists(path: string): Promise<boolean>;
    }
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
