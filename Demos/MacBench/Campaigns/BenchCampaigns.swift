//
//  BenchCampaigns.swift
//  NGTable Mac Bench
//
//  synthetic campaigns for the NGTable bench, built as the API's models (so they go
//  through `CampaignRow` and the real campaigns table). Metrics hang together (clicks from
//  impressions, conversions from clicks, revenue from approved conversions), statuses and marks
//  follow rough production shares, and a share of the fields is left empty. Seeded, so the same
//  settings give the same data.
//

import Foundation

nonisolated enum BenchCampaigns {
    /// A fast, seedable generator (SplitMix64).
    struct Random: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &self) < probability }
        mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
        /// Mostly small, sometimes large: campaigns' traffic spans orders of magnitude.
        mutating func skewed(_ range: ClosedRange<Double>) -> Double {
            let unit = Double.random(in: 0...1, using: &self)
            return range.lowerBound + (range.upperBound - range.lowerBound) * unit * unit * unit
        }
    }

    // MARK: Vocabulary

    private static let countries = ["DE", "IT", "ES", "FR", "PL", "CZ", "RO", "HU", "PT", "NL", "AT", "GR", "BG", "SK", "HR"]
    private static let verticals = ["Keto", "Diabetes", "Joints", "Hearing", "Vision", "Prostatitis", "Cardio",
                                    "Weight Loss", "Parasites", "Hair", "Skin", "Varicose", "Detox", "Sleep"]
    private static let formats = ["Wide", "Video", "Carousel", "Native", "Push", "Retarget", "Lookalike", "Test", "Broad", "Narrow"]
    private static let sources = (1...24).map { "B-\(["EU", "LATAM", "ASIA", "CIS"][$0 % 4]) Source \($0)" }
    private static let accounts = (1...60).map { String(format: "acc-%03d", $0) }
    private static let groups = ["Здоровье", "Суставы", "Диабет", "Похудение", "Зрение", "Слух", "Тесты", "Масштаб",
                                 "Ретаргет", "Новые офферы", "Видео", "Пуш", "Ночные", "Выходные"]
    private static let owners = ["anna", "boris", "vera", "gleb", "dina", "egor", "zhanna", "ilya"]
    private static let statuses: [(CampaignStatus, Double)] = [
        (.active, 0.45), (.paused, 0.20), (.pendingReview, 0.08), (.rejected, 0.05), (.autoBlocked, 0.05),
        (.stoppedByCap, 0.05), (.stoppedBySchedule, 0.04), (.isActivating, 0.03), (.deleted, 0.02), (.null, 0.03),
    ]

    // MARK: Making campaigns

    /// `count` campaigns with ids from 1; `emptyShare` of the optional fields is left empty.
    static func make(count: Int, emptyShare: Double, seed: UInt64) -> [CampaignRow] {
        summaries(count: count, emptyShare: emptyShare, seed: seed).map(CampaignRow.init(campaign:))
    }

    /// The same campaigns as the server sends them.
    static func summaries(count: Int, emptyShare: Double, seed: UInt64) -> [CampaignSummary] {
        var random = Random(seed: seed)
        return (0..<max(count, 0)).map { index in campaign(id: index + 1, emptyShare: emptyShare, random: &random) }
    }

    private static func campaign(id: Int, emptyShare: Double, random: inout Random) -> CampaignSummary {
        let network = random.pick(AdNetwork.allCases)
        // Some campaigns aren't synced yet: no card at all.
        let info: CampaignInfo? = random.chance(emptyShare / 5) ? nil : self.info(id: id, network: network, emptyShare: emptyShare, random: &random)
        let hasTraffic = !random.chance(emptyShare)
        return CampaignSummary(id: id, info: info, report: report(hasTraffic: hasTraffic, random: &random))
    }

    private static func info(id: Int, network: AdNetwork, emptyShare: Double, random: inout Random) -> CampaignInfo {
        func optional<T>(_ value: T) -> T? { random.chance(emptyShare) ? nil : value }
        let status = pickStatus(&random)
        let task: CurrentTask? = random.chance(0.03) ? random.pick([.start, .stop, .delete]) : nil
        let usesCPA = random.chance(0.3)
        let hasProblems = random.chance(0.12)
        let marked = random.chance(0.15)
        return CampaignInfo(
            name: "\(random.pick(countries)) \(random.pick(verticals)) \(random.pick(formats)) #\(id)",
            brandingText: optional("Brand \(id % 97)"),
            adNetwork: network,
            adNetworkId: optional("\(network.rawValue.lowercased())-\(100_000 + id)"),
            account: optional(random.pick(accounts)) ?? "",
            owner: optional(random.pick(owners)) ?? "",
            creatorId: 1,
            status: status,
            statusReason: status == .rejected || status == .autoBlocked ? "Причина \(id % 7)" : nil,
            state: status == .deleted ? .deleted : .exist,
            currentTask: task,
            currentTaskMessage: task.map { "\($0.displayName)…" },
            clickPrice: usesCPA ? nil : (random.skewed(2...80)).rounded(),
            dailyCap: optional((random.skewed(20...2_000) / 10).rounded() * 10),
            cpaGoal: usesCPA ? (random.skewed(5...60)).rounded() : nil,
            mark: marked ? random.pick(CampaignMark.allCases) : .none,
            note: random.chance(0.1) ? "Заметка \(id)" : nil,
            group: optional(random.pick(groups)),
            groupId: nil,
            trafficSource: optional(random.pick(sources)),
            domain: "example.com",
            categoryName: "Health",
            countries: [random.pick(countries)],
            platforms: Array([0, 1, 2, 3].filter { _ in random.chance(0.5) }),
            devices: [],
            os: [],
            startedAt: nil,
            updatedByUserAt: nil,
            teasersCounts: teasers(&random),
            guarantee: GuaranteeInfo(leadWorth: random.skewed(10...60).rounded(), approvePercent: Double.random(in: 0.2...0.7, using: &random),
                                     trashPercent: Double.random(in: 0...0.2, using: &random),
                                     guaranteeStatus: random.pick([.disabled, .assumed, .confirmed])),
            problems: CampaignProblems(hasProblems: hasProblems, hasCancelledTeasers: hasProblems && random.chance(0.5),
                                       hasBrokenUrls: hasProblems && random.chance(0.3), hasBrokenPrices: false,
                                       hasBetterOffer: false, betterOfferName: nil, hasOfferSplitImbalance: false,
                                       splitImbalanceText: nil, hasModerationOffer: false, moderationOfferName: nil,
                                       hasNetworkSyncIssue: hasProblems && random.chance(0.2)),
            links: CampaignLinks(trackerCampaignUrl: nil, trackerStatsLink: nil, trackerEditLink: nil,
                                 adNetworkStatsLink: nil, adNetworkEditLink: nil, adNetworkTeasersLink: nil)
        )
    }

    private static func pickStatus(_ random: inout Random) -> CampaignStatus {
        var roll = Double.random(in: 0..<1, using: &random)
        for (status, share) in statuses {
            roll -= share
            if roll < 0 { return status }
        }
        return .active
    }

    private static func teasers(_ random: inout Random) -> CampaignTeasersCounts {
        func count(_ upper: Int) -> Int { Int.random(in: 0...upper, using: &random) }
        return CampaignTeasersCounts(
            allPictureTeasers: count(30), allVideoTeasers: count(8), allMotionTeasers: count(3),
            activePictureTeasers: count(20), activeVideoTeasers: count(5), activeMotionTeasers: count(2),
            moderationPictureTeasers: count(4), moderationVideoTeasers: count(2), moderationMotionTeasers: count(1),
            rejectedPictureTeasers: count(4), rejectedVideoTeasers: count(1), rejectedMotionTeasers: count(1)
        )
    }

    // MARK: Metrics

    private static func report(hasTraffic: Bool, random: inout Random) -> CampaignReport {
        guard hasTraffic else { return report(impressions: 0, random: &random) }
        return report(impressions: Int(random.skewed(500...2_000_000)), random: &random)
    }

    /// Metrics that follow from the impressions, with some noise.
    private static func report(impressions: Int, random: inout Random) -> CampaignReport {
        let ctr = Double.random(in: 0.002...0.02, using: &random)
        let adClicks = Int(Double(impressions) * ctr)
        let cpc = Double.random(in: 0.02...0.6, using: &random)
        let adSpent = (Double(adClicks) * cpc * 100).rounded() / 100
        let trackerClicks = Int(Double(adClicks) * Double.random(in: 0.85...0.98, using: &random))
        let cr = Double.random(in: 0...0.05, using: &random)
        let conversions = Int(Double(trackerClicks) * cr)
        let approved = Int(Double(conversions) * Double.random(in: 0.2...0.7, using: &random))
        let rejected = Int(Double(conversions - approved) * Double.random(in: 0...0.5, using: &random))
        let revenue = (Double(approved) * Double.random(in: 10...60, using: &random) * 100).rounded() / 100
        let spent = (adSpent * Double.random(in: 0.95...1.0, using: &random) * 100).rounded() / 100
        let profit = revenue - spent
        let hours = conversions == 0 ? 0 : Int.random(in: 1...24, using: &random)
        let tracker = TrackerReport(
            clickCount: trackerClicks, conversionCount: conversions, holdConversionCount: conversions - approved - rejected,
            approveConversionCount: approved, rejectConversionCount: rejected,
            cr: trackerClicks == 0 ? 0 : Double(conversions) / Double(trackerClicks) * 100,
            spent: spent, saleRevenue: revenue, profitConfirmed: profit,
            roiConfirmed: spent == 0 ? 0 : profit / spent * 100,
            activeHours: hours, hourlyRate: hours == 0 ? 0 : conversions / hours
        )
        let adNetwork = AdNetworkReport(clicks: adClicks, impressions: impressions, ctr: ctr, spent: adSpent, cpc: cpc)
        return CampaignReport(tracker: tracker, adNetwork: adNetwork)
    }

    /// The campaign a few minutes later: more traffic, now and then another status (which moves it
    /// to another group when grouped by status).
    static func advanced(_ row: CampaignRow, random: inout Random) -> CampaignRow {
        let campaign = row.campaign
        let impressions = campaign.report.adNetwork.impressions + Int(random.skewed(100...20_000))
        var info = campaign.info
        if let current = info, random.chance(0.05) {
            info = current.with(status: pickStatus(&random))
        }
        return CampaignRow(campaign: CampaignSummary(id: campaign.id, info: info, report: report(impressions: impressions, random: &random)))
    }
}

private extension CampaignInfo {
    nonisolated func with(status: CampaignStatus) -> CampaignInfo {
        CampaignInfo(name: name, brandingText: brandingText, adNetwork: adNetwork, adNetworkId: adNetworkId, account: account,
                     owner: owner, creatorId: creatorId, status: status, statusReason: statusReason, state: state,
                     currentTask: currentTask, currentTaskMessage: currentTaskMessage, clickPrice: clickPrice,
                     dailyCap: dailyCap, cpaGoal: cpaGoal, mark: mark, note: note, group: group, groupId: groupId,
                     trafficSource: trafficSource, domain: domain, categoryName: categoryName, countries: countries,
                     platforms: platforms, devices: devices, os: os, startedAt: startedAt, updatedByUserAt: updatedByUserAt,
                     teasersCounts: teasersCounts, guarantee: guarantee, problems: problems, links: links)
    }
}
