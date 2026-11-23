import SwiftUI

extension Int {
    var priorityColor: Color {
        switch self {
        case 0: .red
        case 1: .orange
        case 2: .yellow
        case 3: .blue
        default: .gray
        }
    }
}

struct PriorityBadge: View {
    let priority: Int
    var body: some View {
        Text("P\(priority)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(priority.priorityColor.opacity(0.18), in: Capsule())
            .foregroundStyle(priority.priorityColor)
    }
}

struct TypeBadge: View {
    let type: String
    var symbol: String {
        switch type {
        case "bug": "ladybug"
        case "feature": "sparkles"
        case "epic": "square.stack.3d.up"
        case "chore": "wrench"
        case "decision": "scale.3d"
        default: "checklist"
        }
    }
    var body: some View { Label(type, systemImage: symbol).font(.caption).foregroundStyle(.secondary) }
}

struct StatusIcon: View {
    let status: String
    var body: some View {
        let s = Status(rawValue: status)
        Image(systemName: s?.symbol ?? "circle")
            .foregroundStyle(status == "closed" ? .green : status == "in_progress" ? .blue : status == "blocked" ? .red : .secondary)
    }
}
