# macOS 原生 Terminal + SSH + SFTP 一体化客户端完整开发计划书

## 1. 项目概述

### 1.1 项目名称

暂定项目代号：

**MacSSH**

后续可以单独确定正式产品名称。

---

## 1.2 产品定位

开发一款专门面向 macOS 的原生终端与服务器管理工具，将以下三类能力整合到一个应用中：

1. 本地 Terminal
2. SSH 主机管理
3. SFTP 文件管理

核心产品定位：

> 一个轻量、快速、原生、安全的 macOS Terminal + SSH + SFTP 工作台。

主要参考产品：

- Termius
- Electerm
- FinalShell
- iTerm2
- FileZilla
- Finder
- VS Code

但不直接复制任何产品的代码或 UI。

---

# 2. 核心开发原则

整个项目必须遵守以下原则。

## 2.1 原生优先

禁止使用：

- Electron
- Chromium
- React
- Vue
- WebView 套壳

核心采用：

- Swift
- SwiftUI
- AppKit

目标是真正的 macOS 原生应用。

---

## 2.2 轻量优先

第一版性能目标：

| 指标 | 目标 |
|---|---:|
| App Release 体积 | 尽量 `< 80 MB` |
| 冷启动 | 尽量 `< 1 秒` |
| 空闲 CPU | 接近 `0%` |
| 空闲内存 | 尽量 `< 100 MB` |
| 单 SSH 会话 | 不应产生明显额外固定开销 |
| SFTP 大文件 | 内存占用不得随文件大小线性增加 |

这些属于性能预算，不应为了达到某个数字牺牲稳定性。

---

## 2.3 安全优先

禁止：

- 明文保存密码
- 明文保存私钥口令
- 自动信任未知 SSH Host Key
- 自动忽略 Host Key 变化
- 在日志打印密码
- 在日志打印私钥
- 在日志打印完整终端内容
- 把整个上传文件加载进内存

密码和其他小型秘密信息使用 macOS Keychain。Apple 将 Keychain 定位为存储密码、密钥等敏感小型数据的系统安全存储。

---

# 3. 第一版支持平台

## 3.1 操作系统

建议：

**macOS 14+**

第一阶段重点适配：

**Apple Silicon**

即：

```text
arm64
```

优先支持：

- M1
- M2
- M3
- M4
- M5
- 后续 Apple Silicon

---

## 3.2 Intel Mac

第一版暂时不作为强制目标。

MVP 稳定以后再决定是否构建：

```text
Universal 2

arm64
+
x86_64
```

这样可以：

- 降低初期构建复杂度
- 降低 OpenSSL/libssh2 多架构处理复杂度
- 减少测试矩阵
- 减少应用体积

---

# 4. 分发策略

## 4.1 第一优先

推荐：

**官网 / GitHub Release + Developer ID + Apple Notarization**

而不是第一版直接上 Mac App Store。

原因是本软件需要：

- 本地 Shell
- PTY
- SSH
- SFTP
- 本地文件
- 用户目录
- SSH Key
- 拖放上传
- 外部进程

这些能力与 App Sandbox 的限制需要额外协调。

Apple 要求 Mac App Store 应用开启 App Sandbox；而站外 Developer ID 分发主要要求正确签名、Hardened Runtime 和公证。

因此第一版：

```text
Developer ID
+
Hardened Runtime
+
Notarization
+
DMG
```

后续再单独研究 Mac App Store 版本。

---

# 5. 总体技术栈

确定使用：

| 功能 | 技术 |
|---|---|
| 编程语言 | Swift |
| UI | SwiftUI |
| 原生高级 UI | AppKit |
| Terminal | SwiftTerm |
| Local Shell | SwiftTerm + PTY |
| SSH | libssh2 |
| SFTP | libssh2 |
| 加密后端 | OpenSSL |
| 数据存储 | SwiftData |
| 密码安全 | macOS Keychain |
| 并发 | Swift Concurrency |
| 日志 | OSLog / Logger |
| 包管理 | Swift Package Manager |
| IDE | Xcode |
| 测试 | XCTest / Swift Testing |

SwiftTerm 本身提供 VT100/Xterm Terminal Engine、macOS AppKit `TerminalView`，并提供能够连接 Unix pseudo-terminal 的本地进程 Terminal 实现，因此不需要自行开发终端模拟器。

libssh2 是客户端 SSH2 C 库，官方支持 password/public-key authentication、shell、exec、PTY、SFTP、direct-tcpip 等能力，并支持 non-blocking 模式。

---

# 6. 总体软件架构

