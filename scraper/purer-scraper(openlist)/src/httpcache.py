"""本地 Range 缓存代理：同一个视频的重复头部/尾部索引读取不再请求上游。

WMV / MKV / 部分 AVI 的远程抽帧里，每个 ffmpeg 进程都会重新读文件头、文件尾的
索引（WMV 的 Index Object、MKV 的 Cues 等）。一个视频 25 帧就是 25 次重复读取。
这里在 127.0.0.1 起一个很小的 HTTP 代理，ffmpeg 仍然按原来的 Range 请求访问，
代理把字节按 1MB 分块缓存：

- 头部 4MB、尾部 16MB 常驻，不参与淘汰（索引基本都在这些区域）；
- 中间的目标数据块按 LRU 淘汰，整个缓存上限约 96MB；
- 上游请求统一走全局 1 路并发 + 退避重试。

代理只服务当前视频，视频结束就关闭，不改变缓存文件格式。
"""
from __future__ import annotations

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import upstream
from .mp4window import read_range_retry
from .webdav import WebDav

_CHUNK = 1024 * 1024
_MAX_CHUNKS = 96
_PIN_HEAD_CHUNKS = 4
_PIN_TAIL_CHUNKS = 16
_FETCH_SPAN = 4  # 一次未命中时顺带读取 4 个块，减少请求次数


class _ChunkCache:
    def __init__(self, client: WebDav, url: str, size: int) -> None:
        self.client = client
        self.url = url
        self.size = size
        self._lock = threading.Lock()
        self._fetch_lock = threading.Lock()
        self._chunks: dict[int, bytes] = {}
        self._order: list[int] = []
        last = (size - 1) // _CHUNK
        self._pinned = set(range(min(_PIN_HEAD_CHUNKS, last + 1))) | set(
            range(max(0, last - _PIN_TAIL_CHUNKS + 1), last + 1)
        )

    def _touch(self, index: int) -> None:
        try:
            self._order.remove(index)
        except ValueError:
            pass
        self._order.append(index)

    def _store(self, index: int, data: bytes) -> None:
        self._chunks[index] = data
        self._touch(index)
        while len(self._chunks) > _MAX_CHUNKS:
            victim = next(
                (candidate for candidate in list(self._order) if candidate not in self._pinned),
                None,
            )
            if victim is None:
                break
            self._order.remove(victim)
            self._chunks.pop(victim, None)

    def get(self, index: int) -> bytes | None:
        with self._lock:
            data = self._chunks.get(index)
            if data is not None:
                self._touch(index)
            return data

    def get_or_fetch(self, index: int) -> bytes:
        data = self.get(index)
        if data is not None:
            return data
        with self._fetch_lock:
            data = self.get(index)
            if data is not None:
                return data
            start = index * _CHUNK
            end = min(self.size, start + _FETCH_SPAN * _CHUNK)
            length = end - start
            with upstream.UPSTREAM_LIMIT:
                block = read_range_retry(
                    self.client, self.url, start, length,
                    timeout=30, budget=90, attempts=3,
                )
            if len(block) != length:
                raise OSError(f"上游返回 {len(block)}/{length} 字节")
            with self._lock:
                for step in range(_FETCH_SPAN):
                    offset = step * _CHUNK
                    if offset >= len(block):
                        break
                    self._store(index + step, block[offset:offset + _CHUNK])
            data = block[:_CHUNK]
            return data


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args) -> None:  # noqa: D401 - 静默
        return None

    @property
    def cache(self) -> _ChunkCache:
        return self.server.cache  # type: ignore[attr-defined]

    def _parse_range(self) -> tuple[int, int]:
        size = self.cache.size
        header = self.headers.get("Range") or ""
        if not header.startswith("bytes="):
            return 0, size - 1
        spec = header[6:].split(",")[0]
        first, _, last = spec.partition("-")
        try:
            if first:
                start = int(first)
                end = int(last) if last else size - 1
            else:
                suffix = int(last or 0)
                start = max(0, size - suffix)
                end = size - 1
        except ValueError:
            start, end = 0, size - 1
        start = max(0, min(start, size - 1))
        end = max(start, min(end, size - 1))
        return start, end

    def do_HEAD(self) -> None:
        self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(self.cache.size))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()

    def do_GET(self) -> None:
        start, end = self._parse_range()
        remaining = end - start + 1
        self.send_response(206)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{self.cache.size}")
        self.send_header("Content-Length", str(remaining))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        position = start
        try:
            while remaining > 0:
                index = position // _CHUNK
                offset = position % _CHUNK
                data = self.cache.get_or_fetch(index)
                piece = data[offset:offset + remaining]
                if not piece:
                    break
                self.wfile.write(piece)
                position += len(piece)
                remaining -= len(piece)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:  # noqa: BLE001 - 代理失败就让 ffmpeg 自己报错
            pass


class CacheProxy:
    def __init__(self, client: WebDav, url: str, size: int) -> None:
        self.cache = _ChunkCache(client, url, size)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self.server.daemon_threads = True
        self.server.cache = self.cache  # type: ignore[attr-defined]
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/video"
        self._thread = threading.Thread(
            target=self.server.serve_forever, name="purer-http-cache", daemon=True
        )

    def start(self) -> "CacheProxy":
        self._thread.start()
        return self

    def close(self) -> None:
        try:
            self.server.shutdown()
        except Exception:
            pass
        try:
            self.server.server_close()
        except Exception:
            pass


def start_cache_proxy(client: WebDav, url: str, size: int) -> CacheProxy:
    return CacheProxy(client, url, size).start()
