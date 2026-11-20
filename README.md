StreamFlow-iOS

 StreamFlow是一款面向个人 NAS 用户的 iPhone 客户端，提供下载任务管理、媒体浏览与播放、DLNA 投屏及 SMB 文件管理功能。

连接自己的 NAS 服务端，即可通过 iPhone 管理下载任务、访问媒体文件，并在手机或电视上享受影音内容。

功能特性

下载任务管理
- 创建下载任务
- 暂停、继续和取消任务
- 删除任务
- 查看下载进度及错误信息

媒体管理与播放
- 浏览 NAS 媒体库
- 在线播放媒体文件
- 支持 HTTP / HLS 播放

DLNA 投屏
- 搜索局域网内的 DLNA 播放设备
- 支持手动输入设备 IP 或扫描网段
- 将媒体投放到电视等兼容设备
- 支持播放、暂停、停止及进度查看

SMB 文件管理
- 配置 SMB 共享
- 浏览共享目录
- 备份媒体文件
- 备份任务由 NAS 服务端执行

技术架构

- iOS 原生客户端
- 通过 HTTP API 与 NAS 服务端通信
- 服务端与客户端独立部署
- 登录凭据通过 iOS Keychain 安全保存

服务端不包含在本仓库中。

API 接口定义：[`docs/openapi.yaml`](docs/openapi.yaml)

环境要求

- iOS 17 或更新版本
- Xcode 15 或更新版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

构建与运行

安装 XcodeGen：

```bash
brew install xcodegen
```

生成 Xcode 项目：

```bash
cd ios
xcodegen generate
```

打开项目：

```bash
open StreamFlow.xcodeproj
```

项目默认不配置代码签名。安装到真机时，需要在 Xcode 中配置自己的 Apple Developer Team。

网络与设备发现

DLNA 设备发现目前支持单播搜索、手动输入电视 IP 和网段扫描。

多播设备发现需要 Apple Multicast Networking Entitlement，当前版本未启用该功能。

使用 DLNA 投屏时，请确保 iPhone 与电视连接到同一局域网，并允许应用访问本地网络。
反馈与贡献

欢迎通过 GitHub Issues 提交问题、反馈使用体验或提出功能建议。

Pull Request 将根据项目维护安排进行审核与合并。
许可证

本项目采用 [Apache License 2.0](LICENSE) 开源许可证。
