import SwiftUI

struct ToolbarPill: ViewModifier {
    var filled = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(filled ? 0.16 : 0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
            .fixedSize()
    }
}

extension View {
    func toolbarPill(filled: Bool = false) -> some View {
        modifier(ToolbarPill(filled: filled))
    }
}
