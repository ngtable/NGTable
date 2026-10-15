#if os(iOS)
import UIKit

/// Covers the table while its data updates (`updatingData`): a veil of the
/// background color, which pales it, a spinner and a text on a plate, and a
/// wall for every touch.
final class NGDataUpdateOverlay: UIView {
    /// Whether touches stop here (off while the veil fades out).
    var blocksInput = true
    var showsIndicator = false {
        didSet { setNeedsLayout() }
    }
    var text: String? {
        didSet {
            label.text = text
            label.isHidden = text?.isEmpty ?? true
            setNeedsLayout()
        }
    }
    var indicatorCenter: CGPoint = .zero {
        didSet { setNeedsLayout() }
    }
    private let indicator = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let plate = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
        plate.layer.cornerRadius = 12
        plate.clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.isHidden = true
        addSubview(plate)
        plate.contentView.addSubview(indicator)
        plate.contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    func startIndicator() {
        guard showsIndicator else { return }
        indicator.startAnimating()
    }

    func stopIndicator() {
        indicator.stopAnimating()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let showsPlate = showsIndicator || !label.isHidden
        plate.isHidden = !showsPlate
        guard showsPlate else { return }
        let labelSize = label.isHidden ? .zero : label.sizeThatFits(CGSize(width: bounds.width - 64, height: 100))
        let indicatorSize = showsIndicator ? indicator.intrinsicContentSize : .zero
        let gap: CGFloat = showsIndicator && !label.isHidden ? 8 : 0
        let size = CGSize(width: max(labelSize.width, indicatorSize.width) + 32, height: indicatorSize.height + gap + labelSize.height + 24)
        plate.frame = CGRect(x: indicatorCenter.x - size.width / 2, y: indicatorCenter.y - size.height / 2, width: size.width, height: size.height)
        indicator.isHidden = !showsIndicator
        indicator.center = CGPoint(x: size.width / 2, y: 12 + indicatorSize.height / 2)
        label.frame = CGRect(x: (size.width - labelSize.width) / 2, y: 12 + indicatorSize.height + gap, width: labelSize.width, height: labelSize.height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        blocksInput && bounds.contains(point) ? self : nil
    }
}
#endif
