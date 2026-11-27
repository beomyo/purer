"""ffmpeg / ffprobe 调用：读时长、抽帧、心跳与卡死检测。"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import threading
import time
from pathlib import Path

from . import runtime
from .constants import (
    AVI_INPUT_OPTIONS,
    EXTRACT_TIMEOUT,
    HEARTBEAT_INTERVAL,
    PROBE_TIMEOUT,
    USER_AGENT,
)
from .console import log
from .errors import VideoError, classify_ffmpeg_failure
from .paths import PROJECT_ROOT
from .progress import TaskProgress
from .urls import is_avi_url

# ---------------------------------------------------------------------------
# ffmpeg / ffprobe
# ---------------------------------------------------------------------------


def find_tool(name: str, explicit: str | None) -> str:
    if explicit:
        candidate = Path(explicit)
        if candidate.is_file():
            return str(candidate)
        found = shutil.which(explicit)
        if found:
            return found
        raise FileNotFoundError(f"找不到 {name}：{explicit} 不是文件，也不在 PATH 中。")
    found = shutil.which(name)
    if found:
        return found
    executable = f"{name}.exe" if os.name == "nt" else name
    candidates = [
        PROJECT_ROOT / "ffmpeg" / "bin" / executable,
        Path(r"D:\Program Files\Environment\ffmpeg\bin") / executable,
        Path(r"C:\ffmpeg\bin") / executable,
        Path(r"C:\Program Files\ffmpeg\bin") / executable,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(
        f"找不到 {name}。请安装 ffmpeg 并加入 PATH，或用 --{name} 指定可执行文件路径。"
    )


def _is_local_url(url: str) -> bool:
    from urllib import parse

    host = (parse.urlsplit(url).hostname or "").lower()
    return host in ("127.0.0.1", "localhost", "::1")


def _ffmpeg_net_args(url: str, token: str | None, insecure: bool) -> list[str]:
    if not url.lower().startswith(("http://", "https://")):
        return []
    args: list[str] = ["-user_agent", USER_AGENT, "-rw_timeout", "120000000"]
    if insecure and url.lower().startswith("https://"):
        args += ["-tls_verify", "0"]
    # 本地 Range 缓存代理是 127.0.0.1，不能再去走外部代理
    if runtime.ffmpeg_proxy and not _is_local_url(url):
        args += ["-http_proxy", runtime.ffmpeg_proxy]
    if token:
        args += ["-headers", f"Authorization: Basic {token}\r\n"]
    return args


# ffmpeg -progress 输出的键值行；不能当成错误信息，也不能参与失败原因判断
PROGRESS_PREFIXES = (
    "frame=",
    "fps=",
    "stream_",
    "bitrate=",
    "total_size=",
    "out_time_us=",
    "out_time_ms=",
    "out_time=",
    "dup_frames=",
    "drop_frames=",
    "speed=",
    "progress=",
)


def _strip_progress_lines(text: str) -> str:
    """去掉 -progress 的进度行，只保留真正的报错。"""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return "\n".join(line for line in lines if not line.startswith(PROGRESS_PREFIXES))


def _stderr_detail(stderr: bytes, fallback: str) -> tuple[str, str]:
    text = _strip_progress_lines(stderr.decode("utf-8", "replace"))
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    detail = lines[-1] if lines else fallback
    return text, detail


def _format_command(cmd: list[str]) -> str:
    """把命令行拼成一行日志；Basic 认证头会被隐藏。"""
    try:
        text = subprocess.list2cmdline(cmd) if os.name == "nt" else shlex.join(cmd)
    except Exception:
        text = " ".join(cmd)
    text = re.sub(
        r"(Authorization:\s*Basic\s+)[A-Za-z0-9+/=]+", r"\1<已隐藏>", text
    )
    # 代理地址或 URL 里可能带 user:password@，同样不能写进日志
    text = re.sub(r"(://)[^/@\s'\"]+@", r"\1<已隐藏>@", text)
    # Header 值里的 CRLF 不能把日志拆成多行
    return text.replace("\r", "\\r").replace("\n", "\\n")


def _task_detail(label: str | None, video: str, fallback: str) -> str:
    """任务进度行里已经有视频名，当前操作的说明去掉重复的名称前缀。"""
    text = (label or fallback).strip()
    for prefix in (f"{video}：", f"{video} "):
        if text.startswith(prefix):
            text = text[len(prefix):].strip()
            break
    return text or fallback


def _stderr_tail(stderr: bytes) -> str:
    text = _strip_progress_lines(stderr.decode("utf-8", "replace"))
    return text[-6000:]


def _run_capture(
    cmd: list[str],
    timeout: float,
    timeout_message: str = "命令执行超时",
    label: str | None = None,
    stall_timeout: float = 0.0,
    progress: bool = False,
    task: TaskProgress | None = None,
    context: dict | None = None,
) -> tuple[int, bytes, bytes]:
    """运行 ffmpeg/ffprobe 并捕获输出；支持取消、心跳、卡死检测与失败详情。

    - label：这次操作的说明（通常是「视频名 抽帧 123s」）。
    - task：所属视频的 :class:`TaskProgress`。传入时由统一的进度线程按任务
      输出心跳，本函数只更新任务状态（当前操作、解码帧数、最近进展），
      不再为每个 ffmpeg 进程各写一条「已用 Ns」，并发时进度口径一致。
    - progress：命令带了 ffmpeg 的 -progress pipe:2，可以读到解码进度。
    - stall_timeout：连续这么多秒没有任何新进展就杀掉进程。服务器一直慢慢发流量、
      ffmpeg 却解析不出画面时，不会一直等到总超时。
    - context：调用方提供的失败详情字典；命令、退出码、错误输出会补充进去，
      抛出的 VideoError 持有同一个字典引用，最终写入失败日志。
    - 支持从其他线程取消（中断时 kill 子进程）。
    """
    info = context if context is not None else {}
    info["command"] = _format_command(cmd)
    if label:
        info["label"] = label
    if task is not None:
        task.begin(_task_detail(label, task.video, timeout_message))

    if runtime.cancel_event.is_set():
        raise VideoError("timeout", "已取消", context=info)
    try:
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        info["error"] = str(exc)
        raise VideoError(
            "unknown", f"无法启动 {cmd[0]}：{exc}", context=info
        ) from exc
    with runtime.running_lock:
        runtime.running_processes.add(process)
    if runtime.cancel_event.is_set():
        try:
            process.kill()
        except Exception:
            pass

    started = time.monotonic()
    captured = {
        "stdout": b"",
        "stderr": bytearray(),
        "advance_at": started,
        "frame": 0,
        "decoded": 0.0,
        "speed": "",
    }

    def fail(reason: str, message: str, retryable: bool = True) -> VideoError:
        """创建带当前运行上下文的 VideoError（finally 还会补充最终状态）。"""
        info["elapsed"] = round(time.monotonic() - started, 1)
        info["stderr_tail"] = _stderr_tail(bytes(captured["stderr"]))
        info["stdout_bytes"] = len(captured["stdout"] or b"")
        info["exit_code"] = process.poll()
        info["timeout"] = timeout
        return VideoError(reason, message, retryable, context=info)

    def read_stdout() -> None:
        try:
            captured["stdout"] = process.stdout.read() or b""
        except Exception:
            pass

    def read_stderr() -> None:
        # 逐行读取：一边收集输出，一边把 -progress 的进度行转成「最近进展」
        try:
            for raw in process.stderr:
                captured["stderr"] += raw
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("frame="):
                    try:
                        captured["frame"] = int(line.split("=", 1)[1])
                    except ValueError:
                        pass
                    captured["advance_at"] = time.monotonic()
                    if task is not None:
                        task.feed(frame=captured["frame"])
                elif line.startswith("out_time_us="):
                    try:
                        value = int(line.split("=", 1)[1]) / 1_000_000.0
                    except ValueError:
                        continue
                    if value != captured["decoded"]:
                        captured["decoded"] = value
                        captured["advance_at"] = time.monotonic()
                        if task is not None:
                            task.feed(decoded=value)
                elif line.startswith("speed="):
                    captured["speed"] = line.split("=", 1)[1].strip()
                    if task is not None:
                        task.feed(speed=captured["speed"])
                elif line.startswith("progress="):
                    captured["advance_at"] = time.monotonic()
        except Exception:
            pass

    stdout_thread = threading.Thread(target=read_stdout, name="purer-ffmpeg-stdout", daemon=True)
    stderr_thread = threading.Thread(target=read_stderr, name="purer-ffmpeg-stderr", daemon=True)
    stdout_thread.start()
    stderr_thread.start()

    # 没有 task 时（例如离线局部窗口）才由本函数自己写心跳，避免两个时间线并存
    next_heartbeat = started + HEARTBEAT_INTERVAL
    try:
        while True:
            try:
                process.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                pass
            now = time.monotonic()
            elapsed = now - started
            if runtime.cancel_event.is_set():
                raise fail("timeout", "已取消")
            if timeout > 0 and elapsed >= timeout:
                raise fail("timeout", timeout_message)
            idle = now - captured["advance_at"]
            if stall_timeout > 0 and idle >= stall_timeout:
                info["idle"] = round(idle, 1)
                if progress:
                    detail = f"连续 {idle:.0f}s 没有解码进展（服务器可能有流量但解析不动）"
                else:
                    detail = f"连续 {idle:.0f}s 没有完成读取（服务器可能有流量但无结果）"
                raise fail("timeout", f"{detail}，已判定卡死并中止", retryable=False)
            if task is None and label and now >= next_heartbeat:
                next_heartbeat = now + HEARTBEAT_INTERVAL
                # ffprobe 没有进度输出，只说已用时间；ffmpeg 才能显示解码进展
                extra = f" · 最近进展 {idle:.0f}s 前" if progress else ""
                if progress:
                    extra += f" · 帧 {captured['frame']}"
                    if captured["decoded"] > 0:
                        extra += f" · 已解码 {captured['decoded']:.1f}s"
                    speed = captured["speed"].rstrip("x").strip()
                    if speed and speed != "N/A":
                        extra += f" · 速度 {captured['speed']}"
                log(f"  {label}：已用 {elapsed:.0f}s{extra}")
    except BaseException:
        try:
            process.kill()
        except Exception:
            pass
        raise
    finally:
        # 等读取线程收尾，避免进程被杀后丢掉最后的报错
        stderr_thread.join(timeout=5)
        stdout_thread.join(timeout=5)
        if process.poll() is None:
            try:
                process.kill()
            except Exception:
                pass
            try:
                process.wait(timeout=5)
            except Exception:
                pass
        with runtime.running_lock:
            runtime.running_processes.discard(process)
        info["elapsed"] = round(time.monotonic() - started, 1)
        info["exit_code"] = process.returncode
        info["stderr_tail"] = _stderr_tail(bytes(captured["stderr"]))
        info["stdout_bytes"] = len(captured["stdout"] or b"")

    if runtime.cancel_event.is_set():
        raise VideoError("timeout", "已取消", context=info)
    return process.returncode, captured["stdout"] or b"", bytes(captured["stderr"])


def _is_unknown_option_error(stderr: bytes) -> bool:
    """ffmpeg 报 “Option xxx not found”：AVI 专属参数被用到了别的封装上（扩展名不可靠）。"""
    text = stderr.decode("utf-8", "replace").lower()
    return "option" in text and "not found" in text


def _run_with_input_options(
    base: list[str],
    input_options: list[str],
    tail: list[str],
    timeout: float,
    timeout_message: str,
    label: str | None = None,
    stall_timeout: float = 0.0,
    progress: bool = False,
    task: TaskProgress | None = None,
    context: dict | None = None,
) -> tuple[int, bytes, bytes]:
    """先带 AVI 专属输入参数运行；参数不被识别时去掉它们重跑一次。"""
    returncode, stdout, stderr = _run_capture(
        base + input_options + tail,
        timeout,
        timeout_message,
        label=label,
        stall_timeout=stall_timeout,
        progress=progress,
        task=task,
        context=context,
    )
    if input_options and returncode != 0 and _is_unknown_option_error(stderr):
        returncode, stdout, stderr = _run_capture(
            base + tail,
            timeout,
            timeout_message,
            label=label,
            stall_timeout=stall_timeout,
            progress=progress,
            task=task,
            context=context,
        )
    return returncode, stdout, stderr


def is_riff_avi(data: bytes) -> bool:
    """文件头是否为真正的 AVI（扩展名不可靠，很多 .avi 其实是 MP4）。"""
    return len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"AVI "


def parse_avi_duration(data: bytes) -> float | None:
    """解析 AVI 的 avih/dmlh，返回时长（秒）。数据只需文件头。"""
    if not is_riff_avi(data):
        return None

    def u32(offset: int) -> int:
        return int.from_bytes(data[offset:offset + 4], "little") if offset + 4 <= len(data) else 0

    micro = 0
    frames = 0
    index = data.find(b"avih")
    if index >= 0 and index + 28 <= len(data):
        start = index + 8
        micro = u32(start)
        frames = u32(start + 16)
    dmlh_frames = 0
    index = data.find(b"dmlh")
    if index >= 0 and index + 12 <= len(data):
        dmlh_frames = u32(index + 8)
    total = max(frames, dmlh_frames)
    if micro <= 0 or total <= 0:
        return None
    duration = micro * total / 1_000_000.0
    return duration if 0 < duration < 24 * 3600 else None


def probe_duration(
    ffprobe: str,
    url: str,
    token: str | None,
    insecure: bool,
    timeout: float = PROBE_TIMEOUT,
    label: str | None = None,
    stall_timeout: float = 0.0,
    task: TaskProgress | None = None,
) -> float | None:
    info = {"url": url, "timeout": timeout}
    cmd = [ffprobe, "-v", "error", "-hide_banner"]
    cmd += _ffmpeg_net_args(url, token, insecure)
    # 避免为读 OpenDML 索引去读文件尾部；头部的 avih/dmlh 足够
    avi_options = AVI_INPUT_OPTIONS if is_avi_url(url) else []
    tail = ["-show_entries", "format=duration:stream=duration", "-of", "json", url]
    try:
        returncode, stdout, stderr = _run_with_input_options(
            cmd,
            avi_options,
            tail,
            timeout,
            "读取视频时长超时",
            label=label,
            stall_timeout=stall_timeout,
            task=task,
            context=info,
        )
    except VideoError as exc:
        if not exc.phase or exc.phase == exc.reason:
            exc.phase = "读时长"
        raise
    if returncode != 0:
        text, detail = _stderr_detail(stderr, f"exit {returncode}")
        raise VideoError(
            classify_ffmpeg_failure(text),
            "ffprobe 失败：" + detail,
            phase="读时长",
            context=info,
        )
    try:
        data = json.loads(stdout.decode("utf-8", "replace") or "{}")
    except json.JSONDecodeError:
        return None
    candidates = [data.get("format", {}).get("duration")]
    candidates += [stream.get("duration") for stream in data.get("streams", [])]
    for candidate in candidates:
        try:
            value = float(candidate)
        except (TypeError, ValueError):
            continue
        if value > 0:
            return value
    return None


def extract_frame(
    ffmpeg: str,
    url: str,
    timestamp: float,
    width: int,
    token: str | None,
    insecure: bool,
    timeout: float = EXTRACT_TIMEOUT,
    seek_modes: tuple[bool, ...] = (True,),
    label: str | None = None,
    stall_timeout: float = 0.0,
    task: TaskProgress | None = None,
) -> bytes:
    """取一帧 JPEG。

    默认只在输入端定位（-ss 在 -i 之前），让服务器用 HTTP Range 只读取目标
    附近的数据；不会在输出端从头解码，因为那会读取大量数据，等同于下载大文件。
    如果服务器不支持 Range，会改用更靠前的 fallback_seconds 位置，而不是从头读。
    绝不会把整个源视频下载到本地。
    """
    errors: list[VideoError] = []
    for input_seek in seek_modes:
        if runtime.cancel_event.is_set():
            raise VideoError("timeout", "已取消")
        try:
            return _extract_frame_once(
                ffmpeg,
                url,
                timestamp,
                width,
                token,
                insecure,
                timeout,
                input_seek,
                label=label,
                stall_timeout=stall_timeout,
                task=task,
            )
        except VideoError as exc:
            errors.append(exc)
            # 文件不存在或认证失败时，换一种定位方式也不会成功
            if exc.reason in ("notfound", "auth"):
                break
    if not errors:
        raise VideoError("unknown", "没有可用的抽帧方式")
    reasons = [exc.reason for exc in errors]
    if "noframe" in reasons:
        reason = "noframe"
    elif "notfound" in reasons:
        reason = "notfound"
    else:
        reason = errors[0].reason
    # 只要有一次尝试是卡死（不可重试），整体就不重试，避免同一个视频反复等待
    primary = next((exc for exc in errors if exc.reason == reason), errors[0])
    context = dict(primary.context)
    context.update(
        {
            "url": url,
            "timestamp": timestamp,
            "width": width,
            "seek_attempts": [
                {
                    "reason": exc.reason,
                    "message": str(exc),
                    "context": exc.context,
                }
                for exc in errors
            ],
        }
    )
    raise VideoError(
        reason,
        "；".join(str(exc) for exc in errors),
        retryable=all(exc.retryable for exc in errors),
        phase=primary.phase,
        context=context,
    )


def _extract_frame_once(
    ffmpeg: str,
    url: str,
    timestamp: float,
    width: int,
    token: str | None,
    insecure: bool,
    timeout: float,
    input_seek: bool,
    label: str | None = None,
    stall_timeout: float = 0.0,
    task: TaskProgress | None = None,
) -> bytes:
    position = f"{max(0.0, timestamp):.3f}"
    # -progress pipe:2：把解码进度写到 stderr（画质数据仍在 stdout），
    # 这样可以显示「已用多久、是否还有新进展」，并在没有进展时判卡死。
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-progress", "pipe:2"]
    cmd += _ffmpeg_net_args(url, token, insecure)
    avi_options = AVI_INPUT_OPTIONS if is_avi_url(url) else []
    if input_seek:
        tail = ["-ss", position, "-i", url]
    else:
        tail = ["-i", url, "-ss", position]
    tail += [
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-an",
        "-sn",
        "-vf",
        f"scale={width}:{width}:force_original_aspect_ratio=decrease,format=yuvj420p",
        "-q:v",
        "3",
        "-f",
        "mjpeg",
        "pipe:1",
    ]
    info = {
        "url": url,
        "timestamp": timestamp,
        "width": width,
        "input_seek": input_seek,
        "timeout": timeout,
    }
    try:
        returncode, stdout, stderr = _run_with_input_options(
            cmd,
            avi_options,
            tail,
            timeout,
            "抽帧超时",
            label=label,
            stall_timeout=stall_timeout,
            progress=True,
            task=task,
            context=info,
        )
    except VideoError as exc:
        if not exc.phase or exc.phase == exc.reason:
            exc.phase = "抽帧"
        raise
    text, detail = _stderr_detail(stderr, f"exit {returncode}")
    if returncode != 0 or not stdout:
        if returncode == 0 and not stdout:
            # ffmpeg 定位点超出视频末尾时仍然返回 0，但一个画面都不输出
            detail = "没有输出任何画面（定位点超出视频末尾，或该时间点没有视频帧）"
        raise VideoError(
            classify_ffmpeg_failure(text),
            "ffmpeg 抽帧失败：" + detail,
            phase="抽帧",
            context=info,
        )
    if not stdout.startswith(b"\xff\xd8"):
        raise VideoError("noframe", "ffmpeg 没有返回 JPEG 画面", phase="抽帧", context=info)
    return stdout
