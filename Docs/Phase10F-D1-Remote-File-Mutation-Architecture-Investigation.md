# MacSSH 1.1 — Phase 10F-D1 Remote File Mutation Architecture Investigation

状态：只读架构调查与发布语义冻结
日期：2026-09-17
范围：不实现 Remote file mutation，不修改生产代码、测试、Provider、UI、工具目录、Package 或 SwiftTerm。

## Repository

- Checkout：/Users/msl/msl_coding/MacSSH
- 新分支：feature/macssh-1.1-agent-remote-file-mutation
- 基线与当前 HEAD：958fc1c9d1046a7714d2d2ca39a2f05d99f971aa
- 分支创建成功；没有删除或改写既有 terminal-mutation / file-mutation 分支。
- 既有未跟踪 Docs、GUI evidence 与 ThirdParty/SwiftTerm-fork-clean/ 均保持原样。
- D1 新增的唯一工作产物是本架构报告；没有 staged source change、没有 commit、没有 push。

依赖身份：

- ThirdParty/MANIFEST.txt:4-15、43-48：libssh2 来源为官方仓库，精确 commit 为 be937743a85c4064a6399cee39e606672a401069，版本标记为 1.11.2_DEV，静态库 SHA-256 为 27a520a8fdbd3f79def139955fa5a91c8d82140ca9da6ae3c1af6560979c0141。
- ThirdParty/libssh2/include/libssh2_sftp.h:45-51：当前头文件的 SFTP protocol version 为 3。
- MacSSH.xcodeproj/project.pbxproj:1555-1569 与 Package.resolved：SwiftTerm 使用 canbyte0/SwiftTerm 的固定 revision 040d1271734694d046b77050b5bfc7aa483423ff；D1 未改变 Package。
- 当前 Debug build 使用 Swift 6.0、macOS 14.0，BUILD SUCCEEDED；构建日志没有 compiler warning 或 error。Xcode 的多 destination 提示属于构建环境提示，不是源码 warning。

证据等级：

- 已核实：当前 checkout 的源代码、精确 vendored header、随依赖保存的 man page、静态库符号和现有测试源码。
- 未核实：本机真实 Remote fixture 上的服务器行为；本阶段没有现存 key/fixture，因此没有创建 fixture、修改 sshd 或写入远端。
- 不把已有测试源码中的注释或断言当成新鲜 live evidence；它们只代表当前意图和待验收行为。

## Current SSH/SFTP Architecture

### SSHConnection 是唯一 libssh2 所有者

MacSSH/Services/SSH/SSHConnection.swift:79-86 将 SSHConnection 定义为 actor，并明确一个 LIBSSH2_SESSION 只有一个 actor owner。所有 libssh2 与 socket 调用都在 actor 隔离内；EAGAIN 通过 poll 与 libssh2_session_block_directions 等待。

MacSSH/Services/SSH/SSHConnection.swift:87-100 的 Configuration 目前只有 hostID、hostname、port、username、认证类型和 credential/key 引用，没有公开的 connection incarnation token。

MacSSH/Services/SSH/SSHConnection.swift:158-165 保存 session 与 socket；:237-243 保存共享 SFTP 子系统；:245-290 登记目录句柄、文件句柄和初始化/排空任务；:310-322 以 FIFO gate 串行化共享 LIBSSH2_SFTP 状态；:324-341 提供初始化、句柄和 partial-write 计数器。

SSHConnection.connect 从认证完成后才进入 connected，见 :414-499；connect 不自动初始化 SFTP。SFTP 是惰性建立的共享子系统，Terminal、Files sidebar、Remote read façade 和既有 Transfer 都复用同一个 SSHConnection 上的 SFTP。

### SFTP 子系统生命周期

MacSSH/Services/SSH/SFTPSession.swift:97-147 的 openSFTPSubsystemIfNeeded 只对已认证 session 惰性调用 libssh2_sftp_init，并用 sftpInitTask 去重。

MacSSH/Services/SSH/SFTPSession.swift:149-199 的 sftpRealpath 使用服务端 REALPATH；当前缓冲为 4096 字节。:224-273 的 sftpListDirectory 使用 opendir/readdir/closedir，并从 LIBSSH2_SFTP_ATTRIBUTES.permissions 判定 regular file、directory、symlink 或 other。

MacSSH/Services/SSH/SFTPSession.swift:557-645 的 teardown 先等待初始化、目录列举、文件操作和 SFTP gate，再关闭残留句柄，最后把 sftpSubsystem 置 nil 并调用 libssh2_sftp_shutdown。:658-668 的 validateSFTPOperation 会在每次跨 await 恢复后检查取消、disconnect requested、当前 session 指针和当前 sftp 指针。

这套机制能防止旧指针在 teardown 后继续被使用，但它不是 Agent approval 可持久化的远端文件 identity。它只在同一个 actor incarnation 内保护 libssh2 生命周期。

### 当前文件操作层

MacSSH/Services/SSH/SFTPFileOperations.swift:64-86 定义当前 wrapper 使用的打开标志和 mode：

- read = 0x1
- write = 0x2
- creat = 0x8
- excl = 0x20
- 上传临时文件 mode = 0600
- 用户创建目录 mode = 0755

