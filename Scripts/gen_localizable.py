#!/usr/bin/env python3
"""
Generate MacSSH/Resources/Localizable.xcstrings.

Phase 1（MacSSH 1.1 Localization）的集中翻译资源：
- sourceLanguage = en（用作 fallback / debug）
- 同时为 zh-Hans 与 en 提供完整翻译。
- 所有 key 与源码中实际使用的 localization key 一一对应，
  避免废弃 / 重复 / raw key 泄漏。

不要手改生成的 xcstrings — 改本脚本后重新运行：

    python3 Scripts/gen_localizable.py

生成的 zh-Hans 文案与 AppLanguage.defaultLanguage.locale 完全一致，
新启动且无偏好时 App 即显示简体中文；用户切换 English 后由 SwiftUI
`.environment(\.locale, ...)` 即时驱动 String Catalog 解析切换。
"""

from __future__ import annotations

import json
import os
from pathlib import Path

# (key, en, zh-Hans) 三元组。en 同时作为 fallback / debug 展示。
# 路径、协议、技术名等不翻译；产品名 MacSSH 始终保留。
TRANSLATIONS: list[tuple[str, str, str]] = [
    # ── 通用动作 / buttons ──────────────────────────────────────────
    ("action.add", "Add", "添加"),
    ("action.cancel", "Cancel", "取消"),
    ("action.choose", "Choose…", "选择…"),
    ("action.clear", "Clear", "清除"),
    ("action.close", "Close", "关闭"),
    ("action.connect", "Connect", "连接"),
    ("action.create", "Create", "创建"),
    ("action.delete", "Delete", "删除"),
    ("action.disconnect", "Disconnect", "断开连接"),
    ("action.download", "Download", "下载"),
    ("action.ok", "OK", "好"),
    ("action.reconnect", "Reconnect", "重新连接"),
    ("action.refresh", "Refresh", "刷新"),
    ("action.rename", "Rename", "重命名"),
    ("action.retry", "Retry", "重试"),
    ("action.save", "Save", "保存"),
    ("action.upload", "Upload", "上传"),

    # ── 通用状态 / common ───────────────────────────────────────────
    ("common.none", "None", "无"),
    ("common.on", "On", "开"),

    # ── 侧栏 / sidebar ──────────────────────────────────────────────
    ("sidebar.local_terminal", "Terminal", "终端"),
    ("sidebar.hosts", "Hosts", "主机"),
    ("sidebar.transfers", "Transfers", "传输"),
    ("sidebar.settings", "Settings", "设置"),

    # ── 菜单 / menu ─────────────────────────────────────────────────
    ("menu.terminal", "Terminal", "终端"),
    ("terminal.new_local", "New Local Terminal", "新建本地终端"),
    ("terminal.show_tab", "Show Tab %lld", "显示标签页 %lld"),
    ("toolbar.new_session", "New Session", "新建会话"),
    ("toolbar.new_local_terminal_help", "Create a new local terminal session.", "新建一个本地终端会话。"),

    # ── 状态栏 / status ─────────────────────────────────────────────
    ("status.transfer_queue", "Transfer Queue", "传输队列"),
    ("status.connecting", "Connecting…", "连接中…"),
    ("status.authenticating", "Authenticating…", "认证中…"),
    ("status.verifying_host", "Verifying Host…", "正在验证主机…"),
    ("status.opening", "Opening…", "正在打开…"),
    ("status.local.starting", "Local · %@ · Starting", "本地 · %@ · 启动中"),
    ("status.local.active", "Local · %@", "本地 · %@"),
    ("status.local.exited", "Local · %@ · Exited", "本地 · %@ · 已退出"),
    ("status.local.failed_to_start", "Local · %@ · Failed to Start", "本地 · %@ · 启动失败"),
    ("status.ssh.connecting", "SSH · %@ · Connecting…", "SSH · %@ · 连接中…"),
    ("status.ssh.authenticating", "SSH · %@ · Authenticating…", "SSH · %@ · 认证中…"),
    ("status.ssh.verifying_host", "SSH · %@ · Verifying Host…", "SSH · %@ · 正在验证主机…"),
    ("status.ssh.opening", "SSH · %@ · Opening…", "SSH · %@ · 正在打开…"),
    ("status.ssh.exited", "SSH · %@ · Exited", "SSH · %@ · 已退出"),
    ("status.ssh.disconnected", "SSH ○ %@ · Disconnected", "SSH ○ %@ · 已断开"),
    ("status.ssh.failed", "SSH ○ %@ · Failed", "SSH ○ %@ · 失败"),
    ("status.ssh.closing", "SSH · %@ · Closing…", "SSH · %@ · 正在关闭…"),
    ("terminal.no_sessions", "No Terminal Sessions", "没有终端会话"),

    # ── 终端 / terminal ─────────────────────────────────────────────
    ("terminal.title", "Terminal", "终端"),
    ("terminal.local_title", "Terminal", "终端"),
    ("terminal.local", "Terminal", "终端"),
    ("terminal.remote", "Remote Terminal: %@", "远程终端：%@"),
    ("terminal.ssh_title", "SSH · %@", "SSH · %@"),
    ("terminal.pane", "Pane", "面板"),
    ("terminal.close_tab", "Close tab", "关闭标签页"),
    ("terminal.closing", "Closing…", "正在关闭…"),
    ("terminal.connection_failed", "Connection failed", "连接失败"),
    ("terminal.connection_failed_message", "The connection could not be established.", "无法建立连接。"),
    ("terminal.connection_lost", "Connection lost", "连接丢失"),
    ("terminal.remote_shell_exited", "Remote shell exited", "远程 Shell 已退出"),
    ("terminal.shell_exited", "Shell exited", "Shell 已退出"),
    ("terminal.empty_message", "Open a new terminal session to start working.", "打开新的终端会话以开始工作。"),
    ("terminal.new", "New Terminal", "新建终端"),
    ("terminal.connecting_to", "Connecting to %@", "正在连接到 %@"),
    ("terminal.local_tab_accessibility", "Local terminal tab: %@", "本地终端标签页：%@"),
    ("terminal.ssh_tab_accessibility", "SSH terminal tab: %@", "SSH 终端标签页：%@"),
    ("terminal.close_named_tab", "Close tab: %@", "关闭标签页：%@"),
    ("terminal.retry", "Retry", "重试"),
    ("terminal.close", "Close", "关闭"),
    ("terminal.reconnect", "Reconnect", "重新连接"),
    ("files.title", "Files", "文件"),

    # ── 主机 / hosts ────────────────────────────────────────────────
    ("hosts.title", "Hosts", "主机"),
    ("hosts.search", "Search hosts", "搜索主机"),
    ("hosts.all", "All Hosts", "全部主机"),
    ("hosts.favorites", "Favorites", "收藏"),
    ("hosts.empty", "No Hosts", "没有主机"),
    ("hosts.empty_message", "Add a host to connect and start a terminal session.", "添加主机以连接并开始终端会话。"),
    ("hosts.search_empty_message", "No hosts match your search.", "没有匹配搜索条件的主机。"),
    ("hosts.new", "New Host", "新建主机"),
    ("hosts.add", "Add Host", "添加主机"),
    ("hosts.edit", "Edit Host", "编辑主机"),
    ("hosts.delete", "Delete Host", "删除主机"),
    ("hosts.delete_title", "Delete Host?", "删除主机？"),
    ("hosts.delete_message", "This will remove the host and any saved credentials. This action cannot be undone.", "此操作将删除该主机及其保存的凭据。此操作无法撤销。"),
    ("hosts.delete_failed", "The host could not be deleted. Please try again.", "无法删除该主机。请重试。"),
    ("hosts.delete_keychain_restore_failed", "The host was not deleted and macOS Keychain restoration also failed. Please retry.", "主机未删除，且 macOS Keychain 恢复也失败。请重试。"),
    ("hosts.error_title", "Operation failed", "操作失败"),
    ("hosts.favorite", "Favorite", "收藏"),
    ("hosts.add_favorite", "Add to Favorites", "添加到收藏"),
    ("hosts.remove_favorite", "Remove from Favorites", "从收藏移除"),
    ("hosts.favorite_update_failed", "Favorite could not be updated.", "无法更新收藏。"),
    ("hosts.open_new_terminal_help", "Open a new terminal session for this host.", "为该主机打开新的终端会话。"),
    ("hosts.disconnect_all_help", "Disconnect all terminal sessions for this host.", "断开该主机的全部终端会话。"),
    ("hosts.open_terminal", "Open Terminal", "打开终端"),
    ("hosts.open_remote_terminal", "Open Remote Terminal", "打开远程终端"),
    ("hosts.add_help", "Add a new host or host group.", "添加新的主机或主机分组。"),
    ("hosts.edit_selected_help", "Edit the selected host.", "编辑所选主机。"),
    ("hosts.ungrouped", "Ungrouped", "未分组"),
    ("hosts.count.one", "1 Host", "1 个主机"),
    ("hosts.count.other", "%lld Hosts", "%lld 个主机"),
    ("search.no_results", "No Results", "无结果"),
    ("host.generic_name", "the host", "该主机"),

    # ── 主机编辑器 / host_editor ────────────────────────────────────
    ("host_editor.section.host", "Host", "主机"),
    ("host_editor.section.authentication", "Authentication", "认证"),
    ("host_editor.section.organization", "Organization", "组织"),
    ("host_editor.name", "Name", "名称"),
    ("host_editor.hostname", "Hostname", "主机名"),
    ("host_editor.port", "Port", "端口"),
    ("host_editor.username", "Username", "用户名"),
    ("host_editor.authentication", "Authentication", "认证方式"),
    ("host_editor.group", "Group", "分组"),
    ("host_editor.notes", "Notes", "备注"),
    ("host_editor.password", "Password", "密码"),
    ("host_editor.new_password", "New Password", "新密码"),
    ("host_editor.passphrase", "Passphrase", "密钥短语"),
    ("host_editor.new_passphrase", "New Passphrase", "新密钥短语"),
    ("host_editor.password_stored", "Password saved", "密码已保存"),
    ("host_editor.password_keep_hint", "Leave the field empty to keep the current password.", "留空字段以保留当前密码。"),
    ("host_editor.password_remove_on_save", "Password will be removed on save", "保存时将移除密码"),
    ("host_editor.password_storage_hint", "The password will be stored securely in macOS Keychain.", "密码将安全保存在 macOS Keychain。"),
    ("host_editor.remove_saved_password", "Remove Saved Password", "移除已保存的密码"),
    ("host_editor.passphrase_stored", "Passphrase saved", "密钥短语已保存"),
    ("host_editor.passphrase_keep_hint", "Leave the field empty to keep the current passphrase.", "留空字段以保留当前密钥短语。"),
    ("host_editor.passphrase_remove_on_save", "Passphrase will be removed on save", "保存时将移除密钥短语"),
    ("host_editor.passphrase_optional_hint", "Leave the passphrase empty if your private key is not protected.", "私钥未加密时请留空密钥短语。"),
    ("host_editor.remove_saved_passphrase", "Remove Saved Passphrase", "移除已保存的密钥短语"),
    ("host_editor.private_key_hint", "Choose a private key file for SSH public key authentication.", "为 SSH 公钥认证选择私钥文件。"),
    ("host_editor.no_file_chosen", "No file chosen", "未选择文件"),
    ("host_editor.choose_private_key_title", "Choose Private Key File", "选择私钥文件"),
    ("host_editor.save_failed_title", "Save failed", "保存失败"),
    ("host_editor.save_failed_message", "The host could not be saved.", "无法保存主机。"),
    ("host_editor.swiftdata_save_failed", "SwiftData could not save the host. Please try again.", "SwiftData 无法保存主机。请重试。"),
    ("host_editor.keychain_cleanup_failed", "The host was not saved and macOS Keychain cleanup also failed. Please retry.", "主机未保存，且 macOS Keychain 清理也失败。请重试。"),

    # ── 分组 / groups ───────────────────────────────────────────────
    ("groups.title", "Groups", "分组"),
    ("groups.singular", "Group", "分组"),
    ("groups.new", "New Group", "新建分组"),
    ("groups.rename", "Rename Group", "重命名分组"),
    ("groups.delete", "Delete Group", "删除分组"),
    ("groups.delete_title", "Delete Group?", "删除分组？"),
    ("groups.delete_message", "Hosts in this group will be moved to All Hosts. This action cannot be undone.", "该分组下的主机会移动到全部主机。此操作无法撤销。"),
    ("groups.delete_failed", "The group could not be deleted.", "无法删除分组。"),
    ("groups.save_failed_title", "Save failed", "保存失败"),
    ("groups.save_failed_message", "The group could not be saved.", "无法保存分组。"),
    ("groups.duplicate_name", "A group with this name may already exist.", "可能已存在同名分组。"),

    # ── 认证方式 / authentication ───────────────────────────────────
    ("authentication.password", "Password", "密码"),
    ("authentication.private_key", "Private Key", "私钥"),

    # ── 验证 / validation ──────────────────────────────────────────
    ("validation.name_required", "Name is required.", "名称不能为空。"),
    ("validation.hostname_required", "Hostname is required.", "主机名不能为空。"),
    ("validation.username_required", "Username is required.", "用户名不能为空。"),
    ("validation.port_range", "Port must be between 1 and 65535.", "端口必须为 1 到 65535。"),
    ("validation.private_key_required", "Choose a private key file.", "请选择私钥文件。"),

    # ── Host Trust 对话框 / host_trust ──────────────────────────────
    ("host_trust.title", "Verify Host Identity", "验证主机身份"),
    ("host_trust.message", "The authenticity of this host could not be verified. Compare the fingerprint below before continuing.", "无法验证该主机的真实性。继续之前请核对下方指纹。"),
    ("host_trust.choice_explanation", "Trust Once connects only this time. Trust Always saves the identity for future connections. Cancel disconnects.", "仅本次信任只连接本次。始终信任会保存身份以便后续连接。取消即断开。"),
    ("host_trust.key_type", "Key Type", "密钥类型"),
    ("host_trust.fingerprint", "Fingerprint", "指纹"),
    ("host_trust.trust_once", "Trust Once", "仅本次信任"),
    ("host_trust.trust_always", "Trust Always", "始终信任"),
    ("host.field.host", "Host", "主机"),
    ("host.field.port", "Port", "端口"),

    # ── Host Key Changed 警告 / host_key_changed ───────────────────
    ("host_key_changed.title", "Host Key Changed", "主机密钥已更改"),
    ("host_key_changed.message", "The server's host key differs from the saved identity. This may indicate a man-in-the-middle attack or a reinstalled server. Verify with your administrator before continuing.", "服务器主机密钥与已保存身份不一致。这可能意味着中间人攻击或服务器重装。继续之前请与您的管理员核实。"),
    ("host_key_changed.old_fingerprint", "Old Fingerprint", "原指纹"),
    ("host_key_changed.new_fingerprint", "New Fingerprint", "新指纹"),
    ("host_key_changed.replace", "Replace Trusted Key", "替换受信任密钥"),
    ("host_key_changed.confirm_title", "Replace Trusted Key?", "替换受信任密钥？"),
    ("host_key_changed.confirm_replace", "Replace", "替换"),
    ("host_key_changed.confirm_message", "The saved host key will be deleted and replaced with the new key shown above. This will allow future connections to proceed.", "已保存的主机密钥将被删除并替换为上方显示的新密钥。后续连接将基于新密钥进行。"),

    # ── 已知主机 / known_hosts ─────────────────────────────────────
    ("known_hosts.title", "Known Hosts", "已知主机"),
    ("known_hosts.empty_message", "No trusted hosts yet.", "尚无已信任主机。"),
    ("known_hosts.forget", "Forget", "移除信任"),
    ("known_hosts.forget_title", "Forget Host?", "移除信任主机？"),
    ("known_hosts.forget_message", "Next time you connect, you will be asked to verify this host again.", "下次连接时将再次要求验证该主机。"),
    ("known_hosts.forget_failed_title", "Could not forget host", "无法移除信任主机"),
    ("known_hosts.forget_failed_message", "The trusted host could not be removed. Please try again.", "无法移除已信任的主机。请重试。"),
    ("known_hosts.trusted_at", "Trusted %@", "已信任于 %@"),

    # ── SFTP 浏览器 / sftp ─────────────────────────────────────────
    ("sftp.column.name", "Name", "名称"),
    ("sftp.column.size", "Size", "大小"),
    ("sftp.column.modified", "Modified", "修改时间"),
    ("sftp.column.permissions", "Permissions", "权限"),
    ("sftp.parent", "Parent", "上级"),
    ("sftp.copy_path", "Copy Path", "复制路径"),
    ("sftp.new_folder", "New Folder", "新建文件夹"),
    ("sftp.folder_name", "Folder name", "文件夹名称"),
    ("sftp.new_name", "New name", "新名称"),
    ("sftp.empty_folder", "Empty Folder", "空文件夹"),
    ("sftp.empty_message", "This folder is empty.", "该文件夹为空。"),
    ("sftp.connection_lost", "Connection Lost", "连接丢失"),
    ("sftp.unable_to_load", "Unable to load folder", "无法加载文件夹"),
    ("sftp.connection_inactive", "Connection is inactive. Reconnect to continue.", "连接已断开。请重新连接以继续。"),
    ("sftp.ssh_only", "Files are only available for SSH sessions.", "文件仅对 SSH 会话可用。"),
    ("sftp.operation_failed_title", "Operation failed", "操作失败"),
    ("sftp.transfer_unavailable_title", "Transfer unavailable", "传输不可用"),
    ("sftp.delete_named_title", "Delete “%@”?", "删除“%@”？"),
    ("sftp.delete_message", "This action cannot be undone.", "此操作无法撤销。"),
    ("sftp.rename_ellipsis", "Rename…", "重命名…"),
    ("sftp.item_count.one", "%lld item", "%lld 个项目"),
    ("sftp.item_count.other", "%lld items", "%lld 个项目"),

    # ── Settings ──────────────────────────────────────────────────
    ("settings.title", "Settings", "设置"),
    ("settings.section.general", "General", "通用"),
    ("settings.section.terminal", "Terminal", "终端"),
    ("settings.section.appearance", "Appearance", "外观"),
    ("settings.language", "Language", "语言"),
    ("settings.launch_behavior", "Launch behavior", "启动行为"),
    ("settings.open_main_window", "Open main window", "打开主窗口"),
    ("settings.confirm_before_closing_ssh", "Confirm before closing SSH session", "关闭 SSH 会话前确认"),
    ("settings.font", "Font", "字体"),
    ("settings.font_size", "Font size", "字体大小"),
    ("settings.scrollback", "Scrollback", "回滚行数"),
    ("settings.scrollback_value", "10000 lines", "10000 行"),
    ("settings.paste_highlight", "Highlight pasted text", "粘贴后高亮"),
    ("settings.paste_highlight_help", "Applies to new local zsh terminals. When on, uses the shell's paste highlighting. Does not affect SSH or bracketed paste protection.", "对新建的本地 zsh 终端生效。开启时使用 Shell 自身的粘贴高亮，不影响 SSH 或安全粘贴保护。"),
    ("settings.mode", "Mode", "模式"),
    ("settings.connection_timeout", "Connection timeout", "连接超时"),
    ("settings.connection_timeout_value", "15 seconds", "15 秒"),
    ("settings.read_only_note", "Settings are read-only in this version.", "本版本设置仅供查看，暂不支持修改。"),

    # ── 会话关闭确认 / session close ───────────────────────────────
    ("session.close.title", "Close SSH session?", "关闭 SSH 会话？"),
    ("session.close.disconnect_host", "This will disconnect from %@.", "这将断开与%@的连接。"),
    ("session.close.active_transfers", "This SSH session has %lld file transfer tasks. Closing it will cancel active and waiting transfers.", "当前 SSH 会话有 %lld 个文件传输任务。关闭会话将取消相关传输并断开连接。"),
    ("host.disconnect.title", "Disconnect host?", "断开主机连接？"),
    ("host.disconnect.sessions_message", "This will close %lld terminal session(s) connected to %@.", "这将关闭 %lld 个连接到%@的终端会话。"),

    # ── 传输 / transfers ──────────────────────────────────────────
    ("transfers.title", "Transfers", "传输"),
    ("transfers.empty_message", "Upload and download progress appears here once started.", "上传 / 下载开始后，进度会显示在这里。"),
    ("transfers.clear_finished", "Clear Finished", "清除已完成"),
    ("transfers.count.one", "%lld task", "%lld 个任务"),
    ("transfers.count.other", "%lld tasks", "%lld 个任务"),
    ("transfer.state.waiting", "Waiting", "等待中"),
    ("transfer.state.waiting_for_connection", "Waiting for connection", "等待连接"),
    ("transfer.state.preparing", "Preparing", "准备中"),
    ("transfer.state.transferring", "Transferring", "传输中"),
    ("transfer.state.cancelling", "Cancelling", "正在取消"),
    ("transfer.state.completed", "Completed", "已完成"),
    ("transfer.state.failed", "Failed", "失败"),
    ("transfer.state.cancelled", "Cancelled", "已取消"),
    ("transfer.queue.running", "%lld Transferring", "%lld 个进行中"),
    ("transfer.queue.waiting", "%lld Waiting", "%lld 个等待中"),

    # ── 通用错误 / operation error ────────────────────────────────
    ("error.operation_failed", "The operation could not be completed.", "无法完成操作。"),
    ("error.operation_cancelled", "The operation was cancelled.", "操作已取消。"),

    # ── Keychain 错误 / keychain ───────────────────────────────────
    ("error.keychain.item_not_found", "The credential was not found in macOS Keychain.", "在 macOS Keychain 中找不到凭据。"),
    ("error.keychain.duplicate", "A credential with this identifier already exists.", "已存在相同标识符的凭据。"),
    ("error.keychain.empty", "The credential cannot be empty.", "凭据不能为空。"),
    ("error.keychain.encoding", "The credential could not be prepared for secure storage.", "无法准备凭据以进行安全存储。"),
    ("error.keychain.decoding", "The stored credential could not be decoded.", "无法解码已存储的凭据。"),
    ("error.keychain.access_denied", "macOS Keychain denied access to the credential.", "macOS Keychain 拒绝访问凭据。"),
    ("error.keychain.interaction_not_allowed", "macOS Keychain interaction is not currently allowed.", "当前不允许 macOS Keychain 交互。"),
    ("error.keychain.unavailable", "macOS Keychain is currently unavailable.", "macOS Keychain 当前不可用。"),
    ("error.keychain.unexpected", "The credential operation could not be completed.", "无法完成凭据操作。"),

    # ── SSH 错误 / ssh ─────────────────────────────────────────────
    ("error.ssh.invalid_host", "Please check the host name and username before connecting.", "连接前请核对主机名与用户名。"),
    ("error.ssh.dns", "The server address could not be resolved. Check the hostname and your network.", "无法解析服务器地址。请检查主机名与网络。"),
    ("error.ssh.timeout", "The connection timed out. The server or network may be unreachable.", "连接超时。服务器或网络可能不可达。"),
    ("error.ssh.refused", "The connection was refused. No SSH server is listening on this port.", "连接被拒绝。该端口上没有 SSH 服务器在监听。"),
    ("error.ssh.network", "A network error occurred while connecting to the server.", "连接服务器时发生网络错误。"),
    ("error.ssh.session_init", "The SSH session could not be created.", "无法创建 SSH 会话。"),
    ("error.ssh.handshake", "The SSH handshake failed. The server may not be a compatible SSH server.", "SSH 握手失败。服务器可能不是兼容的 SSH 服务器。"),
    ("error.ssh.host_key_unavailable", "The server identity could not be read after the handshake.", "握手后无法读取服务器身份。"),
    ("error.ssh.trust_rejected", "The connection was cancelled because the server identity was not trusted.", "由于服务器身份未受信任，连接已取消。"),
    ("error.ssh.host_key_changed", "The server's host key has changed. The connection was blocked to protect against a possible man-in-the-middle attack.", "服务器主机密钥已更改。为防范可能的中间人攻击，连接已被阻断。"),
    ("error.ssh.known_host_save", "The trusted host key could not be saved, so the connection was closed before signing in. Please try again.", "无法保存已信任的主机密钥，因此连接在登录前已关闭。请重试。"),
    ("error.ssh.credential_missing", "No saved password was found for this host. Save a password before connecting.", "未找到该主机保存的密码。连接前请先保存密码。"),
    ("error.ssh.password_unsupported", "This server does not support password authentication.", "该服务器不支持密码认证。"),
    ("error.ssh.authentication", "Authentication failed. Check your username and password.", "认证失败。请检查用户名与密码。"),
    ("error.ssh.private_key_missing", "No private key file is configured for this host. Choose a private key before connecting.", "该主机未配置私钥文件。连接前请选择私钥。"),
    ("error.ssh.private_key_not_found", "The configured private key file could not be found. It may have been moved or deleted.", "找不到已配置的私钥文件。它可能已被移动或删除。"),
    ("error.ssh.private_key_unreadable", "The private key file exists but could not be read. Check its file permissions.", "私钥文件存在但无法读取。请检查其文件权限。"),
    ("error.ssh.passphrase_required", "This private key requires a passphrase, but none is saved. Save a passphrase before connecting.", "该私钥需要密钥短语，但未保存。连接前请保存密钥短语。"),
    ("error.ssh.passphrase_incorrect", "The saved passphrase is incorrect and could not decrypt the private key.", "已保存的密钥短语不正确，无法解密私钥。"),
    ("error.ssh.public_key_unsupported", "This server does not support public key authentication.", "该服务器不支持公钥认证。"),
    ("error.ssh.private_key_authentication", "Private key authentication was rejected by the server. Check that the key is authorized.", "私钥认证被服务器拒绝。请确认该密钥已被授权。"),
    ("error.ssh.connection_lost", "The SSH connection was lost.", "SSH 连接已丢失。"),
    ("error.ssh.cancelled", "The connection was cancelled.", "连接已取消。"),
    ("error.ssh.disconnect_cleanup", "The connection closed, but the SSH session could not be cleaned up cleanly.", "连接已关闭，但 SSH 会话未能完全清理。"),

    # ── Remote Terminal 错误 ────────────────────────────────────────
    ("error.remote.channel_open", "The server refused to open a terminal channel.", "服务器拒绝打开终端通道。"),
    ("error.remote.pty", "The server refused to allocate a pseudo-terminal.", "服务器拒绝分配伪终端。"),
    ("error.remote.shell", "The server refused to start a remote shell.", "服务器拒绝启动远程 Shell。"),
    ("error.remote.read", "The terminal connection was interrupted while receiving output.", "接收输出时终端连接被中断。"),
    ("error.remote.write", "Input could not be delivered to the remote terminal.", "输入无法发送到远程终端。"),
    ("error.remote.closed", "The remote terminal channel is closed.", "远程终端通道已关闭。"),
    ("error.remote.resize", "The remote terminal could not be resized.", "无法调整远程终端尺寸。"),

    # ── SFTP 错误 ────────────────────────────────────────────────────
    ("error.sftp.subsystem", "The server could not open an SFTP session.", "服务器无法打开 SFTP 会话。"),
    ("error.sftp.no_such_path", "This folder no longer exists on the server.", "该文件夹在服务器上已不存在。"),
    ("error.sftp.permission_denied", "You do not have permission to view this folder.", "没有权限查看该文件夹。"),
    ("error.sftp.protocol", "The SFTP server reported an error.", "SFTP 服务器报告了错误。"),
    ("error.sftp.invalid_name", "The name cannot be empty, contain /, or be . or ....", "名称不能为空、包含 / 或为 . 或 ..。"),
    ("error.sftp.stale_target", "The item is no longer in this folder. Refresh and try again.", "该项目已不在该文件夹。请刷新后重试。"),
    ("error.sftp.active_transfer", "This file is being transferred, so the operation was blocked.", "该文件正在传输，操作已被阻止。"),
    ("error.sftp.regular_file_only", "Only regular files can be deleted.", "只能删除普通文件。"),
    ("error.sftp.operation_permission", "You do not have permission to complete this operation.", "没有权限完成该操作。"),
    ("error.sftp.target_missing", "The item does not exist. Refresh and try again.", "该项目不存在。请刷新后重试。"),
    ("error.sftp.operation_connection_lost", "The SSH connection was lost.", "SSH 连接已丢失。"),
    ("error.sftp.operation_rejected", "The operation failed. The destination name may already exist, or the server refused it.", "操作失败。目标名称可能已存在，或服务器拒绝了该操作。"),
    ("error.sftp.unavailable", "The SFTP session is unavailable.", "SFTP 会话不可用。"),

    # ── 传输错误 / transfer ────────────────────────────────────────
    ("error.transfer.cancelled", "The transfer was cancelled.", "传输已取消。"),
    ("error.transfer.connection_lost", "The SSH connection was lost and the transfer failed.", "SSH 连接已断开，传输失败。"),
    ("error.transfer.connection_lost_residue", "The SSH connection was lost and the transfer failed. A temporary file may remain on the server: %@. You can clean it up manually later.", "SSH 连接已断开，传输失败。远端可能残留临时文件 %@，可稍后手动清理。"),
    ("error.transfer.remote_file_exists", "A file with the same name already exists on the server and will not be overwritten.", "远程文件已存在，不会自动覆盖该文件。"),
    ("error.transfer.permission_denied", "Permission denied; the transfer could not be completed.", "权限不足，无法完成传输。"),
    ("error.transfer.remote_file_missing", "The remote file no longer exists.", "远程文件已不存在。"),
    ("error.transfer.local_read_failed", "The local file could not be read.", "无法读取本地文件。"),
    ("error.transfer.local_write_failed", "The local temporary file could not be written.", "无法写入本地临时文件。"),
    ("error.transfer.remote_write_failed", "The server reported an error while writing data.", "服务器写入异常。"),
    ("error.transfer.remote_protocol_error", "The server reported a protocol error during the transfer.", "服务器报告了协议错误，传输失败。"),
    ("error.transfer.verification_failed", "Transfer verification failed; the byte count does not match.", "传输校验失败，字节数不一致。"),
    ("error.transfer.publish_failed", "Replacing the destination file failed.", "替换目标文件失败。"),
    ("error.transfer.queue_full", "The transfer queue is full. Please wait for some tasks to finish.", "传输队列已满，请等待部分任务完成。"),
    ("error.transfer.session_unavailable", "The current session is unavailable.", "当前会话不可用。"),
    ("error.transfer.session_missing", "The session no longer exists.", "会话不存在。"),
    ("error.transfer.upload_regular_file_only", "Only regular files can be uploaded.", "只能上传普通文件。"),
    ("error.transfer.download_regular_file_only", "Only regular files can be downloaded.", "仅支持下载普通文件。"),
    ("error.transfer.upload_conflict", "A task uploading to the same remote destination is already in the queue.", "队列中已有相同远端目标的上传任务。"),
    ("error.transfer.download_conflict", "A task downloading to the same local destination is already in the queue.", "队列中已有相同本地目标文件的传输任务。"),

    # ── 无障碍 / accessibility ────────────────────────────────────
    ("accessibility.main_sidebar", "Main sidebar", "主侧栏"),
    ("accessibility.hosts_sidebar", "Hosts sidebar", "主机侧栏"),
    ("accessibility.terminal_tabs", "Terminal tabs", "终端标签栏"),
    ("accessibility.macssh_workspace", "MacSSH workspace", "MacSSH 工作区"),
    ("accessibility.host_trust_dialog", "Host trust verification dialog", "主机信任验证对话框"),
    ("accessibility.host_key_changed_dialog", "Host key changed warning dialog", "主机密钥已更改警告对话框"),
    ("accessibility.selected", "Selected", "已选中"),
    # 已有外观、高亮和右侧命令栏翻译也须保留，避免重新生成时丢失。
    ("action.edit", "Edit", "编辑"),
    ("common.save", "Save", "保存"),
    ("settings.appearance.dark", "Dark", "深色"),
    ("settings.appearance.light", "Light", "浅色"),
    ("settings.appearance.system", "Follow System", "跟随系统"),
    ("settings.terminal.highlight.add", "Add Rule", "添加规则"),
    ("settings.terminal.highlight.case_insensitive", "Case Insensitive", "不区分大小写"),
    ("settings.terminal.highlight.case_sensitive", "Case Sensitive", "区分大小写"),
    ("settings.terminal.highlight.color", "Color", "颜色"),
    ("settings.terminal.highlight.color.blue", "Blue", "蓝色"),
    ("settings.terminal.highlight.color.gray", "Gray", "灰色"),
    ("settings.terminal.highlight.color.green", "Green", "绿色"),
    ("settings.terminal.highlight.color.orange", "Orange", "橙色"),
    ("settings.terminal.highlight.color.purple", "Purple", "紫色"),
    ("settings.terminal.highlight.color.red", "Red", "红色"),
    ("settings.terminal.highlight.color.yellow", "Yellow", "黄色"),
    ("settings.terminal.highlight.delete", "Delete", "删除"),
    ("settings.terminal.highlight.empty", "No highlight rules", "暂无高亮规则"),
    ("settings.terminal.highlight.enable", "Enable Highlighting", "自动高亮"),
    ("settings.terminal.highlight.enabled", "Enabled", "启用"),
    ("settings.terminal.highlight.text", "Text", "文本"),
    ("sidebar_right.add", "Add", "添加"),
    ("sidebar_right.add_command", "New Command", "新增命令"),
    ("sidebar_right.add_group", "New Group", "新增分组"),
    ("sidebar_right.clear_history", "Clear History", "清空历史"),
    ("sidebar_right.clear_history_confirm", "Clear all command history?", "确认清空所有命令历史？"),
    ("sidebar_right.clear_history_message", "This only removes command history. Saved commands and groups are not affected.", "这只会删除命令历史。常用命令和分组不受影响。"),
    ("sidebar_right.command_empty", "Command cannot be empty.", "命令不能为空。"),
    ("sidebar_right.command_placeholder", "Command", "命令"),
    ("sidebar_right.command_single_line", "Command must be a single line.", "命令必须为单行。"),
    ("sidebar_right.delete_command", "Delete Command", "删除命令"),
    ("sidebar_right.delete_group", "Delete Group", "删除分组"),
    ("sidebar_right.delete_group_confirm", "Delete this group?", "确认删除分组？"),
    ("sidebar_right.delete_group_message", "Commands in this group will move to Ungrouped (%lld command(s)).", "分组中的命令将移到未分组（%lld 条命令）。"),
    ("sidebar_right.edit", "Edit", "编辑"),
    ("sidebar_right.edit_command", "Edit Command", "编辑命令"),
    ("sidebar_right.execute", "Run Command", "执行命令"),
    ("sidebar_right.group_actions", "Group Actions", "分组操作"),
    ("sidebar_right.group_empty", "No commands", "暂无命令"),
    ("sidebar_right.group_name", "Group name", "分组名称"),
    ("sidebar_right.group_name_empty", "Group name cannot be empty.", "分组名称不能为空。"),
    ("sidebar_right.hide", "Hide Sidebar", "隐藏侧边栏"),
    ("sidebar_right.history", "History", "历史记录"),
    ("sidebar_right.history_disclosure", "This version records commands run through MacSSH.\nCommands entered manually in the terminal are not recorded.", "当前版本仅记录通过 MacSSH 执行的命令。\n手动在终端输入的命令不会记录。"),
    ("sidebar_right.history_empty", "No command history", "暂无历史记录"),
    ("sidebar_right.local", "Local", "本地"),
    ("sidebar_right.paste", "Paste into Terminal", "粘贴到终端"),
    ("sidebar_right.rename", "Rename", "重命名"),
    ("sidebar_right.rename_group", "Rename Group", "重命名分组"),
    ("sidebar_right.resize", "Resize Sidebar", "调整侧边栏宽度"),
    ("sidebar_right.save_history", "Save command history", "保存命令历史"),
    ("sidebar_right.saved_commands", "Saved Commands", "常用命令"),
    ("sidebar_right.saved_empty", "No saved commands", "暂无常用命令"),
    ("sidebar_right.show", "Show Sidebar", "显示侧边栏"),
    ("sidebar_right.ungrouped", "Ungrouped", "未分组"),
    ("validation.highlight_text_required", "Highlight text is required", "请输入高亮文本"),
]

def build_catalog() -> dict:
    strings: dict[str, dict] = {}
    for key, en, zh in TRANSLATIONS:
        strings[key] = {
            "extractionState": "manual_uploaded",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            },
        }
    return {
        "sourceLanguage": "en",
        "strings": dict(sorted(strings.items())),
        "version": "1.0",
    }

def main() -> None:
    repo = Path(__file__).resolve().parent.parent
    out = repo / "MacSSH" / "Resources" / "Localizable.xcstrings"
    out.parent.mkdir(parents=True, exist_ok=True)
    catalog = build_catalog()
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {out.relative_to(repo)} ({len(TRANSLATIONS)} keys)")

if __name__ == "__main__":
    main()
