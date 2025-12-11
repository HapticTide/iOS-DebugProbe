# DebugProbe Demo

这是一个完整的 DebugProbe SDK 演示应用，展示了所有调试功能的使用方法。

## 功能演示

### 🌐 HTTP 请求
- 发送 GET/POST 请求到公开 API
- 批量请求测试
- 查看响应详情

### 🔌 WebSocket
- 连接到 Echo 服务器
- 发送文本/JSON/二进制消息
- 批量消息测试
- 实时查看收发记录

### 📝 日志
- 发送不同级别的日志（Verbose/Debug/Info/Warning/Error）
- 自定义日志内容和类别
- 批量日志测试
- 模拟真实场景（登录流程、网络错误、崩溃日志）

### 🗄️ 数据库
- SQLite 数据库 CRUD 操作
- 用户数据管理
- 批量数据插入
- 在 WebUI 中查看数据库结构和内容

### 🎭 Mock & Breakpoint
- Mock 规则测试请求
- 断点调试测试
- Chaos 故障注入测试

## 使用方法

### 1. 启动 Debug Hub

```bash
cd DebugPlatform/DebugHub
./deploy.sh --sqlite
```

### 2. 打开 Demo 工程

```bash
cd DebugProbe/Demo/DebugProbeDemo
open DebugProbeDemo.xcodeproj
```

### 3. 运行 Demo

1. 选择目标设备（模拟器或真机）
2. 点击运行按钮
3. Demo 启动后会自动连接到 Debug Hub

### 4. 查看调试信息

打开浏览器访问：http://127.0.0.1:8081

## 项目结构

```
DebugProbeDemo/
├── DebugProbeDemoApp.swift    # App 入口，初始化 DebugProbe
├── ContentView.swift          # 主界面
├── Views/
│   ├── NetworkDemoView.swift   # HTTP 请求演示
│   ├── WebSocketDemoView.swift # WebSocket 演示
│   ├── LogDemoView.swift       # 日志演示
│   ├── DatabaseDemoView.swift  # 数据库演示
│   ├── MockDemoView.swift      # Mock/断点演示
│   └── SettingsView.swift      # 设置页面
└── Managers/
    ├── DatabaseManager.swift   # SQLite 数据库管理
    └── WebSocketManager.swift  # WebSocket 连接管理
```

## 配置说明

默认配置连接到本地 Debug Hub：

```swift
var config = DebugProbe.Configuration(
    hubURL: URL(string: "ws://127.0.0.1:8081/debug-bridge")!,
    token: "demo-device-xxx"
)
```

如需连接到其他地址，请修改 `DebugProbeDemoApp.swift` 中的配置。

## 测试用 API

Demo 使用以下公开 API 进行测试：

- **JSONPlaceholder**: https://jsonplaceholder.typicode.com
- **HTTPBin**: https://httpbin.org
- **WebSocket Echo**: wss://echo.websocket.org

## 注意事项

1. 确保 Debug Hub 在运行中
2. 如果使用真机测试，需要修改 Hub URL 为电脑的局域网 IP
3. Mock 和断点规则需要在 WebUI 中配置后才能生效

## License

MIT License
