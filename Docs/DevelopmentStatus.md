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

## 下一阶段

Phase 6 已复验通过（PASS），Phase 6 final cleanup（`default.profraw` 清理 +
Known Hosts Forget 失败错误提示）已完成。本轮修改不触及 SSH 安全流程，
13 项 KnownHostServiceTests 全过，Debug/Release arm64 clean build 零 warning，
`git diff --check` 通过。停止开发，等待用户确认。

下一阶段是 Phase 7（Remote SSH Terminal），只有用户明确要求后才能开始。
