"""雪碧图快速路径：解析一次 MP4 索引，只取每帧需要的字节，本地抽帧。

115 上的大 MP4 基本是 mdat 在前、moov（索引）在尾部。原来的做法是每帧启动一个
ffmpeg 远程取帧，每次都要重新读一遍几 MB 的 moov：25 帧就是几百 MB 的重复下载，
单帧耗时几乎全花在这上面。这里改成：

1. 只读一次尾部（或头部）的 moov，顺带读出时长，省掉单独的 ffprobe；
2. 用 stss/stts/stsc/stco/stsz 算出每个时间点「前一个关键帧 → 目标帧」的
   精确字节范围（25 帧通常只有几十 MB）；
3. 把这些范围拼成一个稀疏本地文件，让 ffmpeg 在本地抽帧。

任何一步遇到不支持的格式或索引不完整，都抛 :class:`SpriteIndexUnavailable`，
由调用方退回原来的远程抽帧路径，行为保持不变。
"""
from __future__ import annotations

import bisect
import os
import shutil
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

from . import runtime
from .constants import (
    EXTRACT_TIMEOUT,
    SPRITE_INDEX_ATTEMPTS,
    SPRITE_INDEX_FRAME_WORKERS,
    SPRITE_INDEX_HEAD_BYTES,
    SPRITE_INDEX_MAX_MOOV,
    SPRITE_INDEX_MAX_RANGE,
    SPRITE_INDEX_MARGIN,
    SPRITE_INDEX_MAX_SKIP,
    SPRITE_INDEX_MAX_TOTAL,
    SPRITE_INDEX_TAIL_BYTES,
    SPRITE_INDEX_WORKERS,
)
from .errors import VideoError
from .ffmpeg import extract_frame
from . import upstream
from .mp4window import (
    _mark_sparse,
    read_range_retry,
    _mp4_chunk_offsets,
    _mp4_find,
    _mp4_sample_at,
    _mp4_table,
    _mp4_timescale_duration,
    _mp4_video_track,
    _read_range,
)
from .progress import TaskProgress
from .rate import RateLimiter
from .urls import sprite_positions
from .webdav import WebDav

# 顶层 box 类型：用来判断文件是不是 MP4，以及定位 moov
_MP4_TOP_LEVEL = {b"ftyp", b"moov", b"free", b"skip", b"wide", b"mdat", b"styp", b"sidx"}
# moov 之后允许存在的尾部残留（free/udta 之类的少量字节）
_TAIL_SLACK = 64 * 1024


class SpriteIndexUnavailable(Exception):
    """这份文件无法走索引快速路径（格式不支持、索引不完整或数据段过大）。"""


@dataclass
class _SampleTables:
    """从 moov 里解析出来的视频轨样本表。"""

    duration: float          # 视频总时长（秒，mvhd）
    track_duration: float    # 视频轨时长（track timescale ticks）
    sample_sizes: list[int]
    chunk_offsets: list[int]
    chunk_starts: list[tuple[int, int]]  # (该 chunk 的第一个样本序号, chunk 序号)
    first_samples: list[int]
    stts: list[tuple[int, ...]]
    syncs: list[int]         # 关键帧样本序号（0 起）；为空表示所有样本都是关键帧


