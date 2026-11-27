"""失败视频的详细日志。

每一次失败除了终端/日志里的一行摘要，还会输出一块结构化详情：

- 视频名、源地址、文件大小、缓存目录、处理模式；
- 失败阶段（读时长/第几帧/上传/局部窗口）、失败原因、是否可重试；
- 整个视频的用时、尝试次数；
- 每一次尝试的命令行（隐藏 Basic 认证头）、退出码、错误输出末尾几行。

同样的字段会写进 ``failed_videos.json``，便于事后排查；``--retry-failed``
重新失败时也会走这里，不会丢失上一次的详细信息。
"""
from __future__ import annotations

import re

from .console import log
from .constants import NON_RETRYABLE_FAILURES
from .errors import failure_label
from .urls import normalize_folder

_AUTH_RE = re.compile(r"(Authorization:\s*Basic\s+)[A-Za-z0-9+/=]+", re.IGNORECASE)
_URL_AUTH_RE = re.compile(r"(://)[^/@\s'\"]+@")
_STDERR_KEEP = 6000
_STDERR_LINES = 15


def _fmt_size(size: int | None) -> str:
    if not size or size <= 0:
        return ""
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return ""


def _redact(text: str) -> str:
    value = _AUTH_RE.sub(r"\1<已隐藏>", text or "")
    return _URL_AUTH_RE.sub(r"\1<已隐藏>@", value)


def _tail_lines(text: str | None, limit: int = _STDERR_LINES) -> list[str]:
    if not text:
        return []
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    return lines[-limit:]


def _attempt_block(attempt: dict, index: int, total: int) -> list[str]:
    context = attempt.get("context") or {}
    reason = attempt.get("reason") or "unknown"
    lines = [
        f"  尝试 {index}/{total} · 用时 {float(attempt.get('elapsed') or 0):.1f}s · "
        f"{failure_label(reason)}（{reason}）"
    ]
    if attempt.get("phase"):
        lines.append(f"    阶段：{attempt['phase']}")
    message = attempt.get("message")
    if message:
        lines.append(f"    消息：{message}")
    if context:
        if context.get("url"):
            lines.append(f"    地址：{context['url']}")
        if context.get("timestamp") is not None:
            extra = f"    目标位置：{float(context['timestamp']):g}s"
            if context.get("width"):
                extra += f" · 宽度 {context['width']}px"
            if context.get("input_seek") is not None:
                extra += " · 输入端定位" if context["input_seek"] else " · 输出端定位"
            lines.append(extra)
        if context.get("command"):
            lines.append(f"    命令：{_redact(context['command'])}")
        if context.get("exit_code") is not None:
            lines.append(f"    退出码：{context['exit_code']}")
        if context.get("timeout"):
            lines.append(f"    超时上限：{float(context['timeout']):g}s")
        if context.get("idle") is not None:
            lines.append(f"    无进展时长：{float(context['idle']):g}s")
        if context.get("stdout_bytes") is not None:
            lines.append(f"    标准输出：{context['stdout_bytes']} 字节")
        tail = _tail_lines(context.get("stderr_tail"))
        if tail:
            lines.append("    错误输出（末尾 %d 行）：" % len(tail))
            lines.extend("      " + line for line in tail)
    # 兜底路径里的子错误（读时长失败 / 目标位置失败 / 局部窗口失败）
    for key, label in (
        ("probe_error", "读时长失败"),
        ("first_attempt", "目标位置尝试"),
        ("window_fallback", "局部窗口兜底"),
    ):
        item = context.get(key)
        if not isinstance(item, dict) or not item:
            continue
        reason = item.get("reason") or "unknown"
        head = f"{failure_label(reason)}（{reason}）"
        if item.get("message"):
            head += "：" + str(item["message"])
        lines.append(f"    {label}：{head}")
        sub = item.get("context") or {}
        if sub.get("command"):
            lines.append(f"      命令：{_redact(sub['command'])}")
        sub_tail = _tail_lines(sub.get("stderr_tail"), 3)
        if sub_tail:
            lines.append("      错误输出：")
            lines.extend("        " + line for line in sub_tail)
    return lines


