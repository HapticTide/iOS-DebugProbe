// BuiltinPlugins.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - 内置插件注册

/// 内置插件工厂
/// 负责创建和注册所有内置插件
public enum BuiltinPlugins {
    /// 创建所有内置插件实例
    /// - Returns: 内置插件数组
    public static func createAll() -> [DebugProbePlugin] {
        [
            HttpPlugin(),
            LogPlugin(),
            WebSocketPlugin(),
            DatabasePlugin(),
            MockPlugin(),
            BreakpointPlugin(),
            ChaosPlugin(),
            PerformancePlugin(),
        ]
    }

    /// 注册所有内置插件到插件管理器
    public static func registerAll() throws {
        let plugins = createAll()
        try PluginManager.shared.register(plugins: plugins)
    }

    /// 创建指定的内置插件
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 插件实例，不存在则返回 nil
    public static func create(pluginId: String) -> DebugProbePlugin? {
        switch pluginId {
        case BuiltinPluginId.http:
            HttpPlugin()
        case BuiltinPluginId.log:
            LogPlugin()
        case BuiltinPluginId.webSocket:
            WebSocketPlugin()
        case BuiltinPluginId.database:
            DatabasePlugin()
        case BuiltinPluginId.mock:
            MockPlugin()
        case BuiltinPluginId.breakpoint:
            BreakpointPlugin()
        case BuiltinPluginId.chaos:
            ChaosPlugin()
        case BuiltinPluginId.performance:
            PerformancePlugin()
        default:
            nil
        }
    }
}
