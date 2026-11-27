"""远端卡死兜底：只读文件头和取帧位置附近的数据窗口，在本地拼文件抽帧。"""
from __future__ import annotations

import os
import shutil
import tempfile
import time
from urllib import request

from .constants import (
    EXTRACT_TIMEOUT,
    MIN_THUMBNAIL_BYTES,
    WINDOW_BYTES,
    WINDOW_HEAD_BYTES,
    USER_AGENT,
)
from .errors import VideoError
from .ffmpeg import extract_frame
from .progress import TaskProgress
from .urls import cache_bust
from .webdav import WebDav

# ---------------------------------------------------------------------------
# 远端卡死兜底：只取文件头和目标位置附近的数据窗口
# ---------------------------------------------------------------------------
#
# 少数大 MP4 交给 ffmpeg 远程打开时会退化成从头逐块读取（Range 请求一路往后
# 爬），等于要把整个文件读完。这时改用下面的方式：
#   1. 只读文件头（含 moov 索引）；
#   2. 用索引算出目标百分比对应关键帧的文件偏移；
#   3. 只读该位置附近的 48MB，拼成本地文件抽帧。
# 每个视频最多下载约 72MB，绝不下载整个文件。

MP4_CONTAINER_BOXES = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf", b"udta", b"mvex"}


def _mp4_int(buf: bytes, pos: int, size: int = 4) -> int:
    if pos < 0 or pos + size > len(buf):
        return 0
    return int.from_bytes(buf[pos:pos + size], "big")


def _mp4_boxes(buf: bytes, start: int, end: int):
    """遍历 [start, end) 内的完整 MP4 box，产出 (类型, 负载起点, 负载终点)。"""
    pos = start
    limit = min(end, len(buf))
    while pos + 8 <= limit:
        size = _mp4_int(buf, pos)
        kind = bytes(buf[pos + 4:pos + 8])
        header = 8
        if size == 1:
            if pos + 16 > limit:
                return
            size = _mp4_int(buf, pos + 8, 8)
            header = 16
        elif size == 0:
            size = limit - pos
        if size < header or pos + size > limit:
            return
        yield kind, pos + header, pos + size
        pos += size


def _mp4_find(buf: bytes, start: int, end: int, name: bytes):
    """在 box 内递归查找（只进入容器 box，避免把数据当成子 box）。"""
    for kind, payload, stop in _mp4_boxes(buf, start, end):
        if kind == name:
            return payload, stop
        if kind in MP4_CONTAINER_BOXES:
            found = _mp4_find(buf, payload, stop, name)
            if found is not None:
                return found
    return None


def _mp4_timescale_duration(buf: bytes, box) -> tuple[int, int]:
    """mvhd / mdhd 的 (timescale, duration ticks)。"""
    payload, _ = box
    version = buf[payload] if payload < len(buf) else 0
    if version == 1:
        return _mp4_int(buf, payload + 20), _mp4_int(buf, payload + 24, 8)
    return _mp4_int(buf, payload + 12), _mp4_int(buf, payload + 16)


def _mp4_video_track(buf: bytes, moov):
    for kind, payload, stop in _mp4_boxes(buf, *moov):
        if kind != b"trak":
            continue
        hdlr = _mp4_find(buf, payload, stop, b"hdlr")
        if hdlr is not None and bytes(buf[hdlr[0] + 8:hdlr[0] + 12]) == b"vide":
            return payload, stop
    return None


