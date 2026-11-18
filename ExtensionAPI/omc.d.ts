// Type definitions for the Oh My Code extension API (`require("omc")`), version 0.3.0.
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
    /** Values kept across restarts (JSON), shared by every window and folder; removed on uninstall. */
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
    /** Its file as a URI (for `Location`, `WorkspaceEdit`). */
    readonly uri: Uri;
    /** The word at `position`: letters, digits, _ and $, or what `regex` matches on the line. */
    getWordRangeAtPosition(position: Position, regex?: RegExp): Range | undefined;
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
     * elsewhere, and writing inside a .git folder, needs the "fileSystem" permission.
     */
    namespace fs {
      function readFile(path: string): Promise<string>;
      function writeFile(path: string, text: string): Promise<void>;
      function readDirectory(path: string): Promise<{ name: string; isDirectory: boolean }[]>;
      function exists(path: string): Promise<boolean>;
    }
  }

  /**
   * Which documents a provider is for: a language id ("swift", "toy", "*" for all), a filter
   * (every given part must match: `language`, `scheme` "file", `pattern` a glob on the path
   * such as "**\/*.test.toy"), or a list of those (any may match).
   */
  export type DocumentFilter = { language?: string; scheme?: string; pattern?: string };
  export type DocumentSelector = string | DocumentFilter | (string | DocumentFilter)[];

  type ProviderResult<T> = T | undefined | null | Promise<T | undefined | null>;

  /**
   * Passed to every provider: set when the editor no longer needs the answer (the user typed
   * on, moved, or the provider took longer than 1.5 seconds). Stop work and return early.
   */
  export interface CancellationToken {
    readonly isCancellationRequested: boolean;
    readonly onCancellationRequested: Event<void>;
  }

  export class CancellationTokenSource {
    readonly token: CancellationToken;
    cancel(): void;
    dispose(): void;
  }

  /** Thrown or rejected with to say a provider stopped because it was cancelled. */
  export class CancellationError extends Error {}

  /** A file URI ("file:///…") or a path (relative paths are from the first workspace folder). */
  export type UriLike = string | Uri | { path: string };

  export interface Uri {
    readonly scheme: string;
    readonly path: string;
    readonly fsPath: string;
    toString(): string;
  }
  export namespace Uri {
    function file(path: string): Uri;
    /** Only file URIs: `path` is the decoded path, and `scheme` is always "file". */
    function parse(value: string): Uri;
  }

  export class Location {
    constructor(uri: UriLike, rangeOrPosition: Range | Position);
    uri: UriLike;
    range: Range;
  }

  /** A link to a target, with the part of the source it's for (definition providers may return these). */
  export interface LocationLink {
    originSelectionRange?: Range;
    targetUri: UriLike;
    targetRange: Range;
    targetSelectionRange?: Range;
  }

  /** Markdown text (VS Code's `MarkdownString`). */
  export class MarkdownString {
    constructor(value?: string, supportThemeIcons?: boolean);
    value: string;
    appendText(value: string): MarkdownString;
    appendMarkdown(value: string): MarkdownString;
    appendCodeblock(value: string, language?: string): MarkdownString;
  }
  export type MarkupContent = string | MarkdownString;

  /** A snippet to insert: `$1`, `${2:default}`, `${3|a,b|}`, `$0` and variables, as TextMate snippets. */
  export class SnippetString {
    constructor(value?: string);
    value: string;
    appendText(text: string): SnippetString;
    appendTabstop(number?: number): SnippetString;
    appendPlaceholder(value: string | ((snippet: SnippetString) => unknown), number?: number): SnippetString;
    appendChoice(values: string[], number?: number): SnippetString;
    appendVariable(name: string, defaultValue?: string): SnippetString;
  }

  export class TextEdit {
    constructor(range: Range, newText: string);
    range: Range;
    newText: string;
    static replace(range: Range, newText: string): TextEdit;
    static insert(position: Position, newText: string): TextEdit;
    static delete(range: Range): TextEdit;
  }

  /** Edits to one or more files, applied together (each file one undo step). */
  export class WorkspaceEdit {
    replace(uri: UriLike, range: Range, newText: string): void;
    insert(uri: UriLike, position: Position, newText: string): void;
    delete(uri: UriLike, range: Range): void;
    set(uri: UriLike, edits: TextEdit[]): void;
    get(uri: UriLike): TextEdit[];
    has(uri: UriLike): boolean;
    entries(): [string, TextEdit[]][];
    readonly size: number;
  }

  /** A command to run: an extension's own (`commands.registerCommand`) or a built-in one. */
  export interface Command {
    title: string;
    command: string;
    tooltip?: string;
    arguments?: unknown[];
  }

  // Completion

  export enum CompletionItemKind {
    Text = 0, Method = 1, Function = 2, Constructor = 3, Field = 4, Variable = 5, Class = 6, Interface = 7,
    Module = 8, Property = 9, Unit = 10, Value = 11, Enum = 12, Keyword = 13, Snippet = 14, Color = 15, File = 16,
    Reference = 17, Folder = 18, EnumMember = 19, Constant = 20, Struct = 21, Event = 22, Operator = 23, TypeParameter = 24,
  }

  export class CompletionItem {
    constructor(label: string, kind?: CompletionItemKind);
    label: string | { label: string; detail?: string; description?: string };
    kind?: CompletionItemKind;
    /** Shown beside the label. */
    detail?: string;
    /** Markdown about the item (shown when it's pointed at). */
    documentation?: MarkupContent;
    /** Inserted instead of the label; a SnippetString has placeholders Tab moves through. */
    insertText?: string | SnippetString;
    /** What typing is matched against (the label by default). */
    filterText?: string;
    /** How it sorts among equally good matches (the label by default). */
    sortText?: string;
    preselect?: boolean;
    /** What it replaces (by default the word before the cursor); `{ inserting, replacing }` as VS Code has it. */
    range?: Range | { inserting: Range; replacing: Range };
    /** Edits elsewhere made with it (an import); they mustn't overlap the insertion. */
    additionalTextEdits?: TextEdit[];
    /** Typing one of these while the item is selected accepts it first. */
    commitCharacters?: string[];
    /** Run after it's inserted. */
    command?: Command;
  }

  export class CompletionList {
    constructor(items?: CompletionItem[], isIncomplete?: boolean);
    items: CompletionItem[];
    /** Asked again as the user types on. */
    isIncomplete: boolean;
  }

  export interface CompletionContext {
    /** 0 invoked (typing, Esc), 1 a trigger character. */
    readonly triggerKind: number;
    readonly triggerCharacter?: string;
  }

  export interface CompletionItemProvider<T extends CompletionItem = CompletionItem> {
    /**
     * The items at `position`. The third argument is the cancellation token; it also carries
     * the context's `triggerCharacter` (as API 0.2 passed the context there).
     */
    provideCompletionItems(document: TextDocument, position: Position, token: CancellationToken & CompletionContext,
                           context: CompletionContext): ProviderResult<(T | string)[] | CompletionList | { items: (T | string)[]; isIncomplete?: boolean }>;
    /** Fills in what was left out of the list (documentation, additional edits) for an item about to be inserted. */
    resolveCompletionItem?(item: T, token: CancellationToken): ProviderResult<T>;
  }

  // Hover, signature help

  export class Hover {
    constructor(contents: MarkupContent | MarkupContent[], range?: Range);
    contents: MarkupContent[];
    range?: Range;
  }

  export interface HoverProvider {
    /** Markdown: one string, several, a MarkdownString, a Hover or { contents }. */
    provideHover(document: TextDocument, position: Position, token: CancellationToken):
      ProviderResult<Hover | MarkupContent | MarkupContent[] | { contents: MarkupContent | MarkupContent[] }>;
  }

  export class ParameterInformation {
    constructor(label: string | [number, number], documentation?: MarkupContent);
    /** The parameter's text, or its [start, end) offsets in the signature's label. */
    label: string | [number, number];
    documentation?: MarkupContent;
  }

  export class SignatureInformation {
    constructor(label: string, documentation?: MarkupContent);
    label: string;
    documentation?: MarkupContent;
    parameters: ParameterInformation[];
    activeParameter?: number;
  }

  export class SignatureHelp {
    signatures: SignatureInformation[];
    activeSignature: number;
    activeParameter: number;
  }

  export enum SignatureHelpTriggerKind { Invoke = 1, TriggerCharacter = 2, ContentChange = 3 }

  export interface SignatureHelpContext {
    readonly triggerKind: SignatureHelpTriggerKind;
    readonly triggerCharacter?: string;
    readonly isRetrigger: boolean;
  }

  export interface SignatureHelpProvider {
    provideSignatureHelp(document: TextDocument, position: Position, token: CancellationToken, context: SignatureHelpContext):
      ProviderResult<SignatureHelp>;
  }

  export interface SignatureHelpProviderMetadata {
    /** Open signature help: "(", ",". */
    readonly triggerCharacters: readonly string[];
    /** Update it once it's open. */
    readonly retriggerCharacters: readonly string[];
  }

  // Navigation

  export type Definition = Location | Location[];

  export interface DefinitionProvider {
    provideDefinition(document: TextDocument, position: Position, token: CancellationToken): ProviderResult<Definition | LocationLink[]>;
  }
  export interface TypeDefinitionProvider {
    provideTypeDefinition(document: TextDocument, position: Position, token: CancellationToken): ProviderResult<Definition | LocationLink[]>;
  }
  export interface ImplementationProvider {
    provideImplementation(document: TextDocument, position: Position, token: CancellationToken): ProviderResult<Definition | LocationLink[]>;
  }
  export interface ReferenceProvider {
    provideReferences(document: TextDocument, position: Position, context: { includeDeclaration: boolean }, token: CancellationToken):
      ProviderResult<Location[]>;
  }

  export enum SymbolKind {
    File = 0, Module = 1, Namespace = 2, Package = 3, Class = 4, Method = 5, Property = 6, Field = 7, Constructor = 8,
    Enum = 9, Interface = 10, Function = 11, Variable = 12, Constant = 13, String = 14, Number = 15, Boolean = 16,
    Array = 17, Object = 18, Key = 19, Null = 20, EnumMember = 21, Struct = 22, Event = 23, Operator = 24, TypeParameter = 25,
  }

  /** A declaration in the Outline and breadcrumbs: `range` is all of it, `selectionRange` its name. */
  export class DocumentSymbol {
    constructor(name: string, detail: string, kind: SymbolKind, range: Range, selectionRange: Range);
    name: string;
    detail: string;
    kind: SymbolKind;
    range: Range;
    selectionRange: Range;
    children: DocumentSymbol[];
  }

  export class SymbolInformation {
    constructor(name: string, kind: SymbolKind, containerName: string, location: Location);
    name: string;
    kind: SymbolKind;
    containerName: string;
    location: Location;
  }

  export interface DocumentSymbolProvider {
    provideDocumentSymbols(document: TextDocument, token: CancellationToken): ProviderResult<DocumentSymbol[] | SymbolInformation[]>;
  }
  export interface WorkspaceSymbolProvider {
    /** Symbols named like `query` anywhere (Go to Symbol in Workspace). */
    provideWorkspaceSymbols(query: string, token: CancellationToken): ProviderResult<SymbolInformation[]>;
  }

  export enum DocumentHighlightKind { Text = 0, Read = 1, Write = 2 }
  export class DocumentHighlight {
    constructor(range: Range, kind?: DocumentHighlightKind);
    range: Range;
    kind: DocumentHighlightKind;
  }
  export interface DocumentHighlightProvider {
    /** Where the symbol at `position` appears in the file (highlighted while the cursor is on it). */
    provideDocumentHighlights(document: TextDocument, position: Position, token: CancellationToken): ProviderResult<DocumentHighlight[]>;
  }

  export class DocumentLink {
    constructor(range: Range, target?: UriLike);
    range: Range;
    /** A URL or file; leave it out and fill it in `resolveDocumentLink`. */
    target?: UriLike;
    tooltip?: string;
  }
  export interface DocumentLinkProvider<T extends DocumentLink = DocumentLink> {
    provideDocumentLinks(document: TextDocument, token: CancellationToken): ProviderResult<T[]>;
    resolveDocumentLink?(link: T, token: CancellationToken): ProviderResult<T>;
  }

  // Code actions and lenses

  /** "quickfix", "refactor.extract", "source.organizeImports"… */
  export class CodeActionKind {
    static readonly Empty: CodeActionKind;
    static readonly QuickFix: CodeActionKind;
    static readonly Refactor: CodeActionKind;
    static readonly RefactorExtract: CodeActionKind;
    static readonly RefactorInline: CodeActionKind;
    static readonly RefactorRewrite: CodeActionKind;
    static readonly Source: CodeActionKind;
    static readonly SourceOrganizeImports: CodeActionKind;
    static readonly SourceFixAll: CodeActionKind;
    constructor(value: string);
    readonly value: string;
    append(part: string): CodeActionKind;
    contains(other: CodeActionKind): boolean;
    intersects(other: CodeActionKind): boolean;
  }

  /** An action in ⌘. and the lightbulb: its edit is made, then its command run. */
  export class CodeAction {
    constructor(title: string, kind?: CodeActionKind);
    title: string;
    kind?: CodeActionKind;
    edit?: WorkspaceEdit;
    command?: Command;
    /** The problems it fixes. */
    diagnostics?: Diagnostic[];
    /** Shown first (and offered by the lightbulb first). */
    isPreferred?: boolean;
    /** Listed but not runnable, with why. */
    disabled?: { reason: string };
  }

  export interface CodeActionContext {
    /** The problems in the range. */
    readonly diagnostics: readonly Diagnostic[];
    /** Only actions of this kind are wanted (Organize Imports asks for "source.organizeImports"). */
    readonly only?: CodeActionKind;
    readonly triggerKind: number;
  }

  export interface CodeActionProvider {
    provideCodeActions(document: TextDocument, range: Range, context: CodeActionContext, token: CancellationToken):
      ProviderResult<(CodeAction | Command)[]>;
  }

  export class CodeLens {
    constructor(range: Range, command?: Command);
    range: Range;
    /** Shown after the line; leave it out and fill it in `resolveCodeLens`. */
    command?: Command;
    readonly isResolved: boolean;
  }
  export interface CodeLensProvider<T extends CodeLens = CodeLens> {
    provideCodeLenses(document: TextDocument, token: CancellationToken): ProviderResult<T[]>;
    resolveCodeLens?(codeLens: T, token: CancellationToken): ProviderResult<T>;
  }

  // Rename

  export interface RenameProvider {
    /** The edits that rename the symbol at `position` (shown for review before they're made). */
    provideRenameEdits(document: TextDocument, position: Position, newName: string, token: CancellationToken): ProviderResult<WorkspaceEdit>;
    /** What's renamed (and the name to start from); throw to say nothing can be renamed there. */
    prepareRename?(document: TextDocument, position: Position, token: CancellationToken):
      ProviderResult<Range | { range: Range; placeholder: string }>;
  }

  // Formatting

  export interface FormattingOptions { tabSize: number; insertSpaces: boolean }

  export interface DocumentFormattingEditProvider {
    provideDocumentFormattingEdits(document: TextDocument, options: FormattingOptions, token: CancellationToken):
      ProviderResult<TextEdit[] | { range: Range; newText: string }[]>;
  }
  export interface DocumentRangeFormattingEditProvider {
    provideDocumentRangeFormattingEdits(document: TextDocument, range: Range, options: FormattingOptions, token: CancellationToken):
      ProviderResult<TextEdit[]>;
  }
  export interface OnTypeFormattingEditProvider {
    /** After `ch` (one of the trigger characters) was typed at `position`. */
    provideOnTypeFormattingEdits(document: TextDocument, position: Position, ch: string, options: FormattingOptions,
                                 token: CancellationToken): ProviderResult<TextEdit[]>;
  }

  // Folding, inlay hints, semantic tokens

  export enum FoldingRangeKind { Comment = 1, Imports = 2, Region = 3 }
  export class FoldingRange {
    /** Zero-based lines: `start` stays visible, the lines after it up to `end` fold. */
    constructor(start: number, end: number, kind?: FoldingRangeKind);
    start: number;
    end: number;
    kind?: FoldingRangeKind;
  }
  export interface FoldingRangeProvider {
    provideFoldingRanges(document: TextDocument, context: {}, token: CancellationToken): ProviderResult<FoldingRange[]>;
  }

  export enum InlayHintKind { Type = 1, Parameter = 2 }
  export interface InlayHintLabelPart { value: string; tooltip?: MarkupContent }
  export class InlayHint {
    constructor(position: Position, label: string | InlayHintLabelPart[], kind?: InlayHintKind);
    position: Position;
    label: string | InlayHintLabelPart[];
    kind?: InlayHintKind;
    tooltip?: MarkupContent;
    paddingLeft?: boolean;
    paddingRight?: boolean;
  }
  export interface InlayHintsProvider {
    provideInlayHints(document: TextDocument, range: Range, token: CancellationToken): ProviderResult<InlayHint[]>;
  }

  export class SemanticTokensLegend {
    /** The editor colors "type", "class", "function", "method", "property", "decorator"… (see the README). */
    constructor(tokenTypes: string[], tokenModifiers?: string[]);
    readonly tokenTypes: string[];
    readonly tokenModifiers: string[];
  }
  export class SemanticTokens {
    constructor(data: Uint32Array | number[], resultId?: string);
    /** 5 numbers per token, relative to the one before (the protocol's encoding). */
    readonly data: Uint32Array | number[];
  }
  export class SemanticTokensBuilder {
    constructor(legend?: SemanticTokensLegend);
    push(line: number, char: number, length: number, tokenType: number, tokenModifiers?: number): void;
    push(range: Range, tokenType: string, tokenModifiers?: string[]): void;
    build(): SemanticTokens;
  }
  export interface DocumentSemanticTokensProvider {
    provideDocumentSemanticTokens(document: TextDocument, token: CancellationToken): ProviderResult<SemanticTokens>;
  }

  // Diagnostics

  export enum DiagnosticSeverity { Error = 0, Warning = 1, Information = 2, Hint = 3 }

  export interface Diagnostic {
    range: Range;
    message: string;
    severity?: DiagnosticSeverity;
    /** Shown with the message; the collection's name by default. */
    source?: string;
    /** Accepted for VS Code compatibility; not shown for an extension's own diagnostics. */
    code?: string | number;
  }

  export interface DiagnosticCollection {
    readonly name: string;
    /** Replaces the file's diagnostics from this collection (a path relative to the open folder, or absolute). */
    set(document: TextDocument | string, diagnostics: Diagnostic[]): void;
    delete(document: TextDocument | string): void;
    clear(): void;
    dispose(): void;
  }

  // Language servers

  /**
   * A language server to start for files of `languages` (as `contributes.languageServers` in
   * extension.json declares one). Needs the "process" permission.
   */
  export interface LanguageServerDefinition {
    /** What settings call it: `languageServers.<id>.enabled`. */
    id: string;
    name?: string;
    /** Language ids ("rust", "toy"). Used before a built-in server for them. */
    languages: string[];
    /** A path (relative ones inside the extension's folder, `${extensionPath}` works too) or a program on the login shell's PATH. */
    command: string;
    args?: string[];
    env?: Record<string, string>;
    /** Sent in `initialize`. Strings `"${config:ext.key}"` become the extension's setting. */
    initializationOptions?: unknown;
    /** Answers `workspace/configuration` and is sent with `workspace/didChangeConfiguration`; `${config:…}` as above. */
    settings?: unknown;
    /** Files marking a project's root ("Cargo.toml"): the server starts in the nearest folder that has one. */
    rootPatterns?: string[];
    /** Only "stdio". */
    transport?: "stdio";
  }

  /** A running language server, for messages of its own protocol (rust-analyzer's `experimental/…`). */
  export interface LanguageServer {
    readonly id: string;
    /** Rejects when it isn't running (no file of its languages is open) or answers with an error. */
    sendRequest<R = unknown>(method: string, params?: unknown): Promise<R>;
    sendNotification(method: string, params?: unknown): void;
    /** Notifications the editor doesn't handle itself. */
    onNotification(method: string, handler: (params: any) => void): Disposable;
    /** Requests the editor doesn't answer itself: the handler's value (or promise) is the answer. */
    onRequest(method: string, handler: (params: any) => unknown): Disposable;
  }

  /**
   * Language features, shown together with the language server's (both are asked; for
   * definitions, references, symbols, code actions, lenses, highlights, links, hints and
   * tokens the answers are merged). Each provider has 1.5 seconds to answer; then its token
   * is cancelled and its answer left out. An extension's formatter and rename are used before
   * the server's.
   */
  export namespace languages {
    function registerCompletionItemProvider(selector: DocumentSelector, provider: CompletionItemProvider, ...triggerCharacters: string[]): Disposable;
    function registerHoverProvider(selector: DocumentSelector, provider: HoverProvider): Disposable;
    function registerDefinitionProvider(selector: DocumentSelector, provider: DefinitionProvider): Disposable;
    function registerTypeDefinitionProvider(selector: DocumentSelector, provider: TypeDefinitionProvider): Disposable;
    function registerImplementationProvider(selector: DocumentSelector, provider: ImplementationProvider): Disposable;
    function registerReferenceProvider(selector: DocumentSelector, provider: ReferenceProvider): Disposable;
    function registerDocumentSymbolProvider(selector: DocumentSelector, provider: DocumentSymbolProvider): Disposable;
    function registerWorkspaceSymbolProvider(provider: WorkspaceSymbolProvider): Disposable;
    function registerCodeActionsProvider(selector: DocumentSelector, provider: CodeActionProvider,
                                         metadata?: { providedCodeActionKinds?: readonly CodeActionKind[] }): Disposable;
    function registerCodeLensProvider(selector: DocumentSelector, provider: CodeLensProvider): Disposable;
    function registerSignatureHelpProvider(selector: DocumentSelector, provider: SignatureHelpProvider, ...triggerCharacters: string[]): Disposable;
    function registerSignatureHelpProvider(selector: DocumentSelector, provider: SignatureHelpProvider, metadata: SignatureHelpProviderMetadata): Disposable;
    function registerRenameProvider(selector: DocumentSelector, provider: RenameProvider): Disposable;
    function registerDocumentHighlightProvider(selector: DocumentSelector, provider: DocumentHighlightProvider): Disposable;
    function registerDocumentLinkProvider(selector: DocumentSelector, provider: DocumentLinkProvider): Disposable;
    function registerFoldingRangeProvider(selector: DocumentSelector, provider: FoldingRangeProvider): Disposable;
    function registerInlayHintsProvider(selector: DocumentSelector, provider: InlayHintsProvider): Disposable;
    function registerDocumentSemanticTokensProvider(selector: DocumentSelector, provider: DocumentSemanticTokensProvider,
                                                    legend: SemanticTokensLegend): Disposable;
    function registerDocumentFormattingEditProvider(selector: DocumentSelector, provider: DocumentFormattingEditProvider): Disposable;
    function registerDocumentRangeFormattingEditProvider(selector: DocumentSelector, provider: DocumentRangeFormattingEditProvider): Disposable;
    function registerOnTypeFormattingEditProvider(selector: DocumentSelector, provider: OnTypeFormattingEditProvider,
                                                  firstTriggerCharacter: string, ...moreTriggerCharacters: string[]): Disposable;
    /** Diagnostics are removed when the extension stops. */
    function createDiagnosticCollection(name?: string): DiagnosticCollection;
    /** Starts `definition`'s server for its languages (stopped when disposed or the extension stops). */
    function registerLanguageServer(definition: LanguageServerDefinition): Disposable;
    /** A server by id, declared or registered by any extension, or built in ("rust-analyzer"). */
    function getLanguageServer(id: string): LanguageServer;
    /** Every language id the editor knows (built in and from extensions). */
    function getLanguages(): Promise<string[]>;
    /** Puts an open document in another language (as Change Language Mode does). */
    function setTextDocumentLanguage(document: TextDocument, languageId: string): Promise<TextDocument>;
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
