//
//  DDLogBridgeLocal.swift
//  DebugProbeDemo
//
//  本地 CocoaLumberjack 日志桥接器
//  由于 DebugProbe 不再包含 CocoaLumberjack 依赖，
//  需要在 Demo App 中自行实现桥接器
//

#if canImport(CocoaLumberjack)
import Foundation
import CocoaLumberjack
import DebugProbe

/// CocoaLumberjack 日志桥接器，将 DDLog 日志转发到 DebugProbe
public final class DDLogBridgeLocal: DDAbstractLogger {
    // MARK: - Properties

    private var _logFormatter: DDLogFormatter?

    // MARK: - Lifecycle

    override public init() {
        super.init()
    }

    // MARK: - DDAbstractLogger Override

    override public var logFormatter: DDLogFormatter? {
        get { _logFormatter }
        set { _logFormatter = newValue }
    }

    override public func log(message logMessage: DDLogMessage) {
        // 将 DDLogMessage 映射为 LogEvent 并发送到 DebugProbe
        DebugProbe.shared.log(
            level: mapDDLogFlagToLevel(logMessage.flag),
            message: logMessage.message,
            subsystem: logMessage.fileName,
            category: logMessage.function ?? "DDLog"
        )
    }

    // MARK: - Helpers

    /// 将 DDLogFlag 映射为 LogEvent.Level
    private func mapDDLogFlagToLevel(_ flag: DDLogFlag) -> LogEvent.Level {
        switch flag {
        case .verbose:
            return .verbose
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        default:
            return .debug
        }
    }
}
#endif
