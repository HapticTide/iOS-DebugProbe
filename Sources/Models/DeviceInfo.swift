// DeviceInfo.swift
// DebugProbe
//
// Created by Sun on 2025/12/02.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// 设备信息模型，用于向 Debug Hub 注册设备
public struct DeviceInfo: Codable {
    public let deviceId: String
    public let deviceName: String
    public let deviceModel: String
    public let systemName: String
    public let systemVersion: String
    public let appName: String
    public let appVersion: String
    public let buildNumber: String
    public let platform: String
    public let isSimulator: Bool
    public var captureEnabled: Bool
    public var logCaptureEnabled: Bool
    public var wsCaptureEnabled: Bool
    public var dbInspectorEnabled: Bool
    public let appIcon: String?

    public init(
        deviceId: String,
        deviceName: String,
        deviceModel: String,
        systemName: String,
        systemVersion: String,
        appName: String,
        appVersion: String,
        buildNumber: String,
        platform: String = "iOS",
        isSimulator: Bool = false,
        captureEnabled: Bool = true,
        logCaptureEnabled: Bool = true,
        wsCaptureEnabled: Bool = true,
        dbInspectorEnabled: Bool = true,
        appIcon: String? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appName = appName
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.platform = platform
        self.isSimulator = isSimulator
        self.captureEnabled = captureEnabled
        self.logCaptureEnabled = logCaptureEnabled
        self.wsCaptureEnabled = wsCaptureEnabled
        self.dbInspectorEnabled = dbInspectorEnabled
        self.appIcon = appIcon
    }
}

public enum DeviceInfoProvider {
    public static func current() -> DeviceInfo {
        let bundle = Bundle.main

        // 公共字段（App 相关）
        let appName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? "Unknown"

        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.0.0"

        let buildNumber = bundle.infoDictionary?[kCFBundleVersionKey as String] as? String
            ?? "0"

        // 平台相关字段
        #if canImport(UIKit)
            let device = UIDevice.current

            #if targetEnvironment(simulator)
                let isSimulator = true
            #else
                let isSimulator = false
            #endif

            let deviceId = device.identifierForVendor?.uuidString ?? UUID().uuidString
            let deviceName = device.name
            let deviceModel = getDeviceModel()
            let systemName = device.systemName
            let systemVersion = device.systemVersion
            let platform = "iOS"
            let appIcon = getAppIconBase64()

        #else
            let isSimulator = false
            let deviceId = UUID().uuidString
            let deviceName = Host.current().localizedName ?? "Mac"
            let deviceModel = macDeviceModel()
            let systemName = "macOS"
            let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let platform = "macOS"
            let appIcon: String? = nil
        #endif

        return DeviceInfo(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceModel: deviceModel,
            systemName: systemName,
            systemVersion: systemVersion,
            appName: appName,
            appVersion: appVersion,
            buildNumber: buildNumber,
            platform: platform,
            isSimulator: isSimulator,
            appIcon: appIcon
        )
    }

    // MARK: - 私有平台实现

    #if canImport(UIKit)
        /// 获取设备型号标识符（如 iPhone15,2）
        private static func getDeviceModel() -> String {
            var systemInfo = utsname()
            uname(&systemInfo)
            let machineMirror = Mirror(reflecting: systemInfo.machine)
            let identifier = machineMirror.children.reduce("") { identifier, element in
                guard let value = element.value as? Int8, value != 0 else {
                    return identifier
                }
                return identifier + String(UnicodeScalar(UInt8(value)))
            }
            return identifier
        }

        private static func getAppIconBase64() -> String? {
            guard
                let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
                let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
                let lastIcon = iconFiles.last,
                let image = UIImage(named: lastIcon)
            else {
                return nil
            }
            return image.pngData()?.base64EncodedString()
        }
    #else
        private static func macDeviceModel() -> String {
            var size: size_t = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)

            var model = [CChar](repeating: 0, count: Int(size))
            sysctlbyname("hw.model", &model, &size, nil, 0)

            return String(cString: model)
        }
    #endif
}
