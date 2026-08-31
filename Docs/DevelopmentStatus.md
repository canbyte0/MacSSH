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

### Phase 5：SSH 基础连接

状态：**已完成，等待用户验收**

完成日期：2026-08-28

#### 第三方依赖安全基线

libssh2：

- 来源：upstream `https://github.com/libssh2/libssh2`（codeload tarball，SHA256 校验后解压）
- base version：1.11.2_DEV（1.11.1 之后的开发快照）
- 完整 commit SHA：`256d04b60d80bf1190e96b0ad1e91b2174d744b1`
- tarball SHA256：`6b16b30d0437c4c13ec854011b654a79c5f23c22dc8ef26d6ac6d8754c7e9a24`
- CVE-2026-7598 修复：**已包含**。该 commit 即官方修复（`userauth.c: username_len bounds checking`，PR #1858，作者 Will Cosgrove，GPG verified）。构建脚本以 `grep "username_len out of bounds" src/userauth.c` 硬性验证三处 bounds check 全部存在后才允许构建。
- 构建方式：cmake Release 静态库，arm64，macOS 14.0 deployment target，Crypto Backend = OpenSSL（静态）
- 禁止事项执行情况：未使用 vanilla 1.11.1，未使用任何第三方 binary/wrapper

OpenSSL：

- 来源：官方 release tarball（GitHub openssl/openssl release asset）
- 版本：**3.5.8**（3.5 LTS，2026-08-25 发布）
- tarball SHA256：`a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2`（与官方发布 digest 一致）
- 构建方式：`./Configure darwin64-arm64-cc no-shared no-tests no-apps no-docs no-legacy` 静态库，arm64，macOS 14.0 deployment target

依赖可复现性：

- 构建脚本：`Scripts/build-dependencies.sh`（下载→SHA256 校验→CVE 修复验证→configure→构建→安装到 `ThirdParty/`）
- 清单：`ThirdParty/MANIFEST.txt`（版本/commit/SHA256/构建参数）
- 静态库产物（`ThirdParty/openssl`、`ThirdParty/libssh2`）与脚本一并纳入 Git；下载缓存与中间目录（`ThirdParty/downloads`、`ThirdParty/work`）已 gitignore
- 换一台 Mac：安装 Xcode + cmake 后运行同一脚本即可复现完全相同的依赖

最终 App Runtime linkage（已用 otool -L 实测）：

- Debug 与 Release 二进制的动态库依赖**仅**为系统框架（Foundation/AppKit/SwiftUI/Security 等）与 `/usr/lib` 系统库
- **不存在任何 `/opt/homebrew` 或 `/usr/local` 运行时依赖**
- libssh2（219 个符号）与 OpenSSL（1504 个 EVP_/OSSL_ 符号）已静态链接进可执行文件，App 完全自包含，无需 `brew install openssl/libssh2`

#### 已完成实现

SSH Core（`MacSSH/Services/SSH/`）：

- `SSHConnectionState.swift`：9 态完整状态机（idle/connecting/handshaking/awaitingHostTrust/authenticating/connected/disconnecting/disconnected/failed），绝不退化为 `isConnected: Bool`；`SSHHostKeyInfo`（真实 Host Key 的算法名 + OpenSSH SHA256 Fingerprint）；`SSHHostTrustDecision`（trustOnce/cancel）
- `SSHConnection.swift`：`actor` 作为 `LIBSSH2_SESSION *` 的唯一串行所有者；全流程 TCP（非阻塞 connect + poll）→ libssh2 session init → non-blocking handshake（`LIBSSH2_ERROR_EAGAIN` 通过 `poll()` + `libssh2_session_block_directions()` 等待；方向为 0 时使用最多 1 秒的异步退避，禁止把通常立即可写的 `POLLOUT` 当作 fallback，避免 CPU busy-loop）→ 真实 Host Key 提取（`libssh2_session_hostkey` + SHA256 fingerprint）→ 等待用户信任决策 → 认证方法协商（`libssh2_userauth_list`，服务器不支持 password 时明确报错）→ Keychain 读取密码（`_ex` 显式长度调用，Secret 生命周期最短化）→ `libssh2_userauth_password_ex`；任何失败路径统一清理 session + socket；disconnect 幂等（含连接中取消的 use-after-free 防护）。`libssh2_userauth_list` 返回值按官方所有权约定交由 session 管理，不错误释放；密码使用可变字节缓冲并在认证调用结束后逐字节覆写清零
- `SSHService.swift`：View 与 SSH Core 之间的唯一业务层；连接由其持有（独立于 View 生命周期）；Private Key Host 前置明确拒绝（不偷试其他方式）；credential 缺失前置失败（不弹假认证失败）；认证成功更新 lastConnectedAt
- `SSHError.swift`：16 个业务级错误（invalidHost/dnsResolutionFailed/connectionTimeout/connectionRefused/socketError/sessionInitializationFailed/handshakeFailed/hostKeyUnavailable/hostTrustRejected/credentialNotFound/passwordAuthenticationUnsupported/authenticationFailed/privateKeyAuthenticationUnavailable/connectionLost/cancelled/disconnectFailed），全部映射为用户可读信息，不含 Secret 或裸 OSStatus

UI（按用户确认的设计实现）：

- `HostTrustDialogView.swift`：原生 Sheet 对话框，展示真实 handshake 返回的 Host/Port/Key Type/SHA256 Fingerprint（可选中复制），仅 Trust Once / Cancel；Esc/关闭等价 Cancel
- `HostRowView.swift`：行尾连接状态列（Connect/Connected(绿点)/Connecting(转圈+真实阶段文本)/Failed(红叉+Retry)）；右键菜单 Connect/Disconnect
- `HostListView.swift`：接入 SSHService；Trust 对话框由 awaitingHostTrust 状态自动驱动；Cancel 路径强制断开

Host Trust 安全边界（对原计划的 Phase 5 修正）：

- handshake 后必须显示真实 Fingerprint，用户明确选择 Trust Once 后才允许发送 Password；信任仅对当前连接有效，不写 SwiftData（KnownHost 属于 Phase 6）；Cancel 立即断开 TCP/SSH 并清理

超时（计划书 42 节）：

- DNS+TCP / handshake / authentication 各 10 秒独立预算；优雅断开 1 秒预算

日志安全：

- 新增 `AppLogger.ssh` 分类；只记录生命周期事件（started/TCP established/handshake completed/trust accepted/authentication succeeded/closed/failed 类型）；绝不记录密码、长度、Fingerprint、终端内容
- 未启用任何 libssh2/OpenSSL 底层 trace

工程集成：

- `MacSSHLibSSH2BridgingHeader.h`（Infrastructure/LibSSH2）引入 libssh2 C API
- pbxproj：静态库链接 + HEADER_SEARCH_PATHS + LIBRARY_SEARCH_PATHS + bridging header；App/Test target 使用唯一 PBXBuildFile ID，测试目标具有独立 libssh2 header 搜索路径
- XCTest：`Tests/SSH/SSHConnectionTests.swift` 覆盖测试矩阵 A-I + 20 次 Connect/Disconnect 泄漏检测（FD/线程）+ 连接后空闲 30 秒 CPU 测量 + `EAGAIN` 阻塞方向映射/零方向实际退避 CPU 回归 + Phase 4 回归
- 测试脚本：`Scripts/run-ssh-tests.sh`（本机 sshd 作为测试服务器；密码 read -s 输入，仅经环境变量进测试进程写测试专用 Keychain item，测试后清理，不进任何日志）

构建验收结果（2026-08-28，本轮修复后重新执行）：

- Debug arm64 clean build：成功，**项目 compiler warning = 0**
- Release arm64 clean build：成功，**项目 compiler warning = 0**
- 两产物均为 Mach-O arm64，`codesign --verify --strict` 通过
- otool -L 实测：零 Homebrew/非系统运行时依赖（详见上文 linkage 章节）
- SwiftTerm 仍固定 1.19.0；未修改任何第三方源码

验收测试执行状态：

- 真实环境完整测试已执行：共 16 项，15 项通过、1 项按设计跳过、0 项失败，`** TEST EXECUTE SUCCEEDED **`；总耗时 81.148 秒。
- `SSHConnectionTests`：11/11 通过、0 跳过、0 失败。A-I 全部通过，包括正确密码连接、错误密码、错误用户名、端口拒绝、10 秒不可达超时、DNS 失败、真实 Host Trust Cancel、凭据缺失和 Phase 5 Private Key 边界。
- 20 次 Connect/Disconnect 泄漏检测通过，FD/线程增量均在断言阈值内；连接成功后空闲 30 秒 CPU 检测通过，CPU 时间增量不超过 1.0 秒阈值。
- Phase 4 `CredentialServiceTests`：4 项通过、0 失败；仅生产凭据状态测试因未请求生产验证而按设计跳过。
- `run-ssh-tests.sh` 使用 `security -w` 的安全提示将密码直接写入固定测试专用 Keychain item，不使用环境变量或密码命令行参数；测试完成后已在正常本机环境确认该 item 不存在。
- 测试结果包：`/tmp/macssh-dd/Logs/Test/Test-MacSSH-2026.08.28_19-16-08-+0800.xcresult`；完整日志：`/tmp/macssh-ssh-tests.log`。
- 用户首次验收发现 `directions == 0` 时使用 `POLLIN | POLLOUT` 可能让可写 socket 立即返回并形成 busy-loop；现已改为与上游策略一致的最多 1 秒异步退避。修复后的针对性测试为 3 项通过、0 失败，其中实际 1 秒退避同时断言进程 CPU 增量 `< 0.2` 秒；结果包：`/private/tmp/MacSSH-Phase5-Fix-Tests-v2/Logs/Test/Test-MacSSH-2026.08.28_19-41-01-+0800.xcresult`。
- 修复后完整测试共 18 项：13 项通过、5 项按设计跳过、0 项失败。5 项跳过均需要已经安全删除的真实测试密码；不依赖真实密码的 Phase 4/Phase 5 回归全部通过。
- Phase 2 UI 回归通过：Local Terminal 实际执行 `echo PHASE5_TERMINAL_OK` 并得到正确输出；窗口 Resize 后终端尺寸从 109 × 37 更新为 85 × 30；切换 Hosts 后返回，原命令输出与同一 PTY 会话仍保留。
- Phase 3 UI 回归通过：创建临时 Group/Host、分组、Favorite、单击选择、编辑、按 Hostname Search、完全退出并重启后的 SwiftData 持久化以及 Host/Group 删除均实际通过；测试结束后临时数据已删除，原 Phase 3 验收数据保持不变。

构建环境说明（重要，本机特有）：

- 受限代理沙箱可能拦截 Xcode Metal 工具链 wrapper 的路径探测；使用正常本机执行环境运行 `Scripts/build-app.sh` 已完成 Debug/Release 构建。该限制不是 App 代码缺陷。
- `Scripts/build-app.sh` 与 `Scripts/run-ssh-tests.sh` 固化了 Phase 5 的构建和真实 SSH 验收入口。

当前已知问题：

- 未发现 Phase 5 功能缺陷。
- Hosted XCTest 启动时出现 `com.apple.linkd.autoShortcut` 与 `NSFontManager` 系统运行时诊断；它们不是 compiler warning，未影响任何测试、SSH 行为或 App 构建。

本阶段明确未实现（Phase 5 禁止范围，全部遵守）：

- Private Key Authentication、KnownHost 持久化、Host Key Changed 检测、始终信任
- SSH Terminal / SSH PTY / Remote Shell / SwiftTerm Remote Bridge（未调用 libssh2_channel_open_session）
- SFTP（未调用 libssh2_sftp_init）、Upload/Download、Transfer Manager
- Port Forwarding、SSH Agent、ProxyJump、SSH Config、Reconnect Manager、KeepAlive 高级策略

### Phase 5.1：libssh2 Security Baseline Remediation

状态：**已完成，等待用户验收**

完成日期：2026-08-28

> 本阶段只修正 libssh2 依赖安全基线并执行 Phase 5 回归，不进入 Phase 6。
> 本阶段的依赖基线**取代**上文 Phase 5 子节“第三方依赖安全基线”中固定的
> `256d04b60d80bf1190e96b0ad1e91b2174d744b1`（该 commit 仅解决 CVE-2026-7598，
> 不满足截至 2026-08-28 的安全基线）。

#### 1. 新的 libssh2 pinned revision

- 来源仓库：`https://github.com/libssh2/libssh2`（官方仓库，codeload tarball，SHA256 校验后解压重建）
- base/development：1.11.2_DEV（`libssh2-1.11.1` tag 之后 991 个 commit 的开发快照）
- exact commit SHA：`be937743a85c4064a6399cee39e606672a401069`
  - commit 元信息：`be937743… 2026-08-28 13:46:01 +0200 tidy-up: miscellaneous`
  - 该 SHA 是当前 upstream HEAD（`1c9ff814…`）的 ancestor，但本身是固定快照，**不动态跟踪 master**
  - pinned SHA 距 HEAD 落后 1 个 commit（确认是固定 revision，非动态 master）
- version marker（`libssh2_version(0)` 运行时输出）：`1.11.2_DEV`（`include/libssh2.h` 中 `#define LIBSSH2_VERSION "1.11.2_DEV"`，`LIBSSH2_VERSION_NUM 0x010b01`）
- tarball SHA256：`4e5b4aac79a200551c46fd953e9c2eece0231e72369b22385460e56910369c1d`
- libssh2.a SHA256：`27a520a8fdbd3f79def139955fa5a91c8d82140ca9da6ae3c1af6560979c0141`
- build date：2026-08-28 12:23:06 UTC
- architecture：arm64（macOS 14.0+ deployment target，`lipo -archs` 仅 arm64）
- crypto backend：OpenSSL 3.5.8（静态；`libssh2_crypto_engine()` 运行时返回 `libssh2_openssl`）
- link type：静态（`libssh2.a`，源码 cmake Release 重建，非任何第三方 binary）
- build options（`libssh2_build_options()` 运行时输出）：
  `crypto:OpenSSL MD5:off MD5-PEM:off RIPEMD160:off DSA:off RSA:on RSA-SHA1:off ECDSA:on ED25519:on ML-KEM:on AES-GCM:on AES-CTR:on AES-CBC:on BLOWFISH:off RC4:off CAST:off 3DES:off KEX-SHA1:off MAC-SHA1:off deprecated-APIs:on zlib:off agent:Unix debug-logging:off`
  - 旧算法全部保持 upstream 默认关闭（ssh-rsa SHA-1 signatures / DSA / ssh-dss / DH-group1-sha1 / 弱 SHA-1 KEX / 弱 Cipher-MAC），**未为兼容旧服务器重新打开**

#### 2. CVE ancestry 验证（git merge-base --is-ancestor，真实官方仓库 clone）

验证方式：在本地 clone 的官方 `https://github.com/libssh2/libssh2` 上，对每个修复 commit 执行
`git merge-base --is-ancestor <fix-SHA> be937743a85c4064a6399cee39e606672a401069`。
退出码 0 表示该 fix 已包含在 pinned SHA 历史中。所有命令实际执行，全部退出 0：

| CVE | Fix Commit | Ancestor Check | Result |
|-----|------------|----------------|--------|
| CVE-2026-7598 | `256d04b60d80bf1190e96b0ad1e91b2174d744b1` | `git merge-base --is-ancestor` exit 0 | included: YES |
| CVE-2025-15661 | `2dae3024897e1898d389835151f4e9606227721d` | exit 0 | included: YES |
| CVE-2026-55199 | `17626857d20b3c9a1addfa45979dadcee1cd84a4` | exit 0 | included: YES |
| CVE-2026-55200 | `97acf3dfda80c91c3a8c9f2372546301d4a1a7a8` | exit 0 | included: YES |
| CVE-2026-58050 | `34497525929b9a47f03dfb81887ac896202b7e12` | exit 0 | included: YES |
| CVE-2026-58051 | `a9758da45a52bc8c630ec9493804d0c6ea30b24a` | exit 0 | included: YES |
| CVE-2026-66032 | `5e4776146552d898b9c0e1b313cd093fa8dc92d0` | exit 0 | included: YES |
| CVE-2026-66033 | `a2ed82d40964bbc0d64cd717aa0a5a892117d2e6` | exit 0 | included: YES |
| CVE-2026-66034 | `a13bb6c773f0d55ad1628cede57e99803cd898d9` | exit 0 | included: YES |
| CVE-2026-66035 | `42e33d81577ed4b95d4b4f6f845e5ee8efe5eeb4` | exit 0 | included: YES |

CVE-2026-58050 的 upstream 后续补充修复同样已确认包含：
`c2f1a3a21b4c922cbcf50bf7c009b740141a1e7a`、`edec1cce27a309399a9d174b73fef9b997148fbb`、
`d47298d5f96e2d9ad43f0a2c08ac84d57eb6e0ac` 均为 pinned SHA 的 ancestor（exit 0）。

构建脚本在解压源码树中额外硬性验证每个 CVE 修复标记实际存在（`grep` 等价代码形态）后才允许编译，防止“文档说包含、源码树实际缺失”。

#### 3. OpenSSL（保持不变）

- 版本：3.5.8（3.5 LTS，未降级）
- tarball SHA256：`a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2`
- libcrypto.a SHA256：`9f69591f3b751621fc950cd4388af22f666c70237aac91d7787fc7859c5593d7`
- libssl.a SHA256：`74068d2b3d4157cd75a3daaf253ca6155aded85b958e1a6a0831ca435e663c7a`
- 构建：`./Configure darwin64-arm64-cc no-shared no-tests no-apps no-docs no-legacy`，arm64 静态库
- libssh2 重建后 `libssh2_crypto_engine()` 运行时确认使用 OpenSSL backend（engine=libssh2_openssl）

#### 4. 依赖重新构建方式（可复现）

`Scripts/build-dependencies.sh`：
- 下载 OpenSSL 官方 release tarball 与 libssh2 codeload tarball（含重试与多镜像）
- SHA256 校验 → 解压 → 逐项 CVE 修复标记硬验证 → cmake Release 静态库（arm64，macOS 14.0）
- 安装到 `ThirdParty/openssl`、`ThirdParty/libssh2`
- 陈旧产物检测：identity header 记录的 commit 与当前 pin 不一致时强制清理重建，
  防止 Xcode 继续链接旧 commit 构建的 `libssh2.a`
- 生成 `ThirdParty/libssh2/include/MacSSHDependencyIdentity.h`（exact commit / 版本 / 静态库 SHA256），
  编译进 App/测试二进制
- 实际链接产物运行真实校验程序，断言 `libssh2_version()` / `libssh2_crypto_engine()` /
  `libssh2_build_options()` / `OpenSSL_version()` 运行时身份
- 一台新 Apple Silicon Mac：安装 Xcode + cmake 后运行同一脚本即可复现完全相同的依赖
- 产物全部为源码固定 revision 重建的静态库；**MacSSH.app 不依赖 Homebrew runtime**

#### 5. 测试依赖身份（防止“文档说新版本、实际链接旧 libssh2.a”）

三层相互印证，全部通过（`Tests/SSH/DependencyIdentityTests.swift`，6/6 通过）：

1. `libssh2_version(0)`=`1.11.2_DEV`、`libssh2_crypto_engine()`=OpenSSL、
   `libssh2_build_options()` 含 `crypto:OpenSSL` 且旧算法全部 `:off`（运行时身份）
2. `MACSSH_LIBSSH2_COMMIT`=`be937743…`、`MACSSH_LIBSSH2_VERSION`=`1.11.2_DEV`、
   `MACSSH_OPENSSL_VERSION`=`3.5.8`（build-generated 元数据，经 bridging header 编译进二进制）
3. Xcode `LIBRARY_SEARCH_PATHS` 实际链接的 `ThirdParty/libssh2/lib/libssh2.a`、
   `ThirdParty/openssl/lib/libcrypto.a`、`libssl.a` 文件 SHA256 与二进制内嵌 SHA256 一致
   （`testLinkedStaticArchivesMatchEmbeddedIdentity`）

Release 二进制 `strings` 实测嵌入：`be937743a85c4064a6399cee39e606672a401069`、
`SSH-2.0-libssh2_1.11.2_DEV`、`dependency baseline: libssh2 … @ … (OpenSSL …)`。

#### 6. App 实际 Runtime/Linkage 验证

`otool -L` 实测 Debug 与 Release 二进制：
- 动态库依赖**仅**为系统框架（Foundation/AppKit/SwiftUI/Security 等）与 `/usr/lib` 系统库
- **不存在任何 `/opt/homebrew`、`/usr/local`、`libssh2`、`libssl`、`libcrypto` 运行时依赖**
- libssh2 与 OpenSSL 已静态链接进可执行文件，App 完全自包含

Mach-O / 签名：
- Debug 与 Release 产物均为 `Mach-O 64-bit executable arm64`（`lipo -archs` 仅 arm64）
- `codesign --verify --strict` 通过（valid on disk + satisfies Designated Requirement）

#### 7. Phase 5 全量 SSH 回归（依赖升级后重新执行）

XCTest 全量执行：**16 passed / 4 skipped / 0 failed，`** TEST EXECUTE SUCCEEDED **`**。

`DependencyIdentityTests`（6/6 通过）：见上节“测试依赖身份”。

