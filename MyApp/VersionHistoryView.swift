import SwiftUI

// MARK: - VersionHistorySheet
// Timeline of saved versions (Aujourd'hui / Hier / date) with a word-level diff
// against the current text. Restoring auto-snapshots the current text first.

struct VersionHistorySheet: View {
    let sheet: WritingSheet
    var onRestore: (SheetVersion) -> Void
    var onClose: () -> Void

    @State private var selectedID: UUID?
    @State private var diffText = AttributedString()

    private var ordered: [SheetVersion] { sheet.versions.reversed() }
    private var selected: SheetVersion? { ordered.first { $0.id == selectedID } }

    private struct TimelineSection: Identifiable {
        let title: String
        var versions: [SheetVersion]
        var id: String { title }
    }

    private var timeline: [TimelineSection] {
        let cal = Calendar.current
        var out: [TimelineSection] = []
        for version in ordered {
            let title: String
            if cal.isDateInToday(version.createdAt) {
                title = "Aujourd'hui"
            } else if cal.isDateInYesterday(version.createdAt) {
                title = "Hier"
            } else {
                title = version.createdAt.formatted(date: .abbreviated, time: .omitted)
            }
            if out.isEmpty || out[out.count - 1].title != title {
                out.append(TimelineSection(title: title, versions: [version]))
            } else {
                out[out.count - 1].versions.append(version)
            }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            versionList.frame(width: 230)
            Divider()
            rightPane
        }
        .frame(width: 720, height: 460)
        .onAppear {
            selectedID = ordered.first?.id
            refreshDiff()
        }
        .onChange(of: selectedID) { refreshDiff() }
    }

    // MARK: Timeline list

    private var versionList: some View {
        Group {
            if sheet.versions.isEmpty {
                ContentUnavailableView(
                    "Aucune version",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("⌘S enregistre l'état actuel du texte.")
                )
            } else {
                List(selection: $selectedID) {
                    ForEach(timeline) { section in
                        Section(section.title) {
                            ForEach(section.versions) { version in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(version.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.callout)
                                    Text("\(version.wordCount) mot\(version.wordCount != 1 ? "s" : "")")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .tag(version.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Diff pane

    private var rightPane: some View {
        VStack(spacing: 0) {
            if selected != nil {
                HStack(spacing: 14) {
                    legendDot(.green, "Ajouts depuis cette version")
                    legendDot(.red, "Suppressions")
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    Text(diffText)
                        .font(.system(size: 14, design: .serif))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "Sélectionnez une version",
                    systemImage: "clock",
                    description: Text("La comparaison avec le texte actuel s'affiche ici.")
                )
                .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Fermer", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restaurer cette version") {
                    if let version = selected { onRestore(version) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
            }
            .padding(14)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func refreshDiff() {
        guard let version = selected else {
            diffText = AttributedString()
            return
        }
        diffText = diffAttributedString(wordDiff(old: version.plainText, new: sheet.plainText))
    }
}
