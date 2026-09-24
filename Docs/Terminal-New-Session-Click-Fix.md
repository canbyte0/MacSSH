# 新增终端按钮点击修复记录

日期：2026-09-24。

## 问题与范围

用户反馈连续新增终端时，偶尔需要多次点击加号中心才会新增。
修复前独立探针确认原按钮的透明留白不能触发点击；但未稳定复现用户描述的中心偶发失效，不能将点击范围或拖动手势认定为该现象的唯一根因。

用户确认预览后，仅修改 `MacSSH/Features/Terminal/TerminalTabBar.swift` 的新增按钮交互。保留该文件原有的未提交重命名功能及工作区其他修改，不提交、不推送、不替换已安装应用。

## 实现

- 为加号标签明确设置完整的 42 × 42 pt 矩形命中范围。
- 使用仅服务于该按钮的 `TerminalNewSessionButtonStyle: ButtonStyle`，由 `configuration.isPressed` 提供按压状态，不再通过 `AppInteractiveButtonStyle` 叠加零距离 `DragGesture`。
- 缩放后的样式外层重新声明完整命中范围，悬停、按压缩放只影响视觉。
- 保留 28 pt 圆形反馈、既有透明度与动画时长、Reduce Motion 和禁用状态处理；装饰底色不参与命中。
- 新增会话业务入口与所有其他按钮的公共样式不变。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| Debug arm64 构建 | BUILD SUCCEEDED，0 条编译 warning |
| Release arm64 构建 | BUILD SUCCEEDED，0 条编译 warning |
| 现有 SessionManager 本地测试 A–I、U | 10 通过，0 失败，0 跳过 |
| U 用例的创建、关闭循环 | 20 轮，资源增长断言通过 |
| Release 副本启动与签名检查 | 通过 |
| GUI 坐标点击新增 | 7 次点击新增 7 个标签，无重复触发 |
| `git diff --check` | 通过 |

GUI 使用本次 Release 构建的副本 `/tmp/MacSSHClickCheck.app`，独立 bundle ID 为 `local.macssh.clickcheck`，避免把仍在运行的旧版本当成新版本。
从初始 1 个标签依次新增到 8 个：中心点击 3 次，上、下、左、右留白各 1 次；每次均单击触发一次新增。最后退出验证副本，未关闭用户原有 MacSSH 会话。
这些坐标点击含自动化观察间隔，不等同于用户手动快速点击的节奏，也不替代对偶发问题的实际使用验收。

构建日志：`/tmp/macssh-tabbar-debug-build.log`、`/tmp/macssh-tabbar-release-build.log`。
测试日志：`/tmp/macssh-tabbar-session-tests.log`；结果包：`/tmp/macssh-tabbar-session-tests.xcresult`。
测试日志有系统 `com.apple.linkd.autoShortcut` 连接诊断；所选测试均成功，无项目编译 warning。

## 验收边界

实现、编译、所选自动化测试和上述 GUI 检查通过。对用户报告的中心偶发失效仍为 **CONDITIONAL PASS**：需要用户用新构建按原来的连续新增节奏复测，不能仅据本次成功样本宣称问题已彻底消失。

本次交付停在该修复与验证，不进入其他 Phase。
