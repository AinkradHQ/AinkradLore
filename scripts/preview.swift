// Mount the CodeMirror surface on a real note, so it can be looked at.
//
//   swiftc -O scripts/preview.swift -o scripts/.preview
//   ./scripts/.preview "<note.md>"                 # look at it
//   ./scripts/.preview "<note.md>" --shot out.png  # snapshot it and exit
//
// `--shot` exists because `screencapture` cannot be trusted to photograph this
// window: it captures whatever the WINDOW SERVER is currently compositing, so a
// shot taken while Mission Control is up, or during the open animation, comes
// back as a thumbnail or a skewed sheet — and looks like a rendering bug rather
// than a capture bug. `takeSnapshot` asks the web view itself, which has no
// opinion about window state.
//
// The sibling of `shoot.sh` for the CM6 surface. The settings flag lives in the
// host's key-value store and cannot be flipped from outside the app, so this
// exists to make the surface visible without waiting on E4 or asking someone to
// toggle a preference before every screenshot.
//
// It loads the SHIPPED bundle — Editor/dist — not a copy, so what is on screen
// is what the plugin contains.
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves `![[picture.png]]` the way the plugin's `CM6AssetSchemeHandler` does,
/// but resolving against the note's own directory rather than a vault index —
/// this is a preview tool, and it has no business importing the resolver.
final class Assets: NSObject, WKURLSchemeHandler {
    var root: URL?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
            let target = String(url.path.dropFirst()).removingPercentEncoding,
            let root,
            case let file = root.appendingPathComponent(target),
            // A preview tool still does not serve outside its own folder.
            file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
            let data = try? Data(contentsOf: file)
        else {
            task.didReceive(
                HTTPURLResponse(
                    url: task.request.url!, statusCode: 404,
                    httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let type =
            UTType(
                filenameExtension: root.appendingPathComponent(target)
                    .pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(
            URLResponse(
                url: url, mimeType: type,
                expectedContentLength: data.count,
                textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var document = "# No note given\n\nPass a path as the first argument.\n"
    /// Where to write a snapshot, if `--shot` was given.
    var shotPath: String?
    let assets = Assets()

    func applicationDidFinishLaunching(_ note: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--shot"),
            index + 1 < CommandLine.arguments.count
        {
            shotPath = CommandLine.arguments[index + 1]
        }
        if CommandLine.arguments.count > 1,
            let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        {
            // Body only: the editor is bound to `note.body`, so previewing the
            // frontmatter would be previewing something the editor never sees.
            document = Self.body(of: text)
            assets.root = URL(fileURLWithPath: CommandLine.arguments[1])
                .deletingLastPathComponent()
        }
        let dist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Editor/dist")

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assets, forURLScheme: "lore-asset")
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1000, height: 800),
            configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Lore — CodeMirror surface"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.loadFileURL(
            dist.appendingPathComponent("index.html"),
            allowingReadAccessTo: dist)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let json = String(
            data: try! JSONSerialization.data(withJSONObject: [document]),
            encoding: .utf8)!
        let arg = String(json.dropFirst().dropLast())
        // The caret parks at the END. At offset 0 line 1 is the caret's line,
        // so its syntax is correctly REVEALED — and a snapshot then shows the
        // first line as source while every other line is rendered, which reads
        // as the first line being broken. Cost two rounds of looking at `#` and
        // at unrendered tags before the cause was the caret.
        webView.evaluateJavaScript(
            """
            window.loreEditor.init(\(arg));
            window.loreEditor.selectAt(window.loreEditor.text().length);
            """
        ) { _, _ in
            guard let path = self.shotPath else { return }
            // One turn of the run loop after init, so the decorations the
            // document produces have been laid out. Snapshotting immediately
            // photographs an empty editor, which is the picture that would be
            // most reassuring and least true.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.webView.takeSnapshot(with: nil) { image, error in
                    defer { NSApp.terminate(nil) }
                    guard let image,
                        let tiff = image.tiffRepresentation,
                        let rep = NSBitmapImageRep(data: tiff),
                        let png = rep.representation(using: .png, properties: [:])
                    else {
                        FileHandle.standardError.write(
                            Data("snapshot failed: \(error.map(String.init(describing:)) ?? "no image")\n".utf8))
                        return
                    }
                    try? png.write(to: URL(fileURLWithPath: path))
                    print(path)
                }
            }
        }
    }

    /// The same split `Frontmatter.parse` performs, kept deliberately dumb: a
    /// preview tool has no business importing the parser and no business being
    /// trusted about edge cases.
    static func body(of text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(close + 1)...].joined(separator: "\n")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
