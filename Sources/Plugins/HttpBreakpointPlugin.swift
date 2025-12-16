//
//  HttpBreakpointPlugin.swift
//  DebugProbe
//
//  Created by Sun on 2025/12/15.
//  Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Http Breakpoint Plugin

/// 断点调试插件
public final class HttpBreakpointPlugin: DebugProbePlugin, @unchecked Sendable {
    public let pluginId: String = BuiltinPluginId.breakpoint
    public let displayName: String = "Breakpoint"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "HTTP 请求断点调试"
    public let dependencies: [String] = [BuiltinPluginId.http]

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.breakpoint.state")

    private var breakpointEngine: BreakpointEngine { BreakpointEngine.shared }

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context
        if let enabled: Bool = context.getConfiguration(for: "breakpoint.enabled") {
            isEnabled = enabled
        }
        state = .stopped
        context.logInfo("HttpBreakpointPlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }
        stateQueue.sync { state = .starting }

        // 注册 EventCallbacks 处理器
        registerEventCallbacks()

        stateQueue.sync { state = .running }
        context?.logInfo("HttpBreakpointPlugin started")
    }

    /// 注册 EventCallbacks 处理器
    /// 这些处理器将被 CaptureURLProtocol 调用来执行断点检查
    private func registerEventCallbacks() {
        // 请求阶段断点检查
        EventCallbacks.breakpointCheckRequest = { [weak self] requestId, request in
            guard let self, isEnabled else { return .proceed(request) }
            return await breakpointEngine.checkRequestBreakpoint(requestId: requestId, request: request)
        }

        // 响应阶段断点检查
        EventCallbacks.breakpointCheckResponse = { [weak self] requestId, request, response, body in
            guard let self, isEnabled else { return nil }
            return await breakpointEngine.checkResponseBreakpoint(
                requestId: requestId,
                request: request,
                response: response,
                body: body
            )
        }

        // 检查是否有响应断点规则（同步方法，用于预判断）
        EventCallbacks.breakpointHasResponseRule = { [weak self] request in
            guard let self, isEnabled else { return false }
            return breakpointEngine.hasResponseBreakpoint(for: request)
        }
    }

    /// 注销 EventCallbacks 处理器
    private func unregisterEventCallbacks() {
        EventCallbacks.breakpointCheckRequest = nil
        EventCallbacks.breakpointCheckResponse = nil
        EventCallbacks.breakpointHasResponseRule = nil
    }

    public func pause() async {
        guard state == .running else { return }
        isEnabled = false
        breakpointEngine.updateRules([])
        stateQueue.sync { state = .paused }
        context?.logInfo("HttpBreakpointPlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        isEnabled = true
        if let rules: [BreakpointRule] = context?.getConfiguration(for: "breakpoint.rules") {
            breakpointEngine.updateRules(rules)
        }
        stateQueue.sync { state = .running }
        context?.logInfo("HttpBreakpointPlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }
        stateQueue.sync { state = .stopping }
        breakpointEngine.updateRules([])

        // 注销 EventCallbacks 处理器
        unregisterEventCallbacks()

        stateQueue.sync { state = .stopped }
        context?.logInfo("HttpBreakpointPlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        switch command.commandType {
        case "enable":
            isEnabled = true
            context?.setConfiguration(true, for: "breakpoint.enabled")
            if state == .paused { await resume() }
            sendSuccessResponse(for: command)

        case "disable":
            isEnabled = false
            context?.setConfiguration(false, for: "breakpoint.enabled")
            if state == .running { await pause() }
            sendSuccessResponse(for: command)

        case "update_rules":
            await handleUpdateRules(command)

        case "resume_breakpoint":
            await handleResumeBreakpoint(command)

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
            let rules = try decoder.decode([BreakpointRule].self, from: payload)
            breakpointEngine.updateRules(rules)
            context?.setConfiguration(rules, for: "breakpoint.rules")
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid rules format")
        }
    }

    private func handleResumeBreakpoint(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let resume = try JSONDecoder().decode(BreakpointResumePayload.self, from: payload)
            let action = mapBreakpointAction(resume)
            await breakpointEngine.resumeBreakpoint(requestId: resume.requestId, action: action)
            sendSuccessResponse(for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid resume payload")
        }
    }

    private func mapBreakpointAction(_ payload: BreakpointResumePayload) -> BreakpointAction {
        switch payload.action.lowercased() {
        case "continue", "resume":
            return .resume
        case "abort":
            return .abort
        case "modify":
            if let mod = payload.modifiedRequest {
                let request = BreakpointRequestSnapshot(
                    method: mod.method ?? "GET",
                    url: mod.url ?? "",
                    headers: mod.headers ?? [:],
                    body: mod.bodyData
                )
                return .modify(BreakpointModification(request: request, response: nil))
            }
            if let mod = payload.modifiedResponse {
                let response = BreakpointResponseSnapshot(
                    statusCode: mod.statusCode ?? 200,
                    headers: mod.headers ?? [:],
                    body: mod.bodyData
                )
                return .modify(BreakpointModification(request: nil, response: response))
            }
            return .resume
        default:
            return .resume
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
