"""缓存目录中的缩略图、失败标记与上传辅助。"""
from __future__ import annotations

import time
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .console import log
from .constants import (
    DURATION_PREFIX,
    FAILURE_ENUM_NAMES,
    FAILURE_NAME,
    FAILURE_SUFFIX,
)
from .errors import WebDavError
from .urls import (
    normalize_folder,
    quote_name,
    same_location,
    split_sprite_suffix,
)
from .webdav import Resource, WebDav

# ---------------------------------------------------------------------------
# 缓存目录中的缩略图与失败标记
# ---------------------------------------------------------------------------


@dataclass
class CacheListing:
    # 已有普通缩略图的视频名（同时接受带时长前缀与原始名两种解释）
    frames: set[str] = field(default_factory=set)
    # 已有雪碧图的视频名 -> 该视频存在的所有格子（同样接受两种解释）
    sprites: dict[str, set[tuple[int, int]]] = field(default_factory=dict)
    # 缓存目录中的 .jpg 文件，用于清理源视频已删除的无效缩略图/雪碧图
    thumbnails: list[Resource] = field(default_factory=list)
    # 雪碧图文件：视频名 -> [(格子, 文件资源)]，用于清理旧格子
    sprite_files: dict[str, list[tuple[tuple[int, int], Resource]]] = field(default_factory=dict)
    # 缓存镜像目录里的子目录，用于清理源子文件夹已删除的缓存
    dirs: list[Resource] = field(default_factory=list)
    # 失败标记：视频名 -> 标记文件资源
    failures: dict[str, Resource] = field(default_factory=dict)


def cache_listing(client: WebDav, mirror_url: str) -> CacheListing:
    """一次 PROPFIND 同时读出缩略图和失败标记，与 App 的做法一致。"""
    listing = CacheListing()
    try:
        entries = client.list(mirror_url)
    except WebDavError as exc:
        if exc.status in (404, 409):
            return listing
        raise
    for entry in entries:
        if entry.is_dir:
            listing.dirs.append(entry)
            continue
        if entry.name.lower().endswith(".jpg"):
            base = entry.name[:-4]
            if not base:
                continue
            plain, sprite = split_sprite_suffix(base)
            if sprite is not None:
                listing.sprites.setdefault(plain, set()).add(sprite)
                listing.sprite_files.setdefault(plain, []).append((sprite, entry))
                match = DURATION_PREFIX.match(plain)
                if match:
                    rest = plain[match.end():]
                    if rest:
                        listing.sprites.setdefault(rest, set()).add(sprite)
                        listing.sprite_files.setdefault(rest, []).append((sprite, entry))
            else:
                listing.frames.add(plain)
                match = DURATION_PREFIX.match(plain)
                if match:
                    rest = plain[match.end():]
                    if rest:
                        listing.frames.add(rest)
            listing.thumbnails.append(entry)
            continue
        match = FAILURE_NAME.match(entry.name)
        if match and match.group(1):
            listing.failures[match.group(1)] = entry
    return listing


def thumbnail_video_names(thumbnail_name: str) -> tuple[str, ...]:
    """缩略图文件名可能对应的源视频名。

    缓存名是 `HH.MM.SS_<视频名>.jpg`；如果视频名本身已带时长前缀，
    缓存名不会再叠加。所以去掉 `.jpg` 后，带前缀和不带前缀两种解释都要考虑。
    """
    if not thumbnail_name.lower().endswith(".jpg"):
        return ()
    base = thumbnail_name[:-4]
    if not base:
        return ()
    base, _ = split_sprite_suffix(base)
    names = [base]
    match = DURATION_PREFIX.match(base)
    if match:
        rest = base[match.end():]
        if rest:
            names.append(rest)
    return tuple(names)


def _name_key(name: str) -> str:
    """中文/Unicode 归一化后的比较键。"""
    return unicodedata.normalize("NFC", name).casefold()


def thumbnail_is_orphan(thumbnail_name: str, file_names: set[str]) -> bool:
    """缩略图对应的源视频是否已不存在（file_names 为已归一化的源目录文件名）。"""
    return not any(_name_key(name) in file_names for name in thumbnail_video_names(thumbnail_name))


def delete_thumbnail(client: WebDav, thumbnail: Resource) -> bool:
    """删除无效缩略图；404 视为已删除。"""
    try:
        client.delete(thumbnail.url)
        return True
    except WebDavError as exc:
        if exc.status == 404:
            return True
        log(f"删除无效缩略图失败 {thumbnail.name}：{exc}")
        return False


def orphan_cache_dirs(listing: CacheListing, source_dir_names: set[str]) -> list[Resource]:
    """找出缓存镜像目录里、源目录已经不存在的子目录。

    source_dir_names 是源目录直接子目录名；比较时会做 Unicode NFC + casefold。
    只应在源目录成功列出时调用，避免网络/认证问题导致误删。
    """
    normalized = {_name_key(name) for name in source_dir_names}
    return [
        entry
        for entry in listing.dirs
        if _name_key(entry.name) not in normalized
    ]


def _delete_file(client: WebDav, resource: Resource) -> bool:
    """删除缓存文件；404 视为已删除。"""
    try:
        client.delete(resource.url)
        return True
    except WebDavError as exc:
        if exc.status == 404:
            return True
        log(f"删除无效缓存文件失败 {resource.name}：{exc}")
        return False


