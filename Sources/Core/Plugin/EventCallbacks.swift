// EventCallbacks.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 事件回调中心

/// 全局事件回调注册中心
/// 提供静态回调机制让捕获层直接上报事件到插件系统
/// 插件处理后通过 onDebugEvent 统一上报到 BridgeClient
public enum EventCallbacks {
    // MARK: - Input Callbacks (捕获层 → 插件层)

    /// HTTP 事件回调
    public static var onHTTPEvent: ((HTTPEvent) -> Void)?

    /// 上报 HTTP 事件
    public static func reportHTTP(_ event: HTTPEvent) {
        DebugLog.debug(.network, "[EventCallbacks] reportHTTP called, onHTTPEvent is \(onHTTPEvent == nil ? "nil" : "set")")
        onHTTPEvent?(event)
    }

    /// 日志事件回调
    public static var onLogEvent: ((LogEvent) -> Void)?

    /// 上报日志事件
    public static func reportLog(_ event: LogEvent) {
        onLogEvent?(event)
    }

    /// WebSocket 事件回调
    public static var onWebSocketEvent: ((WSEvent) -> Void)?

    /// 上报 WebSocket 事件
    public static func reportWebSocket(_ event: WSEvent) {
        onWebSocketEvent?(event)
    }

    // MARK: - Output Callback (插件层 → BridgeClient)

    /// 统一事件输出回调
    /// 插件处理后的事件通过此回调上报到 BridgeClient
    public static var onDebugEvent: ((DebugEvent) -> Void)?

    /// 上报调试事件到 BridgeClient
    public static func reportEvent(_ event: DebugEvent) {
        let eventDesc: String
        switch event {
        case let .http(httpEvent):
            eventDesc = "HTTP \(httpEvent.request.method) \(httpEvent.request.url.prefix(50))"
        case let .log(logEvent):
            eventDesc = "Log [\(logEvent.level)]"
        case .webSocket:
            eventDesc = "WebSocket"
        case .stats:
            eventDesc = "Stats"
        case .performance:
            eventDesc = "Performance"
        }
        DebugLog.debug(.bridge, "[EventCallbacks] reportEvent called: \(eventDesc), onDebugEvent is \(onDebugEvent == nil ? "nil" : "set")")
        onDebugEvent?(event)
    }

    // MARK: - Mock Handlers (拦截处理)

    /// HTTP Mock 请求处理器
    /// - 返回 (修改后的请求, Mock响应, 匹配的规则ID)
    public static var mockHTTPRequest: ((URLRequest) -> (URLRequest, HTTPEvent.Response?, String?))?

    /// WebSocket 发送帧 Mock 处理器
    /// - 返回 (修改后的负载, 是否Mock, 匹配的规则ID)
    public static var mockWSOutgoingFrame: ((Data, String, String) -> (Data, Bool, String?))?

    /// WebSocket 接收帧 Mock 处理器
    /// - 返回 (修改后的负载, 是否Mock, 匹配的规则ID)
    public static var mockWSIncomingFrame: ((Data, String, String) -> (Data, Bool, String?))?

    // MARK: - Chaos Handlers (故障注入)

    /// Chaos 请求评估处理器
    /// - 输入: URLRequest
    /// - 返回: ChaosResult (延迟、超时、错误等)
    public static var chaosEvaluate: ((URLRequest) -> ChaosResult)?

    /// Chaos 响应评估处理器
    /// - 输入: (URLRequest, HTTPURLResponse, Data?)
    /// - 返回: ChaosResult
    public static var chaosEvaluateResponse: ((URLRequest, HTTPURLResponse, Data?) -> ChaosResult)?

    // MARK: - Breakpoint Handlers (断点调试)

    /// 请求阶段断点处理器 (异步)
    /// - 输入: (requestId, URLRequest)
    /// - 返回: RequestBreakpointResult (继续/中止/Mock响应)
    public static var breakpointCheckRequest: ((String, URLRequest) async -> RequestBreakpointResult)?

    /// 响应阶段断点处理器 (异步)
    /// - 输入: (requestId, URLRequest, HTTPURLResponse, Data?)
    /// - 返回: 修改后的响应快照，或 nil 表示不修改
    public static var breakpointCheckResponse: ((String, URLRequest, HTTPURLResponse, Data?) async -> BreakpointResponseSnapshot?)?

    /// 检查是否有响应阶段断点（同步方法，用于预判断）
    public static var breakpointHasResponseRule: ((URLRequest) -> Bool)?

    // MARK: - Page Timing Callbacks

    /// 页面耗时事件回调
    public static var onPageTimingEvent: ((PageTimingEvent) -> Void)?

    /// 上报页面耗时事件
    public static func reportPageTiming(_ event: PageTimingEvent) {
        onPageTimingEvent?(event)
    }

    // MARK: - Lifecycle

    /// 清理所有回调（在 DebugProbe.stop() 时调用）
    public static func clearAll() {
        // 事件回调
        onHTTPEvent = nil
        onLogEvent = nil
        onWebSocketEvent = nil
        onDebugEvent = nil
        onPageTimingEvent = nil

        // Mock 处理器
        mockHTTPRequest = nil
        mockWSOutgoingFrame = nil
        mockWSIncomingFrame = nil

        // Chaos 处理器
        chaosEvaluate = nil
        chaosEvaluateResponse = nil

        // Breakpoint 处理器
        breakpointCheckRequest = nil
        breakpointCheckResponse = nil
        breakpointHasResponseRule = nil
    }
}
