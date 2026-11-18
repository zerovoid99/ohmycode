import * as omc from "omc";

/** What the toy language's words mean (completion and hover). */
const KEYWORDS: Record<string, string> = {
  fn: "Declares a function: `fn name(params) do … end`.",
  do: "Starts a block.",
  end: "Ends a block.",
  let: "Declares a variable: `let name = value`.",
  if: "Runs a block when its condition holds: `if x > 1 do … end`.",
  print: "Prints its argument.",
};

interface Declaration {
  name: string;
  kind: "fn" | "let";
  line: number;
  /** Where the name starts on its line. */
  start: number;
  text: string;
}

/** The file's `fn` and `let` declarations, top to bottom. */
function declarations(document: omc.TextDocument): Declaration[] {
  const found: Declaration[] = [];
  for (let line = 0; line < document.lineCount; line++) {
    const text = document.lineAt(line).text;
    const match = /^(\s*)(fn|let)\s+([A-Za-z_]\w*)/.exec(text);
    if (match) {
      found.push({ name: match[3], kind: match[2] as "fn" | "let", line, start: match[0].length - match[3].length, text: text.trim() });
    }
  }
  return found;
}

/** The declaration of the word at `position`, if the file has one. */
function declarationAt(document: omc.TextDocument, position: omc.Position): Declaration | undefined {
  const range = document.getWordRangeAtPosition(position);
  if (!range) return undefined;
  const word = document.getText(range);
  return declarations(document).find((declaration) => declaration.name === word);
}

export function activate(context: omc.ExtensionContext) {
  const selector: omc.DocumentSelector = { language: "toy" };
  context.subscriptions.push(
    // Keywords, and the file's own functions (inserted with a placeholder for the arguments).
    omc.languages.registerCompletionItemProvider(selector, {
      provideCompletionItems(document) {
        const items = Object.keys(KEYWORDS).map((word) => {
          const item = new omc.CompletionItem(word, omc.CompletionItemKind.Keyword);
          item.documentation = new omc.MarkdownString(KEYWORDS[word]);
          return item;
        });
        for (const declaration of declarations(document)) {
          const isFunction = declaration.kind === "fn";
          const item = new omc.CompletionItem(declaration.name, isFunction ? omc.CompletionItemKind.Function : omc.CompletionItemKind.Variable);
          item.detail = declaration.text;
          if (isFunction) item.insertText = new omc.SnippetString(declaration.name + "(").appendPlaceholder("args").appendText(")");
          items.push(item);
        }
        return items;
      },
    }),
    // A keyword's meaning, or a name's declaration.
    omc.languages.registerHoverProvider(selector, {
      provideHover(document, position) {
        const range = document.getWordRangeAtPosition(position);
        if (!range) return undefined;
        const word = document.getText(range);
        if (KEYWORDS[word]) return new omc.Hover(new omc.MarkdownString(KEYWORDS[word]), range);
        const declaration = declarationAt(document, position);
        return declaration ? new omc.Hover(new omc.MarkdownString().appendCodeblock(declaration.text, "toy"), range) : undefined;
      },
    }),
    // F12 and ⌘-click: where a name is declared.
    omc.languages.registerDefinitionProvider(selector, {
      provideDefinition(document, position) {
        const declaration = declarationAt(document, position);
        if (!declaration) return undefined;
        const start = new omc.Position(declaration.line, declaration.start);
        return new omc.Location(document.uri, new omc.Range(start, new omc.Position(declaration.line, declaration.start + declaration.name.length)));
      },
    }),
    // The Outline, breadcrumbs and Go to Symbol.
    omc.languages.registerDocumentSymbolProvider(selector, {
      provideDocumentSymbols(document) {
        return declarations(document).map((declaration) => {
          const line = document.lineAt(declaration.line).text;
          return new omc.DocumentSymbol(
            declaration.name, declaration.kind,
            declaration.kind === "fn" ? omc.SymbolKind.Function : omc.SymbolKind.Variable,
            new omc.Range(declaration.line, 0, declaration.line, line.length),
            new omc.Range(declaration.line, declaration.start, declaration.line, declaration.start + declaration.name.length),
          );
        });
      },
    }),
  );
}

export function deactivate() {}
