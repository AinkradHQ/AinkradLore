import CoreGraphics
import Foundation

// Prints "x,y,w,h" for the app's largest on-screen window, for
// `screencapture -R`. Per-window capture (-l) is refused by recent macOS even
// with Screen Recording granted; a region computed from the window's own
// bounds is not.
let pidArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard let targetPid = Int32(pidArg) else {
    FileHandle.standardError.write("invalid PID argument\n".data(using: .utf8)!)
    exit(1)
}

// NOT `.optionOnScreenOnly`: a window that is merely OCCLUDED reports
// onScreen == false, so the obvious filter finds nothing for a running app
// whose window is behind the terminal. The caller activates the app first;
// this just needs to find its largest real window.
guard
    let list = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]]
else { exit(1) }
var best: (Double, String)? = nil
for w in list {
    guard let ownerPID = w[kCGWindowOwnerPID as String] as? Int32, ownerPID == targetPid,
        let b = w[kCGWindowBounds as String] as? [String: Any],
        let x = b["X"] as? Double, let y = b["Y"] as? Double,
        let width = b["Width"] as? Double, let height = b["Height"] as? Double,
        height > 200
    else { continue }
    let area = width * height
    if best == nil || area > best!.0 {
        best = (area, "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))")
    }
}
guard let best else {
    FileHandle.standardError.write("no window for PID \(targetPid)\n".data(using: .utf8)!)
    exit(2)
}
print(best.1)
