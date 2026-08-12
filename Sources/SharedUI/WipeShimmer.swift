import SwiftUI

struct WipeShimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0.35 : 1)
            .overlay {
                if active {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let band = max(width * 0.5, 60)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white, location: 0.5),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + phase * (width + band))
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
            }
            .onAppear { if active { start() } }
            .onChange(of: active) { _, isActive in
                if isActive { start() } else { phase = 0 }
            }
    }

    private func start() {
        phase = 0
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

extension View {
    func wipeShimmer(active: Bool) -> some View {
        modifier(WipeShimmer(active: active))
    }
}
