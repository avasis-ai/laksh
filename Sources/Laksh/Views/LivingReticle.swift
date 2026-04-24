import SwiftUI

/// Minimal reticle mark for the empty state — just the static icon, no animation.
struct LivingReticle: View {
    var size: CGFloat = 120

    var body: some View {
        ReticleMark()
            .frame(width: size, height: size)
            .opacity(0.25)
    }
}