:127-174 的 sftpStatFile 使用 LIBSSH2_SFTP_STAT，因此会跟随 symlink；当前生产 wrapper 没有 lstat 或 readlink 方法。:183-200 的只读打开和临时写入打开都登记文件句柄并受 SFTP gate 保护。

:269-370 的 read/write chunk 处理 EAGAIN 与 partial write；写入调用方必须使用已确认字节数推进 offset，不能重发已确认部分。:395-463 的 close 只保证 SFTP handle close，不等于远端 fsync 或断电持久化。

:473-514 的 sftpRenameFile 调用的是 libssh2_sftp_rename_ex，flags 为 0。:519-550 使用 unlink，:555-586 使用 mkdir。

### Teardown、reconnect 与传输的现有边界

SessionManager.close 流程在 SessionManager.swift:309-337 先等待传输、SFTP browser、Remote terminal，再 disconnect SSHConnection。

Reconnect 在 SessionManager.swift:342-391 释放旧 runtime 和旧 connection，然后创建全新的 SSHConnection。:483-500 重新 attach SFTP service，并通知 pending Transfer queue。

当前 TransferManager.swift:383-441 在真正执行 transfer 时解析当时可用的 connection；:636-657 规定 reconnect 时 running transfer 取消，pending transfer 可以在新连接上重新排队。这是既有用户 Transfer 的专门语义，不能复制给未来的 Agent Remote approval。Agent approval 必须绑定旧 incarnation，不能按 sessionID 在执行时重新解析到新 connection。

### 当前 Agent Remote 能力仍然是只读

当前 Remote resolver 为 MacSSH/Services/Agent/Tools/AgentRemoteServiceResolver.swift:5-53：

- 只按显式 origin sessionID 查找；
- 只取现有、已认证且 phase 为 connected 的 SSHConnection；
- 不创建连接、不读取凭据、不 fallback 到其它 session 或 Local；
- 返回 SSHConnectionAgentRemoteFileClient。

SSHConnectionAgentRemoteFileClient 在同文件 :58-203 只调用 canonicalPath、stat、list、open-for-read、read chunk、close。AgentRemoteReadOnlyFileClient.swift:5-40 也只暴露这六个原语，明确不暴露 write、upload、rename、unlink、mkdir、rmdir、chmod、chown、truncate、exec 或 shell。

AgentToolModels.swift:5-19 的静态工具集合恰好是七个工具：

1. get_terminal_context
2. get_current_directory
3. list_directory
4. read_file
5. run_command
6. send_to_terminal
7. write_file

AgentToolModels.swift:48-62 明确 write_file 不支持 Remote。AgentToolDefinition.swift:82-89 将 write_file 描述为 Local text file，并明确 Remote file mutation is not supported。AgentToolRouter.swift:52-55 对 Remote unsupported tool 返回 unsupportedForSession，:98-103 对 write_file 只返回 fileMutationRequiresApproval，不触碰 executor，也不提供 Remote fallback。

因此 D1 的安全基线是：Remote file mutation 当前不存在，Provider Remote dispatch 当前关闭。

## Current Upload Semantics

当前 SFTPTransferService.swift:61-180 的上传流程如下：

1. TransferManager.swift:444-478 先对最终目标执行 stat 预检；这是用户体验层的早期拒绝，不是 no-clobber authority，因为预检与发布之间存在 TOCTOU。
2. 在目标同目录生成 .macssh-upload-UUID.partial。临时文件名由应用生成，目标名不来自 Provider。
3. 通过 sftpOpenTemporaryFileForWrite 使用 WRITE|CREAT|EXCL 和 0600。现有临时名被占用时不会覆盖。
4. 以 1 MiB 分块读取本地文件并写入远端；partial write 通过 offset += written 完整推进。
5. 关闭临时句柄，stat 临时文件检查远端大小与已传输字节数一致。
6. 使用 sftpRenameFile(tempPath, remoteTarget)，实际调用 rename_ex(flags=0)。
7. 失败或取消时尝试 unlink 临时文件；连接已经丢失时，远端临时文件可能残留，失败文案会携带临时文件名。当前代码没有 fsync。
8. 当前完成语义是“数据完整、句柄关闭、大小校验、rename 返回成功”，不是“远端已获得 crash/power-loss durability”。

当前代码注释在 SFTPFileOperations.swift:467-468 把 flags=0 描述成 posix-rename@openssh.com 语义，但实际调用在 :492-499 是 generic libssh2_sftp_rename_ex，而不是 libssh2_sftp_posix_rename_ex。该命名不作为 D1 证据，也不在 D1 修改。

本地依赖随附的 libssh2_sftp_rename_ex.3:37-43 给出了重要区分：

- LIBSSH2_SFTP_RENAME_OVERWRITE 未设置时，目标已存在则操作失败；
- LIBSSH2_SFTP_RENAME_ATOMIC 与 LIBSSH2_SFTP_RENAME_NATIVE 表示 preference，而不是 requirement。

因此结论不是“flags=0 没有 no-clobber”，而是：

- libssh2 generic rename 的 no-overwrite 条件有本地 API 文档支持；
- 当前 wrapper 确实传 flags=0，没有请求 overwrite；
- 但当前 wrapper 没有请求或验证 atomic publication；
- server 是否把 rename 实现成原子可见操作，不能仅凭 flags=0 推出；
- stat 预检仍然不是 authority。

