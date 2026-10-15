#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// The platform's types under one name, for the parts of the table both the
// Mac's (AppKit) and the iPad's (UIKit) share: on the Mac they are AppKit's
// own types, so nothing changes for AppKit code.

#if os(macOS)
/// The view the table is: `NSView` on the Mac, `UIView` on the iPad.
public typealias NGPlatformView = NSView
/// `NSColor` on the Mac, `UIColor` on the iPad.
public typealias NGColor = NSColor
/// `NSFont` on the Mac, `UIFont` on the iPad.
public typealias NGFont = NSFont
typealias NGLayoutDirection = NSUserInterfaceLayoutDirection
/// What dynamic colors resolve for: `NSAppearance` on the Mac, the trait
/// collection on the iPad.
typealias NGAppearance = NSAppearance
#elseif os(iOS)
public typealias NGPlatformView = UIView
public typealias NGColor = UIColor
public typealias NGFont = UIFont
typealias NGLayoutDirection = UIUserInterfaceLayoutDirection
typealias NGAppearance = UITraitCollection

extension UITraitCollection {
    /// What tells appearances apart for the colors (as `NSAppearance.Name`).
    typealias Name = String

    var name: String { "\(userInterfaceStyle.rawValue):\(accessibilityContrast.rawValue):\(userInterfaceLevel.rawValue)" }

    /// Dynamic colors resolve for these traits in `block` (as NSAppearance's).
    func performAsCurrentDrawingAppearance(_ block: () -> Void) {
        performAsCurrent(block)
    }
}

extension UIView {
    /// The traits colors resolve for (as NSView's `effectiveAppearance`).
    var effectiveAppearance: UITraitCollection { traitCollection }
}
#endif

extension NGColor {
    /// One color in the light appearance, another in the dark.
    static func dynamic(light: NGColor, dark: NGColor) -> NGColor {
        #if os(macOS)
        NGColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        #else
        NGColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}

extension NGPlatformView {
    /// Left to right or right to left, as the interface is laid out.
    var layoutDirection: NGLayoutDirection {
        #if os(macOS)
        userInterfaceLayoutDirection
        #else
        effectiveUserInterfaceLayoutDirection
        #endif
    }
}

/// What the system says or does, the same on both platforms.
@MainActor
enum NGSystem {
    /// The user asked for less motion (Accessibility).
    static var reducesMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Opens a URL in its app.
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
