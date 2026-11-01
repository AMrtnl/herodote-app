import SwiftUI

// MARK: - ToolPaletteView (floating glass tool bar)

struct ToolPaletteView: View {
    @Bindable var model: EditorModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
                if model.tool.usesColor || model.tool == .text {
                    separator
                    colorSwatches
                }
                if model.tool.isInk || (model.tool == .eraser && model.settings.tools.eraserMode == .precise) {
                    separator
                    widthButtons
                }
                separator
                toggle("ruler", label: "Règle", isOn: model.ruler) {
                    model.ruler.toggle()
                }
                toggle("circle.square", label: "Formes automatiques", isOn: model.alwaysSnapShapes) {
                    model.alwaysSnapShapes.toggle()
                    model.flash(model.alwaysSnapShapes
                                ? "Formes automatiques activées"
                                : "Formes : maintenez la pointe en fin de trait")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: horizontalSizeClass == .regular, vertical: true)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12)
        .popover(isPresented: $model.showToolOptions, arrowEdge: .top) {
            ToolOptionsView(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var separator: some View {
        Capsule()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let selected = model.tool == tool
        return Button {
            model.select(tool)
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: 40, height: 36)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
                .overlay(alignment: .bottom) {
                    if tool.isInk {
                        Capsule()
                            .fill(Color(hex: inkColor(for: tool)))
                            .frame(width: 14, height: 3)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .padding(.bottom, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(tool.label)
    }

    private func inkColor(for tool: EditorTool) -> String {
        let t = model.settings.tools
        switch tool {
        case .pencil:      return t.pencilColor
        case .highlighter: return t.highlighterColor
        default:           return t.penColor
        }
    }

    private var colorSwatches: some View {
        let current = model.currentColorHex.uppercased()
        var swatches = model.palette.map { $0.uppercased() }
        if !swatches.contains(current) { swatches.insert(current, at: 0) }
        return HStack(spacing: 0) {
            ForEach(swatches, id: \.self) { hex in
                Button {
                    model.setColor(hex)
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .padding(3)
                        .overlay {
                            if hex == current {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2.5)
                            }
                        }
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couleur \(hex)")
            }
            ColorPicker("Couleur personnalisée",
                        selection: Binding(get: { Color(hex: model.currentColorHex) },
                                           set: { model.setColor($0.hexString) }),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 36)
        }
    }

    private var widthButtons: some View {
        let sizes: [CGFloat] = [5, 9, 14]
        return HStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                let selected = model.currentWidthIndex == index
                Button {
                    model.setWidthIndex(index)
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(selected ? 0.9 : 0.45))
                        .frame(width: sizes[index], height: sizes[index])
                        .frame(width: 32, height: 36)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Fin", "Moyen", "Épais"][index])
            }
        }
    }

    private func toggle(_ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 38, height: 36)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(label)
    }
}

// MARK: - ToolOptionsView (popover when tapping the active tool again, or Pencil double-tap)

struct ToolOptionsView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.tool.label)
                .font(.headline)

            switch model.tool {
            case .pen:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type de stylo").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(PenStyle.allCases) { style in
                        Button {
                            model.setPenStyle(style)
                        } label: {
                            HStack {
                                Image(systemName: style.symbol).frame(width: 24)
                                Text(style.label)
                                Spacer()
                                if model.settings.tools.penStyle == style {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            case .eraser:
                Picker("Mode", selection: Binding(get: { model.settings.tools.eraserMode },
                                                  set: { model.setEraserMode($0) })) {
                    ForEach(EraserMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.settings.tools.eraserMode == .stroke
                     ? "Efface chaque trait touché en entier."
                     : "Efface uniquement là où vous passez.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .lasso:
                Text("Entourez de l’écriture pour la déplacer, la copier, la supprimer ou la convertir en texte.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .text:
                Text("Touchez la page pour créer une zone de texte. Touchez une zone existante pour la modifier.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .hand:
                Text("Touchez une image ou une zone de texte pour la sélectionner, faites-la glisser pour la déplacer, tirez la poignée pour la redimensionner.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .laser:
                Text("Montrez une partie de la page pendant une présentation ou un appel : le trait rouge s’efface tout seul et n’est jamais enregistré.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .pencil, .highlighter:
                Text("Choisissez la couleur et l’épaisseur dans la barre d’outils.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Dessin au doigt", isOn: Binding(get: { model.settings.fingerDrawing },
                                                    set: { _ in model.toggleFingerDrawing() }))
            Toggle("Maintenir pour une forme parfaite", isOn: Binding(
                get: { model.settings.holdToSnapShapes },
                set: { model.settings.holdToSnapShapes = $0; model.settings.save() }))
        }
        .font(.callout)
        .padding(18)
        .frame(width: 300)
    }
}

// MARK: - ReaderBar (iPhone and Mac: the notebook is read-only)

struct ReaderBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Label("Lecture seule", systemImage: "eye")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .help(Platform.readOnlyExplanation)
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 4)
            item("laser.burst", "Pointeur laser", isOn: model.tool == .laser) {
                model.select(.laser)
            }
            item("rectangle.split.2x1", "Pages côte à côte", isOn: model.isHorizontal) {
                model.toggleScrollDirection()
            }
            item("arrow.left.and.right", model.isHorizontal ? "Page entière" : "Ajuster à la largeur", isOn: false) {
                model.canvas?.zoomToFitWidth()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12)
    }

    private func item(_ symbol: String, _ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 40, height: 36)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(label)
    }
}
