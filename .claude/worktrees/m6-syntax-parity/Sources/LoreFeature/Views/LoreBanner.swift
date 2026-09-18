import SwiftUI
import AinkradAppKit

/// A document-pane banner: one sentence, optionally followed by the actions
/// that resolve it.
///
/// Wraps `AinkradBanner` rather than re-drawing it. `DocumentPane` used to
/// hand-roll all three of its banners as `HStack { icon; content }
/// .background(tint.opacity(0.15))`, which meant Lore's most important
/// messages were the one part of the app that looked like nothing else in the
/// platform — no chamfer, no border, a flat wash instead of the kit's
/// fill-plus-stroke.
///
/// ## Why the actions sit BELOW the message
///
/// `AinkradBanner` takes a `String`, not a content builder, so buttons cannot
/// go inside its chamfer. Stacking them underneath is the honest composition:
/// the alternative was duplicating the kit's chamfer, fill and stroke values
/// here to fake an inline slot, which is exactly the drift this file exists to
/// end — the moment the kit retunes a banner, the copy would be wrong and
/// nothing would say so.
///
/// ## Severity comes from `status`, not from a hand-picked accent
///
/// The old banners tinted themselves `accentTertiary` / `accentSecondary` /
/// `accentPrimary` for read-only / conflict / save-failure. Those are BRAND
/// colours with no severity ordering: nothing about `accentPrimary` says
/// "worse than `accentTertiary`", so the three most consequential states in
/// the app were colour-coded by an accident of which accent was left over.
/// `AinkradStatus` maps to the host's semantic status colours, so a warning
/// looks like every other warning the user has seen.
struct LoreBanner<Actions: View>: View {
    let message: String
    let status: AinkradStatus
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradBanner(message: message, status: status)
            // `Actions` is `EmptyView` for the two banners that offer no
            // resolution; rendering the row unconditionally would leave them
            // with a stray gap under the text.
            if Actions.self != EmptyView.self {
                HStack(spacing: AinkradSpacing.sm) {
                    actions
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, AinkradSpacing.md)
        .padding(.vertical, AinkradSpacing.sm)
    }
}

extension LoreBanner where Actions == EmptyView {
    /// A banner with nothing to press — read-only and save-failure, where the
    /// only requirement is that the state stops being invisible.
    init(message: String, status: AinkradStatus) {
        self.init(message: message, status: status) { EmptyView() }
    }
}
