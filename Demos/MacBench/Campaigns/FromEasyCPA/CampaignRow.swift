//
//  CampaignRow.swift
//  NGTable Mac Bench
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

/// Flattened, display-ready row of the campaign table.
///
/// Every metric the table shows is precomputed here so table columns can sort on plain key paths.
/// Totals are the table's summary row (see `CampaignsTable`).
nonisolated struct CampaignRow: Identifiable, Hashable, Sendable {
    let id: Int
    let campaign: CampaignSummary

    // MARK: Common columns

    let name: String
    let brandingText: String?
    let note: String?
    let network: AdNetwork?
    let adNetworkId: String?
    let mark: CampaignMark
    let sourceName: String
    let groupName: String
    let account: String
    let owner: String
    let platforms: [CampaignPlatform]
    let teasersCounts: CampaignTeasersCounts?
    let status: CampaignStatus?
    let state: CampaignState?
    let currentTask: CurrentTask?
    /// Secondary status text: in-flight task message or the network's status reason.
    let statusDetail: String?
    let problems: CampaignProblems?
    let guaranteeStatus: GuaranteeStatus?
    /// Target approve rate from the guarantee, in percent; 0 when unknown.
    let targetApprovePercent: Double
    /// Daily cap; `nil` means unlimited.
    let budget: Double?
    let budgetSortValue: Double
    /// Bid value: CPC click price, or CPA goal when `bidIsCPA` is true.
    let bid: Double?
    let bidIsCPA: Bool
    let bidSortValue: Double

    // MARK: Ad network metrics

    let adClicks: Int
    let impressions: Int
    let adSpent: Double
    /// Tracker revenue minus ad-network spend.
    let adProfit: Double
    let adRoi: Double
    let vCtr: Double

    // MARK: Conversions

    let conversions: Int
    let holdConversions: Int
    let approvedConversions: Int
    let approvePercent: Double
    let rejectedConversions: Int

    // MARK: Tracker metrics

    let trackerClicks: Int
    let cr: Double
    /// Conversions per active hour.
    let cph: Double
    let activeHours: Double
    let revenue: Double
    let spent: Double
    let profit: Double
    let roi: Double
    let cpl: Double
    let epl: Double
    let cpc: Double
    let epc: Double

    // MARK: Guarantee metrics

    let eplG: Double
    let revenueG: Double
    let epcG: Double
    let profitG: Double
    let roiG: Double

    // MARK: - Building

    init(campaign: CampaignSummary) {
        let info = campaign.info
        let tracker = campaign.report.tracker
        let adNetwork = campaign.report.adNetwork

        id = campaign.id
        self.campaign = campaign

        name = info?.name ?? "#\(campaign.id)"
        brandingText = info?.brandingText
        note = info?.note
        network = info?.adNetwork
        adNetworkId = info?.adNetworkId
        mark = info?.mark ?? .none
        sourceName = info?.trafficSource ?? "Без источника"
        groupName = info?.group ?? "Без группы"
        account = info?.account ?? ""
        owner = info?.owner ?? ""
        platforms = info.map { CampaignPlatform.platforms(ids: $0.platforms, network: $0.adNetwork) } ?? []
        teasersCounts = info?.teasersCounts
        status = info?.status
        state = info?.state
        currentTask = info?.currentTask
        statusDetail = info?.currentTaskMessage ?? info?.statusReason
        problems = info?.problems
        guaranteeStatus = info?.guarantee.guaranteeStatus
        targetApprovePercent = (info?.guarantee.approvePercent ?? 0) * 100

        budget = info?.dailyCap
        budgetSortValue = info?.dailyCap ?? .greatestFiniteMagnitude
        if let clickPrice = info?.clickPrice {
            // The API gives the click price in cents; the CPA goal is in dollars.
            bid = clickPrice / 100
            bidIsCPA = false
        } else {
            bid = info?.cpaGoal
            bidIsCPA = true
        }
        bidSortValue = bid ?? 0

        adClicks = adNetwork.clicks
        impressions = adNetwork.impressions
        adSpent = adNetwork.spent
        adProfit = tracker.saleRevenue - adNetwork.spent
        adRoi = Self.ratio(adProfit, adNetwork.spent) * 100
        vCtr = Self.ratio(Double(adNetwork.clicks), Double(adNetwork.impressions)) * 100

        conversions = tracker.conversionCount
        holdConversions = tracker.holdConversionCount
        approvedConversions = tracker.approveConversionCount
        approvePercent = Self.ratio(Double(tracker.approveConversionCount), Double(tracker.conversionCount)) * 100
        rejectedConversions = tracker.rejectConversionCount

        trackerClicks = tracker.clickCount
        cr = tracker.cr
        cph = Double(tracker.hourlyRate)
        activeHours = Double(tracker.activeHours)
        revenue = tracker.saleRevenue
        spent = tracker.spent
        profit = tracker.profitConfirmed
        roi = tracker.roiConfirmed
        cpl = Self.ratio(tracker.spent, Double(tracker.conversionCount))
        epl = Self.ratio(tracker.saleRevenue, Double(tracker.conversionCount))
        cpc = Self.ratio(tracker.spent, Double(tracker.clickCount))
        epc = Self.ratio(tracker.saleRevenue, Double(tracker.clickCount))

        let guarantee = info?.guarantee
        let earningsPerLead = guarantee?.earningsPerLead ?? 0
        let guaranteedRevenue = earningsPerLead * Double(tracker.conversionCount)
        let hasGuarantee = guarantee?.isEffective ?? false
        eplG = earningsPerLead
        revenueG = guaranteedRevenue
        epcG = Self.ratio(guaranteedRevenue, Double(tracker.clickCount))
        profitG = hasGuarantee ? guaranteedRevenue - tracker.spent : 0
        roiG = hasGuarantee ? Self.ratio(guaranteedRevenue - tracker.spent, tracker.spent) * 100 : 0
    }

    /// "$0.052" for a click price, "CPA $1.50" for a CPA goal, "—" without a bid.
    var bidText: String {
        guard let bid else { return "—" }
        return bidIsCPA ? "CPA " + Formatters.money(bid) : Formatters.money(bid, fractionDigits: 3)
    }

    private static func ratio(_ numerator: Double, _ denominator: Double) -> Double {
        denominator == 0 ? 0 : numerator / denominator
    }
}
