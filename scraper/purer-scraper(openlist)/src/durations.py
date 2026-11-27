"""视频时长缓存：按 (URL, 文件大小) 记住 ffprobe 结果，重跑时省掉一次读时长。

读一次时长对远程大文件来说并不便宜（要读文件头/尾的索引，常见 5–10 秒），
而同一个文件的大小不会变、时长也不会变。缓存写到项目根目录的
``duration_cache.json``，文件被替换（大小变化）时自动失效。
"""
from __future__ import annotations

import atexit
import json
import os
import threading

from .paths import PROJECT_ROOT
from .urls import _url_key

CACHE_FILE = PROJECT_ROOT / "duration_cache.json"
MAX_ENTRIES = 20000
SAVE_EVERY = 200

_lock = threading.Lock()
_data: dict[str, float] | None = None
_puts_since_save = 0


def _key(url: str, size: int | None) -> str | None:
    if not url or size is None or size <= 0:
        return None
    scheme, netloc, path = _url_key(url)
    return f"{scheme}://{netloc}{path}|{int(size)}"


def _ensure_loaded_locked() -> dict[str, float]:
    global _data
    if _data is not None:
        return _data
    raw: object = {}
    try:
        with open(CACHE_FILE, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError):
        raw = {}
    data: dict[str, float] = {}
    if isinstance(raw, dict):
        for key, value in raw.items():
            try:
                number = float(value)
            except (TypeError, ValueError):
                continue
            if number > 0:
                data[str(key)] = number
    _data = data
    return data


def get(url: str, size: int | None) -> float | None:
    """取缓存的时长（秒）；没有缓存返回 None。"""
    key = _key(url, size)
    if key is None:
        return None
    with _lock:
        return _ensure_loaded_locked().get(key)


def put(url: str, size: int | None, duration: float | None) -> None:
    """记录一个视频的时长；定期落盘，避免每个视频都重写整份 JSON。"""
    global _puts_since_save
    if not duration or duration <= 0:
        return
    key = _key(url, size)
    if key is None:
        return
    with _lock:
        data = _ensure_loaded_locked()
        if data.get(key) == float(duration):
            return
        data[key] = float(duration)
        while len(data) > MAX_ENTRIES:
            data.pop(next(iter(data)))
        _puts_since_save += 1
        if _puts_since_save >= SAVE_EVERY:
            _save_locked()


def flush() -> None:
    """把缓存写回磁盘（进程退出时也会调用）。"""
    if not _lock.acquire(timeout=5):
        return
    try:
        _ensure_loaded_locked()
        _save_locked()
    finally:
        _lock.release()


def _save_locked() -> None:
    global _puts_since_save
    if _data is None:
        return
    _puts_since_save = 0
    tmp = CACHE_FILE.with_name(CACHE_FILE.name + ".tmp")
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(_data, handle, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, CACHE_FILE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


atexit.register(flush)
