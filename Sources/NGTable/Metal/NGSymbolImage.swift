#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// SF Symbols, white, for the glyph atlas (which tints them): made once by
// name, size and weight, and drawn into the atlas's context the same way on
// the Mac (NSImage) and the iPad (UIImage).

/// A white SF Symbol, its size in points, drawn into a context.
struct NGSymbolImage {
    #if os(macOS)
    let image: NSImage
    #elseif os(iOS)
    let image: UIImage
    #endif

    var size: CGSize { image.size }

    /// Draws it into a context whose y grows downward (the atlas's).
    func draw(into context: CGContext, in rect: CGRect) {
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        #elseif os(iOS)
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
        #endif
    }

    /// Draws it at its size from the context's origin.
    func draw(into context: CGContext) {
        draw(into: context, in: CGRect(origin: .zero, size: size))
    }

    @MainActor private static var made: [String: NGSymbolImage?] = [:]

    /// A symbol by name, white, made once.
    @MainActor
    static func named(_ name: String, pointSize: CGFloat, weight: NGFont.Weight) -> NGSymbolImage? {
        let key = "\(name):\(pointSize):\(weight.rawValue)"
        if let made = made[key] { return made }
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            .map { NGSymbolImage(image: $0) }
        #elseif os(iOS)
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight.symbolWeight)
        let image = (UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal))
            .map { NGSymbolImage(image: $0) }
        #endif
        made[key] = .some(image)
        return image
    }

    /// A filled square with a symbol cut out of it (`checkmark` for a checked
    /// box): the atlas tints a symbol in one color, which would fill the cut too.
    @MainActor
    static func box(cutting name: String, pointSize: CGFloat, weight: NGFont.Weight, key: String) -> NGSymbolImage? {
        if let made = made[key] { return made }
        guard let box = named("square.fill", pointSize: pointSize, weight: weight),
              let cut = named(name, pointSize: pointSize * 0.62, weight: .bold) else { return nil }
        let size = box.size
        let cutRect = CGRect(x: size.width / 2 - cut.size.width / 2, y: size.height / 2 - cut.size.height / 2,
                             width: cut.size.width, height: cut.size.height)
        #if os(macOS)
        let image = NSImage(size: size, flipped: false) { rect in
            box.image.draw(in: rect)
            cut.image.draw(in: cutRect, from: .zero, operation: .destinationOut, fraction: 1)
            return true
        }
        let made = NGSymbolImage(image: image)
        #elseif os(iOS)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            box.image.draw(in: CGRect(origin: .zero, size: size))
            cut.image.draw(in: cutRect, blendMode: .destinationOut, alpha: 1)
        }
        let made = NGSymbolImage(image: image)
        #endif
        self.made[key] = .some(made)
        return made
    }
}

#if os(iOS)
extension UIFont.Weight {
    /// The symbol weight of a font weight.
    var symbolWeight: UIImage.SymbolWeight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
#endif
