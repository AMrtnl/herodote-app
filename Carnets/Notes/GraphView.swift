import SwiftUI
import UIKit

// MARK: - GraphView (Obsidian-style force-directed graph of linked notes)

struct GraphView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router
    @State private var simulation = GraphSimulation()
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var scaleStart: CGFloat = 1
    @State private var showOrphans = true

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { _ in
                Canvas { context, size in
                    simulation.step()
                    draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(4, max(0.25, scaleStart * value.magnification)) }
                    .onEnded { _ in scaleStart = scale }
            )
            .onTapGesture { location in
                if let path = simulation.node(at: unproject(location, size: geo.size), radius: 18 / scale) {
                    router.push(.note(path))
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Graphe")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Notes isolées", isOn: $showOrphans)
                    Button("Recentrer") {
                        withAnimation { offset = .zero; dragStart = .zero; scale = 1; scaleStart = 1 }
                    }
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
            }
        }
        .overlay(alignment: .bottomLeading) { legend }
        .onAppear { rebuild() }
        .onChange(of: vault.notes.count) { rebuild() }
        .onChange(of: showOrphans) { rebuild() }
    }

    private func rebuild() {
        var edges: [(String, String)] = []
        for (source, targets) in vault.outgoing {
            for target in targets { edges.append((source, target)) }
        }
        let linked = Set(edges.flatMap { [$0.0, $0.1] })
        let nodes = vault.notes.filter { showOrphans || linked.contains($0.path) }
        simulation.update(nodes: nodes.map { GraphSimulation.NodeInfo(path: $0.path, title: $0.title, kind: $0.kind) },
                          edges: edges)
    }

    private func project(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + p.x * scale, y: size.height / 2 + offset.height + p.y * scale)
    }

    private func unproject(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - offset.width) / scale, y: (p.y - size.height / 2 - offset.height) / scale)
    }

    private func color(for kind: NoteKind) -> Color {
        switch kind {
        case .note:     return Color(uiColor: .systemGray)
        case .daily:    return .blue
        case .notebook: return .accentColor
        case .sheet:    return .purple
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let nodes = simulation.nodes
        var edgePath = Path()
        for edge in simulation.edges {
            edgePath.move(to: project(nodes[edge.0].position, size: size))
            edgePath.addLine(to: project(nodes[edge.1].position, size: size))
        }
        context.stroke(edgePath, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        for node in nodes {
            let p = project(node.position, size: size)
            let r = (4 + sqrt(CGFloat(node.degree)) * 2.4) * min(max(scale, 0.6), 1.6)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color(for: node.kind)))
            if scale > 0.7 || node.degree >= 3 {
                context.draw(Text(node.title).font(.caption2).foregroundStyle(.primary),
                             at: CGPoint(x: p.x, y: p.y + r + 3), anchor: .top)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Note", color(for: .note))
            legendItem("Journal", color(for: .daily))
            legendItem("Carnet", color(for: .notebook))
            legendItem("Écriture", color(for: .sheet))
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(in: Capsule())
        .padding(16)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }
}

// MARK: - Force simulation

final class GraphSimulation {
    struct NodeInfo {
        let path: String
        let title: String
        let kind: NoteKind
    }

    struct Node {
        let path: String
        var title: String
        var kind: NoteKind
        var position: CGPoint
        var velocity: CGPoint = .zero
        var degree = 0
    }

    private(set) var nodes: [Node] = []
    private(set) var edges: [(Int, Int)] = []
    private var energy: CGFloat = .infinity

    func update(nodes infos: [NodeInfo], edges pairs: [(String, String)]) {
        let previous = Dictionary(nodes.map { ($0.path, $0.position) }, uniquingKeysWith: { a, _ in a })
        nodes = infos.enumerated().map { index, info in
            let angle = CGFloat(index) * 2.399963 // golden angle spiral for a pleasant start
            let radius = 20 * sqrt(CGFloat(index + 1))
            let start = previous[info.path] ?? CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            return Node(path: info.path, title: info.title, kind: info.kind, position: start)
        }
        let index = Dictionary(nodes.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        edges = pairs.compactMap { pair in
            guard let a = index[pair.0], let b = index[pair.1], a != b else { return nil }
            return (a, b)
        }
        for edge in edges {
            nodes[edge.0].degree += 1
            nodes[edge.1].degree += 1
        }
        energy = .infinity
    }

    /// One integration step; stops moving once the layout has settled.
    func step() {
        guard energy > 0.05, !nodes.isEmpty else { return }
        let count = nodes.count
        var forces = [CGPoint](repeating: .zero, count: count)
        let repulsion: CGFloat = 1400, spring: CGFloat = 0.03, rest: CGFloat = 80, gravity: CGFloat = 0.012
        if count <= 600 {
            for i in 0..<count {
                for j in (i + 1)..<count {
                    var dx = nodes[i].position.x - nodes[j].position.x
                    var dy = nodes[i].position.y - nodes[j].position.y
                    if dx == 0 && dy == 0 { dx = 0.1; dy = 0.1 }
                    let d2 = max(dx * dx + dy * dy, 36)
                    let f = repulsion / d2
                    let d = sqrt(d2)
                    forces[i].x += dx / d * f; forces[i].y += dy / d * f
                    forces[j].x -= dx / d * f; forces[j].y -= dy / d * f
                }
            }
        }
        for (a, b) in edges {
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let d = max(sqrt(dx * dx + dy * dy), 0.1)
            let f = spring * (d - rest)
            forces[a].x += dx / d * f; forces[a].y += dy / d * f
            forces[b].x -= dx / d * f; forces[b].y -= dy / d * f
        }
        var total: CGFloat = 0
        for i in 0..<count {
            forces[i].x -= nodes[i].position.x * gravity
            forces[i].y -= nodes[i].position.y * gravity
            var v = CGPoint(x: (nodes[i].velocity.x + forces[i].x) * 0.82, y: (nodes[i].velocity.y + forces[i].y) * 0.82)
            let speed = sqrt(v.x * v.x + v.y * v.y)
            if speed > 20 { v = CGPoint(x: v.x / speed * 20, y: v.y / speed * 20) }
            nodes[i].velocity = v
            nodes[i].position.x += v.x
            nodes[i].position.y += v.y
            total += abs(v.x) + abs(v.y)
        }
        energy = total / CGFloat(count)
    }

    func node(at point: CGPoint, radius: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for node in nodes {
            let d = hypot(node.position.x - point.x, node.position.y - point.y)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (node.path, d) }
        }
        return best?.0
    }
}
