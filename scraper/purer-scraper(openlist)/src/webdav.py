"""WebDAV 客户端（Basic 认证，标准库实现）。"""
from __future__ import annotations

import base64
import ssl
import threading
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from urllib import error, parse, request

from .constants import PROPFIND_BODY, USER_AGENT
from .console import log
from .errors import WebDavError
from .ffmpeg import is_riff_avi, parse_avi_duration
from .urls import _url_key, cache_bust, display_url, is_under, normalize_folder

# ---------------------------------------------------------------------------
# WebDAV 客户端（Basic 认证，标准库实现）
# ---------------------------------------------------------------------------


@dataclass
class Resource:
    url: str
    name: str
    is_dir: bool
    mime: str | None = None
    # PROPFIND 返回的文件大小；失败详情里用于判断是超大文件还是空文件
    size: int | None = None


class WebDav:
    def __init__(
        self,
        base_url: str,
        username: str = "",
        password: str = "",
        insecure: bool = False,
        timeout: int = 60,
        proxy: str | None = None,
    ) -> None:
        base_url = base_url.strip()
        if not base_url.lower().startswith(("http://", "https://")):
            raise ValueError("WebDAV 地址必须以 http:// 或 https:// 开头")
        self.base_url = normalize_folder(base_url)
        self.username = username
        self.password = password
        self.timeout = timeout
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        # 与手机端一致：默认直连，不自动使用系统 http_proxy；需要代理时用 --proxy
        proxy_map = {"http": proxy, "https": proxy} if proxy else {}
        self.opener = request.build_opener(
            request.ProxyHandler(proxy_map),
            request.HTTPSHandler(context=context),
        )
        token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        self.auth_header = f"Basic {token}" if (username or password) else None
        # 已确认存在的目录，避免每个文件夹都重复 MKCOL 一遍
        self._ensured: set[tuple[str, str, str]] = set()
        self._ensured_lock = threading.Lock()
        # 服务器是否支持 Range，按主机缓存；不支持时避免整文件顺序读取
        self._range_cache: dict[tuple[str, str], bool] = {}
        self._range_lock = threading.Lock()

    def _request(
        self,
        method: str,
        url: str,
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: int | None = None,
    ) -> bytes:
        req = request.Request(url, data=data, method=method)
        req.add_header("User-Agent", USER_AGENT)
        if self.auth_header:
            req.add_header("Authorization", self.auth_header)
        if headers:
            for key, value in headers.items():
                req.add_header(key, value)
        try:
            with self.opener.open(req, timeout=timeout or self.timeout) as response:
                return response.read()
        except error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read(2048).decode("utf-8", "replace").strip()
            except Exception:
                pass
            hint = "（账号或密码可能不正确）" if exc.code == 401 else ""
            raise WebDavError(f"{method} {display_url(url)} -> HTTP {exc.code}{hint} {detail}".strip(), exc.code) from exc
        except error.URLError as exc:
            raise WebDavError(f"{method} {display_url(url)} 失败：{exc.reason}") from exc
        except TimeoutError as exc:
            raise WebDavError(f"{method} {display_url(url)} 超时") from exc

    def list(self, folder_url: str) -> list[Resource]:
        folder_url = normalize_folder(folder_url)
        body = self._request(
            "PROPFIND",
            folder_url,
            data=PROPFIND_BODY.encode("utf-8"),
            headers={"Depth": "1", "Content-Type": "application/xml; charset=utf-8"},
            timeout=45,
        )
        try:
            root = ET.fromstring(body)
        except ET.ParseError as exc:
            raise WebDavError(f"无法解析 {display_url(folder_url)} 的目录列表：{exc}") from exc

        requested = _url_key(folder_url)
        resources: list[Resource] = []
        for response in root.iter():
            if _local_name(response.tag) != "response":
                continue
            href_el = _first_child(response, "href")
            if href_el is None or not (href_el.text or "").strip():
                continue
            href = parse.urljoin(folder_url, href_el.text.strip())
            if _url_key(href) == requested:
                continue

            prop = _find_prop(response)
            resourcetype = _first_child(prop, "resourcetype") if prop is not None else None
            is_dir = resourcetype is not None and _first_child(resourcetype, "collection") is not None
            mime_text = _child_text(prop, "getcontenttype")
            mime = mime_text.split(";")[0].strip() if mime_text else None
            size_text = _child_text(prop, "getcontentlength")
            try:
                size = int(size_text) if size_text else None
            except ValueError:
                size = None

            path = parse.urlsplit(href).path
            raw_name = path.rstrip("/").rsplit("/", 1)[-1]
            name = parse.unquote(raw_name)
            if not name:
                continue
            resources.append(
                Resource(
                    url=normalize_folder(href) if is_dir else href,
                    name=name,
                    is_dir=is_dir,
                    mime=mime,
                    size=size,
                )
            )

        resources.sort(key=lambda r: (not r.is_dir, r.name.lower()))
        return resources

    def get_bytes(self, file_url: str, timeout: int = 120) -> bytes:
        return self._request("GET", file_url, timeout=timeout)

    def ensure_dir(self, folder_url: str, force: bool = False) -> None:
        folder_url = normalize_folder(folder_url)
        key = _url_key(folder_url)
        if not force:
            with self._ensured_lock:
                if key in self._ensured:
                    return
        try:
            self._request("MKCOL", folder_url, timeout=45)
        except WebDavError as exc:
            # 405：已经存在；301/302：带斜杠的地址，视为已就绪
            if exc.status not in (405, 301, 302):
                raise
        with self._ensured_lock:
            self._ensured.add(key)

    def ensure_tree(self, folder_url: str, base_url: str, force: bool = False) -> None:
        """逐级创建文件夹；base_url 必须已存在或由调用方先行创建。

        force=True 时忽略「已确认存在」缓存，用于服务器上的目录被外部删除后重建。
        """
        folder_url = normalize_folder(folder_url)
        base_url = normalize_folder(base_url)
        folder_path = parse.urlsplit(folder_url).path
        base_path = parse.urlsplit(base_url).path
        if not is_under(folder_url, base_url) or not folder_path.startswith(base_path):
            self.ensure_dir(folder_url, force=force)
            return
        current = base_url
        for segment in [s for s in folder_path[len(base_path):].split("/") if s]:
            current += segment + "/"
            self.ensure_dir(current, force=force)

    def put_bytes(self, file_url: str, data: bytes, content_type: str = "image/jpeg") -> None:
        self._request(
            "PUT",
            file_url,
            data=data,
            headers={"Content-Type": content_type},
            timeout=180,
        )

    def delete(self, file_url: str) -> None:
        self._request("DELETE", file_url, timeout=60)

    def supports_range(self, file_url: str, timeout: float = 10) -> bool:
        """用 Range: bytes=0-0 探测服务器是否支持断点读取，结果按主机缓存。

        不支持时调用方会只从开头附近取帧，避免 ffprobe/ffmpeg 顺序读取整个大文件。
        """
        if not file_url.lower().startswith(("http://", "https://")):
            return True
        key = _url_key(file_url)[:2]
        with self._range_lock:
            if key in self._range_cache:
                return self._range_cache[key]
        req = request.Request(cache_bust(file_url), method="GET")
        req.add_header("User-Agent", USER_AGENT)
        if self.auth_header:
            req.add_header("Authorization", self.auth_header)
        req.add_header("Range", "bytes=0-0")
        supported = False
        try:
            with self.opener.open(req, timeout=timeout) as response:
                status = getattr(response, "status", None)
                if status is None:
                    status = response.getcode()
                supported = status == 206
                # 不读取响应体：服务器忽略 Range 时这里会返回 200，
                # 立即关闭可以避免把整个视频读进内存/磁盘。
        except error.HTTPError as exc:
            supported = exc.code == 206
            try:
                exc.close()
            except Exception:
                pass
        except Exception:
            # 证书、连接、超时、重定向等任何失败都按「不支持 Range」处理，
            # 后续只从开头附近取帧，避免顺序读取大文件。
            supported = False
        with self._range_lock:
            self._range_cache[key] = supported
        if not supported:
            log("服务器不支持 HTTP Range：只从开头附近取帧，避免读取大文件。")
        return supported

    def get_range(self, file_url: str, start: int, length: int, timeout: float = 20) -> bytes:
        """只读取指定字节范围；服务器忽略 Range 时最多也只读 length 字节。"""
        req = request.Request(cache_bust(file_url), method="GET")
        req.add_header("User-Agent", USER_AGENT)
        if self.auth_header:
            req.add_header("Authorization", self.auth_header)
        req.add_header("Range", f"bytes={start}-{start + length - 1}")
        try:
            with self.opener.open(req, timeout=timeout) as response:
                return response.read(length)
        except Exception:
            return b""

    def probe_avi_header(self, file_url: str) -> tuple[bool, float | None]:
        """读文件头：返回（是否真的是 AVI，时长）。

        扩展名不可靠（有 .avi 实际是 MP4 的），所以用 RIFF 魔数判断封装格式；
        读不到任何数据时按“未知”处理，返回 (True, None) 沿用扩展名判断。
        """
        for size in (1024 * 1024, 4 * 1024 * 1024):
            data = self.get_range(file_url, 0, size)
            if not data:
                continue
            if not is_riff_avi(data):
                return False, None
            duration = parse_avi_duration(data)
            if duration is not None:
                return True, duration
        return True, None

    def probe_avi_duration(self, file_url: str) -> float | None:
        """从 AVI 文件头（avih/dmlh）读时长，只需要 1MB 左右的 Range。"""
        return self.probe_avi_header(file_url)[1]

    def test_connection(self) -> None:
        self.list(self.base_url)


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _children(element, name: str):
    return [child for child in element if _local_name(child.tag) == name]


def _first_child(element, name: str):
    for child in element:
        if _local_name(child.tag) == name:
            return child
    return None


def _child_text(element, name: str) -> str | None:
    child = _first_child(element, name)
    if child is None or child.text is None:
        return None
    text = child.text.strip()
    return text or None


def _find_prop(response):
    for propstat in _children(response, "propstat"):
        status = _child_text(propstat, "status") or ""
        if " 200 " in status or not status:
            prop = _first_child(propstat, "prop")
            if prop is not None:
                return prop
    return _first_child(response, "prop")