采用：

```text
┌───────────────────────────────────────┐
│             Presentation              │
│                                       │
│ SwiftUI / AppKit                      │
│ Hosts / Terminal / SFTP / Settings    │
└───────────────────┬───────────────────┘
                    │
┌───────────────────▼───────────────────┐
│              Application              │
│                                       │
│ Session Manager                       │
│ Connection Manager                    │
│ Transfer Manager                      │
└───────────────────┬───────────────────┘
                    │
┌───────────────────▼───────────────────┐
│                Core                   │
│                                       │
│ SSH / SFTP / Terminal                 │
└──────────────┬─────────────┬──────────┘
               │             │
        ┌──────▼─────┐ ┌────▼───────┐
        │ libssh2    │ │ SwiftTerm  │
        │ OpenSSL    │ │ PTY        │
        └────────────┘ └────────────┘

┌───────────────────────────────────────┐
│             Persistence               │
│                                       │
│ SwiftData               Keychain      │
└───────────────────────────────────────┘
```

---

# 7. 强制架构规则

## 7.1 View 不允许直接操作 libssh2

禁止：

```text
HostDetailView
    ↓
libssh2_session_handshake()
```

必须：

```text
HostDetailView
    ↓
SSHService
    ↓
SSHConnection
    ↓
libssh2
```

---

## 7.2 UI 与连接生命周期分离

SSH 连接不能绑定某一个 SwiftUI View 生命周期。

否则：

```text
切换页面
↓
View 被销毁
↓
SSH 意外断开
```

应该：

```text
AppState
   ↓
SessionManager
   ↓
SSHConnection
```

View 只是观察 Session 状态。

---

# 8. 项目目录结构

建议建立：

```text
MacSSH/
│
├── App/
│   ├── MacSSHApp.swift
│   ├── AppState.swift
│   └── AppCommands.swift
│
├── Models/
│   ├── Host.swift
│   ├── HostGroup.swift
│   ├── AuthenticationType.swift
│   ├── TerminalSession.swift
│   ├── KnownHost.swift
│   ├── SFTPFile.swift
│   ├── TransferTask.swift
│   └── AppSettings.swift
│
├── Features/
│   │
│   ├── Hosts/
│   │   ├── HostListView.swift
│   │   ├── HostRowView.swift
│   │   ├── HostEditorView.swift
│   │   ├── HostDetailView.swift
│   │   └── HostSearchView.swift
│   │
│   ├── Terminal/
│   │   ├── TerminalContainerView.swift
│   │   ├── TerminalRepresentable.swift
│   │   ├── TerminalTabBar.swift
│   │   └── TerminalToolbar.swift
│   │
│   ├── SFTP/
│   │   ├── SFTPBrowserView.swift
│   │   ├── SFTPFileRow.swift
│   │   ├── SFTPToolbar.swift
│   │   └── SFTPPathBar.swift
│   │
│   ├── Transfers/
│   │   ├── TransferListView.swift
│   │   ├── TransferRowView.swift
│   │   └── TransferProgressView.swift
│   │
│   └── Settings/
│       ├── SettingsView.swift
│       ├── TerminalSettingsView.swift
│       ├── SSHSettingsView.swift
│       └── AppearanceSettingsView.swift
│
├── Services/
│   │
│   ├── SSH/
│   │   ├── SSHService.swift
│   │   ├── SSHConnection.swift
│   │   ├── SSHChannel.swift
│   │   ├── SSHAuthentication.swift
│   │   ├── SSHHostKeyVerifier.swift
│   │   └── SSHError.swift
│   │
│   ├── SFTP/
│   │   ├── SFTPService.swift
│   │   ├── SFTPSession.swift
│   │   ├── SFTPDirectoryService.swift
│   │   └── SFTPError.swift
│   │
│   ├── Terminal/
│   │   ├── LocalTerminalService.swift
│   │   └── RemoteTerminalService.swift
│   │
│   ├── Transfer/
│   │   ├── TransferManager.swift
│   │   ├── UploadTask.swift
│   │   └── DownloadTask.swift
│   │
│   └── Security/
│       ├── KeychainService.swift
│       └── CredentialService.swift
│
├── Infrastructure/
│   ├── LibSSH2/
│   ├── OpenSSL/
│   ├── Persistence/
│   └── Logging/
│
├── Components/
│   ├── Sidebar/
│   ├── Toolbar/
│   ├── Dialogs/
│   └── Common/
│
├── Utilities/
│   ├── Extensions/
│   ├── Constants.swift
│   └── Logger.swift
│
├── Tests/
│
└── Resources/
```

