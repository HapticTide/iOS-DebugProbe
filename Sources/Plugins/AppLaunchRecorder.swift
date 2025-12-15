//  AppLaunchRecorder.swift
//  DebugProbe
//
//  自动记录 App 启动开始时间
//  使用静态初始化在模块加载时执行
//
//  Created by Sun on 2025/12/12.
//  Copyright © 2025 Sun. All rights reserved.
//

import Foundation

/// App 启动时间自动记录器
/// 使用静态属性初始化在模块加载时自动记录启动开始时间
///
/// 注意：静态初始化的执行时机是模块首次访问时，
/// 通常在 `import DebugProbe` 语句执行时触发，
/// 这比 `main()` 稍晚，但比 AppDelegate 初始化更早
internal enum AppLaunchRecorder {
    /// 触发器 - 在模块加载时自动执行
    /// 通过访问这个属性来确保初始化代码被执行
    @usableFromInline
    static let trigger: Void = {
        // 记录 processStart 阶段
        PerformancePlugin.recordLaunchPhase(.processStart)
    }()

    /// 确保触发器被访问（在模块入口处调用）
    @inline(__always)
    static func ensureRecorded() {
        _ = trigger
    }
}
