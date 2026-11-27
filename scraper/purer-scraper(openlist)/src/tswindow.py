"""TS/M2TS 雪碧图快速路径：按码率估算字节位置，只读每帧附近的窗口本地抽帧。

MPEG-TS 没有索引，ffmpeg 对远程 TS 做 `-ss` 只能从头顺序读，49GB 的文件定位
到 95% 处基本不可能在超时内完成。这里改用：

1. 读 4KB 判断包长（188/192/204）；
2. 按「文件大小 × 时间占比」估算每个时间点的字节位置，向前后各取几秒的数据
   窗口（默认覆盖约 5 秒，8–32MB），窗口起点对齐到包边界；
3. 每个窗口单独在本地用 `-skip_frame nokey` 解出第一个关键帧。

TS 包自带同步头，扇区之间没有依赖，因此窗口可以独立解码。代价是位置是按码率
估算的，实际帧可能比目标时间点早几秒，对雪碧图没有影响。
任何一步失败（不是 TS、读不到数据窗口、窗口里没有关键帧）都会抛
:class:`TsWindowUnavailable`，由调用方退回原来的逐帧远程读取。
"""
from __future__ import annotations

import os
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

from . import runtime, upstream
from .constants import (
    EXTRACT_TIMEOUT,
    SPRITE_TS_ATTEMPTS,
    SPRITE_TS_DECODE_TIMEOUT,
    SPRITE_TS_WINDOW_MAX,
    SPRITE_TS_WINDOW_MIN,
    SPRITE_TS_WINDOW_SECONDS,
    SPRITE_TS_WORKERS,
)
from .errors import VideoError
from .ffmpeg import _run_capture
from .mp4window import read_range_retry
from .progress import TaskProgress
from .rate import RateLimiter
from .urls import sprite_positions
from .webdav import WebDav

_DETECT_BYTES = 4096
_MIN_JPEG_BYTES = 800


class TsWindowUnavailable(Exception):
    """这份文件无法走 TS 窗口快速路径（不是 TS、窗口太小或解不出关键帧）。"""


def _read_head(client: WebDav, url: str, size: int) -> bytes:
    length = min(_DETECT_BYTES, size)
    if length < 4096:
        raise TsWindowUnavailable("文件太小")
    with upstream.UPSTREAM_LIMIT:
        return read_range_retry(client, url, 0, length, timeout=20, budget=30)


def detect_packet_size(head: bytes) -> int | None:
    """根据同步头 0x47 判断 TS 包长：188（TS）、192（M2TS）、204（TS+FEC）。"""
    for packet in (188, 192, 204):
        base = 4 if packet == 192 else 0
        if len(head) < base + packet * 8:
            continue
        if head[base] != 0x47:
            continue
        ok = True
        for offset in range(base + packet, len(head) - packet, packet):
            if head[offset] != 0x47:
                ok = False
                break
        if ok:
            return packet
    return None


def prepare_ts_window(
    client: WebDav, url: str, size: int | None
) -> int | None:
    """判断是不是 TS 并返回包长；不是 TS 返回 None。只读 4KB。"""
    if not size or size <= 0:
        return None
    try:
        head = _read_head(client, url, size)
    except VideoError:
        raise
    return detect_packet_size(head)


def _window_range(
    file_size: int, duration: float, position: float, window: int, packet: int
) -> tuple[int, int]:
    """估算时间点对应的字节窗口，起点对齐到 TS 包边界。"""
    ratio = min(max(position / duration if duration > 0 else 0.0, 0.0), 0.999)
    offset = int(file_size * ratio)
    start = offset - window // 2
    if start + window > file_size:
        start = file_size - window
    start = max(0, start)
    start -= start % packet
    length = min(window, file_size - start)
    length -= length % packet
    return start, length


def _fetch_window(
    client: WebDav,
    url: str,
    start: int,
    length: int,
    folder: str,
    limiter: RateLimiter,
    packet: int,
) -> bytes:
    """读取一个数据窗口；同一文件的并发由调用方限制为 2 路。"""
    last_error: VideoError | None = None
    for attempt in range(SPRITE_TS_ATTEMPTS):
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消", phase="取窗口")
        limiter.wait(folder)
        try:
            with upstream.UPSTREAM_LIMIT:
                data = read_range_retry(
                    client,
                    url,
                    start,
                    length,
                    timeout=30,
                    budget=max(90.0, length / 1048576 * 30.0),
                    attempts=1,
                )
            if len(data) != length:
                raise VideoError("timeout", f"只读到 {len(data)}/{length} 字节", phase="取窗口")
            base = 4 if packet == 192 else 0
            if data[base] != 0x47:
                raise VideoError("timeout", "窗口起点没有对齐 TS 包", phase="取窗口")
            return data
        except VideoError as exc:
            last_error = exc
            if runtime.cancel_event.is_set():
                raise
            time.sleep(min(10.0, 2.0 * (attempt + 1)))
    raise VideoError(
        "timeout",
        f"读取 TS 数据窗口失败（{last_error}）",
        phase="取窗口",
        context={"url": url, "start": start, "length": length},
    )


