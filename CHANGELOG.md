# DebugProbe SDK 更新日志

所有显著更改都将记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [1.2.4] - 2026-02-04

### 新增

- **HTTP 错误结构化**: 响应新增 error 结构体（domain/code/category/isNetworkError/message）
- **错误分类**: 细分 timeout/dns/tls/cancelled/network/http 等错误类别

### 修复

- **重定向链路**: 完善重定向事件关联与记录
- **响应头解析**: 修复响应头丢失导致 `Location` 无法识别的问题

---

## [1.2.3] - 2026-01-31

### 改进

- 设备信息新增 `appSessionId`，用于区分重连与 App 重启

### 修复

- 数据库跨表搜索结果跳转在非第一页无法定位的问题
- 插件命令响应保留 `commandId`，修复日志 ZIP 导出超时

---

## [1.2.0] - 2026-01-26

### 新增

#### 加密数据库状态检测
- 新增 `EncryptionStatus` 枚举（none/unlocked/locked）
- `DBInfo` 新增 `encryptionStatus` 字段，用于区分数据库的加密状态
- 支持检测 SQLCipher 加密数据库是否已解锁

#### SQLCipher 配置增强
- 新增 `preparationStatements` 支持，用于在应用密钥后执行额外的 PRAGMA 配置
- 新增 `registerEncrypted(id:keyProvider:preparationSQL:)` 方法
- 支持配置 `PRAGMA cipher_compatibility`、`PRAGMA kdf_iter` 等 SQLCipher 参数

#### 加密注册管理
- 新增 `unregisterEncryption(for:)` 方法，用于清理单个数据库的密钥提供者
- 新增 `unregisterAllEncryption()` 方法，用于清理所有密钥提供者
- 适用于用户切换账户时清理加密配置

#### 数据库所有者标识
- 新增 `ownerDisplayName` 字段支持用户友好标识
- 支持显示数据库所属用户信息

### 改进

- 优化 `SQLiteInspector` 对加密数据库的处理逻辑
- 改进数据库列表返回时的加密状态显示
- `listDatabases` 即使无法打开加密数据库也返回文件大小
- 自动检测加密数据库并在无密钥时拒绝访问

### 修复

- 修复 SQLCipher 数据库支持的关键问题

---

## [1.0.0] - 2025-12-02

### 新增

#### 核心功能
- HTTP/HTTPS 请求捕获 (URLProtocol)
- URLSessionTaskMetrics 性能数据
- CocoaLumberjack 日志集成
- os_log 日志捕获
- WebSocket 连接监控
- SQLite 数据库检查

#### 调试功能
- Mock 规则引擎
- 断点调试框架
- 故障注入框架

#### 通信
- WebSocket 连接到 Debug Hub
- 设备信息上报
- 实时事件推送

#### 配置管理
- `DebugProbeSettings` 运行时配置管理
- 支持 Info.plist 配置
- 支持 UserDefaults 持久化
- 配置变更通知机制

#### 网络捕获
- HTTP 自动拦截 (`URLSessionConfigurationSwizzle`)
- WebSocket 连接级 Swizzle
- WebSocket 消息级 Hook

#### 可靠性
- 事件持久化队列 (SQLite)
- 断线重连自动恢复
- 批量发送优化

#### 内部日志
- `DebugLog` 分级日志系统
- 支持 verbose 开关

#### 页面耗时监控
- `PageTimingRecorder` 页面耗时记录器
- 支持 UIKit 自动采集（viewWillAppear → viewDidAppear）
- 支持 SwiftUI UIHostingController 自动采集
- 支持手动 API 精确控制页面生命周期标记
- 排除系统类和 SwiftUI UIHostingController

#### 性能监控插件
- `PerformancePlugin` 插件
- 支持 CPU 使用率监控
- 支持内存使用监控
- 支持帧率 (FPS) 监控

#### 断点调试
- `BreakpointEngine` 网络层集成
- 支持请求断点和响应断点

#### Chaos 故障注入
- `ChaosEngine` 网络层集成
- 支持延迟注入、超时模拟、连接重置
- 支持错误码注入、数据损坏、请求丢弃

#### 数据库多用户支持
- 支持多用户数据库隔离
- SQL 查询超时保护（5 秒自动中断）
- 结果集大小限制（最多 1000 行）
- 并发查询限制（串行队列）

#### 请求重放
- 完整实现 `replayRequest` 消息处理
- 使用 `.ephemeral` URLSession 执行重放

### 变更

- 插件化架构重构
- 统一使用 `PluginManager` 管理所有功能模块
- 通信时间改为毫秒级
- 优化 premain 时间统计

### 修复

- 修复 HTTP 请求 body 参数解析问题
- 修复包含 'create' 等关键词的查询报错问题
- 修复 `tableExists()` 方法的内存 bug
- 使用 `SQLITE_TRANSIENT` 确保字符串正确绑定

---

## 版本历史图表

```
1.0.0 ────────────────────────► 1.2.4 (当前)
  │                                │
  │                                └─ 加密数据库状态检测
  │                                   SQLCipher 配置增强
  │                                   ownerDisplayName 支持
  │
  └─ 核心功能实现
     HTTP/Log/WS/DB 捕获
     Mock/断点/Chaos 框架
     页面耗时/性能监控
     多用户数据库支持
```

---

## 升级指南

### 从 1.0.0 升级到 1.2.0

1. **无破坏性变更**，直接更新依赖即可

2. **加密数据库支持增强**：
   ```swift
   // 注册带有 preparationSQL 的加密数据库
   SQLiteInspector.shared.registerEncrypted(
       id: dbId,
       keyProvider: { passphrase },
       preparationSQL: [
           "PRAGMA cipher_compatibility = 4;",
           "PRAGMA kdf_iter = 256000;"
       ]
   )
   ```

3. **ownerDisplayName 支持**：
   ```swift
   // 数据库现在会显示所有者名称
   // 需要配合 Debug Hub 1.2.0+ 使用
   ```