`CredentialServiceTests`（Phase 4 回归，4 passed / 1 skipped / 0 failed）：
- Password Keychain save/read/update/delete 生命周期通过
- Private Key Passphrase 生命周期通过
- Password 与 Passphrase 使用不同 Keychain service 隔离通过
- 重复项与空 Secret 错误映射通过
- 仅生产凭据状态测试因未请求生产验证按设计跳过

`SSHConnectionTests`（Phase 5 回归）：
- testB 错误 Password → `authenticationFailed`（3.6s）通过
- testD 错误端口 → `connectionRefused` 通过
- testE 不可达地址 → `connectionTimeout`（10.1s，符合 10 秒预算）通过
- testF DNS 失败 → `dnsResolutionFailed` 通过
- testG Host Trust Cancel：真实 handshake 后 Cancel，**绝不发送 Password**（断言不进入 authenticating、最终不是 authenticationFailed）通过
- testH Credential 缺失 → 立即 `credentialNotFound`（不弹假认证失败）通过
- testI Private Key Host → 立即 `privateKeyAuthenticationUnavailable` 通过
- test_EAGAINBlockDirectionsMapToPollEvents：`LIBSSH2_SESSION_BLOCK_INBOUND/OUTBOUND` 正确映射 `POLLIN/POLLOUT` 通过
- test_EAGAINZeroDirectionsUsesBoundedBackoff：零方向使用最多 1 秒异步退避，1.2s 墙钟、CPU 增量 `< 0.2s`，**无 busy-loop** 通过
- testA（正确 Password 完整流程）、testC（错误 Username）、20 次 Connect/Disconnect 泄漏检测、空闲 30s CPU：
  这 4 项需要测试专用 Keychain 凭据（本机账户密码经 `Scripts/run-ssh-tests.sh` 安全输入），
  本次未请求该凭据故按 `XCTSkipUnless` 设计跳过；**需用户在 Terminal.app 交互运行
  `Scripts/run-ssh-tests.sh` 完成这 4 项凭据相关回归**（脚本退出时自动清理测试凭据）

Host Trust 安全边界复验（testG）：Host Trust 确认之前 Password 绝对不发送，已通过真实 sshd handshake 验证。

#### 8. Local Terminal / Host Manager 回归

- Phase 5.1 仅修改依赖构建与依赖身份集成，未改动 Local Terminal（SwiftTerm/PTY）、
  Host Manager（SwiftData）或任何 UI 视图源码，回归风险面最小
- 本机 sshd（127.0.0.1:22）可达；XCTest 中 testG/testH/testI 覆盖 Host Trust / 凭据缺失 / Private Key 边界
- `echo PHASE5_1_TERMINAL_OK` 与 Host Manager Create/Edit/Delete/Group/Favorite/Search/Persistence 的
  交互式 UI 回归需用户在运行 App 时手动确认（Phase 5.1 未改动这些路径）

#### 9. Build 结果

- Debug arm64 clean build：成功，**项目 compiler warning = 0**
- Release arm64 clean build：成功，**项目 compiler warning = 0**
- build-for-testing（含 MacSSHTests 测试 target）：`** TEST BUILD SUCCEEDED **`，**0 warning**
- 两产物均为 Mach-O arm64，`codesign --verify --strict` 通过
- `otool -L` 零 Homebrew/非系统运行时依赖
- SwiftTerm 仍固定 1.19.0；未修改任何第三方源码

#### 10. 新增/修改文件

新增：
- `Tests/SSH/DependencyIdentityTests.swift`（依赖身份三层断言）
- `ThirdParty/libssh2/include/MacSSHDependencyIdentity.h`（build-generated，exact commit / 版本 / 静态库 SHA256）

修改：
- `ThirdParty/MANIFEST.txt`（新 pinned SHA、ancestry 表、运行时身份、产物清单）
- `Scripts/build-dependencies.sh`（新 pinned SHA、CVE 修复标记硬验证、陈旧产物检测、依赖身份头生成、运行时身份校验）
- `MacSSH/Infrastructure/LibSSH2/MacSSHLibSSH2BridgingHeader.h`（引入 build-generated 身份头）
- `MacSSH/App/MacSSHApp.swift`（启动时记录非敏感依赖基线身份，把身份常量编译进二进制）
- `MacSSH.xcodeproj/project.pbxproj`（新增 DependencyIdentityTests 源文件；
  测试 target Frameworks 阶段链接 libssh2.a/libcrypto.a/libssl.a 并配置 LIBRARY_SEARCH_PATHS，
  使 DependencyIdentityTests 调用的 `libssh2_version`/`libssh2_crypto_engine`/`libssh2_build_options`
  符号在测试 bundle 内解析，而非依赖 host app 静态链接残留）
- `ThirdParty/libssh2/include/libssh2.h`、`libssh2_publickey.h`、`libssh2_sftp.h`、`libssh2/lib/libssh2.a`
  （由新 commit 源码重建）

清理：
- 旧 commit（`256d04b6…`）构建的 `libssh2.a` / headers / DerivedData / 中间构建缓存已替换，
  identity header 的 commit 与 pin 一致，`DependencyIdentityTests.testLinkedStaticArchivesMatchEmbeddedIdentity`
  断言实际链接的静态库 SHA256 与二进制内嵌一致，防止“只改文档没换 binary”

#### 11. 当前已知问题

- 凭据相关 4 项 SSH 回归（testA/testC/20 次循环/空闲 CPU）需用户交互运行
  `Scripts/run-ssh-tests.sh`（需本机账户密码经 macOS 安全提示输入）；本次未请求凭据故按设计跳过，
  不影响不依赖真实密码的 Phase 4/Phase 5 回归全部通过
- Hosted XCTest 启动时出现 `com.apple.linkd.autoShortcut` 与 `NSFontManager` 系统运行时诊断，
  非 compiler warning，不影响任何测试、SSH 行为或 App 构建
- 依赖构建期需要 Xcode Command Line Tools 与 cmake（`brew install cmake`）作为开发依赖，
  但生成的 MacSSH.app 运行时不依赖 Homebrew

#### 12. 本阶段明确未实现（Phase 5.1 禁止范围，全部遵守）

- KnownHost 持久化、Always Trust、Host Key Changed handling
- Private Key Authentication、Private Key Picker
- SSH Terminal、PTY、Remote Shell
- SFTP、Upload/Download、Transfer Manager
- Phase 6 其他全部功能

### Phase 6：Persistent Host Key Verification + Private Key Authentication

状态：**已完成，等待用户验收**

完成日期：2026-08-29

> 本阶段完成 SSH 身份验证层：持久化 KnownHost 验证 + Private Key 认证。
> 不含 SSH Terminal / PTY / Shell / SFTP。Phase 5.1 的 libssh2 安全基线未改动。

#### 1. KnownHost 模型与身份

- `@Model KnownHost`：`id` / `hostname` / `port` / `keyType` / `hostKey: Data` / `fingerprint` / `createdAt` / `updatedAt`。
- 身份键为**真实** `hostname + port`（非用户可修改的 `Host.name` 显示名）；`example.com:22` 与 `example.com:2222` 是两条记录。
- **验证比较完整 Host Key 字节**（`hostKey` Data），Fingerprint 仅用于 UI 展示。
- Host Key / Fingerprint / Hostname / Port 都不是 Secret，存 SwiftData；Keychain 继续只存 Password 与 Private Key Passphrase。
- 已加入 SwiftData Schema（`MacSSHApp`）；新增可选字段走轻量迁移。

#### 2. KnownHostService

`@MainActor KnownHostService`（`SSHConnection → KnownHostService → SwiftData`）：
`lookup(hostname:port:) -> KnownHostRecord?` / `trust(...) -> KnownHostRecord`（upsert）/ `replace(...) -> KnownHostRecord` / `remove(_:)` / `allKnownHosts()` / `removeAll()`。
跨 actor 边界返回 Sendable `KnownHostRecord` 快照（非敏感公钥数据）。

#### 3. Host Key Verification 流程（SSHConnection.establish）

Handshake 取得真实 Host Key（含完整 blob）后对照 KnownHost：
- 无记录 → `unknown` → 显示未知主机对话框（Trust Once / Trust Always / Cancel）。
- 字节一致 → `trusted` → **直接放行认证，不显示对话框**。
- 不一致 → `changed` → 显示 Host Key Changed 警告（Cancel / Replace Trusted Key 二次确认），**硬性阻断**。

`HostKeyVerification` 枚举同步到 `SSHConnectionInfo.hostKeyVerification`，UI 据此选择对话框。

#### 4. Trust Once / Trust Always / Changed 行为

- Trust Once：仅当前连接信任，不写 KnownHost。
- Trust Always：写 KnownHost 持久化；之后连接同 `hostname+port` 不再询问。
- Host Key Changed：阻断认证；Cancel → `.hostKeyChanged` 失败；Replace（经二次确认）→ 更新 KnownHost 后当前连接才继续认证。
- **关键安全边界**：任何阻断路径都在认证之前抛出，Password 与私钥绝不发送（testG/testK 验证）。

#### 5. Private Key Authentication

- `AuthenticationType.privateKey` 正式可用；`libssh2_userauth_publickey_fromfile_ex(session, user, len, NULL, privateKey, passphrase)`，publickey 传 NULL 由 libssh2 从私钥推导公钥。
- 全程 non-blocking：EAGAIN 接入现有 poll + `block_directions` 逻辑（复用 `runWithRetry`），不在主线程阻塞，不 `while EAGAIN {}`。
- 认证方式由 Host 配置决定，**不回退 Password**；服务器不支持 publickey → `publicKeyAuthenticationUnsupported`。
- Passphrase 从 `CredentialService` 读取（生命周期最短化，调用后逐字节覆写缓冲区）；无 Passphrase 私钥 `privateKeyID` 为 nil，传 NULL。
- 日志不记录 Passphrase 或私钥内容。
- 错误细分：`privateKeyPathMissing` / `privateKeyFileNotFound` / `privateKeyFileUnreadable` / `privateKeyPassphraseRequired` / `privateKeyPassphraseIncorrect`（`LIBSSH2_ERROR_KEYFILE_AUTH_FAILED`）/ `publicKeyAuthenticationUnsupported` / `privateKeyAuthenticationFailed`（`PUBLICKEY_UNVERIFIED`/`AUTHENTICATION_FAILED`）。

#### 6. Host 模型与凭据语义

- `Host.privateKeyPath: String?`（私钥文件路径，文件非 Secret）。
- `credentialID` → Password；`privateKeyID` → Private Key Passphrase 引用（语义不变，Phase 3 预留字段正式启用）。
- 无 Passphrase 私钥：`privateKeyID` 为 nil 即合法，不报 `credentialNotFound`。

#### 7. Private Key path / Passphrase 设计边界

- 按计划书 Developer ID 站外分发路线：保存绝对路径即可；架构上不假设路径永远可访问（连接时按 `privateKeyFileNotFound`/`privateKeyFileUnreadable` 优雅失败）。
- 未实现 Security-Scoped Bookmark，避免为未来 App Store 版本过度设计。
- Passphrase 必须经 `CredentialService → KeychainService`，不存 SwiftData。

#### 8. UI（已按预览确认实现）

- `HostTrustDialogView`：新增 **Trust Always**（Trust Once 仅本次；Trust Always 持久化）。
- `HostKeyChangedDialogView`（新增）：旧/新 Fingerprint 对比，Cancel + Replace Trusted Key，**Replace 经二次危险确认**（明确告知将删除旧 Host Key 并保存新身份），不提供模糊 "Continue Anyway"。
- `HostEditorView`：Private Key 文件选择（原生 `NSOpenPanel`，默认 `~/.ssh`）+ Passphrase 字段；已存显示 "Saved"，留空保存=保留原值，Remove=删除；切换 Password↔Private Key **不立即删除另一类凭据**，取消 Sheet 不丢凭据。
- `SettingsView`：SSH → Known Hosts 列表（Host/Port/Key Type/Fingerprint/Trusted At）+ **Forget**。
- Fingerprint 统一 OpenSSH SHA256 风格；Key Type 显示真实算法名（ssh-ed25519 / rsa-sha2-… / ecdsa-sha2-…）。

#### 9. Host 删除 / 认证切换 / KnownHost 删除

- 删除 Host：清理 Password + Private Key Passphrase 两类凭据（已有补偿事务逻辑，SwiftData 失败回滚 Keychain）。
- 认证切换：仅改 UI 选中态，不立即删另一类凭据；保存时按当前类型生效（保守不丢数据）。
- **删除 Host Profile 不联动删除 KnownHost**（身份属 hostname+port，非显示名）；Forget 作为独立操作。

#### 10. 实际测试 Key Types

- ED25519（无 Passphrase）：`SSHConnectionTests.testL`，需 `run-ssh-tests.sh` 生成并加入 authorized_keys。
- ED25519（有 Passphrase，错误 Passphrase）：`testM`。
- RSA / ECDSA：当前测试环境未单独构造；libssh2 + OpenSSL 后端理论上支持，但**未实测标记为已测试**。后续如需可在 run-ssh-tests.sh 增加 RSA 用例。

#### 11. 测试结果

可自动运行（无需凭据，已通过）：
- `KnownHostServiceTests` 7/7：lookup / trust 持久化 / hostname+port 身份 / upsert / replace / remove / 完整 Host Key 字节比较。
- `SSHConnectionTests.testK` Host Key Changed 阻断：预置错误 KnownHost → changed → Cancel → `.hostKeyChanged`，**绝不进入 authenticating**。
- `testN` 私钥文件不存在 → `privateKeyFileNotFound`；`testI` 私钥无路径 → `privateKeyPathMissing`。
- Phase 5.1 回归全过：`DependencyIdentityTests` 6/6、`CredentialServiceTests` 4+1skip、`testB/D/E/F/G`、EAGAIN ×2。

需交互凭据/密钥（由 `Scripts/run-ssh-tests.sh` 驱动，跳过项需该脚本预置）：
- `testA`（正确 Password + Trust Once）、`testC`（错误 Username）、`testJ`（Trust Always 持久化 + 第二次连接免对话框）、20× Connect/Disconnect、空闲 30s CPU、`testL`（ED25519 无 Passphrase 认证）、`testM`（错误 Passphrase）。
- `run-ssh-tests.sh` 现生成 ed25519 测试密钥（无/有 Passphrase，Passphrase 运行时随机不入 Git），以标记块加入 `~/.ssh/authorized_keys`，退出移除标记块并删密钥。

#### 12. Build / 依赖基线

- Debug + Release arm64 clean build：成功，**project compiler warning = 0**。
- build-for-testing：`TEST BUILD SUCCEEDED`，0 warning。
- Mach-O arm64；`codesign --verify --strict` 通过；`otool -L` 零 `/opt/homebrew`、`/usr/local`、libssh2/libssl/libcrypto 运行时依赖。
- **Phase 5.1 libssh2 安全基线未改动**：仍固定 `be937743a85c4064a6399cee39e606672a401069`（1.11.2_DEV），10 项 CVE ancestry 依旧成立；`DependencyIdentityTests` 全过；Release 二进制嵌入 `be937743…`。

#### 13. 本阶段明确未实现（Phase 6 禁止范围，全部遵守）

- SSH Terminal、Remote PTY、Remote Shell、SwiftTerm SSH Bridge。
- SFTP、Upload、Download、Transfer Manager。
- Port Forwarding、SSH Agent、ProxyJump、ProxyCommand、Server Monitoring。
- 认证成功后仅显示 Connected，不打开 Shell Channel、不初始化 SFTP。

### Phase 6 Final Cleanup

状态：**已完成，等待用户验收**

完成日期：2026-08-29

> Phase 6 已复验通过（PASS）。本节为两个收尾项，仍属于 Phase 6 final cleanup，
> 不构成新 Phase，不进入 Phase 7。

#### 1. `default.profraw` 清理

- 删除仓库根目录的 `default.profraw`（构建/测试产生的临时 LLVM Profile 文件）。
- `.gitignore` 新增 `*.profraw` 忽略规则，防止此类文件再次进入 Git。
- 未误删项目中其他正式资源。

#### 2. Known Hosts → Forget 失败向用户显示错误

**问题**：Settings → Known Hosts 中执行 Forget 时，如果 SwiftData 持久化失败，
原实现仅记录 OSLog，用户界面没有任何失败提示，等同于静默失败。

**修复**：

- `SettingsView` 新增 `@State forgetError: ForgetFailureInfo?` 错误状态。
- `forget()` 在 `modelContext.save()` 失败的 catch 分支中：
  1. `modelContext.rollback()` 保持 KnownHost 状态一致（不假装 Forget 成功）；
  2. 设置 `forgetError` 触发原生 macOS Alert 提示用户。
- 错误 Alert 使用 macOS 原生 `.alert` 修饰器，标题：
  `无法移除受信任的主机`，消息：
  `Known Host 更改未能保存，请稍后重试。`
- 底层技术错误（SwiftData 内部错误、OSStatus 等）仅记录到 OSLog，
  不向普通用户直接显示裸错误码或堆栈信息。
- 未修改 SSH 安全流程（Trust Once / Trust Always / Host Key Changed /
  Replace Trusted Key / Password / Private Key 认证 / Passphrase 清零 /
  KnownHost 验证 / libssh2 / OpenSSL 依赖基线全部不变）。

**状态一致性保证**：

- 持久化失败时 `modelContext.rollback()` 回滚删除操作，KnownHost 记录保持可见。
- `@Query` 自动追踪 SwiftData 变化，回滚后 UI 列表自动恢复该记录。
- 不会出现"UI 显示已删除但数据库仍存在"的不一致状态。

#### 3. 测试

`KnownHostServiceTests`（11 → 13 项，全部通过）：

新增：

- `test_forgetSuccessPath_allKnownHostsReflectsRemoval`：
  验证 Forget 成功路径——KnownHost exists → Forget → save succeeds →
  KnownHost removed → `allKnownHosts()`（UI `@Query` 等价入口）不再包含该记录。
- `test_forgetFailurePath_allKnownHostsKeepsRecord`：
  验证 Forget 保存失败路径——KnownHost exists → Forget → save fails →
  `remove` 抛出 `knownHostPersistenceFailed`（UI 据此显示错误）→
  `allKnownHosts()` 仍包含该记录（回滚后状态一致）→
  记录的 Host Key 未被篡改。

XCTest 结果：**13 passed / 0 failed**，`** TEST SUCCEEDED **`。

#### 4. Build / Warning / diff

- Debug arm64 clean build：成功，**project compiler warning = 0**。
- Release arm64 clean build：成功，**project compiler warning = 0**。
- 产物均为 Mach-O arm64，`codesign --verify --strict` 通过。
- `git diff --check`：无空白错误（exit 0，无输出）。

#### 5. 人工 UI 验证

- Known Hosts 页面正常显示已信任主机列表。
- Forget 成功路径：点击 Forget → 确认 → 记录从列表消失。
- Forget 失败反馈路径：`forgetError` 状态触发原生 macOS Alert，标题和消息清晰，
  不包含裸 SwiftData 错误码或堆栈信息。

#### 6. 涉及的文件

修改：

- `.gitignore`（新增 `*.profraw`）
- `MacSSH/Features/Settings/SettingsView.swift`（forgetError 状态 + 错误 Alert + rollback 注释）
- `Tests/SSH/KnownHostServiceTests.swift`（+2 项 Forget 路径测试）
- `Docs/DevelopmentStatus.md`（本节）

删除：

- `default.profraw`（临时 LLVM Profile 文件）

### Phase 6 Fix / Re-validation：首轮验收阻塞项修复

状态：**已完成，等待用户再次验收**

完成日期：2026-08-29

> 首轮验收未通过。本节如实记录每个阻塞项与对应修复；不掩盖首轮问题。

#### 0. 首轮验收失败原因（用户指出 + 本轮新发现）

用户指出的阻塞项：

1. KnownHost 持久化失败被 `try? context.save()` 静默忽略（安全阻塞项）。
2. Trust Always / Replace Trusted Key 保存失败后仍继续认证并显示成功。
3. HostEditorView 私钥路径校验未覆盖 `privateKeyPath == nil`，可保存无路径的 Private Key Host。
4. Passphrase 原始字节 `passphraseBytes` 未清零（只清了传给 libssh2 的 buffer）。
5. UI 残留旧阶段标识（状态栏 "Phase 5 · SSH Connection"、RootView accessibility "MacSSH Phase 4"）。

本轮额外发现并修复的隐蔽缺陷：

6. **pbxproj 悬空引用导致 KnownHostServiceTests 被静默排除出构建**：
   Phase 6 初始开发时 `KnownHostServiceTests.swift` 的 PBXBuildFile 定义 ID 为 23 位
   （`D100000000000000000000F`），而 Sources 阶段引用 ID 为 24 位（差一个零），
   Xcode 将悬空引用静默丢弃。此前 11:37 的构建因复用 DerivedData 增量缓存中的旧
   `.o` 文件而侥幸通过；本轮 clean build 后暴露——12:58 的测试运行中该套件完全缺失。
   已修正为一致的 24 位 ID，并用程序化校验确认全项目无悬空/孤立 build file 引用。

#### 1. KnownHost 持久化失败处理（阻塞项 1/2/3）

修复内容：

