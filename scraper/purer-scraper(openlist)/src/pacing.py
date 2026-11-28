"""雪碧图取帧节奏：每个视频至少处理一段时间，上游读取均匀铺开。

115 的 WAF 不只按请求总数拦截，还会看「打开新文件/并发读取的速度」：快速路径
把单个视频压到 40–100 秒后，连续切换文件仍然会触发风控。这里给每个正在生成雪碧图
的视频一个取帧节奏：

- 第 i 帧的数据读取与上一帧至少间隔 ``min_seconds / count`` 秒；
- 所有帧取完、雪碧图上传结束时，如果整个视频还不到 ``min_seconds`` 秒，再补足。

这样每个视频的处理时间最少 ``min_seconds`` 秒（默认 90），请求在时间上均匀分布，
而不是开头一阵狂读、后面空等。取消（Ctrl+C）时等待会立即返回，由调用方检查。
"""
from __future__ import annotations

import threading
import time

from . import runtime


class SpritePacer:
    """一个视频的取帧节奏；线程安全，可被多个取帧工作线程共用。"""

    def __init__(self, count: int, min_seconds: float) -> None:
        self.count = max(1, count)
        self.min_seconds = max(0.0, min_seconds)
        self.interval = self.min_seconds / self.count
        self.started_at = time.monotonic()
        self._next_at = self.started_at
        self._lock = threading.Lock()

    def wait_for(self, index: int = 0) -> None:
        """领取第 index 帧的时间槽并按需等待（每帧只调用一次）。"""
        if self.interval <= 0:
            return
        with self._lock:
            now = time.monotonic()
            target = max(now, self._next_at)
            self._next_at = target + self.interval
        delay = target - now
        if delay > 0:
            runtime.cancel_event.wait(delay)

    def finish(self) -> float:
        """补足视频的最短处理时间，返回实际补等的秒数（0 表示已经够久）。"""
        if self.min_seconds <= 0:
            return 0.0
        delay = self.started_at + self.min_seconds - time.monotonic()
        if delay <= 0:
            return 0.0
        runtime.cancel_event.wait(delay)
        return delay
