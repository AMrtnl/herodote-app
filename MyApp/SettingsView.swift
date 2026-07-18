import SwiftUI

// MARK: - Settings Window (⌘,)

struct SettingsView: View {
    var body: some View {
        @Bindable var s = AppSettings.shared
        Form {
            Picker("Police", selection: $s.fontName) {
                ForEach(AppSettings.availableFonts, id: \.name) { f in
                    Text(f.label).tag(f.name)
                }
            }

            LabeledContent("Taille") {
                HStack(spacing: 10) {
                    Slider(value: $s.fontSize, in: 12...26, step: 1)
                    Text("\(Int(s.fontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            LabeledContent("Interligne") {
                HStack(spacing: 10) {
                    Slider(value: $s.lineSpacing, in: 0...16, step: 1)
                    Text("\(Int(s.lineSpacing)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            LabeledContent("Esp. paragraphe") {
                HStack(spacing: 10) {
                    Slider(value: $s.paragraphSpacing, in: 0...24, step: 2)
                    Text("\(Int(s.paragraphSpacing)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            LabeledContent("Marges") {
                HStack(spacing: 10) {
                    Slider(value: $s.horizontalInset, in: 40...200, step: 10)
                    Text("\(Int(s.horizontalInset)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 260)
        .onDisappear { AppSettings.shared.save() }
    }
}
