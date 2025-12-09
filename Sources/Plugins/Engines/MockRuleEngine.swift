// MockRuleEngine.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//
// Mock 规则引擎 - 提供规则存储、匹配和应用逻辑
//
// *** 架构说明 ***
// 此引擎作为 MockPlugin 的内部实现使用，不直接对外暴露
// 插件架构：
//   1. MockPlugin 在 start() 时注册 EventCallbacks 处理器
//   2. CaptureURLProtocol 通过 EventCallbacks 调用 Mock 处理
//   3. 处理器内部委托给 MockRuleEngine.shared 执行实际逻辑
//
// 事件流：
//   CaptureURLProtocol
//     → EventCallbacks.mockHTTPRequest()
//     → MockPlugin handler
//     → MockRuleEngine.shared.processHTTPRequest()
//

import Foundation

/// Mock 规则引擎，负责管理和执行 Mock 规则
final class MockRuleEngine {
    // MARK: - Singleton

    static let shared = MockRuleEngine()

    // MARK: - State

    private var rules: [MockRule] = []
    private let rulesLock = NSLock()

    // MARK: - Callbacks

    var onRulesUpdated: (([MockRule]) -> Void)?

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Rule Management

    /// 更新所有规则
    func updateRules(_ newRules: [MockRule]) {
        rulesLock.lock()
        rules = newRules.sorted { $0.priority > $1.priority }
        rulesLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onRulesUpdated?(newRules)
        }
    }

    /// 添加单条规则
    func addRule(_ rule: MockRule) {
        rulesLock.lock()
        rules.append(rule)
        rules.sort { $0.priority > $1.priority }
        rulesLock.unlock()
    }

    /// 移除规则
    func removeRule(id: String) {
        rulesLock.lock()
        rules.removeAll { $0.id == id }
        rulesLock.unlock()
    }

    /// 清空所有规则
    func clearRules() {
        rulesLock.lock()
        rules.removeAll()
        rulesLock.unlock()
    }

    /// 获取所有规则
    func getAllRules() -> [MockRule] {
        rulesLock.lock()
        defer { rulesLock.unlock() }
        return rules
    }

    // MARK: - HTTP Request Processing

    /// 处理 HTTP 请求，返回修改后的请求和可能的 Mock 响应
    func processHTTPRequest(
        _ request: URLRequest
    ) -> (modifiedRequest: URLRequest, mockResponse: HTTPEvent.Response?, matchedRuleId: String?) {
        rulesLock.lock()
        let currentRules = rules
            .filter { $0.enabled && ($0.targetType == .httpRequest || $0.targetType == .httpResponse) }
        rulesLock.unlock()

        var modifiedRequest = request
        var mockResponse: HTTPEvent.Response?
        var matchedRuleId: String?

        for rule in currentRules {
            // 构建临时请求对象用于匹配
            let tempRequest = HTTPEvent.Request(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody
            )

            guard rule.condition.matches(request: tempRequest) else { continue }

            matchedRuleId = rule.id

            switch rule.targetType {
            case .httpRequest:
                // 修改请求头
                if let headerMods = rule.action.modifyRequestHeaders {
                    for (key, value) in headerMods {
                        modifiedRequest.setValue(value, forHTTPHeaderField: key)
                    }
                }

                // 修改请求体
                if let bodyMod = rule.action.modifyRequestBody {
                    modifiedRequest.httpBody = bodyMod
                }

            case .httpResponse:
                // 直接返回 Mock 响应
                if let statusCode = rule.action.mockResponseStatusCode {
                    mockResponse = HTTPEvent.Response(
                        statusCode: statusCode,
                        headers: rule.action.mockResponseHeaders ?? [:],
                        body: rule.action.mockResponseBody,
                        duration: 0
                    )
                    break // Mock 响应后不再处理其他规则
                }

            default:
                break
            }
        }

        return (modifiedRequest, mockResponse, matchedRuleId)
    }

    // MARK: - WebSocket Processing

    /// 处理 WebSocket 发送帧
    func processWSOutgoingFrame(
        _ payload: Data,
        sessionId: String,
        sessionURL: String
    ) -> (modifiedPayload: Data, isMocked: Bool, matchedRuleId: String?) {
        rulesLock.lock()
        let currentRules = rules.filter { $0.enabled && $0.targetType == .wsOutgoing }
        rulesLock.unlock()

        var modifiedPayload = payload
        var isMocked = false
        var matchedRuleId: String?

        for rule in currentRules {
            let tempFrame = WSEvent.Frame(
                sessionId: sessionId,
                sessionUrl: sessionURL,
                direction: .send,
                opcode: .text,
                payload: payload
            )

            guard rule.condition.matches(frame: tempFrame, sessionURL: sessionURL) else { continue }

            matchedRuleId = rule.id

            if let mockPayload = rule.action.mockWebSocketPayload {
                modifiedPayload = mockPayload
                isMocked = true
                break
            }
        }

        return (modifiedPayload, isMocked, matchedRuleId)
    }

    /// 处理 WebSocket 接收帧
    func processWSIncomingFrame(
        _ payload: Data,
        sessionId: String,
        sessionURL: String
    ) -> (modifiedPayload: Data, isMocked: Bool, matchedRuleId: String?) {
        rulesLock.lock()
        let currentRules = rules.filter { $0.enabled && $0.targetType == .wsIncoming }
        rulesLock.unlock()

        var modifiedPayload = payload
        var isMocked = false
        var matchedRuleId: String?

        for rule in currentRules {
            let tempFrame = WSEvent.Frame(
                sessionId: sessionId,
                sessionUrl: sessionURL,
                direction: .receive,
                opcode: .text,
                payload: payload
            )

            guard rule.condition.matches(frame: tempFrame, sessionURL: sessionURL) else { continue }

            matchedRuleId = rule.id

            if let mockPayload = rule.action.mockWebSocketPayload {
                modifiedPayload = mockPayload
                isMocked = true
                break
            }
        }

        return (modifiedPayload, isMocked, matchedRuleId)
    }
}
