"""失败标记的扫描、本地失败记录与交互式重试。"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
from pathlib import Path
from urllib import parse

from . import runtime
from .cache import (
    format_stamp,
    shorten,
    utc_stamp,
    write_failure_marker,
)
from .console import bold, dim, green, hr, log, log_failure, log_success, red, yellow
from .constants import (
    DEFAULT_MIN_VIDEO_SECONDS,
    DEFAULT_SPRITE_MIN_DURATION,
    DEFAULT_SPRITE_WIDTH,
    EXTRACT_TIMEOUT,
    FAILURE_NAME,
    PROBE_TIMEOUT,
    RECORDED_FAILURES,
    STALL_TIMEOUT,
)
from .errors import VideoError, VideoSkipped, VideoUnsupported, failure_label
from .failure_report import collect_failure_details, log_failure_details
from .pacing import hold_min_seconds
from .rate import RateLimiter
from .scrape import scrape_one, scrape_one_sprite
from .urls import (
    _url_key,
    display_url,
    child_url,
    is_under,
    normalize_folder,
    relative_path,
)
from .webdav import Resource, WebDav, WebDavError

# ---------------------------------------------------------------------------
# 失败标记的扫描与重试
# ---------------------------------------------------------------------------


@dataclass
class FailedMarker:
    video_url: str
    name: str
    folder: str
    mirror_dir: str
    marker_name: str
    marker_url: str
    reason: str
    timestamp: str = ""
    detail: str = ""


class FailureStore:
    """本地失败记录：所有失败视频（含临时失败）都写入 failed_videos.json。

    普通刮削据此自动跳过；重试脚本据此重试；成功或发现已有缩略图后自动移除。
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._items: dict[str, dict] = self._load()

    def _load(self) -> dict[str, dict]:
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, json.JSONDecodeError):
            return {}
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, dict):
            return {}
        result: dict[str, dict] = {}
        for url, item in items.items():
            if isinstance(url, str) and isinstance(item, dict):
                result[url] = item
        return result

    def _save_locked(self) -> None:
        data = {"version": 1, "items": self._items}
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
                fh.write("\n")
            os.replace(tmp, self.path)
        except OSError as exc:
            log(f"保存失败记录 {self.path.name} 失败（不影响刮削）：{exc}")
            try:
                tmp.unlink()
            except OSError:
                pass

    def record(
        self,
        video_url: str,
        name: str,
        folder: str,
        mirror_dir: str,
        reason: str,
        detail: str,
        permanent: bool,
        *,
        mode: str = "thumb",
        details: dict | None = None,
    ) -> None:
        item = {
            "name": name,
            "folder": normalize_folder(folder),
            "mirror_dir": normalize_folder(mirror_dir),
            "reason": str(reason or "unknown").lower(),
            "permanent": bool(permanent),
            "detail": shorten(detail, 1000),
            "time": utc_stamp(),
            "mode": mode,
        }
        if details:
            # 完整的失败详情：阶段、每次尝试的命令/退出码/错误输出，供事后排查
            item["details"] = details
            item["phase"] = details.get("phase") or ""
            item["size"] = details.get("size")
            item["elapsed"] = details.get("elapsed")
        with self._lock:
            self._items[video_url] = item
            self._save_locked()

    def remove(self, video_url: str) -> None:
        with self._lock:
            if self._items.pop(video_url, None) is not None:
                self._save_locked()

    def get(self, video_url: str) -> dict | None:
        with self._lock:
            item = self._items.get(video_url)
            return dict(item) if item is not None else None

    def has(self, video_url: str) -> bool:
        with self._lock:
            return video_url in self._items

    def to_markers(self) -> list[FailedMarker]:
        with self._lock:
            items = list(self._items.items())
        markers: list[FailedMarker] = []
        for video_url, item in items:
            name = item.get("name")
            folder = item.get("folder")
            mirror_dir = item.get("mirror_dir")
            if not all(isinstance(value, str) and value for value in (name, folder, mirror_dir)):
                continue
            markers.append(
                FailedMarker(
                    video_url=video_url,
                    name=name,
                    folder=normalize_folder(folder),
                    mirror_dir=normalize_folder(mirror_dir),
                    marker_name="",
                    marker_url="",
                    reason=str(item.get("reason") or "unknown").lower(),
                    timestamp=str(item.get("time") or ""),
                    detail=str(item.get("detail") or ""),
                )
            )
        return markers


