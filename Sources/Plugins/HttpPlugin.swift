// HttpPlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - HTTP Plugin

/// HTTP 请求监控插件
/// 负责 HTTP/HTTPS 请求的拦截、记录和上报
public final class HttpPlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.http
    public let displayName: String = "HTTP"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "HTTP/HTTPS 请求监控"
    public let dependencies: [String] = []

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Configuration

    /// 网络捕获模式
    public var captureMode: NetworkCaptureMode = .automatic

    /// 是否仅捕获 HTTP（不含 WebSocket）
    public var httpOnly: Bool = false

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.network.state")

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "http.enabled") {
            isEnabled = enabled
        }
        if let mode: String = context.getConfiguration(for: "http.captureMode") {
            captureMode = mode == "manual" ? .manual : .automatic
        }

        state = .stopped
        context.logInfo("HttpPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 确定捕获范围
        let scope: NetworkCaptureScope = httpOnly ? .http : .all

        // 注册事件回调（CaptureURLProtocol 通过 EventCallbacks 上报事件）
        registerEventCallback()

        // 启动网络捕获
        NetworkInstrumentation.shared.start(mode: captureMode, scope: scope)

        stateQueue.sync { state = .running }
        context?.logInfo("HttpPlugin started with mode: \(captureMode), scope: \(scope)")
    }

    public func pause() async {
        guard state == .running else { return }

        NetworkInstrumentation.shared.stop()
        stateQueue.sync { state = .paused }
        context?.logInfo("HttpPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }

        let scope: NetworkCaptureScope = httpOnly ? .http : .all
        NetworkInstrumentation.shared.start(mode: captureMode, scope: scope)

        stateQueue.sync { state = .running }
        context?.logInfo("HttpPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }

        NetworkInstrumentation.shared.stop()
        unregisterEventCallback()

        stateQueue.sync { state = .stopped }
        context?.logInfo("HttpPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            await enable()
            sendSuccessResponse(for: command)

        case "disable":
            await disable()
            sendSuccessResponse(for: command)

        case "set_config":
            await handleSetConfig(command)

        case "get_status":
            await handleGetStatus(command)

        case "replay":
            await handleReplay(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    public func onConfigurationChanged(key: String) {
        guard key.hasPrefix("network.") else { return }

        switch key {
        case "network.enabled":
            if let enabled: Bool = context?.getConfiguration(for: key) {
                Task {
                    if enabled {
                        await enable()
                    } else {
                        await disable()
                    }
                }
            }
        case "network.captureMode":
            if let mode: String = context?.getConfiguration(for: key) {
                captureMode = mode == "manual" ? .manual : .automatic
            }
        default:
            break
        }
    }

    // MARK: - Public Methods

    /// 启用网络捕获
    public func enable() async {
        isEnabled = true
        context?.setConfiguration(true, for: "network.enabled")

        if state == .paused {
            await resume()
        } else if state == .stopped {
            try? await start()
        }
    }

    /// 禁用网络捕获
    public func disable() async {
        isEnabled = false
        context?.setConfiguration(false, for: "network.enabled")

        if state == .running {
            await pause()
        }
    }

    // MARK: - Event Callback Registration

    /// 注册事件回调
    /// CaptureURLProtocol 通过 EventCallbacks.reportHTTP() 上报事件
    /// HttpPlugin 接收后通过 EventCallbacks.reportEvent() 发送到 BridgeClient
    private func registerEventCallback() {
        EventCallbacks.onHTTPEvent = { [weak self] httpEvent in
            self?.handleHTTPEvent(httpEvent)
        }
    }

    /// 注销事件回调
    private func unregisterEventCallback() {
        EventCallbacks.onHTTPEvent = nil
    }

    /// 处理 HTTP 事件
    /// - Parameter httpEvent: 从 CaptureURLProtocol 捕获的 HTTP 事件
    private func handleHTTPEvent(_ httpEvent: HTTPEvent) {
        guard isEnabled else { return }

        // 1. 通过统一回调发送到 BridgeClient
        EventCallbacks.reportEvent(.http(httpEvent))

        // 2. 上报插件事件（用于插件系统内部状态管理）
        do {
            let event = try PluginEvent(
                pluginId: pluginId,
                eventType: "http_event",
                eventId: httpEvent.request.id,
                timestamp: httpEvent.request.startTime,
                encodable: httpEvent
            )
            context?.sendEvent(event)
        } catch {
            context?.logError("Failed to encode HTTP event: \(error)")
        }
    }

    // MARK: - Command Handlers

    private func handleSetConfig(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let config = try JSONDecoder().decode(HttpPluginConfig.self, from: payload)

            if let mode = config.captureMode {
                captureMode = mode == "manual" ? .manual : .automatic
                context?.setConfiguration(mode, for: "http.captureMode")
            }

            if let httpOnly = config.httpOnly {
                self.httpOnly = httpOnly
            }

            // 如果正在运行，重启以应用新配置
            if state == .running {
                await stop()
                try await start()
            }

            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid config format: \(error)")
        }
    }

    private func handleGetStatus(_ command: PluginCommand) async {
        let status = HttpPluginStatus(
            isEnabled: isEnabled,
            captureMode: captureMode == .automatic ? "automatic" : "manual",
            httpOnly: httpOnly,
            state: state.rawValue
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

    /// 处理重放请求命令
    private func handleReplay(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let replayData = try JSONDecoder().decode(ReplayPayload.self, from: payload)

            guard let url = URL(string: replayData.url) else {
                sendErrorResponse(for: command, message: "Invalid URL: \(replayData.url)")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = replayData.method

            // 设置请求头
            for (key, value) in replayData.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            // 添加重放标记头，让捕获系统识别这是重放请求
            request.setValue("true", forHTTPHeaderField: "X-DebugProbe-Replay")

            // 设置请求体
            request.httpBody = replayData.body

            context?.logInfo("Executing replay request: \(replayData.method) \(replayData.url)")
            // 使用 default configuration 创建 session，确保请求被 CaptureURLProtocol 捕获
            // 注意：不能使用 URLSession.shared，因为它的 configuration 可能不包含 CaptureURLProtocol
            let session = URLSession(configuration: .default)
            session.dataTask(with: request) { [weak self] _, response, error in
                guard let self else { return }

                if let error {
                    self.context?.logError("Replay request failed: \(error.localizedDescription)")
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    self.context?.logInfo("Replay request completed: \(httpResponse.statusCode)")
                }
            }.resume()

            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Failed to decode replay payload: \(error)")
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

// MARK: - Configuration DTOs

/// HTTP 插件配置
struct HttpPluginConfig: Codable {
    let captureMode: String?
    let httpOnly: Bool?
}

/// HTTP 插件状态
struct HttpPluginStatus: Codable {
    let isEnabled: Bool
    let captureMode: String
    let httpOnly: Bool
    let state: String
}

/// 重放请求负载
struct ReplayPayload: Codable {
    let url: String
    let method: String
    let headers: [String: String]
    let body: Data?
}
