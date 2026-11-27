"""进程级共享状态。

日志、终端进度、取消事件、失败记录等需要跨模块共享；集中放在这里，
避免模块之间为了几个全局变量产生循环导入。
"""
from __future__ import annotations

import subprocess
import threading
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # 仅用于类型标注，避免运行时循环导入
    from .console import StatusBoard
    from .failures import FailureStore

# 终端输出与日志文件共用这把锁，防止多线程输出互相覆盖
log_lock = threading.Lock()
log_path: Path | None = None
# 成功/失败分类日志（与主日志同目录，由 CLI 根据 --log-file 推导）
success_log_path: Path | None = None
failure_log_path: Path | None = None
# 短片（时长不超过雪碧图下限）记录，后续运行直接跳过
short_log_path: Path | None = None
run_summary: str | None = None
failure_store: "FailureStore | None" = None
# ffmpeg 的协议代理；由 --proxy 设置。默认不走系统代理，与手机端一致。
ffmpeg_proxy: str | None = None
# 终端 UI：只在交互式终端里启用颜色与多行实时进度
use_color = False
board: "StatusBoard | None" = None

# 中断控制：主线程收到 Ctrl+C 后设置事件，并杀掉正在运行的 ffmpeg/ffprobe
cancel_event = threading.Event()
running_processes: set[subprocess.Popen] = set()
running_lock = threading.Lock()


def cancel_running() -> None:
    """中断时终止正在运行的 ffmpeg/ffprobe，避免它们继续占用连接和 CPU。"""
    cancel_event.set()
    with running_lock:
        processes = list(running_processes)
    for process in processes:
        try:
            process.kill()
        except Exception:
            pass
