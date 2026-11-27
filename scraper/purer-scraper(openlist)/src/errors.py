"""错误类型、失败原因分类与失败标记常量。"""
from __future__ import annotations

import re

from .constants import FAILURE_LABELS

# ---------------------------------------------------------------------------
# 抽帧失败原因（与 App 的 CloudVideoThumbnailFailure 对应）
# ---------------------------------------------------------------------------


class VideoError(Exception):
    """抽帧/读时长/上传失败；reason 是 App 失败原因的小写名字。

    ``context`` 保存这类失败的结构化细节（命令、退出码、错误输出、目标位置等），
    失败时由 :mod:`src.failure_report` 汇总写入终端、scraper.log 和
    failed_videos.json。``attempts`` 由 :func:`src.retry.retry` 填充，记录每次尝试。
    """

    def __init__(
        self,
        reason: str,
        message: str,
        retryable: bool = True,
        *,
        phase: str = "",
        context: dict | None = None,
    ) -> None:
        super().__init__(message)
        self.reason = reason
        # 卡死等重试也不会变化的情况标记为不可重试，避免在同一个视频上反复耗时间
        self.retryable = retryable
        self.phase = phase or reason
        # 故意保留同一个 dict 引用：调用链下层可以先创建异常，
        # 上层再补充 url/时长等上下文，最终报告能看到合并后的内容。
        self.context = context if context is not None else {}
        self.attempts: list[dict] = []


class VideoSkipped(Exception):
    """视频不满足处理条件而主动跳过（例如雪碧图的时长下限），不计入失败。"""

    def __init__(self, message: str, *, duration: float | None = None) -> None:
        super().__init__(message)
        self.duration = duration


class WebDavError(Exception):
    """WebDAV 请求失败；status 是 HTTP 状态码（网络错误时为 None）。"""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


_STATUS_IN_TEXT = re.compile(
    r"(?:server returned|http error|http status|returned error:?)\s*(\d{3}|[45]XX)",
    re.IGNORECASE,
)
_TIMEOUT_HINTS = ("timed out", "timeout", "超时", "operation timed out")
_NOFRAME_HINTS = (
    "invalid data found",
    "moov atom not found",
    "could not find codec parameters",
    "does not contain any stream",
    "does not contain a video",
    "output file is empty",
    "nothing was written into output file",
    "error while decoding",
    "decode_slice_header",
    "invalid nal",
    "unsupported codec",
    "decoder not found",
    "unknown decoder",
    "could not decode",
    "cannot decode",
    "no frame",
)


def classify_ffmpeg_failure(stderr: str) -> str:
    """把 ffmpeg/ffprobe 的错误输出映射为 App 的失败原因。"""
    text = stderr or ""
    lower = text.lower()
    match = _STATUS_IN_TEXT.search(text)
    if match:
        token = match.group(1).upper()
        if token == "5XX":
            return "server"
        if token == "4XX":
            return "unknown"
        status = int(token)
        if status in (401, 403):
            return "auth"
        if status == 404:
            return "notfound"
        if status == 429:
            return "ratelimited"
        if status >= 500:
            return "server"
        return "unknown"
    if any(hint in lower for hint in _TIMEOUT_HINTS):
        return "timeout"
    if any(hint in lower for hint in _NOFRAME_HINTS):
        return "noframe"
    return "unknown"


def failure_label(reason: str) -> str:
    return FAILURE_LABELS.get(reason, FAILURE_LABELS["unknown"])