现有测试源码表达了当前产品意图：

- Tests/SSH/SFTPFileOpsTests.swift:100-130：重命名到已存在名称应失败且两个文件不变；
- Tests/SSH/SFTPTransferTests.swift:226-263：同名再次上传应失败、原文件字节不变、无临时文件残留；
- :345-385：取消上传十次后不应有临时文件残留；
- :447-497：连接丢失时上传失败且不续传，远端临时文件可能真实残留；
- :680-725：强制 partial write 后内容逐字节完整、写调用次数超过分块数、句柄配对。

这些测试需要本地 SSH key 与 fixture；D1 没有把源码断言升级成 live acceptance。

## libssh2 Capability Matrix

| 能力 | 精确证据 | D1 结论 |
|---|---|---|
| SFTP protocol | libssh2_sftp.h:45-51 | 当前 vendored header 是 SFTP v3。 |
| Final EXCL open | libssh2_sftp.h:187-192；libssh2_sftp_open_ex.3:24-42 | WRITE|CREAT|EXCL 可拒绝已存在 final；CREAT 是 EXCL 的前提。 |
| Generic rename | libssh2_sftp.h:291-303；libssh2_sftp_rename_ex.3:34-43 | flags=0 不带 OVERWRITE，目标存在时失败；ATOMIC/NATIVE 只是 preference。 |
| Overwrite-capable convenience macro | libssh2_sftp.h:297-303 | libssh2_sftp_rename convenience macro 明确带 OVERWRITE，未来不得误用。 |
| POSIX rename extension | libssh2_sftp.h:305-312；libssh2_sftp_posix_rename_ex.3:29-43 | 客户端符号存在，但它是 posix-rename@openssh.com extension，没有 no-clobber 参数；不作为 create-only authority。 |
| Hardlink | 精确 header 没有 hardlink/link API；静态库符号也没有对应 libssh2_sftp_link | 当前栈没有 Strategy B 所需 primitive。 |
| Remote fsync | libssh2_sftp.h:262-266；libssh2_sftp_fsync.3:13-32 | 客户端可调用，但要求 fsync@openssh.com；当前生产 wrapper 未调用；不等于目录 fsync 或 rename durability。 |
| stat/lstat/setstat | libssh2_sftp.h:338-350；libssh2_sftp_stat_ex.3:22-37 | 具备 follow symlink 的 STAT 与不跟随 symlink 的 LSTAT；当前生产 stat wrapper 只用 STAT。 |
| readlink/realpath | libssh2_sftp.h:352-367；SFTPSession.swift:155-199 | 具备服务端 readlink/realpath；当前生产只读层使用 REALPATH，不使用 READLINK。 |
| mkdir/rmdir/unlink | libssh2_sftp.h:314-336 | 有路径级 mutation API；当前 wrapper 有 unlink/mkdir，没有 Agent Remote dispatch。 |
| Remote attributes | libssh2_sftp.h:75-105 | 只有 flags、filesize、uid、gid、permissions、atime、mtime；没有标准 inode、device 或 server object ID。字段还受 flags 控制，不能缺失时猜默认。 |
| Directory handle | libssh2_sftp_open_ex 可 OPENDIR；SFTPSession 当前用于 opendir/readdir/closedir | 能保护列举生命周期，但当前 mutation API 全部接受 path，没有 openat-relative mutation，因此不能等价为 parent FD capability。 |
| Extension advertisement | 当前精确 header 与 wrapper 没有通用 server extension advertisement/query façade | 不可在 D1 假定 posix-rename 或 fsync 被服务器支持。 |
| Nonblocking behavior | libssh2_sftp_rename_ex.3:45-47；当前 SSH/SFTP readiness wrapper | EAGAIN 是可恢复等待，不是发布成功或失败的结果；发布状态必须单独建模。 |
| Actual static symbols | nm 对 libssh2.a 确认包含 sftp_fsync、sftp_posix_rename_ex、sftp_rename_ex、sftp_open_ex、sftp_stat_ex、sftp_unlink_ex、sftp_mkdir_ex 等 | 客户端实现存在不等于每个远端服务器支持对应 extension 或 atomic behavior。 |

### 对“能否等价 Local C2”的回答

当前栈能提供：

- final EXCL 的 create-only admission；
- generic rename flags=0 的 no-overwrite API contract；
- 流式写、partial write、EAGAIN 等待；
- 同一 SSHConnection/SFTP actor 内的生命周期与串行保护。

当前栈不能从已核实证据中提供：

- 跨服务器保证的 Local-equivalent atomic visibility；
- 可用于 mutation 的远端 parent directory FD/openat authority；
- inode/dev/server object ID；
- 通用 hardlink publication；
- 不依赖服务器扩展的 durability；
- reconnect 后仍可复用的旧审批。

因此 A 的 no-clobber 条件可用，但 A 的 Local-equivalent atomic no-clobber publication 不能被当前证据证明。R2 不成立。

## Remote Identity

### 当前可用身份与 authority 分类

