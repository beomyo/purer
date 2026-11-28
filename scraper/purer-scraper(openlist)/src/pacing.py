"""每个视频的最低处理时间：避免跳过太快的视频把 115 风控引出来。

雪碧图只处理时长超过下限的视频，短片通常读一次时长（约 1 秒）就被跳过，紧接着
打开下一个文件。请求数虽然不多，但连续、快速地切换文件本身就会触发 115 的 WAF。
这里给每个视频一个最低处理时间：

- 目标用时在 ``min_seconds`` 到 ``1.5 × min_seconds`` 之间随机（默认 4–6 秒），
  没有固定节奏；
- 视频本身已经处理够久（正常取帧通常远超这个值）就不等待；
- 取消（Ctrl+C）时立即返回。
"""
from __future__ import annotations

import random
import time

from . import runtime

MIN_VIDEO_SECONDS_RATIO = 1.5


def target_seconds(min_seconds: float) -> float:
    """本次视频的目标用时：min_seconds 到 1.5 倍之间随机；0 表示不限制。"""
    if min_seconds <= 0:
        return 0.0
    return min_seconds * random.uniform(1.0, MIN_VIDEO_SECONDS_RATIO)


def hold_min_seconds(started_at: float, min_seconds: float) -> float:
    """视频用时不足目标值时补足等待，返回实际等待的秒数（0 表示无需等待）。"""
    target = target_seconds(min_seconds)
    if target <= 0:
        return 0.0
    delay = started_at + target - time.monotonic()
    if delay <= 0:
        return 0.0
    runtime.cancel_event.wait(delay)
    return delay
