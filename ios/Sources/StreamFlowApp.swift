import SwiftUI

/// StreamFlow V2 iOS 客户端最小工程（阶段一脚手架）。
/// 后续阶段接入（按第四阶段计划）：NAS 连接配置、下载任务管理、媒体浏览与播放、
/// DLNA 发现/投屏/控制（从 docs/reference/swift-porting 移植 DLNAKit，先修 docs/25 已知缺陷）。
@main
struct StreamFlowApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("StreamFlow")
                    .font(.largeTitle.bold())
                Text("V2 脚手架")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