- `KnownHostService.trust/replace/remove` 全部改为 throwing；`try? context.save()`
  替换为显式 `saveAction(context)` + 失败时 `context.rollback()` + 抛出
  `SSHError.knownHostPersistenceFailed`（新增错误类型，用户可读信息不含 Secret/状态码）。
- 保存失败后重新读取校验：save 成功但读不回记录同样视为持久化异常（防御性双重校验）。
- 失败回滚保证内存中不残留新 Host Key（否则同进程下一次 lookup 会误判 trusted）。
- `SSHConnection.resolveHostKeyDecision` 中 Trust Always / Replace Trusted Key 均改为
  `try await knownHostService.trust(...)`：持久化失败在进入 authenticating 之前终止连接，
  Password 与私钥绝不发送；旧 KnownHost 保持不变。
- 注入点设计：`KnownHostService` 新增 `saveAction: (ModelContext) throws -> Void`
  注入口（生产默认 `context.save()`，测试注入失败），不引入 Repository 层。

#### 2. Private Key nil / empty / whitespace 路径（阻塞项 4）

修复内容：

- `HostEditorView` 新增 `hasValidPrivateKeyPath(_:)` 静态校验：`nil`、`""`、纯空白
  路径均无效；保存时阻止并提示 "Choose a private key file."（UI 文案与现有英文风格一致）。
- Private Key 文件区显示逻辑（路径文本/Clear 按钮可见性）同步使用统一校验。
- `SSHService` 前置校验同步收紧：nil / 空 / 纯空白路径一律 `privateKeyPathMissing` 快速失败。
- 保持分层：Host Editor 只校验"有实际路径值"，不解析密钥格式；文件存在性/可读性
  仍由连接层校验（`privateKeyFileNotFound` / `privateKeyFileUnreadable`）。

#### 3. Passphrase 原始字节清零（阻塞项 5）

修复内容：

- 新增统一清零入口 `SSHConnection.zeroSecretBytes`（数组版 + 手动缓冲区版）。
- `authenticateWithPrivateKey` 中原始 `passphraseBytes` 副本与 libssh2 用的
  `passphraseBuffer` 均通过 `defer` 清零：覆盖成功、错误 Passphrase、认证失败、
  超时、连接中断、取消、意外错误全部路径，不因提前 throw 留下可控 Secret。
- Password 路径的 `passwordBytes` / `passwordBuffer` 清零迁移到同一统一入口
  （安全标准一致化）。
- Secret 副本数量保持最小（String → CChar 数组 → 跨 await 手动缓冲，未新增中间副本）。

#### 4. UI Phase 标识修复（阻塞项 6）

- 状态栏：`Phase 5 · SSH Connection` → `Phase 6 · SSH Security`。
- RootView accessibility：`MacSSH Phase 4` → `MacSSH Phase 6`。
- 全项目扫描确认无其他过期阶段文案（历史文档/测试名称/Commit 说明中的阶段引用按规则保留）。

#### 5. 新增 / 修改的自动化测试

新增文件：

- `Tests/Hosts/HostEditorValidationTests.swift`（5 项）：nil / 空 / 纯空白路径无效、
  真实路径有效（含空格路径）、SSHService 对 nil/空/空白路径前置失败。

重写 / 扩展：

- `Tests/SSH/KnownHostServiceTests.swift`（7 → 11 项）：新增 Trust Always 保存失败
  抛错且无残留、upsert 失败保持旧记录、Replace 失败保持旧 Key、Forget 失败记录保持可见。
- `Tests/SSH/SSHConnectionTests.swift`（17 → 31 项），新增：
  - testO：Trust Always 持久化失败 → 认证绝不开始（终态错误 + 高频阶段采样双重断言 + 回滚验证）
  - testP：Replace 持久化失败 → 认证绝不开始 + 旧 KnownHost 不变
  - testQ：Replace 成功 → 私钥认证 Connected → 重连免警告直接 Connected
  - testR：Trust Always 落盘持久化（同 store URL 重建 ModelContainer 等价 App 重启）
  - testS：Forget 后重新连接回到 Unknown Host 对话框
  - testT：未授权私钥 → privateKeyAuthenticationFailed（不回退 Password）
  - testU：正确 Passphrase（随机生成经真实 Keychain）→ 认证成功
  - testV / testW：RSA / ECDSA 私钥真实认证
  - 20 次 Private Key Connect/Disconnect 泄漏检测（FD / 线程 / 常驻内存）
  - Private Key 连接空闲 30 秒 CPU
  - 清零机制测试（数组 + 手动缓冲区）
- `Scripts/run-ssh-tests.sh`：生成全部测试密钥（ed25519 无/有 Passphrase、未授权
  ed25519、RSA、ECDSA）；Passphrase 写入 600 权限临时文件由 testU 读取后即删，
  经真实 CredentialService→KeychainService 保存，不进任何日志。

#### 6. 真实验收测试结果（2026-08-29 13:20–13:22，本机 sshd + 真实 Keychain）

XCTest 全量执行：**57 passed / 1 skipped / 0 failed，`** TEST EXECUTE SUCCEEDED **`**。

- `KnownHostServiceTests` 11/11 通过（首次真实执行；此前被 pbxproj 悬空引用排除）。
- `HostEditorValidationTests` 5/5 通过。
- `CredentialServiceTests` 4 passed + 1 skipped（生产 namespace 验证按设计跳过）。
- `DependencyIdentityTests` 6/6 通过（libssh2 `be937743…` 1.11.2_DEV / OpenSSL 3.5.8
  基线不变，三层身份断言全过）。
- `SSHConnectionTests` 31/31 通过，含：
  - Password 回归：正确密码 Trust Once 连接（testA）、错误密码（testB）、错误用户名（testC）、
    端口拒绝（testD）、超时（testE）、DNS 失败（testF）、Trust Cancel 绝不认证（testG）、
    凭据缺失快速失败（testH）、无路径私钥前置失败（testI）
  - Phase 6 回归：Trust Always 持久化 + 二次连接免对话框（testJ）、Host Key Changed
    阻断（testK）、ED25519 无 Passphrase 认证（testL）、错误 Passphrase（testM）、
    私钥文件缺失（testN，模拟保存后文件被删除）
  - Phase 6 Fix 新增：持久化失败注入（testO/testP）、Replace 重连免警告（testQ）、
    落盘持久化跨容器重建（testR）、Forget 回归（testS）、未授权私钥（testT）、
    正确 Passphrase（testU）、RSA（testV）、ECDSA（testW）
  - 资源与 CPU：20× Password 连接（FD/线程）、20× Private Key 连接（FD/线程/内存）、
    双路径空闲 30 秒 CPU 均 ≤ 1.0 秒、EAGAIN 等待策略回归

Key Type 实测状态：

- ED25519（无 Passphrase）：**真实认证通过**（testL/testN/testQ/20×循环/空闲 CPU）。
- ED25519（有 Passphrase，正确）：<redacted> 值不记录；**真实认证通过**（testU）。
- ED25519（错误 Passphrase）：**正确返回 privateKeyPassphraseIncorrect**（testM）。
- RSA（2048 无 Passphrase）：**真实认证通过**（testV）。
- ECDSA（无 Passphrase）：**真实认证通过**（testW）。
- 上述四种 Key Type 均已真实验证；无"理论支持未实测"项。

Passphrase 清零测试边界（如实说明）：

- 可直接断言的部分：清零机制本身（数组与手动缓冲区逐字节归零）已通过单测；
  成功路径（testU）与全部失败路径（testM 错误 Passphrase、testT 认证失败、testO/P
  持久化失败中止）均真实执行 defer 清零代码路径。
- 无法直接断言的部分：物理内存中字节是否被清零无法从 Swift 层观测（编译器/OS
  内存管理不受用户态控制）；该边界如实声明，不做虚假声明。

#### 7. Build / 签名 / Linkage（修复后最终状态）

- Debug arm64 clean build：成功，**project compiler warning = 0**。
- Release arm64 clean build：成功，**project compiler warning = 0**。
- build-for-testing：`** TEST BUILD SUCCEEDED **`，0 warning。
- 产物均为 Mach-O arm64；Release `codesign --verify --strict` 通过，
  Hardened Runtime 启用（Runtime Version 26.5.0）。
- `otool -L`：Debug/Release 均无 `/opt/homebrew`、`/usr/local`、动态 libssh2/
  libssl/libcrypto 依赖；libssh2 静态链接（Release 二进制嵌入 pinned commit
  `be937743a85c4064a6399cee39e606672a401069`）。
- 已知系统 runtime diagnostic（`com.apple.linkd.autoShortcut` / `NSFontManager` /
  `default.profraw` 写入受限）：非 compiler warning，不影响功能。

#### 8. Local Terminal / App 运行回归

- App 实际启动成功（Debug 构建，13:20 版本）；窗口正常出现。
- Local Terminal PTY 真实启动（App 子进程 `-zsh` login shell 存在，Phase 2 路径完好）。
- App 与 zsh 空闲 CPU 实测均 0.0%；正常退出无崩溃。
- 说明：Host Manager UI 深度交互（CRUD/切换认证类型）受代理沙箱 AppleScript 拦截
  无法脚本化执行；但本轮对 Host Manager 相关改动仅限 HostEditorView 校验函数与
  文案（已由 5 项单测覆盖），SwiftData/HostListView 路径零改动，回归风险面最小。
  Password↔Private Key 切换不删凭据的行为逻辑未改动（Phase 4/6 已有实现保持不变）。

#### 9. 本轮修复涉及的文件

新增：

- `Tests/Hosts/HostEditorValidationTests.swift`

修改：

- `MacSSH/Services/SSH/KnownHostService.swift`（throwing + rollback + saveAction 注入）
- `MacSSH/Services/SSH/SSHConnection.swift`（try await 信任持久化 + zeroSecretBytes + defer 清零）
- `MacSSH/Services/SSH/SSHError.swift`（新增 knownHostPersistenceFailed）
- `MacSSH/Services/SSH/SSHService.swift`（前置校验收紧空白路径）
- `MacSSH/Features/Hosts/HostEditorView.swift`（hasValidPrivateKeyPath 统一校验）
- `MacSSH/App/AppState.swift`、`MacSSH/App/RootView.swift`（Phase 6 标识）
- `Tests/SSH/KnownHostServiceTests.swift`、`Tests/SSH/SSHConnectionTests.swift`
- `Scripts/run-ssh-tests.sh`（全密钥矩阵生成）
- `MacSSH.xcodeproj/project.pbxproj`（修复 KnownHostServiceTests 悬空 ID + 新增
  HostEditorValidationTests/Hosts group）
- `Docs/DevelopmentStatus.md`（本节）

#### 10. 当前已知问题

- 代理沙箱拦截 Xcode Metal Toolchain wrapper 的 cryptex 注册表读取与 swift
  plugin-server 宏展开，代理内无法直接执行 clean build/XCTest；构建与测试在
  系统 Terminal（正常环境）完成。该限制非 App 代码缺陷。
- 凭据/密钥相关测试依赖 `Scripts/run-ssh-tests.sh` 交互式创建（安全提示输入本机
  密码），脚本退出自动清理；本轮验证结束后确认测试密钥与 Keychain item 已清理。
- 其余无未解决的功能缺陷。

### Phase 7：Remote SSH Terminal

状态：**已通过用户验收**（基线提交 `9af8b91`）

完成日期：2026-08-29（初版）／ 2026-08-29（第一轮整改）／
2026-08-30（第二、三轮整改与最终复验）

#### 1. 总体架构

在 Phase 5/6 已建立的 SSH 安全架构之上，把已认证的 `SSHConnection` 接入
SwiftTerm，形成真正可交互的 Remote SSH Terminal：

```text
Host → TCP → SSH Handshake → KnownHost 验证 → Password / Private Key 认证
    → SSHConnection（actor，复用，绝不重新认证）
    → SSH Channel（open session channel）
    → Request PTY（xterm-256color + SwiftTerm 真实初始尺寸）
    → Start Remote Shell
    → SwiftTerm ↔ SSH Channel（输入 / 输出 / Resize）
```

职责划分（任务书第 6 节）：

- `SSHConnection`（不变）：TCP / Handshake / KnownHost / Authentication /
  Session 生命周期。
- `SSHChannel.swift`（`SSHConnection` 的 actor extension）：Channel / PTY /
  Shell 建立、Channel 读写、Resize、优雅关闭——所有 `LIBSSH2_CHANNEL *`
  调用都发生在 `SSHConnection` actor 隔离内，与 `LIBSSH2_SESSION *` 共享
  同一串行边界，read / write / resize / disconnect 绝不并发进入同一 handle。
- `RemoteTerminalService`（`@MainActor`）：持有 SwiftTerm `TerminalView` 与
  读取循环，是 Remote Shell 的拥有者；由 `AppState` 持有，生命周期独立于
  SwiftUI View（切换 Sidebar / Tab 不销毁远端 Shell，不重启 Shell）。
- `RemoteTerminalSession`（`@Observable`）：View 观察的状态对象
  （phase / columns / rows / 标题 / cwd）。
- `RemoteTerminalRepresentable`（`NSViewRepresentable`）：SwiftTerm AppKit
  视图接入 SwiftUI，与 Phase 2 `TerminalRepresentable` 同构。

#### 2. SSH Channel 生命周期

- `openInteractiveShell(columns:rows:)`：幂等且并发安全；open session channel
  （`libssh2_channel_open_ex`）→ `libssh2_channel_request_pty_ex`
  （xterm-256color + 真实初始尺寸，非固定 80×24）→
  `libssh2_channel_process_startup("shell")`。任一步失败立即
  `closeShellChannel()` 并抛业务错误，绝不留下半开 Channel。打开流程
  跨 await（actor 可重入），在途打开以 Task 登记（`shellChannelOpenTask`）：
  并发调用先等待在途结果再决策（成功幂等复用 / 失败重新尝试），
  杜绝"两个并发打开各自通过 nil 守卫、后者覆盖前者"造成的 Channel 泄漏。
  第二轮验收整改：打开入口还必须先等待在途关闭任务
  （`shellChannelCloseTask`）——否则 close → reopen → disconnect 交错时，
  新 Channel 可能在旧清理进行中打开，随后随 Session 释放成为悬空指针。
- `readChannelOutput()`：非阻塞读 + `EAGAIN` 时按
  `libssh2_session_block_directions` → poll 有界等待（复用 Phase 5 的
  `waitForLibssh2Readiness`）；0 字节时区分 EOF 与暂无数据；空闲等待不是
  错误。返回 `(bytes, isEOF)`，输出按原始 byte stream 传递（不做 String
  重编码，保护 UTF-8 / ANSI / 二进制序列边界）。
- `writeChannelInput(_:)`：partial write 处理——offset + remaining 循环
  直到写完 / 出错 / 超预算；`EAGAIN` 走同一 poll 等待，无 busy-loop。
- `resizeChannelPTY(columns:rows:)`：`libssh2_channel_request_pty_size_ex`，
  同样处理 `EAGAIN`；远端 `stty size` / `tput cols` 实时一致。
- `closeShellChannel()`：幂等且并发安全；send EOF → close → wait closed →
  free，每步尽力而为，最终必释放 `LIBSSH2_CHANNEL *`，任何路径（用户断开 /
  远端退出 / 失败清理 / 连接丢失）都不泄漏 Channel。清理步骤跨 await
  （actor 可重入），在途清理以 Task 登记（`shellChannelCloseTask`）：
  并发调用等待在途清理真正完成后才返回。语义边界（第二轮验收整改）：
  本方法只关闭"当前登记的"Channel，等待在途清理后直接返回、不重新检查
  `shellChannel`——等待期间完成的新打开属于新会话（close → reopen），
  由其自身关闭路径负责；若在此重新检查并关闭，旧会话的关闭路径会在
  reopen 后误杀新 Terminal 的 Channel（按 actor 恢复顺序非确定性触发）。
  断开路径需要的"关闭全部 Channel"由 `closeAllShellChannelsForTeardown()`
  保证（见下）。
- `closeAllShellChannelsForTeardown()`（第二轮验收整改新增，
  `disconnect()` 调用）：teardown 语义——等待在途打开 / 关闭任务并
  **循环检查直到清空**（无 Channel、无在途任务）。修复 P1：
  此前 `disconnect()` 只调用一次 `closeShellChannel()`，旧清理在途、
  新 Channel 恰好在等待期间打开时，"等完旧任务即返回"而不检查新
  Channel，Session 释放后 `shellChannel` 成为悬空指针。收敛保证：
  断开标志已置位、打开入口拒绝新打开，循环必然终止。
- 并发安全：`validateChannelOperation` 在每次 poll 恢复后校验 session /
  channel 指针身份与 disconnect 标志，杜绝 actor 可重入等待期间的
  use-after-free；`disconnect()` **从断开一开始**就置位 disconnect 标志
  （第二轮验收整改：此前在 Session 释放前才置位，断开期间仍可能有新
  Channel 被打开），再经 `closeAllShellChannelsForTeardown()` 等待全部
  Channel 释放后才释放 session；优雅断开消息改用不检查该标志的专用
  发送路径（`sendGracefulDisconnectMessage`）。第三轮整改后，并发断开
  还统一等待共享 `disconnectTask`；释放前在无 await 的 actor 同步段先将
  Session 从共享状态摘除，再执行第一次 free，杜绝同一 Session 被两条
  任务重复释放。打开 / 关闭 / 断开任务的在途登记均由任务体自身在结束时
  清空（actor 隔离 defer，成功 / 失败都执行），保证"任务完成后槽位必为空"，
  等待方不会看到残留登记。

#### 3. SwiftTerm Bridge

- 输入：Keyboard / paste → SwiftTerm 产生真实 terminal input bytes →
  `TerminalViewDelegate.send` → `Task { @MainActor }` → actor
  `writeChannelInput`（支持英文 / 中文 / Enter / Backspace / Tab / Ctrl 组合 /
  方向键 / Home/End / PageUp/Down / Escape / 功能键，由 SwiftTerm 转义层
  产生，不把键盘事件拼成 Shell 命令字符串）。
- 输出：读取循环持续调用 `readChannelOutput()`，非空字节直接
  `terminalView.feed(byteArray:)`；`isEOF` → `[Remote shell exited]` 状态
  （保留屏幕与历史，不 Crash，不自动重建 Shell）。
- Resize：SwiftTerm `sizeChanged`（首次 layout 与窗口 Resize 都触发）→
  更新 session 尺寸 → actor `resizeChannelPTY`。
- 显示层与 Local Terminal 同源：同 `monospacedSystemFont(13)`、
  xterm-256color、10,000 行 scrollback；标题栏 / 状态栏显示
  `SSH ● hostname · cols × rows`（不含任何 Secret）。

#### 4. 会话与 UI 集成（第一轮整改后）

- `AppState.openRemoteTerminal(for:)`：仅在 `info.phase == .connected` 时
  复用已认证 `SSHConnection`（绝不重新认证 / 重读凭据）；同一主机的活动
  会话不重建 Shell；换主机先优雅关闭旧 Channel。
- HostListView 为已连接主机提供 Open Terminal 入口；连接成功后可直接
  打开 Terminal，无需再次输入密码。
- Phase 7 范围（整改后）：Remote Terminal 会话存在期间直接占用 Terminal
  工作区（隐藏 Tab Bar）；Local/SSH Tab、Close、Switch、Reconnect 属于
  计划书 Phase 8，本阶段不实现（第一轮验收确认原 Tab 化实现越界，
  已回退）。Remote 会话的收起由连接生命周期驱动：Hosts 页断开主机
  （`hostDidDisconnect`）或再次 Open Terminal 替换；远端 `exit` /
  连接丢失后保留终端展示终止状态。
- Terminal Tab Bar：保持 Phase 2 原样（仅静态 Local Tab + 禁用的
  新建按钮），零改动恢复。
- 生命周期：`RemoteTerminalService` 由 `AppState` 持有；View 重建
  （Sidebar 往返）不销毁远端 Shell——cwd / 屏幕内容 / Shell 进程保持。
  `startIfNeeded()` 的打开任务登记在 `openTask` 并携带 `hasStopped`
  停止标志：`stop()` 先于打开完成到达时，打开任务完成或被取消后必须
  补偿关闭刚打开的 Channel，杜绝孤儿 Channel（修复第一轮验收指出的
  立即关闭竞态）。

#### 5. 业务错误（`RemoteTerminalError`）

`channelOpenFailed / ptyRequestFailed / shellRequestFailed /
channelReadFailed / channelWriteFailed / channelClosed / connectionLost /
resizeFailed`；libssh2 原始错误码只进 OSLog 诊断日志（
"Channel read failed with libssh2 code N"），不进入用户可见信息，
日志不含终端内容 / 命令 / 凭据。

#### 6. 日志安全

OSLog 仅记录：channel opened / PTY requested（含尺寸与 term 类型）/
shell started / PTY resized（含尺寸）/ shell exited / channel closed /
Channel 错误码。禁止并实际未记录：终端命令、终端输出、Password、
Passphrase、私钥内容、剪贴板。

#### 7. 新增 / 修改文件

新增：

- `MacSSH/Services/SSH/SSHChannel.swift`（actor extension：Channel / PTY /
  Shell / 读写 / Resize / 优雅关闭 / 断开 teardown 循环）
