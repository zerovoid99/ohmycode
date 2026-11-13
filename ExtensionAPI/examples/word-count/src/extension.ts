import * as omc from "omc";

function count(text: string): number {
  const words = text.match(/[\p{L}\p{N}_'-]+/gu);
  return words ? words.length : 0;
}

function words(): { count: number; scope: string } | undefined {
  const editor = omc.window.activeTextEditor;
  if (!editor) return undefined;
  const useSelection = omc.workspace.getConfiguration("wordCount").get("countSelection", true) && !editor.selection.isEmpty;
  const text = editor.document.getText(useSelection ? editor.selection : undefined);
  return { count: count(text), scope: useSelection ? "selection" : editor.document.fileName };
}

export function activate(context: omc.ExtensionContext) {
  const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Right, 10);
  item.command = "wordCount.show";
  item.tooltip = "Words in this file";

  const update = () => {
    const result = words();
    if (!result) { item.hide(); return; }
    item.text = `$(text.word.spacing) ${result.count}`;
    item.show();
  };

  context.subscriptions.push(
    item,
    omc.commands.registerCommand("wordCount.show", async () => {
      const result = words();
      if (!result) {
        await omc.window.showWarningMessage("Open a file to count its words.");
        return;
      }
      await omc.window.showInformationMessage(`${result.count} words in ${result.scope}.`);
    }),
    omc.window.onDidChangeActiveTextEditor(update),
    omc.workspace.onDidChangeTextDocument(update),
    omc.workspace.onDidChangeConfiguration((e) => { if (e.affectsConfiguration("wordCount")) update(); }),
  );
  update();
}
