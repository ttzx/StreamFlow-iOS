# StreamFlow iOS

StreamFlow 的 iPhone 原生客户端：连接自架 NAS 上的 StreamFlow 服务端，浏览媒体库、
发起 HTTP/magnet/torrent 下载任务、本地播放（直读或 HLS），并通过 DLNA/UPnP 投屏到
局域网电视。

- 服务端（NAS 侧，本仓库不含）：FastAPI 实现，见项目文档中的 OpenAPI 契约
  （`docs/22-OpenAPI-v1-草案.yaml`）。
- 本仓库为客户端单仓：SwiftUI App + XcodeGen 工程描述。

## 构建

```bash
cd ios
brew install xcodegen
xcodegen generate
xcodebuild -project StreamFlow.xcodeproj -scheme StreamFlow \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

要求：Xcode 16+、iOS 17.0+ 部署目标。

## 本地自测（不依赖真实 NAS）

仓库提供两个测试夹具（来自服务端仓库的 scripts/）：

```bash
# 源站文件服务器（确定性字节 + Range）
python3 server/scripts/dev_source_server.py            # 127.0.0.1:8090
# DLNA 模拟电视（SSDP 1900 + AVTransport 8091）
python3 server/scripts/dev_dlna_mock.py --port 8091
```

完整集成测试套件（连接/下载/播放/HLS/DLNA 投屏）运行在服务端仓库的 CI 中，
需要真实 FastAPI 服务端，故不随本仓库分发。

## 契约

客户端与服务端通过 `docs/22-OpenAPI-v1-草案.yaml` 描述的 HTTP API 通信；
播放地址由服务端 HMAC 签名（零请求头可播，支持 Range 206）。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
