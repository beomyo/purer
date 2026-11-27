"""刮削主流程：扫描目录、并发生成缩略图/雪碧图。"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

from . import durations, runtime
from .aviwindow import (
    AviCodecUnsupported,
    AviWindowUnavailable,
    extract_dv_frames,
    prepare_avi_info,
)
from .cache import (
    cache_listing_with_retry,
    cleanup_stale_sprites,
    delete_cache_dir,
    delete_marker,
    delete_thumbnail,
    orphan_cache_dirs,
    marker_file_name,
    put_ensured,
    shorten_left,
    utc_stamp,
    stale_sprite_files,
    thumbnail_is_orphan,
    write_failure_marker,
)
from .console import (
    StatusBoard,
    cyan,
    dim,
    green,
    log,
    log_failure,
    log_success,
    progress_bar,
    red,
)
from .constants import (
    AVI_SAFE_DURATION,
    DEFAULT_UNSUPPORTED_CODECS,
    AVI_SAFE_POSITIONS,
    DEFAULT_SPRITE_MIN_DURATION,
    DEFAULT_SPRITE_WIDTH,
    EXTRACT_TIMEOUT,
    GOOD_THUMBNAIL_BYTES,
    MAX_RETRY_TIMEOUT,
    MAX_SPRITE_BYTES,
    MIN_THUMBNAIL_BYTES,
    PROBE_TIMEOUT,
    RECORDED_FAILURES,
    SPRITE_END,
    SPRITE_QUALITIES,
    SPRITE_START,
    STALL_TIMEOUT,
    WINDOW_BYTES,
)
from .errors import VideoError, VideoSkipped, VideoUnsupported, failure_label
from .failure_report import collect_failure_details, log_failure_details
from .ffmpeg import extract_frame, probe_duration
from .httpcache import start_cache_proxy
from .mp4sprite import SpriteIndexUnavailable, prepare_sprite_index
from .mp4window import extract_frame_window
from .tswindow import TsWindowUnavailable, extract_ts_frames, prepare_ts_window
from .paths import DEFAULT_FAILED
from .progress import TaskProgress, TaskTracker
from .rate import RateLimiter
from .retry import retry
from .urls import (
    _url_key,
    cache_base_name,
    cache_bust,
    display_url,
    is_avi_url,
    is_hls_url,
    is_under,
    mirror_folder,
    normalize_folder,
    quote_name,
    same_location,
    sprite_filename,
    sprite_positions,
    video_mime,
)
from .webdav import Resource, WebDav, WebDavError

# ---------------------------------------------------------------------------
# 刮削
# ---------------------------------------------------------------------------


@dataclass
class Stats:
    """本次刮削的统计。

    工作线程与终端刷新线程会同时访问，所有修改都经过 :meth:`bump` /
    :meth:`add_failure` / :meth:`counts`，避免并发下进度数字忽大忽小。
    """

    generated: int = 0
    skipped: int = 0
    skipped_failed: int = 0
    skipped_short: int = 0
    skipped_unsupported: int = 0
    failed: int = 0
    recorded: int = 0
    recorded_local: int = 0
    removed: int = 0
    folders: int = 0
    started_at: float = 0.0
    timed: int = 0
    total_seconds: float = 0.0
    failures: list[tuple[str, str]] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def bump(self, **deltas: int) -> None:
        with self._lock:
            for name, delta in deltas.items():
                setattr(self, name, getattr(self, name) + delta)

    def add_failure(self, url: str, reason: str, count: int = 1) -> None:
        with self._lock:
            self.failed += count
            self.failures.append((url, reason))

    def add_elapsed(self, seconds: float) -> None:
        """记录一个视频的实际用时，用于动态平均（进度区和结束汇总）。"""
        if seconds < 0:
            return
        with self._lock:
            self.timed += 1
            self.total_seconds += float(seconds)

    def average_seconds(self) -> float:
        with self._lock:
            return self.total_seconds / self.timed if self.timed else 0.0

    def counts(self) -> dict[str, float | int]:
        with self._lock:
            return {
                "generated": self.generated,
                "skipped": self.skipped,
                "skipped_failed": self.skipped_failed,
                "skipped_short": self.skipped_short,
                "skipped_unsupported": self.skipped_unsupported,
                "failed": self.failed,
                "recorded": self.recorded,
                "recorded_local": self.recorded_local,
                "removed": self.removed,
                "folders": self.folders,
                "timed": self.timed,
                "average": self.total_seconds / self.timed if self.timed else 0.0,
            }


def _abort_on_server_errors(streak: int) -> None:
    """连续多个视频都是服务器 5xx 时停止本轮，避免把 115/OpenList 打到更严重的限流。"""
    log(
        red(
            f"连续 {streak} 个视频都返回服务器 5xx，可能是 115 限流/WAF 拦截或 OpenList 后端故障，"
            "已停止本轮。"
        )
    )
    log("  建议：等待一段时间后先用单次 Range 请求确认恢复，再降低 --rate / --jobs 重试。")
    runtime.run_summary = "连续服务器 5xx，已停止"
    runtime.cancel_running()


def _probe_duration_cached(
    ffprobe: str,
    url: str,
    token: str | None,
    insecure: bool,
    *,
    cache_url: str,
    cache_size: int | None,
    **kwargs,
) -> float | None:
    """读时长前先查本地缓存（按 URL + 文件大小），成功后写回。

    远程读一次时长要读索引，常见 5–10 秒；同一文件的时长不会变，重跑时直接用
    缓存可以省掉这一步。缓存文件损坏或大小变化都会自动失效。
    """
    cached = durations.get(cache_url, cache_size)
    if cached is not None:
        label = kwargs.get("label")
        log(f"  {label}：使用缓存的时长 {cached:.0f}s" if label else f"  使用缓存的时长 {cached:.0f}s")
        return cached
    value = probe_duration(ffprobe, url, token, insecure, **kwargs)
    if value is not None:
        durations.put(cache_url, cache_size, value)
    return value


def scrape_one(
    video: Resource,
    folder: str,
    mirror_dir: str,
    cache_root: str,
    cache_client: WebDav,
    ffmpeg: str,
    ffprobe: str,
    token: str | None,
    insecure: bool,
    percent: float,
    width: int,
    fallback_seconds: float,
    retries: int,
    limiter: RateLimiter,
    probe_timeout: float = PROBE_TIMEOUT,
    extract_timeout: float = EXTRACT_TIMEOUT,
    fallback_retry: bool = True,
    source_client: WebDav | None = None,
    stall_timeout: float = STALL_TIMEOUT,
    window_fallback: bool = True,
    task: TaskProgress | None = None,
) -> tuple[str, float | None]:
    """生成并上传一个视频的缩略图，返回缓存文件名与时长。

    与 App 一致：一次抽帧占用该文件夹的一个限速名额；失败直接上报，
    由调用方决定是否写失败标记。

    - 只使用输入端定位（HTTP Range），不从头解码，绝不下载整个源文件。
    - 支持 HTTP Range 的服务器上，不会在输出端从头解码。
    - 超大 AVI：只读 1MB 文件头解析时长，并加 `-use_odml 0` 取帧；
      在 3/120/180/300 秒几个靠前位置里选一张非黑屏画面。
    - 封装格式用文件头（RIFF 魔数）判断，不信任扩展名：改名的 MP4 只按普通视频处理。
    - HLS（.m3u8）：播放列表本身很小，不做 Range 探测，始终读取时长；
      ffmpeg 打开列表后只拉取目标时间点附近的分片，同样不下载整个视频。
    - ffprobe 读不到时长时，文件名不带时长前缀。
    - 网络类失败由 retry() 统一再试一次，第二次使用更长的超时（上限 300 秒）。
    - 运行中定期写心跳日志；连续 stall_timeout 秒没有进展就中止该视频，
      不会让一个卡住的视频拖住整次刮削。
    """

    log(f"  {cyan('▶')} {video.name}：开始处理")
    if task is not None:
        task.set_phase("探测格式")
    avi = is_avi_url(video.url)
    hls = is_hls_url(video.url)
    range_ok = True
    # 播放列表只有几 KB，Range 探测既没有意义也会误判：直接按可定位处理
    if source_client is not None and not hls:
        range_ok = source_client.supports_range(video.url)

    # 地址带查询参数：IDM 等下载器按扩展名接管 .ts/.avi/.mp4 请求时就会放行
    ffmpeg_url = cache_bust(video.url)
    ffmpeg_token = token

    attempt_no = 0
    probe_done = False
    duration: float | None = None
    probe_error: VideoError | None = None
    header_duration = False

    def remote() -> tuple[bytes, float | None]:
        nonlocal attempt_no, probe_done, duration, probe_error, header_duration, avi
        attempt_no += 1
        limiter.wait(folder)
        current_extract_timeout = min(extract_timeout * (2 ** (attempt_no - 1)), MAX_RETRY_TIMEOUT)
        current_probe_timeout = min(probe_timeout * (2 ** (attempt_no - 1)), MAX_RETRY_TIMEOUT)
        if attempt_no > 1:
            log(f"  {video.name}：第 {attempt_no} 次尝试，抽帧超时上限 {current_extract_timeout:g}s")

        if not probe_done:
            if task is not None:
                task.set_phase("读时长")
            header_value: float | None = None
            if avi and range_ok and source_client is not None and hasattr(source_client, "probe_avi_duration"):
                header_reader = getattr(source_client, "probe_avi_header", None)
                if header_reader is not None:
                    real_avi, header_value = header_reader(video.url)
                else:
                    real_avi, header_value = True, source_client.probe_avi_duration(video.url)
                if not real_avi:
                    # 扩展名是 .avi，但封装不是 AVI：AVI 专属参数会失效，按普通视频处理
                    avi = False
                    header_value = None
                    log(f"  {video.name}：扩展名是 .avi，但封装不是 AVI，改用普通方式取帧")
            if header_value is not None:
                duration = header_value
                header_duration = True
                log(f"  {video.name}：从 AVI 文件头读取时长 {header_value:.0f}s")
            elif range_ok:
                try:
                    duration = _probe_duration_cached(
                        ffprobe,
                        ffmpeg_url,
                        ffmpeg_token,
                        insecure,
                        cache_url=video.url,
                        cache_size=video.size,
                        timeout=current_probe_timeout,
                        label=f"{video.name} 读时长",
                        stall_timeout=stall_timeout,
                        task=task,
                    )
                except VideoError as exc:
                    # 卡死（不可重试）直接放弃远端读取：马上改走局部窗口兜底，
                    # 不必再花一个卡死周期去尝试抽帧。
                    if (
                        runtime.cancel_event.is_set()
                        or not exc.retryable
                        or exc.reason in ("notfound", "auth")
                        or not fallback_retry
                    ):
                        raise
                    probe_error = exc
                    duration = None
            else:
                duration = None
            probe_done = True

        safe_avi = (
            avi
            and range_ok
            and (header_duration or duration is None or (duration is not None and duration > AVI_SAFE_DURATION))
        )

        def safe_avi_frame(timeout: float) -> bytes:
            if task is not None:
                task.set_phase("抽帧")
            positions: list[float] = []
            for position in (fallback_seconds, *AVI_SAFE_POSITIONS):
                if position in positions:
                    continue
                if duration is not None and position >= duration - 1:
                    continue
                positions.append(position)
            if not positions:
                # 视频比所有候选位置都短：取靠中间的位置，绝不能落到文件末尾之后（那样取不到任何帧）
                positions = [max(0.0, (duration - 0.5) / 2) if duration else fallback_seconds]
            candidates: list[tuple[float, bytes]] = []
            errors: list[VideoError] = []
            for position in positions:
                if runtime.cancel_event.is_set():
                    raise VideoError("timeout", "已取消")
                limiter.wait(folder)
                try:
                    jpeg = extract_frame(
                        ffmpeg,
                        ffmpeg_url,
                        position,
                        width,
                        ffmpeg_token,
                        insecure,
                        timeout=timeout,
                        seek_modes=(True,),
                        label=f"{video.name} 抽帧 {position:g}s",
                        stall_timeout=stall_timeout,
                        task=task,
                    )
                except VideoError as exc:
                    errors.append(exc)
                    continue
                candidates.append((position, jpeg))
                if len(jpeg) >= GOOD_THUMBNAIL_BYTES:
                    log(f"  {video.name}：在 {position:g}s 取到画面")
                    return jpeg
            if candidates:
                position, best = max(candidates, key=lambda item: len(item[1]))
                if len(best) >= MIN_THUMBNAIL_BYTES:
                    log(f"  {video.name}：使用 {position:g}s 的画面")
                    return best
                # 有候选但都像黑屏；如果某个位置是超时，留给上层重试
                transient = next(
                    (e for e in errors if e.reason in ("timeout", "server", "ratelimited")), None
                )
                if transient is not None:
                    raise transient
                raise VideoError(
                    "noframe",
                    "只取到黑屏/空白画面",
                    phase="抽帧",
                    context={"url": video.url, "avi_positions": positions},
                )
            if errors:
                for reason in ("timeout", "server", "ratelimited", "unknown", "noframe", "notfound", "auth"):
                    for error in errors:
                        if error.reason == reason:
                            raise error
            raise VideoError(
                "noframe",
                "没有取到画面",
                phase="抽帧",
                context={"url": video.url, "avi_positions": positions},
            )

        if safe_avi:
            try:
                jpeg = safe_avi_frame(current_extract_timeout)
            except VideoError as exc:
                if runtime.cancel_event.is_set():
                    raise
                if probe_error is not None:
                    context = dict(exc.context)
                    context["probe_error"] = {
                        "reason": probe_error.reason,
                        "message": str(probe_error),
                        "context": probe_error.context,
                    }
                    merged = VideoError(
                        exc.reason,
                        f"读取视频时长失败（{probe_error}）；{exc}",
                        retryable=exc.retryable,
                        phase="抽帧",
                        context=context,
                    )
                    merged.attempts = exc.attempts
                    raise merged from exc
                raise
            if probe_error is not None:
                log(f"  {video.name}：读取时长失败（{probe_error}），已用靠前位置取帧")
            return jpeg, duration

        timestamp = duration * percent / 100.0 if duration and duration > 0 else fallback_seconds
        if task is not None:
            task.set_phase("抽帧")
        if duration is not None:
            log(f"  {video.name}：时长 {duration:.0f}s · 取帧位置 {timestamp:.0f}s（{percent:g}%）")
        else:
            log(f"  {video.name}：未读到时长 · 取帧位置 {fallback_seconds:g}s")
        try:
            jpeg = extract_frame(
                ffmpeg,
                ffmpeg_url,
                timestamp,
                width,
                ffmpeg_token,
                insecure,
                timeout=current_extract_timeout,
                seek_modes=(True,),
                label=f"{video.name} 抽帧 {timestamp:.0f}s",
                stall_timeout=stall_timeout,
                task=task,
            )
        except VideoError as exc:
            if runtime.cancel_event.is_set():
                raise
            can_retry_near_start = (
                fallback_retry
                and timestamp > fallback_seconds + 0.01
                and exc.reason in ("timeout", "server", "ratelimited", "unknown")
            )
            if can_retry_near_start:
                try:
                    jpeg = extract_frame(
                        ffmpeg,
                        ffmpeg_url,
                        fallback_seconds,
                        width,
                        ffmpeg_token,
                        insecure,
                        timeout=current_extract_timeout,
                        seek_modes=(True,),
                        label=f"{video.name} 抽帧 {fallback_seconds:g}s（兜底）",
                        stall_timeout=stall_timeout,
                        task=task,
                    )
                    log(f"  {video.name}：目标位置抽帧失败，改用 {fallback_seconds:g}s 位置成功")
                except VideoError as retry_exc:
                    if runtime.cancel_event.is_set():
                        raise retry_exc
                    detail = f"抽帧失败（{exc}）；开头重试失败（{retry_exc}）"
                    if probe_error is not None:
                        detail = f"读取视频时长失败（{probe_error}）；" + detail
                    # 尽量沿用第一次失败的临时原因，避免因服务器抖动写出永久失败标记
                    reason = exc.reason
                    if reason == "unknown":
                        reason = retry_exc.reason
                    context = dict(retry_exc.context)
                    context["first_attempt"] = {
                        "reason": exc.reason,
                        "message": str(exc),
                        "context": exc.context,
                    }
                    if probe_error is not None:
                        context["probe_error"] = {
                            "reason": probe_error.reason,
                            "message": str(probe_error),
                            "context": probe_error.context,
                        }
                    merged = VideoError(
                        reason,
                        detail,
                        retryable=exc.retryable and retry_exc.retryable,
                        phase="抽帧",
                        context=context,
                    )
                    merged.attempts = retry_exc.attempts
                    raise merged from retry_exc
            else:
                if probe_error is not None:
                    context = dict(exc.context)
                    context["probe_error"] = {
                        "reason": probe_error.reason,
                        "message": str(probe_error),
                        "context": probe_error.context,
                    }
                    merged = VideoError(
                        exc.reason,
                        f"读取视频时长失败（{probe_error}）；抽帧失败（{exc}）",
                        retryable=exc.retryable,
                        phase="抽帧",
                        context=context,
                    )
                    merged.attempts = exc.attempts
                    raise merged from exc
                raise
        if probe_error is not None:
            log(f"  {video.name}：读取时长失败（{probe_error}），已用 {fallback_seconds:g}s 位置取帧")
        return jpeg, duration

    try:
        jpeg, duration = retry(f"抽帧 {video.name}", retries, remote)
    except VideoError as exc:
        # 只有「卡死」（不可重试的超时）才走局部窗口兜底；
        # 404、认证失败、无法解码等换一种读法也不会成功。
        if not window_fallback or source_client is None or exc.reason != "timeout" or exc.retryable:
            raise
        log(
            f"  {video.name}：远端读取卡住，改用局部窗口补图"
            f"（只读索引和 {percent:g}% 附近约 {WINDOW_BYTES // 1048576}MB）"
        )
        started = time.monotonic()
        try:
            jpeg, duration = extract_frame_window(
                ffmpeg,
                source_client,
                video.url,
                percent,
                width,
                timeout=extract_timeout,
                label=f"{video.name} 本地窗口",
                task=task,
            )
        except VideoError as fallback_error:
            log(f"  {video.name}：局部窗口补图失败（{fallback_error}），保留原失败原因")
            exc.context.setdefault(
                "window_fallback",
                {
                    "reason": fallback_error.reason,
                    "message": str(fallback_error),
                    "context": fallback_error.context,
                },
            )
            raise exc from fallback_error
        log(f"  {video.name}：局部窗口取帧成功（用时 {time.monotonic() - started:.1f}s）")
    filename = cache_base_name(video.name, duration) + ".jpg"
    file_url = normalize_folder(mirror_dir) + quote_name(filename)
    if task is not None:
        task.set_phase("上传")
        task.begin(filename)

    def upload() -> None:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消")
        try:
            put_ensured(cache_client, file_url, jpeg, "image/jpeg", cache_root)
        except WebDavError as exc:
            raise VideoError(
                "upload",
                f"上传缩略图失败：{exc}",
                phase="上传",
                context={"url": file_url, "size": len(jpeg), "http_status": exc.status},
            ) from exc

    retry(f"上传 {filename}", retries, upload)
    return filename, duration


def compose_sprite(
    ffmpeg: str,
    frames: list[bytes],
    cols: int,
    rows: int,
    max_bytes: int = MAX_SPRITE_BYTES,
) -> bytes:
    """用本地 ffmpeg 把多帧 JPEG 拼成一张雪碧图（不引入额外依赖）。

    先用质量 3 拼图；超过 max_bytes（默认 1MB）时依次降质量，仍超出再按比例
    缩小整张图。App 只需按列/行均分实际图片尺寸，不需要在文件名里记录尺寸。
    """
    tmpdir = tempfile.mkdtemp(prefix="purer-sprite-")
    try:
        for index, data in enumerate(frames, 1):
            with open(os.path.join(tmpdir, f"f{index:03d}.jpg"), "wb") as fh:
                fh.write(data)
        output = os.path.join(tmpdir, "sprite.jpg")
        tile = f"tile={cols}x{rows}:margin=0:padding=0"

        def encode(quality: int, scale: float | None = None) -> bytes:
            vf = tile
            if scale is not None and scale < 1:
                vf += f",scale=trunc(iw*{scale:.3f}/2)*2:trunc(ih*{scale:.3f}/2)*2"
            cmd = [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-framerate",
                "1",
                "-start_number",
                "1",
                "-i",
                os.path.join(tmpdir, "f%03d.jpg"),
                "-vf",
                vf,
                "-frames:v",
                "1",
                "-q:v",
                str(quality),
                output,
            ]
            proc = subprocess.run(cmd, capture_output=True, timeout=120)
            if proc.returncode != 0 or not os.path.exists(output):
                detail = (proc.stderr or b"").decode("utf-8", "replace").strip()
                raise VideoError(
                    "noframe",
                    "拼接雪碧图失败：" + (detail[:300] or f"exit {proc.returncode}"),
                )
            with open(output, "rb") as fh:
                data = fh.read()
            if not data.startswith(b"\xff\xd8"):
                raise VideoError(
                    "noframe",
                    "拼接雪碧图没有返回 JPEG",
                    phase="拼接",
                )
            return data

        limit_kb = max_bytes // 1024
        best = b""
        for quality in SPRITE_QUALITIES:
            data = encode(quality)
            if not best or len(data) < len(best):
                best = data
            if len(data) <= max_bytes:
                if quality != SPRITE_QUALITIES[0]:
                    log(f"  雪碧图超过 {limit_kb}KB，已降质量到 q={quality}（{len(data) // 1024}KB）")
                return data

        # 质量降到最低仍超出：按面积比例缩小整张图，再试几次
        ratio = 0.8
        while ratio >= 0.05:
            data = encode(8, ratio)
            if len(data) < len(best):
                best = data
            if len(data) <= max_bytes:
                log(
                    f"  雪碧图超过 {limit_kb}KB，已缩小到 {ratio:.0%}"
                    f"（{len(data) // 1024}KB）"
                )
                return data
            ratio *= 0.8
        log(f"  雪碧图压缩后仍有 {len(best) // 1024}KB（上限 {limit_kb}KB）")
        return best
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def scrape_one_sprite(
    video: Resource,
    folder: str,
    mirror_dir: str,
    cache_root: str,
    cache_client: WebDav,
    ffmpeg: str,
    ffprobe: str,
    token: str | None,
    insecure: bool,
    cols: int,
    rows: int,
    cell_width: int,
    retries: int,
    limiter: RateLimiter,
    probe_timeout: float = PROBE_TIMEOUT,
    extract_timeout: float = EXTRACT_TIMEOUT,
    source_client: WebDav | None = None,
    stall_timeout: float = STALL_TIMEOUT,
    min_duration: float = DEFAULT_SPRITE_MIN_DURATION,
    sprite_index: bool = True,
    sprite_window: bool = True,
    unsupported_codecs: frozenset[str] | None = None,
    task: TaskProgress | None = None,
) -> tuple[str, float | None]:
    """生成雪碧图并上传，返回缓存文件名与时长。

    与普通缩略图唯一的区别是取帧次数：在视频 10%–95% 区间内均匀取 cols*rows 个
    时间点（含两端）。优先走 MP4 索引快速路径：只读一次 moov，按样本表只取每帧
    真正需要的字节，再拼成稀疏本地文件在本地抽帧；格式不支持或索引不完整时退回
    逐帧远程读取（每帧仍然只做输入端定位，不会顺序读取整个文件）。
    时长不超过 min_duration（默认 300 秒）的视频主动跳过，不计入失败。
    """
    count = cols * rows
    log(f"  {cyan('▶')} {video.name}：开始生成雪碧图（{cols}x{rows}，{count} 帧）")
    if task is not None:
        task.set_phase("探测格式")
    avi = is_avi_url(video.url)
    hls = is_hls_url(video.url)
    range_ok = True
    if source_client is not None and not hls:
        range_ok = source_client.supports_range(video.url)
    if not range_ok:
        # 不支持 Range 时每次取帧都会从头顺序读，N 帧等于读 N 遍，不能这么做
        raise VideoError(
            "timeout",
            "服务器不支持 Range，雪碧图需要多次定位读取",
            phase="探测格式",
            context={"url": video.url},
        )

    duration: float | None = None
    frames: list[bytes] | None = None

    # ---- TS/M2TS：先花 4KB 判断是不是 TS，是的话跳过 MP4 索引 ----
    ts_packet: int | None = None
    if (
        sprite_window
        and source_client is not None
        and bool(video.size)
        and not avi
        and not hls
    ):
        try:
            ts_packet = prepare_ts_window(source_client, video.url, video.size)
        except VideoError:
            if runtime.cancel_event.is_set():
                raise
            ts_packet = None

    # ---- AVI：读 256KB 头部判断编码（DV 可走快速路径，CUVC 直接失败） ----
    avi_info = None
    avi_codec_error: AviCodecUnsupported | None = None
    if (
        sprite_window
        and source_client is not None
        and bool(video.size)
        and avi
        and not hls
    ):
        try:
            avi_info = prepare_avi_info(
                source_client,
                video.url,
                video.size,
                unsupported_codecs,
            )
        except AviCodecUnsupported as exc:
            avi_codec_error = exc
        except AviWindowUnavailable:
            avi_info = None
        except VideoError:
            if runtime.cancel_event.is_set():
                raise
            avi_info = None

    # ---- 优先：MP4 索引快速路径（读一次索引，只取各帧所需的字节） ----
    index_error: str | None = None
    index_ready = (
        sprite_index
        and ts_packet is None
        and source_client is not None
        and bool(video.size)
        and not avi
        and not hls
    )
    if index_ready:
        try:
            index = prepare_sprite_index(source_client, video.url, video.size, task=task)
            duration = index.duration
            durations.put(video.url, video.size, duration)
            if min_duration > 0 and duration <= min_duration:
                raise VideoSkipped(
                    f"时长 {duration:.0f}s 未超过雪碧图下限 {min_duration:g}s",
                    duration=duration,
                )
            log(
                f"  {video.name}：时长 {duration:.0f}s · 已读取 MP4 索引，"
                "只取各帧所需数据后在本地抽帧"
            )
            frames = index.frames(
                ffmpeg,
                source_client,
                video.url,
                count,
                cell_width,
                folder,
                limiter,
                extract_timeout=extract_timeout,
                task=task,
            )
        except VideoSkipped:
            raise
        except SpriteIndexUnavailable as exc:
            index_error = str(exc)
        except VideoError as exc:
            if runtime.cancel_event.is_set():
                raise
            index_error = str(exc)
        if index_error is not None:
            log(f"  {video.name}：MP4 索引快速路径不可用（{index_error}），改用远程抽帧")
            frames = None
            duration = None

    # ---- 兜底：逐帧远程读取（行为与旧版一致） ----
    if (
        duration is None
        and avi
        and source_client is not None
        and hasattr(source_client, "probe_avi_header")
    ):
        real_avi, header_value = source_client.probe_avi_header(video.url)
        if real_avi:
            duration = header_value
            if duration:
                durations.put(video.url, video.size, duration)
    if duration is None:
        if task is not None:
            task.set_phase("读时长")

        def probe() -> float | None:
            return _probe_duration_cached(
                ffprobe,
                cache_bust(video.url),
                token,
                insecure,
                cache_url=video.url,
                cache_size=video.size,
                timeout=probe_timeout,
                label=f"{video.name} 读时长",
                stall_timeout=stall_timeout,
                task=task,
            )

        duration = retry(f"雪碧图 {video.name} 读时长", retries, probe)
    if not duration or duration <= 0:
        raise VideoError(
            "noframe",
            "雪碧图需要视频时长，但读取时长失败",
            phase="读时长",
            context={"url": video.url},
        )
    if min_duration > 0 and duration <= min_duration:
        # 主动跳过，不算失败：既不写失败标记，也不写本地失败记录。
        raise VideoSkipped(
            f"时长 {duration:.0f}s 未超过雪碧图下限 {min_duration:g}s",
            duration=duration,
        )

    interval = duration * (SPRITE_END - SPRITE_START) / max(1, count - 1)
    if frames is None and ts_packet is not None and source_client is not None and video.size:
        ts_error: str | None = None
        try:
            log(f"  {video.name}：TS 窗口快速路径（包长 {ts_packet} 字节）")
            frames = extract_ts_frames(
                ffmpeg,
                source_client,
                video.url,
                video.size,
                duration,
                count,
                cell_width,
                ts_packet,
                folder,
                limiter,
                extract_timeout=extract_timeout,
                task=task,
            )
        except TsWindowUnavailable as exc:
            ts_error = str(exc)
        except VideoError as exc:
            if runtime.cancel_event.is_set():
                raise
            ts_error = str(exc)
        if ts_error is not None:
            log(f"  {video.name}：TS 窗口快速路径不可用（{ts_error}），改用远程抽帧")
            frames = None

    if frames is None and avi_codec_error is not None:
        # 不支持编码：主动跳过，不计失败，也别再去远程按 75 秒卡死
        raise VideoUnsupported(str(avi_codec_error), codec=avi_codec_error.codec)
    if frames is None and avi_info is not None and source_client is not None and video.size:
        avi_error: str | None = None
        try:
            log(f"  {video.name}：AVI(DV) 快速路径（{avi_info.chunk_id.decode('ascii', 'replace')} 定长帧）")
            frames = extract_dv_frames(
                ffmpeg,
                source_client,
                video.url,
                video.size,
                duration,
                count,
                cell_width,
                avi_info,
                folder,
                limiter,
                extract_timeout=extract_timeout,
                task=task,
            )
        except AviWindowUnavailable as exc:
            avi_error = str(exc)
        except VideoError as exc:
            if runtime.cancel_event.is_set():
                raise
            avi_error = str(exc)
        if avi_error is not None:
            log(f"  {video.name}：AVI(DV) 快速路径不可用（{avi_error}），改用远程抽帧")
            frames = None

    if frames is None:
        positions = sprite_positions(duration, count)
        log(
            f"  {video.name}：时长 {duration:.0f}s · 在 10%–95% 区间每 {interval:.1f}s 取一帧 · "
            f"单格上限 {cell_width}px"
        )
        remote_url = video.url
        frame_proxy = None
        if sprite_window and source_client is not None and video.size:
            try:
                frame_proxy = start_cache_proxy(source_client, video.url, video.size)
                remote_url = frame_proxy.url
                log(f"  {video.name}：使用本地 Range 缓存代理（重复索引读取不再请求上游）")
            except Exception as exc:  # noqa: BLE001
                log(f"  {video.name}：本地缓存代理启动失败（{exc}），直接远程抽帧")
                frame_proxy = None
        frames = []
        if task is not None:
            task.set_phase("取帧", steps=count)
        try:
            for index, position in enumerate(positions, 1):
                if runtime.cancel_event.is_set():
                    raise VideoError("timeout", "已取消", phase="取帧")
                if task is not None:
                    task.advance(index, count)

                def grab(position: float = position, index: int = index) -> bytes:
                    limiter.wait(folder)
                    return extract_frame(
                        ffmpeg,
                        cache_bust(remote_url),
                        position,
                        cell_width,
                        token,
                        insecure,
                        timeout=extract_timeout,
                        seek_modes=(True,),
                        label=f"{video.name} 第 {index}/{count} 帧",
                        stall_timeout=stall_timeout,
                        task=task,
                    )

                try:
                    frames.append(retry(f"雪碧图 {video.name} 第 {index}/{count} 帧", retries, grab))
                except VideoError as exc:
                    exc.context.setdefault("frame_index", index)
                    exc.context.setdefault("frame_count", count)
                    exc.context.setdefault("frame_position", round(position, 3))
                    # 卡死（不可重试）立即放弃整个雪碧图，不再为后面每一帧重复等超时
                    if exc.reason in ("notfound", "auth", "noframe") or not exc.retryable:
                        raise
                    wrapped = VideoError(
                        exc.reason,
                        f"第 {index}/{count} 帧取帧失败（{exc}）",
                        retryable=exc.retryable,
                        phase=f"取帧 {index}/{count}",
                        context=exc.context,
                    )
                    wrapped.attempts = exc.attempts
                    raise wrapped from exc
        finally:
            if frame_proxy is not None:
                frame_proxy.close()
    else:
        log(
            f"  {video.name}：时长 {duration:.0f}s · 本地数据窗口已取到 {len(frames)} 帧"
            f"（每 {interval:.1f}s 一帧）"
        )

    if task is not None:
        task.set_phase("拼接")
        task.begin(f"{count} 帧拼成 {cols}x{rows}")
    try:
        sprite = compose_sprite(ffmpeg, frames, cols, rows)
    except VideoError as exc:
        exc.context.setdefault("frames", len(frames))
        exc.context.setdefault("cols", cols)
        exc.context.setdefault("rows", rows)
        exc.context.setdefault("cell_width", cell_width)
        raise
    filename = sprite_filename(video.name, duration, cols, rows)
    file_url = normalize_folder(mirror_dir) + quote_name(filename)
    if task is not None:
        task.set_phase("上传")
        task.begin(filename)

    def upload() -> None:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消")
        try:
            put_ensured(cache_client, file_url, sprite, "image/jpeg", cache_root)
        except WebDavError as exc:
            raise VideoError(
                "upload",
                f"上传雪碧图失败：{exc}",
                phase="上传",
                context={"url": file_url, "size": len(sprite), "http_status": exc.status},
            ) from exc

    retry(f"上传 {filename}", retries, upload)
    log(f"  {video.name}：雪碧图完成（{len(sprite) // 1024}KB）")
    return filename, duration

def scrape(
    source_client: WebDav,
    cache_client: WebDav,
    source_folder: str,
    source_base: str,
    cache_root: str,
    ffmpeg: str,
    ffprobe: str,
    source_token: str | None,
    insecure: bool,
    percent: float,
    rate: float,
    width: int,
    jobs: int,
    retries: int,
    fallback_seconds: float,
    limit: int | None,
    dry_run: bool,
    probe_timeout: float = PROBE_TIMEOUT,
    extract_timeout: float = EXTRACT_TIMEOUT,
    fallback_retry: bool = True,
    stall_timeout: float = STALL_TIMEOUT,
    window_fallback: bool = True,
    mode: str = "thumb",
    sprite_grid: tuple[int, int] = (3, 3),
    sprite_width: int = DEFAULT_SPRITE_WIDTH,
    sprite_min_duration: float = DEFAULT_SPRITE_MIN_DURATION,
    sprite_index: bool = True,
    sprite_window: bool = True,
    unsupported_codecs: frozenset[str] | None = None,
) -> Stats:
    runtime.cancel_event.clear()
    stats = Stats(started_at=time.monotonic())
    skip_codecs = frozenset(
        (item.upper() for item in (unsupported_codecs or DEFAULT_UNSUPPORTED_CODECS))
    )
    limiter = RateLimiter(rate)
    source_folder = normalize_folder(source_folder)
    cache_root = normalize_folder(cache_root)

    # 进度区：第 1 行是文件夹汇总，之后每个并发任务一行；由 TaskTracker 统一刷新。
    board = StatusBoard()
    runtime.board = board
    state_lock = threading.Lock()
    status_state = {"folder": "", "done": 0, "total": 0}

    def summary_line() -> str:
        if dry_run:
            return ""
        with state_lock:
            folder_url = status_state["folder"]
            done = status_state["done"]
            total = status_state["total"]
        if not folder_url:
            return ""
        counts = stats.counts()
        elapsed = int(time.monotonic() - stats.started_at)
        clock = time.strftime("%H:%M:%S", time.gmtime(elapsed))
        average = counts["average"]
        avg_text = f"均 {average:.0f}s/个 · " if counts["timed"] else ""
        return (
            f"{progress_bar(done, total)} {done}/{total} · "
            f"新增 {counts['generated']} · 失败 {counts['failed']} · "
            f"{avg_text}{clock} · "
            f"{shorten_left(display_url(folder_url), 48)}"
        )

    tracker = TaskTracker(board, summary_line)

    def show_status(folder_url: str, done: int, total: int) -> None:
        with state_lock:
            status_state["folder"] = folder_url
            status_state["done"] = done
            status_state["total"] = total
        tracker.refresh(heartbeat=False)

    cache_is_server_root = same_location(cache_root, source_base)

    def scan() -> Stats:
        store = runtime.failure_store
        stack = [source_folder]
        visited: set[tuple[str, str, str]] = set()
        submitted = 0
        # 连续服务器 5xx 保护：115 WAF/OpenList 故障时不要把所有视频都打一遍
        server_streak = 0
        server_streak_limit = 5

        log(f"开始刮削：{display_url(source_folder)}")
        log(f"缓存根目录：{display_url(cache_root)}")
        if mode == "sprite":
            cols, rows = sprite_grid
            log(
                f"雪碧图 {cols}x{rows}（{cols * rows} 帧）· 单格上限 {sprite_width}px · "
                f"限速 {rate:g} 次/秒（按文件夹）· 并发 {jobs}"
            )
            log("提示：雪碧图需要对每个视频取多帧，流量和耗时约为普通缩略图的多倍。")
            if sprite_index:
                log(
                    "MP4 视频会先读一次索引，只取每帧所需数据后在本地抽帧"
                    "（--no-sprite-index 可关闭）"
                )
            if sprite_window:
                log(
                    "TS/M2TS 按码率取数据窗口、AVI(DV) 按定长帧直接读取，本地抽帧"
                    "（--no-sprite-window 可关闭）"
                )
            if skip_codecs:
                log("不支持的编码直接跳过： " + ", ".join(sorted(skip_codecs)))
            if sprite_min_duration > 0:
                log(
                    f"只处理时长超过 {sprite_min_duration:g}s 的视频"
                    "（时长不超过该值的视频直接跳过；可用 --sprite-min-duration 调整，0 表示不限制）"
                )
                if dry_run:
                    log("dry-run 不读取视频时长，时长不足的视频也会出现在待处理列表中。")
        else:
            log(f"取帧位置 {percent:g}% · 限速 {rate:g} 次/秒（按文件夹）· 缩略图 {width}px · 并发 {jobs}")
        stall_note = f"卡死判定 {stall_timeout:g}s 无进展即中止" if stall_timeout > 0 else "卡死判定关闭"
        log(
            f"失败兜底：{'开启' if fallback_retry else '关闭'} · "
            f"读时长超时 {probe_timeout:g}s · 抽帧超时 {extract_timeout:g}s · {stall_note}"
        )
        log(
            "卡死兜底："
            + (
                f"开启（远端卡住时只读索引和取帧位置附近约 {WINDOW_BYTES // 1048576}MB，"
                "拼成本地文件抽帧）"
                if window_fallback
                else "关闭"
            )
        )

        while stack:
            if runtime.cancel_event.is_set():
                break
            if limit is not None and submitted >= limit:
                log(f"已达到本次上限 {limit} 个视频，停止扫描。")
                break

            folder = normalize_folder(stack.pop())
            key = _url_key(folder)
            if key in visited:
                continue
            visited.add(key)

            # 不进入缓存镜像本身，避免把缓存当视频目录再刮一遍
            if is_under(folder, cache_root) and not cache_is_server_root:
                continue

            try:
                entries = source_client.list(folder)
            except WebDavError as exc:
                stats.add_failure(folder, f"列目录失败：{exc}")
                log(f"列目录失败 {display_url(folder)}：{exc}")
                continue

            stats.bump(folders=1)
            dirs = [entry for entry in entries if entry.is_dir]
            videos = [entry for entry in entries if not entry.is_dir and video_mime(entry.name, entry.mime)]
            for directory in dirs:
                stack.append(normalize_folder(directory.url))

            mirror_dir = normalize_folder(mirror_folder(cache_root, folder, source_base))
            try:
                listing = cache_listing_with_retry(cache_client, mirror_dir)
            except WebDavError as exc:
                # 不能把「读取失败」当成「没有缓存」，否则会把整个目录重新抽帧上传
                stats.add_failure(folder, f"读取缓存目录失败：{exc}", count=max(1, len(videos)))
                log(f"读取缓存目录失败 {display_url(mirror_dir)}：{exc}；跳过该文件夹（不会重新抽帧已有缩略图）")
                if exc.status in (401, 403):
                    log("缓存 WebDAV 认证失败，停止本次刮削。")
                    break
                continue

            # 有缩略图但源视频已经不存在：缩略图无效，直接删除。
            # 只有成功列出源目录时才这样做，避免因网络/认证问题误删。
            source_files = {unicodedata.normalize("NFC", entry.name).casefold() for entry in entries if not entry.is_dir}
            orphans = [
                thumbnail for thumbnail in listing.thumbnails
                if thumbnail_is_orphan(thumbnail.name, source_files)
            ]
            if orphans:
                if dry_run:
                    for thumbnail in orphans:
                        log(f"  待删除无效缩略图（源视频已删除）：{thumbnail.name}")
                else:
                    removed_here = sum(
                        1 for thumbnail in orphans if delete_thumbnail(cache_client, thumbnail)
                    )
                    stats.bump(removed=removed_here)
                    if removed_here:
                        log(f"  已删除 {removed_here} 个无效缩略图（源视频已删除）")

            # 源子文件夹已经不存在：对应的缓存镜像子目录整体无效，递归删除。
            # 只在源目录成功列出时比较，避免网络/认证问题导致误删。
            source_dirs = {entry.name for entry in entries if entry.is_dir}
            orphan_dirs = orphan_cache_dirs(listing, source_dirs)
            if orphan_dirs:
                if dry_run:
                    for directory in orphan_dirs:
                        log(f"  待删除无效缓存目录（源文件夹已删除）：{directory.name}")
                else:
                    removed_dirs = 0
                    for directory in orphan_dirs:
                        if delete_cache_dir(cache_client, directory):
                            removed_dirs += 1
                    if removed_dirs:
                        stats.bump(removed=removed_dirs)
                        log(f"  已删除 {removed_dirs} 个无效缓存目录（源文件夹已删除）")

            if not videos:
                continue

            todo: list[Resource] = []
            skipped_here = 0
            failed_here = 0
            existing_label = "雪碧图" if mode == "sprite" else "缩略图"
            for video in videos:
                if mode == "sprite":
                    # 雪碧图与缩略图的失败记录互不影响：只看雪碧图文件是否存在，
                    # 按格子判断，改了 --sprite-grid 会重新生成。
                    if sprite_grid in listing.sprites.get(video.name, ()):
                        skipped_here += 1
                        stale = stale_sprite_files(listing, video.name, sprite_grid)
                        if stale:
                            if dry_run:
                                log(f"  待清理旧格子雪碧图 {len(stale)} 个：{video.name}")
                            else:
                                removed_here = sum(
                                    1 for resource in stale if delete_thumbnail(cache_client, resource)
                                )
                                if removed_here:
                                    stats.bump(removed=removed_here)
                                    log(f"  已清理旧格子雪碧图 {removed_here} 个：{video.name}")
                    else:
                        todo.append(video)
                    continue
                stale = listing.failures.get(video.name)
                stored = store.has(video.url) if store is not None else False
                if video.name in listing.frames:
                    # 已有缩略图：顺带清掉可能残留的失败标记和本地失败记录
                    if stale is not None:
                        delete_marker(cache_client, stale)
                        log(f"  已有{existing_label}，清除过期失败标记 {stale.name}")
                    if store is not None:
                        store.remove(video.url)
                    skipped_here += 1
                    continue
                if stale is not None or stored:
                    failed_here += 1
                    continue
                todo.append(video)
            stats.bump(skipped=skipped_here, skipped_failed=failed_here)
            if limit is not None:
                remaining = max(0, limit - submitted)
                todo = todo[:remaining]
            if not todo:
                log(f"[第 {stats.folders} 个文件夹] {display_url(folder)} · {len(videos)} 个视频均已有{existing_label}或失败记录")
                continue

            log(
                f"[第 {stats.folders} 个文件夹] {display_url(folder)} · "
                f"视频 {len(videos)} 个 · 已有 {skipped_here} 个 · "
                f"失败跳过 {failed_here} 个 · 待处理 {len(todo)} 个"
            )
            show_status(folder, 0, len(todo))
            if dry_run:
                for video in todo:
                    log(f"  待处理：{video.name}")
                submitted += len(todo)
                continue

            try:
                cache_client.ensure_tree(mirror_dir, cache_root)
            except WebDavError as exc:
                for video in todo:
                    stats.add_failure(video.url, f"创建缓存目录失败：{exc}")
                log(f"创建缓存目录失败 {display_url(mirror_dir)}：{exc}")
                continue

            submitted += len(todo)

            started_at: dict[str, float] = {}

            def handle(video: Resource) -> tuple[str, float | None]:
                started_at[video.url] = time.monotonic()
                task = tracker.new_task(video.name)
                try:
                    return _handle_with_task(video, task)
                finally:
                    task.finish()

            def _handle_with_task(
                video: Resource, task: TaskProgress
            ) -> tuple[str, float | None]:
                if mode == "sprite":
                    return scrape_one_sprite(
                        video,
                        folder,
                        mirror_dir,
                        cache_root,
                        cache_client,
                        ffmpeg,
                        ffprobe,
                        source_token,
                        insecure,
                        sprite_grid[0],
                        sprite_grid[1],
                        sprite_width,
                        retries,
                        limiter,
                        probe_timeout=probe_timeout,
                        extract_timeout=extract_timeout,
                        source_client=source_client,
                        stall_timeout=stall_timeout,
                        min_duration=sprite_min_duration,
                        sprite_index=sprite_index,
                        sprite_window=sprite_window,
                        unsupported_codecs=skip_codecs,
                        task=task,
                    )
                return scrape_one(
                    video,
                    folder,
                    mirror_dir,
                    cache_root,
                    cache_client,
                    ffmpeg,
                    ffprobe,
                    source_token,
                    insecure,
                    percent,
                    width,
                    fallback_seconds,
                    retries,
                    limiter,
                    probe_timeout=probe_timeout,
                    extract_timeout=extract_timeout,
                    fallback_retry=fallback_retry,
                    source_client=source_client,
                    stall_timeout=stall_timeout,
                    window_fallback=window_fallback,
                    task=task,
                )

            done_count = 0
            executor = ThreadPoolExecutor(max_workers=max(1, jobs))
            futures: dict = {}
            completed = False
            try:
                for video in todo:
                    if runtime.cancel_event.is_set():
                        break
                    futures[executor.submit(handle, video)] = video
                for future in as_completed(futures):
                    video = futures[future]
                    done_count += 1
                    elapsed = time.monotonic() - started_at.get(video.url, time.monotonic())
                    stats.add_elapsed(elapsed)
                    show_status(folder, done_count, len(todo))
                    try:
                        filename, duration = future.result()
                        stats.bump(generated=1)
                        server_streak = 0
                        suffix = "" if duration is None else f" · {duration:.0f}s"
                        log(
                            f"  {green('✓')} [{done_count}/{len(todo)}] {filename}{suffix}"
                            f" · 用时 {elapsed:.1f}s"
                        )
                        log_success(
                            f"[{done_count}/{len(todo)}] {filename}{suffix} · 用时 {elapsed:.1f}s"
                            f" · {display_url(folder)} · {video.url}"
                        )
                        # 另一个设备可能刚写过标记：成功后把它清掉。
                        # 雪碧图模式不动缩略图的失败状态。
                        if mode != "sprite":
                            stale = listing.failures.get(video.name)
                            if stale is not None:
                                delete_marker(cache_client, stale)
                            if store is not None:
                                store.remove(video.url)
                        else:
                            removed_here = cleanup_stale_sprites(
                                cache_client, listing, video.name, sprite_grid, filename
                            )
                            if removed_here:
                                stats.bump(removed=removed_here)
                                log(f"  已清理旧格子雪碧图 {removed_here} 个：{video.name}")
                    except VideoSkipped as exc:
                        # 时长低于雪碧图下限：主动跳过，不写失败标记/本地失败记录，
                        # 下次运行仍会重新判断（调整阈值后即可处理）。
                        stats.bump(skipped_short=1)
                        server_streak = 0
                        log(
                            f"  {dim('已跳过')} [{done_count}/{len(todo)}] {video.name}：{exc}"
                            f" · 用时 {elapsed:.1f}s"
                        )
                    except VideoUnsupported as exc:
                        # 编码不在支持列表：主动跳过，不计失败、不写失败标记
                        stats.bump(skipped_unsupported=1)
                        server_streak = 0
                        log(
                            f"  {dim('已跳过')} [{done_count}/{len(todo)}] {video.name}：{exc}"
                            f" · 用时 {elapsed:.1f}s"
                        )
                    except VideoError as exc:
                        stats.add_failure(video.url, str(exc))
                        reason = exc.reason
                        details = collect_failure_details(
                            exc,
                            video,
                            folder,
                            mirror_dir,
                            mode,
                            elapsed,
                            extra={"time": utc_stamp()},
                        )
                        if mode == "sprite":
                            # 雪碧图不写失败标记/本地记录：下次运行只要还没有雪碧图就会重试，
                            # 也不会污染缩略图模式的失败状态。详细日志仍然会完整记录。
                            log(
                                f"  {red('✗')} [{done_count}/{len(todo)}] {video.name}："
                                f"{failure_label(reason)}（{exc}）· 未写失败标记，下次会重新尝试"
                                f" · 用时 {elapsed:.1f}s"
                            )
                            log_failure(
                                f"[{done_count}/{len(todo)}] {video.name} · "
                                f"{failure_label(reason)}（{reason}）· 用时 {elapsed:.1f}s"
                                f" · {display_url(folder)} · {video.url}"
                            )
                            log_failure_details(details)
                            if reason == "server":
                                server_streak += 1
                                if server_streak >= server_streak_limit:
                                    _abort_on_server_errors(server_streak)
                                    break
                            else:
                                server_streak = 0
                            continue
                        if store is not None:
                            store.record(
                                video.url,
                                video.name,
                                folder,
                                mirror_dir,
                                reason,
                                str(exc),
                                reason in RECORDED_FAILURES,
                                mode=mode,
                                details=details,
                            )
                            stats.bump(recorded_local=1)
                        if reason in RECORDED_FAILURES:
                            try:
                                write_failure_marker(
                                    cache_client,
                                    mirror_dir,
                                    cache_root,
                                    video.name,
                                    reason,
                                    str(exc),
                                    listing.failures.get(video.name),
                                )
                                stats.bump(recorded=1)
                                note = f"已写入 {marker_file_name(video.name, reason)}"
                            except WebDavError as marker_error:
                                note = f"写入失败标记失败：{marker_error}"
                        else:
                            note = "临时失败，不写 App 标记"
                        if store is not None:
                            note += f"，已记录到 {DEFAULT_FAILED.name}，后续运行会跳过"
                        log(
                            f"  {red('✗')} [{done_count}/{len(todo)}] {video.name}："
                            f"{failure_label(reason)}（{exc}）· {note} · 用时 {elapsed:.1f}s"
                        )
                        log_failure(
                            f"[{done_count}/{len(todo)}] {video.name} · "
                            f"{failure_label(reason)}（{reason}）· 用时 {elapsed:.1f}s"
                            f" · {display_url(folder)} · {video.url}"
                        )
                        log_failure_details(details)
                        if reason == "server":
                            server_streak += 1
                            if server_streak >= server_streak_limit:
                                _abort_on_server_errors(server_streak)
                                break
                        else:
                            server_streak = 0
                    except Exception as exc:  # noqa: BLE001
                        stats.add_failure(video.url, str(exc))
                        details = collect_failure_details(
                            exc,
                            video,
                            folder,
                            mirror_dir,
                            mode,
                            elapsed,
                            extra={"time": utc_stamp()},
                        )
                        if mode == "sprite":
                            log(
                                f"  {red('✗')} [{done_count}/{len(todo)}] {video.name}：{exc}"
                                f" · 未写失败标记，下次会重新尝试 · 用时 {elapsed:.1f}s"
                            )
                            log_failure(
                                f"[{done_count}/{len(todo)}] {video.name} · 未知错误"
                                f"（{exc}）· 用时 {elapsed:.1f}s"
                                f" · {display_url(folder)} · {video.url}"
                            )
                            log_failure_details(details)
                            continue
                        if store is not None:
                            store.record(
                                video.url,
                                video.name,
                                folder,
                                mirror_dir,
                                "unknown",
                                str(exc),
                                False,
                                mode=mode,
                                details=details,
                            )
                            stats.bump(recorded_local=1)
                        note = f"，已记录到 {DEFAULT_FAILED.name}" if store is not None else ""
                        log(
                            f"  {red('✗')} [{done_count}/{len(todo)}] {video.name}：{exc}{note}"
                            f" · 用时 {elapsed:.1f}s"
                        )
                        log_failure(
                            f"[{done_count}/{len(todo)}] {video.name} · 未知错误"
                            f"（{exc}）· 用时 {elapsed:.1f}s"
                            f" · {display_url(folder)} · {video.url}"
                        )
                        log_failure_details(details)
                completed = True
            finally:
                if completed and not runtime.cancel_event.is_set():
                    executor.shutdown(wait=True)
                else:
                    # Ctrl+C：取消未开始的任务并杀掉正在运行的 ffmpeg，避免等所有排队视频跑完
                    runtime.cancel_running()
                    for future in futures:
                        future.cancel()
                    executor.shutdown(wait=False)

        if stats.removed:
            log(f"本次删除 {stats.removed} 个无效文件/目录（源视频或源文件夹已删除，或旧格子雪碧图）。")
        if stats.recorded:
            log(f"本次写入 {stats.recorded} 个 App 失败标记，后续运行会自动跳过。")
        if stats.recorded_local:
            log(
                f"本次记录 {stats.recorded_local} 个失败视频到 {DEFAULT_FAILED.name}，"
                "后续运行会自动跳过；可用重试脚本或 --retry-failed 单独重试。"
            )
        return stats

    try:
        return scan()
    finally:
        tracker.stop()
        board.done()
        if runtime.board is board:
            runtime.board = None