def delete_cache_dir(client: WebDav, resource: Resource) -> bool:
    """删除无效缓存目录；服务器不支持递归 DELETE 时逐项删除。

    只在源目录成功列出、并确认该缓存子目录没有对应源目录时调用。
    """
    if not resource.is_dir:
        return _delete_file(client, resource)

    try:
        client.delete(resource.url)
        return True
    except WebDavError as exc:
        if exc.status == 404:
            return True
        if exc.status in (401, 403):
            log(f"删除无效缓存目录失败 {resource.name}：{exc}")
            return False
        # 某些 WebDAV 不允许 DELETE collection，改为逐项删除后再删目录

    try:
        children = client.list(resource.url)
    except WebDavError as exc:
        if exc.status == 404:
            return True
        log(f"读取无效缓存目录失败 {resource.name}：{exc}")
        return False

    ok = True
    for child in children:
        if child.is_dir:
            ok = delete_cache_dir(client, child) and ok
        else:
            ok = _delete_file(client, child) and ok
    if not ok:
        return False

    try:
        client.delete(resource.url)
        return True
    except WebDavError as exc:
        if exc.status == 404:
            return True
        log(f"删除无效缓存目录失败 {resource.name}：{exc}")
        return False


def stale_sprite_files(
    listing: CacheListing,
    video_name: str,
    keep_grid: tuple[int, int],
    keep_filename: str | None = None,
) -> list[Resource]:
    """找出该视频需要清理的旧雪碧图。

    keep_filename 不为空时只保留这个文件（刚生成的图），其余同视频的雪碧图都算旧图；
    否则保留所有 keep_grid 格子的文件，清理其他格子。
    """
    stale: list[Resource] = []
    seen: set[str] = set()
    for grid, resource in listing.sprite_files.get(video_name, ()):
        if resource.url in seen:
            continue
        seen.add(resource.url)
        if keep_filename is not None:
            if resource.name == keep_filename:
                continue
        elif grid == keep_grid:
            continue
        stale.append(resource)
    return stale


def cleanup_stale_sprites(
    client: WebDav,
    listing: CacheListing,
    video_name: str,
    keep_grid: tuple[int, int],
    keep_filename: str | None = None,
) -> int:
    """删除旧格子雪碧图，返回成功删除的数量。"""
    removed = 0
    for resource in stale_sprite_files(listing, video_name, keep_grid, keep_filename):
        if delete_thumbnail(client, resource):
            removed += 1
    return removed


def cache_listing_with_retry(client: WebDav, mirror_url: str, attempts: int = 2) -> CacheListing:
    """读取缓存目录；临时错误重试一次，认证错误不重试。"""
    last_error: WebDavError | None = None
    for attempt in range(max(1, attempts)):
        try:
            return cache_listing(client, mirror_url)
        except WebDavError as exc:
            if exc.status in (401, 403):
                raise
            last_error = exc
            if attempt + 1 < attempts:
                time.sleep(1.0)
    assert last_error is not None
    raise last_error


def marker_file_name(video_name: str, reason: str) -> str:
    return f"{video_name}{FAILURE_SUFFIX}-{reason.lower()}"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"


def format_stamp(stamp: str) -> str:
    value = (stamp or "").strip()
    if not value:
        return ""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone().strftime("%Y-%m-%d %H:%M")


def shorten(text: str, limit: int = 140) -> str:
    value = " ".join((text or "").split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


def shorten_left(text: str, limit: int = 140) -> str:
    """保留字符串结尾，用于状态行显示长 URL 时仍能看出是哪一级目录。"""
    value = text or ""
    return value if len(value) <= limit else "…" + value[-(limit - 1):]


def put_ensured(client: WebDav, file_url: str, data: bytes, content_type: str, root: str) -> None:
    """上传文件；目录被服务器上删除时重建后重试一次（与 App 的 _putEnsured 一致）。"""
    try:
        client.put_bytes(file_url, data, content_type)
    except WebDavError as exc:
        if exc.status not in (404, 409):
            raise
        folder = file_url.rsplit("/", 1)[0] + "/"
        client.ensure_tree(folder, root, force=True)
        client.put_bytes(file_url, data, content_type)


def write_failure_marker(
    client: WebDav,
    mirror_dir: str,
    cache_root: str,
    video_name: str,
    reason: str,
    detail: str,
    previous: Resource | None = None,
) -> tuple[str, str]:
    """写入 `<视频名>.failed-<原因>`，格式与 App 一致：
    第一行 UTC 时间，第二行 Dart 枚举名，之后是详情。"""
    name = marker_file_name(video_name, reason)
    url = normalize_folder(mirror_dir) + quote_name(name)
    enum_name = FAILURE_ENUM_NAMES.get(reason, reason)
    content = f"{utc_stamp()}\n{enum_name}\n{detail}"
    put_ensured(client, url, content.encode("utf-8"), "text/plain; charset=utf-8", cache_root)
    if previous is not None and not same_location(previous.url, url):
        try:
            client.delete(previous.url)
        except WebDavError as exc:
            if exc.status != 404:
                log(f"删除旧失败标记失败 {previous.name}：{exc}")
    return url, name


def delete_marker(client: WebDav, marker: Resource) -> bool:
    try:
        client.delete(marker.url)
        return True
    except WebDavError as exc:
        if exc.status == 404:
            return True
        log(f"删除失败标记失败 {marker.name}：{exc}")
        return False