@dataclass
class SpriteIndex:
    """一份视频的 MP4 索引，可反复用来计算各时间点的数据范围。"""

    duration: float
    file_size: int
    buffer: bytes            # moov 所在的文件头/尾缓冲区
    buffer_offset: int       # 该缓冲区在文件中的起始偏移
    sample_tables: _SampleTables
    head: bytes | None = None  # 文件头（moov 在尾部时，本地文件仍需 ftyp/mdat 头）

    # ---- 计算与取帧 ----

    def byte_ranges(self, positions: list[float]) -> list[tuple[int, int]]:
        """把每个时间点换算成 (文件偏移, 字节数)：从前一个关键帧到目标帧之后一点。"""
        tables = self.sample_tables
        ranges: list[tuple[int, int]] = []
        margin_ticks = int(
            SPRITE_INDEX_MARGIN * tables.track_duration / self.duration
        ) if self.duration > 0 else 0
        for position in positions:
            if self.duration <= 0:
                raise SpriteIndexUnavailable("时长为零")
            tick = int(max(0.0, position) / self.duration * tables.track_duration)
            sample = _mp4_sample_at(tables.stts, tick)
            if sample is None:
                raise SpriteIndexUnavailable("样本时间表为空")
            sample = min(max(0, sample), len(tables.sample_sizes) - 1)
            # ffmpeg 的 -ss 取的是目标时间点之后的第一帧，且 B 帧会重排，
            # 因此数据段要多取一点，否则目标帧的字节可能不在窗口里。
            end_sample = _mp4_sample_at(tables.stts, tick + margin_ticks)
            if end_sample is None:
                end_sample = sample
            end_sample = min(max(sample, end_sample), len(tables.sample_sizes) - 1)
            key = sample
            if tables.syncs:
                index = bisect.bisect_right(tables.syncs, sample) - 1
                if index < 0:
                    raise SpriteIndexUnavailable("目标时间点在首个关键帧之前")
                key = tables.syncs[index]
            start = self._sample_offset(key)
            end = self._sample_offset(end_sample) + tables.sample_sizes[end_sample]
            if end <= start or end > self.file_size:
                raise SpriteIndexUnavailable("样本偏移超出文件大小")
            ranges.append((start, end - start))
        return ranges

    def _sample_offset(self, sample: int) -> int:
        tables = self.sample_tables
        if sample < 0 or sample >= len(tables.sample_sizes):
            raise SpriteIndexUnavailable("样本序号超出范围")
        index = bisect.bisect_right(tables.first_samples, sample) - 1
        if index < 0:
            raise SpriteIndexUnavailable("样本不在任何数据块中")
        first, chunk = tables.chunk_starts[index]
        if chunk >= len(tables.chunk_offsets) or first > sample:
            raise SpriteIndexUnavailable("数据块表不完整")
        return tables.chunk_offsets[chunk] + sum(tables.sample_sizes[first:sample])

    def frames(
        self,
        ffmpeg: str,
        client: WebDav,
        url: str,
        count: int,
        cell_width: int,
        folder: str,
        limiter: RateLimiter,
        extract_timeout: float = EXTRACT_TIMEOUT,
        serial: bool = False,
        task: TaskProgress | None = None,
    ) -> list[bytes]:
        """按索引取回 count 帧（按时间顺序），失败抛 VideoError / SpriteIndexUnavailable。

        serial=True 时本地解码只用 1 个工作线程（大文件避免 CPU 打满）。
        """
        positions = sprite_positions(self.duration, count)
        ranges = self.byte_ranges(positions)
        total_bytes = sum(length for _, length in ranges)
        if total_bytes > SPRITE_INDEX_MAX_TOTAL:
            raise SpriteIndexUnavailable(
                f"需要读取 {total_bytes // 1048576}MB，超过一次快速路径的上限"
            )
        for _, length in ranges:
            if length <= 0 or length > SPRITE_INDEX_MAX_RANGE:
                raise SpriteIndexUnavailable(
                    f"单帧需要读取 {length // 1024}KB，超出快速路径范围"
                )

        if task is not None:
            task.set_phase("取数据段", steps=len(ranges))
        chunks = self._fetch_ranges(client, url, ranges, folder, limiter, task)

        tmpdir = tempfile.mkdtemp(prefix="purer-sprite-index-")
        try:
            local = self._build_sparse_file(tmpdir, ranges, chunks)
            if task is not None:
                task.set_phase("本地抽帧", steps=len(positions))
            return _extract_local(
                ffmpeg, local, positions, cell_width, extract_timeout, task, serial
            )
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def _fetch_ranges(
        self,
        client: WebDav,
        url: str,
        ranges: list[tuple[int, int]],
        folder: str,
        limiter: RateLimiter,
        task: TaskProgress | None,
    ) -> list[bytes]:
        """并发读取各数据段；同一文件的并发保持较低，避免服务器 403。"""

        def fetch(index: int) -> tuple[int, bytes]:
            start, length = ranges[index]
            last_error: VideoError | None = None
            for attempt in range(SPRITE_INDEX_ATTEMPTS):
                if runtime.cancel_event.is_set():
                    raise VideoError("timeout", "已取消", phase="取数据段")
                limiter.wait(folder)
                try:
                    with upstream.UPSTREAM_LIMIT:
                        data = _read_range(
                            client,
                            url,
                            start,
                            length,
                            timeout=30,
                            budget=max(90.0, length / 1048576 * 30.0),
                        )
                    if len(data) != length:
                        raise VideoError(
                            "timeout",
                            f"只读到 {len(data)}/{length} 字节",
                            phase="取数据段",
                        )
                    return index, data
                except VideoError as exc:
                    last_error = exc
                    if runtime.cancel_event.is_set():
                        raise
                    time.sleep(min(10.0, 2.0 * (attempt + 1)))
            raise VideoError(
                "timeout",
                f"第 {index + 1}/{len(ranges)} 段数据读取失败（{last_error}）",
                phase="取数据段",
                context={"url": url, "start": start, "length": length},
            )

        results: list[bytes | None] = [None] * len(ranges)
        workers = max(1, min(SPRITE_INDEX_WORKERS, len(ranges)))
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [executor.submit(fetch, index) for index in range(len(ranges))]
            done = 0
            for future in as_completed(futures):
                index, data = future.result()
                results[index] = data
                done += 1
                if task is not None:
                    task.advance(done, len(ranges))
        if any(item is None for item in results):
            raise VideoError("timeout", "数据段读取结果不完整", phase="取数据段")
        return [item for item in results if item is not None]

    def _build_sparse_file(
        self,
        tmpdir: str,
        ranges: list[tuple[int, int]],
        chunks: list[bytes],
    ) -> str:
        """把 moov 缓冲区与各数据段写进一个稀疏文件，让 ffmpeg 本地抽帧。"""
        local = os.path.join(tmpdir, "video.mp4")
        with open(local, "wb") as handle:
            _mark_sparse(handle)
            handle.truncate(self.file_size)
            if self.head is not None and self.buffer_offset != 0:
                handle.seek(0)
                handle.write(self.head)
            handle.seek(self.buffer_offset)
            handle.write(self.buffer)
            for (start, _), data in zip(ranges, chunks):
                if start + len(data) > self.file_size:
                    raise SpriteIndexUnavailable("数据段超出文件大小")
                handle.seek(start)
                handle.write(data)
        return local


