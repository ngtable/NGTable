//
//  Enums.swift
//  NGTable Mac Bench
//
//  GraphQL enums. Raw values match the SCREAMING_SNAKE_CASE names in API/schema.graphqls.
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

nonisolated enum Role: String, Codable, Sendable, Hashable, CaseIterable {
    case user = "USER"
    case admin = "ADMIN"
}

nonisolated enum AdNetwork: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case mgid = "MGID"
    case adskeeper = "ADSKEEPER"
    case taboola = "TABOOLA"
    case outbrain = "OUTBRAIN"
    case geozo = "GEOZO"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mgid: "MGID"
        case .adskeeper: "Adskeeper"
        case .taboola: "Taboola"
        case .outbrain: "Outbrain"
        case .geozo: "Geozo"
        }
    }
}

nonisolated enum CampaignStatus: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case pendingReview = "PENDING_REVIEW"
    case rejected = "REJECTED"
    case paused = "PAUSED"
    case active = "ACTIVE"
    case deleted = "DELETED"
    case null = "NULL"
    case isActivating = "IS_ACTIVATING"
    case autoBlocked = "AUTO_BLOCKED"
    case stoppedBySchedule = "STOPPED_BY_SCHEDULE"
    case stoppedByCap = "STOPPED_BY_CAP"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pendingReview: "На модерации"
        case .rejected: "Отклонена"
        case .paused: "Пауза"
        case .active: "Активна"
        case .deleted: "Удалена"
        case .null: "Без статуса"
        case .isActivating: "Запускается"
        case .autoBlocked: "Автостоп"
        case .stoppedBySchedule: "Стоп по расписанию"
        case .stoppedByCap: "Стоп по капу"
        }
    }

    /// Ordering used when sorting by status: running first, terminal states last.
    var sortRank: Int {
        switch self {
        case .active: 0
        case .isActivating: 1
        case .pendingReview: 2
        case .stoppedBySchedule: 3
        case .stoppedByCap: 4
        case .autoBlocked: 5
        case .paused: 6
        case .rejected: 7
        case .null: 8
        case .deleted: 9
        }
    }
}

/// Campaign lifecycle state in the EasyCPA database (distinct from the ad-network status).
nonisolated enum CampaignState: String, Codable, Sendable, Hashable {
    case exist = "EXIST"
    case deleted = "DELETED"
    case archive = "ARCHIVE"
}

/// Async operation currently in flight for a campaign or teaser.
nonisolated enum CurrentTask: String, Codable, Sendable, Hashable {
    case start = "START"
    case stop = "STOP"
    case delete = "DELETE"

    var displayName: String {
        switch self {
        case .start: "Запуск"
        case .stop: "Остановка"
        case .delete: "Удаление"
        }
    }
}

/// User-assigned marker icon on a campaign. Raw values are Material icon names from the web UI.
nonisolated enum CampaignMark: String, Codable, Sendable, Hashable, CaseIterable {
    case addTask = "ADD_TASK"
    case task = "TASK"
    case moneyOff = "MONEY_OFF"
    case priceCheck = "PRICE_CHECK"
    case heapSnapshotLarge = "HEAP_SNAPSHOT_LARGE"
    case percent = "PERCENT"
    case restartAll = "RESTART_ALL"
    case contentCopy = "CONTENT_COPY"
    case thumbDown = "THUMB_DOWN"
    case thumbUp = "THUMB_UP"
    case star = "STAR"
    case question = "QUESTION"
    case pause = "PAUSE"
    case none = "NONE"

    /// SF Symbol equivalent of the Material icon; `nil` for `none`.
    var symbol: String? {
        switch self {
        case .addTask: "plus.square"
        case .task: "checklist"
        case .moneyOff: "dollarsign.circle.fill"
        case .priceCheck: "tag.circle"
        case .heapSnapshotLarge: "square.stack.3d.up"
        case .percent: "percent"
        case .restartAll: "arrow.trianglehead.2.clockwise"
        case .contentCopy: "doc.on.doc"
        case .thumbDown: "hand.thumbsdown"
        case .thumbUp: "hand.thumbsup"
        case .star: "star.fill"
        case .question: "questionmark.circle"
        case .pause: "pause.circle"
        case .none: nil
        }
    }
}

/// Guarantee (payout insurance) status of a campaign.
nonisolated enum GuaranteeStatus: String, Codable, Sendable, Hashable {
    case disabled = "DISABLED"
    case assumed = "ASSUMED"
    case confirmed = "CONFIRMED"
}

/// Device platform targeted by a campaign. Platform ids in the API are network-specific.
nonisolated enum CampaignPlatform: String, Sendable, Hashable, CaseIterable, Comparable {
    case desktop
    case tablet
    case mobile

    var symbol: String {
        switch self {
        case .desktop: "desktopcomputer"
        case .tablet: "ipad"
        case .mobile: "iphone"
        }
    }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .tablet: "Tablet"
        case .mobile: "Mobile"
        }
    }

    static func < (lhs: CampaignPlatform, rhs: CampaignPlatform) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .desktop: 0
        case .tablet: 1
        case .mobile: 2
        }
    }

    /// Decodes the network-specific platform ids from `Info.platforms`.
    /// An empty list means "all platforms"; Geozo has no platform targeting.
    static func platforms(ids: [Int], network: AdNetwork) -> [CampaignPlatform] {
        if ids.isEmpty {
            return [.desktop, .tablet, .mobile]
        }
        let mapping: [Int: CampaignPlatform]
        switch network {
        case .adskeeper, .mgid:
            mapping = [1: .tablet, 2: .mobile, 3: .desktop]
        case .taboola:
            mapping = [1: .desktop, 2: .mobile, 3: .tablet]
        case .outbrain:
            mapping = [0: .desktop, 1: .mobile, 2: .tablet]
        case .geozo:
            return []
        }
        return Array(Set(ids.compactMap { mapping[$0] })).sorted()
    }
}

nonisolated enum Tracker: String, Codable, Sendable, Hashable, CaseIterable {
    case keitaro = "KEITARO"
    case binom = "BINOM"
    case binomAU = "BINOM_AU"
    case binomEU = "BINOM_EU"
}
