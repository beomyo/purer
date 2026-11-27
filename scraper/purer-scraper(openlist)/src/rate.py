"""限速（与 App 一致：按文件夹计算，两次抽帧开始之间至少 1/rate 秒）。"""
from __future__ import annotations

import threading
import time

from .constants import MIN_RATE
from .urls import _url_key

# ---------------------------------------------------------------------------
# 限速（与 App 一致：按文件夹计算，两次抽帧开始之间至少 1/rate 秒）
# ---------------------------------------------------------------------------


class RateLimiter:
    def __init__(self, rate: float) -> None:
        self.rate = rate if rate > 0 else MIN_RATE
        self.interval = 1.0 / self.rate
        self._lock = threading.Lock()
        self._next_at: dict[tuple[str, str, str], float] = {}

    def wait(self, folder: str) -> None:
        key = _url_key(folder)
        with self._lock:
            now = time.monotonic()
            start = max(now, self._next_at.get(key, now))
            self._next_at[key] = start + self.interval
        delay = start - now
        if delay > 0:
            time.sleep(delay)
