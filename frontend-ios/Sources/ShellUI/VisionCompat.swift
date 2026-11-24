// visionOS stand-ins for the Liquid Glass and toolbar API the shell views use on iOS and macOS 26.
// The visionOS SDK marks these unavailable (windows there are already glass), so the views would not compile.
// Each stand-in has the name and the call shape of the real one, so no view needs a branch of its own:
// the compiler prefers the available declaration of this module over the unavailable one of SwiftUI.
// A button style falls back to the bordered one, a container to its content, and an effect to nothing.
import SwiftUI

extension View {
    /// A game card as a button. On visionOS a plain button is lit by the system as a soft round spot that follows the
    /// eyes, which on a wide cover looks like a circle and never reaches the corners. The card gets a style of its own
    /// there (`VisionCardButtonStyle`): the whole rounded card lights evenly. Elsewhere it is the plain button.
    @ViewBuilder func cardButtonStyle(cornerRadius: CGFloat) -> some View {
        #if os(visionOS)
        self.buttonStyle(VisionCardButtonStyle(cornerRadius: cornerRadius))
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// On visionOS, drops the shell's cream tint from a control that draws a white label on its own fill. No change elsewhere.
    @ViewBuilder func neutralTintOnVision() -> some View {
        #if os(visionOS)
        self.tint(nil)
        #else
        self
        #endif
    }
}

#if os(visionOS)

/// A card that lights as a whole under the eyes: an even veil and a rim in the card's own rounded shape, and a slight
/// growth. A button style of the app's own gets no highlight from the system, so the round spot is gone. The veil and
/// the growth are one group: looking anywhere on the card starts both.
struct VisionCardButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .overlay {
                shape.fill(.white.opacity(0.10))
                    .overlay(shape.strokeBorder(.white.opacity(0.75), lineWidth: 2))
                    .hoverEffect { effect, isActive, _ in effect.opacity(isActive ? 1 : 0) }
            }
            .contentShape(.hoverEffect, shape)
            .contentShape(shape)
            .hoverEffect { effect, isActive, _ in effect.scaleEffect(isActive ? 1.02 : 1) }
            .hoverEffectGroup()
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The plain glass button: visionOS's bordered button, without the shell's cream tint. A bordered button there fills
/// with its tint and draws a white label, so the cream that is an accent on iOS hid the icon.
struct VisionGlassButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.bordered).tint(nil)
    }
}

extension PrimitiveButtonStyle where Self == VisionGlassButtonStyle {
    static var glass: VisionGlassButtonStyle { VisionGlassButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    static var glassProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() }
}

/// SwiftUI's container merges the glass shapes of its children. Here it only shows them.
struct GlassEffectContainer<Content: View>: View {
    private let content: Content
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content }
}

enum VisionGlassTransition { case identity, matchedGeometry }
enum VisionScrollEdgeStyle { case automatic, soft, hard }

extension View {
    func glassEffectID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View { self }
    func glassEffectTransition(_ transition: VisionGlassTransition) -> some View { self }
    func scrollEdgeEffectStyle(_ style: VisionScrollEdgeStyle?, for edges: Edge.Set) -> some View { self }
    func scrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all) -> some View { self }
    func navigationSubtitle(_ subtitle: String) -> some View { self }
}

extension ToolbarContent {
    func sharedBackgroundVisibility(_ visibility: Visibility) -> some ToolbarContent { self }
}

/// A fixed gap between toolbar items.
struct ToolbarSpacer: ToolbarContent {
    enum Sizing { case fixed, flexible }
    private let placement: ToolbarItemPlacement
    init(_ sizing: Sizing = .flexible, placement: ToolbarItemPlacement = .automatic) { self.placement = placement }
    var body: some ToolbarContent {
        ToolbarItem(placement: placement) { Color.clear.frame(width: 8, height: 1).accessibilityHidden(true) }
    }
}
#endif
