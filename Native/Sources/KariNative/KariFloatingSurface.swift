import SwiftUI

// Native glass belongs to floating controls; Form/List rows keep the system's
// normal content appearance. Earlier systems retain their native material.
struct KariFloatingSurface: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
