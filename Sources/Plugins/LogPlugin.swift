// LogPlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

#if canImport(CocoaLumberjack)
    import CocoaLumberjack
#endif

// MARK: - Log Plugin

/// 日志监控插件
/// 负责捕获应用日志（CocoaLumberjack、os_log 等）并上报
public final class LogPlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.log
    public let displayName: String = "Log"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "应用日志捕获与上报"
    public let dependencies: [String] = []

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Configuration

    /// 最低日志级别
    public var minimumLogLevel: LogEvent.Level = .debug

    /// 是否包含系统日志
    public var includeSystemLogs: Bool = false

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.log.state")

    #if canImport(CocoaLumberjack)
        private var ddLogger: DDLogBridge?
    #endif

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "log.enabled") {
            isEnabled = enabled
        }
        if let level: String = context.getConfiguration(for: "log.minimumLevel") {
            minimumLogLevel = LogEvent.Level(rawValue: level) ?? .debug
        }

        state = .stopped
        context.logInfo("LogPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 注册事件回调（DDLogBridge 通过 EventCallbacks 上报事件）
        registerEventCallback()

        // 启动日志捕获
        startLogCapture()

        stateQueue.sync { state = .running }
        context?.logInfo("LogPlugin started with minimum level: \(minimumLogLevel)")
    }

    public func pause() async {
        guard state == .running else { return }

        isEnabled = false
        stopLogCapture()
        stateQueue.sync { state = .paused }
        context?.logInfo("LogPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }

        isEnabled = true
        startLogCapture()
        stateQueue.sync { state = .running }
        context?.logInfo("LogPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }

        stopLogCapture()
        unregisterEventCallback()

        stateQueue.sync { state = .stopped }
        context?.logInfo("LogPlugin stopped")
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

        case "set_minimum_level":
            await handleSetMinimumLevel(command)

        case "get_status":
            await handleGetStatus(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    public func onConfigurationChanged(key: String) {
        guard key.hasPrefix("log.") else { return }

        switch key {
        case "log.enabled":
            if let enabled: Bool = context?.getConfiguration(for: key) {
                Task {
                    if enabled {
                        await enable()
                    } else {
                        await disable()
                    }
                }
            }
        case "log.minimumLevel":
            if let level: String = context?.getConfiguration(for: key) {
                minimumLogLevel = LogEvent.Level(rawValue: level) ?? .debug
            }
        default:
            break
        }
    }

    // MARK: - Public Methods

    /// 启用日志捕获
    public func enable() async {
        isEnabled = true
        context?.setConfiguration(true, for: "log.enabled")

        if state == .paused {
            await resume()
        } else if state == .stopped {
            try? await start()
        }
    }

    /// 禁用日志捕获
    public func disable() async {
        isEnabled = false
        context?.setConfiguration(false, for: "log.enabled")

        if state == .running {
            await pause()
        }
    }

    /// 手动记录日志
    public func log(
        level: LogEvent.Level,
        message: String,
        subsystem: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        traceId: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard isEnabled, level >= minimumLogLevel else { return }

        let event = LogEvent(
            source: .osLog,
            level: level,
            subsystem: subsystem,
            category: category,
            thread: Thread.isMainThread ? "main" : Thread.current.description,
            file: (file as NSString).lastPathComponent,
            function: function,
            line: line,
            message: message,
            tags: tags,
            traceId: traceId
        )

        handleLogEvent(event)
    }

    // MARK: - Private Methods

    private func startLogCapture() {
        #if canImport(CocoaLumberjack)
            if ddLogger == nil {
                ddLogger = DDLogBridge()
                DDLog.add(ddLogger!)
            }
        #endif
    }

    private func stopLogCapture() {
        #if canImport(CocoaLumberjack)
            if let logger = ddLogger {
                DDLog.remove(logger)
                ddLogger = nil
            }
        #endif
    }

    // MARK: - Event Callback Registration

    /// 注册事件回调
    /// DDLogBridge 通过 EventCallbacks.reportLog() 上报事件
    /// LogPlugin 接收后通过 EventCallbacks.reportEvent() 发送到 BridgeClient
    private func registerEventCallback() {
        EventCallbacks.onLogEvent = { [weak self] logEvent in
            self?.handleLogEvent(logEvent)
        }
    }

    /// 注销事件回调
    private func unregisterEventCallback() {
        EventCallbacks.onLogEvent = nil
    }

    /// 处理日志事件
    /// - Parameter logEvent: 从 DDLogBridge 捕获的日志事件
    private func handleLogEvent(_ logEvent: LogEvent) {
        guard isEnabled else { return }
        guard logEvent.level >= minimumLogLevel else { return }

        // 1. 通过统一回调发送到 BridgeClient
        EventCallbacks.reportEvent(.log(logEvent))

        // 2. 上报插件事件（用于插件系统内部状态管理）
        do {
            let event = try PluginEvent(
                pluginId: pluginId,
                eventType: "log_event",
                eventId: logEvent.id,
                timestamp: logEvent.timestamp,
                encodable: logEvent
            )
            context?.sendEvent(event)
        } catch {
            // 避免递归日志
            print("[LogPlugin] Failed to encode log event: \(error)")
        }
    }

    // MARK: - Command Handlers

    private func handleSetConfig(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let config = try JSONDecoder().decode(LogPluginConfig.self, from: payload)

            if let level = config.minimumLevel {
                minimumLogLevel = LogEvent.Level(rawValue: level) ?? .debug
                context?.setConfiguration(level, for: "log.minimumLevel")
            }

            if let includeSystem = config.includeSystemLogs {
                includeSystemLogs = includeSystem
            }

            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid config format: \(error)")
        }
    }

    private func handleSetMinimumLevel(_ command: PluginCommand) async {
        guard
            let payload = command.payload,
            let levelStr = String(data: payload, encoding: .utf8),
            let level = LogEvent.Level(rawValue: levelStr.trimmingCharacters(in: .init(charactersIn: "\"")))
        else {
            sendErrorResponse(for: command, message: "Invalid level")
            return
        }

        minimumLogLevel = level
        context?.setConfiguration(level.rawValue, for: "log.minimumLevel")
        sendSuccessResponse(for: command)
    }

    private func handleGetStatus(_ command: PluginCommand) async {
        let status = LogPluginStatus(
            isEnabled: isEnabled,
            minimumLevel: minimumLogLevel.rawValue,
            includeSystemLogs: includeSystemLogs,
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

/// 日志插件配置
struct LogPluginConfig: Codable {
    let minimumLevel: String?
    let includeSystemLogs: Bool?
}

/// 日志插件状态
struct LogPluginStatus: Codable {
    let isEnabled: Bool
    let minimumLevel: String
    let includeSystemLogs: Bool
    let state: String
}

// MARK: - LogEvent.Level Comparable

extension LogEvent.Level: Comparable {
    public static func < (lhs: LogEvent.Level, rhs: LogEvent.Level) -> Bool {
        let order: [LogEvent.Level] = [.verbose, .debug, .info, .warning, .error]
        guard
            let lhsIndex = order.firstIndex(of: lhs),
            let rhsIndex = order.firstIndex(of: rhs)
        else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}
