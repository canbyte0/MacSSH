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

状态：**已完成并通过用户验收**

完成日期：2026-08-27

验收阻塞修复日期：2026-08-28

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

验收阻塞修复结果：

- 修复 Host 行双击手势吞掉原生选择状态的问题；普通单击会更新 `selectedHostID` 并让 Host List 获得键盘焦点。
- 单击 Host 后，行状态实测为 selected，工具栏 `Edit Host` 立即启用且可打开编辑表单。
- 双击 Host 和右键编辑入口保持不变；双击实测仍可打开编辑表单。
- 单击选中后按 macOS Delete 键，实测成功弹出 `Delete Host?` 确认框；测试时选择 Cancel，未删除验收数据。
- 将无效的 `EXTRACT_APP_INTENTS_METADATA = NO` 替换为 Xcode Swift Build 实际支持的 `LM_SKIP_METADATA_EXTRACTION = YES`。
- 修复后 Debug arm64 与 Release arm64 均完成 clean build；`xcodebuild -quiet` 无输出，compiler warning 为 0。
- 修复后两个产物仍为 Mach-O arm64，严格代码签名校验通过。
- Local Terminal 实际执行并输出 `PHASE3_FINAL_TERMINAL_OK`；切换 Hosts 再返回后，同一会话和输出保持。
- 用户保留的 `Phase 3 Acceptance Host Edited` 与 `Phase 3 Acceptance Group Edited` 仍存在于 SwiftData；Favorite、Group 关联保持，credentialID/privateKeyID 仍为 NULL。

构建环境说明：

- SwiftTerm 仍固定为 1.19.0，`Package.resolved` 继续提交并参与可复现构建。
- 命令行构建继续使用 `-skipPackagePluginValidation`；SwiftTerm 插件和 Metal Toolchain 要求与 Phase 2 相同。
- App 不依赖 AppIntents.framework；通过 `LM_SKIP_METADATA_EXTRACTION = YES` 阻止不适用的 AppIntents metadata extraction task，避免 Xcode 产生跳过提示。

本阶段明确未实现：

- macOS Keychain、密码或 Private Key Passphrase 保存。
- 真实 SSH Connection、SSH 登录、Test Connection、Host Key 验证或远程 Terminal。
- SFTP、Transfer、libssh2、OpenSSL 或任何 Phase 4 及后续功能。

### Phase 4：Keychain / Credential Security

状态：**已通过用户验收**

完成日期：2026-08-28

验收日期：2026-08-28

已完成：

- 使用 Apple Security.framework `SecItem` API 建立统一 `KeychainService`，封装 Generic Password 的 save、read、update、delete 和 upsert。
- 使用 `CredentialService` 隔离 SSH Password 与 Private Key Passphrase 两类 Secret；两类凭据使用不同 service namespace。
- 使用不可编辑字段无关的 UUID 作为稳定 account；SwiftData `Host` 只保存 `credentialID` / `privateKeyID` 引用。
- Keychain item 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，不启用同步；阻塞式 SecItem 调用在专用串行队列执行。
- Host Editor 的 Password `SecureField` 已接入 Keychain；创建时保存、输入新值时更新、留空时保持、显式按钮负责移除。
- 删除 Host 时同步清理 Password 与 Private Key Passphrase，并在 SwiftData 保存失败时尽力执行凭据补偿恢复。
- 建立 `KeychainError`，把常见 OSStatus 映射为用户可理解且不回显 Secret/状态码的错误。
- 增加真实 macOS Keychain XCTest target，覆盖 Password 与 Private Key Passphrase 生命周期、类型隔离、重复项与空 Secret 错误映射。
- 更新应用阶段状态和安全日志；日志只记录凭据生命周期，不记录 Secret、Secret Data 或可关联的凭据 ID。

安全与功能验证结果：

- 创建 Password Host 后立即出现在 Host Manager；SwiftData 中只存在普通元数据与稳定 credentialID。
- 实际扫描 `MacSSH.store`、WAL 和 SHM，未发现两个测试 Secret；源代码和本文档也未发现测试 Secret。
- Password save/read/update/delete 均通过真实 Keychain 验证；更新后新值可读取，旧值不再是该 item 的值。
- App 使用 `⌘Q` 完全退出并重新启动后，Host 和 Keychain Password 均仍存在。
- 仅把 Host Name 改为验收名称且保持 Password 输入为空后，credentialID 未变化，原 Password 仍能通过 `CredentialService` 读取。
- 删除专用验收 Host 后，SwiftData 查询数量为 0；对应 `CredentialService` 读取返回 `itemNotFound`，未留下孤立 Password。
- Private Key Passphrase 的 save/read/update/delete 真实 Keychain 测试通过；没有实现私钥解析或 SSH 登录。
- 独立 Keychain XCTest 结果为 4 passed、0 failed、0 skipped。
- 实时 OSLog 只出现 saved、updated、deleted、lookup failed 等生命周期消息，未发现 Secret。
- Host Manager 的 Create、Edit、Delete、Group、Favorite、Search、Persistence 均无回归；保留的 Phase 3 Host/Group/Favorite/关联关系不变。
- Local Terminal 实际执行 `echo PHASE4_TERMINAL_OK` 成功；Hosts 与 Local Terminal 往返后 PTY 和输出保持。
- Debug arm64 与 Release arm64 均完成 clean build；两次 `xcodebuild -quiet` 无输出，项目 compiler warning 为 0。
- Debug/Release 产物均为 Mach-O arm64，严格代码签名校验通过。