---

# 9. 数据模型

## 9.1 Host

Host 保存：

```text
id
name
hostname
port
username

group
favorite

authenticationType

credentialID
privateKeyID

createdAt
updatedAt
lastConnectedAt

notes
```

其中：

```text
port = 22
```

作为默认值。

---

# 10. 认证类型

定义：

```text
AuthenticationType

password
privateKey
```

第一版只支持这两种。

后续：

```text
keyboardInteractive
sshAgent
certificate
```

---

# 11. 密码存储设计

SwiftData：

```text
Host
├── hostname
├── port
├── username
└── credentialID
```

Keychain：

```text
credentialID
↓
Password
```

禁止：

```text
Host.password
```

---

# 12. 私钥设计

支持：

```text
RSA
ED25519
ECDSA
```

主要兼容 OpenSSH 私钥。

支持：

```text
无密码私钥
有 Passphrase 私钥
```

Passphrase：

```text
Keychain
```

私钥本身禁止写入普通 SwiftData 数据库。

后续可以支持：

```text
~/.ssh/id_ed25519

~/.ssh/id_rsa
```

以及：

```text
SSH Agent
```

---

# 13. SSH Host Key 安全机制

第一次连接服务器：

```text
第一次连接到：

192.168.1.100

ED25519

SHA256:
xxxxxxxxxxxxxxxxxxxxxxxxxxxx

[取消]
[仅本次信任]
[始终信任]
```

如果选择始终信任：

保存：

```text
hostname
port
algorithm
fingerprint
```

第二次连接：

```text
当前 fingerprint
        ↓
KnownHost
        ↓
比较
```

一致：

```text
允许连接
```

不一致：

```text
阻止连接
```

显示：

```text
警告：服务器身份信息已发生变化

这可能是服务器重新安装，
也可能存在中间人攻击。

旧 Fingerprint：
xxx

新 Fingerprint：
yyy
```

禁止提供：

```text
永远忽略 Host Key
```

作为默认行为。

---

# 14. SSH Core 设计

核心对象：

```text
SSHService

SSHConnection

SSHChannel

SSHAuthentication

SSHHostKeyVerifier
```

其中一个：

```text
SSHConnection
```

代表：

```text
Host
↓
TCP Socket
↓
SSH Session
```

---

# 15. Swift Concurrency

SSHConnection 建议设计成：

```text
Actor
```

避免多个线程同时操作同一个 libssh2 handle。

libssh2 官方说明线程安全的关键限制是不要同时共享操作同一个 handle，因此 SSH Session 的调用应由统一的 Actor 或串行执行上下文管理。

例如逻辑：

```text
SSHConnectionActor

connect()
authenticate()
openShell()
openSFTP()
disconnect()
```

---

# 16. SSH 状态机

定义明确状态：

```text
idle

connecting

handshaking

verifyingHost

authenticating

connected

disconnecting

disconnected

failed
```

禁止只用：

```text
isConnected: Bool
```

因为无法表达真实 SSH 生命周期。

---

# 17. SSH Terminal

流程：

```text
Host
 ↓
SSH Connection
 ↓
SSH Authentication
 ↓
SSH Channel
 ↓
PTY
 ↓
Remote Shell
 ↓
SwiftTerm
```

数据流：

```text
Keyboard
   ↓
SwiftTerm
   ↓
RemoteTerminalService
   ↓
SSH Channel
   ↓
Server
```

返回：

```text
Server
   ↓
SSH Channel
   ↓
RemoteTerminalService
   ↓
SwiftTerm.feed()
   ↓
Screen
```

---

# 18. PTY

SSH Terminal 创建：

```text
xterm-256color
```

后续可考虑：

```text
xterm
xterm-256color
```

Terminal resize：

```text
window changed
↓
Terminal cols / rows
↓
SSH PTY resize
↓
Server
```

必须正确处理：

```text
vim
nano
top
htop
less
tmux
```

---

# 19. 本地 Terminal

本地终端使用：

```text
SwiftTerm
+
PTY
```

默认 Shell：

```text
用户当前 login shell
```

优先读取系统配置，而不是强制写死 `/bin/zsh`。

支持：

```text
zsh
bash
fish
```

只要用户系统存在。

---

# 20. Terminal 第一版功能

必须支持：

- ANSI Color
- 256 Color
- TrueColor
- Unicode
- 中文
- Emoji
- Copy
- Paste
- Select
- Scroll
- Resize
- Terminal Search
- Command Line App
- vim
- nano
- top
- htop
- tmux 基础兼容

