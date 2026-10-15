//
//  CampaignColumn.swift
//  NGTable Mac Bench
//
//  A copy of EasyCPA's campaigns table (as of October 2026) for the campaigns bench: the bench
//  shows NGTable on a real app's table. It doesn't follow EasyCPA's changes.

import Foundation

/// Metric groups of a campaign, mirroring the web table's column groups.
nonisolated enum CampaignColumnGroup: String, CaseIterable, Identifiable, Sendable {
    case common
    case adNetwork
    case conversions
    case tracker
    case guarantee
    case controls

    var id: String { rawValue }

    /// Title shown in the group header row; `nil` groups get an empty span.
    var title: String? {
        switch self {
        case .common, .controls: nil
        case .adNetwork: "Рекламная сеть"
        case .conversions: "Конверсии"
        case .tracker: "Трекер"
        case .guarantee: "Гарант"
        }
    }

    /// Section title in the column-visibility menu.
    var menuTitle: String {
        switch self {
        case .common: "Кампания"
        case .controls: "Управление"
        default: title ?? rawValue
        }
    }

    var columns: [CampaignColumn] {
        CampaignColumn.allCases.filter { $0.campaignGroup == self }
    }
}

/// Campaign metrics in the web table's column order. Table layout (widths, pinning, formats)
/// lives in `CampaignsTable`.
nonisolated enum CampaignColumn: String, CaseIterable, Codable, Sendable, Identifiable {
    case id
    case name
    case source
    case platforms
    case account
    case group
    case teasers
    case owner

    case adClicks
    case impressions
    case adSpent
    case adProfit
    case adRoi
    case vCtr

    case conversions
    case hold
    case approved
    case approvePercent
    case rejected

    case clicks
    case cr
    case cph
    case hours
    case revenue
    case spent
    case profit
    case roi
    case cpl
    case epl
    case cpc
    case epc

    case eplG
    case revenueG
    case epcG
    case profitG
    case roiG

    case budget
    case bid
    case status

    var id: String { rawValue }

    var campaignGroup: CampaignColumnGroup {
        switch self {
        case .id, .name, .source, .platforms, .account, .group, .teasers, .owner:
            .common
        case .adClicks, .impressions, .adSpent, .adProfit, .adRoi, .vCtr:
            .adNetwork
        case .conversions, .hold, .approved, .approvePercent, .rejected:
            .conversions
        case .clicks, .cr, .cph, .hours, .revenue, .spent, .profit, .roi, .cpl, .epl, .cpc, .epc:
            .tracker
        case .eplG, .revenueG, .epcG, .profitG, .roiG:
            .guarantee
        case .budget, .bid, .status:
            .controls
        }
    }

    /// Short header title.
    var title: String {
        switch self {
        case .id: "ID"
        case .name: "Кампания"
        case .source: "Источник"
        case .platforms: "Платф."
        case .account: "Аккаунт"
        case .group: "Группа"
        case .teasers: "Тизеры"
        case .owner: "Владелец"
        case .adClicks: "Клики"
        case .impressions: "Показы"
        case .adSpent: "Траты"
        case .adProfit: "Прибыль"
        case .adRoi: "ROI %"
        case .vCtr: "vCTR %"
        case .conversions: "Всего"
        case .hold: "Hold"
        case .approved: "Продажи"
        case .approvePercent: "Аппрув %"
        case .rejected: "Отказы"
        case .clicks: "Клики"
        case .cr: "CR %"
        case .cph: "CP/h"
        case .hours: "H"
        case .revenue: "Доход"
        case .spent: "Траты"
        case .profit: "Прибыль"
        case .roi: "ROI %"
        case .cpl: "CPL"
        case .epl: "EPL"
        case .cpc: "CPC"
        case .epc: "EPC"
        case .eplG: "EPL"
        case .revenueG: "Доход"
        case .epcG: "EPC"
        case .profitG: "Прибыль"
        case .roiG: "ROI %"
        case .budget: "Budget"
        case .bid: "Bid"
        case .status: "Статус"
        }
    }

    /// Unambiguous title for tooltips and the visibility menu.
    var fullTitle: String {
        switch self {
        case .platforms: "Платформы"
        case .teasers: "Тизеры: активные / на модерации / отклонённые"
        case .adClicks: "Клики (сеть)"
        case .impressions: "Показы (сеть)"
        case .adSpent: "Траты (сеть)"
        case .adProfit: "Прибыль (сеть)"
        case .adRoi: "ROI % (сеть)"
        case .vCtr: "vCTR % (сеть)"
        case .conversions: "Конверсии всего"
        case .hold: "Конверсии в холде"
        case .approved: "Продажи (подтверждённые)"
        case .approvePercent: "Аппрув % (и отклонение от гаранта)"
        case .rejected: "Отказы"
        case .clicks: "Клики (трекер)"
        case .cr: "CR % (трекер)"
        case .cph: "Конверсий в час (трекер)"
        case .hours: "Активных часов (трекер)"
        case .revenue: "Доход (трекер)"
        case .spent: "Траты (трекер)"
        case .profit: "Прибыль (трекер)"
        case .roi: "ROI % (трекер)"
        case .cpl: "CPL (трекер)"
        case .epl: "EPL (трекер)"
        case .cpc: "CPC (трекер)"
        case .epc: "EPC (трекер)"
        case .eplG: "EPL (гарант)"
        case .revenueG: "Доход (гарант)"
        case .epcG: "EPC (гарант)"
        case .profitG: "Прибыль (гарант)"
        case .roiG: "ROI % (гарант)"
        case .budget: "Дневной бюджет кампании"
        case .bid: "Ставка кампании"
        default: title
        }
    }

    /// Right-aligned columns.
    var isNumeric: Bool {
        switch self {
        case .id, .name, .source, .platforms, .account, .group, .teasers, .owner, .status:
            false
        default:
            true
        }
    }
}
