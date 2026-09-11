#!/usr/bin/env python3
"""隔离 HOME 验证 MacSSH OSC 7 cwd emitter：真实 zsh / PTY，不读取用户配置。

 emitter 的独立 oracle：Python urllib.parse.quote 的 RFC3986 编码
（unreserved + `/` 原样、其余 UTF-8 byte 大写 %HH）与 production
`.zshenv` emitter 的逐字节比对。与 Swift 侧测试（LocalShellOSC7Tests）
互不依赖：这里证明「编码器产出」，Swift 侧证明「parser 解码」。
"""
import os
import pty
import re
import select
import signal
import shlex
import subprocess
import tempfile
import time
import unittest
import urllib.parse
from pathlib import Path

INTEGRATION = Path(__file__).resolve().parents[1] / "MacSSH/Resources/ShellIntegration"

OSC7 = re.compile(rb"\x1b\]7;file://([^\x07]*)\x07")
ST_VARIANT = re.compile(rb"\x1b\]7;[^\x07]*\x1b\\")


def reference_url(path: str, host: str) -> str:
    """RFC3986 参考编码：unreserved + `/` 原样，其余 UTF-8 byte %HH 大写。"""
    return "file://" + host + urllib.parse.quote(path, safe="/")


def decoded_path(raw_url: bytes) -> str:
    """与 Swift `URL(string:).path` 同语义：提取并解码 path 段。"""
    url = "file://" + raw_url.decode("ascii")
    return urllib.parse.unquote(urllib.parse.urlsplit(url).path)


