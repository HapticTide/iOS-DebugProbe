// PageTimingEvent.swift
// DebugProbe
//
// Created by Sun on 2025/12/17.
// Copyright © 2025 Sun. All rights reserved.
//

#if canImport(UIKit)
    import UIKit
#endif
import Foundation

// MARK: - Page Timing Event

/// 页面耗时事件
/// 记录一次页面访问的完整生命周期耗时数据
public struct PageTimingEvent: Codable, Sendable {
    // MARK: - Identification

    /// 事件唯一 ID
    public let eventId: String

    /// 访问唯一 ID（区分同一页面的多次访问）
    public let visitId: String

    /// 页面标识（通常为 VC 类名 + 可选业务路由）
    public let pageId: String

    /// 页面展示名称
    public let pageName: String

    /// 业务路由（可选，SwiftUI/Router 等场景使用）
    public let route: String?

    // MARK: - Timestamps (ISO 8601)

    /// 页面开始时间（触发页面展示意图）
    public let startAt: Date

    /// 首次布局完成时间
    public let firstLayoutAt: Date?

    /// viewDidAppear 时间
    public let appearAt: Date?

    /// 页面结束时间（默认 = appearAt，可由业务手动标记）
    public let endAt: Date?

    // MARK: - Durations (毫秒)

    /// 加载耗时: firstLayout - start
    public let loadDuration: Double?

    /// 出现耗时: appear - start（主指标）
    public let appearDuration: Double?

    /// 总耗时: end - start
    public let totalDuration: Double?

    // MARK: - Custom Markers

    /// 自定义标记点
    public let markers: [PageTimingMarker]

    // MARK: - Context

    /// App 版本
    public let appVersion: String?

    /// App Build 号
    public let appBuild: String?

    /// 系统版本
    public let osVersion: String?

    /// 设备型号
    public let deviceModel: String?

    /// 是否冷启动后的首个页面
    public let isColdStart: Bool

    /// 是否通过 push 方式进入
    public let isPush: Bool?

    /// 父页面 ID（如果有）
    public let parentPageId: String?

    // MARK: - Initialization

    public init(
        eventId: String = UUID().uuidString,
        visitId: String,
        pageId: String,
        pageName: String,
        route: String? = nil,
        startAt: Date,
        firstLayoutAt: Date? = nil,
        appearAt: Date? = nil,
        endAt: Date? = nil,
        markers: [PageTimingMarker] = [],
        appVersion: String? = nil,
        appBuild: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        isColdStart: Bool = false,
        isPush: Bool? = nil,
        parentPageId: String? = nil
    ) {
        self.eventId = eventId
        self.visitId = visitId
        self.pageId = pageId
        self.pageName = pageName
        self.route = route
        self.startAt = startAt
        self.firstLayoutAt = firstLayoutAt
        self.appearAt = appearAt
        self.endAt = endAt ?? appearAt
        self.markers = markers
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.isColdStart = isColdStart
        self.isPush = isPush
        self.parentPageId = parentPageId

        // 计算耗时
        if let firstLayout = firstLayoutAt {
            self.loadDuration = firstLayout.timeIntervalSince(startAt) * 1000
        } else {
            self.loadDuration = nil
        }

        if let appear = appearAt {
            self.appearDuration = appear.timeIntervalSince(startAt) * 1000
        } else {
            self.appearDuration = nil
        }

        if let end = self.endAt {
            self.totalDuration = end.timeIntervalSince(startAt) * 1000
        } else {
            self.totalDuration = nil
        }
    }
}

// MARK: - Page Timing Marker

/// 页面耗时自定义标记点
public struct PageTimingMarker: Codable, Sendable {
    /// 标记名称
    public let name: String

    /// 标记时间
    public let timestamp: Date

    /// 距离页面 start 的耗时（毫秒）
    public let deltaMs: Double?

    public init(name: String, timestamp: Date, deltaMs: Double? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.deltaMs = deltaMs
    }
}

// MARK: - Page Visit State

/// 页面访问状态（内部使用）
final class PageVisitState {
    let visitId: String
    let pageId: String
    let pageName: String
    let route: String?
    let startAt: Date
    let isColdStart: Bool
    let isPush: Bool?
    let parentPageId: String?

    var firstLayoutAt: Date?
    var appearAt: Date?
    var endAt: Date?
    var markers: [PageTimingMarker] = []

    /// 是否已完成首次布局
    var hasFirstLayout: Bool = false

    init(
        visitId: String = UUID().uuidString,
        pageId: String,
        pageName: String,
        route: String? = nil,
        startAt: Date = Date(),
        isColdStart: Bool = false,
        isPush: Bool? = nil,
        parentPageId: String? = nil
    ) {
        self.visitId = visitId
        self.pageId = pageId
        self.pageName = pageName
        self.route = route
        self.startAt = startAt
        self.isColdStart = isColdStart
        self.isPush = isPush
        self.parentPageId = parentPageId
    }

    /// 添加自定义标记
    func addMarker(name: String, timestamp: Date = Date()) {
        let deltaMs = timestamp.timeIntervalSince(startAt) * 1000
        markers.append(PageTimingMarker(name: name, timestamp: timestamp, deltaMs: deltaMs))
    }

    /// 转换为事件
    func toEvent() -> PageTimingEvent {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let appBuild = bundle.infoDictionary?["CFBundleVersion"] as? String

        #if canImport(UIKit)
            let osVersion = UIDevice.current.systemVersion
            let deviceModel = UIDevice.current.model
        #else
            let osVersion: String? = nil
            let deviceModel: String? = nil
        #endif

        return PageTimingEvent(
            visitId: visitId,
            pageId: pageId,
            pageName: pageName,
            route: route,
            startAt: startAt,
            firstLayoutAt: firstLayoutAt,
            appearAt: appearAt,
            endAt: endAt,
            markers: markers,
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: osVersion,
            deviceModel: deviceModel,
            isColdStart: isColdStart,
            isPush: isPush,
            parentPageId: parentPageId
        )
    }
}
