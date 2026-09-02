import SwiftUI

// MARK: - Day cell model

private struct DayCell: Identifiable {
    let id: String   // "yyyy-MM-dd"
    let date: Date
    let words: Int
}

// MARK: - HeatmapView with day & month labels

struct HeatmapView: View {
    let activities: [String: Int]
    var weeks: Int = 26

    private let cellSize: CGFloat = 11
    private let gap: CGFloat = 3
    // French weekday initials, Monday first
    private let dayLabels = ["L", "M", "M", "J", "V", "S", "D"]

    private var weekColumns: [[DayCell]] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2   // Monday
        let today = cal.startOfDay(for: Date())
        let total = weeks * 7
        let allCells = (0..<total).map { offset -> DayCell in
            let date = cal.date(byAdding: .day, value: -(total - 1 - offset), to: today)!
            let key = dateKey(date)
            return DayCell(id: key, date: date, words: activities[key] ?? 0)
        }
        return stride(from: 0, to: allCells.count, by: 7).map { start in
            Array(allCells[start..<min(start + 7, allCells.count)])
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // Day labels
            VStack(alignment: .trailing, spacing: gap) {
                Spacer().frame(height: 14)  // room for month labels
                ForEach(dayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8, height: cellSize)
                }
            }

            // Grid columns
            VStack(alignment: .leading, spacing: gap) {
                // Month labels row
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(weekColumns.enumerated()), id: \.offset) { idx, week in
                        Text(monthLabel(week: week, index: idx))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: cellSize, height: 14, alignment: .leading)
                    }
                }
                // Cell grid
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weekColumns.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(week) { day in
                                cell(day)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: DayCell) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(intensity(day.words))
            .frame(width: cellSize, height: cellSize)
            .help("\(day.words) mot\(day.words != 1 ? "s" : "") — \(day.date.formatted(date: .abbreviated, time: .omitted))")
    }

    private func intensity(_ words: Int) -> Color {
        switch words {
        case 0:          return Color.secondary.opacity(0.1)
        case 1...50:     return Color.green.opacity(0.28)
        case 51...200:   return Color.green.opacity(0.52)
        case 201...500:  return Color.green.opacity(0.75)
        default:         return Color.green
        }
    }

    private var lastMonth = -1

    private func monthLabel(week: [DayCell], index: Int) -> String {
        guard let first = week.first else { return "" }
        let cal = Calendar.current
        let day = cal.component(.day, from: first.date)
        let month = cal.component(.month, from: first.date)
        // Show label at first week and whenever the month changes (first ~7 days of month)
        let prevFirst = index > 0 ? weekColumns[index - 1].first : nil
        let prevMonth = prevFirst.map { cal.component(.month, from: $0.date) } ?? -1
        guard month != prevMonth || index == 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM"
        f.locale = Locale(identifier: "fr_FR")
        return f.string(from: first.date)
    }

    private func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
}

// MARK: - ProfileView (Élan)

struct ProfileView: View {
    @Environment(LibraryManager.self) private var library

    private var topWords: Int {
        library.groups.map { $0.totalWordCount }.max() ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                statRow
                heatmapSection
                projectSection
            }
            .padding(36)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Élan")
                    .font(.system(size: 36, weight: .bold, design: .serif))
                Text("Tableau de bord d'écriture")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(library.totalWordsAllTime)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("mots écrits au total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Stat row

    private var statRow: some View {
        HStack(spacing: 12) {
            StatPill(value: "\(library.currentStreak)",
                     unit: "jour\(library.currentStreak != 1 ? "s" : "")",
                     label: "Série actuelle",
                     icon: "flame.fill", accent: .orange)
            StatPill(value: "\(library.wordsToday)",
                     unit: "mots",
                     label: "Aujourd'hui",
                     icon: "pencil.line", accent: .blue)
            StatPill(value: "\(library.activities.filter { $0.value > 0 }.count)",
                     unit: "jours",
                     label: "Jours actifs",
                     icon: "calendar", accent: .green)
            StatPill(value: "\(library.groups.count)",
                     unit: "groupe\(library.groups.count != 1 ? "s" : "")",
                     label: "En cours",
                     icon: "folder.fill", accent: .purple)
        }
    }

    // MARK: Heatmap section

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("26 dernières semaines")
                    .font(.headline)
                Spacer()
                // Legend
                HStack(spacing: 4) {
                    Text("Moins").font(.caption2).foregroundStyle(.tertiary)
                    ForEach([0, 1, 2, 3, 4], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(legendColor(level))
                            .frame(width: 11, height: 11)
                    }
                    Text("Plus").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HeatmapView(activities: library.activities)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func legendColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color.secondary.opacity(0.1)
        case 1: return Color.green.opacity(0.28)
        case 2: return Color.green.opacity(0.52)
        case 3: return Color.green.opacity(0.75)
        default: return Color.green
        }
    }

    // MARK: Project section

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Par groupe").font(.headline)
            ForEach(library.groups) { group in
                let words = group.totalWordCount
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(group.displayColor.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: group.iconName)
                            .font(.system(size: 12))
                            .foregroundStyle(group.displayColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.title).font(.callout.weight(.medium))
                            Spacer()
                            Text("\(words) mots")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(height: 5)
                                Capsule()
                                    .fill(group.displayColor)
                                    .frame(width: geo.size.width * min(1, Double(words) / Double(topWords)), height: 5)
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .padding(.vertical, 4)
                if group.id != library.groups.last?.id {
                    Divider().padding(.leading, 40)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - StatPill

private struct StatPill: View {
    let value: String
    let unit: String
    let label: String
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
