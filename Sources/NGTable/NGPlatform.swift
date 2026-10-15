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
#elseif os(iOS)
public typealias NGPlatformView = UIView
public typealias NGColor = UIColor
public typealias NGFont = UIFont
#endif
