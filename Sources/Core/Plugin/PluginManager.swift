// PluginManager.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 插件管理器

/// 插件管理器，负责插件的注册、生命周期管理和消息路由
public final class PluginManager: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = PluginManager()

    // MARK: - Properties

    /// 已注册的插件
    private var plugins: [String: DebugProbePlugin] = [:]

    /// 插件启动顺序（拓扑排序后）
    private var startOrder: [String] = []

    /// 线程安全锁
    private let lock = NSLock()

    /// 上下文实例
    private var context: PluginContextImpl?

    /// 是否已启动
    public private(set) var isStarted: Bool = false

    // MARK: - Callbacks

    /// 插件状态变化回调
    public var onPluginStateChanged: ((String, PluginState) -> Void)?

    /// 插件事件回调（用于转发到 Bridge）
    public var onPluginEvent: ((PluginEvent) -> Void)?

    /// 插件命令响应回调
    public var onPluginCommandResponse: ((PluginCommandResponse) -> Void)?

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Plugin Registration

    /// 注册插件
    /// - Parameter plugin: 要注册的插件实例
    /// - Throws: 如果插件 ID 已存在则抛出错误
    public func register(plugin: DebugProbePlugin) throws {
        lock.lock()
        defer { lock.unlock() }

        guard plugins[plugin.pluginId] == nil else {
            throw PluginError.duplicatePluginId(plugin.pluginId)
        }

        plugins[plugin.pluginId] = plugin
        DebugLog.info(.plugin, "Registered plugin: \(plugin.pluginId) (\(plugin.displayName))")
    }

    /// 批量注册插件
    /// - Parameter plugins: 要注册的插件列表
    public func register(plugins: [DebugProbePlugin]) throws {
        for plugin in plugins {
            try register(plugin: plugin)
        }
    }

    /// 注销插件
    /// - Parameter pluginId: 插件 ID
    public func unregister(pluginId: String) async {
        let plugin = withLock { plugins.removeValue(forKey: pluginId) }

        if let plugin {
            await plugin.stop()
            DebugLog.info(.plugin, "Unregistered plugin: \(pluginId)")
        }
    }

    /// 在锁保护下执行闭包
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 获取插件实例
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 插件实例，不存在则返回 nil
    public func getPlugin(pluginId: String) -> DebugProbePlugin? {
        withLock { plugins[pluginId] }
    }

    /// 获取所有已注册的插件
    public func getAllPlugins() -> [DebugProbePlugin] {
        withLock { Array(plugins.values) }
    }

    /// 获取所有插件信息
    public func getAllPluginInfos() -> [PluginInfo] {
        getAllPlugins().map { PluginInfo(from: $0) }
    }

    // MARK: - Lifecycle Management

    /// 初始化并启动所有插件
    /// - Parameter deviceInfo: 设备信息
    public func startAll(deviceInfo: DeviceInfo) async throws {
        guard !isStarted else {
            DebugLog.warning(.plugin, "PluginManager already started")
            return
        }

        // 创建上下文
        context = PluginContextImpl(
            deviceInfo: deviceInfo,
            onEvent: { [weak self] event in
                self?.onPluginEvent?(event)
            },
            onCommandResponse: { [weak self] response in
                self?.onPluginCommandResponse?(response)
            }
        )

        // 拓扑排序确定启动顺序
        try resolveStartOrder()

        // 按顺序初始化和启动插件
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId], let context else { continue }

            DebugLog.info(.plugin, "Starting plugin: \(pluginId)")

            // 初始化
            plugin.initialize(context: context)

            // 启动
            do {
                try await plugin.start()
                DebugLog.info(.plugin, "Plugin started: \(pluginId)")
                onPluginStateChanged?(pluginId, .running)
            } catch {
                DebugLog.error(.plugin, "Failed to start plugin \(pluginId): \(error)")
                onPluginStateChanged?(pluginId, .error)
                throw PluginError.startFailed(pluginId, error)
            }
        }

        isStarted = true
        DebugLog.info(.plugin, "All plugins started (\(startOrder.count) plugins)")
    }

    /// 停止所有插件
    public func stopAll() async {
        guard isStarted else { return }

        // 逆序停止
        for pluginId in startOrder.reversed() {
            guard let plugin = plugins[pluginId] else { continue }

            DebugLog.info(.plugin, "Stopping plugin: \(pluginId)")
            await plugin.stop()
            onPluginStateChanged?(pluginId, .stopped)
        }

        isStarted = false
        context = nil
        DebugLog.info(.plugin, "All plugins stopped")
    }

    /// 暂停所有插件
    public func pauseAll() async {
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId] else { continue }
            await plugin.pause()
            onPluginStateChanged?(pluginId, .paused)
        }
    }

    /// 恢复所有插件
    public func resumeAll() async {
        for pluginId in startOrder {
            guard let plugin = plugins[pluginId] else { continue }
            await plugin.resume()
            onPluginStateChanged?(pluginId, .running)
        }
    }

    // MARK: - Plugin Control

    /// 启用或禁用指定插件
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - enabled: 是否启用
    public func setPluginEnabled(_ pluginId: String, enabled: Bool) async {
        guard let plugin = getPlugin(pluginId: pluginId) else {
            DebugLog.warning(.plugin, "Cannot set enabled state: plugin not found: \(pluginId)")
            return
        }

        if enabled {
            // 如果当前状态是 paused 或 stopped，则恢复/启动
            if plugin.state == .paused {
                await plugin.resume()
                onPluginStateChanged?(pluginId, .running)
            } else if plugin.state == .stopped {
                do {
                    try await plugin.start()
                    onPluginStateChanged?(pluginId, .running)
                } catch {
                    DebugLog.error(.plugin, "Failed to start plugin \(pluginId): \(error)")
                    onPluginStateChanged?(pluginId, .error)
                }
            }
        } else {
            // 禁用插件（暂停而非完全停止，保留状态）
            if plugin.state == .running {
                await plugin.pause()
                onPluginStateChanged?(pluginId, .paused)
            }
        }

        DebugLog.info(.plugin, "Plugin \(pluginId) \(enabled ? "enabled" : "disabled")")
    }

    /// 获取插件是否启用
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否启用（运行中）
    public func isPluginEnabled(_ pluginId: String) -> Bool {
        guard let plugin = getPlugin(pluginId: pluginId) else { return false }
        return plugin.state == .running
    }

    // MARK: - Command Routing

    /// 路由命令到对应插件
    /// - Parameter command: 插件命令
    public func routeCommand(_ command: PluginCommand) async {
        guard let plugin = getPlugin(pluginId: command.pluginId) else {
            DebugLog.warning(.plugin, "Plugin not found for command: \(command.pluginId)")
            let response = PluginCommandResponse(
                pluginId: command.pluginId,
                commandId: command.commandId,
                success: false,
                errorMessage: "Plugin not found: \(command.pluginId)"
            )
            onPluginCommandResponse?(response)
            return
        }

        DebugLog.debug(.plugin, "Routing command to plugin: \(command.pluginId), type: \(command.commandType)")
        await plugin.handleCommand(command)
    }

    // MARK: - Private Methods

    /// 拓扑排序解析启动顺序
    private func resolveStartOrder() throws {
        var visited: Set<String> = []
        var visiting: Set<String> = []
        var order: [String] = []

        func visit(_ pluginId: String) throws {
            if visited.contains(pluginId) { return }
            if visiting.contains(pluginId) {
                throw PluginError.circularDependency(pluginId)
            }

            visiting.insert(pluginId)

            if let plugin = plugins[pluginId] {
                for dep in plugin.dependencies {
                    guard plugins[dep] != nil else {
                        throw PluginError.missingDependency(pluginId, dep)
                    }
                    try visit(dep)
                }
            }

            visiting.remove(pluginId)
            visited.insert(pluginId)
            order.append(pluginId)
        }

        for pluginId in plugins.keys {
            try visit(pluginId)
        }

        startOrder = order
    }
}

