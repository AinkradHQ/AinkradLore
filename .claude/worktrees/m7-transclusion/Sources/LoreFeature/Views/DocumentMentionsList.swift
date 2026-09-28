import SwiftUI
import AinkradAppKit

/// What else in the vault points at this document.
///
/// ## Why this is summoned rather than always present
///
/// It began as a band below the document body, on the reasoning that you never
/// scroll past the end mid-sentence so it would cost nothing while writing.
/// That holds for a LONG document and fails for a short one — which is most of
/// a vault: on a nearly-empty note the band landed directly under the title and
/// competed with the writing area, the exact opposite of the intent.
///
/// Anchoring it to the window's bottom edge fixed the crowding and left the
/// deeper problem: "what links here" is a question asked deliberately, a few
/// times a session, and anything answering it permanently is furniture. So it
/// is reached from the document's own actions menu (and ⌘⇧B), and is closed
/// until then.
struct DocumentMentionsList: View {
    let backlinks: [LoreStore.Backlink]
    let unresolved: [UnresolvedLink]
    let theme: HostTheme
    let onOpen: (URL) -> Void
    let onCreate: (UnresolvedLink) -> Void

    @Environment(\.ainkradTypography) private var typo


    /// Collapsed by default, and summarised in one line.
    ///
    /// The summary is the point: "7 linked mentions · 2 unresolved" answers the
    /// question most of the time without expanding anything, which is why the
    /// old panel's count badge was most of what it actually provided.
    private var summary: String {
        var parts = [backlinks.count == 1 ? "1 linked mention"
                                          : "\(backlinks.count) linked mentions"]
        if !unresolved.isEmpty { parts.append("\(unresolved.count) unresolved") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        // Nothing points here and nothing is broken: draw NOTHING. An empty
        // "0 linked mentions" band at the foot of every new note is a permanent
        // reminder of an absence, and it would be the first thing a reader sees
        // under a document they just started.
        if !backlinks.isEmpty || !unresolved.isEmpty {
            // No inner disclosure: opening the slideover IS the disclosure,
            // and a second one inside it would be a click to reveal what the
            // first click asked for.
            ScrollView {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    Text(summary)
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.tokens.foreground.opacity(LoreMetrics.tertiaryText))
                    details
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.ainkradTheme, theme.tokens)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            ForEach(backlinks) { link in
                Button { onOpen(link.row.path) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.row.title)
                            .font(AinkradFontResolver.font(.headline, typography: typo))
                            .lineLimit(1)
                        if !link.context.isEmpty {
                            // The LINE the link sits on. A bare list of
                            // filenames is meaningfully less useful than seeing
                            // WHY something links here — the rule the old panel
                            // established and this keeps.
                            Text(link.context)
                                .font(AinkradFontResolver.font(.caption, typography: typo))
                                .foregroundStyle(theme.tokens.foreground.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !unresolved.isEmpty {
                AinkradSectionHeader(title: "Unresolved links")
                ForEach(unresolved) { link in
                    HStack(spacing: AinkradSpacing.sm) {
                        Text(link.rawTarget).lineLimit(1)
                        Spacer(minLength: 0)
                        AinkradButton(title: "Create note", style: .ghost) {
                            onCreate(link)
                        }
                    }
                }
            }
        }
    }
}
