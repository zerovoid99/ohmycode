import AppKit

/// Which language each open file is in: Change Language Mode's choice for the file, else
/// `files.associations` (the folder's over the app's), else what the registry says (languages
/// extensions add, then the built-in table).
extension Workspace {
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// `files.associations` for a file: its folder's settings over the app's.
    func fileAssociations(for url: URL) -> [String: String] {
        AppSettings.shared.fileAssociations.merging(settings(for: url).fileAssociations ?? [:]) { $1 }
    }

    func resolvedLanguage(for document: EditorDocument) -> SourceLanguage {
        if let chosen = languageModeOverrides[Self.key(document.url)] { return chosen }
        return LanguageRegistry.shared.language(for: document.url, firstLine: LanguageRegistry.firstLine(of: document.textStorage.mutableString),
                                                associations: fileAssociations(for: document.url))
    }

    /// Languages were added or removed, or `files.associations` changed: open files follow.
    /// Grammars extensions contribute, and the highlighting picked per language, can change
    /// what colors a file without changing its language.
    func updateLanguageModes() {
        for document in documents {
            changeLanguage(of: document, to: resolvedLanguage(for: document))
            document.refreshHighlighting()
        }
    }

    /// Puts `document` in `language`: its colors, symbols and server follow, and extensions
    /// for the language activate.
    func changeLanguage(of document: EditorDocument, to language: SourceLanguage) {
        guard document.language != language else { return }
        document.setLanguage(language)
        reattachLanguageServer(document)
        extensions.documentLanguageChanged(document)
    }

    /// Change Language Mode (palette, or the status bar's language): every language, the
    /// file's own first; the choice holds for the file while the window is open. "Auto Detect"
    /// goes back to what the file's name says.
    func changeLanguageMode(_ target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument else { NSSound.beep(); return }
        let languages = LanguageRegistry.shared.languages
        let detected = LanguageRegistry.shared.language(for: document.url, firstLine: LanguageRegistry.firstLine(of: document.textStorage.mutableString),
                                                        associations: fileAssociations(for: document.url))
        var items = [QuickPickItem(label: "Auto Detect", description: detected.displayName, detail: nil)]
        items += languages.map { entry in
            QuickPickItem(label: entry.name, description: entry.language == document.language ? "\(entry.language.languageId) (current)" : entry.language.languageId,
                          detail: nil)
        }
        Task {
            guard let index = await showQuickPick(items, placeholder: "Select the language for \(document.fileName)") else { return }
            if index == 0 {
                languageModeOverrides[Self.key(document.url)] = nil
            } else {
                languageModeOverrides[Self.key(document.url)] = languages[index - 1].language
            }
            changeLanguage(of: document, to: resolvedLanguage(for: document))
        }
    }
}