| 身份组件 | 当前状态 | authority 结论 |
|---|---|---|
| logical sessionID | ManagedTerminalSession.id；resolver 按它查找 | 仅是逻辑路由身份，不是 connection incarnation。 |
| SSHConnection actor instance | 当前 session.connection 被 reconnect 替换 | 可作为运行时对象身份，但当前没有显式、可冻结的 token。 |
| LIBSSH2_SESSION 指针 | SSHConnection actor 内受保护，validate 会比较当前指针 | 是 actor 内生命周期 authority，不能带出 actor，也不能序列化进 approval。 |
| SFTP 子系统指针 | 与 session 一起受保护；teardown 后置 nil | 是当前 SFTP incarnation 的内部 authority，不是用户可见身份。 |
| SFTP file handle | 当前登记表认领关闭 ownership | 只能证明同一 actor/incarnation 内的句柄生命周期，不能证明路径对象未被替换。 |
| hostID | SSHConnection.Configuration 与 ManagedTerminalSession 保存 | Host Profile identity；不能单独证明当前网络连接仍是该 incarnation。 |
| hostname/port/username | SSHConnectionInfo 与 session 保存 | 连接展示/匹配 metadata，不是 mutation capability。 |
| verified host key blob | SSHConnection.swift:450-471、815-847 从真实 handshake 得到并与 KnownHost 比较 | 服务器密码学身份；应绑定摘要或等价不可伪造快照。fingerprint 可展示，匹配实际使用 hostKeyBlob。 |
| canonical path | Remote realpath 返回 | 路径快照，不是对象 identity；realpath 后仍可被同用户或服务器改变。 |
| SFTP attributes | 当前只有 size/uid/gid/mode/time | 无 inode/dev/server object ID，不能仿造 Local FD+dev+ino。 |

### 未来 Remote capability 的最强可行形态

D1 不实现，但未来若重新开启 Remote mutation admission，immutable capability 至少应冻结：

- logicalSessionID；
- exact SSHConnection incarnation token；
- exact SFTP subsystem incarnation token；
- hostID、hostname、port、username；
- verified host key blob 的内部摘要；
- canonical absolute parent path 与 final basename；
- admission 时的 path policy、payload byte count 和一次性 approval token；
- capability 创建时的 allowed operation，仅限 create-only write；
- provider/UI 显示所需的非敏感摘要，不携带 content、凭据、原始 pointer 或 secret path。

其中真正的运行时 authority 是 exact connection/SFTP incarnation 和 actor 内部 token；host key 是远端服务器 identity；canonical parent、basename、size、uid、mode 只属于快照或约束，不是不可替换的远端对象证明。

未来执行器必须由 actor 提供“当前 token 仍是同一 connection/SFTP incarnation”的校验。resolver 不能在 execution time 仅按 sessionID 重新取当前 connection。

## Remote Path Semantics

### 当前 Agent 路径来源

AgentRemotePathResolver.swift:3-20、:22-81 的规则是：

- 空路径拒绝；
- 以 ~ 开头的路径拒绝；
- 绝对路径直接作为候选；
- 相对路径只有在 AgentWorkingDirectory confidence 为 authoritative 时才拼接；
- 先做 .、..、重复斜杠的词法预处理；
- 再调用服务端 realpath；
- containment 只对 canonical result 判定。

AgentWorkingDirectory.swift:3-21、:30-85 区分 OSC7 authoritative、sessionDefault approximate 和 unavailable。AgentReadScope.makeRemote 在 AgentRemotePathResolver.swift:107-143 中只把 authoritative OSC7 cwd canonicalize 后作为 allowed root；SFTP 的 session default 即使 realpath(".") 看起来相同，也不能被当作 interactive shell cwd。

SFTP browser 的 currentPath 是 SFTPService 的浏览状态，不等于交互 Shell 当前目录。未来 Remote write 不能执行时再用 SFTP home、SFTP browser currentPath 或 sessionDefault 猜相对路径。

### D1 冻结的路径政策

如果未来重新实现 Remote write_file，D1 推荐只接受绝对 Remote path。除非未来能在 approval admission 时冻结 authoritative OSC7 cwd，并把该 cwd 与同一个 terminal/connection incarnation 绑定，否则不允许相对路径。

当前 SFTP wrapper 用 String.withCString 加显式 UTF-8 byte count 传路径；Agent write_file parser 已拒绝 U+0000，payload 也以 exact UTF-8 byte count 为上限。RemotePath.swift:3-47 的 normalized/join 只做文本路径辅助，不能替代服务端 canonicalization 或 mutation authority。

### Symlink 与 parent replacement

当前 stat 是 follow-symlink 的 STAT；目录列举通过 permissions mode bits 识别 symlink 条目。精确 header 具备 LSTAT、READLINK、REALPATH，但当前 Agent read façade 和生产 mutation wrapper 没有完整的 LSTAT/READLINK mutation preflight。

未来可以用 LSTAT 判定 final entry 本身是 regular file、directory、symlink 或其它，用 READLINK 诊断链接，用 REALPATH 做服务端 canonicalization。但 SFTP mutation API 仍按 path 发送，没有相对于已打开 parent directory handle 的 openat/renameat/unlinkat。因而无法保证在 proposal 到 execution 之间 parent path 没有被替换成 symlink 或其它目录。