def collect_failed_markers(
    cache_client: WebDav,
    cache_root: str,
    source_base: str,
    workers: int = 4,
) -> list[FailedMarker]:
    """并发遍历缓存根目录，收集所有 `<视频名>.failed-<原因>` 标记。"""
    root = normalize_folder(cache_root)
    found: list[FailedMarker] = []
    visited: set[tuple[str, str, str]] = {_url_key(root)}

    def scan_folder(folder: str) -> tuple[list[str], list[FailedMarker]]:
        children: list[str] = []
        local: list[FailedMarker] = []
        try:
            entries = cache_client.list(folder)
        except WebDavError as exc:
            if exc.status not in (404, 409):
                log(f"读取缓存目录失败 {display_url(folder)}：{exc}")
            return children, local
        for entry in entries:
            if entry.is_dir:
                children.append(entry.url)
                continue
            match = FAILURE_NAME.match(entry.name)
            if match is None or not match.group(1):
                continue
            video_name = match.group(1)
            reason = (match.group(2) or "unknown").lower()
            rel = relative_path(folder, root)
            source_folder = normalize_folder(
                parse.urljoin(normalize_folder(source_base), rel) if rel else source_base
            )
            local.append(
                FailedMarker(
                    video_url=child_url(source_folder, video_name, False),
                    name=video_name,
                    folder=source_folder,
                    mirror_dir=folder,
                    marker_name=entry.name,
                    marker_url=entry.url,
                    reason=reason,
                )
            )
        return children, local

    executor = ThreadPoolExecutor(max_workers=max(1, workers))
    futures: dict = {executor.submit(scan_folder, root): root}
    scanned = 0
    completed = False
    try:
        while futures:
            done, _ = wait(futures, return_when=FIRST_COMPLETED)
            for future in done:
                folder = futures.pop(future)
                scanned += 1
                try:
                    children, local = future.result()
                except Exception as exc:  # noqa: BLE001
                    log(f"读取缓存目录失败 {display_url(folder)}：{exc}")
                    continue
                found.extend(local)
                if scanned % 50 == 0:
                    log(f"  已扫描 {scanned} 个缓存目录，发现 {len(found)} 个失败标记…")
                for child in children:
                    child = normalize_folder(child)
                    key = _url_key(child)
                    if key in visited:
                        continue
                    visited.add(key)
                    futures[executor.submit(scan_folder, child)] = child
        completed = True
    finally:
        if completed and not runtime.cancel_event.is_set():
            executor.shutdown(wait=True)
        else:
            runtime.cancel_running()
            for future in futures:
                future.cancel()
            executor.shutdown(wait=False)
    found.sort(key=lambda m: (m.folder.lower(), m.name.lower()))
    return found


def collect_all_failures(
    cache_client: WebDav,
    cache_root: str,
    source_base: str,
) -> list[FailedMarker]:
    """合并缓存里的 App 失败标记与本地 failed_videos.json 记录。"""
    markers = collect_failed_markers(cache_client, cache_root, source_base)
    store = runtime.failure_store
    if store is not None:
        known = {_url_key(marker.video_url) for marker in markers}
        for marker in store.to_markers():
            key = _url_key(marker.video_url)
            if key in known:
                continue
            if not is_under(marker.mirror_dir, cache_root):
                continue
            if not is_under(marker.video_url, source_base):
                continue
            known.add(key)
            markers.append(marker)
        markers.sort(key=lambda m: (m.folder.lower(), m.name.lower()))
    return markers


def read_marker_info(client: WebDav, marker: FailedMarker) -> None:
    if not marker.marker_url:
        # 只有本地 failed_videos.json 记录，没有缓存标记文件
        return
    try:
        raw = client.get_bytes(marker.marker_url, timeout=30)
    except WebDavError:
        return
    lines = raw.decode("utf-8", "replace").splitlines()
    if lines:
        marker.timestamp = lines[0].strip()
    if len(lines) > 2:
        marker.detail = "\n".join(lines[2:]).strip()