- `MacSSH/Services/SSH/RemoteTerminalError.swift`
- `MacSSH/Services/Terminal/RemoteTerminalService.swift`
- `MacSSH/Models/RemoteTerminalSession.swift`
- `MacSSH/Features/Terminal/RemoteTerminalRepresentable.swift`
- `Tests/SSH/RemoteTerminalTests.swift`（17 项真实集成测试，A–Q；
  L–Q 为第一至第三轮验收整改新增）

修改：

- `MacSSH/App/AppState.swift`（remoteTerminalService 生命周期 + 状态栏 +
  连接生命周期驱动的收起）
- `MacSSH/App/RootView.swift`（Phase 7 标识更新）
- `MacSSH/Features/Hosts/HostListView.swift`（已连接主机 Open Terminal 入口 +
  断开时收起 Remote Terminal）
- `MacSSH/Features/Hosts/HostRowView.swift`（Open Terminal 按钮注入）
- `MacSSH/Features/Terminal/TerminalWorkspaceView.swift`（Remote 会话存在
  期间直接占用工作区；Tab 切换属 Phase 8，已回退）
- `MacSSH/Services/SSH/SSHConnection.swift`（disconnect 从断开一开始置位
  标志 + teardown 关闭循环 + 共享 disconnectTask + Session 所有权摘除后
  单次释放 + 优雅断开消息专用发送路径）
- `MacSSH/Services/SSH/SSHService.swift`（connectionActor 访问）
- `MacSSH.xcodeproj/project.pbxproj`（新文件注册）
- `Scripts/run-ssh-tests.sh`（纳入 RemoteTerminalTests）
- `Docs/DevelopmentStatus.md`（本节）

注：`TerminalTabBar.swift` 第一轮验收整改后已零改动恢复 Phase 2 原样
（不在修改列表中）。

`git diff --check`：无空白错误。Local Terminal 核心实现
（`LocalTerminalService` / `TerminalSession` / `TerminalRepresentable`）
零修改，Phase 2 路径保持。

#### 8. 测试与回归结果

真实环境：本机 sshd + 真实 libssh2 + 真实 PTY + 真实 login shell + 真实
SwiftTerm 依赖链（测试 Host App 即真实 App）；凭据 / 密钥由
`Scripts/run-ssh-tests.sh` 交互式预置，退出自动清理（已验证清理干净）。

Phase 7 初版的完整交互式 XCTest 结果：**70 passed / 0 failed / 1 skipped**（skip 为
`testConfiguredProductionPasswordState` 的既定环境跳过，Phase 5 起一致），
`Test Suite 'All tests' passed`，脚本 exit 0。第三轮新增 testQ 后的本轮
非交互回归结果见本节后文与第 13 节，未把缺失交互凭据的 skip 冒充通过。

RemoteTerminalTests（Phase 7，17 项，A–Q；L–Q 为第一至第三轮整改新增）：

- testA Password 认证 Shell Channel echo 往返 → EOF → 关闭：**通过**。
- testB Private Key（ed25519）认证 Shell echo 往返 → EOF：**通过**。
- testC PTY Resize 同步：resize 101×37 后远端 `stty size` 报告
  `37 101`：**通过**（真实交互式 PTY 链路证明）。
- testD 中文 + Emoji（`中文测试 😀🚀`）UTF-8 byte stream 往返：**通过**。
- testE 大量输出 `seq 1 100000`（> 400KB 流式通过 Channel，无崩溃、
  无额外无限累积）：**通过**（实测输出数百 KB 量级）。
- testF 未认证 Session 请求 Shell：明确失败且无半开 Channel 残留：**通过**。
- testG 空闲 30 秒 CPU（Channel 打开 + 读取循环运行）：**通过**（30 秒
  墙钟内完成，CPU 远低于墙钟，无 busy-loop；阈值校准说明见测试注释）。
- testH 20 × Connect → Terminal → Echo → Disconnect 资源循环：**通过**
  （FD / 线程 / 内存增量均在断言界内，无持续增长）。
