"""本地 Range 缓存代理：同一个视频的重复头部/尾部索引读取不再请求上游。

WMV / MKV / 部分 AVI 的远程抽帧里，每个 ffmpeg 进程都会重新读文件头、文件尾的
索引（WMV 的 Index Object、MKV 的 Cues 等）。一个视频 25 帧就是 25 次重复读取。
这里在 127.0.0.1 起一个很小的 HTTP 代理，ffmpeg 仍然按原来的 Range 请求访问，
代理把字节按 1MB 分块缓存：

- 头部 4MB、尾部 16MB 常驻，不参与淘汰（索引基本都在这些区域）；
- 中间的目标数据块按 LRU 淘汰，整个缓存上限约 96MB；
- 上游请求统一走全局 1 路并发 + 退避重试。

代理只服务当前视频，视频结束就关闭，不改变缓存文件格式。

上游失败时不能装作成功：先取到第一块再回响应头，取不到就回 502/403 等真实状态，
ffmpeg 会按「服务器错误」上报；已经回了一半数据才断开的，把上游错误记下来，由调用方
（雪碧图取帧）按真实原因分类，避免 115 WAF 拦截被伪装成「未知错误」而一直重试。
"""
from __future__ import annotations

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import upstream
from .errors import VideoError
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
        # 最近一次上游读取失败（供调用方判断 ffmpeg 为什么被中断）
        self._error: VideoError | None = None
        self._error_seq = 0
        last = (size - 1) // _CHUNK
        self._pinned = set(range(min(_PIN_HEAD_CHUNKS, last + 1))) | set(
            range(max(0, last - _PIN_TAIL_CHUNKS + 1), last + 1)
        )

    def record_error(self, exc: BaseException) -> None:
        with self._lock:
            self._error_seq += 1
            if isinstance(exc, VideoError):
                self._error = exc
            else:
                self._error = VideoError("unknown", f"本地缓存代理读取上游失败：{exc}")

    def error_version(self) -> int:
        with self._lock:
            return self._error_seq

    def error_since(self, version: int) -> VideoError | None:
        """version 之后有没有新的上游失败；没有就返回 None。"""
        with self._lock:
            return self._error if self._error_seq > version else None

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
            try:
                with upstream.UPSTREAM_LIMIT:
                    block = read_range_retry(
                        self.client, self.url, start, length,
                        timeout=30, budget=90, attempts=3,
                    )
                if len(block) != length:
                    raise VideoError(
                        "timeout",
                        f"上游只返回 {len(block)}/{length} 字节",
                        phase="本地缓存代理",
                    )
            except Exception as exc:  # noqa: BLE001 - 记录后原样抛出
                self.record_error(exc)
                raise
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

    def _send_upstream_error(self, exc: BaseException) -> None:
        """上游读不到数据时返回真实状态码，别让 ffmpeg 只看到空响应。

        以前一律先回 206 再取数据，上游被 115 WAF 拦截时 ffmpeg 只看到
        「Stream ends prematurely at 0」，被归成「未知错误」，既不计数也不会触发
        「连续 5xx 停止本轮」。这里按上游原因返回 5xx/403/404/429，让分类正确。
        """
        status = {"auth": 403, "notfound": 404, "ratelimited": 429}.get(
            str(getattr(exc, "reason", "")), 502
        )
        body = f"upstream read failed: {exc}".encode("utf-8", "replace")[:512]
        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except Exception:  # noqa: BLE001 - 客户端可能已经断开
            pass
        self.close_connection = True

    def do_GET(self) -> None:
        start, end = self._parse_range()
        remaining = end - start + 1
        first_index = start // _CHUNK
        try:
            # 先确认第一块真能读到，再声明 206；上游失败时 ffmpeg 拿到的是
            # 5xx/403 而不是「Content-Length 有值、字节数为 0」。
            first = self.cache.get_or_fetch(first_index)
        except Exception as exc:  # noqa: BLE001 - 上游失败按真实状态返回
            self._send_upstream_error(exc)
            return
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
                data = first if index == first_index else self.cache.get_or_fetch(index)
                piece = data[offset:offset + remaining]
                if not piece:
                    break
                self.wfile.write(piece)
                position += len(piece)
                remaining -= len(piece)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:  # noqa: BLE001 - 已经回了响应头，只能断开；
            # 上游失败原因在 get_or_fetch 里已经记录，这里不再覆盖成客户端错误
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

    # 取帧失败时用来判断「是不是上游整体不可用」：ffmpeg 只看到连接被断开，
    # 真实原因（HTTP 500/403 等）由这里带出去。
    def error_version(self) -> int:
        return self.cache.error_version()

    def error_since(self, version: int) -> VideoError | None:
        return self.cache.error_since(version)

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