def read_marker_info_all(client: WebDav, markers: list[FailedMarker]) -> None:
    """并发读取标记内容；读取失败保持为空，不影响重试。"""
    if len(markers) <= 1:
        for marker in markers:
            read_marker_info(client, marker)
        return
    executor = ThreadPoolExecutor(max_workers=min(8, len(markers)))
    futures = [executor.submit(read_marker_info, client, marker) for marker in markers]
    completed = False
    try:
        for future in futures:
            future.result()
        completed = True
    finally:
        if completed and not runtime.cancel_event.is_set():
            executor.shutdown(wait=True)
        else:
            runtime.cancel_running()
            for future in futures:
                future.cancel()
            executor.shutdown(wait=False)


@dataclass
class RetryContext:
    cache_client: WebDav
    cache_root: str
    ffmpeg: str
    ffprobe: str
    source_token: str | None
    insecure: bool
    percent: float
    width: int
    fallback_seconds: float
    retries: int
    limiter: RateLimiter
    probe_timeout: float = PROBE_TIMEOUT
    extract_timeout: float = EXTRACT_TIMEOUT
    fallback_retry: bool = True
    source_client: WebDav | None = None
    stall_timeout: float = STALL_TIMEOUT
    window_fallback: bool = True
    mode: str = "thumb"
    sprite_grid: tuple[int, int] = (3, 3)
    sprite_width: int = DEFAULT_SPRITE_WIDTH
    sprite_min_duration: float = DEFAULT_SPRITE_MIN_DURATION
    min_video_seconds: float = DEFAULT_MIN_VIDEO_SECONDS
    sprite_index: bool = True
    sprite_window: bool = True
    unsupported_codecs: frozenset[str] | None = None


def _select_markers(markers: list[FailedMarker], raw: str) -> list[FailedMarker]:
    selected: list[FailedMarker] = []
    for token in re.split(r"[\s,]+", raw):
        if not token.isdigit():
            continue
        index = int(token)
        if 1 <= index <= len(markers):
            selected.append(markers[index - 1])
    unique: list[FailedMarker] = []
    seen: set[int] = set()
    for marker in selected:
        if id(marker) in seen:
            continue
        seen.add(id(marker))
        unique.append(marker)
    return unique


