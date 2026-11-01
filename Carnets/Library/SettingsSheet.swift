import SwiftUI
import PencilKit

// MARK: - SettingsSheet

struct SettingsSheet: View {
    @Bindable private var settings = CarnetsSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reindexed = false

    private var availableLanguages: [RecognitionLanguage] {
        let supported = PKStrokeRecognizer.supportedLanguages
        guard !supported.isEmpty else { return RecognitionLanguage.all }
        let filtered = RecognitionLanguage.all.filter { language in
            supported.contains { $0.languageCode?.identifier == language.code }
        }
        return filtered.isEmpty ? RecognitionLanguage.all : filtered
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        VaultSettingsView()
                    } label: {
                        Label("Coffre et serveur", systemImage: "externaldrive.connected.to.line.below")
                    }
                } footer: {
                    Text("Où sont stockés vos notes, projets et carnets, et la synchronisation avec votre serveur.")
                }
                Section {
                    Picker("Défilement des pages", selection: $settings.scrollDirection) {
                        ForEach(ScrollDirection.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Lecture des carnets")
                } footer: {
                    Text(NotebookStore.shared.isReadOnly
                         ? "\(Platform.readOnlyTitle). \(Platform.readOnlyExplanation)"
                         : "Horizontal : une page à la fois, feuilletée d’un geste, comme un cahier. Les carnets s’ouvrent aussi en lecture seule sur iPhone et Mac.")
                }

                if !NotebookStore.shared.isReadOnly {
                    Section {
                        Toggle("Dessiner avec le doigt", isOn: $settings.fingerDrawing)
                        Toggle("Maintenir la pointe pour une forme parfaite", isOn: $settings.holdToSnapShapes)
                        Toggle("Toucher avec 2 doigts pour annuler, 3 pour rétablir", isOn: $settings.tapGesturesForUndo)
                    } header: {
                        Text("Écriture")
                    } footer: {
                        Text("Le double-toucher et la pression de l’Apple Pencil suivent les réglages de l’Apple Pencil dans Réglages.")
                    }

                    Section {
                        ForEach(availableLanguages) { language in
                            Toggle(language.label, isOn: languageBinding(language.code))
                        }
                        Button {
                            HandwritingIndexer.shared.reindexEverything()
                            reindexed = true
                        } label: {
                            Label(reindexed ? "Réindexation en cours…" : "Réindexer toutes les notes",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(reindexed)
                    } header: {
                        Text("Reconnaissance de l’écriture")
                    } footer: {
                        Text("Votre écriture est reconnue sur l’appareil pour la recherche et la conversion en texte. Rien ne quitte votre iPad.")
                    }

                    Section("Nouveaux carnets") {
                        Picker("Modèle", selection: $settings.defaultTemplate) {
                            ForEach(PageTemplate.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Papier", selection: $settings.defaultPaper) {
                            ForEach(PaperStyle.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Format", selection: $settings.defaultFormat) {
                            ForEach(PageFormat.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }

                Section("À propos") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Notes, projets et carnets sont des fichiers ordinaires dans votre coffre (Markdown, JSON, PDF, images) : rien n’est enfermé dans l’app. Exportez un carnet en PDF pour le partager.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .onDisappear { settings.save() }
    }

    private func languageBinding(_ code: String) -> Binding<Bool> {
        Binding {
            settings.recognitionLanguages.contains(code)
        } set: { enabled in
            if enabled {
                if !settings.recognitionLanguages.contains(code) { settings.recognitionLanguages.append(code) }
            } else if settings.recognitionLanguages.count > 1 {
                settings.recognitionLanguages.removeAll { $0 == code }
            }
            settings.save()
        }
    }
}
