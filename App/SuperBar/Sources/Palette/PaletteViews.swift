import AppKit
import SuperBarKit

// MARK: - Metrics

enum PaletteMetrics {
    static let headerHeight: CGFloat = 52
    static let scopeBarHeight: CGFloat = 30
    static let footerHeight: CGFloat = 28
    static let sectionHeaderHeight: CGFloat = 26
    static let compactRowHeight: CGFloat = 28
    static let subtitledRowHeight: CGFloat = 40
    static let messageRowHeight: CGFloat = 132
    static let skeletonRowHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let selectionRadius: CGFloat = 6
    static let indentation: CGFloat = 16
    /// Where the disclosure chevron column starts (inside the selection rect).
    static let chevronX: CGFloat = horizontalInset + 8
    static let chevronWidth: CGFloat = 16
    /// Where cell content starts for level 0 (the chevron column plus a gap).
    static let contentX: CGFloat = chevronX + chevronWidth + 2
}

/// Everything a row needs to draw itself.
struct RowStyle {
    var theme: ResolvedTheme
    var textSizeDelta: CGFloat
    var showCountBadge: Bool
    var reduceMotion: Bool

    var titleFont: NSFont { .systemFont(ofSize: 13 + textSizeDelta) }
    var subtitleFont: NSFont { .systemFont(ofSize: 11 + textSizeDelta) }
    var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11 + textSizeDelta * 0.5, weight: .medium) }
}

// MARK: - Badge

/// A capsule with optional leading symbol and text (count, key equivalent, ⌘n).
final class BadgeView: NSView {
    var text: String = "" { didSet { needsLayout = true; needsDisplay = true } }
    var symbol: NSImage? { didSet { needsLayout = true; needsDisplay = true } }
    var fillColor: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .medium) { didSet { needsLayout = true } }
    private static let padding: CGFloat = 6
    private static let symbolSize: CGFloat = 9

    override var isFlipped: Bool { true }

    var intrinsicWidth: CGFloat {
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let symbolWidth: CGFloat = symbol == nil ? 0 : BadgeView.symbolSize + 3
        return ceil(textWidth + symbolWidth + BadgeView.padding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        fillColor.setFill()
        path.fill()
        var x = BadgeView.padding
        if let symbol {
            let size = BadgeView.symbolSize
            let rect = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
            let tinted = symbol.tinted(textColor)
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size + 3
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static var symbolCache: [String: NSImage] = [:]

    /// SF Symbol images are comparatively expensive to create; rows are
    /// configured on every keystroke, so cache them.
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)/\(pointSize)/\(weight.rawValue)"
        if let cached = symbolCache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        if let image { symbolCache[key] = image }
        return image
    }
}

// MARK: - Row view (selection)

final class PaletteRowView: NSTableRowView {
    var selectionColor: NSColor = .controlAccentColor
    var hoverColor: NSColor = NSColor.labelColor.withAlphaComponent(0.06)

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: PaletteMetrics.horizontalInset, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: PaletteMetrics.selectionRadius, yRadius: PaletteMetrics.selectionRadius)
        selectionColor.setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent: the panel material shows through.
    }
}

// MARK: - Section header

final class SectionHeaderView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, style: RowStyle) {
        label.stringValue = title
        label.textColor = style.theme.secondaryText
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame = NSRect(x: 2, y: bounds.height - label.frame.height - 3, width: bounds.width - 32, height: label.frame.height)
    }
}

// MARK: - Menu / script row

