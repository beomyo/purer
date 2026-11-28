"""AVI 雪碧图快速路径：DV 编码按定长帧直接读取；不支持的编码快速失败。

AVI（尤其 OpenDML 大文件）对远程 `-ss` 很不友好：ffmpeg 需要读索引/扫 movi，
29–64GB 的文件在 828 秒处经常直接卡死。这里针对实际遇到的两种编码：

- **DV（dvsd/dv25/dv50…）**：视频帧是固定长度（NTSC 120000 字节、PAL 144000 字节），
  按「文件大小 × 时间占比」估算位置，只读约 1MB 窗口，找到 `00db` 块后直接把
  一帧 DV 数据交给 ffmpeg 本地解码。25 帧通常只有几十 MB 流量。
- **CUVC 等 ffmpeg 没有解码器的编码**：直接抛 :class:`AviCodecUnsupported`，
  由调用方快速失败，不再让 ffmpeg 去远程读 75 秒后卡死。

其他 AVI 编码返回 :class:`AviWindowUnavailable`，继续走原来的远程路径。
"""
from __future__ import annotations

import os
import shutil
import struct
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

from . import runtime, upstream
from .constants import (
    DEFAULT_UNSUPPORTED_CODECS,
    EXTRACT_TIMEOUT,
    SPRITE_AVI_DECODE_TIMEOUT,
    SPRITE_AVI_MAX_CHUNK,
    SPRITE_AVI_MIN_CHUNK,
    SPRITE_AVI_WINDOW_BYTES,
    SPRITE_AVI_WORKERS,
)
from .errors import VideoError, is_upstream_block
from .ffmpeg import _run_capture
from .mp4window import read_range_retry
from .pacing import SpritePacer
from .progress import TaskProgress
from .rate import RateLimiter
from .urls import sprite_positions
from .webdav import WebDav

# ffmpeg 能解码的 DV 变体（视频轨 handler / strf compression）
_DV_HANDLERS = {
    b"dvsd", b"dv25", b"dv50", b"dvh1", b"dvhe", b"dvc ", b"dvcp", b"dvpp",
}
# 默认跳过名单由 constants.DEFAULT_UNSUPPORTED_CODECS 提供，可写进配置
_MIN_JPEG_BYTES = 800


class AviWindowUnavailable(Exception):
    """这份 AVI 无法走 DV 快速路径（不是 AVI、不是 DV 或窗口里没找到帧）。"""


class AviCodecUnsupported(Exception):
    """AVI 使用了 ffmpeg 无法解码的编码。"""

    def __init__(self, codec: str) -> None:
        super().__init__(f"AVI 编码 {codec} 不受 ffmpeg 支持")
        self.codec = codec


@dataclass
class AviInfo:
    handler: bytes
    is_dv: bool
    movi_start: int
    chunk_id: bytes
    width: int
    height: int


def _iter_chunks(buf: bytes, start: int, stop: int):
    pos = start
    limit = min(stop, len(buf))
    while pos + 8 <= limit:
        chunk_id = buf[pos:pos + 4]
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        payload = pos + 8
        end = payload + size
        if end > len(buf):
            return
        yield chunk_id, payload, end
        pos = end + (size & 1)


def _video_stream(buf: bytes) -> tuple[bytes, bytes, int, int] | None:
    """返回 (handler, compression, width, height)；只找第一个 vids 流。"""
    for chunk_id, payload, end in _iter_chunks(buf, 12, len(buf)):
        if chunk_id != b"LIST" or buf[payload:payload + 4] != b"hdrl":
            continue
        for sub_id, sub_payload, sub_end in _iter_chunks(buf, payload + 4, end):
            if sub_id != b"LIST" or buf[sub_payload:sub_payload + 4] != b"strl":
                continue
            handler = b""
            compression = b""
            width = height = 0
            is_video = False
            for item_id, item_payload, item_end in _iter_chunks(buf, sub_payload + 4, sub_end):
                if item_id == b"strh" and item_end - item_payload >= 8:
                    is_video = buf[item_payload:item_payload + 4] == b"vids"
                    handler = buf[item_payload + 4:item_payload + 8]
                elif item_id == b"strf" and item_end - item_payload >= 20:
                    width, height = struct.unpack_from("<ii", buf, item_payload + 4)
                    compression = buf[item_payload + 16:item_payload + 20]
            if is_video:
                return handler, compression, width, height
    return None