def collect_failure_details(
    exc: BaseException,
    video,
    folder: str,
    mirror_dir: str,
    mode: str,
    elapsed: float,
    extra: dict | None = None,
) -> dict:
    """把异常与上下文整理成可写入日志/JSON 的详情。"""
    reason = str(getattr(exc, "reason", "") or "unknown").lower()
    context = dict(getattr(exc, "context", {}) or {})
    attempts = list(getattr(exc, "attempts", []) or [])
    if not attempts:
        attempts = [
            {
                "attempt": 1,
                "elapsed": round(float(elapsed), 1),
                "reason": reason,
                "phase": getattr(exc, "phase", "") or "",
                "message": str(exc),
                "context": context,
            }
        ]
    details = {
        "time": None,  # 由调用方或 FailureStore 填 UTC 时间
        "video": getattr(video, "name", ""),
        "url": getattr(video, "url", ""),
        "size": getattr(video, "size", None),
        "folder": normalize_folder(folder),
        "mirror_dir": normalize_folder(mirror_dir),
        "mode": mode,
        "reason": reason,
        "label": failure_label(reason),
        "retryable": bool(getattr(exc, "retryable", True))
        and reason not in NON_RETRYABLE_FAILURES,
        "phase": getattr(exc, "phase", "") or "",
        "elapsed": round(float(elapsed), 1),
        "message": str(exc),
        "attempts": attempts,
    }
    if context:
        details["context"] = context
    if extra:
        details.update(extra)
    return details


def _hint(reason: str) -> str:
    return {
        "timeout": "网络或服务器响应慢：可稍后 --retry-failed；持续卡死可降低 --jobs 或检查带宽。",
        "ratelimited": "服务器限流：稍后重试，或降低 --rate / --jobs。",
        "server": "服务器错误：稍后 --retry-failed；若持续出现请检查 WebDAV 服务。",
        "auth": "认证失败：用 --password / --cache-password 更新密码后重试。",
        "notfound": "源文件不存在（404）：确认文件是否已被删除或移动。",
        "noframe": "无法解码出画面：格式/编码不受支持，或服务器不支持 HTTP Range 定位。",
        "upload": "上传缩略图失败：检查缓存目录写权限、磁盘空间与 WebDAV 服务。",
        "unknown": "未知错误：请结合下方命令与错误输出排查。",
    }.get(reason, "")


def log_failure_details(details: dict) -> None:
    """把详情块写进终端与 scraper.log。"""
    lines: list[str] = []
    lines.append("  " + "─" * 24 + " 失败详情 " + "─" * 28)
    lines.append(f"  视频：{details.get('video', '')}")
    if details.get("url"):
        lines.append(f"  源地址：{details['url']}")
    size = _fmt_size(details.get("size"))
    if size:
        lines.append(f"  大小：{size}")
    if details.get("mirror_dir"):
        lines.append(f"  缓存目录：{details['mirror_dir']}")
    lines.append(
        "  模式："
        + ("雪碧图" if details.get("mode") == "sprite" else "缩略图")
    )
    phase = details.get("phase") or ""
    context = details.get("context") or {}
    if context.get("timestamp") is not None:
        phase += f" · 目标 {float(context['timestamp']):g}s"
    if phase:
        lines.append(f"  阶段：{phase}")
    reason = details.get("reason", "unknown")
    retryable = "可重试" if details.get("retryable") else "不重试"
    lines.append(f"  原因：{details.get('label') or failure_label(reason)}（{reason}）· {retryable}")
    lines.append(
        f"  用时：{float(details.get('elapsed') or 0):.1f}s · "
        f"共尝试 {len(details.get('attempts') or [])} 次"
    )
    attempts = details.get("attempts") or []
    for index, attempt in enumerate(attempts, 1):
        lines.extend(_attempt_block(attempt, index, len(attempts)))
    hint = _hint(reason)
    if hint:
        lines.append(f"  提示：{hint}")
    lines.append("  " + "─" * 62)
    # 失败详情同时写进主日志和 scraper_failure.log
    log("\n".join(lines), category="failure")
