import SwiftUI

// Supporting text: reset times, pace lines, captions, the footer.
//
// This was Color.secondary faded further with opacity(0.6–0.7), which measures
// 2.1–2.4:1 against white — under half the 4.5:1 accessibility minimum for small
// text, and lower again over the translucent popover. Reported as hard to read.
// Primary at 65% is 7:1 on white and still clearly quieter than headings.
// The popover is now always dark on Color.panel, where white at 78% keeps
// the same step down from headings and reads at over 11:1.
extension Color {
    static let subtleText = Color.primary.opacity(0.78)

    // The popover's floor: charcoal, 94% opaque, so the desktop behind the
    // menu bar barely shows through. Only the popover uses it; the login and
    // preference windows keep the system's window background.
    static let panel = Color(.sRGB, white: 0.11, opacity: 0.94)
}