SwiftTerm 当前就是针对 VT100/Xterm 的 Swift Terminal Engine，并提供 AppKit 前端。

---

# 21. Scrollback

Terminal 禁止无限缓存作为默认值。

默认：

```text
10,000 lines
```

设置：

```text
5,000
10,000
50,000
100,000
Unlimited
```

显示：

```text
Unlimited 可能明显增加内存占用
```

---

# 22. Terminal Tab

主界面允许：

```text
[Local] [Aliyun] [NAS] [Test Server] [+]
```

每个 Tab 对应：

```text
TerminalSession
```

Session 类型：

```text
local
ssh
```

支持快捷键：

```text
⌘T
新建 Terminal

⌘W
关闭当前 Tab

⌘1
第一个 Tab

⌘2
第二个 Tab

...

⌘F
搜索

⌘K
清屏
```

具体快捷键后续允许配置。

---

# 23. SSH 主机管理

左侧 Sidebar：

```text
HOSTS

⭐ Favorites

▼ 公司

   Web Server
   DB Server
   Test Server

▼ 个人

   NAS
   Aliyun

+ 添加主机
```

支持：

- 创建
- 修改
- 删除
- 分组
- 收藏
- 搜索
- 最近连接
- 双击连接
- 右键菜单

---

# 24. 新建主机页面

字段：

```text
Name

Host

Port

Username

Authentication

Password / Private Key

Group

Notes
```

按钮：

```text
取消

测试连接

保存并连接

保存
```

---

# 25. 主界面布局

推荐：

```text
┌─────────────────────────────────────────────────────────┐
│ Toolbar                                                 │
├───────────┬─────────────────────────────────────────────┤
│           │ Tab Bar                                     │
│ Sidebar   ├─────────────────────────────────────────────┤
│           │                                             │
│ Local     │                                             │
│ Hosts     │             Workspace                       │
│ Transfers │                                             │
│           │                                             │
│ Settings  │                                             │
│           │                                             │
├───────────┴─────────────────────────────────────────────┤
│ Status                                                  │
└─────────────────────────────────────────────────────────┘
```

使用：

```text
SwiftUI
NavigationSplitView
```

Terminal 部分通过：

```text
NSViewRepresentable
```

包装 SwiftTerm AppKit View。

---

# 26. SSH Workspace

连接服务器以后：

```text
Aliyun

[Terminal] [Files] [Info]
```

第一版：

```text
Terminal
Files
```

Info 可稍后完成。

---

# 27. Terminal + SFTP 同屏

这是重要功能。

支持：

```text
┌─────────────────────────┬──────────────────────┐
│                         │                      │
│        Terminal         │        SFTP          │
│                         │                      │
│                         │ /home/ubuntu         │
│                         │                      │
└─────────────────────────┴──────────────────────┘
```

允许：

```text
Terminal Only

SFTP Only

Terminal + SFTP
```

---

# 28. SFTP Core

核心：

```text
SFTPService

SFTPSession

SFTPDirectoryService

TransferManager
```

复用现有：

```text
SSHConnection
```

不要：

```text
每打开一次 Files
重新创建 SSH 登录
```

应该：

```text
SSH Connection
├── Terminal Channel
└── SFTP Subsystem
```

libssh2 官方能力列表包含 SFTP subsystem，因此 SSH 与 SFTP 可以统一在底层 SSH Core 中。

---

# 29. SFTP 文件模型

```text
SFTPFile

name

path

type

size

permissions

owner

group

modifiedAt
```

type：

```text
file
directory
symbolicLink
other
```

---

# 30. SFTP 第一版功能

必须实现：

### 浏览

```text
进入目录

上级目录

刷新

路径输入
```

### 文件操作

```text
上传

下载

删除

重命名

新建文件夹
```

### 信息

```text
名称

大小

修改时间

权限
```

---

# 31. SFTP 第二阶段功能

MVP 后实现：

```text
拖放上传

拖放下载

多文件选择

多文件上传

多文件下载

覆盖确认

文件夹上传

文件夹下载

chmod
```

---

# 32. 双栏文件管理

后续支持：

```text
LOCAL                  REMOTE

~/Downloads            /home/ubuntu

app.zip                 docker/
config.json             app/
test.sh                 logs/
```

支持：

```text
Local → Remote

Remote → Local
```

拖放操作。

---

# 33. Transfer Manager

统一管理：

```text
Upload

Download
```

模型：

```text
TransferTask

id

direction

localPath

remotePath

totalBytes

transferredBytes

progress

speed

status

createdAt
```

