"""终端输出：颜色、日志、单行/多行实时进度。

交互式终端里，进度区由「当前文件夹汇总 + 每个并发任务一行」组成；
日志行打印前会先清掉进度区，打印后再重画，避免多线程互相覆盖。
非交互环境（计划任务、重定向）自动关闭颜色与进度区，只输出纯文本日志。
"""
from __future__ import annotations

import os
import re
import shutil
import sys
import time
import unicodedata

from . import runtime

_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def setup_console() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    if not sys.stdout.isatty():
        return
    if os.name == "nt":
        # 打开 Windows 控制台的 ANSI 转义支持。即使 NO_COLOR 关闭颜色，
        # 进度区仍会用到 \r 和清行转义，所以这一步要在颜色判断之前。
        try:
            import ctypes

            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        except Exception:
            pass
    if os.environ.get("NO_COLOR") is not None:
        return
    runtime.use_color = True


def c(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if runtime.use_color else text


def dim(text: str) -> str:
    return c(text, "2")


def bold(text: str) -> str:
    return c(text, "1")


def green(text: str) -> str:
    return c(text, "32")


def red(text: str) -> str:
    return c(text, "31")


def yellow(text: str) -> str:
    return c(text, "33")


def cyan(text: str) -> str:
    return c(text, "36")


def hr(char: str = "─", width: int = 64) -> None:
    print(dim(char * width))


def _display_width(text: str) -> int:
    """粗略计算终端显示宽度：中日韩全角字符按 2 列。"""
    width = 0
    for ch in text:
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def fit_status(text: str, columns: int) -> str:
    """把单行文本截断到终端宽度，避免折行后清不干净。"""
    limit = max(10, columns - 1)
    if _display_width(text) <= limit:
        return text
    out = ""
    used = 0
    for ch in text:
        step = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if used + step > limit:
            break
        out += ch
        used += step
    return out


class StatusBoard:
    """交互式终端里的多行实时进度区。

    第 1 行是当前文件夹汇总，之后每个并发任务一行。日志与进度共用
    ``runtime.log_lock``，所以打印日志时会先清空进度区、打印、再重画。
    """

    def __init__(self) -> None:
        self.enabled = sys.stdout.isatty()
        self.lines: list[str] = []
        self.drawn = 0

    def update(self, lines: list[str]) -> None:
        with runtime.log_lock:
            self.lines = [line for line in lines if line]
            self._redraw_locked()

    def _clear_locked(self) -> None:
        if not self.enabled or not self.drawn:
            return
        parts = ["\r"]
        if self.drawn > 1:
            parts.append(f"\033[{self.drawn - 1}A")
        for index in range(self.drawn):
            parts.append("\033[2K")
            if index < self.drawn - 1:
                parts.append("\n")
        if self.drawn > 1:
            parts.append(f"\033[{self.drawn - 1}A")
        parts.append("\r")
        sys.stdout.write("".join(parts))
        sys.stdout.flush()
        self.drawn = 0

    def _draw_locked(self) -> None:
        if not self.enabled or not self.lines:
            return
        columns = shutil.get_terminal_size((100, 24)).columns
        text = "\n".join(fit_status(line, columns) for line in self.lines)
        sys.stdout.write(text)
        sys.stdout.flush()
        self.drawn = len(self.lines)

    def _redraw_locked(self) -> None:
        self._clear_locked()
        self._draw_locked()

    def done(self) -> None:
        with runtime.log_lock:
            self._clear_locked()
            # 之后即使还有刷新线程醒来，也不再往终端上画
            self.enabled = False
            self.lines = []


def log(message: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {message}"
    with runtime.log_lock:
        board = runtime.board
        if board is not None:
            board._clear_locked()
        print(line, flush=True)
        if board is not None:
            board._draw_locked()
        if runtime.log_path is not None:
            try:
                with open(runtime.log_path, "a", encoding="utf-8") as fh:
                    # 日志文件不写 ANSI 颜色
                    fh.write(_ANSI_RE.sub("", line) + "\n")
            except OSError:
                pass


def log_line(message: str) -> None:
    """只写日志文件，不打印到终端；用于运行分隔和结束汇总。"""
    if runtime.log_path is None:
        return
    line = f"[{time.strftime('%H:%M:%S')}] {message}"
    with runtime.log_lock:
        try:
            with open(runtime.log_path, "a", encoding="utf-8") as fh:
                fh.write(_ANSI_RE.sub("", line) + "\n")
        except OSError:
            pass


def progress_bar(done: int, total: int, width: int = 18) -> str:
    if total <= 0:
        return ""
    filled = min(width, int(width * done / total))
    return "[" + "█" * filled + "░" * (width - filled) + "]"
