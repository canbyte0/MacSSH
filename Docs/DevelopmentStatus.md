# MacSSH 开发状态

## 规范基线

本项目的最高级开发规范是根目录的：

`macOS 原生 Terminal + SSH + SFTP 一体化客户端完整开发计划书.md`

所有开发必须按计划书中的 Phase 顺序进行，每个 Phase 完成后停止并等待用户验收。

## 当前阶段

### Phase 0：项目初始化

状态：**已完成并通过用户验收**

完成日期：2026-08-27

已完成：

- 创建原生 macOS Xcode Project、App Target 和共享 Scheme。
- 创建 SwiftUI App 入口与最小根视图。
- 建立计划书约定的 Feature、Service、Infrastructure、Component 等目录骨架。
- 建立基础 `AppState`，并限定在主线程使用。
- 建立系统动态颜色驱动的基础 Theme。
- 建立基于 `OSLog.Logger` 的统一 App 日志入口。
- 设置 macOS 14.0 最低系统版本和 Apple Silicon arm64 构建验证。
- 配置 Hardened Runtime；本地 Debug/Release 使用 Xcode 的 `Sign to Run Locally`。

验收结果：

- Debug arm64 干净构建成功，无 warning。
- Release arm64 干净构建成功，无 warning。
- App 实际启动成功，主窗口和辅助功能树正常。
- Light Mode 实际显示正常。
- Dark Mode 实际显示正常，测试后已恢复系统原外观。

本阶段明确未实现：

- Sidebar、Workspace、Toolbar、Tab Bar、Settings。
- SwiftTerm、本地 PTY、SSH、SFTP、SwiftData、Keychain。
- 任何 Phase 1 或后续阶段的业务功能。

### Phase 1：主界面

状态：**已完成并通过用户验收**

完成日期：2026-08-27

已完成：

- 使用原生 `NavigationSplitView` 建立 Sidebar 与 Workspace 双栏结构。
- Sidebar 提供 Local Terminal、Hosts、Transfers、Settings 四个入口，并支持原生收起/展开。
- Toolbar 提供应用标题和禁用态 New Session 入口，明确不提前实现会话创建。
- Terminal Workspace 提供只读 Mock Tab Bar，可在 Local 与 Demo Server 两个模拟标签间切换。
- Hosts 页面展示无敏感信息的 Mock 主机列表。
- Transfers 页面展示 Phase 1 占位状态。
- Settings 页面按计划书字段展示只读 Mock 配置，不进行持久化。
- 增加 Phase 1 状态栏，并为主要界面元素补充辅助功能标识和说明。

验收前自测结果：

- Debug arm64 干净构建成功，无 warning。
- Release arm64 干净构建成功，无 warning。
- App 实际启动成功，四个 Sidebar 页面均可切换。
- Local 与 Demo Server 两个 Mock 标签均可切换。
- Sidebar 收起和恢复正常。
- Light Mode 与 Dark Mode 实际显示正常，测试后已恢复系统原外观。

本阶段明确未实现：

- SwiftTerm、本地 PTY、Shell 会话与真实终端输入输出。
- SSH、SFTP、libssh2、OpenSSL、Host Key 验证和凭据处理。
- SwiftData、Keychain 和任何设置持久化。
- 新建/关闭真实会话及传输任务。

### Phase 2：本地 Terminal

状态：**已完成并通过用户验收**

完成日期：2026-08-27

已完成：

- 通过 Swift Package Manager 固定引入 SwiftTerm 1.19.0。
- 使用 `NSViewRepresentable` 将 SwiftTerm AppKit `LocalProcessTerminalView` 接入 SwiftUI Workspace。
- 使用 SwiftTerm 内置 `LocalProcess` 和 PTY 启动本地 Shell，没有自行实现终端模拟器。
- 通过 `getpwuid_r` 优先读取当前 macOS 账户的 login shell，并使用 login shell 语义启动。
- 设置 `TERM=xterm-256color`、TrueColor 环境与默认 10,000 行 Scrollback。
- 支持本地 Shell 输入输出、选择、复制、粘贴、滚动及全屏命令行程序。
- 使用 SwiftTerm 内置尺寸计算将窗口 Resize 自动同步给 PTY。
- 状态栏实时显示 Terminal 生命周期和 PTY 列数、行数。
- 本地会话由 `AppState` 持有，切换 Sidebar 页面不会销毁正在运行的 Shell。
- Terminal 生命周期日志不记录用户命令、输出或环境变量。

验收前自测结果：