class _ProgressProbe:
    """只记录 ffmpeg -progress 的 out_time，用来确认抽到的是目标附近的那一帧。

    ffmpeg 在索引对应的数据缺失时会继续往后读到下一个能解码的关键帧，进程仍然
    返回 0，画面却是别的时间点。这里用输出时间戳做兜底校验。
    """

    __slots__ = ("decoded", "video")

    def __init__(self) -> None:
        self.decoded = 0.0
        self.video = ""

    def begin(self, detail: str) -> None:  # noqa: D401 - 与 TaskProgress 接口保持一致
        return None

    def advance(self, step: int, steps: int | None = None) -> None:
        return None

    def feed(
        self,
        frame: int | None = None,
        decoded: float | None = None,
        speed: str | None = None,
    ) -> None:
        if decoded is not None and decoded > self.decoded:
            self.decoded = decoded


def _extract_local(
    ffmpeg: str,
    local: str,
    positions: list[float],
    width: int,
    timeout: float,
    task: TaskProgress | None,
    serial: bool = False,
) -> list[bytes]:
    """在本地稀疏文件上抽帧；任何一帧失败都交给调用方回退远程路径。"""

    def grab(index: int) -> tuple[int, bytes]:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消", phase="本地抽帧")
        probe = _ProgressProbe()
        try:
            jpeg = extract_frame(
                ffmpeg,
                local,
                positions[index],
                width,
                None,
                False,
                timeout=min(timeout, 120.0) if timeout > 0 else 120.0,
                seek_modes=(True,),
                label=None,
                stall_timeout=0.0,
                task=probe,
            )
        except VideoError as exc:
            raise SpriteIndexUnavailable(
                f"本地抽帧第 {index + 1}/{len(positions)} 帧失败：{exc}"
            ) from exc
        if probe.decoded > SPRITE_INDEX_MAX_SKIP:
            raise SpriteIndexUnavailable(
                f"本地抽帧第 {index + 1}/{len(positions)} 帧跳到 {probe.decoded:.1f}s"
                " 之后，数据窗口不完整"
            )
        return index, jpeg

    frames: list[bytes | None] = [None] * len(positions)
    workers = 1 if serial else max(1, min(SPRITE_INDEX_FRAME_WORKERS, len(positions)))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(grab, index) for index in range(len(positions))]
        done = 0
        for future in as_completed(futures):
            index, jpeg = future.result()
            frames[index] = jpeg
            done += 1
            if task is not None:
                task.advance(done, len(positions))
    if any(frame is None for frame in frames):
        raise SpriteIndexUnavailable("本地抽帧结果不完整")
    return [frame for frame in frames if frame is not None]


# ---------------------------------------------------------------------------
# 定位并解析 moov
# ---------------------------------------------------------------------------


