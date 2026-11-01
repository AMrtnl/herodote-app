import SwiftUI
import UIKit
import VisionKit

// MARK: - TextElementEditor

struct TextElementEditor: View {
    let request: TextEditRequest
    var onSave: (String, Double, TextFontStyle, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var fontSize: Double
    @State private var style: TextFontStyle
    @State private var color: Color
    @FocusState private var focused: Bool

    init(request: TextEditRequest, onSave: @escaping (String, Double, TextFontStyle, String) -> Void) {
        self.request = request
        self.onSave = onSave
        _text = State(initialValue: request.element.text)
        _fontSize = State(initialValue: request.element.fontSize)
        _style = State(initialValue: request.element.fontStyle)
        _color = State(initialValue: Color(hex: request.element.colorHex))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(Font(PageRenderer.font(size: CGFloat(min(fontSize, 26)), style: style) as CTFont))
                        .foregroundStyle(color)
                        .frame(minHeight: 150)
                        .focused($focused)
                }
                Section("Style") {
                    Picker("Police", selection: $style) {
                        ForEach(TextFontStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $fontSize, in: 9...72, step: 1) {
                        Text("Taille : \(Int(fontSize)) pt")
                    }
                    ColorPicker("Couleur", selection: $color, supportsOpacity: false)
                }
                if request.elementID != nil {
                    Section {
                        Button("Supprimer la zone de texte", role: .destructive) {
                            onSave("", fontSize, style, color.hexString)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(request.elementID == nil ? "Nouvelle zone de texte" : "Modifier le texte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        onSave(text, fontSize, style, color.hexString)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - ConversionSheet (handwriting → text)

struct ConversionSheet: View {
    let conversion: ConversionResult
    var onReplace: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(conversion: ConversionResult, onReplace: @escaping (String) -> Void) {
        self.conversion = conversion
        self.onReplace = onReplace
        _text = State(initialValue: conversion.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                } header: {
                    Text("Texte reconnu")
                } footer: {
                    Text("Corrigez le texte si besoin. La reconnaissance s’effectue entièrement sur l’appareil.")
                }
                Section {
                    Button {
                        onReplace(text)
                        dismiss()
                    } label: {
                        Label("Remplacer l’écriture par ce texte", systemImage: "character.textbox")
                    }
                    Button {
                        UIPasteboard.general.string = text
                        dismiss()
                    } label: {
                        Label("Copier", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: text) {
                        Label("Partager…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Conversion en texte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - DocumentScannerView (VisionKit)

struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
