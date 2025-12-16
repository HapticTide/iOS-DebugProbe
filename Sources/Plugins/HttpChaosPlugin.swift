//
//  HttpChaosPlugin.swift
//  DebugProbe
//
//  Created by Sun on 2025/12/15.
//  Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Http Chaos Plugin

/// 故障注入插件
public final class HttpChaosPlugin: DebugProbePlugin, @unchecked Sendable {
    public let pluginId: String = BuiltinPluginId.chaos
    public let displayName: String = "Chaos"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "网络故障注入与混沌测试"
    public let dependencies: [String] = [BuiltinPluginId.http]

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.chaos.state")

    private var chaosEngine: ChaosEngine { ChaosEngine.shared }

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context
        if let enabled: Bool = context.getConfiguration(for: "chaos.enabled") {
            isEnabled = enabled
        }
        state = .stopped
        context.logInfo("HttpChaosPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }
        stateQueue.sync { state = .starting }

        // 注册 EventCallbacks 处理器
        registerEventCallbacks()

        stateQueue.sync { state = .running }
        context?.logInfo("HttpChaosPlugin started")
    }

    /// 注册 EventCallbacks 处理器
    /// 这些处理器将被 CaptureURLProtocol 调用来执行故障注入
    private func registerEventCallbacks() {
        // 请求阶段故障评估
        EventCallbacks.chaosEvaluate = { [weak self] request in
            guard let self, isEnabled else { return .none }
            return chaosEngine.evaluate(request: request)
        }

        // 响应阶段故障评估
        EventCallbacks.chaosEvaluateResponse = { [weak self] request, response, data in
            guard let self, isEnabled else { return .none }
            return chaosEngine.evaluateResponse(request: request, response: response, data: data)
        }
    }

    /// 注销 EventCallbacks 处理器
    private func unregisterEventCallbacks() {
        EventCallbacks.chaosEvaluate = nil
        EventCallbacks.chaosEvaluateResponse = nil
    }

    public func pause() async {
        guard state == .running else { return }
        isEnabled = false
        chaosEngine.updateRules([])
        stateQueue.sync { state = .paused }
        context?.logInfo("HttpChaosPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        isEnabled = true
        if let rules: [ChaosRule] = context?.getConfiguration(for: "chaos.rules") {
            chaosEngine.updateRules(rules)
        }
        stateQueue.sync { state = .running }
        context?.logInfo("HttpChaosPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }
        stateQueue.sync { state = .stopping }
        chaosEngine.updateRules([])

        // 注销 EventCallbacks 处理器
        unregisterEventCallbacks()

        stateQueue.sync { state = .stopped }
        context?.logInfo("HttpChaosPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            isEnabled = true
            context?.setConfiguration(true, for: "chaos.enabled")
            if state == .paused { await resume() }
            sendSuccessResponse(for: command)

        case "disable":
            isEnabled = false
            context?.setConfiguration(false, for: "chaos.enabled")
            if state == .running { await pause() }
            sendSuccessResponse(for: command)

        case "update_rules":
            await handleUpdateRules(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type")
        }
    }

    private func handleUpdateRules(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let rules = try decoder.decode([ChaosRule].self, from: payload)
            chaosEngine.updateRules(rules)
            context?.setConfiguration(rules, for: "chaos.rules")
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rules format")
        }
    }

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(pluginId: pluginId, commandId: command.commandId, success: true)
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