final class MenuRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let recentOverlay = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let countBadge = BadgeView()
    private let keyBadge = BadgeView()
    private let quickBadge = BadgeView()

    private var style: RowStyle?
    private var showsSubtitle = false
    private var isDisabled = false
    private var isSelectedRow = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        recentOverlay.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1
        [iconView, recentOverlay, titleLabel, subtitleLabel, countBadge, keyBadge, quickBadge].forEach(addSubview)
        quickBadge.symbol = .symbol("bolt.fill", pointSize: 9, weight: .bold)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(row: PaletteRow, style: RowStyle, selected: Bool) {
        self.style = style
        self.isSelectedRow = selected
        showsSubtitle = row.showsSubtitle
        isDisabled = false
        var subtitle = ""
        var count: Int? = nil
        var key: String? = nil
        var mark: String? = nil
        var title = row.title
        var symbolName = "list.bullet.rectangle"

        switch row.kind {
        case .menu(let node):
            isDisabled = !node.isEnabled
            title = row.showsSubtitle ? node.displayTitle : node.title
            if node.title == "Apple" && node.depth == 0 { title = "\u{F8FF}" }   // Apple logo glyph
            subtitle = row.showsSubtitle ? node.subtitlePath.joined(separator: " › ") : ""
            if node.isContainer { count = node.visibleChildCount }
            key = node.keyEquivalent?.display
            mark = node.mark
            symbolName = node.depth == 0 ? "menubar.rectangle" : "list.bullet.rectangle"
        case .script:
            symbolName = "curlybraces.square"
            subtitle = row.showsSubtitle ? "Scripts" : ""
        default:
            break
        }

        iconView.image = .symbol(symbolName, pointSize: 15, weight: .regular)
        recentOverlay.image = row.isRecent ? .symbol("clock.fill", pointSize: 8, weight: .bold) : nil
        recentOverlay.isHidden = !row.isRecent

        titleLabel.attributedStringValue = MenuRowView.attributedTitle(title, mark: mark, ranges: row.ranges, font: style.titleFont, color: titleColor)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = style.subtitleFont
        subtitleLabel.isHidden = subtitle.isEmpty

        if let count, style.showCountBadge {
            countBadge.text = String(count)
            countBadge.isHidden = false
        } else {
            countBadge.isHidden = true
        }
        if let key {
            keyBadge.text = key
            keyBadge.isHidden = false
        } else {
            keyBadge.isHidden = true
        }
        if let q = row.quickIndex {
            quickBadge.text = "⌘\(q)"
            quickBadge.isHidden = false
        } else {
            quickBadge.isHidden = true
        }
        for badge in [countBadge, keyBadge, quickBadge] { badge.font = style.badgeFont }
        applyColors()
        needsLayout = true
    }

    private var titleColor: NSColor {
        guard let style else { return .labelColor }
        let base = isSelectedRow ? style.theme.selectionText : style.theme.text
        return isDisabled ? base.withAlphaComponent(0.4) : base
    }

    private func applyColors() {
        guard let style else { return }
        let theme = style.theme
        let selected = isSelectedRow
        let text = titleColor
        iconView.contentTintColor = selected ? theme.selectionText : theme.accent
        recentOverlay.contentTintColor = selected ? theme.selectionText : theme.secondaryText
        subtitleLabel.textColor = selected ? theme.selectionText.withAlphaComponent(0.8) : theme.secondaryText
        titleLabel.attributedStringValue = MenuRowView.recolor(titleLabel.attributedStringValue, color: text)
        let badgeFill = selected ? theme.selectionText.withAlphaComponent(0.22) : theme.badgeBackground
        let badgeText = selected ? theme.selectionText : theme.badgeText
        countBadge.fillColor = badgeFill; countBadge.textColor = badgeText
        keyBadge.fillColor = badgeFill; keyBadge.textColor = badgeText
        quickBadge.fillColor = selected ? theme.selectionText.withAlphaComponent(0.22) : theme.accent.withAlphaComponent(0.16)
        quickBadge.textColor = selected ? theme.selectionText : theme.accent
        if isDisabled && !selected {
            iconView.contentTintColor = theme.accent.withAlphaComponent(0.4)
        }
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelectedRow else { return }
        isSelectedRow = selected
        applyColors()
    }

    /// Cheap update of the ⌘n badge only (used after expand/collapse).
    func updateQuickIndex(_ index: Int?) {
        if let index {
            let text = "⌘\(index)"
            if quickBadge.isHidden || quickBadge.text != text {
                quickBadge.text = text
                quickBadge.isHidden = false
                needsLayout = true
            }
        } else if !quickBadge.isHidden {
            quickBadge.isHidden = true
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 2
        let h = bounds.height
        let iconSize: CGFloat = 20
        iconView.frame = NSRect(x: inset, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        recentOverlay.frame = NSRect(x: inset + iconSize - 8, y: (h - iconSize) / 2 + iconSize - 9, width: 10, height: 10)

        var right = bounds.width - PaletteMetrics.horizontalInset - 10
        let badgeHeight: CGFloat = 18
        for badge in [quickBadge, keyBadge] where !badge.isHidden {
            let w = badge.intrinsicWidth
            badge.frame = NSRect(x: right - w, y: (h - badgeHeight) / 2, width: w, height: badgeHeight)
            right -= w + 6
        }

        let textX = inset + iconSize + 12
        let available = right - textX - 4
        if showsSubtitle && !subtitleLabel.isHidden {
            titleLabel.frame = NSRect(x: textX, y: 4, width: available, height: 17 + (style?.textSizeDelta ?? 0))
            subtitleLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY, width: available, height: 15 + (style?.textSizeDelta ?? 0))
        } else {
            let th = 18 + (style?.textSizeDelta ?? 0)
            titleLabel.frame = NSRect(x: textX, y: (h - th) / 2, width: available, height: th)
        }
        if !countBadge.isHidden {
            let titleWidth = min(titleLabel.attributedStringValue.size().width + 2, available)
            let w = countBadge.intrinsicWidth
            countBadge.frame = NSRect(x: textX + titleWidth + 6, y: titleLabel.frame.midY - 8, width: w, height: 16)
            countBadge.isHidden = countBadge.frame.maxX > right
        }
    }

    override var isFlipped: Bool { true }

    static func attributedTitle(_ title: String, mark: String?, ranges: [NSRange], font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let mark, !mark.isEmpty {
            result.append(NSAttributedString(string: mark + " ", attributes: [.font: font, .foregroundColor: color]))
        }
        let offset = result.length
        let body = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        for r in ranges where r.location + r.length <= body.length {
            body.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color.withAlphaComponent(0.9)], range: r)
        }
        result.append(body)
        _ = offset
        return result
    }

    static func recolor(_ string: NSAttributedString, color: NSColor) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
        copy.enumerateAttribute(.underlineColor, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { copy.addAttribute(.underlineColor, value: color.withAlphaComponent(0.9), range: range) }
        }
        return copy
    }
}

