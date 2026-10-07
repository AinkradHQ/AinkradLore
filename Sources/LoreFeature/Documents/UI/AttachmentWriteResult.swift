import Foundation

/// The result of attempting a paste/drop attachment write: embed syntax to
/// insert on success, or a human-readable failure message to surface, never
/// both and never neither.
struct AttachmentWriteResult {
    let embedSyntax: String?
    let failureMessage: String?
}

/// Attempts an attachment write and turns the outcome into
/// `AttachmentWriteResult`, with NO SwiftUI dependency — this is the seam
/// `AttachmentWriteTests` exercises directly.
///
/// Exists because whole-branch review round 2 fixed `DocumentPane`'s
/// `try? … else { return nil }` (which silently dropped `LoreError
/// .notARegularFile` — a dropped Finder folder did nothing with no
/// explanation) by inlining a `do`/`catch` straight into the view's body.
/// That fix was correct but UNTESTABLE where it lived: nothing outside a
/// running SwiftUI host could prove the catch block still runs, still calls
/// `SidebarOperations.describeAttachmentWrite`, and still returns `nil`
/// rather than partial embed syntax — so a future edit reverting the
/// `do`/`catch` back to a `try?` would compile clean and break silently
/// again. Pulling the logic out here — pure, synchronous, no `@State` — is
/// what lets a test call it directly and assert on `failureMessage` without
/// standing up a view host.
@MainActor
func attemptAttachmentWrite(
    write: () throws -> URL, embedSyntax: (URL) -> String
) -> AttachmentWriteResult {
    do {
        let written = try write()
        return AttachmentWriteResult(embedSyntax: embedSyntax(written), failureMessage: nil)
    } catch {
        return AttachmentWriteResult(
            embedSyntax: nil,
            failureMessage: SidebarOperations.describeAttachmentWrite(error))
    }
}