// MARK: - Plugin Errors

/// 插件相关错误
public enum PluginError: Error, LocalizedError {
    case duplicatePluginId(String)
    case pluginNotFound(String)
    case circularDependency(String)
    case missingDependency(String, String)
    case startFailed(String, Error)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicatePluginId(id):
            "Plugin ID already registered: \(id)"
        case let .pluginNotFound(id):
            "Plugin not found: \(id)"
        case let .circularDependency(id):
            "Circular dependency detected for plugin: \(id)"
        case let .missingDependency(plugin, dep):
            "Plugin '\(plugin)' depends on missing plugin: \(dep)"
        case let .startFailed(id, error):
            "Failed to start plugin '\(id)': \(error.localizedDescription)"
        case let .invalidConfiguration(msg):
            "Invalid plugin configuration: \(msg)"
        }
    }
}

// MARK: - Plugin Context Implementation

/// 插件上下文具体实现
final class PluginContextImpl: PluginContext, @unchecked Sendable {
    let deviceInfo: DeviceInfo
    private let onEvent: (PluginEvent) -> Void
    private let onCommandResponse: (PluginCommandResponse) -> Void
    private var configurations: [String: Data] = [:]
    private let configLock = NSLock()

    var deviceId: String { deviceInfo.deviceId }

    init(
        deviceInfo: DeviceInfo,
        onEvent: @escaping (PluginEvent) -> Void,
        onCommandResponse: @escaping (PluginCommandResponse) -> Void
    ) {
        self.deviceInfo = deviceInfo
        self.onEvent = onEvent
        self.onCommandResponse = onCommandResponse
    }

    func sendEvent(_ event: PluginEvent) {
        onEvent(event)
    }

    func sendCommandResponse(_ response: PluginCommandResponse) {
        onCommandResponse(response)
    }

    func getConfiguration<T: Decodable>(for key: String) -> T? {
        configLock.lock()
        defer { configLock.unlock() }

        guard let data = configurations[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setConfiguration(_ value: some Encodable, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        configLock.lock()
        configurations[key] = data
        configLock.unlock()
    }

    func log(_ level: PluginLogLevel, _ message: String, file: String, function: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent
        switch level {
        case .debug:
            DebugLog.debug(.plugin, "[\(fileName):\(line)] \(message)")
        case .info:
            DebugLog.info(.plugin, "[\(fileName):\(line)] \(message)")
        case .warning:
            DebugLog.warning(.plugin, "[\(fileName):\(line)] \(message)")
        case .error:
            DebugLog.error(.plugin, "[\(fileName):\(line)] \(message)")
        }
    }
}
