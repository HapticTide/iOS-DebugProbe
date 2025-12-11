// WebSocketPlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - WebSocket Plugin

/// WebSocket 监控插件
/// 负责 WebSocket 连接和消息的监控
public final class WebSocketPlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.webSocket
    public let displayName: String = "WebSocket"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "WebSocket 连接与消息监控"
    public let dependencies: [String] = []

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.websocket.state")

    /// sessionId -> URL 映射缓存
    private var sessionURLCache: [String: String] = [:]
    private let cacheLock = NSLock()

    /// 在锁保护下执行闭包
    private func withCacheLock<T>(_ body: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "websocket.enabled") {
            isEnabled = enabled
        }

        state = .stopped
        context.logInfo("WebSocketPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 注册事件回调（WebSocketInstrumentation 通过 EventCallbacks 上报事件）
        registerEventCallback()

        // 启动 WebSocket 监控
        WebSocketInstrumentation.shared.start()

        stateQueue.sync { state = .running }
        context?.logInfo("WebSocketPlugin started")
    }

    public func pause() async {
        guard state == .running else { return }

        WebSocketInstrumentation.shared.stop()
        stateQueue.sync { state = .paused }
        context?.logInfo("WebSocketPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }

        WebSocketInstrumentation.shared.start()
        stateQueue.sync { state = .running }
        context?.logInfo("WebSocketPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }

        WebSocketInstrumentation.shared.stop()
        unregisterEventCallback()

        withCacheLock { sessionURLCache.removeAll() }

        stateQueue.sync { state = .stopped }
        context?.logInfo("WebSocketPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            await enable()
            sendSuccessResponse(for: command)

        case "disable":
            await disable()
            sendSuccessResponse(for: command)

        case "get_status":
            await handleGetStatus(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    // MARK: - Public Methods

    /// 启用 WebSocket 监控
    public func enable() async {
        isEnabled = true
        context?.setConfiguration(true, for: "websocket.enabled")

        if state == .paused {
            await resume()
        } else if state == .stopped {
            try? await start()
        }
    }

    /// 禁用 WebSocket 监控
    public func disable() async {
        isEnabled = false
        context?.setConfiguration(false, for: "websocket.enabled")

        if state == .running {
            await pause()
        }
    }

    // MARK: - Hook Methods (供宿主 App 调用)

    /// 获取 WebSocket 调试钩子
    public func getHooks() -> (
        onSessionCreated: (String, String, [String: String]) -> Void,
        onSessionClosed: (String, Int?, String?) -> Void,
        onMessageSent: (String, Data) -> Void,
        onMessageReceived: (String, Data) -> Void
    ) {
        let onSessionCreated: (String, String, [String: String]) -> Void = { [weak self] sessionId, url, headers in
            self?.handleSessionCreated(sessionId: sessionId, url: url, headers: headers)
        }

        let onSessionClosed: (String, Int?, String?) -> Void = { [weak self] sessionId, closeCode, reason in
            self?.handleSessionClosed(sessionId: sessionId, closeCode: closeCode, reason: reason)
        }

        let onMessageSent: (String, Data) -> Void = { [weak self] sessionId, data in
            self?.handleMessageSent(sessionId: sessionId, data: data)
        }

        let onMessageReceived: (String, Data) -> Void = { [weak self] sessionId, data in
            self?.handleMessageReceived(sessionId: sessionId, data: data)
        }

        return (onSessionCreated, onSessionClosed, onMessageSent, onMessageReceived)
    }

    // MARK: - Private Methods

    // MARK: - Event Callback Registration

    /// 注册事件回调
    /// WebSocketInstrumentation 通过 EventCallbacks.reportWebSocket() 上报事件
    /// WebSocketPlugin 接收后通过 EventCallbacks.reportEvent() 发送到 BridgeClient
    private func registerEventCallback() {
        EventCallbacks.onWebSocketEvent = { [weak self] wsEvent in
            self?.handleWebSocketEvent(wsEvent)
        }
    }

    /// 注销事件回调
    private func unregisterEventCallback() {
        EventCallbacks.onWebSocketEvent = nil
    }

    /// 处理 WebSocket 事件
    /// - Parameter wsEvent: 从 WebSocketInstrumentation 或 InstrumentedWebSocketClient 捕获的 WebSocket 事件
    ///
    /// 事件来源：
    /// - WebSocketInstrumentation: 自动捕获的连接级别事件（连接创建/关闭）
    /// - InstrumentedWebSocketClient: 完整的消息级别事件（帧发送/接收）
    ///
    /// 注意：不要在此处再调用 reportWSEvent，否则会导致重复发送。
    /// EventCallbacks.reportEvent 已经会将事件发送到 BridgeClient。
    private func handleWebSocketEvent(_ wsEvent: WSEvent) {
        guard isEnabled else { return }

        // 更新会话缓存
        switch wsEvent.kind {
        case let .sessionCreated(session):
            cacheLock.lock()
            sessionURLCache[session.id] = session.url
            cacheLock.unlock()
        case .sessionClosed, .frame:
            break
        }

        // 通过统一回调发送到 BridgeClient（只发送一次）
        EventCallbacks.reportEvent(.webSocket(wsEvent))
    }

    private func handleSessionCreated(sessionId: String, url: String, headers: [String: String]) {
        guard isEnabled else { return }

        // 缓存 sessionId -> URL 映射
        cacheLock.lock()
        sessionURLCache[sessionId] = url
        cacheLock.unlock()

        let session = WSEvent.Session(
            id: sessionId,
            url: url,
            requestHeaders: headers,
            subprotocols: []
        )
        let event = WSEvent(kind: .sessionCreated(session))
        EventCallbacks.reportEvent(.webSocket(event))
    }

    private func handleSessionClosed(sessionId: String, closeCode: Int?, reason: String?) {
        guard isEnabled else { return }

        cacheLock.lock()
        let cachedURL = sessionURLCache[sessionId] ?? ""
        cacheLock.unlock()

        var session = WSEvent.Session(id: sessionId, url: cachedURL, requestHeaders: [:], subprotocols: [])
        session.disconnectTime = Date()
        session.closeCode = closeCode
        session.closeReason = reason

        let event = WSEvent(kind: .sessionClosed(session))
        EventCallbacks.reportEvent(.webSocket(event))
    }

    private func handleMessageSent(sessionId: String, data: Data) {
        guard isEnabled else { return }

        cacheLock.lock()
        let cachedURL = sessionURLCache[sessionId]
        cacheLock.unlock()

        let frame = WSEvent.Frame(
            sessionId: sessionId,
            sessionUrl: cachedURL,
            direction: .send,
            opcode: .binary,
            payload: data,
            isMocked: false,
            mockRuleId: nil
        )
        let event = WSEvent(kind: .frame(frame))
        EventCallbacks.reportEvent(.webSocket(event))
    }

    private func handleMessageReceived(sessionId: String, data: Data) {
        guard isEnabled else { return }

        cacheLock.lock()
        let cachedURL = sessionURLCache[sessionId]
        cacheLock.unlock()

        let frame = WSEvent.Frame(
            sessionId: sessionId,
            sessionUrl: cachedURL,
            direction: .receive,
            opcode: .binary,
            payload: data,
            isMocked: false,
            mockRuleId: nil
        )
        let event = WSEvent(kind: .frame(frame))
        EventCallbacks.reportEvent(.webSocket(event))
    }

    /// 上报 WebSocket 事件
    private func reportWSEvent(_ wsEvent: WSEvent) {
        guard isEnabled else { return }

        do {
            let event = try PluginEvent(
                pluginId: pluginId,
                eventType: "ws_event",
                eventId: wsEvent.eventId,
                timestamp: wsEvent.timestamp,
                encodable: wsEvent
            )
            context?.sendEvent(event)
        } catch {
            context?.logError("Failed to encode WebSocket event: \(error)")
        }
    }

    // MARK: - Command Handlers

    private func handleGetStatus(_ command: PluginCommand) async {
        let activeSessionCount = withCacheLock { sessionURLCache.count }

        let status = WebSocketPluginStatus(
            isEnabled: isEnabled,
            state: state.rawValue,
            activeSessionCount: activeSessionCount
        )

        do {
            let payload = try JSONEncoder().encode(status)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: payload
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode status")
        }
    }

    // MARK: - Response Helpers

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: true
        )
        context?.sendCommandResponse(response)
    }

    private func sendErrorResponse(for command: PluginCommand, message: String) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: false,
            errorMessage: message
        )
        context?.sendCommandResponse(response)
    }
}

// MARK: - Status DTO

/// WebSocket 插件状态
struct WebSocketPluginStatus: Codable {
    let isEnabled: Bool
    let state: String
    let activeSessionCount: Int
}
