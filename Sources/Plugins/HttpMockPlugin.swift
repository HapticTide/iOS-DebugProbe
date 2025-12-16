// HttpMockPlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Http Mock Plugin

/// Mock 规则插件
/// 负责管理和应用 HTTP Mock 规则
public final class HttpMockPlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.mock
    public let displayName: String = "Mock"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "HTTP 请求 Mock 与规则管理"
    public let dependencies: [String] = [BuiltinPluginId.http]

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.mock.state")

    /// Mock 规则引擎引用
    private var ruleEngine: MockRuleEngine { MockRuleEngine.shared }

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "mock.enabled") {
            isEnabled = enabled
        }

        state = .stopped
        context.logInfo("HttpMockPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 注册 Mock 处理器
        registerMockHandlers()

        // 从配置恢复规则
        if let rules: [MockRule] = context?.getConfiguration(for: "mock.rules") {
            ruleEngine.updateRules(rules)
        }

        stateQueue.sync { state = .running }
        context?.logInfo("HttpMockPlugin started")
    }

    public func pause() async {
        guard state == .running else { return }

        isEnabled = false
        // 暂停时注销处理器（不清空规则，以便恢复时使用）
        unregisterMockHandlers()

        stateQueue.sync { state = .paused }
        context?.logInfo("HttpMockPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }

        isEnabled = true
        // 恢复时重新注册处理器
        registerMockHandlers()

        stateQueue.sync { state = .running }
        context?.logInfo("HttpMockPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }

        // 注销处理器并清空规则
        unregisterMockHandlers()
        ruleEngine.updateRules([])

        stateQueue.sync { state = .stopped }
        context?.logInfo("HttpMockPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            await enable()
            sendSuccessResponse(for: command)

        case "disable":
            await disable()
            sendSuccessResponse(for: command)

        case "update_rules":
            await handleUpdateRules(command)

        case "add_rule":
            await handleAddRule(command)

        case "remove_rule":
            await handleRemoveRule(command)

        case "get_rules":
            await handleGetRules(command)

        case "get_status":
            await handleGetStatus(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    // MARK: - Public Methods

    /// 启用 Mock
    public func enable() async {
        isEnabled = true
        context?.setConfiguration(true, for: "mock.enabled")

        if state == .paused {
            await resume()
        } else if state == .stopped {
            try? await start()
        }
    }

    /// 禁用 Mock
    public func disable() async {
        isEnabled = false
        context?.setConfiguration(false, for: "mock.enabled")

        if state == .running {
            await pause()
        }
    }

    /// 更新 Mock 规则
    public func updateRules(_ rules: [MockRule]) {
        guard isEnabled else { return }
        ruleEngine.updateRules(rules)
        context?.setConfiguration(rules, for: "mock.rules")
        context?.logInfo("Updated \(rules.count) mock rules")
    }

    /// 添加单条规则
    public func addRule(_ rule: MockRule) {
        var rules = ruleEngine.getAllRules()
        rules.append(rule)
        updateRules(rules)
    }

    /// 移除规则
    public func removeRule(id: String) {
        var rules = ruleEngine.getAllRules()
        rules.removeAll { $0.id == id }
        updateRules(rules)
    }

    /// 获取当前规则列表
    public func getRules() -> [MockRule] {
        ruleEngine.getAllRules()
    }

    // MARK: - Command Handlers

    private func handleUpdateRules(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rules = try decoder.decode([MockRule].self, from: payload)
            updateRules(rules)
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rules format: \(error)")
        }
    }

    private func handleAddRule(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rule = try decoder.decode(MockRule.self, from: payload)
            addRule(rule)
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rule format: \(error)")
        }
    }

    private func handleRemoveRule(_ command: PluginCommand) async {
        guard
            let payload = command.payload,
            let ruleId = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .init(charactersIn: "\""))
        else {
            sendErrorResponse(for: command, message: "Missing rule ID")
            return
        }

        removeRule(id: ruleId)
        sendSuccessResponse(for: command)
    }

    private func handleGetRules(_ command: PluginCommand) async {
        let rules = getRules()

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(rules)

            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: payload
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode rules")
        }
    }

    private func handleGetStatus(_ command: PluginCommand) async {
        let status = MockPluginStatus(
            isEnabled: isEnabled,
            state: state.rawValue,
            ruleCount: getRules().count
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

    // MARK: - Mock Handler Registration

    /// 注册 Mock 处理器
    /// CaptureURLProtocol 和 WebSocketInstrumentation 会通过 EventCallbacks 调用这些处理器
    private func registerMockHandlers() {
        // HTTP 请求 Mock
        EventCallbacks.mockHTTPRequest = { [weak self] request in
            guard let self, isEnabled else {
                return (request, nil, nil)
            }
            return ruleEngine.processHTTPRequest(request)
        }

        // WebSocket 发送帧 Mock
        EventCallbacks.mockWSOutgoingFrame = { [weak self] payload, sessionId, sessionURL in
            guard let self, isEnabled else {
                return (payload, false, nil)
            }
            return ruleEngine.processWSOutgoingFrame(payload, sessionId: sessionId, sessionURL: sessionURL)
        }

        // WebSocket 接收帧 Mock
        EventCallbacks.mockWSIncomingFrame = { [weak self] payload, sessionId, sessionURL in
            guard let self, isEnabled else {
                return (payload, false, nil)
            }
            return ruleEngine.processWSIncomingFrame(payload, sessionId: sessionId, sessionURL: sessionURL)
        }
    }

    /// 注销 Mock 处理器
    private func unregisterMockHandlers() {
        EventCallbacks.mockHTTPRequest = nil
        EventCallbacks.mockWSOutgoingFrame = nil
        EventCallbacks.mockWSIncomingFrame = nil
    }
}

// MARK: - Status DTO

/// Mock 插件状态
struct MockPluginStatus: Codable {
    let isEnabled: Bool
    let state: String
    let ruleCount: Int
}
