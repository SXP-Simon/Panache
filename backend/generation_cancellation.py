# Copyright (c) 2026 Simon and Panache contributors.
"""2026-10-24：线程局部的协作取消，不中断其他任务或提前释放执行槽."""

import functools
import time
from collections.abc import Callable, Iterable, Iterator
from contextvars import ContextVar
from typing import Protocol, cast

from library_boundary import install_member, member
from task_store import get_task, set_task


class GenerationCancelledError(Exception):
    """2026-10-24：生成已在安全检查点停止，临时文件由调用栈清理."""


class CancellationProbe:
    """2026-10-24：合并高频字符/像素检查，SQLite 状态支持跨进程取消."""

    def __init__(self, task_id: str) -> None:
        """2026-10-24：绑定仅供当前生成任务使用的取消探针."""
        self.task_id = task_id
        self.next_read = 0.0
        self.next_heartbeat = 0.0

    def check(self, *, force: bool = False) -> None:
        """2026-10-24：读到取消请求时从工作线程安全展开调用栈."""
        now = time.monotonic()
        if not force and now < self.next_read:
            return
        self.next_read = now + 0.05
        task = get_task(self.task_id)
        if task is None or task.get("status") in ("cancelling", "cancelled"):
            raise GenerationCancelledError
        # 2026-10-24：活跃线程续期；进程异常退出后仍由原 TTL 回收，不永久占用队列。
        if now >= self.next_heartbeat:
            self.next_heartbeat = now + 10
            set_task(
                self.task_id, expected_status=("pending", "processing"), updated_at=time.time()
            )


active_probe: ContextVar[CancellationProbe | None] = ContextVar("generation_probe", default=None)


def check_cancelled(*, force: bool = False) -> None:
    """2026-10-24：未绑定任务的直接渲染保持原有行为."""
    probe = active_probe.get()
    if probe is not None:
        probe.check(force=force)


def checked_items[T](items: Iterable[T]) -> Iterator[T]:
    """2026-10-24：跨页生成和打包都在消费下一项之前检查."""
    iterator = iter(items)
    while True:
        check_cancelled()
        try:
            item = next(iterator)
        except StopIteration:
            return
        check_cancelled()
        yield item


class _Bitmap(Protocol):
    def __getitem__(self, position: tuple[int, int]) -> object: ...


class _CheckedBitmap:
    def __init__(self, bitmap: object) -> None:
        self.bitmap = cast("_Bitmap", bitmap)
        self.remaining = 4096

    def __getitem__(self, position: tuple[int, int]) -> object:
        self.remaining -= 1
        if not self.remaining:
            check_cancelled()
            self.remaining = 4096
        return self.bitmap[position]


def install_cancellation_checks(core: object) -> None:
    """2026-10-24：覆盖连通域扫描及最终像素绘制，不改写第三方包文件."""
    extract = cast(
        "Callable[[object, tuple[int, int, int, int]], object]", member(core, "_extract_strokes")
    )
    if getattr(extract, "_cancellable", False):
        return
    draw = cast(
        "Callable[[object, Iterable[int], object, object], None]", member(core, "_draw_strokes")
    )

    @functools.wraps(extract)
    def extract_checked(bitmap: object, bbox: tuple[int, int, int, int]) -> object:
        check_cancelled()
        return extract(_CheckedBitmap(bitmap) if active_probe.get() is not None else bitmap, bbox)

    @functools.wraps(draw)
    def draw_checked(
        bitmap: object, strokes: Iterable[int], template: object, rand: object
    ) -> None:
        check_cancelled()
        draw(
            bitmap,
            checked_items(strokes) if active_probe.get() is not None else strokes,
            template,
            rand,
        )
        check_cancelled()

    # 2026-10-24：单个连通笔画也可能很大，旋转每个像素时仍保留检查点。
    rotate = cast(
        "Callable[[tuple[float, float], float, float, float], tuple[float, float]]",
        member(core, "_rotate"),
    )

    @functools.wraps(rotate)
    def rotate_checked(
        center: tuple[float, float], x: float, y: float, theta: float
    ) -> tuple[float, float]:
        check_cancelled()
        return rotate(center, x, y, theta)

    install_member(extract_checked, "_cancellable", value=True)
    install_member(core, "_extract_strokes", extract_checked)
    install_member(core, "_draw_strokes", draw_checked)
    install_member(core, "_rotate", rotate_checked)
