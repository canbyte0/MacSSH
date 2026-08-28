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

## 下一阶段

Phase 5 已完成并停止开发，等待用户验收。下一阶段是 Phase 6（SSH 安全：KnownHost 持久化 + Private Key Authentication），只有用户验收 Phase 5 并明确要求后才能开始。