def _decode_window(ffmpeg: str, path: str, width: int, timeout: float) -> bytes:
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-skip_frame",
        "nokey",
        "-f",
        "mpegts",
        "-i",
        path,
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-an",
        "-sn",
        "-vf",
        f"scale={width}:{width}:force_original_aspect_ratio=decrease,format=yuvj420p",
        "-q:v",
        "3",
        "-f",
        "mjpeg",
        "pipe:1",
    ]
    returncode, stdout, stderr = _run_capture(
        cmd,
        timeout,
        timeout_message="TS 本地抽帧超时",
        progress=False,
        stall_timeout=0.0,
        task=None,
    )
    if returncode != 0 or not stdout:
        detail = (stderr or b"").decode("utf-8", "replace").strip().splitlines()
        raise VideoError(
            "noframe",
            "TS 窗口里没有解出画面：" + ((detail[-1][:200] if detail else f"exit {returncode}")),
            phase="本地抽帧",
        )
    if not stdout.startswith(b"\xff\xd8") or len(stdout) < _MIN_JPEG_BYTES:
        raise VideoError("noframe", "TS 窗口没有返回有效 JPEG", phase="本地抽帧")
    return stdout


def extract_ts_frames(
    ffmpeg: str,
    client: WebDav,
    url: str,
    file_size: int,
    duration: float,
    count: int,
    cell_width: int,
    packet: int,
    folder: str,
    limiter: RateLimiter,
    extract_timeout: float = EXTRACT_TIMEOUT,
    task: TaskProgress | None = None,
) -> list[bytes]:
    """按字节窗口取 count 帧；失败抛 VideoError / TsWindowUnavailable。"""
    if duration <= 0:
        raise TsWindowUnavailable("时长为零")
    byte_rate = file_size / duration
    window = int(byte_rate * SPRITE_TS_WINDOW_SECONDS)
    window = max(SPRITE_TS_WINDOW_MIN, min(SPRITE_TS_WINDOW_MAX, window))
    window -= window % packet
    if window < packet * 16:
        raise TsWindowUnavailable("数据窗口太小")

    positions = sprite_positions(duration, count)
    if task is not None:
        task.set_phase("取窗口", steps=count)

    tmpdir = tempfile.mkdtemp(prefix="purer-ts-")
    timeout = min(extract_timeout, SPRITE_TS_DECODE_TIMEOUT) if extract_timeout > 0 else SPRITE_TS_DECODE_TIMEOUT

    def work(index: int) -> tuple[int, bytes]:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消", phase="取窗口")
        attempts: list[int] = [window]
        if window * 2 <= SPRITE_TS_WINDOW_MAX * 2:
            attempts.append(min(window * 2, file_size))
        last_error: Exception | None = None
        for size in attempts:
            start, length = _window_range(file_size, duration, positions[index], size, packet)
            if length < 65536:
                last_error = TsWindowUnavailable("窗口太小")
                continue
            path = os.path.join(tmpdir, f"w{index:03d}.ts")
            try:
                data = _fetch_window(client, url, start, length, folder, limiter, packet)
                with open(path, "wb") as handle:
                    handle.write(data)
                return index, _decode_window(ffmpeg, path, cell_width, timeout)
            except VideoError as exc:
                last_error = exc
                continue
            finally:
                try:
                    os.remove(path)
                except OSError:
                    pass
        raise VideoError(
            "noframe",
            f"第 {index + 1}/{count} 个 TS 窗口失败（{last_error}）",
            phase="取窗口",
            context={"url": url, "position": positions[index], "window": window},
        )

    frames: list[bytes | None] = [None] * count
    workers = max(1, min(SPRITE_TS_WORKERS, count))
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
        raise VideoError("noframe", "TS 窗口取帧结果不完整", phase="取窗口")
    return [frame for frame in frames if frame is not None]
