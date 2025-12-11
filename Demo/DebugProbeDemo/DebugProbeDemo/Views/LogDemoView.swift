//
//  LogDemoView.swift
//  DebugProbeDemo
//
//  Created by AI Agent on 2025/12/11.
//

import SwiftUI
import DebugProbe
import os.log

struct LogDemoView: View {
    @State private var customMessage = ""
    @State private var selectedLevel = 2 // info
    
    private let levels = ["Verbose", "Debug", "Info", "Warning", "Error"]
    
    var body: some View {
        List {
            // 快速日志
            Section {
                Button {
                    logVerbose()
                } label: {
                    HStack {
                        Circle()
                            .fill(.gray)
                            .frame(width: 8, height: 8)
                        Text("Verbose 日志")
                    }
                }
                
                Button {
                    logDebug()
                } label: {
                    HStack {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                        Text("Debug 日志")
                    }
                }
                
                Button {
                    logInfo()
                } label: {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Info 日志")
                    }
                }
                
                Button {
                    logWarning()
                } label: {
                    HStack {
                        Circle()
                            .fill(.yellow)
                            .frame(width: 8, height: 8)
                        Text("Warning 日志")
                    }
                }
                
                Button {
                    logError()
                } label: {
                    HStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Error 日志")
                    }
                }
            } header: {
                Text("快速日志")
            } footer: {
                Text("点击按钮发送不同级别的日志")
            }
            
            // 自定义日志
            Section {
                TextField("日志内容", text: $customMessage)
                    .textFieldStyle(.roundedBorder)
                
                Picker("日志级别", selection: $selectedLevel) {
                    ForEach(0..<levels.count, id: \.self) { index in
                        Text(levels[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
                
                Button {
                    sendCustomLog()
                } label: {
                    Text("发送自定义日志")
                        .frame(maxWidth: .infinity)
                }
                .disabled(customMessage.isEmpty)
            } header: {
                Text("自定义日志")
            }
            
            // 批量日志
            Section {
                Button {
                    sendBatchLogs(count: 10)
                } label: {
                    Text("批量发送 10 条日志")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    sendBatchLogs(count: 50)
                } label: {
                    Text("批量发送 50 条日志")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    sendMixedLogs()
                } label: {
                    Text("发送混合级别日志")
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("批量测试")
            }
            
            // 模拟场景
            Section {
                Button {
                    simulateUserFlow()
                } label: {
                    Text("模拟用户登录流程")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    simulateNetworkError()
                } label: {
                    Text("模拟网络错误")
                        .frame(maxWidth: .infinity)
                }
                
                Button {
                    simulateCrashLog()
                } label: {
                    Text("模拟崩溃日志")
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("模拟场景")
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Quick Logs
    
    private func logVerbose() {
        DebugProbe.shared.log(
            level: .verbose,
            message: "Verbose: App state changed at \(Date())",
            subsystem: "Demo",
            category: "State"
        )
    }
    
    private func logDebug() {
        DebugProbe.shared.log(
            level: .debug,
            message: "Debug: Button tapped, performing action",
            subsystem: "Demo",
            category: "UI"
        )
    }
    
    private func logInfo() {
        DebugProbe.shared.log(
            level: .info,
            message: "Info: User completed onboarding",
            subsystem: "Demo",
            category: "Analytics"
        )
    }
    
    private func logWarning() {
        DebugProbe.shared.log(
            level: .warning,
            message: "Warning: Low memory detected, consider releasing resources",
            subsystem: "Demo",
            category: "Performance"
        )
    }
    
    private func logError() {
        DebugProbe.shared.log(
            level: .error,
            message: "Error: Failed to load user profile - Network timeout",
            subsystem: "Demo",
            category: "Network"
        )
    }
    
    // MARK: - Custom Log
    
    private func sendCustomLog() {
        let level: LogEvent.Level = switch selectedLevel {
        case 0: .verbose
        case 1: .debug
        case 2: .info
        case 3: .warning
        case 4: .error
        default: .info
        }
        
        DebugProbe.shared.log(
            level: level,
            message: customMessage,
            subsystem: "Demo",
            category: "Custom"
        )
        
        customMessage = ""
    }
    
    // MARK: - Batch Logs
    
    private func sendBatchLogs(count: Int) {
        for i in 1...count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                DebugProbe.shared.log(
                    level: .info,
                    message: "Batch log #\(i) of \(count)",
                    subsystem: "Demo",
                    category: "Batch"
                )
            }
        }
    }
    
    private func sendMixedLogs() {
        let levels: [LogEvent.Level] = [.verbose, .debug, .info, .warning, .error]
        
        for (index, level) in levels.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                DebugProbe.shared.log(
                    level: level,
                    message: "Mixed log test - Level: \(level)",
                    subsystem: "Demo",
                    category: "Mixed"
                )
            }
        }
    }
    
    // MARK: - Simulate Scenarios
    
    private func simulateUserFlow() {
        let steps: [(LogEvent.Level, String)] = [
            (.info, "User opened login screen"),
            (.debug, "Validating email format..."),
            (.debug, "Email validation passed"),
            (.info, "Sending login request..."),
            (.debug, "Request sent to /api/auth/login"),
            (.info, "Login successful, token received"),
            (.debug, "Storing token in keychain"),
            (.info, "Navigating to home screen"),
        ]
        
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.3) {
                DebugProbe.shared.log(
                    level: step.0,
                    message: step.1,
                    subsystem: "Demo",
                    category: "Auth"
                )
            }
        }
    }
    
    private func simulateNetworkError() {
        let logs: [(LogEvent.Level, String)] = [
            (.info, "Starting API request to /api/users"),
            (.debug, "Request URL: https://api.example.com/users"),
            (.debug, "Request method: GET"),
            (.warning, "Request taking longer than expected..."),
            (.error, "Network error: The request timed out"),
            (.error, "Error code: NSURLErrorTimedOut (-1001)"),
            (.info, "Scheduling retry in 5 seconds"),
        ]
        
        for (index, log) in logs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
                DebugProbe.shared.log(
                    level: log.0,
                    message: log.1,
                    subsystem: "Demo",
                    category: "Network"
                )
            }
        }
    }
    
    private func simulateCrashLog() {
        let logs: [(LogEvent.Level, String)] = [
            (.error, "⚠️ FATAL: Unhandled exception caught"),
            (.error, "Exception type: NSInvalidArgumentException"),
            (.error, "Reason: -[__NSCFString objectAtIndex:]: unrecognized selector"),
            (.error, "Stack trace:"),
            (.error, "  0   CoreFoundation  0x00007fff2043f6fb __exceptionPreprocess + 250"),
            (.error, "  1   libobjc.A.dylib 0x00007fff201c3530 objc_exception_throw + 48"),
            (.error, "  2   CoreFoundation  0x00007fff204bdf5c -[__NSCFString objectAtIndex:] + 0"),
            (.error, "  3   DebugProbeDemo  0x0000000104a2b3f0 ContentView.body.getter + 128"),
        ]
        
        for (index, log) in logs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                DebugProbe.shared.log(
                    level: log.0,
                    message: log.1,
                    subsystem: "Demo",
                    category: "Crash"
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        LogDemoView()
    }
}