status：

```text
waiting

running

paused

completed

failed

cancelled
```

第一版暂停功能可以暂缓。

---

# 34. 大文件传输

禁止：

```text
Data(contentsOf: 20GBFile)
```

必须：

```text
FileHandle
    ↓
固定大小 Buffer
    ↓
SFTP
```

建议初始 Buffer：

```text
256 KB
```

后续通过 benchmark 调整。

因此：

```text
上传 1 GB
上传 10 GB
上传 100 GB
```

都不应该因为文件本身大小导致内存同比增长。

---

# 35. 传输速度

TransferManager 需要计算：

```text
transferredBytes

elapsedTime

bytesPerSecond
```

界面：

```text
Ubuntu.iso

2.43 GB / 8.12 GB

29.9%

42.8 MB/s

约 2m 15s
```

ETA 可以第二阶段增加。

---

# 36. KeychainService

统一封装：

```text
save()

read()

update()

delete()
```

禁止业务层到处直接调用：

```text
SecItemAdd
SecItemCopyMatching
```

统一：

```text
CredentialService
↓
KeychainService
```

Apple 对现代 macOS Keychain API 的建议是优先使用 `SecItem` API。

---

# 37. SwiftData

用于保存：

```text
Hosts

Groups

KnownHosts

AppSettings

TransferHistory
```

禁止保存：

```text
Password

Private Key Passphrase
```

SwiftData 适合本地应用模型持久化，并可以直接与 SwiftUI Query 等机制配合。

---

# 38. 网络权限

如果未来启用 App Sandbox：

需要：

```text
com.apple.security.network.client
```

以允许 SSH 客户端建立出站 TCP 连接。

Apple 将该 entitlement 定义为允许沙盒 App 打开出站网络连接。

MVP 使用 Developer ID 站外分发时仍需要正确评估各 Capability，但不要为了方便关闭必要安全保护。

---

# 39. Hardened Runtime

Release 必须开启：

```text
Hardened Runtime
```

原则：

> 不添加不必要 Runtime Exception。

尤其不要为了让代码运行方便直接：

```text
Disable Library Validation
Allow Unsigned Executable Memory
```

除非存在经过验证的必要性。

Apple 要求公证软件开启 Hardened Runtime。

---

# 40. 日志设计

使用：

```text
OSLog
Logger
```

分类：

```text
App

SSH

SFTP

Terminal

Transfer

Security

Persistence
```

例如：

```text
[SSH]
connection started

[SSH]
authentication successful

[SFTP]
directory loaded

[Transfer]
upload completed
```

绝对禁止：

```text
password=123456

privateKey=-----

terminalOutput=...

passphrase=...
```

---

# 41. 错误模型

统一定义：

```text
SSHError
SFTPError
TransferError
KeychainError
```

例如 SSH：

```text
connectionTimeout

connectionRefused

handshakeFailed

unknownHostKey

hostKeyChanged

authenticationFailed

privateKeyInvalid

channelOpenFailed

connectionLost
```

UI 必须把技术错误转换成用户可以理解的信息。

例如不要只显示：

```text
LIBSSH2_ERROR_SOCKET_RECV
```

而显示：

```text
SSH 连接已中断。

服务器：
192.168.1.100

请检查服务器状态或网络连接。
```

高级信息可以放：

```text
查看详情
```

---

# 42. Connection Timeout

设置默认值：

```text
Connection Timeout:
10 秒
```

SSH KeepAlive：

```text
默认开启
```

例如：

```text
30 秒
```

具体参数后续根据实际测试确定。

---

# 43. Session Manager

维护：

```text
Local Sessions

SSH Sessions

Active Session
```

例如：

```text
SessionManager

├── Local-001
├── SSH-Aliyun
├── SSH-NAS
└── SSH-Test
```

支持：

```text
open

close

activate

reconnect
```

---

# 44. 断线处理

SSH 断开：

Terminal 不应该直接消失。

显示：

```text
────────────────────────────

Connection lost.

[Reconnect]

────────────────────────────
```

用户仍然可以查看之前的 Terminal 内容。

点击：

```text
Reconnect
```

重新建立 SSH。

---

# 45. 设置页面

第一版：

## General

```text
Launch behavior

Confirm before closing active SSH session
```

## Terminal

```text
Font

Font Size

Line Height

Cursor Style

Scrollback

Bell

Copy on Select
```

## Appearance

```text
System

Light

Dark
```

## SSH

```text
Connection Timeout

KeepAlive
```

---

# 46. Terminal 字体