def _mp4_table(buf: bytes, stbl, name: bytes, width: int) -> list[tuple[int, ...]]:
    """读取 stts（8 字节/项）、stsc（12 字节/项）、stss（4 字节/项）这类表。"""
    found = _mp4_find(buf, *stbl, name)
    if found is None:
        return []
    payload, stop = found
    count = _mp4_int(buf, payload + 4)
    pos = payload + 8
    rows: list[tuple[int, ...]] = []
    for _ in range(min(count, 1_000_000)):
        if pos + width > stop:
            break
        rows.append(tuple(_mp4_int(buf, pos + j * 4) for j in range(width // 4)))
        pos += width
    return rows


def _mp4_chunk_offsets(buf: bytes, stbl) -> list[int]:
    for name in (b"stco", b"co64"):
        found = _mp4_find(buf, *stbl, name)
        if found is None:
            continue
        payload, stop = found
        count = _mp4_int(buf, payload + 4)
        step = 8 if name == b"co64" else 4
        pos = payload + 8
        offsets: list[int] = []
        for _ in range(min(count, 5_000_000)):
            if pos + step > stop:
                break
            offsets.append(_mp4_int(buf, pos, step))
            pos += step
        return offsets
    return []


def _mp4_sample_at(stts: list[tuple[int, ...]], ticks: int) -> int | None:
    """把时间（track timescale ticks）换算成 0 起的样本序号。"""
    if not stts:
        return None
    index = 0
    elapsed = 0
    for row in stts:
        count, delta = row[0], row[1] if len(row) > 1 else 0
        if delta <= 0:
            index += count
            continue
        span = count * delta
        if ticks < elapsed + span:
            return index + max(0, (ticks - elapsed) // delta)
        index += count
        elapsed += span
    return max(0, index - 1)


def _mp4_sample_time(stts: list[tuple[int, ...]], sample: int) -> int:
    elapsed = 0
    index = 0
    for row in stts:
        count, delta = row[0], row[1] if len(row) > 1 else 0
        if sample < index + count:
            return elapsed + (sample - index) * max(0, delta)
        index += count
        elapsed += count * max(0, delta)
    return elapsed


def _mp4_chunk_for_sample(stsc: list[tuple[int, ...]], offsets: list[int], sample: int) -> int | None:
    """样本序号 -> 0 起的 chunk 序号；没有 stsc 时返回 None。"""
    if not stsc or not offsets:
        return None
    chunk = 1
    consumed = 0
    for i, row in enumerate(stsc):
        first_chunk = row[0]
        per_chunk = max(1, row[1] if len(row) > 1 else 1)
        next_chunk = stsc[i + 1][0] if i + 1 < len(stsc) else len(offsets) + 1
        if chunk < first_chunk:
            chunk = first_chunk
        while chunk < next_chunk and chunk <= len(offsets):
            if sample < consumed + per_chunk:
                return chunk - 1
            consumed += per_chunk
            chunk += 1
    return min(len(offsets) - 1, max(0, chunk - 2))


def _mp4_window_plan(head: bytes, moov, percent: float) -> dict | None:
    """算出入点：总时长、目标关键帧的文件偏移、该关键帧的时间（秒）。"""
    mvhd = _mp4_find(head, *moov, b"mvhd")
    if mvhd is None:
        return None
    movie_scale, movie_duration = _mp4_timescale_duration(head, mvhd)
    if movie_scale <= 0 or movie_duration <= 0:
        return None
    duration = movie_duration / movie_scale

    trak = _mp4_video_track(head, moov)
    if trak is None:
        return None
    mdhd = _mp4_find(head, *trak, b"mdhd")
    stbl = _mp4_find(head, *trak, b"stbl")
    if mdhd is None or stbl is None:
        return None
    track_scale, track_duration = _mp4_timescale_duration(head, mdhd)
    offsets = _mp4_chunk_offsets(head, stbl)
    if track_scale <= 0 or not offsets:
        return None

    stts = _mp4_table(head, stbl, b"stts", 8)
    stsc = _mp4_table(head, stbl, b"stsc", 12)
    syncs = _mp4_table(head, stbl, b"stss", 4)

    chunk = None
    key_time = None
    sample = _mp4_sample_at(stts, int(track_duration * percent / 100.0)) if stts else None
    if sample is not None:
        if syncs:
            # 找不大于目标样本的最后一个关键帧（stss 是 1 起的序号）
            key = 0
            for row in syncs:
                if row[0] - 1 <= sample:
                    key = row[0] - 1
                else:
                    break
            sample = key
        candidate = _mp4_chunk_for_sample(stsc, offsets, sample)
        if candidate is not None and 0 <= candidate < len(offsets):
            chunk = candidate
            key_time = _mp4_sample_time(stts, sample) / track_scale
    if chunk is None:
        # 索引表不完整时按块数比例估算，仍然只读一个窗口
        chunk = min(len(offsets) - 1, max(0, int(len(offsets) * percent / 100.0)))
        key_time = duration * percent / 100.0
    return {"duration": duration, "start": offsets[chunk], "time": key_time}


def _mark_sparse(file_obj) -> None:
    """Windows 上把临时文件标记为稀疏，避免为文件中间的洞真正占用磁盘。"""
    if os.name != "nt":
        return
    try:
        import ctypes
        import ctypes.wintypes
        import msvcrt

        fsctl_set_sparse = 0x000900C4
        handle = msvcrt.get_osfhandle(file_obj.fileno())
        returned = ctypes.wintypes.DWORD()
        ctypes.windll.kernel32.DeviceIoControl(
            ctypes.c_void_p(handle), fsctl_set_sparse, None, 0, None, 0, ctypes.byref(returned), None
        )
    except Exception:
        pass


def _read_range(
    client: WebDav,
    url: str,
    start: int,
    length: int,
    timeout: float,
    budget: float,
) -> bytes:
    """读取一段字节：有总时限，并要求服务器真的按 Range 返回。

    不用 WebDav.get_range，是因为这里的数据窗口较大（几十 MB），
    万一服务器一点点吐数据，需要能在总时限到点时打断。
    """
    req = request.Request(cache_bust(url), method="GET")
    req.add_header("User-Agent", USER_AGENT)
    if client.auth_header:
        req.add_header("Authorization", client.auth_header)
    req.add_header("Range", f"bytes={start}-{start + length - 1}")
    deadline = time.monotonic() + budget
    data = bytearray()
    try:
        with client.opener.open(req, timeout=timeout) as response:
            status = getattr(response, "status", None) or response.getcode()
            content_range = response.headers.get("Content-Range") or ""
            if status != 206 or not content_range.startswith(f"bytes {start}-"):
                raise VideoError("timeout", "服务器没有按 Range 返回（不支持局部读取）")
            while len(data) < length:
                if time.monotonic() > deadline:
                    raise VideoError("timeout", f"读取 {length // 1048576}MB 数据超过 {budget:g}s")
                chunk = response.read(min(262144, length - len(data)))
                if not chunk:
                    break
                data += chunk
    except VideoError:
        raise
    except Exception as exc:  # noqa: BLE001 - 兜底失败统一按超时上报，保留原始失败原因
        raise VideoError("timeout", f"读取数据失败：{exc}") from exc
    return bytes(data)


def extract_frame_window(
    ffmpeg: str,
    client: WebDav,
    url: str,
    percent: float,
    width: int,
    timeout: float = EXTRACT_TIMEOUT,
    label: str | None = None,
    task: TaskProgress | None = None,
) -> tuple[bytes, float | None]:
    """远端抽帧卡死时的兜底：只读文件头和目标附近的数据窗口，本地抽帧。

    返回 (JPEG, 视频时长)；解析不了 MP4 索引时抛 VideoError，由调用方保留原错误。
    """
    info = {"url": url, "percent": percent, "stage": "局部窗口"}
    if task is not None:
        task.set_phase("局部窗口")
        task.begin("读取文件头与索引")
    head = _read_range(client, url, 0, WINDOW_HEAD_BYTES, timeout=30, budget=90)
    info["head_bytes"] = len(head)
    if not head:
        raise VideoError("timeout", "局部窗口兜底失败：读不到文件头", phase="局部窗口", context=info)
    moov = None
    for kind, payload, stop in _mp4_boxes(head, 0, len(head)):
        if kind == b"moov":
            moov = (payload, stop)
            break
    if moov is None:
        raise VideoError(
            "timeout", "局部窗口兜底失败：文件头里没有 MP4 索引（moov）",
            phase="局部窗口", context=info,
        )
    plan = _mp4_window_plan(head, moov, percent)
    if plan is None:
        raise VideoError(
            "timeout", "局部窗口兜底失败：无法解析 MP4 索引",
            phase="局部窗口", context=info,
        )
    info.update(
        {"window_start": plan["start"], "window_time": plan["time"], "duration": plan["duration"]}
    )
    if task is not None:
        task.begin(f"读取 {WINDOW_BYTES // 1048576}MB 数据窗口 @ {plan['start']}")

    window = _read_range(client, url, plan["start"], WINDOW_BYTES, timeout=30, budget=180)
    info["window_bytes"] = len(window)
    if len(window) < 65536:
        raise VideoError(
            "timeout", "局部窗口兜底失败：读不到目标位置的数据",
            phase="局部窗口", context=info,
        )

    tmpdir = tempfile.mkdtemp(prefix="purer-window-")
    local = os.path.join(tmpdir, "video.mp4")
    try:
        end = plan["start"] + len(window)
        with open(local, "wb") as fh:
            _mark_sparse(fh)
            fh.truncate(end)
            fh.seek(0)
            fh.write(head)
            fh.seek(plan["start"])
            fh.write(window)

        tried: list[float] = []
        last_error: VideoError | None = None
        for offset in (0.2, 0.0, 5.0, 10.0, 20.0, -5.0):
            position = max(0.0, plan["time"] + offset)
            if any(abs(position - value) < 0.1 for value in tried):
                continue
            tried.append(position)
            try:
                jpeg = extract_frame(
                    ffmpeg, local, position, width, None, False,
                    timeout=timeout, label=label, task=task,
                )
            except VideoError as exc:
                last_error = exc
                continue
            if len(jpeg) >= MIN_THUMBNAIL_BYTES:
                return jpeg, plan["duration"]
        detail = f"局部窗口兜底失败：{last_error}" if last_error else "局部窗口兜底失败：没有取到画面"
        if last_error is not None:
            info["last_error"] = {
                "reason": last_error.reason,
                "message": str(last_error),
                "context": last_error.context,
            }
        raise VideoError("timeout", detail, phase="局部窗口", context=info)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