class OSC7EmitterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="MacSSH-osc7-test-")
        self.home = Path(self.temp.name)
        self.env = dict(HOME=str(self.home), TERM="xterm-256color", PATH="/usr/bin:/bin")
        self.env["ZDOTDIR"] = str(INTEGRATION)
        # 与生产恒定注入一致：显式传递开关初值（粘贴高亮测试另有矩阵）。
        self.env["MACSSH_PASTE_HIGHLIGHT_ENABLED"] = "0"

    def tearDown(self):
        self.temp.cleanup()

    def config(self, name, content):
        """生成测试专属启动配置，不触碰真实 HOME。"""
        (self.home / name).write_text(content, encoding="utf-8")

    def run_shell(self, command, flags="-lic"):
        result = subprocess.run(["/bin/zsh", flags, command], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("not found", result.stderr)
        return result.stdout

    # MARK: 编码矩阵（任务书 §4）

    def test_encoding_matrix_matches_reference(self):
        names = [
            "simple",
            "path with spaces",
            "路径 中文",
            "한국어",
            "日本語",
            "emoji-😀",
            "contains%-percent",
            "question?mark",
            "hash#fragment",
            "mixed-中文 %-#?",
        ]
        for name in names:
            (self.home / name).mkdir()
        host = self.run_shell("print -r -- $HOST").strip()
        # 直接驱动 production emitter 函数（-i 下定义），逐目录比对。
        script = "; ".join(
            f"cd -- {shlex.quote(str(self.home / name))} && _macssh_osc7_update_cwd"
            for name in names
        )
        output = self.run_shell(script, flags="-ic")
        emitted = OSC7.findall(output.encode("utf-8", "surrogateescape"))
        self.assertEqual(len(emitted), len(names), f"每目录一次上报：{output!r}")
        for name, raw in zip(names, emitted):
            url = "file://" + raw.decode("ascii")
            self.assertEqual(url, reference_url(str(self.home / name), host),
                             f"编码不符：{name}")

    def test_hard_percent_cases_are_encoded(self):
        """任务书 §4 硬断言：% → %25、? → %3F、# → %23、space → %20。"""
        names = ["with %", "with ?", "with #", "with space"]
        for name in names:
            (self.home / name).mkdir()
        script = "; ".join(
            f"cd -- {shlex.quote(str(self.home / name))} && _macssh_osc7_update_cwd"
            for name in names
        )
        output = self.run_shell(script, flags="-ic").encode("utf-8", "surrogateescape")
        urls = b"\n".join(OSC7.findall(output)).decode("ascii")
        self.assertIn("%25", urls)
        self.assertIn("%3F", urls)
        self.assertIn("%23", urls)
        self.assertIn("%20", urls)

    def test_unicode_is_encoded_per_utf8_bytes(self):
        """Unicode 按字节编码（绝不只做 `${PWD// /%20}`）。"""
        (self.home / "路径").mkdir()
        output = self.run_shell(
            f"cd -- {shlex.quote(str(self.home / '路径'))} && _macssh_osc7_update_cwd",
            flags="-ic"
        ).encode("utf-8", "surrogateescape")
        # 路 = E8 B7 AF，径 = E5 BE 84（host 前缀不参与断言）。
        self.assertRegex(output, rb"/%E8%B7%AF%E5%BE%84\x07")

    def test_decoding_roundtrip(self):
        """emitter 输出 → percent-decode → 原始路径（与 Swift URL.path 同语义）。"""
        names = ["simple", "path with spaces", "路径 中文", "emoji-😀", "mixed-中文 %-#?"]
        for name in names:
            (self.home / name).mkdir()
        script = "; ".join(
            f"cd -- {shlex.quote(str(self.home / name))} && _macssh_osc7_update_cwd"
            for name in names
        )
        output = self.run_shell(script, flags="-ic").encode("utf-8", "surrogateescape")
        emitted = OSC7.findall(output)
        for name, raw in zip(names, emitted):
            self.assertEqual(decoded_path(raw), str(self.home / name))

    # MARK: 终止符与形态（任务书 §5/§6）

    def test_bel_terminator_locked_no_st_variant(self):
        (self.home / "simple").mkdir()
        output = self.run_shell(
            f"cd -- {shlex.quote(str(self.home / 'simple'))} && _macssh_osc7_update_cwd",
            flags="-ic"
        ).encode("utf-8", "surrogateescape")
        self.assertRegex(output, rb"\x1b\]7;file://[^\x07]*\x07")
        self.assertIsNone(ST_VARIANT.search(output), "本阶段不混用 ST 终止符")

    def test_noninteractive_shell_emits_nothing(self):
        """emitter 函数只在 interactive shell 定义（`[[ -o interactive ]]` 守卫）。"""
        result = subprocess.run(
            ["/bin/zsh", "-c", "cd / && true"], env=self.env,
            capture_output=True, timeout=10, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b]7;", result.stdout)

    def test_native_shell_without_integration_emits_nothing(self):
        """无 ZDOTDIR 的原生 zsh 不发 OSC 7：证明上报来自 MacSSH 自有 emitter，
        而非系统 cwd hook / TERM_PROGRAM 伪装（任务书 §6）。"""
        env = {k: v for k, v in self.env.items() if k != "ZDOTDIR"}
        result = subprocess.run(
            ["/bin/zsh", "-ic", "true"], env=env,
            capture_output=True, timeout=10, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("\x1b]7;", result.stdout)

    def test_no_term_program_spoofing_in_integration_source(self):
        """静态审计（任务书 §6）：integration 源码不得 *设置* TERM_PROGRAM。
        （注释里讨论「不设置 TERM_PROGRAM」不构成 spoofing。）"""
        source = (INTEGRATION / ".zshenv").read_text(encoding="utf-8")
        stripped = "\n".join(
            line.split("#", 1)[0] for line in source.splitlines()
        )
        self.assertNotIn("TERM_PROGRAM", stripped)
        self.assertNotIn("Apple_Terminal", stripped)

    # MARK: 用户启动链共存（任务书 §7/§8）

    def test_user_startup_files_still_load_with_osc7(self):
        self.config(".zshrc", "typeset -g USER_RC_LOADED=yes\n")
        output = self.run_shell(
            "print -r -- \"RC=$USER_RC_LOADED|${ZDOTDIR-unset}\"; cd $HOME && _macssh_osc7_update_cwd",
            flags="-ic")
        self.assertIn("RC=yes|unset", output)
        self.assertRegex(output.encode("utf-8"), rb"\x1b\]7;file://[^\x07]*\x07")

    def test_emitter_survives_user_precmd_hooks(self):
        self.config(".zshrc", "user_hook() { :; }; precmd_functions+=(user_hook)\n")
        # -c 模式不绘制提示符：显式触发 install-once（与 paste 测试同模式），
        # 之后 precmd 队列必须同时保留用户 hook 与 emitter。
        output = self.run_shell(
            "(( ${+functions[_macssh_install_osc7_once]} )) && _macssh_install_osc7_once; "
            'print -r -- "$precmd_functions"', flags="-ic")
        self.assertIn("user_hook", output)
        self.assertIn("_macssh_osc7_update_cwd", output)
        self.assertNotIn("_macssh_install_osc7_once", output, "install hook 必须自清理")

    # MARK: 真实 PTY（precmd 自动链路，任务书 §8）

    def test_real_pty_prompt_emits_osc7_and_updates_on_cd(self):
        self.config(".zshrc", "PROMPT='READY> '; RPROMPT=''; unsetopt beep\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve("/bin/zsh", ["-zsh"], self.env)
        try:
            first = self.read_until(fd, b"READY>")
            emissions = OSC7.findall(first)
            self.assertEqual(len(emissions), 1, f"首提示符恰好一次上报：{first!r}")
            # 登录 zsh 启动时 PWD 来自 getcwd（kernel canonical 路径），
            # 与 cd 后的逻辑路径（见下）语义不同——两者都合法。
            self.assertEqual(decoded_path(emissions[0]), os.path.realpath(self.home))

            target = self.home / "路径 😀"
            target.mkdir()
            os.write(fd, f"cd -- '{target}'\r".encode())
            second = self.read_until(fd, b"READY>")
            # 每次提示符重绘一次上报：cd 后的最新上报必须指向新目录。
            emissions = OSC7.findall(second)
            self.assertTrue(emissions, "cd 后必须再次上报")
            self.assertEqual(decoded_path(emissions[-1]), str(target))
        finally:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(fd)

    def test_real_pty_osc7_works_with_paste_highlight_enabled(self):
        """粘贴高亮 ON（无控制通道）时 OSC 7 仍工作（任务书 §8 hard gate）。"""
        self.env["MACSSH_PASTE_HIGHLIGHT_ENABLED"] = "1"
        self.config(".zshrc", "PROMPT='READY> '; RPROMPT=''; unsetopt beep\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve("/bin/zsh", ["-zsh"], self.env)
        try:
            output = self.read_until(fd, b"READY>")
            self.assertRegex(output, rb"\x1b\]7;file://[^\x07]*\x07")
            self.assertIn(b"\x1b[?2004h", output, "bracketed paste 不得回归")
        finally:
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