默认使用 macOS 等宽字体。

例如：

```text
SF Mono
```

如果系统不可用则使用系统等宽 fallback。

禁止：

```text
直接把大型字体文件打包进 App
```

除非后续产品确实需要。

---

# 47. UI 设计原则

整体采用 macOS 原生视觉语言。

参考：

```text
Finder
+
Xcode
+
VS Code
+
Termius
```

要求：

- 简洁
- 信息密度合理
- 原生 Toolbar
- 原生 Sidebar
- 原生 Context Menu
- 原生 Keyboard Shortcut
- 原生 Drag & Drop
- 支持 Dark Mode

不要做成 Web Dashboard 风格。

---

# 48. MVP 范围

## 必须完成

### Terminal

- 本地 Terminal
- 多 Tab
- Copy/Paste
- Search
- Scrollback
- Terminal Resize

### Host

- 创建
- 编辑
- 删除
- 分组
- 收藏
- 搜索

### SSH

- Password
- Private Key
- Host Key Verification
- SSH Terminal
- Reconnect

### Security

- Keychain
- Known Host

### SFTP

- Browse
- Upload
- Download
- Rename
- Delete
- New Folder

### Transfer

- Progress
- Speed
- Cancel
- Error

### App

- Settings
- Dark Mode
- Keyboard Shortcuts

---

# 49. MVP 明确禁止实现的功能

Codex 在第一版不得自行扩展：

```text
RDP

VNC

FTP

WebDAV

Telnet

Serial

Docker Manager

Kubernetes

AI Assistant

Server Monitoring

Cloud Sync

iCloud Sync

SSH Agent

Jump Host

ProxyJump

ProxyCommand

Dynamic Port Forwarding

Remote Port Forwarding

SSH Config Editor

Snippet Cloud

Team Collaboration

Account System

Subscription

Remote Code Editor
```

这些都不属于 MVP。

---

# 50. 开发阶段

整个开发过程分为 12 个阶段。

---

# Phase 0：项目初始化

完成：

```text
Xcode Project

Git Repository

SwiftUI App

目录结构

Logger

基础 Theme

基础 AppState
```

验收：

```text
App 可以启动

主窗口显示正常

Dark/Light Mode 正常

项目无 warning
```

---

# Phase 1：主界面

实现：

```text
Sidebar

Workspace

Toolbar

Tab Bar

Settings
```

暂时使用 Mock Data。

验收：

```text
Hosts 页面

Terminal 页面

Transfers 页面

Settings 页面

可以切换
```

---

# Phase 2：本地 Terminal

引入：

```text
SwiftTerm
```

实现：

```text
LocalProcessTerminal

PTY

Shell

Resize
```

验收命令：

```text
pwd

ls

cd

clear

top

vim

nano

python3

node
```

测试：

```text
中文

Emoji

ANSI Color
```

必须正确显示。

---

# Phase 3：Host Manager

建立：

```text
Host

HostGroup
```

实现：

```text
CRUD

Search

Favorite

Group
```

SwiftData 持久化。

验收：

重启 App 后 Host 数据仍然存在。

---

# Phase 4：Keychain

实现：

```text
KeychainService

CredentialService
```

实现：

```text
save password

read password

update password

delete password
```

验收：

SwiftData 数据库内不存在明文 Password。

---

# Phase 5：SSH 基础连接

集成：

```text
libssh2

OpenSSL
```

建立：

```text
SSHConnection
```

实现：

```text
TCP

Handshake

Password Authentication
```

验收：

可以登录标准 OpenSSH Server。

---

# Phase 6：SSH 安全

实现：

```text
Host Fingerprint

KnownHost

First Connection Dialog

Host Key Changed
```

以及：

```text
Private Key Authentication
```

验收：

正确 Host：

```text
连接成功
```

修改 Host Key：

```text
必须阻止并警告
```

---

# Phase 7：Remote Terminal

实现：

```text
SSH Channel

PTY

Shell

SwiftTerm Bridge
```

验收：

远程服务器执行：

```text
ls

top

vim

nano

htop
```

并验证：

```text
窗口 Resize
```

正常。

---

# Phase 8：Session Tabs

实现：

```text
Local Tab

SSH Tab

Close

Switch

Reconnect
```

验收：

同时打开：

```text
Local

Server A

Server B

Server C
```

互不影响。

---

# Phase 9：SFTP Browser

建立：

```text
SFTPSession
```

实现：

```text
ls

cd

parent

refresh
```

UI：

```text
Name
Size
Modified
Permissions
```

验收：