这是一个不可消除的 path-level same-user/server race。canonical path 只能减少误判，不能升级成 Local FD authority。

### Remote staging directory

当前 mkdir_ex 支持 mode 参数，当前业务 mkdir 使用 0755；现有上传 temp file 使用 0600。attributes 可以在 flags 声明时提供 uid/gid/permissions，但服务器可以不提供这些字段，当前模型也没有 inode/dev。

未来创建 staging directory 可以做：

- canonical parent 解析；
- mkdir mode 请求；
- LSTAT/STAT 与 permissions/uid/gid 的 best-effort 校验；
- 只在同一 connection/SFTP incarnation 内继续；
- 将 staging name 作为应用生成的 token。

但它仍不能证明目录不会在随后被 rename、替换或通过 symlink 重新寻址。它是降低暴露面的 staging 设计，不是 Local parent capability 的等价物。

## Strategy A — Temp + Rename

### 可获得的安全属性

- 临时对象可以在目标同目录创建，避免跨文件系统 rename 的额外不确定性。
- 临时文件可用 WRITE|CREAT|EXCL，避免临时名称冲突。
- generic rename_ex(flags=0) 不设置 OVERWRITE；本地 man page 明确目标已存在时失败。
- 因此 “不覆盖已存在目标” 不是由 stat 预检提供，而是由发布操作的 no-overwrite contract 提供。
- 如果具体服务器把 rename 执行为 atomic，完整 temp 可以在 final name 一次显现；但这必须是服务器实测或服务器 profile 证明，不能由 flags=0 推出。

### 不能获得的保证

- 当前代码传 flags=0，没有设置 ATOMIC；即使设置 ATOMIC，libssh2 man page 也将其定义为 preference，不是 requirement。
- generic SFTP 服务器可能使用不同的 rename implementation；D1 没有本地 fixture 证明所有目标服务器都提供 atomic visibility。
- posix_rename@openssh.com extension 没有 no-clobber 参数，不能用它替代 create-only publish；并且当前代码根本没有调用它。
- 传输/进程在 rename request 已发送但 response 丢失时，客户端不能知道目标是否已经发布；再次尝试可能发生重复风险，所以不能自动 retry。
- 当前 temp 文件虽然 mode=0600，但同一目录中的名称可能对能列目录的用户可见；这不等于 private directory isolation。

### 判定

A 提供“可证明的 API-level no-overwrite 条件”，但不提供已证明的跨服务器 Local-equivalent atomic visibility。因此 A 不能进入 R2；未来若选择 A，也只能在独立 D2 证明具体服务器 profile 后重新授权。

## Strategy B — Temp + Hardlink + Unlink

理想流程是：

temp inode → 在 final name 做 no-clobber hardlink → unlink temp。

当前精确 header 没有 hardlink/link API，nm 也没有相应 libssh2_sftp_link 符号。posix-rename man page 提到某些服务器可能在内部尝试 hard link，这不是客户端可控的 hardlink primitive，也不能作为 no-clobber contract。

即使未来通过服务器私有 extension 暴露 hardlink，还必须处理：

- 同一 filesystem 限制；
- server extension 支持差异；
- link 的 no-clobber 结果；
- temp unlink 失败；
- source/destination path race；
- connection loss 后 source 与 final 的不确定组合。

D1 判定 B 在当前 primitives 下 unsupported。

## Strategy C — Direct EXCL Final Open

精确 open API 与 man page 支持：

- final path 直接使用 WRITE|CREAT|EXCL；
- CREAT|EXCL 要求目标已存在时失败；
- 这个检查发生在 server open，而不是 stat-then-open；
- 因此可提供 create-only admission。

但它从第一次成功 open 起就使 final name 存在。上传期间：

- 其它用户可能看到零字节或前缀；
- list/stat 可以看到不完整文件；
- short write、EAGAIN、网络丢失、进程 crash、Task cancellation、SSH disconnect 或 server disconnect 都可能留下 partial final；
- close 不等于 fsync；
- 客户端不能仅凭 path 删除一个可能已经被其它参与者替换的对象；
- EXCL 成功后失败，Agent 绝不能自动 retry 同一路径，因为原路径可能已经含有有效前缀。

C 不具备 Local C2 的 atomic visibility。它只能是 R3 的弱语义，并且必须在 UI/provider 中直白披露“目标不会覆盖，但上传中断可能留下部分文件”。

D1 不选择 R3，因此不实现 C，也不允许现有 write_file Remote 化。

### A/B/C 的取消、断连与收尾语义

| 时点 | Strategy A：temp + rename | Strategy B：hardlink | Strategy C：final EXCL open |
|---|---|---|---|
| 远端对象创建前取消 | noSideEffect | 不可用 | noSideEffect |
| temp/final 创建后、开始写入前 | privateTempOnly，旧 incarnation 上尽力 unlink | 不可用 | partialFinal，final 已经可见 |
| 写入中取消或 short write 后断连 | temp 可能部分写入；cleanup 成功才可报告无残留，否则保留 residue | 不可用 | partialFinal 可能保留，禁止按路径自动删除 |
| 完整写入、close 前取消 | temp 已完整但未 publish；不把完整 temp 当成功 | 不可用 | final 已存在且可能完整；仍不能假设 durability |
| publish/rename 请求期间断连 | unknown；请求可能已成功，绝不自动 retry | 不可用 | open 已成功时是 partialFinal；open response unknown 时是 unknown |
| close/fsync response 丢失 | 不把 close 或 fsync 解释为成功 publish；转 unknown | 不可用 | final 是否已写入不能猜测，禁止补偿性重试 |

