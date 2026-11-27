"""URL、缓存路径与文件名规则（与 Dart 端保持一致）。"""
from __future__ import annotations

import math
import os
import re
import secrets
from urllib import parse

from .constants import (
    DURATION_PREFIX,
    MAX_SPRITE_FRAMES,
    SPRITE_END,
    SPRITE_START,
    SPRITE_TAG,
    VIDEO_EXT_MIME,
)

# ---------------------------------------------------------------------------
# URL / 缓存路径规则（与 Dart 端保持一致）
# ---------------------------------------------------------------------------


def normalize_folder(url: str) -> str:
    return url if url.endswith("/") else url + "/"


def quote_name(name: str) -> str:
    # 与 Dart 的 Uri.encodeComponent 保留字符一致
    return parse.quote(name, safe="-_.!~*'()")


def display_url(url: str) -> str:
    """把 URL 路径里的百分号编码还原成可读文字（仅用于显示，请求仍用原 URL）。"""
    if not isinstance(url, str) or "%" not in url:
        return url
    try:
        return parse.unquote(url, errors="replace")
    except (TypeError, ValueError):
        return url


def child_url(folder_url: str, name: str, is_dir: bool) -> str:
    base = normalize_folder(folder_url)
    return f"{base}{quote_name(name)}{'/' if is_dir else ''}"


def relative_path(folder_url: str, server_base_url: str) -> str:
    """源文件夹相对于 WebDAV 服务根的路径，保留百分号编码。"""
    folder_path = parse.urlsplit(normalize_folder(folder_url)).path
    base_path = parse.urlsplit(normalize_folder(server_base_url)).path
    if base_path and folder_path.startswith(base_path):
        return folder_path[len(base_path):]
    return folder_path.lstrip("/")


def mirror_folder(cache_root: str, source_folder: str, source_base_url: str) -> str:
    return normalize_folder(cache_root) + relative_path(source_folder, source_base_url)


def parent_folder(url: str, base_url: str) -> str | None:
    url = normalize_folder(url)
    base = normalize_folder(base_url)
    u = parse.urlsplit(url)
    b = parse.urlsplit(base)
    if len(u.path.rstrip("/")) <= len(b.path.rstrip("/")):
        return None
    path = u.path.rstrip("/")
    parent_path = path[: path.rfind("/") + 1]
    if len(parent_path) < len(b.path):
        parent_path = b.path
    return parse.urlunsplit((u.scheme, u.netloc, parent_path, "", ""))


def _url_key(url: str) -> tuple[str, str, str]:
    u = parse.urlsplit(normalize_folder(url))
    scheme = u.scheme.lower()
    host = (u.hostname or "").lower()
    try:
        port = u.port
    except ValueError:
        port = None
    if port is None:
        port = 80 if scheme == "http" else 443 if scheme == "https" else None
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    netloc = host if port is None else f"{host}:{port}"
    return (scheme, netloc, parse.unquote(u.path).rstrip("/"))


def same_location(a: str, b: str) -> bool:
    return _url_key(a) == _url_key(b)


def is_under(url: str, root: str) -> bool:
    u = _url_key(url)
    r = _url_key(root)
    return u[0] == r[0] and u[1] == r[1] and (u[2] == r[2] or u[2].startswith(r[2] + "/"))


def duration_prefix(duration_seconds: float) -> str:
    total = int(math.floor(duration_seconds + 0.5))
    hours = total // 3600
    minutes = (total % 3600) // 60
    seconds = total % 60
    return f"{hours:02d}.{minutes:02d}.{seconds:02d}_"


def cache_base_name(video_name: str, duration_seconds: float | None) -> str:
    if DURATION_PREFIX.match(video_name):
        return video_name
    if duration_seconds is None or duration_seconds <= 0:
        return video_name
    return f"{duration_prefix(duration_seconds)}{video_name}"


def split_sprite_suffix(base: str) -> tuple[str, tuple[int, int] | None]:
    """把 00.10.00_vid.mp4~5x5 拆成 ('00.10.00_vid.mp4', (5, 5))。

    没有 ~列x行 后缀时原样返回，sprite 为 None。
    """
    match = SPRITE_TAG.search(base)
    if match is None:
        return base, None
    return base[:match.start()], (int(match.group(1)), int(match.group(2)))


def parse_sprite_grid(text: str) -> tuple[int, int]:
    """解析 5x5 这类格子设置，非法时抛 ValueError。"""
    match = re.fullmatch(r"\s*(\d{1,2})\s*[xX×]\s*(\d{1,2})\s*", text or "")
    if match is None:
        raise ValueError("雪碧图格子格式应为 列x行，例如 5x5")
    cols, rows = int(match.group(1)), int(match.group(2))
    if cols < 1 or rows < 1 or cols * rows < 2 or cols * rows > MAX_SPRITE_FRAMES:
        raise ValueError(f"雪碧图格子行列都必须大于 0，且总帧数在 2–{MAX_SPRITE_FRAMES} 之间")
    return cols, rows


def sprite_filename(
    video_name: str, duration_seconds: float | None, cols: int, rows: int
) -> str:
    """雪碧图缓存名：在普通缩略图名字后加 ~列x行.jpg。"""
    return f"{cache_base_name(video_name, duration_seconds)}~{cols}x{rows}.jpg"


def sprite_positions(duration: float, count: int) -> list[float]:
    """在视频 10%–95% 区间内均匀取 count 个时间点（含两端）。"""
    start = duration * SPRITE_START
    end = duration * SPRITE_END
    if count <= 1:
        return [(start + end) / 2.0]
    step = (end - start) / (count - 1)
    return [start + step * index for index in range(count)]


def video_mime(name: str, reported: str | None) -> str | None:
    if reported and reported.lower().startswith("video/"):
        return reported
    ext = os.path.splitext(name.lower())[1]
    return VIDEO_EXT_MIME.get(ext)


def is_avi_url(url: str) -> bool:
    return parse.urlsplit(url).path.lower().endswith(".avi")


def is_hls_url(url: str) -> bool:
    """HLS 播放列表（.m3u8）：ffmpeg 读取列表后再按需拉取分片。"""
    return parse.urlsplit(url).path.lower().endswith(".m3u8")


def cache_bust(url: str) -> str:
    """给远程地址追加随机查询参数。

    IDM 等下载器会按 URL 末尾的扩展名接管 .ts/.avi/.mp4 请求（表现为弹下载框、
    并把请求拦截成 204/403）。带上查询参数后扩展名不再位于地址末尾，下载器就
    不会抢走 ffmpeg / urllib 发出的请求；AList 会忽略这个参数。
    """
    if not url.lower().startswith(("http://", "https://")):
        return url
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}purer={secrets.token_hex(4)}"