能够浏览服务器完整目录树。

---

# Phase 10：SFTP 文件操作

实现：

```text
upload

download

rename

delete

mkdir
```

验收：

上传后可通过 SSH：

```text
ls
```

看到文件。

下载后 Finder 可以正常打开。

---

# Phase 11：Transfer Manager

实现：

```text
Transfer Queue

Progress

Speed

Cancel

Failed

Completed
```

必须使用 Streaming。

测试：

```text
1 MB

100 MB

1 GB

10 GB
```

大文件传输时 App 内存不得随文件大小持续上涨。

---

# Phase 12：打磨与 Release

完成：

```text
Error Handling

Crash Fix

Memory Test

CPU Test

UI Polish

Keyboard Shortcuts

Code Signing

Hardened Runtime

Notarization

DMG
```

形成：

```text
MacSSH 1.0
```

---

# 51. 测试环境

建议准备：

```text
Mac
+
Ubuntu Server
```

测试服务器至少支持：

```text
OpenSSH Server

Password Login

Public Key Login

SFTP
```

建议准备三个 Test Host：

```text
Ubuntu

Debian

macOS SSH
```

后续增加：

```text
CentOS / Rocky Linux

Alpine

NAS
```

---

# 52. SSH 测试矩阵

必须测试：

```text
正确 IP

错误 IP

错误端口

服务器关闭

超时

错误 Username

错误 Password

正确 Private Key

错误 Private Key

错误 Passphrase

首次 Host Key

已信任 Host Key

Host Key Changed

服务器主动断开

Wi-Fi 断开
```

---

# 53. Terminal 测试

执行：

```text
ls --color

top

htop

vim

nano

less

cat

tail -f

ping
```

测试：

```text
中文

日文

Emoji

大量日志

快速输出

窗口 resize
```

---

# 54. SFTP 测试

必须测试：

```text
空目录

1000 个文件目录

中文文件名

空格文件名

隐藏文件

大文件

零字节文件

符号链接

只读文件

Permission Denied
```

---

# 55. 性能测试

每个 Release 必须观察：

```text
CPU

Memory

Open File Count

Socket Count

Thread Count
```

测试：

```text
App 空闲

1 SSH

5 SSH

10 SSH

20 SSH
```

以及：

```text
1 个 10 GB SFTP Upload
```

重点观察：

是否发生：

```text
Memory Leak

Thread Leak

Socket Leak
```

---

# 56. 内存优化

必须遵守：

### Terminal

限制 Scrollback。

### SFTP

Streaming。

### Directory

目录使用分页/惰性 UI 渲染。

### Connection

断开的 SSH Connection 必须释放：

```text
Channel

SFTP Session

SSH Session

Socket
```

### Task

取消 Transfer 必须真正停止底层 I/O。

---

# 57. CPU 优化

禁止：

```text
while true {
    checkConnection()
}
```

禁止毫无意义的：

```text
10ms Timer
```

优先：

```text
Socket Event

Async IO

Continuation

Task
```

空闲 App CPU 应接近：

```text
0%
```

---

# 58. 安全测试

检查：

```text
Host.db
```

不能发现：

```text
Password

Passphrase
```

检查日志：

不能发现：

```text
Password

Private Key

Passphrase
```

检查 Crash Log：

不能包含 Secret。

---

# 59. 代码质量要求

所有核心逻辑：

禁止：

```text
巨大 ContentView.swift

巨大 SSHManager.swift
```

单个类型承担单一职责。

必须优先使用：

```text
Protocol

Dependency Injection

Actor

Service Layer
```

但禁止为了“架构漂亮”制造几十层无价值抽象。

原则：

> 简单、明确、可测试。

---

# 60. Git 开发规范

Branch：

```text
main

develop
```

Feature：

```text
feature/local-terminal

feature/host-manager

feature/ssh-core

feature/sftp

feature/transfer-manager
```

Commit：

```text
feat: add local terminal

feat: add password authentication

fix: handle ssh reconnect

refactor: isolate ssh connection actor

test: add sftp transfer tests
```

---

# 61. Codex 开发规则

Codex 必须：

1. 一个 Phase 一个 Phase 开发。
2. 当前 Phase 测试通过后再进入下一 Phase。
3. 不允许跳阶段。
4. 不允许主动增加 MVP 外功能。
5. 不允许为了测试暂时禁用 SSH 安全检查。
6. 不允许明文保存 Password。
7. 不允许整文件载入内存上传。
8. 不允许 View 直接控制 libssh2。
9. 不允许使用 Electron/Web 技术替代。
10. 每完成一个 Phase 更新开发文档。