所有策略都必须把旧 SSHConnection/SFTP incarnation 作废；任何清理动作不得跨 reconnect 进入新 connection。B 在当前栈没有可执行路径，表中的“不适用”不是安全成功结果。

### Strategy D — Protocol/server extension 与 Strategy E — Unsupported

客户端确实包含 posix-rename@openssh.com 与 fsync@openssh.com 的函数入口，但：

- posix rename 没有 no-clobber 参数，不能独立满足 create-only；
- fsync 只在服务器支持对应 extension 时有效，且不提供目录 fsync 或 rename durability；
- 当前 header/wrapper 没有通用 extension advertisement/query façade；
- 没有 live fixture 证明目标服务器行为；
- 服务器私有 extension 也不能自动成为跨服务器产品 contract。

因此 D 不能在 D1 直接升级为 R2。E 是当前 primitives 下对“Local-equivalent atomic no-clobber publication”的准确结论，也是本报告选择 R1 的落点。

### Remote durability

当前可证事实只有：libssh2_sftp_fsync 在 header、静态库和 man page 中存在；man page 要求服务器支持 fsync@openssh.com，并在不支持时返回 OP_UNSUPPORTED。SFTPFileOperations 当前没有调用它。close_handle 只完成协议句柄关闭，不是远端磁盘同步；generic rename 的成功也不是目录项已持久化的证明。精确 header 没有通用 directory fsync primitive。

所以 D1 不承诺 crash consistency、power-loss durability、rename durability 或 staging-directory durability。未来若采用 R2/R3，fsync 的成功也必须作为单独状态记录，不能将不支持或 response unknown 映射成“已持久化”。

## Live Probe

状态：SKIPPED，理由是没有可复用的既有 fixture；没有创建新 fixture，也没有改变 sshd 或 authorized_keys。

只读环境检查结果：

- /tmp/macssh_phase6_ed25519 不存在；
- /tmp/macssh_phase10_fixture_path 不存在；
- /tmp/macssh_phase9_fixture_path 不存在；
- 没有发现可安全复用的 D1 Remote mutation fixture/key；
- launchctl 的 ssh 相关查询没有给出可复用服务证据；
- 受沙箱限制的 localhost:22 socket/process 探针不能作为 live server 结论。

因此本报告不声称 OpenSSH extension、rename atomicity、fsync、parent symlink race 或 real server publication 已在设备上通过。现有 AgentRemoteRealSFTPTests.swift 仍是 read-only fixture 测试，且在缺少 key/fixture 时跳过；D1 没有运行会写入远端的 SFTP transfer tests。

## Race Matrix

| 竞态 | 当前可消除程度 | D1 结论与未来规则 |
|---|---|---|
| proposal-time stat → execution | 不可消除 | stat 只能 UX preflight；不能当 no-clobber authority。真正 admission 必须由 EXCL open 或 rename no-overwrite result 决定。 |
| temp creation → validation | 部分可界定 | EXCL 可保护应用生成的 temp basename；attributes 没有 inode/dev，不能证明 path 与 object identity 长期一致。 |
| final precheck → publication | 不可消除 | final precheck 只改善错误前置；发布阶段仍必须使用 no-overwrite primitive。 |
| cleanup identity check → unlink | 不可消除 | Remote 没有 Local 的 parent FD/inode authority；cleanup 只能在同一旧 incarnation 中 best-effort，并在 ownership 不确定时停止。 |
| reconnect | 可检测、必须拒绝 | old connection/SFTP token 失效；旧 approval 返回 staleConnection，不得 resolver 到新 connection，不得自动 retry。 |
| same-user concurrent process | 只可部分保护 | final EXCL 或 rename flags=0 可拒绝目标存在；不能阻止 parent replacement、server-side path race 或非原子可见性。 |
| rename request 后连接丢失 | 不可确定 | publication result = unknown；不能以失败或成功猜测，不能自动重试。 |
| fsync extension unsupported | 可检测 | 返回 unsupported 时不能声称 durable；R1 不调用 Remote mutation，因此不对用户宣称 durability。 |
| parent symlink replacement | 不可消除 | canonicalization 是快照；没有 remote openat/dir-FD authority，需在未来 contract 中明确限制。 |
| cancellation during EAGAIN | 可界定流程、不能回滚未知发布 | 取消需停止后续 mutation；已发送请求的结果仍可能 unknown；不自动补偿或 retry。 |

## Future Result States

未来若独立授权 Remote mutation，结果必须是状态而不是简单 Bool。建议冻结以下语义：

