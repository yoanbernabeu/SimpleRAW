import SwiftUI

/// The history of the photo, latest step on top: click any step to go back to it. The steps
/// after the current one stay, dimmed, until the next edit takes another way.
struct HistoryView: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").sectionTitleStyle().textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    HistoryList(session: session)
                }
                .onAppear { proxy.scrollTo(session.historyCursor, anchor: .center) }
            }
        }
        .frame(width: 240, height: min(CGFloat(session.historySteps.count) * 27 + 56, 420))
        .background(Theme.panel)
    }
}

/// The steps themselves, latest on top.
struct HistoryList: View {
    @Bindable var session: DevelopSession

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(session.historySteps.reversed()) { step in
                row(for: step)
            }
        }
        .padding(6)
    }

    private func row(for step: HistoryStep) -> some View {
        let isCurrent = step.id == session.historyCursor
        let isAhead = step.id > session.historyCursor
        return Button { session.goToHistoryStep(step.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(isCurrent ? Theme.accent : Color.clear).frame(width: 5, height: 5)
                Text(step.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: Theme.labelSize))
            .foregroundStyle(isCurrent ? Theme.accent : .primary)
            .opacity(isAhead ? 0.4 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isCurrent ? Theme.control : .clear, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(step.id)
        .help(isCurrent ? "The photo is at this step" : isAhead ? "Go forward to this step" : "Go back to this step")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
