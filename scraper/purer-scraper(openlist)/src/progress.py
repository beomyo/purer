"""并发任务的统一进度。

每个正在处理的视频对应一个 :class:`TaskProgress`。不管同时跑几个视频，
进度都按同一套口径计量：

- **视频已用**：从该视频开始处理到现在（跨重试、跨多个 ffmpeg 进程）；
- **当前阶段**：读时长 / 抽帧 / 取帧 / 拼接 / 上传 / 局部窗口；
- **当前步骤**：例如雪碧图的第 3/25 帧；
- **当前操作**：本次 ffmpeg/ffprobe 已用时间、解码帧数与最近进展。

以前每个 ffmpeg 进程各自每 10 秒写一条「已用 Ns」，并发时两条时间线
互不对应，看起来像进度不统一。现在心跳由同一个刷新线程按任务输出，
终端进度区也为每个任务固定一行，因此每个视频的进度始终可以独立对照。
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass

from .console import StatusBoard, log
from .constants import HEARTBEAT_INTERVAL


def _clock(seconds: float) -> str:
    total = int(max(0.0, seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def _short_name(name: str, limit: int = 32) -> str:
    value = " ".join((name or "").split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


@dataclass
class TaskSnapshot:
    slot: int
    video: str
    phase: str
    step: int
    steps: int
    detail: str
    elapsed: float
    op_elapsed: float
    idle: float
    frame: int
    decoded: float
    speed: str
    finished: bool

    def step_text(self) -> str:
        if self.steps > 0:
            return f"{self.phase} {self.step}/{self.steps}"
        return self.phase


def _detail_text(snapshot: TaskSnapshot) -> str:
    """去掉与阶段/步骤重复的说明，只保留真正额外的信息。"""
    detail = (snapshot.detail or "").strip()
    if not detail:
        return ""
    if detail == snapshot.phase or detail == snapshot.step_text():
        return ""
    # 雪碧图的步骤已经显示「取帧 3/25」，不再重复「第 3/25 帧」
    if snapshot.steps > 0 and f"{snapshot.step}/{snapshot.steps}" in detail:
        return ""
    if detail.startswith(snapshot.phase + " "):
        detail = detail[len(snapshot.phase):].strip(" ：:")
    if not detail or detail == snapshot.phase:
        return ""
    return detail


class TaskProgress:
    """一个视频的进度；方法都可在工作线程里调用。"""

    def __init__(self, tracker: "TaskTracker", slot: int, video: str) -> None:
        self.tracker = tracker
        self.slot = slot
        self.video = video
        self.started = time.monotonic()
        self._lock = threading.Lock()
        self.phase = "准备"
        self.step = 0
        self.steps = 0
        self.detail = ""
        self.op_started = self.started
        self.last_advance = self.started
        self.frame = 0
        self.decoded = 0.0
        self.speed = ""
        self.finished = False

    # ---- 工作线程调用 ----

    def set_phase(self, phase: str, steps: int = 0) -> None:
        """切换到新阶段；steps>0 时显示为「阶段 步骤/总数」。"""
        with self._lock:
            now = time.monotonic()
            self.phase = phase
            self.step = 0
            self.steps = max(0, steps)
            self.detail = ""
            self.op_started = now
            self.last_advance = now
            self.frame = 0
            self.decoded = 0.0
            self.speed = ""

    def advance(self, step: int, steps: int | None = None) -> None:
        """完成一步（例如取完一帧）。"""
        with self._lock:
            now = time.monotonic()
            self.step = step
            if steps is not None:
                self.steps = max(0, steps)
            self.detail = ""
            self.op_started = now
            self.last_advance = now
            self.frame = 0
            self.decoded = 0.0
            self.speed = ""

    def begin(self, detail: str) -> None:
        """开始一次具体操作（ffmpeg/ffprobe/上传）。"""
        with self._lock:
            now = time.monotonic()
            self.detail = detail
            self.op_started = now
            self.last_advance = now
            self.frame = 0
            self.decoded = 0.0
            self.speed = ""

    def feed(
        self,
        frame: int | None = None,
        decoded: float | None = None,
        speed: str | None = None,
    ) -> None:
        """ffmpeg -progress 解析线程调用，更新解码进展。"""
        with self._lock:
            now = time.monotonic()
            if frame is not None and frame != self.frame:
                self.frame = frame
                self.last_advance = now
            if decoded is not None and decoded != self.decoded:
                self.decoded = decoded
                self.last_advance = now
            if speed is not None:
                self.speed = speed

    def finish(self) -> None:
        with self._lock:
            self.finished = True
        self.tracker._remove(self)

    # ---- 快照 ----

    def snapshot(self, now: float | None = None) -> TaskSnapshot:
        now = time.monotonic() if now is None else now
        with self._lock:
            return TaskSnapshot(
                slot=self.slot,
                video=self.video,
                phase=self.phase,
                step=self.step,
                steps=self.steps,
                detail=self.detail,
                elapsed=max(0.0, now - self.started),
                op_elapsed=max(0.0, now - self.op_started),
                idle=max(0.0, now - self.last_advance),
                frame=self.frame,
                decoded=self.decoded,
                speed=self.speed,
                finished=self.finished,
            )

    def heartbeat_text(self, now: float | None = None) -> str:
        """一条任务心跳；``视频已用`` 从该视频开始处理算起，不随 ffmpeg 重启归零。"""
        snap = self.snapshot(now)
        if snap.finished:
            return ""
        phase_text = snap.step_text()
        detail = _detail_text(snap)
        if detail:
            phase_text += f"（{detail}）"
        parts = [f"[任务 #{snap.slot}] {snap.video}：{phase_text}"]
        parts.append(f"视频已用 {snap.elapsed:.0f}s")
        parts.append(f"当前 {snap.op_elapsed:.0f}s")
        if snap.frame:
            parts.append(f"帧 {snap.frame}")
        if snap.decoded > 0:
            parts.append(f"已解码 {snap.decoded:.1f}s")
        if snap.speed and snap.speed != "N/A":
            parts.append(f"速度 {snap.speed}")
        if snap.idle >= 5:
            parts.append(f"最近进展 {snap.idle:.0f}s 前")
        return "  " + " · ".join(parts)

    def status_line(self) -> str:
        snap = self.snapshot()
        parts = [f"#{snap.slot} {_short_name(snap.video)}"]
        phase_text = snap.step_text()
        detail = _detail_text(snap)
        if detail:
            phase_text += f"（{detail}）"
        parts.append(phase_text)
        parts.append(f"视频 {_clock(snap.elapsed)}")
        parts.append(f"当前 {snap.op_elapsed:.0f}s")
        if snap.frame:
            parts.append(f"帧 {snap.frame}")
        if snap.decoded > 0:
            parts.append(f"解码 {snap.decoded:.1f}s")
        if snap.idle >= 5:
            parts.append(f"静止 {snap.idle:.0f}s")
        return " · ".join(parts)


class TaskTracker:
    """管理所有并发任务，并驱动终端进度区与心跳日志。"""

    def __init__(
        self,
        board: StatusBoard | None,
        summary,
        interval: float = 1.0,
    ) -> None:
        self.board = board
        self.summary = summary
        self.interval = interval
        self._lock = threading.Lock()
        self._tasks: dict[int, TaskProgress] = {}
        self._stop = threading.Event()
        # 心跳按全局节拍统一输出：到点时把所有正在处理的任务一次写完，
        # 多路并发的「已用时间」于是可以逐行对照，而不会各说各话。
        self._next_heartbeat = time.monotonic() + HEARTBEAT_INTERVAL
        self._thread = threading.Thread(
            target=self._run, name="purer-progress", daemon=True
        )
        self._thread.start()

    def new_task(self, video: str) -> TaskProgress:
        with self._lock:
            empty = not self._tasks
            slot = 1
            while slot in self._tasks:
                slot += 1
            task = TaskProgress(self, slot, video)
            self._tasks[slot] = task
        if empty:
            # 扫描目录可能花了很久；第一个任务开始时重新计时，
            # 避免刚开跑就立刻打一条 0 秒的心跳。
            self._next_heartbeat = time.monotonic() + HEARTBEAT_INTERVAL
        self.refresh(heartbeat=False)
        return task

    def _remove(self, task: TaskProgress) -> None:
        with self._lock:
            if self._tasks.get(task.slot) is task:
                del self._tasks[task.slot]

    def snapshot(self) -> list[TaskSnapshot]:
        with self._lock:
            tasks = list(self._tasks.values())
        now = time.monotonic()
        return [task.snapshot(now) for task in tasks]

    def refresh(self, heartbeat: bool = True) -> None:
        """刷新终端进度区；到点时按统一节拍输出所有任务的心跳。"""
        now = time.monotonic()
        with self._lock:
            tasks = list(self._tasks.values())
        if heartbeat and tasks and now >= self._next_heartbeat:
            self._next_heartbeat = now + HEARTBEAT_INTERVAL
            for task in sorted(tasks, key=lambda item: item.slot):
                text = task.heartbeat_text(now)
                if text:
                    log(text)
        lines: list[str] = []
        summary = self.summary()
        if summary:
            lines.append(summary)
        for task in sorted(tasks, key=lambda item: item.slot):
            snap = task.snapshot(now)
            if not snap.finished:
                lines.append(task.status_line())
        if self.board is not None:
            self.board.update(lines)

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            try:
                self.refresh(heartbeat=True)
            except Exception:
                # 终端刷新/心跳失败不应影响刮削
                pass

    def stop(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=2.0)