构建与测试环境说明：

- SwiftTerm 仍固定为 1.19.0，`Package.resolved` 继续提交；未修改任何第三方源码。
- 临时 `test-without-building` production namespace 验证使用单独 xctestrun，因此 Xcode 输出过 run-destination 选择提示；它不是项目 compiler warning，相关临时 xctestrun/xcresult 已删除。
- 本地 `Sign to Run Locally` 的不同临时构建签名读取彼此创建的 Keychain item 时，macOS 可能要求登录钥匙串授权；同一构建完全退出并重启的持久化验证不受影响。最终删除使用创建该测试 item 的同签名验收构建完成。

用户验收端到端验证结果（2026-08-28）：

- Debug arm64 与 Release arm64 均完成 clean build，`xcodebuild -quiet` 无输出，项目 compiler warning 为 0。
- Debug/Release 产物均为 Mach-O arm64，`codesign --verify --strict` 通过（valid on disk + satisfies Designated Requirement）。
- 独立 Keychain XCTest 结果为 4 passed、1 skipped（未请求的 production 验证钩子）、0 failed。
- 通过辅助功能与 CGEvent 驱动真实 UI 完成端到端生命周期：
  - 在 Host Manager 新建带密码 Host（Password 字段进入 SecureField），Save 后 sheet 正常关闭。
  - 数据库 `ZHOST` 行出现新 Host，`ZCREDENTIALID` 非 NULL；`MacSSH.store` / WAL / SHM 三个文件中均未发现密码明文。
  - Keychain 中出现对应 Generic Password item（service=`com.macssh.MacSSH.credentials.ssh-password`，account 为 credentialID 的小写 UUID），创建时间与保存时刻一致。
  - App 进程内 XCTest（环境变量驱动 production namespace）验证 Keychain 中存储的密码与 UI 输入完全匹配。
  - App 使用 `⌘Q` 完全退出并重新启动后，Host 计数保持 2，Keychain 密码仍可通过 App 进程内 XCTest 正确读取。
  - 编辑 Host 仅修改 Name、Password 留空保存后，`ZCREDENTIALID` 保持不变，App 进程内验证密码仍可读取（密码未被覆盖）。
  - 选中 Host 后通过 Delete 键触发 `onDeleteCommand`，确认 Delete 后 sheet 关闭；数据库中该 Host 已删除，Keychain 中对应 item 已清理（`security find-generic-password` 返回 item not found），App 进程内 XCTest `expectation=missing` 通过。
- 用户保留的 Phase 3 验收 Host/Group/Favorite/Group 关联关系在本次端到端验证前后均保持，credentialID/privateKeyID 仍为 NULL，无 Phase 4 验收数据残留。
- 最近 30 分钟 OSLog（subsystem `com.macssh.MacSSH`）扫描 password/passphrase/Secret/测试密码明文均无匹配。
- 验收使用的临时构建产物与临时 UI 驱动工具已清理，工作树保持 clean。

当前已知问题：

- Phase 4 范围内未发现未解决的功能缺陷。
- 开发环境跨临时签名访问 Keychain 的系统授权行为如上；正式稳定签名发布前仍需在后续发布阶段复测。
- 端到端 UI 验收通过 macOS 辅助功能 + CGEvent 合成事件完成；正式稳定签名发布前仍建议在真实键鼠交互下复测一次。

本阶段明确未实现：

- libssh2、OpenSSL、TCP、SSH handshake 或 Password Authentication。
- Private Key 解析与认证、Host Key Verification、Known Hosts、SSH Terminal。
- SFTP、Transfer Manager、KeepAlive、Reconnect 或任何 Phase 5 及后续功能。

## 下一阶段

Phase 4 已通过用户验收（2026-08-28）。下一阶段为 Phase 5：SSH 基础连接（集成 libssh2 + OpenSSL，建立 SSHConnection，实现 TCP + Handshake + Password Authentication）。只有用户明确要求后才能开始。
