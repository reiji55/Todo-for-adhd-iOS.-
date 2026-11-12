import ActivityKit
import SwiftUI
import WidgetKit

/// いま on the lock screen (above the notifications) and in the Dynamic Island.
struct NowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowActivityAttributes.self) { context in
            NowLockView(state: context.state)
                .activityBackgroundTint(NowLockView.paper)
                .activitySystemActionForegroundColor(NowLockView.green)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SproutMark(dark: true).frame(width: 24, height: 28).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NowWhen(state: state).font(.caption.weight(.semibold)).foregroundStyle(NowLockView.mint)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.badge).font(.caption2.weight(.heavy)).foregroundStyle(NowLockView.mint)
                        Text(state.title).font(.headline).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NowButtons(state: state, dark: true).padding(.top, 4)
                }
            } compactLeading: {
                SproutMark(dark: true).frame(width: 16, height: 18)
            } compactTrailing: {
                Text(state.title).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: 72)
            } minimal: {
                SproutMark(dark: true).frame(width: 16, height: 18)
            }
            .keylineTint(NowLockView.mint)
        }
    }
}

struct NowLockView: View {
    let state: NowActivityAttributes.ContentState

    /// The lock screen card: warm paper, like the icon, so it stands apart from the notifications.
    static let paper = Color(red: 0.98, green: 0.97, blue: 0.94)
    static let ink = Color(red: 0.12, green: 0.24, blue: 0.20)
    static let green = Color(red: 0.18, green: 0.42, blue: 0.36)
    static let mint = Color(red: 0.55, green: 0.81, blue: 0.70)
    static let urgent = Color(red: 0.69, green: 0.40, blue: 0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                SproutMark().frame(width: 15, height: 17)
                Text(state.badge).font(.caption.weight(.heavy)).foregroundStyle(Self.green)
                NowWhen(state: state).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Horme").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !state.kicker.isEmpty {
                Text(state.kicker).font(.caption.weight(.bold)).lineLimit(1)
                    .foregroundStyle(state.kickerIsUrgent ? Self.urgent : Self.green)
            }
            Text(state.title).font(.title3.weight(.bold)).foregroundStyle(Self.ink).lineLimit(2)
            NowButtons(state: state, dark: false)
        }
        .padding(14)
        .environment(\.colorScheme, .light)
    }
}

/// When it is, or how long it has been worked on.
private struct NowWhen: View {
    let state: NowActivityAttributes.ContentState
    var body: some View {
        if let started = state.startedAt {
            Text(timerInterval: started...Date.distantFuture, countsDown: false).monospacedDigit()
        } else {
            Text(state.context).lineLimit(1)
        }
    }
}

private struct NowButtons: View {
    let state: NowActivityAttributes.ContentState
    let dark: Bool

    var body: some View {
        let green = dark ? NowLockView.mint : NowLockView.green
        HStack(spacing: 8) {
            if state.canFinish {
                Button(intent: FinishNowIntent(itemID: state.itemID)) {
                    Label("済んだ", systemImage: "checkmark").frame(maxWidth: .infinity)
                        .font(.subheadline.weight(.bold)).foregroundStyle(dark ? Color.black : Color.white)
                        .padding(.vertical, 9)
                        .background(green, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if state.canPass {
                Button(intent: PassNowIntent(itemID: state.itemID)) {
                    Label("次の候補", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity)
                        .font(.subheadline.weight(.bold)).foregroundStyle(green)
                        .padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(green, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
