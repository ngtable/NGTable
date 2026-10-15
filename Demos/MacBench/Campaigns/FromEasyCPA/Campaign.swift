//
//  Campaign.swift
//  NGTable Mac Bench
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

/// A campaign row from `campaigns(filter:)` — `Icampaign` with `info` and `report` selected.
nonisolated struct CampaignSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    /// Snapshot of the campaign card. `nil` when the campaign has not been synced yet.
    let info: CampaignInfo?
    let report: CampaignReport
}

/// GraphQL `Info` — the campaign card (subset used by the list screen).
nonisolated struct CampaignInfo: Decodable, Sendable, Hashable {
    let name: String
    let brandingText: String?
    let adNetwork: AdNetwork
    /// Campaign id inside the ad network.
    let adNetworkId: String?
    let account: String
    let owner: String
    let creatorId: Int
    let status: CampaignStatus
    let statusReason: String?
    let state: CampaignState
    let currentTask: CurrentTask?
    let currentTaskMessage: String?
    let clickPrice: Double?
    let dailyCap: Double?
    let cpaGoal: Double?
    let mark: CampaignMark
    let note: String?
    let group: String?
    let groupId: Int?
    let trafficSource: String?
    let domain: String?
    let categoryName: String?
    let countries: [String]
    /// Network-specific platform ids; see `CampaignPlatform.platforms(ids:network:)`.
    let platforms: [Int]
    let devices: [String]
    let os: [String]
    let startedAt: Date?
    let updatedByUserAt: Date?
    let teasersCounts: CampaignTeasersCounts
    let guarantee: GuaranteeInfo
    let problems: CampaignProblems
    let links: CampaignLinks
}

/// GraphQL `GuaranteeInfo` — payout guarantee parameters used for the "(G)" metric columns.
nonisolated struct GuaranteeInfo: Decodable, Sendable, Hashable {
    let leadWorth: Double
    /// Fraction (0...1), unlike the tracker percentages.
    let approvePercent: Double
    /// Fraction (0...1).
    let trashPercent: Double
    let guaranteeStatus: GuaranteeStatus

    /// Expected earnings per lead after approve and trash rates; zero when the guarantee is disabled.
    var earningsPerLead: Double {
        guard guaranteeStatus != .disabled else { return 0 }
        let gross = leadWorth * approvePercent
        return gross - gross * trashPercent
    }

    /// Whether the guarantee has all three inputs and is not disabled (web: `isThereGuarant`).
    var isEffective: Bool {
        guaranteeStatus != .disabled && leadWorth != 0 && approvePercent != 0 && trashPercent != 0
    }
}

nonisolated struct CampaignTeasersCounts: Decodable, Sendable, Hashable {
    let allPictureTeasers: Int
    let allVideoTeasers: Int
    let allMotionTeasers: Int
    let activePictureTeasers: Int
    let activeVideoTeasers: Int
    let activeMotionTeasers: Int
    let moderationPictureTeasers: Int
    let moderationVideoTeasers: Int
    let moderationMotionTeasers: Int
    let rejectedPictureTeasers: Int
    let rejectedVideoTeasers: Int
    let rejectedMotionTeasers: Int

    var total: Int { allPictureTeasers + allVideoTeasers + allMotionTeasers }
    var active: Int { activePictureTeasers + activeVideoTeasers + activeMotionTeasers }
    var onModeration: Int { moderationPictureTeasers + moderationVideoTeasers + moderationMotionTeasers }
    var rejected: Int { rejectedPictureTeasers + rejectedVideoTeasers + rejectedMotionTeasers }
}

nonisolated struct CampaignProblems: Decodable, Sendable, Hashable {
    let hasProblems: Bool
    let hasCancelledTeasers: Bool
    let hasBrokenUrls: Bool
    let hasBrokenPrices: Bool
    let hasBetterOffer: Bool
    let betterOfferName: String?
    let hasOfferSplitImbalance: Bool
    let splitImbalanceText: String?
    let hasModerationOffer: Bool
    let moderationOfferName: String?
    let hasNetworkSyncIssue: Bool

    /// Human-readable list of active problems for tooltips.
    var descriptions: [String] {
        var items: [String] = []
        if hasCancelledTeasers { items.append("Есть отклонённые тизеры") }
        if hasBrokenUrls { items.append("Битые ссылки в тизерах") }
        if hasBrokenPrices { items.append("Некорректные цены тизеров") }
        if hasBetterOffer { items.append("Есть более выгодный оффер" + (betterOfferName.map { ": \($0)" } ?? "")) }
        if hasOfferSplitImbalance { items.append(splitImbalanceText ?? "Дисбаланс сплита офферов") }
        if hasModerationOffer { items.append("Оффер на модерации" + (moderationOfferName.map { ": \($0)" } ?? "")) }
        if hasNetworkSyncIssue { items.append("Проблема синхронизации с сетью") }
        return items
    }
}

nonisolated struct CampaignLinks: Decodable, Sendable, Hashable {
    let trackerCampaignUrl: String?
    let trackerStatsLink: String?
    let trackerEditLink: String?
    let adNetworkStatsLink: String?
    let adNetworkEditLink: String?
    let adNetworkTeasersLink: String?
}

/// GraphQL `Report` — metrics from the tracker and from the ad network for the requested range.
nonisolated struct CampaignReport: Decodable, Sendable, Hashable {
    let tracker: TrackerReport
    let adNetwork: AdNetworkReport
}

/// Tracker-side metrics. `cr` and `roiConfirmed` are already percentages (×100).
nonisolated struct TrackerReport: Decodable, Sendable, Hashable {
    let clickCount: Int
    let conversionCount: Int
    let holdConversionCount: Int
    let approveConversionCount: Int
    let rejectConversionCount: Int
    let cr: Double
    let spent: Double
    let saleRevenue: Double
    let profitConfirmed: Double
    let roiConfirmed: Double
    let activeHours: Int
    let hourlyRate: Int
}

/// Ad-network-side metrics. `ctr` is a ratio (0.012 = 1.2%), unlike the tracker percentages.
nonisolated struct AdNetworkReport: Decodable, Sendable, Hashable {
    let clicks: Int
    let impressions: Int
    let ctr: Double
    let spent: Double
    let cpc: Double
}

// MARK: - Presentation helpers

nonisolated extension CampaignSummary {
    var displayName: String { info?.name ?? "#\(id)" }
    var networkName: String { info?.adNetwork.displayName ?? "—" }
    var statusRank: Int { info?.status.sortRank ?? 99 }
    var clickPrice: Double { info?.clickPrice ?? 0 }

    /// Secondary line for the list: account, owner and group.
    var subtitle: String {
        guard let info else { return "Нет данных карточки" }
        return [info.account, info.owner, info.group]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
