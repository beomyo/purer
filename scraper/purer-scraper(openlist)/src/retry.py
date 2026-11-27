"""统一的失败重试：记录每次尝试的详细信息。

重试过程中不丢信息：每次失败的耗时、原因、命令与错误输出都会追加到
``VideoError.attempts``，最终失败时由 :mod:`src.failure_report` 完整输出。
"""
from __future__ import annotations

import time

from . import runtime
from .constants import NON_RETRYABLE_FAILURES
from .console import log
from .errors import VideoError


def _is_retryable(exc: Exception) -> bool:
    """永久性失败（无法解码/404/认证）重试也不会成功；网络类失败可以再试一次。"""
    if isinstance(exc, VideoError):
        return exc.retryable and exc.reason not in NON_RETRYABLE_FAILURES
    return True


def _attempt_record(exc: Exception, attempt: int, elapsed: float) -> dict:
    record = {
        "attempt": attempt,
        "elapsed": round(elapsed, 1),
        "reason": str(getattr(exc, "reason", "unknown")),
        "message": str(exc),
    }
    if isinstance(exc, VideoError):
        if exc.phase:
            record["phase"] = exc.phase
        if exc.context:
            record["context"] = exc.context
    return record


def _last_error_line(exc: Exception) -> str:
    if not isinstance(exc, VideoError):
        return ""
    stderr = str(exc.context.get("stderr_tail") or "")
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def retry(description: str, retries: int, action):
    last_error: Exception | None = None
    attempts: list[dict] = []
    for attempt in range(retries + 1):
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消")
        started = time.monotonic()
        try:
            return action()
        except Exception as exc:  # noqa: BLE001 - 单个视频失败不应中断整次刮削
            last_error = exc
            elapsed = time.monotonic() - started
            attempts.append(_attempt_record(exc, attempt + 1, elapsed))
            if isinstance(exc, VideoError):
                # 保留同一个列表引用，异常抛出后仍能看到所有尝试
                exc.attempts = attempts
            if runtime.cancel_event.is_set() or not _is_retryable(exc):
                raise
            if attempt < retries:
                log(
                    f"  {description} 第 {attempt + 1} 次失败（{elapsed:.1f}s），"
                    f"1.5s 后重试：{exc}"
                )
                detail = _last_error_line(exc)
                if detail:
                    log(f"      错误输出：{detail}")
                time.sleep(1.5)
    assert last_error is not None
    raise last_error