def _movi_start(buf: bytes) -> int:
    """找第一个 movi LIST 的起始偏移；movi 可能有 1GB，不能要求它放进头部缓冲区。"""
    pos = 12
    while pos + 12 <= len(buf):
        chunk_id = buf[pos:pos + 4]
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        if size < 8:
            return -1
        if chunk_id == b"LIST" and buf[pos + 8:pos + 12] == b"movi":
            return pos + 12
        if pos + 8 + size > len(buf):
            return -1
        pos += 8 + size + (size & 1)
    return -1


def _chunk_id(buf: bytes) -> bytes:
    """从视频 strl 的 indx 里读 dwChunkId（通常是 00db），读不到就用 00db。"""
    for chunk_id, payload, end in _iter_chunks(buf, 12, len(buf)):
        if chunk_id != b"LIST" or buf[payload:payload + 4] != b"hdrl":
            continue
        for sub_id, sub_payload, sub_end in _iter_chunks(buf, payload + 4, end):
            if sub_id != b"LIST" or buf[sub_payload:sub_payload + 4] != b"strl":
                continue
            is_video = False
            candidate = b""
            for item_id, item_payload, item_end in _iter_chunks(buf, sub_payload + 4, sub_end):
                if item_id == b"strh":
                    is_video = buf[item_payload:item_payload + 4] == b"vids"
                elif item_id == b"indx" and item_end - item_payload >= 12 and is_video:
                    candidate = buf[item_payload + 8:item_payload + 12]
            if is_video:
                return candidate if candidate[:2].isdigit() else b"00db"
    return b"00db"


def prepare_avi_info(
    client: WebDav,
    url: str,
    size: int | None,
    unsupported_codecs: set[str] | frozenset[str] | None = None,
) -> AviInfo:
    """读 AVI 头部判断编码；不是 AVI / 不是 DV 抛 AviWindowUnavailable。"""
    if not size or size <= 0:
        raise AviWindowUnavailable("没有文件大小")
    with upstream.UPSTREAM_LIMIT:
        head = read_range_retry(client, url, 0, min(256 * 1024, size), timeout=20, budget=60)
    if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"AVI ":
        raise AviWindowUnavailable("不是 AVI")
    stream = _video_stream(head)
    if stream is None:
        raise AviWindowUnavailable("没有视频轨")
    handler, compression, width, height = stream
    codec = (handler or compression).decode("ascii", "replace").strip().upper()
    skipped = (
        set(unsupported_codecs)
        if unsupported_codecs is not None
        else set(DEFAULT_UNSUPPORTED_CODECS)
    )
    if codec and codec in {item.upper() for item in skipped}:
        raise AviCodecUnsupported(codec)
    if handler not in _DV_HANDLERS and compression not in _DV_HANDLERS:
        raise AviWindowUnavailable(f"AVI 编码 {codec or '未知'} 不在 DV 快速路径内")
    movi = _movi_start(head)
    if movi <= 0:
        raise AviWindowUnavailable("找不到 movi 数据区")
    return AviInfo(
        handler=handler or compression,
        is_dv=True,
        movi_start=movi,
        chunk_id=_chunk_id(head),
        width=width,
        height=height,
    )


def _decode_dv(ffmpeg: str, path: str, width: int, timeout: float) -> bytes:
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "dv", "-i", path,
        "-map", "0:v:0", "-frames:v", "1", "-an", "-sn",
        "-vf", f"scale={width}:{width}:force_original_aspect_ratio=decrease,format=yuvj420p",
        "-q:v", "3", "-f", "mjpeg", "pipe:1",
    ]
    returncode, stdout, stderr = _run_capture(
        cmd, timeout, timeout_message="DV 本地解码超时",
        progress=False, stall_timeout=0.0, task=None,
    )
    if returncode != 0 or not stdout:
        detail = (stderr or b"").decode("utf-8", "replace").strip().splitlines()
        raise VideoError(
            "noframe",
            "DV 帧解码失败：" + ((detail[-1][:200] if detail else f"exit {returncode}")),
            phase="本地解码",
        )
    if not stdout.startswith(b"\xff\xd8") or len(stdout) < _MIN_JPEG_BYTES:
        raise VideoError("noframe", "DV 解码没有返回有效 JPEG", phase="本地解码")
    return stdout


