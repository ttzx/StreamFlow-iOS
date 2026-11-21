import SwiftUI
import UIKit

/// 键盘收起（真机反馈：滚动收起 + 工具栏「完成」）。
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                     to: nil, from: nil, for: nil)
}

extension View {
    /// 列表/表单滚动时立即收起键盘（iOS 16+；项目部署目标 17.0）
    func scrollDismissesKeyboardImmediately() -> some View {
        scrollDismissesKeyboard(.immediately)
    }

    /// 键盘工具栏右侧「完成」按钮（配合 hideKeyboard 使用）
    func keyboardDoneBar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { hideKeyboard() }
            }
        }
    }
}