def _retry_one(ctx: RetryContext, marker: FailedMarker) -> bool:
    """重试一个失败项。

    与旧行为不同：先尝试，成功后才删除旧标记；永久失败覆盖写回，临时失败保留
    原标记。这样网络抖动或进程中途退出不会让失败记录悄悄消失。
    """
    old_url = marker.marker_url
    old_name = marker.marker_name
    old_reason = marker.reason
    old_timestamp = marker.timestamp
    old_detail = marker.detail
    started = time.monotonic()
    try:
        video = Resource(url=marker.video_url, name=marker.name, is_dir=False)
        if ctx.mode == "sprite":
            filename, duration = scrape_one_sprite(
                video,
                marker.folder,
                marker.mirror_dir,
                ctx.cache_root,
                ctx.cache_client,
                ctx.ffmpeg,
                ctx.ffprobe,
                ctx.source_token,
                ctx.insecure,
                ctx.sprite_grid[0],
                ctx.sprite_grid[1],
                ctx.sprite_width,
                ctx.retries,
                ctx.limiter,
                probe_timeout=ctx.probe_timeout,
                extract_timeout=ctx.extract_timeout,
                source_client=ctx.source_client,
                stall_timeout=ctx.stall_timeout,
                min_duration=ctx.sprite_min_duration,
                sprite_index=ctx.sprite_index,
                sprite_window=ctx.sprite_window,
                unsupported_codecs=ctx.unsupported_codecs,
                thumb_width=ctx.width,
            )
        else:
            filename, duration = scrape_one(
                video,
                marker.folder,
                marker.mirror_dir,
                ctx.cache_root,
                ctx.cache_client,
                ctx.ffmpeg,
                ctx.ffprobe,
                ctx.source_token,
                ctx.insecure,
                ctx.percent,
                ctx.width,
                ctx.fallback_seconds,
                ctx.retries,
                ctx.limiter,
                probe_timeout=ctx.probe_timeout,
                extract_timeout=ctx.extract_timeout,
                fallback_retry=ctx.fallback_retry,
                source_client=ctx.source_client,
                stall_timeout=ctx.stall_timeout,
                window_fallback=ctx.window_fallback,
            )
    except VideoSkipped as exc:
        # 时长不足被跳过：不是失败，保持原状态即可（雪碧图模式下本来也不写标记）。
        log(f"  {dim('已跳过')} {marker.name}：{exc}")
        return False
    except VideoUnsupported as exc:
        # 编码不在支持列表：主动跳过，不是失败
        log(f"  {dim('已跳过')} {marker.name}：{exc}")
        return False
    except Exception as exc:  # noqa: BLE001
        reason = exc.reason if isinstance(exc, VideoError) else "unknown"
        elapsed = time.monotonic() - started
        video = Resource(url=marker.video_url, name=marker.name, is_dir=False)
        details = collect_failure_details(
            exc,
            video,
            marker.folder,
            marker.mirror_dir,
            ctx.mode,
            elapsed,
            extra={"time": utc_stamp()},
        )
        if ctx.mode == "sprite":
            # 雪碧图模式不写失败标记/本地记录，下次直接重试
            log(
                f"  {red('✗')} {marker.name}：{failure_label(reason)}（{exc}）"
                f" · 未写失败标记 · 用时 {elapsed:.1f}s"
            )
            log_failure_details(details)
            return False
        if runtime.failure_store is not None:
            runtime.failure_store.record(
                marker.video_url,
                marker.name,
                marker.folder,
                marker.mirror_dir,
                reason,
                str(exc),
                reason in RECORDED_FAILURES,
                mode=ctx.mode,
                details=details,
            )
        if reason in RECORDED_FAILURES:
            marker.reason = reason
            marker.timestamp = utc_stamp()
            marker.detail = str(exc)
            previous = Resource(url=old_url, name=old_name, is_dir=False) if old_url else None
            try:
                url, name = write_failure_marker(
                    ctx.cache_client,
                    marker.mirror_dir,
                    ctx.cache_root,
                    marker.name,
                    reason,
                    str(exc),
                    previous,
                )
                marker.marker_url = url
                marker.marker_name = name
            except WebDavError as marker_error:
                # 新标记没写成功时保留旧标记的内容
                marker.marker_url = old_url
                marker.marker_name = old_name
                marker.reason = old_reason
                marker.timestamp = old_timestamp
                marker.detail = old_detail
                log(f"  写入失败标记失败：{marker_error}")
        else:
            # 临时失败：保留原标记，视频仍在失败列表里，下次可继续重试
            marker.reason = old_reason
            marker.timestamp = old_timestamp
            marker.detail = old_detail
        log(
            f"  {red('✗')} {marker.name}：{failure_label(reason)}（{exc}）"
            f" · 用时 {elapsed:.1f}s"
        )
        log_failure(
            f"[重试] {marker.name} · {failure_label(reason)}（{reason}）"
            f" · 用时 {elapsed:.1f}s · {display_url(marker.folder)} · {marker.video_url}"
        )
        log_failure_details(details)
        return False

    # 成功后才删除旧标记和本地失败记录；雪碧图模式不动缩略图的失败状态
    if ctx.mode != "sprite":
        if runtime.failure_store is not None:
            runtime.failure_store.remove(marker.video_url)
        if old_url:
            try:
                ctx.cache_client.delete(old_url)
            except WebDavError as exc:
                if exc.status != 404:
                    log(f"  删除失败标记失败 {old_name}：{exc}")
    suffix = "" if duration is None else f" · {duration:.0f}s"
    elapsed = time.monotonic() - started
    log(f"  {green('✓')} {filename}{suffix} · 用时 {elapsed:.1f}s")
    log_success(
        f"[重试] {filename}{suffix} · 用时 {elapsed:.1f}s"
        f" · {display_url(marker.folder)} · {marker.video_url}"
    )
    return True