def _find_head_moov(buffer: bytes) -> tuple[int, int] | None:
    """在文件头缓冲区里按顶层 box 顺序查找 moov，返回 (box 起点, box 大小)。"""
    pos = 0
    limit = len(buffer)
    while pos + 8 <= limit:
        size = int.from_bytes(buffer[pos:pos + 4], "big")
        kind = bytes(buffer[pos + 4:pos + 8])
        header = 8
        if size == 1:
            if pos + 16 > limit:
                return None
            size = int.from_bytes(buffer[pos + 8:pos + 16], "big")
            header = 16
        elif size == 0:
            return None
        if size < header:
            return None
        if kind == b"moov":
            return pos, size
        if pos + size > limit:
            # 下一个 box 不在缓冲区里（通常是大 mdat）：moov 在文件尾部
            return None
        pos += size
    return None


def _find_tail_moov(buffer: bytes) -> tuple[int, int] | None:
    """在文件尾缓冲区里找结束位置贴近文件尾的 moov。"""
    index = 0
    while True:
        found = buffer.find(b"moov", index)
        if found < 0:
            return None
        start = found - 4
        if start >= 0:
            size = int.from_bytes(buffer[start:start + 4], "big")
            if 8 <= size <= SPRITE_INDEX_MAX_MOOV:
                if start + size >= len(buffer) - _TAIL_SLACK:
                    return start, size
        index = found + 4


def _looks_like_mp4(buffer: bytes) -> bool:
    if len(buffer) < 8:
        return False
    size = int.from_bytes(buffer[0:4], "big")
    return buffer[4:8] in _MP4_TOP_LEVEL and size >= 8


def _sample_sizes(buffer: bytes, stbl: tuple[int, int]) -> list[int]:
    """stsz 样本大小表；stz2（紧凑格式）不支持，直接回退。"""
    found = _mp4_find(buffer, *stbl, b"stsz")
    if found is None:
        if _mp4_find(buffer, *stbl, b"stz2") is not None:
            raise SpriteIndexUnavailable("MP4 使用 stz2 样本表，暂不支持")
        raise SpriteIndexUnavailable("MP4 没有 stsz 样本表")
    payload, stop = found
    if payload + 12 > stop:
        raise SpriteIndexUnavailable("stsz 样本表不完整")
    constant = int.from_bytes(buffer[payload + 4:payload + 8], "big")
    count = int.from_bytes(buffer[payload + 8:payload + 12], "big")
    if count <= 0 or count > 5_000_000:
        raise SpriteIndexUnavailable(f"样本数量异常（{count}）")
    if constant:
        return [constant] * count
    if payload + 12 + count * 4 > stop:
        raise SpriteIndexUnavailable("stsz 样本表被截断")
    return [
        int.from_bytes(buffer[payload + 12 + index * 4:payload + 16 + index * 4], "big")
        for index in range(count)
    ]


def _parse_tables(buffer: bytes, moov: tuple[int, int]) -> _SampleTables:
    mvhd = _mp4_find(buffer, *moov, b"mvhd")
    if mvhd is None:
        raise SpriteIndexUnavailable("索引里没有 mvhd")
    movie_scale, movie_duration = _mp4_timescale_duration(buffer, mvhd)
    if movie_scale <= 0 or movie_duration <= 0:
        raise SpriteIndexUnavailable("mvhd 时长无效")

    track = _mp4_video_track(buffer, moov)
    if track is None:
        raise SpriteIndexUnavailable("没有视频轨道")
    mdhd = _mp4_find(buffer, *track, b"mdhd")
    stbl = _mp4_find(buffer, *track, b"stbl")
    if mdhd is None or stbl is None:
        raise SpriteIndexUnavailable("视频轨缺少 mdhd/stbl")
    track_scale, track_duration = _mp4_timescale_duration(buffer, mdhd)
    if track_scale <= 0 or track_duration <= 0:
        raise SpriteIndexUnavailable("mdhd 时长无效")

    offsets = _mp4_chunk_offsets(buffer, stbl)
    if not offsets:
        raise SpriteIndexUnavailable("没有 stco/co64 数据块偏移")
    stts = _mp4_table(buffer, stbl, b"stts", 8)
    stsc = _mp4_table(buffer, stbl, b"stsc", 12)
    if not stts or not stsc:
        raise SpriteIndexUnavailable("缺少 stts/stsc 时间表")
    sizes = _sample_sizes(buffer, stbl)
    if sum(row[0] for row in stts) < len(sizes):
        raise SpriteIndexUnavailable("stts 样本数少于 stsz")
    syncs = [row[0] - 1 for row in _mp4_table(buffer, stbl, b"stss", 4)]

    # 样本序号 -> 所在 chunk（chunk 内样本连续存放，偏移 = chunk 偏移 + 前面的样本大小之和）
    chunk_starts: list[tuple[int, int]] = []
    sample = 0
    for position, row in enumerate(stsc):
        first_chunk = max(1, row[0])
        per_chunk = max(1, row[1] if len(row) > 1 else 1)
        next_chunk = stsc[position + 1][0] if position + 1 < len(stsc) else len(offsets) + 1
        chunk = max(first_chunk, len(chunk_starts) + 1)
        while chunk < next_chunk and chunk <= len(offsets):
            chunk_starts.append((sample, chunk - 1))
            sample += per_chunk
            chunk += 1
    if sample < len(sizes):
        raise SpriteIndexUnavailable("stsc 样本映射不完整")
    if not chunk_starts:
        raise SpriteIndexUnavailable("stsc 为空")

    return _SampleTables(
        duration=movie_duration / movie_scale,
        track_duration=float(track_duration),
        sample_sizes=sizes,
        chunk_offsets=offsets,
        chunk_starts=chunk_starts,
        first_samples=[item[0] for item in chunk_starts],
        stts=stts,
        syncs=syncs,
    )


