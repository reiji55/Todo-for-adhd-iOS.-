import SwiftUI

/// The same lower-right add control as task lists, with the current tab supplying its creation flow.
struct ContextAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.accent.opacity(0.7)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("追加する")
    }
}