def interactive_retry(
    ctx: RetryContext,
    markers: list[FailedMarker],
    limit: int | None = None,
    list_only: bool = False,
) -> None:
    """列出失败标记，按序号单独重试，或删除不想再尝试的标记。

    list_only=True 时只展示（用于 --dry-run --retry-failed）。
    limit 是本次最多真正尝试的数量，交互模式下跨多轮累计。
    """
    if not markers:
        print("没有记录的失败视频。")
        return

    def print_markers(items: list[FailedMarker]) -> None:
        items.sort(key=lambda m: (m.folder.lower(), m.name.lower()))
        print()
        hr("═")
        print(f"  {bold(red('失败视频'))} · {len(items)} 个 · 后续刮削默认跳过")
        hr("═")
        for index, marker in enumerate(items, 1):
            print(f"  {yellow(f'[{index}]')} {bold(marker.name)}")
            print(f"      {dim('文件夹')}  {display_url(marker.folder)}")
            print(f"      {dim('原因')}    {yellow(failure_label(marker.reason))}")
            if marker.timestamp:
                print(f"      {dim('上次')}    {format_stamp(marker.timestamp)}")
            if marker.detail:
                print(f"      {dim('详情')}    {shorten(marker.detail)}")

    if list_only:
        shown = markers[:limit] if limit is not None else markers
        read_marker_info_all(ctx.cache_client, shown)
        print_markers(shown)
        if limit is not None and len(markers) > len(shown):
            print(dim(f"  共 {len(markers)} 个失败记录，按 --limit 只显示前 {len(shown)} 个。"))
        print(dim("  dry-run：只列出失败记录，未重试、未上传。"))
        return

    read_marker_info_all(ctx.cache_client, markers)
    one_pass = not sys.stdin.isatty()
    attempted = 0

    def apply_limit(selected: list[FailedMarker]) -> list[FailedMarker]:
        if limit is None:
            return selected
        remaining = max(0, limit - attempted)
        if remaining <= 0:
            print(f"已达到 --limit {limit} 个。")
            return []
        if len(selected) > remaining:
            print(f"按 --limit 只处理前 {remaining} 个。")
            selected = selected[:remaining]
        return selected

    while markers:
        print_markers(markers)
        if one_pass:
            selected = list(markers)
        else:
            print()
            print(dim("  a 全部重试 · 1 3 5 只重试这些 · d 1 3 忽略并删除记录 · q 返回"))
            try:
                raw = input("请选择：").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if raw.lower() in ("q", ""):
                break
            if raw.lower().startswith("d"):
                chosen = _select_markers(markers, raw[1:].strip())
                if not chosen:
                    print("没有选中有效序号。")
                    continue
                chosen_ids = {id(marker) for marker in chosen}
                remaining: list[FailedMarker] = []
                for marker in markers:
                    if id(marker) not in chosen_ids:
                        remaining.append(marker)
                        continue
                    if marker.marker_url:
                        try:
                            ctx.cache_client.delete(marker.marker_url)
                        except WebDavError as exc:
                            if exc.status != 404:
                                print(f"  删除失败：{exc}")
                                remaining.append(marker)
                                continue
                    if runtime.failure_store is not None:
                        runtime.failure_store.remove(marker.video_url)
                    print(f"  已忽略：{marker.name}")
                markers[:] = remaining
                continue
            if raw.lower() in ("a", "all"):
                selected = list(markers)
            else:
                selected = _select_markers(markers, raw)
                if not selected:
                    print("没有选中有效序号。")
                    continue

        selected = apply_limit(selected)
        if not selected:
            break
        attempted += len(selected)
        selected_ids = {id(marker) for marker in selected}
        still_failed: list[FailedMarker] = []
        succeeded = 0
        for marker in selected:
            retry_started = time.monotonic()
            if _retry_one(ctx, marker):
                succeeded += 1
            else:
                still_failed.append(marker)
            # 与普通刮削一致：每个视频至少处理这么久，避免快速连续切换文件
            hold_min_seconds(retry_started, ctx.min_video_seconds)
        markers[:] = [marker for marker in markers if id(marker) not in selected_ids] + still_failed
        print(f"本轮：成功 {succeeded} · 失败 {len(selected) - succeeded} · 剩余记录 {len(markers)}")
        if one_pass:
            break
        if limit is not None and attempted >= limit:
            print(f"已达到 --limit {limit} 个，停止本次重试。")
            break

    if markers:
        print(f"仍有 {len(markers)} 个失败记录，下次运行会自动跳过。")