// MARK: - Message row (errors, empty states)

final class MessageRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.alignment = .center
        subtitleLabel.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = #selector(tapped)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        [iconView, titleLabel, subtitleLabel, button].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(message: PaletteRow.Message, style: RowStyle) {
        iconView.image = .symbol(message.symbol, pointSize: 26, weight: .medium)
        iconView.contentTintColor = style.theme.secondaryText
        titleLabel.stringValue = message.title
        titleLabel.textColor = style.theme.text
        subtitleLabel.stringValue = message.subtitle ?? ""
        subtitleLabel.textColor = style.theme.secondaryText
        button.title = message.actionTitle ?? ""
        button.isHidden = message.actionTitle == nil
        if !button.isHidden { button.keyEquivalent = "" }
        needsLayout = true
    }

    @objc private func tapped() { onAction?() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        iconView.frame = NSRect(x: (w - 30) / 2, y: 14, width: 30, height: 30)
        titleLabel.frame = NSRect(x: 20, y: 50, width: w - 40, height: 20)
        subtitleLabel.frame = NSRect(x: 40, y: 72, width: w - 80, height: 30)
        button.sizeToFit()
        button.frame = NSRect(x: (w - button.frame.width - 16) / 2, y: bounds.height - button.frame.height - 8, width: button.frame.width + 16, height: button.frame.height)
    }
}

// MARK: - Skeleton row (loading)

final class SkeletonRowView: NSTableCellView {
    var barColor: NSColor = NSColor.labelColor.withAlphaComponent(0.08)
    var seed: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 2
        let widths: [CGFloat] = [0.32, 0.45, 0.28, 0.5, 0.38, 0.42]
        let icon = NSRect(x: inset, y: bounds.midY - 9, width: 18, height: 18)
        barColor.setFill()
        NSBezierPath(roundedRect: icon, xRadius: 4, yRadius: 4).fill()
        let w = (bounds.width - inset - 60) * widths[seed % widths.count]
        let bar = NSRect(x: inset + 30, y: bounds.midY - 6, width: w, height: 12)
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Outline view

final class PaletteOutlineView: NSOutlineView {
    /// Keyboard focus stays in the search field.
    override var acceptsFirstResponder: Bool { false }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        let level = CGFloat(self.level(forRow: row))
        frame.origin.x = level * indentationPerLevel + PaletteMetrics.chevronX
        frame.size.width = PaletteMetrics.chevronWidth
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let level = CGFloat(self.level(forRow: row))
        // Leave room for the disclosure chevron at every level, consistently.
        frame.origin.x = level * indentationPerLevel + PaletteMetrics.contentX
        frame.size.width = bounds.width - frame.origin.x
        return frame
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// MARK: - Search field

final class PaletteSearchField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 16)
        placeholderString = "Search"
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        cell?.sendsActionOnEndEditing = false
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Thin horizontal rule.
final class SeparatorView: NSView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// "⊗ Searching in: Format" bar shown while scoped.
final class ScopeBarView: NSView {
    private let clearButton = NSButton()
    private let label = NSTextField(labelWithString: "Searching in:")
    private let token = BadgeView()
    var onClear: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.image = .symbol("xmark.circle.fill", pointSize: 13, weight: .regular)
        clearButton.imagePosition = .imageOnly
        clearButton.target = self
        clearButton.action = #selector(clear)
        label.font = .systemFont(ofSize: 11)
        token.font = .systemFont(ofSize: 11, weight: .medium)
        [clearButton, label, token].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(scopeTitle: String, theme: ResolvedTheme) {
        token.text = scopeTitle
        token.fillColor = theme.badgeBackground
        token.textColor = theme.text
        label.textColor = theme.secondaryText
        clearButton.contentTintColor = theme.secondaryText
        needsLayout = true
    }

    @objc private func clear() { onClear?() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let x = PaletteMetrics.horizontalInset + 10
        clearButton.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.sizeToFit()
        label.frame = NSRect(x: clearButton.frame.maxX + 6, y: (bounds.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        let w = token.intrinsicWidth
        token.frame = NSRect(x: label.frame.maxX + 6, y: (bounds.height - 18) / 2, width: w, height: 18)
    }
}
