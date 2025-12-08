// DebugProbeSettings.swift
// DebugPlatform
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// DebugProbe 配置管理器
/// 支持多层配置优先级：运行时配置 > Info.plist > 默认值
public final class DebugProbeSettings {
    // MARK: - Singleton

    public static let shared = DebugProbeSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hubHost = "DebugProbe.hubHost"
        static let hubPort = "DebugProbe.hubPort"
        static let token = "DebugProbe.token"
        static let isEnabled = "DebugProbe.isEnabled"
        static let verboseLogging = "DebugProbe.verboseLogging"
    }

    // MARK: - Default Values

    /// 默认主机地址 (可配置)
    public static var defaultHost = "127.0.0.1"
    /// 默认端口 (可配置)
    public static var defaultPort = 8081

    private enum Defaults {
        static let token = "debug-token-2025"
    }

    // MARK: - Properties

    private let userDefaults: UserDefaults

    // MARK: - Lifecycle

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // 同步日志开关状态
        DebugLog.isEnabled = userDefaults.bool(forKey: Keys.verboseLogging)
    }

    // MARK: - Public API

    /// DebugHub 主机地址
    /// 优先级：UserDefaults > Info.plist > 默认值
    public var hubHost: String {
        get {
            // 1. 先检查运行时配置
            if let saved = userDefaults.string(forKey: Keys.hubHost), !saved.isEmpty {
                return saved
            }
            // 2. 再检查 Info.plist
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_HOST"] as? String, !plistValue.isEmpty {
                return plistValue
            }
            // 3. 使用默认值
            return Self.defaultHost
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hubHost)
            notifyConfigChanged()
        }
    }

    /// DebugHub 端口
    public var hubPort: Int {
        get {
            let saved = userDefaults.integer(forKey: Keys.hubPort)
            if saved > 0 {
                return saved
            }
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_PORT"] as? Int, plistValue > 0 {
                return plistValue
            }
            return Self.defaultPort
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hubPort)
            notifyConfigChanged()
        }
    }

    /// 认证 Token
    public var token: String {
        get {
            if let saved = userDefaults.string(forKey: Keys.token), !saved.isEmpty {
                return saved
            }
            if let plistValue = Bundle.main.infoDictionary?["DEBUGHUB_TOKEN"] as? String, !plistValue.isEmpty {
                return plistValue
            }
            return Defaults.token
        }
        set {
            userDefaults.set(newValue, forKey: Keys.token)
            notifyConfigChanged()
        }
    }

    /// 是否启用 DebugProbe（默认 true）
    public var isEnabled: Bool {
        get {
            // 如果从未设置过，默认为 true
            if userDefaults.object(forKey: Keys.isEnabled) == nil {
                return true
            }
            return userDefaults.bool(forKey: Keys.isEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isEnabled)
            notifyConfigChanged()
        }
    }

    /// 是否启用详细日志（默认 false）
    /// 启用后会输出调试级别的日志，功能启用信息不受此开关控制
    public var verboseLogging: Bool {
        get {
            userDefaults.bool(forKey: Keys.verboseLogging)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.verboseLogging)
            DebugLog.isEnabled = newValue
        }
    }

    /// 完整的 Hub URL
    public var hubURL: URL {
        URL(string: "ws://\(hubHost):\(hubPort)/debug-bridge")!
    }

    /// 配置摘要（用于显示，格式为 host:port）
    public var summary: String {
        "\(hubHost):\(hubPort)"
    }

    /// 连接状态详情（用于 BackdoorController 显示）
    /// 返回状态文本、状态颜色和地址信息
    public struct ConnectionStatusDetail {
        public let statusText: String
        public let isGreen: Bool
        public let isOrange: Bool
        public let isRed: Bool
        public let isGray: Bool
        public let address: String
    }

    /// 获取连接状态详情
    public var connectionStatusDetail: ConnectionStatusDetail {
        let address = "\(hubHost):\(hubPort)"

        if !isEnabled {
            return ConnectionStatusDetail(
                statusText: "未启用",
                isGreen: false,
                isOrange: false,
                isRed: false,
                isGray: true,
                address: address
            )
        }

        switch DebugProbe.shared.connectionState {
        case .disconnected:
            return ConnectionStatusDetail(
                statusText: "已断开",
                isGreen: false,
                isOrange: false,
                isRed: true,
                isGray: false,
                address: address
            )
        case .connecting:
            return ConnectionStatusDetail(
                statusText: "连接中...",
                isGreen: false,
                isOrange: true,
                isRed: false,
                isGray: false,
                address: address
            )
        case .connected:
            return ConnectionStatusDetail(
                statusText: "握手中...",
                isGreen: false,
                isOrange: true,
                isRed: false,
                isGray: false,
                address: address
            )
        case .registered:
            return ConnectionStatusDetail(
                statusText: "已连接",
                isGreen: true,
                isOrange: false,
                isRed: false,
                isGray: false,
                address: address
            )
        case .failed:
            return ConnectionStatusDetail(
                statusText: "连接失败",
                isGreen: false,
                isOrange: false,
                isRed: true,
                isGray: false,
                address: address
            )
        }
    }

    /// 连接状态摘要（用于 BackdoorController 显示）
    /// 返回两行：第一行为连接状态，第二行为 host:port
    public var statusSummary: String {
        let detail = connectionStatusDetail
        return "\(detail.statusText)\n\(detail.address)"
    }

    // MARK: - Configuration Changed Notification

    public static let configurationDidChangeNotification = Notification
        .Name("DebugProbeSettings.configurationDidChange")

    private func notifyConfigChanged() {
        NotificationCenter.default.post(name: Self.configurationDidChangeNotification, object: self)
    }

    // MARK: - Reset

    /// 重置为默认值
    public func resetToDefaults() {
        userDefaults.removeObject(forKey: Keys.hubHost)
        userDefaults.removeObject(forKey: Keys.hubPort)
        userDefaults.removeObject(forKey: Keys.token)
        userDefaults.removeObject(forKey: Keys.isEnabled)
        notifyConfigChanged()
    }

    /// 检查是否使用了自定义配置
    public var hasCustomConfiguration: Bool {
        userDefaults.string(forKey: Keys.hubHost) != nil ||
            userDefaults.integer(forKey: Keys.hubPort) > 0 ||
            userDefaults.string(forKey: Keys.token) != nil
    }

    // MARK: - Quick Configuration

    /// 快速配置（用于扫码等场景）
    public func configure(host: String, port: Int = 8081, token: String? = nil) {
        userDefaults.set(host, forKey: Keys.hubHost)
        userDefaults.set(port, forKey: Keys.hubPort)
        if let token {
            userDefaults.set(token, forKey: Keys.token)
        }
        notifyConfigChanged()
    }

    /// 从 URL 解析配置
    /// 支持格式: debughub://host:port?token=xxx
    public func configure(from url: URL) -> Bool {
        guard url.scheme == "debughub" else { return false }

        if let host = url.host, !host.isEmpty {
            hubHost = host
        }
        if url.port != nil {
            hubPort = url.port!
        }
        if
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "token" })?
                .value {
            self.token = token
        }
        return true
    }

    /// 生成配置 URL（用于分享或生成二维码）
    public func generateConfigURL() -> URL {
        var components = URLComponents()
        components.scheme = "debughub"
        components.host = hubHost
        components.port = hubPort
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }
}
