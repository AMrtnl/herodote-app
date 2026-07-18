import SwiftUI

struct LinkPicker: View {
    let allSheets: [WritingSheet]
    let currentSheetID: UUID
    var onSelect: (UUID, String) -> Void

    @State private var search = ""
    @State private var pickedID: UUID?
    @State private var customLabel = ""
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    private func sheetRow(_ sheet: WritingSheet) -> some View {
        HStack {
            Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(sheet.title).font(.body)
                Text("\(sheet.wordCount) mots").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if pickedID == sheet.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(pickedID == sheet.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { pickedID = sheet.id }
    }

    private var filtered: [WritingSheet] {
        let others = allSheets.filter { $0.id != currentSheetID }
        guard !search.isEmpty else { return others }
        return others.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Insérer un lien vers une feuille")
                .font(.title3.bold())
                .padding(.top, 24)
                .padding(.bottom, 12)

            TextField("Rechercher…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Divider().padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { sheet in
                        sheetRow(sheet)
                        Divider().padding(.leading, 40)
                    }
                    if filtered.isEmpty {
                        Text("Aucune feuille trouvée")
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                }
            }
            .frame(height: 220)

            Divider()

            if pickedID != nil {
                TextField("Texte du lien (facultatif)", text: $customLabel)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insérer") {
                    guard let id = pickedID,
                          let sheet = filtered.first(where: { $0.id == id }) else { return }
                    let label = customLabel.trimmingCharacters(in: .whitespaces)
                    onSelect(id, label.isEmpty ? sheet.title : label)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pickedID == nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .frame(width: 400)
    }
}