| 状态 | 事实 | 允许的后续动作 |
|---|---|---|
| noSideEffect | final 未创建；例如 EXCL/open 被目标存在拒绝，或 mutation 在创建前被取消 | 可安全报告未写入；不 retry 未经用户再次批准的旧 request。 |
| privateTempOnly | temp 已创建但只写入部分或尚未完成 | 同一旧 incarnation 尝试 best-effort cleanup；cleanup 失败时报告 residue；不跨 reconnect 清理。 |
| fullTempUnpublished | temp 完整、校验结束但未成功 publish | 可以在同一受控执行中继续；publish response unknown 时转 unknown。 |
| partialFinal | Direct EXCL final 已创建但 payload 未完成 | 只适用于 R3；必须明确显示 partial final，禁止自动 retry 或自动删除。 |
| published | final publish 返回成功且完成语义满足 | 才能报告写入完成；仍不能把此状态扩大为 crash/power-loss durability。 |
| publishedCleanupResidue | final 已发布，但 temp 清理或扩展 fsync 状态有残留/未确认 | 不能把 final 说成未写入；显示已发布并披露 residue，禁止重复 publish。 |
| unknown | 连接在 close/fsync/rename 或响应返回前丢失 | 停止；旧 capability 作废；禁止自动 retry、删除或换新连接继续。 |

状态转换必须保存：

- exact connection/SFTP incarnation；
- create/publish 请求是否已经送出；
- server status code（内部，不送 Provider）；
- final/temporary path 的非敏感摘要；
- cleanup 是否确认成功；
- 是否存在 partial final 风险。

## Recommended Architecture: R1

### 决定

推荐且只推荐 R1：

Remote write unsupported because strong Local-equivalent no-clobber publication cannot be guaranteed under the current cross-server SFTP primitives.

这里的“cannot be guaranteed”指完整的 Local-equivalent publication property：目标不被覆盖、完整内容先在私有对象中写好、final 可见性原子、连接/取消/重连状态可准确收敛。当前 generic rename flags=0 可以支持 no-overwrite 条件，但无法单凭客户端证据保证 atomic visibility；C 的 EXCL final open 又会暴露 partial final；B 没有 primitive。

### Exact contract

D1 冻结以下 contract：

- write_file 仍然是七工具集合中的单一 Local-only file mutation。
- Remote session 调用 write_file 仍返回 unsupportedForSession / 既有 Remote unsupported 语义。
- 不新增 Remote approval、Remote executor、Remote SFTP staging、Remote provider dispatch。
- overwrite 仍未实现；任何设计不得调用 libssh2_sftp_rename convenience macro，因为该 macro 带 OVERWRITE。
- 不把 stat-then-rename 当 no-clobber authority。
- 不把 close、rename 返回或 fsync extension 当成跨服务器 durability。
- 不把 SFTP browser currentPath、remote HOME、sessionDefault 或新的 connection 作为旧 approval 的隐式 target。
- 若未来重新开启 Remote write，必须由新阶段重新完成 capability、server matrix、UI/provider disclosure 和 independent acceptance。

### Security rationale

R1 让当前安全边界保持封闭：

- Provider 没有 Remote write dispatch；
- 没有把 Remote path string 伪装成 Local parent FD authority；
- 没有把 path metadata、size、uid、mode 或 realpath 伪装成 inode identity；
- 没有在 reconnect 后把旧审批重定向到新服务器连接；
- 不会产生 partial final 或不可确认的 Remote residue；
- 不需要在没有 fixture 的情况下假设服务器 extension 行为。

### Portability

R1 不依赖 OpenSSH-only posix-rename 或 fsync。未来若针对受控服务器 profile 重新打开能力，必须分别证明：

- server 支持并实际执行 no-overwrite rename；
- server 的 atomic visibility；
- server extension availability；
- server failure/response-lost 的可观测状态；
- parent symlink 与 same-user race 的允许边界。

### User disclosure

当前 Remote write 的用户语义就是“不支持”，不能显示“已写入”“上传完成”或暗示远端操作已排队。

如果未来选择 R3，必须明确披露：

- existing destination will not be overwritten；
- a new destination may become visible before upload completes；
- interruption may leave a partial file；
- a failed request will not be automatically retried on the same path。

R1 当前不需要把 R3 的 partial-file 风险伪装成普通失败。

### Retry policy

R1 没有 Remote mutation request，因此没有 Remote auto retry。

未来任一 Remote executor 的默认规则应先冻结为：

- old capability 失效后不得换 connection retry；
- publish response unknown 不 retry；
- partialFinal 不 retry；
- privateTempOnly 只能在同一旧 incarnation best-effort cleanup，不把 cleanup 当成成功；
- 必须由新的用户 approval 建立新的 capability 才能重试。

### Stale/reconnect rule

未来 approval 必须绑定：

- logicalSessionID；
- exact SSHConnection incarnation token；
- exact SFTP subsystem incarnation token；
- verified host identity snapshot；
- canonical absolute parent + basename；
- immutable payload byte count / approval token。

执行点必须在 actor 内校验所有 token。SessionManager reconnect 产生新 SSHConnection，SFTP reattach 产生新 SFTP incarnation；旧 approval 一律 staleConnection，绝不按 sessionID 重新解析，绝不将既有 TransferManager 的 pending-transfer requeue 语义复制到 Agent approval。

## Future Test Plan

D1 不实现测试代码；以下是后续独立阶段的验收计划。

### Domain and fake backend

建立不接触真实 server 的 mutation backend seam，注入：