---

# 62. 每阶段 Codex 输出要求

每次开发结束必须给出：

```text
1. 本阶段完成内容

2. 修改的文件

3. 新增的文件

4. 技术实现说明

5. 测试方法

6. 测试结果

7. 已知问题

8. 下一阶段工作
```

---

# 63. 第一版最终产品形态

最终 1.0：

```text
MacSSH

├── Local Terminal
│
├── SSH Hosts
│   ├── Groups
│   ├── Favorites
│   ├── Password
│   └── Private Key
│
├── SSH Terminal
│
├── SFTP
│   ├── Browse
│   ├── Upload
│   ├── Download
│   ├── Rename
│   ├── Delete
│   └── New Folder
│
├── Transfers
│
├── Keychain
│
├── Host Key Verification
│
├── Tabs
│
└── Settings
```

---

# 64. 2.0 路线

1.0 稳定以后再增加：

### SSH

```text
ProxyJump

Jump Host

SSH Agent

SSH Config Import

Known Hosts Import

Port Forwarding

Local Forward

Remote Forward

Dynamic SOCKS
```

### Terminal

```text
Split Terminal

Profiles

Themes

Background

Custom Shortcut

Session Restore
```

### SFTP

```text
Dual Pane

Drag & Drop

Folder Upload

Folder Download

Pause

Retry

Resume

Concurrent Transfer

chmod

Remote Editor
```

### Productivity

```text
Command Snippets

Quick Connect

Command History

Broadcast Input
```

---

# 65. 3.0 可考虑能力

再进一步才考虑：

```text
Server Monitor

CPU

Memory

Disk

Network

Process
```

以及：

```text
Docker

Kubernetes

Remote Code Editing
```

这些不得污染 1.0 架构。

---

# 66. 核心产品原则

最终软件不是：

> 什么远程管理功能都有的“大而全服务器工具”。

而应该首先成为：

> 一个打开非常快、资源占用低、SSH 稳定、Terminal 好用、SFTP 好用的原生 Mac 工具。

优先级始终是：

```text
稳定
  ↓
安全
  ↓
性能
  ↓
体验
  ↓
功能数量
```

---

# 67. 1.0 成功标准

当下面这些场景全部稳定运行时，才能定义为 1.0：

### 场景一

```text
启动 MacSSH
↓
打开 Local Terminal
↓
正常使用 zsh
```

### 场景二

```text
添加服务器
↓
Password 登录
↓
SSH Terminal
↓
正常运行 vim/top
```

### 场景三

```text
Private Key 登录
↓
Keychain 保存 Passphrase
↓
重新启动软件
↓
再次正常连接
```

### 场景四

```text
第一次连接服务器
↓
验证 Fingerprint
↓
信任
↓
以后自动核验
```

### 场景五

```text
服务器 Host Key 改变
↓
MacSSH 阻止连接
↓
明确警告
```

### 场景六

```text
SSH Terminal
+
SFTP
```

同时工作。

### 场景七

```text
上传 10GB 文件
```

期间：

```text
Terminal 仍然可操作
UI 不冻结
内存不持续暴涨
```

### 场景八

同时打开：

```text
10 个 SSH Terminal
```

能够稳定切换和关闭。

---

# 68. 最终技术方案

第一版正式确定：

```text
Platform
macOS

Language
Swift

Architecture
Native macOS

UI
SwiftUI + AppKit

Terminal
SwiftTerm

Local Shell
PTY

SSH
libssh2

SFTP
libssh2

Crypto
OpenSSL

Persistence
SwiftData

Secrets
macOS Keychain / SecItem

Concurrency
Swift Concurrency + Actor

Logging
OSLog

Distribution
Developer ID + Hardened Runtime + Notarization

Architecture
Feature + Service + Core 分层
```

---

# 69. 最终开发路线

```text
Project Skeleton
       ↓
Main UI
       ↓
Local Terminal
       ↓
Host Manager
       ↓
Keychain
       ↓
SSH Core
       ↓
Host Key Verification
       ↓
Private Key Authentication
       ↓
SSH Terminal
       ↓
Multi Session
       ↓
SFTP Browser
       ↓
Upload / Download
       ↓
Transfer Manager
       ↓
Terminal + SFTP Integration
       ↓
Performance Optimization
       ↓
Security Audit
       ↓
Signing / Notarization
       ↓
MacSSH 1.0
```

这就是第一版开发的正式基线。

**在 MacSSH 1.0 完成之前，不扩大产品范围。**