def prepare_sprite_index(
    client: WebDav,
    url: str,
    file_size: int | None,
    task: TaskProgress | None = None,
) -> SpriteIndex:
    """读取并解析 MP4 索引，得到时长与样本表。

    只读文件头 64KB；没找到 moov 再读文件尾（115 的文件基本都是 mdat 在前）。
    无法解析时抛 :class:`SpriteIndexUnavailable`。
    """
    if not file_size or file_size <= 0:
        raise SpriteIndexUnavailable("没有文件大小")
    if task is not None:
        task.set_phase("读索引")

    head_length = min(SPRITE_INDEX_HEAD_BYTES, file_size)
    with upstream.UPSTREAM_LIMIT:
        head = read_range_retry(client, url, 0, head_length, timeout=30, budget=60)
    if not _looks_like_mp4(head):
        raise SpriteIndexUnavailable("文件头不是 MP4")

    found = _find_head_moov(head)
    if found is not None:
        box_start, box_size = found
        if box_size > SPRITE_INDEX_MAX_MOOV:
            raise SpriteIndexUnavailable(f"moov 有 {box_size // 1048576}MB，过大")
        if box_start + box_size <= len(head):
            buffer, buffer_offset = head, 0
            moov = (box_start + 8, box_start + box_size)
        else:
            # faststart 文件：moov 在头部，但比 64KB 大，按大小精确补读
            with upstream.UPSTREAM_LIMIT:
                buffer = read_range_retry(
                    client, url, box_start, box_size, timeout=30,
                    budget=max(90.0, box_size / 1048576 * 30.0),
                )
            buffer_offset = box_start
            moov = (8, box_size)
        tables = _parse_tables(buffer, moov)
        return SpriteIndex(
            duration=tables.duration,
            file_size=file_size,
            buffer=buffer,
            buffer_offset=buffer_offset,
            sample_tables=tables,
            head=None if buffer_offset == 0 else head,
        )

    # mdat 在前：moov 在文件尾部
    tail_length = min(SPRITE_INDEX_TAIL_BYTES, file_size)
    with upstream.UPSTREAM_LIMIT:
        tail = read_range_retry(client, url, file_size - tail_length, tail_length, timeout=30, budget=120)
    candidate = _find_tail_moov(tail)
    if candidate is None:
        raise SpriteIndexUnavailable("文件尾部没有找到 moov")
    box_start, box_size = candidate
    if box_start + box_size > len(tail):
        # moov 比默认尾缓冲区还大：按 moov 的大小补读一次
        want = min(box_size + _TAIL_SLACK, file_size)
        with upstream.UPSTREAM_LIMIT:
            tail = read_range_retry(client, url, file_size - want, want, timeout=30, budget=180)
        candidate = _find_tail_moov(tail)
        if candidate is None:
            raise SpriteIndexUnavailable("补读后仍然找不到 moov")
        box_start, box_size = candidate
        if box_start + box_size > len(tail):
            raise SpriteIndexUnavailable("moov 超出数据窗口")
    buffer_offset = file_size - len(tail)
    moov = (box_start + 8, box_start + box_size)
    tables = _parse_tables(tail, moov)
    return SpriteIndex(
        duration=tables.duration,
        file_size=file_size,
        buffer=tail,
        buffer_offset=buffer_offset,
        sample_tables=tables,
        head=head,
    )
