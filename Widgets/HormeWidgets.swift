import SwiftUI
import UIKit
import WidgetKit

/// Widgets that only open Horme's add screens, for writing something down the moment it comes up.
@main
struct HormeWidgets: WidgetBundle {
    var body: some Widget {
        TaskQuickAddWidget()
        IdeaQuickAddWidget()
        QuickAddPairWidget()
        if #available(iOSApplicationExtension 18.0, *) {
            TaskQuickAddControl()
            IdeaQuickAddControl()
        }
    }
}

extension Color {
    /// Horme's green, a little deeper in dark mode so white text stays readable.
    static let hormeAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.31, blue: 0.28, alpha: 1)
            : UIColor(red: 0.2, green: 0.37, blue: 0.34, alpha: 1)
    })
}

/// Nothing in these widgets changes over time, so one entry is enough.
struct StaticEntry: TimelineEntry { let date: Date }

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) { completion(StaticEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: Date())], policy: .never))
    }
}

private let quickFamilies: [WidgetFamily] = [.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline]

struct TaskQuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.reiji55.threedays.quickadd.task", provider: StaticProvider()) { _ in
            QuickAddWidgetView(link: .task)
        }
        .configurationDisplayName("タスクを書く")
        .description("タップすると、Hormeのタスクを書く画面がすぐ開きます。")
        .supportedFamilies(quickFamilies)
    }
}

struct IdeaQuickAddWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.reiji55.threedays.quickadd.idea", provider: StaticProvider()) { _ in
            QuickAddWidgetView(link: .idea)
        }
        .configurationDisplayName("アイデアを書く")
        .description("タップすると、Hormeのアイデアを書き留める画面がすぐ開きます。")
        .supportedFamilies(quickFamilies)
    }
}

struct QuickAddPairWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.reiji55.threedays.quickadd.pair", provider: StaticProvider()) { _ in
            QuickAddPairView()
        }
        .configurationDisplayName("タスクとアイデア")
        .description("タスクを書く・アイデアを書く、の2つのボタン。")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickAddWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let link: QuickAddLink

    var body: some View {
        content
            .widgetURL(link.url)
            .containerBackground(for: .widget) {
                if family == .systemSmall { Color.hormeAccent } else { Color.clear }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold))
                    Text(link.shortTitle).font(.system(size: 10, weight: .semibold)).minimumScaleFactor(0.7)
                }
            }
            .accessibilityLabel(link.title)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: link.symbol).font(.system(size: 24, weight: .semibold)).widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.title).font(.headline).widgetAccentable()
                    Text("Hormeにすぐ書く").font(.caption)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label(link.title, systemImage: link.symbol)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: link.symbol).font(.system(size: 30, weight: .semibold)).widgetAccentable()
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text(link.title).font(.system(size: 17, weight: .bold)).minimumScaleFactor(0.8)
                }.widgetAccentable()
                Text(link.detail).font(.caption).opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct QuickAddPairView: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(QuickAddLink.allCases, id: \.self) { link in
                Link(destination: link.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: link.symbol).font(.system(size: 26, weight: .semibold)).widgetAccentable()
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            Text(link.title).font(.system(size: 16, weight: .bold)).minimumScaleFactor(0.8)
                        }.widgetAccentable()
                        Text(link.detail).font(.caption).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .containerBackground(for: .widget) { Color.hormeAccent }
    }
}

/// Buttons for Control Center, the lock screen's bottom corners and the Action button (iOS 18 and later).
@available(iOSApplicationExtension 18.0, *)
struct TaskQuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.reiji55.threedays.control.task") {
            ControlWidgetButton(action: OpenTaskQuickAddIntent()) {
                Label("タスクを書く", systemImage: QuickAddLink.task.symbol)
            }
        }
        .displayName("タスクを書く")
        .description("Hormeのタスクを書く画面を開きます。")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct IdeaQuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "io.github.reiji55.threedays.control.idea") {
            ControlWidgetButton(action: OpenIdeaQuickAddIntent()) {
                Label("アイデアを書く", systemImage: QuickAddLink.idea.symbol)
            }
        }
        .displayName("アイデアを書く")
        .description("Hormeのアイデアを書き留める画面を開きます。")
    }
}
