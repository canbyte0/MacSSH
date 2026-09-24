# 终端标签栏横向滚动条

日期：2026-09-24。范围：用户确认预览后的标签栏滚动条改动，未推进其他 Phase。

## 行为

- 标签溢出时，在现有 42 pt 标签栏底部显示 3 pt 细滚动条；未溢出时隐藏。
- 滑块的实际命中高度为 8 pt，可拖动到首尾，也可点击轨道翻页。
- 标签增删、窗口尺寸变化与侧栏展开后同步更新滑块比例；内容缩短后收敛偏移，避免末尾空白。
- 保留此前的加号点击修复、标签重命名和会话切换逻辑。

## 实现

`TerminalTabBar.swift` 通过零尺寸探针连接现有 `ScrollView`，由 SwiftUI 底部覆盖层管理原生 `NSScroller` 的布局和鼠标命中。`TerminalTabScrollbar.swift` 负责几何同步、原生控件 action 和生命周期清理。

滚动范围使用 clip view 的 `contentInsets` 扣除被侧栏覆盖的区域，兼容 macOS 将滚动容器延伸到侧栏下方的布局。细控件的命中检测覆盖完整 8 pt，避免只能拖动滑块上方、不能拖动可见细线的问题。临时几何诊断代码已移除。

## 验证

- Debug 编译及最终定向测试成功；Release 构建成功，未发现编译 warning。
- 10 项定向测试通过：8 项滚动条测试，加上本地多会话独立运行、切换不重建的 2 项既有测试。
- 滚动条测试覆盖溢出显示、偏移同步、首尾 action、内容缩短、窗口 resize、解绑、侧栏 contentInsets、真实 SwiftUI 覆盖层几何及细线命中。
- 独立验证副本实际运行：新增到 9 个标签；直接拖动可见细线到右端（值 1）与左端（值 0）；点击轨道到末尾；单击加号新增第 10 个标签；关闭到 5 个后自动隐藏且没有末尾空白；展开右侧栏后滚动条重新出现并适配宽度。
- GUI 自动化的横向滚轮调用未产生可观察的位移，因此不把该调用计为触控板实测通过；代码继续使用原 `ScrollView` 并将滑块上的滚轮事件转交该容器。
- `git diff --check` 和工程文件 `plutil -lint` 通过。

测试结果：`/tmp/macssh-tab-scrollbar-tests-r4.xcresult`。
测试日志：`/tmp/macssh-tab-scrollbar-tests-r4.log`。
Release 日志：`/tmp/macssh-tab-scrollbar-release.log`。

验证副本：`/tmp/MacSSHTabScrollbarCheck.app`，使用独立 bundle identifier，验证结束后已退出。没有替换 `/Applications/MacSSH.app`，没有提交或推送代码。