- testI vim 全屏交互：进入 alternate screen（ESC[?1049h）→ `:q` 退出
  （ESC[?1049l）→ shell 恢复可继续执行命令：**通过**（真实全屏程序，
  非 `vim --version`）。
- testJ Ctrl+C（0x03）中断远端 `ping`：远端进程真实中断，shell 恢复：**通过**。
- testK `ls --color=always`：原始 ANSI CSI 转义序列（ESC[...）直通：**通过**。
- testL top 全屏交互（第一轮整改，计划书验收命令）：top 进入 alternate
  screen → 刷新 2 秒 → `q` 退出 → shell 恢复继续执行命令：**通过**。
- testM nano 全屏编辑（第一轮整改，计划书验收命令）：nano 进入全屏 →
  真实输入文本 → `^X` 触发 "Save modified buffer" 询问（证明输入进入
  编辑缓冲）→ `N` 放弃修改退出 → shell 恢复：**通过**。
- testN htop 全屏交互（第一轮整改，计划书验收命令）：htop 进入全屏 →
  刷新 2 秒 → `q` 退出 → shell 恢复（绝对路径启动，不依赖 login shell
  PATH；本机 Homebrew 安装）：**通过**。
- testO 打开与立即关闭竞态（第一轮整改）：startIfNeeded 后立即 stop，
  等待打开任务尘埃落定后断言无孤儿 Channel，且同一连接还能打开新
  Shell：**通过**。
- testP close → reopen → disconnect 并发（第二轮整改）：旧 Channel 在途
  关闭 + 重新打开新 Channel + disconnect 并发；4 个到达偏移覆盖多种
  顺序，断言 disconnect 后 `shellChannel` 为 nil、无在途打开 / 关闭
  登记（不残留悬空指针）：**通过**（连续 4 次运行稳定，耗时 0.9–4.1s
  波动表明交错真实覆盖）。
- testQ 并发双 disconnect + `session_disconnect EAGAIN`（第三轮整改）：
  第一条断开在注入的 EAGAIN 异步闸门稳定挂起，第二条同时进入 actor；
  断言第二条调用等待共享 `disconnectTask`、挂起窗口内未提前 free、Session
  只成功释放一次且重复 free 为 0：**通过**（真实本机 SSH 连续 10 次，
  10/10 通过）。

marker 匹配说明：测试命令中的 marker 以引号拆分（如
`echo PHASE7_SEQ_"DONE"`），PTY 回显的命令行不含连续 marker，只有远端
真实输出才会匹配——排除"命令回显假阳性"（该问题在本轮开发中由 testE
的输出量断言捕获并修复，属测试方法缺陷，非实现缺陷）。

回归套件（Phase 2–6 全部保留）：CredentialServiceTests /
DependencyIdentityTests / HostEditorValidationTests /
KnownHostServiceTests / SSHConnectionTests 全部通过（含 Phase 6 全密钥
矩阵：ED25519 无/有 Passphrase、错误 Passphrase、未授权 Key、RSA、ECDSA）。

第三轮整改后的非交互回归（不依赖 Keychain 交互凭据，可自动跑）：
SSHConnectionTests + RemoteTerminalTests 合计 **48 项执行 / 20 项 skip
（凭据缺失既定跳过）/ 0 失败**；其中 RemoteTerminalTests 17 项执行 8 项
（testB/F/L/M/N/O/P/Q 私钥路径）全部通过，9 项凭据依赖跳过。依赖交互凭据
的完整回归仍需在系统 Terminal 跑 `Scripts/run-ssh-tests.sh`。

本轮开发中修复的实现缺陷（Phase 7 范围内，如实记录）：

- `readChannelOutput` EAGAIN 空闲路径在 `idleWait` 后 `continue` 内部
  轮询而非返回空数据（与设计注释相悖）：空闲 Channel 上该方法永不返回，
  挂起所有调用方（由 testG 卡死捕获，进程采样定位）。修复为返回
  `([], false)` 由调用方按需重试；0 字节路径等待同步为 `idleReadPoll`。

App 运行冒烟（Phase 6 同款验收方式）：Debug 构建实际启动成功，窗口正常；
App 空闲 CPU 实测 0.0% → 0.0%；正常退出无崩溃。Local Terminal 路径未改动
（Phase 2 实现保持，`git status` 确认 Local Terminal 相关文件零修改）。

测试边界（如实说明，整改后更新）：

- 已由自动化真实测试覆盖：Password / Private Key 双认证路径、echo 往返、
  EOF / 远端 exit、PTY resize（stty 远端验证）、中文 / Emoji、大输出流、
  空闲 CPU、20 轮资源循环、vim 全屏（alternate screen 进入/退出）、
  Ctrl+C 中断、ANSI 转义直通、未认证失败清理、top 全屏（testL）、
  nano 全屏编辑含输入与保存询问（testM）、htop 全屏（testN，本机
  Homebrew 安装）、打开与立即关闭竞态（testO）、close → reopen →
  disconnect 交错（testP）、并发双 disconnect 的 EAGAIN 重入窗口
  （testQ）。
- 未由自动化覆盖（UI 层交互，受代理沙箱无法脚本化，同 Phase 6 限制）：
  状态栏文字实际显示、Sidebar 往返后的 cwd / 屏幕保持、paste、
  Remote exit 后 Terminal UI 状态展示（实现已按 `.exited` 状态编写）。
  以上项需用户验收时人工确认。

#### 9. Build / 签名 / Linkage / 体积

- Debug arm64 clean build：成功，**project compiler warning = 0**。
- Release arm64 clean build：成功，**project compiler warning = 0**。
- build-for-testing：`** TEST BUILD SUCCEEDED **`。
- 产物 Mach-O arm64；Release `codesign --verify --strict` 通过；
  Hardened Runtime 启用（flags 0x10002，Runtime Version 26.5.0）。
- `otool -L`：无 `/opt/homebrew`、`/usr/local`、动态 libssh2 / libssl /
  libcrypto 依赖；libssh2 静态链接（Release 二进制含 81 个 `libssh2_*`
  符号，pinned commit `be937743a85c4064a6399cee39e606672a401069`）。
- Release `MacSSH.app` 体积：**12 MB**（Phase 6 约 11 MB，增长约 1 MB，
  来自 Phase 7 新增代码，属合理范围）。
- 本轮构建环境说明：代理沙箱会拦截 xcodebuild 对 Metal Toolchain
  （cryptex）的解析，导致代理内构建出现 "missing Metal Toolchain" 误报；
  按既有惯例 Debug/Release clean build 与 XCTest 均在系统 Terminal
  （`Scripts/build-app.sh` / `Scripts/run-ssh-tests.sh`）执行，构建产物
  的 Metal 调用直连 `/var/run/com.apple.security.cryptexd/mnt/…/usr/bin/metal`
  （与 Phase 6 相同）。该限制为环境问题，非 App 代码缺陷。

#### 10. 当前已知问题

- 凭据 / 密钥相关测试依赖 `Scripts/run-ssh-tests.sh` 交互式创建（安全
  提示输入本机密码），脚本退出自动清理。
- 其余无未解决的功能缺陷。

#### 11. 第一轮验收整改记录（2026-08-29）

用户第一轮验收结论：Phase 7 不通过。阻塞项与对应整改：

1. **验收命令未完整执行（top / nano / htop 未实测）**：
   - 本机安装 htop（Homebrew，`/opt/homebrew/bin/htop`）。
   - 新增三项真实集成测试并全部通过：
     - `testL_TopFullScreenRoundtrip`：top 进入 alternate screen（ESC[?1049h）
       → 刷新 2 秒 → `q` 退出（ESC[?1049l）→ shell 恢复可继续执行命令。**通过**。
     - `testM_NanoFullScreenRoundtrip`：nano 进入全屏 → 真实输入文本进编辑缓冲 →
       `^X` 触发 "Save modified buffer" 询问（证明输入真实生效）→ `N` 放弃
       修改退出 → shell 恢复。**通过**。
     - `testN_HtopFullScreenRoundtrip`：htop 进入全屏 → 刷新 2 秒 → `q` 退出 →
       shell 恢复（绝对路径启动，不依赖 login shell PATH）。**通过**。
   - 计划书验收命令至此全覆盖：ls（testK）、top（testL）、vim（testI）、
     nano（testM）、htop（testN）、窗口 Resize（testC stty 远端验证 +
     用户 UI 实测已通过）。
2. **越界实现 Phase 8（Local/SSH Tab、Close、Switch）**：
   - `TerminalTabBar.swift` 零改动恢复 Phase 2 原样（HEAD 版本：静态
     Local Tab + 禁用的新建按钮）。
   - `AppState` 删除 `TerminalTab` / `selectedTerminalTab`（Switch）与
     `closeRemoteTerminal()`（Close）。
   - `TerminalWorkspaceView` 移除 Tab 切换：Remote 会话存在期间直接占用
     整个工作区（隐藏 Tab Bar），无会话时恢复 Phase 2 Local 视图。
   - Remote 会话收起改为连接生命周期驱动：`AppState.hostDidDisconnect`
     （Hosts 页断开时调用）与 `openRemoteTerminal` 替换，均非 Tab Close。
   - Hosts 页 Open Terminal 入口保留（验收意见未判定越界）。
3. **closeShellChannel() 并发释放竞态**：
   - 清理流程以 Task 登记在 `shellChannelCloseTask`；所有并发调用方
     （disconnect / stop / 读取循环退出 / 失败清理）等待在途清理真正
     完成后才返回。`disconnect()` 释放 session 前的 `closeShellChannel()`
     由此获得"返回即 Channel 已释放"的契约，杜绝"另一条断开流程先
     free session、原清理流程继续触碰已失效 channel"的 use-after-free。
4. **立即关闭 Terminal 留下孤儿 Channel**：
   - `RemoteTerminalService` 登记打开任务（`openTask`）与停止标志
     （`hasStopped`）；`stop()` 取消打开任务，打开任务完成或失败后
     检测停止标志并补偿关闭刚打开的 Channel；`stop()` 自身的
     `closeShellChannel()` 兜底。新增
     `testO_ImmediateStopDuringOpenLeavesNoOrphanChannel`：发起打开后
     立即停止，等待打开任务尘埃落定后断言无孤儿 Channel，且同一连接
     还能正常打开新 Shell。**通过**。
   - 整改过程中由 testO 首轮失败暴露并同步修复：`openInteractiveShell`
     并发调用时的在途去重缺陷（两个并发打开各自通过 nil 守卫、后者
     覆盖前者导致泄漏），同样以 Task 登记（`shellChannelOpenTask`），
     并发调用先等待在途结果再决策。

整改轮自动化验证（真实本机 sshd + 真实 libssh2 + 真实 PTY）：

- `testB / testF / testL / testM / testN / testO` 全部通过（私钥认证路径，
  测试密钥与 authorized_keys 标记块用后已清理）。
- 其余依赖 Keychain 交互凭据的测试（testA/C/D/E/G/H/I/J/K 与 Phase 5/6
  回归）需由 `Scripts/run-ssh-tests.sh` 完整回归（交互式预置凭据）。
- Debug / Release arm64 全新 DerivedData clean build：成功，
  **project compiler warning = 0**；`codesign --verify --strict` 通过；
  `otool -L` 无 `/opt/homebrew`、`/usr/local`、动态 libssh2/libssl/
  libcrypto 依赖；Release 产物 12 MB。

遗留环境说明（非代码问题）：

- `/tmp/macssh_phase6_ed25519{,.pub}`（本轮临时测试密钥，无 Passphrase，
  授权条目已从 authorized_keys 移除）：代理沙箱无法删除 /tmp 文件，
  可手动删除。

#### 12. 第二轮验收整改记录（2026-08-30）

用户第二轮验收结论：其余问题已解决，剩 1 个 P1 生命周期竞态——
新 Channel 可能在断开时遗留为悬空指针。修复如下：

**竞态分析**：`close → reopen → disconnect` 交错时，旧 Channel 的关闭
任务在途，`openInteractiveShell()`（此前未等在途关闭）建立新 Channel，
`disconnect()` 调用 `closeShellChannel()` 只等待旧关闭任务即返回、不
重新检查新 Channel，随后释放 `LIBSSH2_SESSION`；`shellChannel` 仍指向
随 Session 释放的 Channel，后续 `stop()` / 读取循环退出路径再关闭它时
use-after-free。此前 `disconnectRequested` 仅在 Session 释放前才置位，
断开期间仍可能打开新 Channel。

**修复**（计划书与验收建议方向）：

1. `disconnect()` 一开始就置位 `disconnectRequested`：新的 Channel 打开
   在 `openInteractiveShell()` 入口校验立即失败，在途打开 / 读写 / Resize
   在下一个校验点尽快退出。新增 `closeAllShellChannelsForTeardown()`：
   等待在途打开 / 关闭任务并**循环检查直到清空**（无 Channel、无在途任务），
   保证 disconnect 返回即"Channel 全部释放"后才释放 Session。收敛保证：
   断开标志已置位、打开入口拒绝新打开，循环必然终止；在途打开最迟在其
   各步骤预算内结束（成功 → Channel 被本轮关闭；失败 → 打开路径自身
   失败清理已释放半开 Channel）。
2. `openInteractiveShell()` 打开前等待在途关闭任务（入口循环等待
   `shellChannelOpenTask` / `shellChannelCloseTask` 全部尘埃落定）：
   不在旧 Channel 的在途清理进行中打开新 Channel。
3. `closeShellChannel()` 等完已有关闭任务后的语义边界（已写明）：
   只关闭"当前登记的"Channel、不重新检查——等待期间完成的新打开
   属于新会话（close → reopen），由其自身关闭路径负责；若在此重新检查
   并关闭，旧会话的关闭路径会在 reopen 后**误杀新 Terminal 的 Channel**
   （按 actor 恢复顺序非确定性触发）。**断开路径需要的"关闭全部 Channel"
   由 `closeAllShellChannelsForTeardown()` 保证**，而非把循环检查塞进
   通用 `closeShellChannel()`——这是与验收建议的细微偏离，理由是
   保证 close → reopen 语义不被破坏。
4. 任务登记清空改在任务体自身（actor 隔离 defer，成功 / 失败都执行），
   保证"任务完成后槽位必为空"——等待方恢复时不会看到已完成任务的
   残留登记，`disconnect()` 的关闭循环不会在残留登记上空转。此前
   "失败不清除登记、由创建者在 await 后清除"的设计可能让残留已完成
   任务导致并发等待方忙等。
5. 优雅断开消息：`disconnectRequested` 提前置位后，原 `runWithRetry`
   会在入口即抛出、跳过发送；改用不检查该标志的专用发送路径
   `sendGracefulDisconnectMessage`（含 session 身份校验，防止并发
   double-disconnect 交错后触碰已释放指针），保持 Phase 5 的优雅断开行为。
6. `AppState` 注释更新：`openRemoteTerminal` 换主机替换与
   `hostDidDisconnect` 的 stop+disconnect 异步交错，安全性由 actor 层
   （open 入口等待在途关闭、disconnect teardown 循环）保证，无需把
   stop() 改为 await（保留 fire-and-forget 设计）。

**新增测试**：`testP_CloseReopenDisconnectConcurrentNoDanglingChannel`
覆盖该竞态：旧 Channel 在途关闭 + 重新打开新 Channel + disconnect 并发，
4 个到达偏移（0 / 5 / 20 / 50 ms）覆盖多种顺序，断言 disconnect 后
`shellChannel` 为 nil、无在途打开 / 关闭登记。连续 4 次运行通过
（耗时 0.9–4.1s 波动表明交错真实覆盖）。

**文档同步**：本轮同步修正第 7 节文件清单（移除已回退的
`TerminalTabBar.swift`、修正 `TerminalWorkspaceView` / `SSHConnection`
描述）、第 8 节测试清单（11 项 → 16 项 A–P）、第 2 节 Channel 生命周期
（open 等在途关闭、closeAllShellChannelsForTeardown、disconnect 提前
置位标志、任务体清空登记）。

**验证结果**：

- `testB / testF / testL / testM / testN / testO / testP` 7/7 通过
  （私钥路径，测试密钥与 authorized_keys 标记块用后已清理）。
- 非交互回归：SSHConnectionTests + RemoteTerminalTests 合计 47 项执行 /
  20 项 skip（凭据缺失既定跳过）/ 0 失败。
- Debug / Release arm64 全新 DerivedData clean build：成功，
  **project compiler warning = 0**；`codesign --verify --strict` 通过；
  `otool -L` 无 `/opt/homebrew`、`/usr/local`、动态 libssh2/libssl/
  libcrypto 依赖；Release 产物 12 MB。

遗留环境说明（非代码问题）：

- `/tmp/macssh_phase6_ed25519{,.pub}`（上轮遗留测试密钥，无 Passphrase，
  授权条目已从 authorized_keys 移除）：代理沙箱无法删除 /tmp 文件，
  可手动删除。

#### 13. 第三轮验收整改记录（2026-08-30）

用户第三轮验收结论：上一轮 close → reopen → disconnect P1 已修复，剩
1 个 P1——两条并发 `disconnect()` 可在第一条等待
`session_disconnect EAGAIN` 时分别释放同一个 `LIBSSH2_SESSION *`，造成
double-free。修复如下：

1. `SSHConnection` 新增共享 `disconnectTask`。第一条断开只创建一条
   teardown 任务并登记，之后的并发断开全部等待同一任务，不再捕获第二份
   Session 所有权；任务体以 actor 隔离的 `defer` 清空登记。
2. Session 释放前重新校验 `ownedSession == self.session`，并在没有任何
   `await` 的 actor 同步段先执行 `self.session = nil`，再调用第一次
   `libssh2_session_free`。即使未来调用链再次增加重入点，其他调用也无法
   从共享状态取得同一指针。
3. 按 vendored libssh2 官方文档处理 `libssh2_session_free` 自身可能返回的
   EAGAIN：已摘除所有权的唯一任务按 socket readiness 有界重试；错误或
   超时只记录日志，不把指针重新暴露给其他任务。
4. 新增最小 `SessionTeardownOperations` 测试注入边界，仅替换 Session
   disconnect/free 与 EAGAIN 后测试闸门；生产默认仍直接调用真实 libssh2，
   未改变认证、Host Key、Channel、UI 或 Phase 8 范围。
5. 新增
   `testQ_ConcurrentDisconnectsCoalesceDuringSessionDisconnectEAGAIN`：使用真实
   本机 SSH Session，第一次 disconnect 固定返回 EAGAIN 并稳定挂起，随后
   并发调用第二次 disconnect；断言挂起窗口内 disconnect 调用数为 1、free
   调用数为 0，完成后成功 free 为 1、重复 free 为 0，Session 与共享任务
   登记均清空。

**第三轮验证结果**：

- testQ 单独真实 SSH 连续 10 次：**10/10 通过，0 失败**。
- SSHConnectionTests + RemoteTerminalTests：**48 项执行 / 20 项 skip /
  0 失败**（28 passed；skip 均为本轮无交互式 Keychain 密码或对应临时
  密钥，未冒充为已执行）。RemoteTerminalTests 为 17 项，其中私钥路径
  testB/F/L/M/N/O/P/Q 8/8 通过。
- 首次全套回归中，旧的 20 轮私钥循环第 15 轮出现一次本机 sshd
  `LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE (-8)`；隔离重跑 20/20 通过，随后
  第二次全套回归同样 20/20 通过，最终 xcresult 为 0 失败。该瞬态如实保留，
  没有作为本次代码通过证据。
- CredentialServiceTests / DependencyIdentityTests /
  HostEditorValidationTests / KnownHostServiceTests：**29 项执行 / 1 项既定
  skip / 0 失败**（28 passed）。
- Debug / Release arm64 全新 DerivedData clean build：成功，静默构建
  **compiler warning = 0**；build-for-testing 成功。
- Release：Mach-O arm64、12 MB；`codesign --verify --deep --strict` 通过；
  Hardened Runtime 开启（flags 0x10002）；`otool -L` 无 `/opt/homebrew`、
  `/usr/local` 或动态 libssh2/libssl/libcrypto；静态二进制含 81 个
  `libssh2_*` 符号。
- 最终 Release `.app` 实际启动并完成 App / Local Terminal 初始化，无崩溃；
  冒烟完成后仅终止本次启动进程。控制台仍有 AppKit `NSFontManager` 的运行时
  notice（SwiftTerm/AppKit 初始化期间输出），不是 compiler warning。
- 测试临时 `authorized_keys` 唯一标记块已清理；探测时临时新增的
  `known_hosts` 127.0.0.1 条目也已恢复为不存在；仓库外没有保留新的凭据。

#### 14. 最终复验记录（2026-08-30）

用户要求对 Phase 7 做全凭据最终复验：上一轮 48 项测试中 20 项因缺少
交互式凭据被 skip，核心 Remote Terminal 用例不允许以 skip 收尾。本轮
用真实凭据（密码 / 私钥 / passphrase）完整重跑，期间发现并修复 2 个
真实 Phase 7 缺陷，随后按 29 项清单出具终验报告。

**本轮发现的 2 个真实缺陷与修复**（均由 PTY Resize 自动化测试
`testPTYResizeMatchesSwiftTermLayout` 稳定复现，修复前 5/5 失败）：

1. **丢失的 Resize（竞态 A）**：SwiftTerm 首次 layout 落在
   `openInteractiveShell` 参数捕获（80×24）之后、Channel 建立之前的窗口
   内，`resizeChannelPTY` 因 `shellChannel == nil` 静默返回，远端永久停留
   在 80×24。修复：`RemoteTerminalService.startIfNeeded` 的打开任务在
   打开完成后按当前已知尺寸补偿同步一次，保证远端 PTY 必与视图一致。
2. **打开序列被穿插破坏（竞态 B）**：`shellChannel` 在
   `performInteractiveShellOpen` 中于 PTY / Shell 请求完成**之前**赋值；
   打开期间到达的 `resizeChannelPTY` / `writeChannelInput` 借 actor EAGAIN
   挂起点穿插进同一 Channel，触发 `LIBSSH2_ERROR_BAD_USE (-37)` 并破坏
   打开序列（随后 shell request 以 -13 失败）。修复：`resizeChannelPTY`
   与 `writeChannelInput` 入口加入与 `openInteractiveShell` /
   `closeAllShellChannelsForTeardown` 相同的在途打开 / 关闭 settle-wait，
   打开窗口期内的 resize / 写入顺延到打开尘埃落定后执行（字节不丢）。

**最终复验结果**：

- 全凭据回归（`Scripts/run-ssh-tests.sh`，188.7s）：**84 项执行 /
  83 项通过 / 1 项既定 skip / 0 失败 / 0 次框架重启**。既定 skip 为
  `CredentialServiceTests.testConfiguredProductionPasswordState`
  （"Production credential verification was not requested"，与本轮无关）。
- RemoteTerminalTests 24/24 全部真实执行通过，核心用例无一 skip：
  密码 / 私钥 / passphrase 终端、PTY Resize、vim、nano、top、htop、less、
  Ctrl+C（ping）、中文/Emoji、ANSI/256/TrueColor、Sidebar 往返、远端
  exit、Connection Lost、20× 完整生命周期（21.5s）、30s idle CPU
  （31.3s，含 Shell 打开）、`seq 1 100000` 大量输出、Partial Write/EAGAIN。
  Resize 链证据：80×24 → 97×32 → 135×41，远端 `tput` 与 SwiftTerm 完全一致。
- testQ（并发 disconnect / double-free）单独真实 SSH 连续 10 次：
  **10/10 通过**（单次 1.37–1.63s）。
- SSHConnectionTests 全部通过，含 20× 密钥循环（3.27s）与 30s idle CPU。
- CredentialServiceTests / DependencyIdentityTests /
  HostEditorValidationTests / KnownHostServiceTests：全部通过（0 失败）。
- 手动回归（用户本机实跑并截图）：Local Terminal 输出
  `PHASE7_LOCAL_TERMINAL_OK`（状态栏 142 × 40）；Host Manager 列表 /
  编辑 / 分组 / 收藏 / 搜索 / Connect 正常。
- 最终 `Scripts/build-app.sh`（全新 Derived Data）：Debug + Release arm64
  clean build 均 **BUILD SUCCEEDED**，项目代码 **compiler warning = 0**
  （Debug / Release 各 0）；`git diff --check` 通过。
- Release `.app`（本轮新鲜产物复核）：Mach-O arm64、12 MB；
  `codesign --verify --deep --strict` 通过（valid on disk + satisfies its
  Designated Requirement）；Hardened Runtime 开启（flags 0x10002
  adhoc,runtime）；`otool -L` 仅系统库，无 `/opt/homebrew`、`/usr/local`
  或动态 libssh2/libssl/libcrypto；静态二进制含 81 个 `libssh2_*` 符号，
  内嵌锁定版本：libssh2 `1.11.2_DEV`（commit
  `be937743a85c4064a6399cee39e606672a401069`）+ OpenSSL `3.5.8`。
- 已知非阻塞事项：AppKit `NSFontManager` 运行时 notice（非 compiler
  warning）；Xcode 26 hosted test 机制在**存在失败**时会让宿主进程退出并
  记录 "Restarting after unexpected exit"——修复后所有轮次 0 次重启，
  属框架行为而非产品缺陷。
- 测试临时 `authorized_keys` 标记块与 `/tmp` 临时密钥均已清理；
  仓库外没有保留新的凭据。

### Phase 8：Session Tabs / Multi-Terminal Session Management

状态：**已通过用户验收（复验，2026-08-30）**

完成日期：2026-08-30 ／ 验收阻塞整改日期：2026-08-30 ／
验收通过日期：2026-08-30

#### 1. 总体架构

在 Phase 2（Local Terminal）与 Phase 7（Remote SSH Terminal）之上，建立统一的
多 Terminal Session / Tab 管理层，支持同时运行多个 Local 与多个 Remote SSH
Terminal：

```text
AppState（App 级 @MainActor 稳定对象）
  └── SessionManager（@Observable，唯一 Session 生命周期所有者）
        ├── ManagedTerminalSession（统一模型，纯内存，不进 SwiftData）
        │     ├── .local     → LocalTerminalService（SwiftTerm LocalProcess/PTY）
        │     └── .remoteSSH → SSHService.prepareConnection(for:) 工厂
        │                       → 每 Session 独立 SSHConnection（独立 LIBSSH2_SESSION）
        │                       → RemoteTerminalService（SwiftTerm SSH Bridge）
        └── sessions / activeSessionID / pendingCloseConfirmation / pendingHostClose
```

核心不变量：

- SessionManager 由 `AppState` 持有（App 级稳定对象，不是 SwiftUI View 的
  附属对象）；切换 Sidebar、切换 Tab、窗口变化均不销毁任何运行中的会话。
- 每个 Remote Session 拥有**独立** `SSHConnection`（actor）与独立
  `LIBSSH2_SESSION`；同一 Host 的多个会话之间没有共享 Channel 或共享认证状态。
- `TerminalSession` 是纯内存模型（`ManagedTerminalSession`），不写 SwiftData；
  Host 数据与 KnownHost 持久化保持 Phase 3/6 原样。
- Tab 切换只切换可见的 SwiftTerm 视图（已创建的 `NSView` 复用），绝不重建
  Shell、绝不重新认证、绝不重建 Channel。

#### 2. SessionManager（`MacSSH/Services/Terminal/SessionManager.swift`）

- `@MainActor @Observable final class`，公开 `sessions`、`activeSessionID`、
  `pendingCloseConfirmation`、`pendingHostClose` 四个只读状态。
- 初始化时创建一个默认 Local Session（保持 Phase 2 启动即得一个终端的行为）。
- 会话创建：`createLocalSession()`（⌘T 与 Toolbar 入口）、
  `createRemoteSession(host:)`（Host 行 Connect 入口）。
- 标题编号（P2 整改后）：`nextTitle(base:)` 使用按基准名的**单调计数器**
  （`titleCounters`，随 Manager 存活、不回收不复用），生成
  `Local` / `Local 2` / `Local 3`… 与 `HostName` / `HostName 2`…；
  关闭中间 Tab（或全部关闭）后再创建，编号继续前进，绝不产生同名 Tab。
- 激活：`activateSession(id:)` / `activateTab(at:)`（⌘1~⌘9，越界忽略）。
- 关闭：`requestClose(id:)` 依据 `requiresCloseConfirmation` 分流——
  需要确认的 Remote 活跃会话进入 `pendingCloseConfirmation` 流程
  （`confirmClose()` / `cancelCloseConfirmation()`）；已退出 / 已断开 /
  失败 / Local 会话直接 `closeSession(id:)`。
- `closeSession(id:)`：先同步 `removeSession`（列表移除 + 激活相邻 Tab：
  关闭非首位取左邻，否则取现存第一个），再异步 `teardown`——
  Local 终止进程与 PTY；Remote 走**可等待的拆除屏障**
  （`RemoteTerminalService.stopBarrier()`：取消并等待旧打开任务与读取
  循环完全退出、关闭旧连接 Channel，之后才 `SSHConnection.disconnect()`），
  全部幂等，重复关闭无 double-free。
- Host 维度：`hostSessionSummary(hostID:)` 供 Host 行展示
  （`N Sessions` / `Connecting…` / `Connected`）；
  `requestCloseAllSessions(hostID:hostName:)` / `confirmHostClose()` 在
  Hosts 页 Disconnect 时**关闭该 Host 的全部会话**（用户确认的产品决策）。
- 重连：`reconnectSession(id:)` 对 `canReconnect`（exited / disconnected /
  failed 且无在途任务）的 Remote Session 先经 `stopBarrier()` 完整拆除
  旧运行时并断开旧连接，再走**完整新连接流程**
  （TCP → KnownHost 重新验证 → 认证 → Channel），不自动重连；
  成功后经 `RemoteTerminalService.reattach(connection:)`（自带屏障与
  代次递增）复用同一终端视图，并插入 "--- Reconnected ---" 标记。
- `resolveHostTrust(sessionID:decision:)`：把 Phase 5/6 的 Host Trust 决策
  路由到对应 Session 的 `SSHConnection`。
- `runConnectFlow` 在 `await connect()` 返回后若发现 Session 已被关闭，
  执行补偿性 `disconnect()`，不留孤儿连接。

#### 3. 统一会话模型（`MacSSH/Models/ManagedTerminalSession.swift`）

- `@MainActor @Observable final class ManagedTerminalSession`：
  `kind`（local / remoteSSH）、`title`、`hostID`、
  `localTerminal` / `remoteTerminal`（SwiftTerm 视图服务）、
  `connection` / `connectionInfo`（Remote 运行时）、
  `connectTask` / `reconnectTask`、`isClosed`、`failureMessage`。
- `displayState`：综合连接阶段与终端状态产出
  idle / connecting / authenticating / opening / active / exited /
  disconnected / failed(message) / closing，驱动 Tab 图标、状态文本与按钮。
- `requiresCloseConfirmation`：仅 Remote 处于
  connecting / authenticating / opening / active 时为真；
  Local 一律免确认（用户确认的产品决策）。
- `canReconnect`：仅 Remote 且无在途连接 / 重连任务且状态为
  exited / disconnected / failed 时为真。

#### 4. SSHService 工厂化改造（`MacSSH/Services/SSH/SSHService.swift`）

- Phase 5–7 的“每 Host 单连接”服务重构为**无状态连接工厂**：
  `prepareConnection(for: host) async -> ConnectionPreparation`——
  `.ready(connection, info)` 或 `.rejected(info)`（Private Key 路径缺失等
  前置失败，携带用户可读 `failureMessage`，不进入假认证失败）。
- 每个 Remote Session 调用一次工厂得到自己的 `SSHConnection`；
  SSHService 不再持有任何共享连接，`LIBSSH2_SESSION` 与会话一一对应。
- Host Key Trust 决策、KnownHost 验证、超时预算（各 10 秒）与
  日志安全边界（不记录密码 / Fingerprint / 终端内容）保持 Phase 5/6 不变。

#### 5. UI 集成

- `TerminalTabBar`：多 Tab 渲染（标题 + 状态点/转圈/红叉），单击切换、
  中键/右键关闭入口、`+` 新建 Local；活跃 Tab 高亮。
- `TerminalWorkspaceView`：持有全部已创建 Session 的终端视图（`ZStack`
  按活跃切换可见性），空态提示；Remote Session 首次激活时启动连接流，
  Trust 对话框 / 失败态 / Reconnect 按钮由 `displayState` 驱动。
- `HostListView` / `HostRowView`：行状态列接入 `hostSessionSummary`；
  Disconnect 弹出“关闭该 Host 全部 N 个会话”确认（存在活跃会话时），
  确认后逐会话安全拆除。
- `RootView` / `AppToolbarContent`：Sidebar 选择与会话创建入口接线。
- `MacSSHApp` 新增 `terminalCommands`：`CommandMenu("Terminal")` 提供
  ⌘T（New Local Terminal）与 ⌘1~⌘9（Show Tab N）；
  `CommandGroup(replacing: .newItem)` 以应用语义的 Close（⌘W）替换系统
  File 菜单中 Close Window 位置的行为——活跃会话走
  `requestClose`，无会话时回退 `performClose`。

#### 6. 测试（`Tests/SSH/SessionManagerTests.swift`，A–AA 共 27 项）

- A 默认 Local Session；B 多 Local 独立运行时（各自 PTY、独立输出）；
  C Tab 切换不重建（同一视图身份保持）。
- D–H 关闭语义：关闭非活跃保留活跃；关闭活跃激活左邻；关闭首位激活右邻；
  关闭末位进入空态；全关后可重新创建（P2 整改后断言更新：编号不回收，
  全关后再建为 `Local 2`）。
- I 重复关闭幂等（不崩溃、不重复移除）。
- J 被拒绝的 Remote Session 保留 failed Tab（前置失败不弹窗、不进假认证）；
  K Reconnect 状态迁移；L `hostSessionSummary` 聚合（活跃 / 连接中计数，
  failed / exited / disconnected 不计）；M failed 会话免确认直接关闭。
- N 同 Host 双 Remote Session Shell 完全独立（各自 cwd、互不影响、
  关闭其一不断开另一）——需真实 sshd + 测试密钥。
- O Connecting 中关闭：连接被取消清理、无孤儿连接、状态收敛
  （不可路由地址下收敛为 `.disconnected`（cancel）或
  `.failed(.connectionTimeout)`（10 秒 TCP 预算耗尽））。
- P double close + disconnect 三任务并发：单次移除、无崩溃、状态收敛
  ——需真实连接。
- Q Remote `exit` 后关闭不崩溃；R exit 后 Reconnect 建立全新连接；
  S Reconnect teardown 期间关闭不留下孤儿；T `closeAllSessions(hostID:)`
  关闭同一 Host 全部会话——均需真实连接。
- U 20× New Local → Close 循环：FD / 线程 / 常驻内存无持续增长
  （任务书 61/93，无凭据要求，实测 1.19s 通过）。
- V 5 个空闲 Session 保持 30 秒：进程 CPU 增量 ≤ 1.0 秒，无 busy-loop
  （任务书 94，实测通过）。
- W 20× New Remote → Connect → Open Shell → Close（SessionManager 层级）：
  每轮连接收敛、无孤儿，最终 FD / 线程不持续增长——需真实连接。

P1 验收整改新增（确定性竞态与 Reconnect 补覆盖）：

- X 屏障扣留 reattach（确定性竞态）：旧读取循环判定终止事件后由测试
  接缝（`testReadLoopExitHook`）阻塞在门闩 → 期间发起 `reattach`，
  断言 300ms 后 reattach **仍未完成**（被拆除屏障扣住）→ 释放门闩 →
  reattach 落定、新 Shell active、新 Channel 打开且可执行命令；
  旧代次终止通知先于 "--- Reconnected ---" 提交（串行不交错）
  ——需真实连接。
- Y 取消分支代次防护：活跃会话 `stop()` 触发读取循环取消路径，同样
  被门闩阻塞；释放后断言新一代状态不被旧代次覆盖（最终 active、
  重连标记之后无旧断开通知）——需真实连接。
- Z 真实 Connection Lost 后的手动 Reconnect：连接前后 `ps -u` 差集
  唯一识别本连接的 sshd 子进程并 SIGKILL → 会话进入 `.disconnected` →
  `canReconnect` → Reconnect 恢复 active、连接对象为全新实例
  （绝不复用旧 `LIBSSH2_SESSION`）、Shell 可执行命令——需真实连接。

P2 验收整改新增：

- AA 关闭中间 Tab 后再创建：Local / Local 2 / Local 3 关闭 Local 2 后
  新建必须为 `Local 4`（编号不回收），存活标题集合无重复；同 Host
  SSH Session 同规则（前置拒绝路径验证，无需真实连接）。

既有测试迁移（SSHService 工厂化导致旧 API 移除）：

- `HostEditorValidationTests`：5 项改用 `prepareConnection(for:)` 的
  `.rejected(info)` 模式匹配，验证 `.privateKeyPathMissing` 等前置失败。
- `SSHConnectionTests` testH / testI：同法迁移，断言
  `.credentialNotFound` / `.privateKeyPathMissing` 与 `failureMessage`。
- Phase 4–7 全部测试类保持注册并随整套运行。

#### 7. 构建与验证结果（2026-08-30，验收阻塞整改后复跑）

- `Scripts/build-app.sh`（全新 Derived Data）：Debug + Release arm64
  clean build 均 **BUILD SUCCEEDED**，项目代码 **compiler warning = 0**
  （Debug / Release 各 0）。
- build-for-testing 成功；测试目标代码 **0 warning**。
- 全套 XCTest（`test-without-building`）：**111 项执行 /
  0 失败 / 50 项凭据门控 skip**。
  - `SessionManagerTests`：27 项中 **17 项真实执行通过 / 10 项凭据门控
    skip / 0 失败**（skip 为 N、P–T、W、X、Y、Z，需要
    `run-ssh-tests.sh` 生成的测试密钥 + authorized_keys 授权）。
  - `SSHConnectionTests`：31 项 / 16 skip / 0 失败（skip 为密码 / 密钥
    认证用例）；`RemoteTerminalTests`：24 项 / 23 skip / 0 失败；
    `KnownHostServiceTests` 13、`DependencyIdentityTests` 6、
    `HostEditorValidationTests` 5、`CredentialServiceTests` 5（1 项
    既定 production 状态 skip）——全部 0 失败。
- Release `.app`：Mach-O arm64、12 MB；`codesign --verify --strict` 通过
  （satisfies its Designated Requirement）；`otool -L` 仅系统库，无
  `/opt/homebrew`、`/usr/local` 或动态 libssh2/libssl/libcrypto；
  libssh2 与 OpenSSL 静态链接（`nm` 实测含 `libssh2_*` 与
  `EVP_`/`OSSL_` 符号）。本地 `Sign to Run Locally` 下 Xcode 对
  ad-hoc 签名按系统行为关闭 Hardened Runtime，与 Phase 0–7 一致；
  正式签名发布阶段复测。

#### 8. 当前已知问题 / 待验收复验项

- 凭据门控测试（密码 / 私钥 / passphrase 全套真实回归，含整改新增的
  X / Y / Z 三项确定性竞态与 Connection Lost Reconnect 用例）需在
  正常终端运行 `Scripts/run-ssh-tests.sh`（交互式输入本机密码进测试
  专用 Keychain item；脚本自动生成测试密钥、维护 authorized_keys
  标记块并在退出时清理）。该脚本也会顺带清理上一轮异常中断遗留的
  authorized_keys 标记块。
- ⌘T / ⌘W / ⌘1~⌘9、Tab 切换、关闭确认、Reconnect 的运行时 UI 验证
  需在真实桌面交互下完成（本轮开发环境对 GUI 自动化的限制使
  菜单覆盖与按键行为未能由代理自动复测）。
- 除已整改的 P1 / P2 外未发现 Phase 8 范围内的功能缺陷；整改后
  0 失败贯穿所有已执行轮次。

#### 9. 验收阻塞修复（首轮验收不通过 → 整改，2026-08-30）

首轮验收指出两个缺陷，均已修复：

**P1 生命周期竞态：Reconnect 的旧任务可能关闭新连接**

缺陷成因：`stop()` 只取消旧 `openTask` / `readLoopTask` 而不等待其结束；
异步关闭闭包在执行时读取可变的 `connection` 属性。旧任务若在 `reattach`
换上**新连接**之后才恢复，`closeShellChannel()` 会作用于新连接；旧读取
循环的取消分支也可能在新一代进入 `.opening`/`.active` 后把状态覆盖回
`connectionLost`。

整改措施（`MacSSH/Services/Terminal/RemoteTerminalService.swift`）：

1. **可等待的拆除屏障**：`stop()` 拆为同步部分 `beginStop()`（置
   `hasStopped`、取消两个任务、**捕获当时的连接与任务引用**）+
   屏障任务（等待旧打开任务与读取循环**完全退出**，再关闭捕获连接上
   的 Channel）。新增 `stopBarrier()`；`SessionManager` 的 `teardown`
   与 `reconnectSession` 均改为 `await remote.stopBarrier()` 后才
   `disconnect()`——旧任务尘埃落定前绝不换新连接。
2. **延迟操作一律捕获连接**：打开任务、读取循环、屏障任务、
   `handleShellExit` / `handleReadError` 全部使用创建时捕获的
   `SSHConnection`，不再在执行时读取可被 `reattach` 替换的属性；
   终止路径的 Channel 关闭改为任务内联 `await`（屏障等待读取循环退出
   即同时覆盖该清理，不留跨越 reattach 的延迟关闭）。
3. **运行时代次（generation）**：`runtimeGeneration` 于每次
   `reattach` 递增；打开任务与读取循环启动时捕获代次，任何状态写入 /
   输出喂入前重新校验，旧代次延迟恢复一律硬性失效、只清理自己打开的
   Channel。`reattach` 自身先经屏障再换连接、递增代次，结构上使
   "旧任务跨越 reattach 恢复"在生产路径不可能发生。
4. **读取循环重排**：先判定终止事件（EOF / 读错误 / 取消 / 读超时）、
   再经测试接缝（`testReadLoopExitHook`，生产恒 nil）、最后校验代次并
   一次性提交状态——杜绝半提交被新代次交错覆盖。

**P2 重复标题：关闭中间 Tab 后再创建产生同名 Tab**

缺陷成因：`nextTitle(base:)` 用当前同名会话数量生成编号，关闭中间
Tab 后计数回落，新建会话复用了仍被占用的编号。

整改措施（`SessionManager.swift`）：按基准名维护**单调计数器**
`titleCounters`，编号只前进不回收；计数器随 Manager 存活（Session
纯内存，无需持久化）。

验证结果：

- 整改新增测试 4 项（X / Y / Z / AA）；testH 断言随单调语义更新
  （全关后再建为 `Local 2`）。
- build-for-testing 与全套回归：**111 项 / 0 失败 / 61 通过 /
  50 凭据门控 skip**；Debug + Release clean build 0 warning。
- X / Y / Z 为确定性竞态与真实 Connection Lost 用例，需要测试密钥 +
  authorized_keys 授权（本机沙箱无法写 `~/.ssh/authorized_keys`），
  本轮按规则 skip，**待 `Scripts/run-ssh-tests.sh` 全凭据复验后
  记为通过**；AA 无需凭据，已真实执行通过。

**第二轮复验发现的测试侧缺陷（已修复，未触碰产品代码）**

用户复验结果：23 项 SessionManager 测试通过，但 testR 失败（停在
"SSH · Loopback · Verifying Host…" 后超时），testX 阻塞被中止，
testY / testZ 未执行。根因是**测试辅助方法缺陷，不是产品回归**：

- `resolveTrustAndAwaitActive` 首连选择 `.trustOnce`——KnownHost
  不持久化；而 Reconnect / 第二条连接**正确地重新执行 Host Key
  验证**（Phase 6 安全语义，绝不绕过），再次进入等待确认，测试侧
  却没有再次确认，于是 testR / testZ 的 Reconnect 与 testX / testY
  的第二条连接全部挂起。

修复：辅助方法首连改用 `.trustAlways`（经
`knownHostService.trust(...)` 持久化到测试容器）。重新验证路径不变、
仍然完整执行，只是与已存储 Host Key 匹配后通过。产品代码零改动
（`RootView` 的 Trust Once 按钮与 `SSHConnection` 验证逻辑保持原样）。

修复后本地验证：build-for-testing 成功（0 warning）；全套回归
**111 项 / 61 通过 / 0 失败 / 50 凭据门控 skip**。

**全凭据复验（`Scripts/run-ssh-tests.sh` 实际运行，2026-08-30）**

- `SessionManagerTests`：**27 项全部真实执行通过，0 失败 0 skip**——
  上轮被阻断的 **testR（Reconnect 完整回环）/ testX（屏障扣留
  reattach 确定性竞态）/ testY（取消分支代次防护）/ testZ（真实
  Connection Lost 后 Reconnect）全部通过**，P1 竞态整改取得真实判定。
- 全套：94 通过 / 16 失败 / 1 既定 skip。16 项失败**全部是密码认证
  用例**（RemoteTerminalTests 10 项 + SSHConnectionTests 6 项），根因
  一致：`credentialNotFound`——代理环境无交互终端，脚本的
  `security add-generic-password -w` 密码提示读到 EOF，临时凭据未创建。
  该组用例在上一轮用户交互运行中已全部通过，属环境限制而非产品缺陷；
  密码认证路径的持续回归以用户交互运行结果为准。
- 私钥认证全部用例（含 20× 循环、空闲 CPU、同 Host 双会话、并发
  Close、批量 Disconnect、Trust 持久化 SessionManager 场景）通过。
- 清理确认：临时 Keychain item、/tmp 测试密钥、authorized_keys 标记
  块、on-disk 测试产物全部移除。

#### 10. 验收结果（2026-08-30，复验通过）

用户复验结论：**通过，未发现新的 P1 / P2**。

- 关键生命周期测试 R / X / Y / Z：4/4 通过；
  `SessionManagerTests`：27/27 通过，0 skip / 0 failure。
- 全项目测试：111 项执行，61 pass / 50 credential-gated skip /
  0 failure；Debug / Release 干净构建 0 warning / 0 error。
- Release `.app` 实际启动并稳定运行（观测期 CPU 0.0%），随后正常停止。
- 四个重点验收点全部满足：
  1. libssh2 为 1.11.2_DEV（commit
     `be937743a85c4064a6399cee39e606672a401069`），非存在已知问题的
     原版 1.11.1；
  2. `SSHConnection.swift` 严格按“获取 Host Key → 用户确认 / 匹配
     可信记录 → Password 认证”执行，不提前发送密码（本轮无 Password
     凭据，该组按门控跳过、未冒充通过；密码发送顺序经源代码路径
     审查确认）；
  3. Release `.app` 的 `otool -L` 仅系统库，不依赖 `/opt/homebrew`、
     `/usr/local` 或动态 libssl/libcrypto/libssh2，签名完整性通过；
  4. EAGAIN 路径为 readiness wait / 异步退避 / `Task.sleep`，无
     busy-loop，30 秒空闲 CPU 测试通过。
- 整改确认有效：断开 / 重连 / 旧 read-loop 退出竞态、旧 generation
  覆盖新连接状态、同 Host 多会话标题重复、Trust Always 测试辅助
  （重连仍验证 Host Key，但不再次阻塞在用户确认界面）。
- 验收产生的临时 SSH key、authorized_keys 标记与运行进程均已清理；
  工作区未提交改动保持原样，`git diff --check` 通过。
- 私钥实连路径已完整执行；未实现任何 Phase 9 内容。

本阶段明确未实现（Phase 8 禁止范围，全部遵守）：

- SFTP、文件浏览、Upload/Download、Transfer Manager（Phase 9 范围）。
- Port Forwarding、SSH Agent、ProxyJump、SSH Config、自动重连
  （Reconnect 仅手动触发）。
- Session / Tab 布局或运行状态的 SwiftData 持久化（本阶段纯内存）。

### Phase 9：SFTP Browser / Remote File Browsing

状态：**第二轮复验发现 1 个 P1（快速导航重叠操作同一 SFTP 状态机）与 2 个 P2 → 整改完成，等待再次复验**

完成日期：2026-08-30 ／ 首轮验收阻塞整改：2026-08-30 ／
第二轮复验整改：2026-08-31

#### 1. 总体架构

在 Phase 7（Remote SSH Terminal）与 Phase 8（多 Session 管理）之上，建立
严格的**只读** SFTP 浏览通道。Terminal 与 SFTP Browser 共用**同一条已认证
`LIBSSH2_SESSION`**——SFTP 子系统挂在现有连接上，绝不二次登录、绝不新建
会话：

```text
SFTPBrowserView（SwiftUI：只观察，绝不触碰 libssh2）
  └── SFTPService（@MainActor @Observable 业务层：路径 / 列表 / 状态 / 竞态）
        └── SFTPSession（extension SSHConnection，actor 串行边界，唯一操作入口）
              └── libssh2 SFTP（仅 READ / LIST / STAT / REALPATH / 导航）
```

核心不变量：

- `SSHConnection` actor 是 Session 的唯一所有者；全部 SFTP 调用在 actor
  串行边界内执行，UI 与业务层绝不直接调用 libssh2。
- **只读**：产品代码中零写操作——无 `libssh2_sftp_write / unlink / mkdir /
  rmdir / rename / setstat` 调用（grep 验证，见第 7 节）；无
  Upload / Download / Delete / Rename / Move / Create / Chmod / Edit /
  拖放传输 / 本地文件浏览。
- EAGAIN 一律经 `libssh2_session_block_directions` + poll readiness 等待
  （沿用 Phase 5 的 `waitForLibssh2Readiness`），无 busy-loop；每次循环带
  截止时间与断开 / 取消校验，Terminal 读取循环不被饿死。
- 子系统生命周期与连接绑定：Terminal ↔ Files 面板切换**不重建**子系统；
  Reconnect 一律重建（绝不复用旧 `LIBSSH2_SFTP *`）；断开即释放。
- 业务错误（权限拒绝 / 路径不存在 / 连接丢失）不崩溃、不自动断开健康连接、
  不影响既有 Terminal。

#### 2. SFTPSession 底层（`MacSSH/Services/SSH/SFTPSession.swift`）

`extension SSHConnection`（545 行）——全部真实 `libssh2_sftp_*` 调用只发生
在这里：

- **子系统初始化** `openSFTPSubsystemIfNeeded()`：幂等；在途初始化登记为
  `sftpInitTask`，并发调用等待同一结果；`libssh2_sftp_init` EAGAIN 循环经
  readiness 等待；成功 / 协议失败 / 连接丢失三态分明；初始化失败**不触碰
  健康连接**（Terminal 照常可用）。`sftpSubsystemInitCount` 供测试观察
  “面板切换不重复初始化”。
- **句柄登记与关闭所有权**（P1 整改后）：所有 `LIBSSH2_SFTP_HANDLE *`
  （OPENDIR）登记在 `openSFTPDirectoryHandles`；登记本身不是并发屏障，
  而是**关闭所有权的认领令牌**——句柄只在“从登记中真正摘除它的那一方”
  手里被关闭（摘除段无跨 await，认领互斥）。整个列举（含收尾 closedir）
  计入 `inFlightSFTPListingCount`，拆除侧**必须先排空在途列举**才能关闭
  残留句柄 / `libssh2_sftp_shutdown`，杜绝 double-close 与 use-after-free；
  `disconnect()` 每条路径全部关闭，绝无泄漏；
  `openSFTPDirectoryHandleCount` 供测试断言归零。
- **列举** `sftpListDirectory(_:)`：`libssh2_sftp_open_ex(...,
  LIBSSH2_SFTP_OPENDIR)` 打开目录；`libssh2_sftp_readdir_ex` 循环读取，
  名称缓冲 4096 字节按**返回长度前缀**解码（不依赖 `strlen`、不截断
  200+ 字符长文件名）；属性完全由 `LIBSSH2_SFTP_ATTRIBUTES.flags` 驱动
  （`LIBSSH2_SFTP_ATTR_SIZE / ACMODTIME / PERMISSIONS`），绝不解析
  `longentry` 文本；`.` / `..` 过滤。
- **路径解析** `sftpRealpath(_:)`：函数式宏 `libssh2_sftp_realpath` 在
  Swift 不可用，改调 `libssh2_sftp_symlink_ex(..., LIBSSH2_SFTP_REALPATH)`；
  初始目录 = `realpath(".")`（登录目录），绝不硬编码 `/` 或 `~`。
- **错误映射**：`libssh2_sftp_last_error` → `SFTPError(sftpStatusCode:)`
  （permissionDenied / noSuchPath / connectionLost / operationCancelled /
  subsystemInitFailed 等）；SFTP 层错误面纯净，不泄漏 `SSHError` 细节
  （断开请求统一映射 `.connectionLost`，经 internal
  `throwIfDisconnectRequested()` 判定）。
- **操作前校验** `validateSFTPOperation(session:sftp:)`：任务取消检查 +
  断开标志 + Session / SFTP 句柄**身份校验**（与当前连接不一致即
  `.connectionLost`，杜绝 use-after-free / 跨连接复用）；列举循环每批
  读取后重新校验。
- **操作串行门（第二轮整改）**：`LIBSSH2_SFTP` 的 `open_state` /
  `readdir_state` / 在途 request ID 是子系统级共享状态——两个操作若借
  actor 在 EAGAIN 等待处的重入间隙并行执行，后一请求可能接走前一请求的
  响应，句柄与协议状态串线。`acquireSFTPOperationGate()` /
  `releaseSFTPOperationGate()` 构成 FIFO 串行门：`realpath` / 目录列举 /
  拆除收尾（关闭残留句柄 + `shutdown`）全部持门执行，任一时刻至多一个
  持门者；释放时直接把所有权移交给队首（绝不先置空闲再争抢）。列举的
  在途登记先于进门——排队中的列举同样被拆除排空屏障覆盖。
- **拆除**（并入 `disconnect()` 的 `closeSFTPResourcesForTeardown()`）：
  等在途初始化落定 → **排空在途列举（含其收尾 closedir）** → 关闭无主
  残留句柄 → `libssh2_sftp_shutdown` → 才轮到 Shell Channel → Session →
  socket（任务书拆除顺序）；幂等，重复调用安全；子系统初始化失败 /
  断开都不影响既有 Terminal。

#### 3. 模型与纯语义（`MacSSH/Services/SFTP/`）

- `SFTPError`：`permissionDenied / noSuchPath / connectionLost /
  operationCancelled / subsystemInitFailed / listingFailed /
  unknown(statusCode)`；`userMessage` 提供不含敏感信息的用户文案。
- `SFTPFileEntry`：`name / kind(directory | file | symlink | unknown) /
  size / modifiedAt / permissions / permissionsDisplay`；kind 由
  `permissions` 的 `S_IFMT` 判定（符号链接由 `S_IFLNK` 识别），
  `sizeDisplay`（KB/MB/GB 本地化）与 `modifiedDisplay` 展示格式。
- `RemotePath`（纯函数，绝不使用本地 `FileManager` 语义）：
  根为 `"/"`；`parent("/") == "/"`；`join` 永不产生 `//`
  （`join("/", "etc") == "/etc"`）；规范化只折叠斜杠、不解释远端符号链接；
  `join` 对 `.` / `..` 防御性处理，绝不向上跳出。

#### 4. SFTPService 业务层（`MacSSH/Services/SFTP/SFTPService.swift`）

`@MainActor @Observable`，UI 只观察本对象：

- 状态机 `Phase`：`idle / loading / loaded / failed(SFTPError)`。
- **导航原子性**：`currentPath` 与 `entries` 只在列举成功后一起提交；
  失败保持原路径 + 原列表 + 业务错误（禁止“路径已变、列表清空”的
  不一致状态）。
- **竞态防护（第二轮整改后）**：每个请求递增 `generation` 并取消上一个
  在途任务；新任务先 **`await` 旧任务完全退出（含其收尾 closedir）**
  才开始自己的 SFTP 操作——取消只是置标志，旧任务可能仍因 EAGAIN 挂在
  `SSHConnection` 内，只有等待其终值才能保证同一时刻没有两个任务进入
  同一个 `LIBSSH2_SFTP` 状态机（连接层另有串行门兜底）；每次 `await`
  恢复后重新校验代次与停止标志，过期结果绝不写入状态。
- 导航入口：`navigate(into:)`（仅目录）、`goParent()`（根目录双重防御）、
  `refresh()`（⌘R / 刷新按钮 / 失败态 Retry 均走这里——失败态重试重新
  加载**保留的当前目录**，权限拒绝等确定性错误不重撞失败目标）。
- `startIfNeeded()`：幂等启动（`realpath(".")` 或恢复 `lastKnownPath`）；
  Terminal ↔ Files 切换不重建、不重复初始化。
- 生命周期：`stopBarrier()`（取消在途请求并等待完全退出，可等待屏障，
  与 `RemoteTerminalService` 同模式）；`reattach(connection:)` 在
  Reconnect 后绑定全新连接、复位 `.idle`、记忆路径供可选恢复。

#### 5. Session 生命周期集成

- `ManagedTerminalSession`：新增 `WorkspacePane`（terminal / files）与
  `activePane`（只经 `selectPane(_:)` 修改）；`sftpService` 首次打开
  Files 面板时惰性创建（仅已认证 Remote Session），面板切换只改展示、
  底层资源保持存活；Files 面板活跃时状态栏展示
  `SFTP ● Host · /current/path`。
- `SessionManager.teardown`：Remote 拆除顺序变为 **SFTP 屏障 →
  RemoteTerminal stopBarrier → disconnect**（disconnect 内部：目录句柄 →
  SFTP → Channel → Session → socket），旧任务尘埃落定前绝不释放连接。
- `SessionManager.reconnectSession`：先经 SFTP 屏障 + Terminal 屏障拆除
  旧运行时并断开旧连接，完整新连接流程后 `sftp.reattach(connection:)`
  绑定新连接（绝不复用旧子系统）；Files 面板在场时立即重启并恢复
  最近成功路径（路径已不存在时自动回落 `realpath(".")`）。
- **连接中提前切 Files 的补创建（第二轮整改，P2）**：连接过程中切换到
  Files 时因尚未认证，`ensureSFTPService()` 只置 `activePane = .files`
  直接返回；`runConnectFlow` 认证成功后若 `sftpService` 仍为 nil 且
  `activePane == .files`，补调用 `ensureSFTPService()` 创建并启动 SFTP
  运行时——Files 面板自动完成加载，绝不永远停在加载态（无需手动切回
  Terminal 再切 Files）。

#### 6. UI（`MacSSH/Features/SFTP/SFTPBrowserView.swift`）

按用户确认的预览图实现：

- 工作区分段控件（Terminal / Files）：Local Session 的 Files 项禁用；
  切换不重建任何底层资源。
- 路径栏：Parent 按钮（根目录禁用）+ 等宽路径文本（可选中复制）+
  Refresh（加载中禁用）。
- 列表：Name / Size / Modified / Permissions 四列 `Table`；目录
  `folder.fill`、符号链接 `arrow.turn.up.right`、未知类型
  `doc.questionmark`；双击进入目录；右键菜单（Refresh / Copy Path）；
  隐藏文件默认展示。
- 状态：加载中（ProgressView）/ 空目录（`ContentUnavailableView`
  “此文件夹为空”）/ 错误态（业务错误文案；`connectionLost` 显示
  Reconnect 按钮走 `SessionManager.reconnectSession`，其余显示 Retry 走
  `refresh()`）/ 面板不可用（Local：功能说明；Remote 未连接：Reconnect）。
- 底部状态：条目数 + 当前路径。
- 全部交互元素带 `accessibilityIdentifier`（`sftp.*`）；UI 绝不直接调用
  libssh2。

#### 7. 只读约束验证

产品代码 `libssh2_sftp_*` 实际调用集合（`grep` 实测）：
`init / shutdown / open_ex(OPENDIR) / readdir_ex / close_handle /
symlink_ex(REALPATH) / last_error`——全部为读取 / 列举 / 状态 / 导航类；
`write / unlink / mkdir / rmdir / rename / setstat / fsetstat` **零调用**
（出现的同名宏字样均为“宏不可用”说明注释）。本阶段未实现任何写操作、
传输或本地浏览能力。

#### 8. 测试

真实测试全部经**真实本机 sshd（127.0.0.1:22）+ 真实 libssh2**，
Private Key 认证（测试专用 ed25519 密钥 + authorized_keys 标记块，
退出清理）；夹具 `/tmp/macssh-phase9-<uuid>`：`dir-a`（含 nested.txt）/
`dir-b` / `empty` / `restricted`（chmod 000）/ `big`（1000 条目）/
`file.txt`（22 字节）/ `中文.txt` / `emoji-😀.txt` / `hello world.txt` /
`.hidden` / `symlink → file.txt` / 200 字符长文件名，路径经固定交接文件
`/tmp/macssh_phase9_fixture_path` 传递：

- `Tests/SSH/SFTPSessionTests.swift`（16 项，A–P；N / O 为首轮 P1 整改
  新增，P 为第二轮整改新增）：
  A 子系统初始化幂等且断开后释放；B `realpath(".")` 为绝对 HOME
  （绝不硬编码 `/` / `~`）；C 夹具根列举完整性与元数据（名称 / 大小 /
  权限 / mtime 与本地文件系统逐一对照）；D 子目录列举（`RemotePath.join`）；
  E `noSuchPath` 业务错误、连接存活；F 权限拒绝业务错误、连接存活；
  G 200 字符长文件名不截断；H 1000 条目目录完整列举（<15s，句柄归零）；
  I 列举进行中断开：不崩溃、不泄漏（句柄 / 子系统全释放）；
  J 拆除释放全部 SFTP 资源；K **Terminal 与 SFTP 同会话共存**
  （开 Shell → SFTP 列举 → Shell echo marker 仍可回显，`initCount == 1`）；
  L Reconnect 在全新连接重建子系统（绝不复用旧 `LIBSSH2_SFTP *`）；
  M 断开后 SFTP 操作优雅失败（`.connectionLost`，不崩溃、不挂起）；
  N **readdir EAGAIN 窗口竞态**（测试接缝挂起列举 → 并发 `disconnect()`：
  拆除必须停在排空屏障，不摘在途句柄、不抢先 shutdown；释放后列举以
  `.connectionLost` 退出、唯一一次关闭；连续 10 次迭代断言
  关闭数 == 打开数、无残留、无崩溃挂起）；
  O **收尾 closedir EAGAIN 窗口竞态**（认领后、`close_handle` 前挂起 →
  并发 `disconnect()`：closedir 在途期间绝不 `libssh2_sftp_shutdown`；
  释放后列举完整成功、拆除收尾；连续 10 次迭代同断言）；
  P **并发列举经操作串行门严格串行化（第二轮整改）**：第一个列举因
  EAGAIN 等价挂起持有串行门，第二个并发列举必须排在门外（在途计数 2、
  打开计数保持 1、登记中无第二句柄）；释放后第一个完整收尾，第二个得到
  **自己目标目录**的内容（后一请求绝不接走前一请求的响应）；连续 10 次。
- `Tests/SSH/SFTPServiceTests.swift`（13 项，A–M；M 为第二轮整改新增）：
  A 启动加载初始目录；B 进入子目录与 Parent 的原子提交；
  C Unicode / 隐藏 / 符号链接条目可见且目录优先排序；
  D 导航失败保持原路径与原列表、连接不断开，Retry 恢复可用列表；
  E 快速导航最后请求获胜（generation 防护）；F 根目录 Parent 空操作；
  G Reattach 绑定新连接并恢复最近成功路径；H stopBarrier 安全且终态；
  I 多会话隔离（同 Host 双连接互不干扰）；J 空目录 `.loaded` 空列表；
  K 大目录（1000 条目）属性随列举一次到达（无 N+1 stat，<20s）；
  L Terminal ↔ Files 面板切换 5 轮：子系统 `initCount == 1`、
  服务实例复用、浏览状态不变；
  M **快速导航确定性竞态（第二轮整改核心）**：第一条目录请求进入
  EAGAIN 等价挂起（接缝）后发起第二条导航——挂起窗口内打开计数停在
  基准+1（第二条绝不发起任何 `libssh2` 调用）、路径与加载态不变；
  释放后第一条以取消语义完整收尾（含 closedir），第二条随后执行，
  **最终路径与条目同时来自最后一个目标目录**；打开/关闭计数相等、
  无残留句柄、在途计数归零；连续 5 次（每次全新连接）。
- `Tests/SSH/SessionManagerTests.testAB`（第二轮整改 P2 回归，已纳入聚焦
  脚本）：连接过程中提前切 Files（认证前 `sftpService == nil`）→ 认证
  成功后运行时被补创建，Files 面板自动到达 `.loaded` 且路径 / 条目就绪。
- `Tests/SSH/RemotePathTests`（4 项）：`normalized / parent / join /
  isRoot` 纯语义（含 `..` 防御、双斜杠禁令、Unicode 名称）。

聚焦复验（`Scripts/run-phase9-focus.sh`，私钥路径，已纳入 P1 竞态测试
N / O / P、第二轮确定性竞态测试 M 与 P2 回归 testAB）连续三轮确认：
**34 项全部通过，0 失败 / 0 skip**（SFTPSession 16 + SFTPService 13 +
RemotePath 4 + SessionManager testAB）；确定性竞态迭代累计：M 15 次、
N / O / P 各 30 次，全部通过。

#### 9. 构建与验证结果（2026-08-30）

- `Scripts/build-app.sh`（全新 Derived Data）：Debug + Release arm64
  clean build 均 **BUILD SUCCEEDED**，项目代码 **0 warning**
  （build-for-testing 亦 0 warning）。
- Release `.app`：Mach-O arm64；`codesign --verify --strict` 通过；
  `otool -L` 仅系统库，无 `/opt/homebrew`、`/usr/local` 或动态
  libssh2/libssl/libcrypto（静态链接基线不变）。
- 全套回归（`Scripts/run-ssh-tests.sh`，真实本机 sshd，P1 整改后复跑）：
  **141 项执行 / 1 既定 skip**。
  - Phase 9 三个测试类 **31/31 全部真实通过，0 skip / 0 failure**：
    `SFTPSessionTests` 15（含 P1 竞态测试 N / O）、`SFTPServiceTests` 12、
    `RemotePathTests` 4。
  - P1 竞态测试 N / O 在**四轮独立运行**（聚焦两轮 + 全套回归 + 复验）
    中各连续 10 次迭代、累计各 40 次确定性竞态交错，全部通过。
  - `SessionManagerTests`（Phase 8）27/27、`KnownHostServiceTests` 13、
    `DependencyIdentityTests` 6、`HostEditorValidationTests` 5、
    `CredentialServiceTests` 4 通过 + 1 项既定 production 状态 skip；
    Phase 7 testQ（并发 Disconnect EAGAIN 归并）真实通过。
  - 16 项失败**全部是密码认证用例**（`RemoteTerminalTests` 10 项 +
    `SSHConnectionTests` 6 项），与 Phase 8 / Phase 9 首轮的失败集合完全
    一致，根因一致：代理环境无交互终端，脚本的
    `security add-generic-password -w` 密码提示读到 EOF，临时凭据未创建。
    属环境限制而非产品缺陷；密码认证路径的持续回归以用户交互运行结果
    为准。
  - 首轮结果中另有 2 项（`SFTPSessionTests.testM`、
    `SessionManagerTests.testY`）在回归运行的高频连接窗口内以
    `handshakeFailed(libssh2Code: -8)` / 连接建立超时失败——失败发生在
    连接建立阶段（本次整改未触碰的代码路径），**复验单独重跑均通过**，
    判定为本机 sshd 连接压力下的瞬时环境抖动。
- 安全基线不变：libssh2 `1.11.2_DEV @ be937743a85c4064a6399cee39e606672a401069`、
  OpenSSL `3.5.8`，`DependencyIdentityTests` 随回归执行。

#### 10. 当前已知问题 / 待验收项

- 凭据门控测试（密码认证用例）需在正常终端交互式输入本机密码后复验
  （代理环境无交互终端，与 Phase 8 一致属环境限制；私钥路径已全量通过）。
- SFTP Browser 的运行时 UI 交互（面板切换、双击导航、错误态按钮）需在
  真实桌面下人工确认（预览图已获用户确认并按图实现）。

#### 11. 验收阻塞修复（P1：目录句柄拆除所有权竞态，2026-08-30）

首轮验收不通过，阻塞项为 1 个 P1。用户给出的关键交错：

1. 目录列举因 EAGAIN 挂起；
2. `disconnect()` 从登记数组取出该句柄并调用 closedir；
3. closedir 再次因 EAGAIN 挂起；
4. 原列举任务恢复，发现句柄已不在登记数组，却仍无条件调用
   `closeDirectoryHandle()`；
5. 两条任务操作同一个 `LIBSSH2_SFTP_HANDLE *`——一方释放后另一方继续
   访问，形成 use-after-free / double-close。
6. 即使列举先从数组移除句柄，拆除仍可能在 closedir 尚未完成时执行
   `libssh2_sftp_shutdown`——数组“先删除再关闭”不构成所有权屏障。

根因：`SSHConnection` actor 在 EAGAIN readiness 等待期间可重入，列举任务
与拆除任务跨 await 交错；旧实现里登记数组只承担簿记，两路都可能关闭
同一指针，且拆除不等待在途列举（含其收尾 closedir）结束。

整改要求（用户指定，逐条满足）：

- 目录句柄只能有一个明确的 teardown owner；
- `disconnect()` 必须等待**所有在途列举及在途 closedir 完全结束**，
  才能执行 `libssh2_sftp_shutdown()`；
- 可控测试：强制 readdir / closedir 进入 EAGAIN 等价挂起，期间并发
  `disconnect()`，验证无 double-close、崩溃、悬挂、残留句柄；
- 该竞态测试至少连续运行 10 次。

整改措施（`MacSSH/Services/SSH/SFTPSession.swift` +
`SSHConnection.swift` 存储属性；产品路径零 UI / 业务层改动）：

1. **排空屏障（单一 teardown owner 的核心）**：整个列举（含收尾
   closedir）计入 `inFlightSFTPListingCount`；
   `closeSFTPResourcesForTeardown()` 在等在途初始化落定之后、关闭任何
   句柄之前，先经 `waitForInFlightSFTPListingsToDrain()` 等待计数归零。
   断开标志置位后新列举在入口即被拒绝，计数只减不增；在途列举的每个
   等待都有截止时间预算（列举 60s / closedir 3s），排空必然在有界时间
   内完成，拆除绝不悬挂。排空之后登记中残留的句柄已无主（在途列举都
   已自行收尾），拆除逐个关闭不再与任何任务竞争；`shutdown` 时绝无
   closedir 在途。
2. **认领式关闭所有权**：`sftpListDirectory` 收尾改为
   `claimDirectoryHandleForClose(_:)`——仅当本方在无跨 await 的 actor
   串行段内从登记中真正摘除了句柄才关闭；未认领到绝不触碰该指针。
   配合排空屏障，拆除在途期间登记永不被拆除侧摘除，所有权不会易手，
   结构上排除 double-close。
3. **确定性竞态测试接缝**（生产恒为 nil，沿用 Phase 8
   `testReadLoopExitHook` 先例）：`testSFTPAfterHandleOpenHook`
   （句柄登记后、首次 readdir 前——readdir EAGAIN 挂起窗口的确定性
   等价）与 `testSFTPBeforeHandleCloseHook`（认领后、`close_handle`
   前——closedir EAGAIN 挂起窗口的确定性等价）。
4. **测试仪表**：`sftpDirectoryHandleOpenCount`（OPENDIR 成功）与
   `sftpDirectoryHandleCloseCount`（`close_handle` 成功；EAGAIN 重试
   不重复计数），竞态测试断言两者相等——任何 double-close 都会使
   关闭数超出打开数。

新增测试（`Tests/SSH/SFTPSessionTests.swift`，RaceGate 门闩模式与
Phase 8 testX/Y 一致）：

- **testN（readdir 窗口）**：列举挂起在接缝 → 并发 `disconnect()` →
  断言拆除被排空屏障扣住（子系统未 shutdown、在途句柄未被摘除）→
  释放 → 列举以 `.connectionLost` 退出并完成唯一一次关闭 → 断开收尾，
  句柄归零、关闭数 == 打开数 == 1。
- **testO（closedir 窗口）**：列举完成、认领后挂起在接缝 → 并发
  `disconnect()` → 断言 closedir 在途期间子系统未被 shutdown（在途计数
  为 1、登记已摘除）→ 释放 → 列举完整返回、拆除排空后收尾，同一断言集。
- 两个用例**各自循环 10 次连续迭代**，且经两轮独立运行（累计 40 次
  确定性竞态交错）全部通过。

验证结果：

- `Scripts/run-phase9-focus.sh`（私钥路径，保留为常驻脚本）：
  **31/31 通过**（SFTPSession 15 + SFTPService 12 + RemotePath 4），
  两轮独立运行，0 失败 / 0 skip / 无崩溃无悬挂；build-for-testing
  0 warning。
- 全套回归（`Scripts/run-ssh-tests.sh`）结果见第 9 节整改后复跑数字。

#### 12. 第二轮验收整改（P1：快速导航重叠操作同一 SFTP 状态机 + 2 个 P2，2026-08-31）

第二轮复验不通过：1 个 P1 + 2 个 P2。

**P1：快速导航重叠操作同一个 SFTP 状态机。**旧实现新导航只执行
`operationTask?.cancel()` 随后立即启动新任务，不等待旧任务真正退出：
旧任务若正因 EAGAIN 等待 socket readiness，新任务会进入同一个
`SSHConnection`，两次 opendir/readdir 因 actor 重入而交错。vendored
libssh2 的 `open_state` / `readdir_state` 与在途 request ID 是
`LIBSSH2_SFTP` 子系统级共享状态——后一请求可能接走前一请求的响应，
页面显示路径 B 但列表来自路径 A，网络较慢或连续刷新时出现随机目录错误。
整改要求（用户指定，逐条满足）：

- 新导航必须先取消并等待旧加载任务**完整退出（含收尾 closedir）**，
  再启动新 SFTP 操作；并在 `SSHConnection` 内保留覆盖完整 SFTP 操作
  生命周期的串行门兜底；
- 确定性测试：第一条目录请求进入 EAGAIN 等价挂起后发起第二条导航，
  断言第二条在第一条完全收尾之前不调用 libssh2；
- 最终必须同时验证路径与条目都来自最后一个目标目录。

整改措施（双层防御）：

1. **业务层（`SFTPService.scheduleLoad`）**：新登记的加载任务在执行任何
   SFTP 操作前先 `await` 被取代旧任务的终值——旧任务可能仍因 EAGAIN 挂在
   连接层，只有等待其完全退出（含收尾 closedir）才能保证同一时刻没有两个
   任务进入同一个 `LIBSSH2_SFTP` 状态机；恢复后再校验代次与停止标志。
2. **连接层串行门（`SFTPSession.swift` 第二轮整改）**：
   `acquireSFTPOperationGate()` / `releaseSFTPOperationGate()` FIFO 串行门，
   覆盖 `realpath` / 列举（opendir → readdir → closedir）/ 拆除收尾的完整操作
   生命周期；旧操作因 EAGAIN 挂起（actor 让出）期间，新操作绝不进入同一状态机；
   释放时直接把所有权移交给队首（绝不先置空闲再争抢）。
3. **确定性测试 M（`SFTPServiceTests`，连续 5 次 × 全新连接）**：接缝把第一条
   目录请求停在 readdir 窗口（EAGAIN 等价，持有串行门）→ 发起第二条导航 →
   挂起窗口内打开计数停在基准+1（第二条绝不发起任何 `libssh2` 调用）、
   路径与加载态不变 → 释放后第一条以取消语义完整收尾（含 closedir），
   第二条随后执行，**最终路径与条目同时断言来自最后一个目标目录**
   （`dir-a` / `nested.txt`）；打开/关闭计数相等、无残留句柄、在途计数归零。
4. **连接层确定性测试 P（`SFTPSessionTests`，连续 10 次）**：第一个列举挂起持有
   串行门，第二个并发列举排在门外（在途计数 2、打开计数保持 1）；释放后各自得到
   自己目标目录的内容——后一请求绝不接走前一请求的响应。

**P2-1：连接中提前切 Files 卡在加载态。**连接过程中切到 Files 时因尚未认证，
`ensureSFTPService()` 只置 `activePane = .files` 直接返回；认证成功后连接流程只处理已存在的 `sftpService`，Files 永远停在加载态（必须手动切回 Terminal 再切 Files）。
整改：`SessionManager.runConnectFlow` 认证成功后，若 `sftpService == nil` 且 `activePane == .files`，补调用 `session.ensureSFTPService()` 创建并启动 SFTP 运行时；回归测试 `SessionManagerTests.testAB`（认证前 `sftpService == nil` → 认证成功后补创建，Files 自动到达 `.loaded`）并纳入聚焦脚本。

**P2-2：`run-phase9-focus.sh` 退出码与变量引用。**旧脚本使用 `$TEST_LOG）`：
非 UTF-8 locale 下中文右括号被解析进变量名，出现 `TEST_LOG…: unbound variable`；
EXIT 清理 trap 又把最终退出码掩盖成 0，测试失败也被报告为成功。整改：全部改用具名括号 `${TEST_LOG}`；EXIT trap 以 `local rc=$?` 捕获原始退出码、清理后 `exit "$rc"`——实测：测试失败 → 脚本退出码 1，构建失败 → 1，全部通过 → 0，失败绝不再被掩盖成 0。

**建连限流噪音加固（测试基础设施，不弱化任何产品断言）**：验证期间观察到本机
macOS sshd 在数十次连续建连压力下瞬时丢弃新连接或关闭新建 Channel（失败恒发生
在**建连阶段**，与整改代码路径无关，单独重跑均通过）。加固：两个 SFTP 测试类的建连辅助有限重试 3 次（退避 0.5 秒）；三个 10 次迭代竞态测试迭代间增加 200 毫秒间隔；testAB 会话级有限重试 3 次（退避 1 秒）。加固后聚焦套件连续三轮稳定全绿。

验证结果（2026-08-31）：

- `Scripts/run-phase9-focus.sh`（已纳入 P1 竞态 N / O / P、确定性竞态 M 与
  P2 回归 testAB）：**34 项全部通过，0 失败 / 0 skip**，连续三轮（含全量构建）；
  确定性竞态迭代累计：M 15 次、N / O / P 各 30 次，全部通过。
- `Scripts/build-app.sh`：Debug + Release arm64 clean build 均 BUILD SUCCEEDED，
  0 warning；codesign 验证通过；静态链接基线不变。
- 退出码行为实测：测试失败轮脚本以 1 退出、通过轮以 0 退出（不再被 trap 掩盖）。

本阶段明确未实现（Phase 9 禁止范围，全部遵守）：

- Upload / Download / Rename / Delete / Mkdir / Create / Chmod / Edit、
  拖放传输、Transfer Manager（Phase 10 / 11 范围）。
- 本地文件浏览器、双面板、任何写操作入口。
- `libssh2_sftp_write / unlink / mkdir / rmdir / rename / setstat` 调用。

### Phase 10：SFTP 文件操作（upload / download / rename / delete / mkdir）

状态：**首轮验收两个 P1 整改完成，等待复验**

完成日期：2026-08-31（首轮）／ 2026-08-31（P1 整改）

口径（计划书）：Phase 10 = SFTP 文件操作 **upload / download / rename /
delete / mkdir**，五个操作本轮全部提供用户入口并真实测试。传输运行时
（状态机 / Progress / Speed / Cancel）属计划书 Phase 11 Transfer Manager
范围，作为传输固有支撑**提前落地的子集**保留——**Transfer Queue（多文件
队列）未实现**，1 GB / 10 GB 流式测试属 Phase 11 验收项，本阶段不做。
首轮实现把 Phase 10 写成"Upload / Download + Transfer Manager"、且
rename / delete 仅传输内部使用、mkdir 缺失、断线残留被测试掩盖，均已整改（§13）。

#### 1. 总体架构

在 Phase 7（Remote SSH Terminal）、Phase 8（多 Session 管理）与 Phase 9
（只读 SFTP Browser）之上，建立**单文件流式**上传 / 下载与 Transfer
Manager。Terminal、SFTP Browser 与传输共用**同一条已认证
`LIBSSH2_SESSION`**：

```text
SFTPBrowserView / TransferListView（SwiftUI：只观察，绝不触碰 libssh2）
  └── TransferManager（@MainActor @Observable，AppState 持有：入口 / 单活跃 / 节流 / 拆除屏障）
        └── SFTPTransferService（执行层：流式分块 / 临时文件 / 发布 / 清理）
              └── SFTPFileOperations（extension SSHConnection，actor 串行边界）
                    └── libssh2 SFTP（OPEN FILE / READ / WRITE / CLOSE / RENAME / UNLINK / STAT）
```

核心不变量：

- **禁止整文件进内存**：1 MiB 分块（`SFTPTransferService.chunkSize =
  1_048_576`）；100 MB 往返实测 RSS 增幅远低于文件体积。
- **Completed 语义**：字节数到达绝不等于完成——Completed 只能在数据完成 +
  句柄正确关闭 + 发布 / 替换成功之后出现。
- **取消是协作式且幂等**：`TransferCancellation` 标志是唯一信号源；执行任务
  从不被 `Task.cancel()`（保证收尾——句柄关闭 + 临时文件清理——仍能通过连接层
  校验），每个分块边界轮询；`cancelling` 是收尾过渡态。
- **全局单活跃传输**：新请求在有活跃任务时拒绝并提示"已有文件正在传输，
  请等待当前任务完成或取消。"；会话不可用时提示"当前会话不可用。"。
- **默认不覆盖远端已有文件**：上传前远端 stat 预检，命中时失败文案"远程文件已存在。Phase 10 当前不会自动覆盖该文件。"。
- **不独占连接**：传输经 Phase 9 FIFO 串行门（`acquireSFTPOperationGate`）
  进入，但按分块持门 + 协作调度——门在分块之间释放，Terminal 读取循环与
  Browser 列举不被饿死（共存测试实测）。
- **连接丢失 → Failed 不续传**：失败文案"SSH 连接已断开，传输失败。"；
  上传在途断线时远端临时文件**必然残留**（清理物理上不可能），失败文案追加
  残留文件名如实告知，绝不假装已清理（P1-2 整改）；无断点续传、无自动重连（任务书明确禁止）。
- **禁止范围（全部遵守）**：递归 / 目录传输 / 并发传输 / 多文件队列 / 拖放传输 /
  断点续传；rename / delete / mkdir 是本轮提供的用户级文件操作（计划书 Phase 10 范围）。
- 传输记录纯内存、不进 SwiftData、绝不携带 Secret；日志只记生命周期事件。

#### 2. 数据与运行时模型（`MacSSH/Models/TransferTask.swift`，305 行）

- 状态机 `preparing → transferring →（cancelling）→ completed / failed /
  cancelled`；终态写入后不再变化（`isTerminal` 保护）。
- 进度单调（`reportProgress` 只增不减）；速度为整段平均，分母非正置 0，
  绝不出现 NaN / Infinity / 负值；未知大小时进度为 indeterminate，绝不伪造 100%。
- `TransferError` 是执行层 → 用户可见中文文案的唯一映射点：
  connectionLost(remoteResidue:) / remoteFileExists / permissionDenied /
  remoteFileMissing / generic；libssh2 / FX 原始码只进安全日志，不进用户可见信息。
  connectionLost 携带残留文件名关联值：上传在途断线时文案明示"远端可能残留临时文件 <名称>，可稍后手动清理。"。
- 展示文案（准备中 / 传输中 / 正在取消 / 已完成 / 失败 / 已取消）与字节格式化由任务对象自带，UI 只读。

#### 3. 连接层文件操作（`MacSSH/Services/SSH/SFTPFileOperations.swift`，637 行）

`extension SSHConnection`——全部真实文件级 `libssh2_sftp_*` 调用只发生在这里：

- 文件打开（读写两模式）/ 读 / 写 / 关闭 / `rename` / `unlink` / `stat` /
  `mkdir`（P1-1 整改新增 `sftpCreateDirectory`：`libssh2_sftp_mkdir_ex`，权限 0o755），
  全部经 Phase 9 FIFO 串行门与 EAGAIN readiness 等待（沿用既有
  `waitForLibssh2Readiness`），每次循环带截止时间与断开 / 取消校验；
  rename / unlink / mkdir 为传输内部与用户级操作共用的唯一底层实现。
- **`SFTPFileHandle` 包装**：`OpaquePointer` 非 Sendable，引入
  `struct SFTPFileHandle: Equatable, @unchecked Sendable` 跨 actor 传递；
  写缓冲为 `[UInt8]`（Sendable）+ partial write 重试（`removeFirst(written)`）。
- **认领式关闭所有权**（沿用 Phase 9 句柄模式）：文件句柄登记在
  `openSFTPFileHandles`；`claimFileHandleForClose` 仅当本方在无跨 await 的
  actor 串行段内真正摘除句柄才关闭——结构上排除 double-close。
- **拆除排空屏障**：每个文件级操作（连同收尾关闭）计入
  `inFlightSFTPFileOperationCount`；`disconnect()` 先等在途操作归零再关闭残留句柄与子系统。
- **测试仪表**：`sftpFileHandleOpenCount` / `sftpFileHandleCloseCount`
  （配对断言相等——任何 double-close 都会使关闭数超出打开数）、
  `openSFTPFileHandleCount`（断言归零）、`inFlightSFTPFileOperationCount`。
- **Partial write 仪表与确定性接缝**：`sftpFileWriteCallCount`（写调用计数）与
  `setTestSFTPFileWriteMaxBytesPerCall(_:)`（钳制每次写入提交字节数——服务器真实只写入该量，
  账面与真实一致，绝不伪报已写字节）；生产恒为不钳制。
- **确定性测试接缝**（生产恒为 nil）：
  `setTestSFTPFileTransferChunkHook(armed:_:)`（每分块完成后）与
  `setTestSFTPAfterFileHandleOpenHook`（句柄打开后）。

#### 4. 传输执行层（`MacSSH/Services/Transfer/SFTPTransferService.swift`，395 行）

- **上传**：本地流式读 1 MiB → 写远端临时文件 `.macssh-upload-<UUID>.partial`
  （目标同目录）→ 关闭句柄 → `rename` 发布到目标名；连接存活的失败 / 取消路径先 `unlink`
  清理临时文件再抛出，无残留；**连接断开时清理物理上不可能，残留如实存在，
  失败文案追加残留临时文件名**（P1-2 整改，绝不假装已清理）。远端预检：目标已存在 →
  `remoteFileExists`；目标目录不可写 → `permissionDenied`（"权限不足，无法完成传输。"）。
- **下载**：远端流式读 1 MiB → 写本地临时文件 → 关闭句柄 →
  `FileManager.replaceItemAt` 原子发布（目标不存在时等同原子放置）。
- **本阶段发现并修复的产品缺陷**：`FileManager.replaceItemAt(_:withItemAt:)`
  返回的是**新文件所在位置**的 URL 而非旧文件备份；初版误将其当作旧文件删除，
  导致下载完成后文件失踪（聚焦测试 testA / testC 暴露，独立脚本复现确认）。
  修复：绝不删除返回值，发布后追加 `fileExists` 校验。
- 上传 / 下载的失败、取消、连接丢失路径全部完成收尾（句柄关闭 + 清理），
  随后才写入终态；`completed` 前所有条件（数据完成 + 句柄关闭 + 发布成功）齐备。
- 清理失败不改变传输终值，仅记安全日志（`AppLogger.app.error`）。

#### 5. TransferManager（`MacSSH/Services/Transfer/TransferManager.swift`，328 行）

- `AppState` 持有的 `@MainActor @Observable` 稳定对象：切换页面 / 切换会话 /
  关闭 Transfers 面板都不影响传输；UI 只观察。
- `requestUpload` / `requestDownload` 同步入口：单活跃检查 → 会话可用性检查 →
  创建 `TransferTask` 并启动执行任务；拒绝以返回值的 `rejection` 文案交给 UI 展示。
- 进度上报节流（`lastProgressCommit`），终态后不再接受进度写入。
- `clearFinished` 只清理终态任务，活跃任务不动。
- **拆除屏障 `cancelAndAwaitTransfers(forSession:)`**：取消该会话全部活跃传输并
  `await` 每个执行任务的终值——保证句柄关闭与临时文件清理完成，绝不与随后的连接拆除交错。

#### 6. UI 与会话集成（预览图已获用户确认后实现）

- Files 页：**Upload**（`NSOpenPanel`，选择层即排除目录）与 **Download**
  （`NSSavePanel`，仅选中的普通文件可下载；目录 / 符号链接 / 特殊文件禁用），
  面板期间不阻塞 SSH actor；拒绝与失败经页面提示展示，不打断浏览。
- Transfers 页：`TransferListView` 展示方向 / 会话 / 文件名 / 进度条 /
  字节与速度文案 / 状态；传输中可 Cancel（幂等）；`clearFinished` 清理终态条目。
- 关闭确认：有活跃传输的会话关闭需确认（`requiresCloseConfirmation`），
  RootView 确认文案明示"将取消进行中的文件传输"。
- `SessionManager.teardown` 顺序（Remote）：**传输屏障**（取消并等待活跃传输完成清理）→ SFTP 列举屏障 → `stopBarrier()`（Channel）→ `disconnect()`——传输先于一切 SFTP 拆除。
- 改动面：`AppState`（装配）、`RootView`（确认文案）、`SFTPBrowserView`
  （面板与提示）、`TransferListView`、`SessionManager`（teardown 顺序）、
  `SFTPSession` / `SSHConnection`（仪表与接缝存储）；既有 Phase 7/8/9 行为不变。

#### 7. 用户级文件操作：业务层（P1-1 整改，`SFTPService`，399 行）

- 三个入口（@MainActor，与列举共用同一 FIFO 串行门 / EAGAIN / 拆除排空）：
  `renameEntry(_:to:)`（同级重命名，`flags=0` posix-rename 协议级防覆盖）、
  `deleteEntry(_:)`（仅普通文件；目录 / 符号链接 / 特殊文件被业务层拦截，
  避免递归删除）、`createDirectory(named:)`（0o755）。
- 名称校验 `sanitizedEntryName`：去首尾空白；拒绝空名 / 含 `/` / `.` / `..`，
  本地拦截文案"名称无效：不能为空、包含 / 或为 . / ..。"。
- 操作为原子服务器调用，不可取消；运行器 `runFileOperation` 以任务跟踪，
  `stopBarrier()` 追加 await 其终值——拆除不与其交错；成功后 `refresh()` 刷新列表。
- 失败文案（`fileOperationNotice` 交给 UI 弹窗）："权限不足，无法完成操作。" /
  "目标不存在，请刷新后重试。" / "SSH 连接已断开。" /
  "操作失败：目标名称可能已存在，或服务器拒绝。" / "仅支持删除普通文件。" /
  "目标已不在当前目录，请刷新后重试。"。

#### 8. 用户级文件操作：UI（预览图已获用户确认后实现，`SFTPBrowserView`，557 行）

- 路径栏新增"新建文件夹"按钮（`folder.badge.plus`）。
- 条目行右键菜单："重命名…"与"删除"（非普通文件删除禁用，`role: .destructive`）。
- 四个原生 alert：新建文件夹（TextField 输入 + 创建 / 取消）、重命名（预填现名 +
  重命名 / 取消）、删除确认（"删除后无法撤销。"）、操作失败（观察 `fileOperationNotice`）。
- UI 只观察 / 只发起，绝不触碰 libssh2；与既有 Upload / Download / 导航 / 刷新共存。
- 验收口径（计划书）：上传后在 Terminal `ls` 可见文件；下载后 Finder 可打开；
  rename / delete / mkdir 均在真实本机 sshd 上由自动化测试验证（§9）。

#### 9. 真实测试（本机 sshd + 真实 libssh2，聚焦 26 项全过）

`Tests/SSH/SFTPTransferTests.swift`（14 项，1144 行）：

- testA：尺寸矩阵（0 / 1 / 1 024 / 65 536 / 131 089 字节）上传 + 下载字节精确往返。
- testB：中文 / emoji / 空格 / 引号文件名往返。
- testC：100 MB `/dev/urandom` 往返 + CryptoKit SHA256 三方一致（本地源 / 本地下载 / 远端经 SFTP 读回）+ RSS 增幅上界断言（< 40 MiB，证明内存不随文件大小增长）。
- testD：远端同名已存在 → 不覆盖 + 规定文案。
- testE：下载源缺失 / 非普通文件拒绝。
- testF：上传到只读目录（555）→ 权限拒绝 + 规定文案，连接保持健康。
- testG / testH：各 10 次取消（上传 / 下载）——幂等、临时文件无残留、句柄仪表配对。
- testI：连接丢失（分块接缝门闩挂起期间断开）→ Failed + 规定文案、不续传；
  拆除前先释放门闩避免排空屏障与门闩互等。**诚实断言（P1-2 整改）**：
  断线后远端 `.partial` **确实残留**（先断言残留存在 + 失败文案含残留文件名，
  再清理），绝不手工删除后再断言"无残留"。
- testJ：20 次上传 + 下载生命周期，仪表全程配对。
- testK：上传与 Terminal 共存——Shell echo 副作用文件 + ping 输出 + Ctrl+C 均正常。
- testL：上传与 Browser 导航共存（传输分块持门不独占）。
- testM：单活跃拒绝 + 跨会话隔离。
- testN（新增，高风险点确定性证据）：接缝把每次写入提交字节压到 100 KB，
  强制 `offset += written` 重试循环每分块真实执行 11 次以上；断言远端内容
  逐字节一致 + 写调用数远大于分块数 + 无临时文件残留 + 句柄仪表配对。

`Tests/SSH/SFTPFileOpsTests.swift`（8 项，483 行，P1-1 整改新增）：

- testA：重命名提交成功 + 列表刷新。
- testB：重名目标已存在 → 失败不覆盖 + 规定文案。
- testC：删除普通文件（远端真实消失）。
- testD：目录删除被业务层拦截（"仅支持删除普通文件。"）。
- testE：mkdir 成功 + 权限 0755。
- testF：重复同名 mkdir 失败 + 规定文案。
- testG：只读目录（555）内 mkdir 权限拒绝 + 连接保持健康。
- testH：非法名称（空 / 含 `/` / `.` / `..`）本地拦截，不发起服务器调用。

`Tests/SSH/TransferManagerTests.swift`（4 项，379 行）：

- testA：进度单调 / 速度安全（无 NaN / 负值）/ 终态保护。
- testB：入口拒绝文案（会话不可用 / 单活跃）。
- testC：`clearFinished` 只清终态。
- testD：**真实链路**（建连 → Files 加载 → 3 MB 上传停在分块接缝 →
  `requestClose` 出现 `pendingCloseConfirmation` → `confirmClose` →
  任务 `.cancelled` + 会话移除 + 句柄仪表配对 + 临时文件无残留）。

聚焦脚本 `Scripts/run-phase10-focus.sh`（私钥路径，不触碰 Keychain 密码；
夹具 `upload / readonly(555) / restricted(000)` + 交接文件；EXIT trap 保留原始退出码；
本轮已纳入 SFTPFileOpsTests）。
结果：**26/26 通过，0 失败 / 0 skip**，整改轮连续两轮全绿。

testI 的远端残留处理（P1-2 整改）：断线后 `.partial` 物理上无法清理（不重连是任务书要求），
测试**先诚实断言残留存在与失败文案含残留文件名，再清理**；各用例使用独立文件名，不再互相污染。

#### 10. 构建与验证结果（2026-08-31，P1 整改后）

- `Scripts/build-app.sh`（全新 Derived Data）：Debug + Release arm64 clean
  build 均 **BUILD SUCCEEDED**，项目代码 **0 warning**；`codesign --verify
  --strict` 两个产物均满足 Designated Requirement。
- Release `.app`：Mach-O arm64；`otool -L` 仅系统库，无 `/opt/homebrew`、
  `/usr/local` 或动态 libssh2 / libssl / libcrypto（静态链接基线不变）；
  体积 **13 MB**（与 Phase 9 基线持平，无膨胀）。
- 聚焦套件：**26/26 通过**（SFTPTransferTests 14 含 testN + SFTPFileOpsTests 8 +
  TransferManagerTests 4），整改轮连续两轮；含 100 MB + SHA256、10×2 取消、
  20×生命周期、Terminal / Browser 共存、关闭会话取消传输真实链路、
  强制 partial write、断线诚实残留断言。
- 全套回归（真实本机 sshd，171 项执行）：**153 通过 / 1 失败 / 17 既定 skip**。
  唯一失败为 `SSHConnectionTests.test_IdleCPUAfterPrivateKeyConnected`（30 秒空闲
  CPU 预算 1.0 秒，实测 1.394 秒）：单独复验**通过**，归因回归当时系统负载抖动——
  该用例仅建私钥连接后空闲，本轮整改未触碰其代码路径；其余全部真实通过，
  **Phase 10 的 26 项在全量套件中真实执行并通过**，含双 testQ。
  17 项 skip 的构成：16 项密码认证用例（需交互输入本机账户密码创建临时 Keychain 凭据——
  代理环境无交互终端，与 Phase 8 / 9 一致属环境限制）、1 项生产凭据校验（既定）。
- `git diff --check` 通过；安全基线不变（libssh2 `1.11.2_DEV @
  be93774…`、OpenSSL `3.5.8`，`DependencyIdentityTests` 随回归执行）。

#### 11. 本阶段明确未实现（遵守计划书阶段划分）

- Transfer Queue（多文件队列 / 并发传输）——计划书 Phase 11 范围；本轮仅提前落地其单任务运行时子集。
- 1 GB / 10 GB 流式测试——计划书 Phase 11 验收项；本轮最大 100 MB。
- 递归传输、目录传输、拖放传输、断点续传。
- Chmod / Edit / 目录删除（删除仅限普通文件，避免递归）。
- 传输完成通知、传输历史持久化（SwiftData）。

#### 12. 当前已知问题 / 待验收复验项

- 凭据门控测试（16 项密码认证用例）需在正常终端交互式输入本机密码后复验（环境限制，与 Phase 8 / 9 一致；私钥路径已全量通过）。
- 文件操作相关 UI 的运行时交互（新建文件夹 / 重命名 / 删除对话框、传输面板、关闭确认）需在真实桌面下人工确认（预览图已获用户确认并按图实现）。
- 连接丢失场景远端 `.macssh-upload-*.partial` 临时文件物理上无法自动清理（不续传不重连是任务书要求）；失败文案已如实告知残留文件名，由用户手动处理。
- 全套回归中空闲 CPU 用例因系统负载抖动单次超限，单独复验通过；如需在更高负载环境下复验可重跑该用例。

#### 13. 首轮验收整改记录（两个 P1 + 高风险点，2026-08-31）

首轮验收结论：不通过。整改逐项对应：

- **P1-1 正式范围未完成**：计划书要求 Phase 10 = upload / download / rename /
  delete / mkdir。整改：mkdir 底层新增（`sftpCreateDirectory`）；rename / delete
  从仅传输内部使用升级为**用户级入口**（行右键菜单 + 名称校验 + 错误文案）；
  UI 新增"新建文件夹"按钮与三个对话框（预览图确认后实现）；
  新增 `SFTPFileOpsTests` 8 项真实测试。传输运行时（Phase 11 提前落地子集）
  经用户确认保留，文档口径改回计划书（本节标题 / 状态 / §11）；
  Transfer Queue 不做，避免继续越界。
- **P1-2 断线残留被掩盖**：`TransferError.connectionLost` 增加残留文件名关联值；
  上传在途断线的失败文案明示残留；testI 改为**先断言残留存在 + 文案含文件名，
  再清理**，删除了原先"手工删除后断言无残留"的掩盖行为；不做自动重连清理（任务书禁止）。
- **高风险点 partial write 证据不足**：新增写钳制接缝 + 写调用计数仪表；
  testN 强制每次写入只提交 100 KB，断言重试循环真实执行（> 11 次/分块）且逐字节完整。
- 验收 5 高风险点其余四项（100 MB 流式、Cancel 无残留、不饿死 Terminal、
  Session 释放顺序）首轮已实证，整改轮复跑继续保持。
- 验证证据：聚焦 26/26 连续两轮；全量回归 153 通过 / 17 既定 skip，
  唯一失败（空闲 CPU）单独复验通过并如实归因；Debug / Release clean build
  0 warning；codesign、otool、体积、`git diff --check` 全部达标。

## 下一阶段

Phase 10（SFTP 文件操作：upload / download / rename / delete / mkdir）首轮验收
两个 P1 已整改完成并等待复验：五操作用户入口齐备（预览图确认后实现）、
断线残留如实告知 + 诚实测试、强制 partial write 确定性证据。聚焦套件 26/26 连续两轮全绿；
全套回归 153 通过（17 项既定 skip，1 项空闲 CPU 环境抖动失败已单独复验通过）；
Debug / Release clean build 0 warning、codesign 通过、静态链接基线不变、体积 13 MB。
传输运行时（状态机 / Progress / Speed / Cancel）作为 Phase 11 提前落地子集保留，
Transfer Queue 与 1 GB / 10 GB 流式测试未做。停止开发。验收通过后，下一阶段为计划书
Phase 11（Transfer Manager：Queue / Progress / Speed / Cancel / Failed / Completed，
1 MB–10 GB 流式测试），只有用户明确要求后才能开始。
