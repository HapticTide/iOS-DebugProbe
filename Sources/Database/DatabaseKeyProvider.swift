// DatabaseKeyProvider.swift
// DebugProbe
//
// Created by Sun on 2025/06/20.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Database Key Provider Protocol

/// 数据库密钥提供者协议
/// 用于为加密数据库提供解密密钥
public protocol DatabaseKeyProvider: Sendable {
    /// 数据库 ID
    var databaseId: String { get }

    /// 获取数据库密钥
    /// - Returns: SQLCipher 格式的密钥字符串（如 "x'hex...'" 或普通字符串）
    /// - Throws: 如果无法获取密钥
    func getKey() async throws -> String
}

// MARK: - Closure Key Provider

/// 基于闭包的密钥提供者
/// 适用于简单场景，直接通过闭包获取密钥
public final class ClosureKeyProvider: DatabaseKeyProvider, @unchecked Sendable {
    public let databaseId: String
    private let keyFetcher: @Sendable () throws -> String

    /// 初始化
    /// - Parameters:
    ///   - databaseId: 数据库 ID
    ///   - keyFetcher: 密钥获取闭包
    public init(databaseId: String, keyFetcher: @escaping @Sendable () throws -> String) {
        self.databaseId = databaseId
        self.keyFetcher = keyFetcher
    }

    public func getKey() async throws -> String {
        try keyFetcher()
    }
}

// MARK: - Async Closure Key Provider

/// 基于异步闭包的密钥提供者
/// 适用于需要异步获取密钥的场景（如从网络或复杂的 Keychain 操作）
public final class AsyncClosureKeyProvider: DatabaseKeyProvider, @unchecked Sendable {
    public let databaseId: String
    private let keyFetcher: @Sendable () async throws -> String

    /// 初始化
    /// - Parameters:
    ///   - databaseId: 数据库 ID
    ///   - keyFetcher: 异步密钥获取闭包
    public init(databaseId: String, keyFetcher: @escaping @Sendable () async throws -> String) {
        self.databaseId = databaseId
        self.keyFetcher = keyFetcher
    }

    public func getKey() async throws -> String {
        try await keyFetcher()
    }
}

// MARK: - Static Key Provider

/// 静态密钥提供者
/// 适用于测试或密钥不变的场景
/// ⚠️ 注意：生产环境不建议使用，密钥应从安全存储获取
public final class StaticKeyProvider: DatabaseKeyProvider, Sendable {
    public let databaseId: String
    private let key: String

    /// 初始化
    /// - Parameters:
    ///   - databaseId: 数据库 ID
    ///   - key: 静态密钥
    public init(databaseId: String, key: String) {
        self.databaseId = databaseId
        self.key = key
    }

    public func getKey() async throws -> String {
        key
    }
}

// MARK: - Key Provider Error

/// 密钥提供者错误
public enum KeyProviderError: Error, LocalizedError {
    /// 密钥未找到
    case keyNotFound(databaseId: String)
    /// 密钥访问被拒绝（如 Keychain 权限问题）
    case accessDenied(reason: String)
    /// 密钥格式无效
    case invalidKeyFormat(reason: String)
    /// 其他错误
    case other(Error)

    public var errorDescription: String? {
        switch self {
        case let .keyNotFound(databaseId):
            "Encryption key not found for database: \(databaseId)"
        case let .accessDenied(reason):
            "Access denied: \(reason)"
        case let .invalidKeyFormat(reason):
            "Invalid key format: \(reason)"
        case let .other(error):
            "Key provider error: \(error.localizedDescription)"
        }
    }
}
