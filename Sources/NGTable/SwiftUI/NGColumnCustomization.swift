#if os(macOS)
import SwiftUI

// The user's columns of an `NGDataTable`, to keep in `@SceneStorage` or
// `@AppStorage` like SwiftUI's `TableColumnCustomization`: which columns
// show, and also their order, widths and pins, which SwiftUI's type keeps but
// doesn't let anything else read or write. Columns are known by their ids
// (`customizationID(_:)`).

/// The user's column order, widths, visibility and pins of an `NGDataTable`,
/// like SwiftUI's `TableColumnCustomization`, for `@SceneStorage`:
///
/// ```swift
/// @SceneStorage("CampaignColumns") private var columns = NGColumnCustomization()
///
/// NGDataTable(campaigns) { … }
///     .columnCustomization($columns)
/// ```
public struct NGColumnCustomization: Hashable, Sendable, RawRepresentable {
    /// Top-level item ids (columns and groups) in the user's order; empty: the definition's.
    public var order: [String] = []
    /// Column ids of each group in the user's order, by group id.
    public var groupOrders: [String: [String]] = [:]
    /// Widths the user gave columns, by column id.
    public var widths: [String: Double] = [:]
    /// Regions the user moved items to, by column or group id.
    public var pins: [String: NGColumnPin] = [:]
    /// Visibility set by the user or in code; other columns are `.automatic`
    /// (their `defaultVisibility`).
    private var hidden: Set<String> = []
    private var shown: Set<String> = []

    public init() {}

    /// The visibility of a column, like `TableColumnCustomization`'s:
    /// `.automatic` unless the user or the app chose.
    public subscript(visibility id: String) -> Visibility {
        get { hidden.contains(id) ? .hidden : shown.contains(id) ? .visible : .automatic }
        set {
            hidden.remove(id)
            shown.remove(id)
            switch newValue {
            case .hidden: hidden.insert(id)
            case .visible: shown.insert(id)
            default: break
            }
        }
    }

    /// The definition's order again, keeping visibility, widths and pins.
    public mutating func resetOrder() {
        order = []
        groupOrders = [:]
    }

    // MARK: Storage

    private struct Stored: Codable {
        var order: [String]
        var groupOrders: [String: [String]]
        var widths: [String: Double]
        var pins: [String: NGColumnPin]
        var hidden: [String]
        var shown: [String]
    }

    /// The customization as JSON text (what scene and app storage keep).
    public var rawValue: String {
        let stored = Stored(order: order, groupOrders: groupOrders, widths: widths, pins: pins,
                            hidden: hidden.sorted(), shown: shown.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        order = stored.order
        groupOrders = stored.groupOrders
        widths = stored.widths
        pins = stored.pins
        hidden = Set(stored.hidden)
        shown = Set(stored.shown)
    }

    // MARK: The table's state

    /// The columns hidden with this customization, given those hidden by default.
    func hiddenIDs(defaultHidden: Set<String>) -> Set<String> {
        defaultHidden.subtracting(shown).union(hidden)
    }

    /// The table's layout state with this customization (no sort, filters or grouping: theirs stay).
    func layoutState(defaultHidden: Set<String>) -> NGColumnLayoutState {
        var state = NGColumnLayoutState(order: order, groupOrders: groupOrders, widths: widths,
                                        hiddenIDs: hiddenIDs(defaultHidden: defaultHidden))
        state.pins = pins
        return state
    }

    /// The customization a table's layout state makes: visibility only where
    /// it differs from the defaults (and where it was chosen before).
    init(_ state: NGColumnLayoutState, defaultHidden: Set<String>, keeping previous: NGColumnCustomization) {
        order = state.order
        groupOrders = state.groupOrders
        widths = state.widths
        pins = state.pins ?? [:]
        let all = defaultHidden.union(state.hiddenIDs).union(previous.hidden).union(previous.shown)
        for id in all {
            let isHidden = state.hiddenIDs.contains(id)
            if isHidden != defaultHidden.contains(id) || previous[visibility: id] != .automatic {
                self[visibility: id] = isHidden ? .hidden : .visible
            }
        }
    }
}
#endif
