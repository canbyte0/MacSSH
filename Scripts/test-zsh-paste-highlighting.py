#!/usr/bin/env python3
"""隔离 HOME 验证启动代理及真实 PTY 安全粘贴；不读取/写入用户配置。"""
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import tempfile
import time
import unittest

INTEGRATION = Path(__file__).resolve().parents[1] / "MacSSH/Resources/ShellIntegration"


class PasteHighlightTests(unittest.TestCase):
    """只启动本机 /bin/zsh，不建立 SSH 连接或执行外部粘贴命令。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="MacSSH-paste-test-")
        self.home = Path(self.temp.name)
        self.env = dict(HOME=str(self.home), TERM="xterm-256color", PATH="/usr/bin:/bin")
        self.env["ZDOTDIR"] = str(INTEGRATION)
        # 默认覆盖关闭态；需要原生开启态的用例会显式移除启动代理。
        self.env["MACSSH_PASTE_HIGHLIGHT_ENABLED"] = "0"

    def tearDown(self):
        self.temp.cleanup()

    def config(self, name, content):
        """生成测试专属的启动配置，不触碰真实 HOME。"""
        (self.home / name).write_text(content, encoding="utf-8")

    def run_shell(self, command, flags="-lic"):
        # -c 不显示提示符，显式执行单次 hook 模拟该时点；真实提示符另由 PTY 用例覆盖。
        command = '(( ${+functions[_macssh_install_paste_highlight_once]} )) && _macssh_install_paste_highlight_once; ' + command
        result = subprocess.run(["/bin/zsh", flags, command], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("not found", result.stderr)
        return result.stdout

    def test_startup_order_and_global_scope(self):
        for name in (".zshenv", ".zprofile", ".zshrc", ".zlogin"):
            self.config(name, f'typeset test_order; test_order+="{name},"\n')
        output = self.run_shell('print -r -- "$test_order|${ZDOTDIR-unset}|$zle_highlight"')
        self.assertIn(".zshenv,.zprofile,.zshrc,.zlogin,|unset|paste:none", output)

    def test_only_paste_style_changes(self):
        self.config(".zshrc", "zle_highlight=(region:underline paste:standout special:bold)\n")
        self.assertIn("region:underline special:bold paste:none", self.run_shell('print -r -- "$zle_highlight"'))

    def test_enabled_uses_native_shell_configuration(self):
        self.env.pop("ZDOTDIR")
        self.config(".zshrc", "zle_highlight=(paste:standout region:underline)\n")
        self.assertIn("paste:standout region:underline", self.run_shell('print -r -- "$zle_highlight"'))

    def test_custom_zdotdir_and_cleanup(self):
        custom = self.home / "custom config"
        custom.mkdir()
        self.config(".zshenv", 'export ZDOTDIR="$HOME/custom config"\n')
        (custom / ".zshrc").write_text('typeset custom_loaded=yes\n', encoding="utf-8")
        output = self.run_shell('print -r -- "$custom_loaded|$ZDOTDIR|${+_macssh_startup_directory}|${+functions[_macssh_install_paste_highlight_once]}"')
        self.assertIn(f"yes|{custom}|0|0", output)

    def test_nonlogin_interactive_shell(self):
        self.assertIn("paste:none|unset", self.run_shell('print -r -- "$zle_highlight|${ZDOTDIR-unset}"', "-ic"))

    def test_user_zdotdir_export_attribute_and_logout(self):
        self.config(".zshenv", 'ZDOTDIR="$HOME"\n')
        self.config(".zlogout", "print USER_LOGOUT\n")
        output = self.run_shell('print -r -- "${parameters[ZDOTDIR]}"')
        self.assertIn("scalar\nUSER_LOGOUT", output)
        self.assertNotIn("export", output)

    def test_noninteractive_shell_is_not_reconfigured(self):
        output = self.run_shell('print -r -- "${ZDOTDIR-unset}|${+zle_highlight}"', "-c")
        self.assertIn("unset|0", output)

    def test_history_path_stays_in_user_home(self):
        output = self.run_shell('print -r -- "$HISTFILE"')
        self.assertIn(str(self.home / ".zsh_history"), output)
        self.assertNotIn(str(INTEGRATION), output)

    def test_existing_precmd_hooks_are_preserved(self):
        self.config(".zshrc", "user_hook() { :; }; precmd_functions+=(user_hook)\n")
        self.assertIn("user_hook", self.run_shell('print -r -- "$precmd_functions"'))

    def test_rcs_disabled_does_not_leak_integration(self):
        self.config(".zshenv", "unsetopt rcs\n")
        self.config(".zshrc", "print SHOULD_NOT_RUN\n")
        output = self.run_shell('print -r -- "${ZDOTDIR-unset}|$zle_highlight"')
        self.assertIn("unset|paste:none", output)
        self.assertNotIn("SHOULD_NOT_RUN", output)

    def test_real_pty_multiline_paste_waits_for_return(self):
        self.check_pty_paste(highlight=False)

    def test_real_pty_enabled_preserves_native_highlight(self):
        self.env.pop("ZDOTDIR")
        self.check_pty_paste(highlight=True)

    def test_real_pty_runtime_toggle_redraws_existing_paste(self):
        """同一 zsh / PTY 中开启和关闭都立即重绘，且粘贴内容不执行。"""
        control_directory = self.home / "MacSSH-paste-highlight-runtime-test"
        control_directory.mkdir(mode=0o700)
        fifo = control_directory / "control.fifo"
        os.mkfifo(fifo, 0o600)
        # 模拟 App 在 Shell 启动前以 O_RDWR 持有通道；zsh 打开后会立即 unlink。
        writer = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        self.env["MACSSH_PASTE_HIGHLIGHT_ENABLED"] = "1"
        self.env["MACSSH_PASTE_HIGHLIGHT_FIFO"] = str(fifo)
        self.config(".zshrc", "PROMPT='READY> '; RPROMPT=''; unsetopt beep\n")

        pid, fd = pty.fork()
        if pid == 0:
            os.execve("/bin/zsh", ["-zsh"], self.env)

        try:
            output = self.read_until(fd, b"READY>")
            if b"\x1b[?2004h" not in output:
                output += self.read_until(fd, b"\x1b[?2004h")
            self.assertIn(b"\x1b[?2004h", output)
            self.assertFalse(control_directory.exists(), "zsh 打开 FIFO 后应清理临时目录入口")

            os.write(fd, b"\x1b[200~print LIVE_TOGGLE_SAFE\x1b[201~")
            enabled = self.read_until(fd, b"LIVE_TOGGLE_SAFE")
            self.assertIn(b"\x1b[7m", enabled)
            self.assertNotIn(b"\r\nLIVE_TOGGLE_SAFE\r\n", enabled)

            os.write(writer, b"0\n")
            disabled = self.read_redraw(fd)
            self.assertIn(b"LIVE_TOGGLE_SAFE", self.strip_ansi(disabled))
            self.assertNotIn(b"\x1b[7m", disabled)

            os.write(writer, b"1\n")
            reenabled = self.read_redraw(fd)
            self.assertIn(b"LIVE_TOGGLE_SAFE", self.strip_ansi(reenabled))
            self.assertIn(b"\x1b[7m", reenabled)

            # 切换本身不能执行输入区中的命令；只在显式 Return 后执行。
            os.write(fd, b"\r")
            executed = self.read_until(fd, b"\r\nLIVE_TOGGLE_SAFE\r\n")
            self.assertIn(b"LIVE_TOGGLE_SAFE", executed)
        finally:
            os.close(writer)
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(fd)

    def read_until(self, fd, marker, timeout=5):
        """从测试 PTY 读取到指定字节标记；超时输出原始证据。"""
        data = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                data += os.read(fd, 65536)
                if marker in data:
                    return data
        self.fail(f"PTY timeout waiting for {marker!r}: {data!r}")

    def read_redraw(self, fd, timeout=2):
        """读取一次 ZLE 重绘；短暂静默后返回，保留 ANSI 供样式断言。"""
        data = b""
        deadline = time.monotonic() + timeout
        quiet_deadline = None
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                data += os.read(fd, 65536)
                quiet_deadline = time.monotonic() + 0.15
            elif quiet_deadline is not None and time.monotonic() >= quiet_deadline:
                return data
        self.fail(f"PTY timeout waiting for redraw: {data!r}")

    @staticmethod
    def strip_ansi(data):
        """移除 CSI 控制序列，仅用于核对重绘后的可见文本。"""
        return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data)

    def check_pty_paste(self, highlight):
        """两种开关状态均验证安全粘贴，并对比真实 ANSI 反色输出。"""
        self.config(".zshrc", "PROMPT='READY> '; RPROMPT=''; unsetopt beep\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.execve("/bin/zsh", ["-zsh"], self.env)
        try:
            output = self.read_until(fd, b"READY>")
            # ZLE 必须仍开启 bracketed paste，不能为了消除高亮绕过安全协议。
            if b"\x1b[?2004h" not in output:
                output += self.read_until(fd, b"\x1b[?2004h")
            self.assertIn(b"\x1b[?2004h", output)
            os.write(fd, b"\x1b[200~print SAFE_\"EXECUTED\"\nprint SECOND_\"EXECUTED\"\x1b[201~")
            pasted = self.read_until(fd, b"SECOND_")
            self.assertNotIn(b"SAFE_EXECUTED", pasted)
            self.assertEqual(b"\x1b[7m" in pasted, highlight, "只切换粘贴文本的反色高亮")
            os.write(fd, b"\r")
            self.read_until(fd, b"SECOND_EXECUTED")
        finally:
            # 只终止本测试创建的 PTY 子进程，避免遗留 Shell。
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(fd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