def _find_dv_frame(
    window: bytes, start: int, target: int, chunk_id: bytes
) -> tuple[int, bytes] | None:
    best: tuple[int, int, bytes] | None = None
    pos = 0
    while True:
        pos = window.find(chunk_id, pos)
        if pos < 0:
            break
        if pos + 8 <= len(window):
            size = struct.unpack_from("<I", window, pos + 4)[0]
            if (
                SPRITE_AVI_MIN_CHUNK <= size <= SPRITE_AVI_MAX_CHUNK
                and pos + 8 + size <= len(window)
            ):
                absolute = start + pos
                distance = abs(absolute - target)
                if best is None or distance < best[0]:
                    best = (distance, absolute, window[pos + 8:pos + 8 + size])
        pos += 4
    if best is None:
        return None
    return best[1], best[2]


def extract_dv_frames(
    ffmpeg: str,
    client: WebDav,
    url: str,
    file_size: int,
    duration: float,
    count: int,
    cell_width: int,
    info: AviInfo,
    folder: str,
    limiter: RateLimiter,
    extract_timeout: float = EXTRACT_TIMEOUT,
    serial: bool = False,
    task: TaskProgress | None = None,
    pacer: SpritePacer | None = None,
) -> list[bytes]:
    """按字节窗口从 DV AVI 取 count 帧；serial=True 时只用一个工作线程。

    pacer 用来把各窗口的读取均匀铺开（见 pacing.py）。
    """
    if duration <= 0:
        raise AviWindowUnavailable("时长为零")
    positions = sprite_positions(duration, count)
    span = max(1, file_size - info.movi_start)
    window_bytes = SPRITE_AVI_WINDOW_BYTES
    timeout = min(extract_timeout, SPRITE_AVI_DECODE_TIMEOUT) if extract_timeout > 0 else SPRITE_AVI_DECODE_TIMEOUT
    tmpdir = tempfile.mkdtemp(prefix="purer-dv-")
    if task is not None:
        task.set_phase("取 DV 帧", steps=count)

    def work(index: int) -> tuple[int, bytes]:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消", phase="取 DV 帧")
        if pacer is not None:
            pacer.wait_for(index)
        target = info.movi_start + int(span * positions[index] / duration)
        last_error: Exception | None = None
        for attempt, size in enumerate((window_bytes, window_bytes * 2)):
            start = max(info.movi_start, target - size // 2)
            start -= start % 2
            if start + size > file_size:
                start = max(info.movi_start, file_size - size)
            if runtime.cancel_event.is_set():
                raise VideoError("timeout", "已取消", phase="取 DV 帧")
            limiter.wait(folder)
            try:
                with upstream.UPSTREAM_LIMIT:
                    data = read_range_retry(
                        client, url, start, size, timeout=25,
                        budget=max(60.0, size / 1048576 * 20.0), attempts=2,
                    )
            except VideoError as exc:
                last_error = exc
                continue
            found = _find_dv_frame(data, start, target, info.chunk_id)
            if found is None:
                last_error = AviWindowUnavailable("窗口里没有完整的 DV 帧")
                continue
            path = os.path.join(tmpdir, f"f{index:03d}.dv")
            try:
                with open(path, "wb") as handle:
                    handle.write(found[1])
                return index, _decode_dv(ffmpeg, path, cell_width, timeout)
            except VideoError as exc:
                last_error = exc
                continue
            finally:
                try:
                    os.remove(path)
                except OSError:
                    pass
        if isinstance(last_error, VideoError) and is_upstream_block(last_error):
            # 上游整体不可用：不要包装成 noframe（会重置连续 5xx 计数）
            raise last_error
        raise VideoError(
            "noframe",
            f"第 {index + 1}/{count} 个 DV 窗口失败（{last_error}）",
            phase="取 DV 帧",
            context={"url": url, "position": positions[index]},
        )

    frames: list[bytes | None] = [None] * count
    workers = 1 if serial else max(1, min(SPRITE_AVI_WORKERS, count))
    try:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [executor.submit(work, index) for index in range(count)]
            done = 0
            for future in as_completed(futures):
                index, jpeg = future.result()
                frames[index] = jpeg
                done += 1
                if task is not None:
                    task.advance(done, count)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    if any(frame is None for frame in frames):
        raise VideoError("noframe", "DV 取帧结果不完整", phase="取 DV 帧")
    return [frame for frame in frames if frame is not None]