- open EXCL success / existing / permission / unsupported；
- partial write、short write、EAGAIN、EINTR 等价事件；
- cancellation at create、mid-write、after full write、before close、during publish；
- disconnect before request、after request sent、after server success before response；
- rename no-overwrite、rename atomic preference ignored、publish status unknown；
- fsync supported / unsupported / response lost；
- cleanup success、missing temp、permission denied、connection lost；
- reconnect token mismatch；
- parent replacement and symlink result models。

断言每一种输入都落入 Future Result States，且 unknown 不会触发 retry。

### Server fixture matrix

在明确授权后，使用隔离 fixture 与已知测试 key，分别验证：

- 目标不存在与目标已存在；
- generic rename flags=0；
- generic rename with ATOMIC preference；
- posix-rename extension present/absent；
- fsync extension present/absent；
- same-directory rename 与 cross-filesystem failure；
- server response lost after publication；
- concurrent creator race；
- parent directory rename/replacement；
- final symlink、dangling symlink、directory、FIFO/other；
- owner/mode attributes 缺失；
- disconnect/crash/cancel 后的 temp/final residue。

结果必须区分 fixture evidence、JVM/Robolectric 或 fake tests、真实 device/process evidence；不能把 fake 或本地文件系统结果标成 server acceptance。

### Agent policy tests

- 七工具名称和 Provider tool definitions 仍精确一致；
- Remote write_file 仍 unsupported；
- origin session mismatch 拒绝；
- closed/disconnected session 不 fallback；
- relative path 没有 authoritative OSC7 时拒绝；
- old connection token 在 reconnect 后拒绝；
- no old approval retarget；
- no automatic retry for unknown 或 partialFinal；
- no secret/content/path payload in diagnostics.

## Frozen Boundaries

D1 明确不做：

- 不增加 Remote write_file dispatch；
- 不增加 Remote mutation executor；
- 不增加 Remote approval coordinator；
- 不改 Provider 请求或 tool schema；
- 不改 UI；
- 不改 AgentToolName、七工具集合或 write_file Local-only description；
- 不改 SSHConnection、SFTPSession、SFTPFileOperations、SFTPTransferService 的生产实现；
- 不改 Tests；
- 不改 libssh2、OpenSSL、SwiftTerm、Package.resolved；
- 不新增远端 fixture、key、authorized_keys、sshd 配置；
- 不 commit；
- 不 push。

## Remote Verification

D1 期间已核实：

- 当前分支：feature/macssh-1.1-agent-remote-file-mutation；
- HEAD：958fc1c9d1046a7714d2d2ca39a2f05d99f971aa；
- git diff --check：clean；
- staged file count：0；
- github/main：e958750643aeb9992d4cb357e91dc084130224eb；
- github/feature/macssh-1.1-agent-terminal-mutation：ABSENT；
- github/feature/macssh-1.1-agent-file-mutation：ABSENT；
- github/feature/macssh-1.1-agent-remote-file-mutation：ABSENT；
- 没有 commit；
- 没有 push。

构建验证：

- Debug build：BUILD SUCCEEDED；
- compiler warning：0；
- compiler error：0；
- 构建产物写入 /private/tmp/macssh-d1-derived-data；
- 因无现存 Remote fixture，没有运行会创建/上传/rename/unlink 真实远端文件的测试；
- 没有把 build success 或静态测试源码断言称为 Remote device validation。

## P1/P2/P3

### P1

P1 = 0。

D1 没有写入、删除或重命名任何真实 Remote 文件；没有启用 Provider Remote write；没有启用 overwrite；没有记录凭据或 payload；没有把 approval retarget 到新 connection；没有修改生产代码。

### P2

P2 = 0。

本报告：

- 审计了实际 SFTP implementation；
- 审计了精确 libssh2 header、随依赖保存的 man page 和静态库符号；
- 把 rename flags=0 的 no-overwrite contract 与 atomic preference 分开；
- 没有把 stat-then-rename 当 authority；
- 明确分析了 direct EXCL 的 partial final；
- 定义了 connection/SFTP incarnation 与 reconnect stale rule；
- 明确 disallow future relative path unless cwd authority can be frozen；
- 明确推荐唯一架构选项 R1；
- 没有改生产代码、没有 commit、没有 push。

当前代码注释把 generic rename_ex(flags=0) 称为 posix-rename 是需要未来阶段澄清的 documentation issue；D1 没有把该注释当成 server proof，也没有修改源代码。

### P3

P3 仅保留明确的环境与能力边界：

- 当前没有可复用 Remote fixture/key，live probe skipped；
- server-specific posix-rename 与 fsync availability 未在本机实测；
- atomic rename behavior 不能从客户端 flags alone 推断；
- 当前 exact header 没有 hardlink primitive；
- Remote attributes 没有 inode/dev/server object ID；
- parent symlink replacement 与 same-user path races 仍不可消除；
- Remote crash/power-loss durability 不在当前可证明范围。

## Decision

最终推荐：R1。

Remote file-mutation architecture：INVESTIGATED

Publication semantics：FROZEN FOR INDEPENDENT REVIEW

Remote write_file：NOT YET IMPLEMENTED

PHASE 10F-D1 FINAL PASS