- Debug arm64 干净构建成功，无 warning。
- Release arm64 干净构建成功，无 warning。
- App 实际启动成功，账户 login shell 为 zsh，`ARG0=-zsh`。
- `TERM=xterm-256color`，`COLORTERM=truecolor`。
- 实际执行 `pwd`、`ls`、`cd`、`clear`、`top`、`vim`、`nano`、`python3`、`node` 均正常。
- 中文、Emoji、ANSI Color、256 Color、TrueColor 实际显示正常。
- 窗口放大时 PTY 从 64 × 28 更新为 149 × 44，恢复窗口后回到 64 × 28。
- Shell 内 `tput cols`、`tput lines` 读取值与状态栏一致。
- 切换到 Hosts 再返回 Local Terminal 后，Shell 会话和屏幕内容保持。
- App 与 login shell 子进程空闲 CPU 实测均为 0.0%。
- Debug/Release 产物均为 arm64，代码签名完整性验证通过。

构建环境说明：

- SwiftTerm 1.19.0 使用官方 `SwiftTermBuildInfoPlugin`；Xcode GUI 首次构建需要确认信任该插件。
- 当前 Xcode 26.6 命令行构建使用 `-skipPackagePluginValidation`，插件源码已按固定 revision 审阅。
- SwiftTerm 的 Package 资源需要 Xcode Metal Toolchain；本机已按 Xcode 提示安装 Metal Toolchain 17F109。

本阶段明确未实现：

- 多 Terminal Tab、新建/关闭/恢复会话。
- Host Manager、SSH、SFTP、libssh2、OpenSSL、Host Key 验证和凭据处理。
- SwiftData、Keychain 和设置持久化。
- Shell 退出后的自动重启或重连。

### Phase 3：Host Manager

状态：**已完成，等待用户验收**

完成日期：2026-08-27

已完成：

- 使用 SwiftData `@Model` 建立真实 `Host` 与 `HostGroup` 持久化模型。
- Host 包含 id、name、hostname、port、username、authenticationType、group、favorite、createdAt、updatedAt、lastConnectedAt、notes，以及后续阶段使用的可空 credential 引用。
- port 默认值为 22；第一版 AuthenticationType 只包含 Password 和 Private Key。
- 使用本地 SwiftData `ModelContainer` 持久化 Host 与 Group，不启用 CloudKit，不使用 Mock Data 或内存数组。
- 支持 Host 创建、编辑、删除、Group 归属、Favorite 切换和 Name/Hostname 搜索。
- 支持 Group 创建、重命名和删除；删除 Group 使用 nullify 关系规则保留其中的 Host。
- 使用原生 macOS HSplitView、List、Section、Context Menu、Form、Sheet、Toolbar 和 Searchable 构建 Hosts Sidebar 与 Host Manager UI。
- Host 编辑表单只记录认证方式，不提供密码、Passphrase、连接测试、SSH 登录或 SFTP 功能。
- SwiftData 操作使用 OSLog 记录非敏感生命周期信息，不记录 Host 名称、地址、用户名或备注。
- 保持 Phase 2 `AppState → LocalTerminalService → SwiftTerm/PTY` 生命周期不变。

验收前自测结果：

- 创建 Group 后立即出现在 Hosts Sidebar。
- 创建 Host 后立即出现在 Hosts 列表，All Hosts、Favorites 和 Group 计数同步更新。
- 编辑 Host 的 Name 与 Hostname 后列表立即显示新值。
- Host 成功归入 Group；重启后 Group 归属仍然存在。
- Favorite 可以切换，Favorites 筛选结果立即更新；重启后 Favorite 状态仍然存在。
- Search 按 Name 和 Hostname 分别实测成功。
- App 使用 `⌘Q` 完全退出并重新启动后，Host、Group、编辑结果和 Favorite 均从 SwiftData 恢复。
- Host 与 Group 删除成功，列表和计数立即更新；再次重启后删除结果仍然保持。
- 测试使用的 `Phase 3 Edited Host` 和 `Phase 3 Test Group` 已在验证后清理。
- SwiftData 数据库 schema 经只读检查，不存在 password、passphrase 或私钥内容字段；credentialID 和 privateKeyID 在 Phase 3 保持 NULL。
- Phase 2 Local Terminal 实际执行 `printf` 成功；切换 Hosts 再返回后，同一 PTY 的输出、Shell 提示符和会话保持。
- Debug arm64 干净构建成功，项目 compiler warning 为 0。
- Release arm64 干净构建成功，项目 compiler warning 为 0。
- Debug/Release 产物均为 Mach-O arm64，代码签名完整性验证通过。

构建环境说明：

- SwiftTerm 仍固定为 1.19.0，`Package.resolved` 继续提交并参与可复现构建。
- 命令行构建继续使用 `-skipPackagePluginValidation`；SwiftTerm 插件和 Metal Toolchain 要求与 Phase 2 相同。

本阶段明确未实现：

- macOS Keychain、密码或 Private Key Passphrase 保存。
- 真实 SSH Connection、SSH 登录、Test Connection、Host Key 验证或远程 Terminal。
- SFTP、Transfer、libssh2、OpenSSL 或任何 Phase 4 及后续功能。

## 下一阶段

Phase 4：Keychain。只有用户验收 Phase 3 并明确要求后才能开始。
