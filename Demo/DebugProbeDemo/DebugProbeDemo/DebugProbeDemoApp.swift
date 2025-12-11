//
//  DebugProbeDemoApp.swift
//  DebugProbeDemo
//
//  Created by AI Agent on 2025/12/11.
//

import SwiftUI
import DebugProbe

@main
struct DebugProbeDemoApp: App {
    
    init() {
        setupDebugProbe()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func setupDebugProbe() {
        #if DEBUG
        // 使用简化的无参数启动方式
        // 自动从 DebugProbeSettings.shared 读取配置（hubHost, hubPort, token）
        // 内部会检查 settings.isEnabled，如果禁用则不启动
        DebugProbe.shared.start()
        
        // 注册 Demo 数据库
        if DebugProbe.shared.isStarted {
            DatabaseManager.shared.setupAndRegister()
            print("✅ DebugProbe started with hub: \(DebugProbeSettings.shared.hubURL)")
        } else {
            print("⚠️ DebugProbe is disabled")
        }
        #endif
    }
}
