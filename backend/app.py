# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""手写体生成 API、持久化任务与桌面静态资源入口."""

from __future__ import annotations

import ast
import asyncio
import base64
import gc
import importlib
import io
import itertools
import math
import mimetypes
import re
import shutil
import stat
import tempfile
import time
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass
from functools import wraps
from pathlib import Path
from typing import Annotated, BinaryIO, Protocol, TypedDict, cast
from uuid import uuid4

import psutil
import pypandoc
import schedule_clean
import sentry_sdk
import uvicorn
from app_environment import get_environment_value
from docx_extractor import extract_text_from_docx
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    File,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from handdrawn_filter import render_inline_markdown_images
from handright import Feature, Template, handwrite
from library_boundary import member
from logging_setup import get_logger
from math_page_layout import RuledTemplate
from PIL import Image, ImageDraw, ImageFont
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.starlette import StarletteIntegration
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from starlette.datastructures import UploadFile as StarletteUploadFile
from symbol_fallback import (
    font_bbox_of,
    font_path_of,
    font_size_of,
    get_cached_image_font,
    is_math_glyph,
    math_text_bbox,
    measure_drawn_advance,
    normalize_text_for_font,
)
from task_store import cleanup_expired as cleanup_expired_generation_tasks
from task_store import get_active_task_count as get_generation_active_task_count
from task_store import get_queue_metrics as get_generation_queue_metrics
from task_store import get_task as get_generation_task
from task_store import pop_task as pop_generation_task
from task_store import read_result_file
from task_store import set_task as set_generation_task
from task_types import GenerateHandwritingParams, GenerationTask, form_dependency_from_model
from werkzeug.utils import secure_filename

type Font = ImageFont.FreeTypeFont | ImageFont.ImageFont
type ReportProgress = Callable[[str, str, int], None]
type RequestResponseEndpoint = Callable[[Request], Awaitable[Response]]


def _delete_directory_contents(directory: Path) -> None:
    for child in directory.iterdir():
        if child.is_dir() and not child.is_symlink():
            _delete_directory_contents(child)
            child.rmdir()
        elif not safe_remove_single_file(str(child), max_retries=2):
            error = f"Failed to remove file {child}"
            raise OSError(error)


def safe_remove_directory(directory_path: str, max_retries: int = 5) -> bool:
    """2026-10-15：重试删除临时目录，失败后写入后续清理标记."""
    directory = Path(directory_path)
    for attempt in range(max_retries):
        if not directory.exists():
            return True
        gc.collect()
        time.sleep(0.2 * (attempt + 1))
        try:
            _delete_directory_contents(directory)
            directory.rmdir()
        except OSError:
            logger.warning("Attempt %s to delete %s failed", attempt + 1, directory, exc_info=True)
            if attempt < max_retries - 1:
                time.sleep(attempt + 1)
        else:
            return True
    try:
        (directory / ".cleanup_later").write_text(
            f"Failed to delete at {time.time()}", encoding="utf-8"
        )
    except OSError:
        logger.warning("Failed to mark directory for cleanup: %s", directory, exc_info=True)
    return False


def safe_remove_single_file(file_path: str, max_retries: int = 3) -> bool:
    """重试删除文件，只为当前用户增加必要的读写权限."""
    path = Path(file_path)
    for attempt in range(max_retries):
        try:
            if not path.exists():
                return True
            path.chmod(path.stat().st_mode | stat.S_IWUSR | stat.S_IRUSR)
            gc.collect()
            time.sleep(0.1)
            path.unlink()
        except OSError:
            logger.warning("Failed to delete file %s", path, exc_info=True)
            if attempt < max_retries - 1:
                time.sleep(0.3 * (attempt + 1))
        else:
            return True
    return False


def safe_remove_file(file_path: str, max_retries: int = 3) -> bool:
    """重试删除响应文件，并记录失败状态."""
    result = safe_remove_single_file(file_path, max_retries)
    if not result:
        logger.error("Failed to delete file after %s attempts: %s", max_retries, file_path)
    return result


def safe_save_and_close_image(image: Image.Image, image_path: str) -> bool:
    """保存图像，失败时记录诊断，调用者负责其余生命周期."""
    try:
        image.save(image_path)
    except OSError:
        logger.exception("Failed to save image %s", image_path)
        return False
    else:
        return True


def cleanup_marked_directories() -> None:
    """清理超过一小时仍带有清理标记的临时目录."""
    base = Path("temp")
    base.mkdir(exist_ok=True)
    cleanup_age_seconds = 3600
    for directory in base.iterdir():
        marker = directory / ".cleanup_later"
        if not directory.name.startswith("tmp") or not marker.is_file():
            continue
        try:
            prefix, _, timestamp = marker.read_text(encoding="utf-8").partition(
                "Failed to delete at "
            )
            if not prefix and timestamp and time.time() - float(timestamp) > cleanup_age_seconds:
                safe_remove_directory(str(directory), max_retries=2)
        except (OSError, ValueError):
            logger.warning("Failed to inspect cleanup marker %s", marker, exc_info=True)


# 桌面版（Electron + PyInstaller 打包）标志，由 desktop_main.py 设置
DESKTOP_MODE = get_environment_value("DESKTOP_MODE", "false").lower() == "true"


def read_app_version() -> str:
    """应用版本号，供前端页面展示.

    优先环境变量：桌面版由 Electron 传 app.getVersion()，拿到的是真正安装的那个版本；
    否则读随包分发的 VERSION（发版时由 scripts/sync-version.js 写入，进后端镜像与
    PyInstaller 的 datas）；都没有就返回空串，前端不显示。
    """
    override = get_environment_value("HANDWRITING_APP_VERSION", "").strip()
    if override:
        return override
    version_file = Path(__file__).with_name("VERSION")
    try:
        return version_file.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


app_version = read_app_version()
current_path = str(Path.cwd())
output_path = str(Path.cwd() / "output")
for directory in (output_path, "textfileprocess", "imagefileprocess"):
    Path(directory).mkdir(exist_ok=True)


font_assets_dir = get_environment_value("FONT_ASSETS_DIR", "./font_assets")
font_assets_bundled_dir = get_environment_value("FONT_ASSETS_BUNDLED_DIR", "./font_assets")


def sync_font_assets(source_dir: str, target_dir: str) -> None:
    """将随包字体补充到可写字体目录，不覆盖用户已有文件."""
    source, target = Path(source_dir), Path(target_dir)
    if source.resolve() == target.resolve() or not source.is_dir() or not target.is_dir():
        return
    for path in source.iterdir():
        destination = target / path.name
        if path.suffix.lower() == ".ttf" and path.is_file() and not destination.exists():
            shutil.copy2(path, destination)


Path(font_assets_dir).mkdir(parents=True, exist_ok=True)
sync_font_assets(font_assets_bundled_dir, font_assets_dir)
font_file_names = [
    path.name
    for path in Path(font_assets_dir).iterdir()
    if path.is_file() and path.suffix == ".ttf"
]


# sentry部分 7.7
# 桌面版由 desktop_main.py 设 SENTRY_DSN="" 关闭上报，避免把用户本地错误发到线上项目
_sentry_dsn = get_environment_value(
    "SENTRY_DSN",
    "",
)
if _sentry_dsn:
    sentry_sdk.init(
        dsn=_sentry_dsn,
        integrations=[
            StarletteIntegration(),
            FastApiIntegration(),
        ],
        # Set traces_sample_rate to 1.0 to capture 100%
        # of transactions for performance monitoring.
        # We recommend adjusting this value in production.
        traces_sample_rate=1.0,
    )

# 启动计划任务线程, 定时清理
schedule_clean.start_schedule_thread()

logger = get_logger(__name__)

app = FastAPI()

# 桌面版由 desktop_main.py 设成本应用窗口的源（http://127.0.0.1:<port>）。
# 前端与后端同源、本来就不依赖 CORS，所以桌面版把白名单收紧到这一个来源；
# Web 部署不设该变量，沿用原来的宽松配置。
_allowed_origin = get_environment_value("HANDWRITING_ALLOWED_ORIGIN", "")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[_allowed_origin] if _allowed_origin else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _origin_of(url: str | None) -> str | None:
    """从 URL 里取出 scheme://host:port，取不到返回 None."""
    match = re.match(r"^https?://[^/]+", url or "")
    return match.group(0) if match else None


def foreign_origin(
    origin_header: str | None, referer_header: str | None, sec_fetch_site: str | None = None
) -> str | None:
    """请求来自本应用之外的站点时返回该来源（或 "cross-site"），否则返回 None.

    CORS 白名单只决定浏览器能否「读」响应，不阻止请求被发出，所以必须再主动拒绝：
    用户浏览任意网页时，那个页面可以往 127.0.0.1 发简单请求驱动本地渲染，甚至用
    <img> / <script> 这类跨源 GET 把任务结果消费掉（result 接口会 pop 掉任务）。

    判断依据三条：Origin（跨源请求一定有，表单 POST 也带）、Referer（可能被
    Referrer-Policy 去掉）、以及 Sec-Fetch-Site —— 跨源 GET 可能两个都没有，
    但现代浏览器会带上这个头标明发起方：同源是 same-origin、别的站点是 cross-site、
    用户直接输网址是 none。同源 GET 三条都不命中，放行。
    """
    if not _allowed_origin:
        return None
    if sec_fetch_site == "cross-site":
        return origin_header or referer_header or "cross-site"
    origin = origin_header or _origin_of(referer_header)
    if origin and origin != _allowed_origin:
        return origin
    return None


if _allowed_origin:

    @app.middleware("http")
    async def reject_foreign_origin(
        request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        """拒绝从其他网页发送到本地桌面后端的跨站请求."""
        source = foreign_origin(
            request.headers.get("origin"),
            request.headers.get("referer"),
            request.headers.get("sec-fetch-site"),
        )
        if source:
            logger.warning("拒绝跨站请求: %s -> %s", source, request.url.path)
            return JSONResponse(
                status_code=403,
                content={"status": "fail", "message": "跨站请求被拒绝"},
            )
        return await call_next(request)


# 自定义 422 错误响应，把字段名提取出来让前端更易读
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(
    _request: Request, exc: RequestValidationError
) -> JSONResponse:
    """将表单验证错误转换为带字段名的响应."""
    missing_fields: list[str] = []
    invalid_fields: list[str] = []
    for err in exc.errors():
        loc = ".".join(str(part) for part in err["loc"] if part not in ("body", "query", "path"))
        if err["type"] in ("missing", "value_error.missing"):
            missing_fields.append(loc)
        else:
            invalid_fields.append(f"{loc}: {err['msg']}")

    if missing_fields:
        message = f"缺少必填字段: {', '.join(missing_fields)}"
    else:
        message = f"字段验证失败: {', '.join(invalid_fields)}"

    return JSONResponse(
        status_code=422,
        content={
            "status": "fail",
            "message": message,
            "errors": [
                {
                    "field": ".".join(
                        str(part) for part in e["loc"] if part not in ("body", "query", "path")
                    ),
                    "message": e["msg"],
                }
                for e in exc.errors()
            ],
        },
    )


# 设置Flask app的logger级别

limiter = Limiter(key_func=get_remote_address, default_limits=["1000 per 5 minute"])
app.state.limiter = limiter


def rate_limit_error_handler(request: Request, exception: Exception) -> Response:
    """2026-10-15：在框架通用异常接口处校验具体限流类型。."""
    if not isinstance(exception, RateLimitExceeded):
        raise exception
    return _rate_limit_exceeded_handler(request, exception)


app.add_exception_handler(RateLimitExceeded, rate_limit_error_handler)


# 创建一个新的白色图片，并添加间隔的线条作为背景
@dataclass(frozen=True)
class NotebookOptions:
    """2026-10-15：笔记本底图的行距、边距与辅助线布局."""

    line_spacing: int
    top_margin: int
    bottom_margin: int
    left_margin: int
    right_margin: int
    underlined: bool


def create_notebook_image(width: int, height: int, layout: NotebookOptions) -> Image.Image:
    """创建底图，在分配像素及绘制辅助线前验证尺寸与行距."""
    if width <= 0 or height <= 0 or layout.line_spacing <= 0:
        error = "Image dimensions and line spacing must be positive"
        raise ValueError(error)
    image = Image.new("RGB", (width, height), "white")
    if layout.underlined:
        draw = ImageDraw.Draw(image)
        # 2026-10-18：横线随纸张宽度缩放，避免 Word 缩图时滤掉单像素细线。
        line_width = max(1, (width + 599) // 600)
        for y in range(
            layout.top_margin + layout.line_spacing,
            height - layout.bottom_margin,
            layout.line_spacing,
        ):
            draw.line(
                (layout.left_margin, y, width - layout.right_margin, y),
                fill="black",
                width=line_width,
            )
    return image


class _ParagraphLike(Protocol):
    text: str


class _WordDocumentLike(Protocol):
    paragraphs: Sequence[_ParagraphLike]


class _PdfPageLike(Protocol):
    def extract_text(self) -> str | None:
        """返回页面文本."""


class _PdfReaderLike(Protocol):
    pages: Sequence[_PdfPageLike]


def read_docx(file_path: str) -> str:
    """优先读取 Word 原生公式与表格，失败时使用段落文本兜底."""
    try:
        return extract_text_from_docx(file_path)
    except Exception:
        logger.exception("DOCX structure extraction failed; falling back to paragraph text")
    constructor = cast(
        "Callable[[str], _WordDocumentLike]", member(importlib.import_module("docx"), "Document")
    )
    return "\n".join(paragraph.text for paragraph in constructor(file_path).paragraphs)


def _detect_pandoc() -> bool:
    try:
        pypandoc.get_pandoc_path()
    except OSError:
        if DESKTOP_MODE:
            return False
        try:
            pypandoc.download_pandoc()
        except Exception:
            logger.exception("Pandoc download failed; using DOCX fallback")
            return False
        return True
    else:
        return True


_pandoc_available = _detect_pandoc()


def convert_docx_to_text(docx_file_path: str) -> str:
    """提取 DOCX 内容，按可用工具回退到 pandoc 或普通段落."""
    try:
        return extract_text_from_docx(docx_file_path)
    except Exception:
        logger.exception("DOCX extraction failed for %s", docx_file_path)
    return (
        pypandoc.convert_file(docx_file_path, "plain")
        if _pandoc_available
        else read_docx(docx_file_path)
    )


def read_pdf(file_path: str) -> str:
    """按需载入 PDF 文本提取器，并保留页面顺序."""
    constructor = cast(
        "Callable[[BinaryIO], _PdfReaderLike]",
        member(importlib.import_module("PyPDF2"), "PdfReader"),
    )
    with Path(file_path).open("rb") as source:
        reader = constructor(source)
        return "".join(page.extract_text() or "" for page in reader.pages)


# A line containing only three or more dashes forces a new page.
_PAGE_BREAK_RE = re.compile(r"(?m)^[ \t]*-{3,}[ \t]*$")

# A line prefixed with ">>>" is right-aligned. One optional following space is
# part of the marker and is removed before rendering.
_RIGHT_ALIGN_RE = re.compile(r"^[ \t]*>>>[ \t]?")


def _alignment_advance(char: str, template: Template, *, math_layout: bool, grid: bool) -> float:
    font = template.get_font()
    word_spacing = template.get_word_spacing()
    if not math_layout:
        left, _, right, _ = font_bbox_of(font, char)
        return right - left + word_spacing
    step = measure_drawn_advance(char, font)
    bbox = math_text_bbox(char, font, font_path_of(font))
    if grid:
        cell = max(1, font_size_of(font) + word_spacing)
        return math.ceil(max(step, bbox[2]) / cell) * cell if is_math_glyph(char) else cell
    return max(1, step + word_spacing, bbox[2] if is_math_glyph(char) else 1)


def apply_right_align(text: str, template: Template) -> str:
    """Replace right-align markers with full-width-space padding."""
    if ">>>" not in text:
        return text

    font = template.get_font()
    width = template.get_size()[0]
    usable_width = width - template.get_left_margin() - template.get_right_margin()
    last_glyph_start_limit = usable_width - font_size_of(font)
    math_layout = any(is_math_glyph(char) for char in text)
    grid = math_layout and Feature.GRID_LAYOUT in template.get_features()

    def advance(char: str) -> float:
        return _alignment_advance(char, template, math_layout=math_layout, grid=grid)

    pad_unit = advance("　")
    output: list[str] = []
    aligned_count = 0

    for line in text.split("\n"):
        marker = _RIGHT_ALIGN_RE.match(line)
        if not marker:
            output.append(line)
            continue

        content = line[marker.end() :]
        if not content:
            output.append("")
            aligned_count += 1
            continue

        # Handright decides whether to wrap before drawing each glyph. Its
        # threshold reserves one nominal font-size cell at the right edge.
        # Negative word spacing can make an advance negative, so the furthest
        # glyph start is not necessarily the final glyph's start.
        prefix_width = 0
        max_prefix_width = 0
        for char in content:
            max_prefix_width = max(max_prefix_width, prefix_width)
            if math_layout:
                bbox = math_text_bbox(char, font, font_path_of(font))
                max_prefix_width = max(max_prefix_width, prefix_width + bbox[2] - min(0, bbox[0]))
            prefix_width += advance(char)
        available_padding = (
            usable_width if math_layout else last_glyph_start_limit
        ) - max_prefix_width

        if pad_unit > 0 and available_padding > 0:
            # Handright perturbs glyph sizes and spacing during rendering. Keep
            # one full-width cell free so small variations do not wrap the last
            # character onto a new line.
            pad_count = max(0, int(available_padding // pad_unit) - 1)
        else:
            pad_count = 0

        output.append("　" * pad_count + content)
        aligned_count += 1

    if aligned_count:
        logger.info("right-align applied to %s line(s)", aligned_count)
    return "\n".join(output)


def handwrite_with_page_breaks(
    text: str,
    template: Template,
    font_path: str | None = None,
    *,
    is_single_page_preview: bool = False,
) -> Iterable[Image.Image]:
    """Render text while honoring manual page-break, alignment markers, and font glyph fallback."""
    if font_path is None and hasattr(template, "get_font"):
        font_obj = template.get_font()
        font_path = font_path_of(font_obj)

    # 非侵入式字符清洗与基于当前字体的字形兜底（解决特殊空格、缺失数学符号等留白问题）
    normalized = normalize_text_for_font(text, font_path)
    normalized = normalized.replace("\r\n", "\n").replace("\r", "\n")
    aligned = apply_right_align(normalized, template)

    if not _PAGE_BREAK_RE.search(aligned):
        return render_inline_markdown_images(aligned, template, handwrite)

    raw_chunks = _PAGE_BREAK_RE.split(aligned)
    chunks: list[str] = []
    for index, raw_chunk in enumerate(raw_chunks):
        chunk = raw_chunk
        if index > 0 and chunk.startswith("\n"):
            chunk = chunk[1:]
        if index < len(raw_chunks) - 1 and chunk.endswith("\n"):
            chunk = chunk[:-1]
        if chunk.strip():
            chunks.append(chunk)
    logger.info("manual page break detected: %s chunk(s)", len(chunks))

    if not chunks:
        return render_inline_markdown_images("", template, handwrite)

    if is_single_page_preview:
        # 单页预览只需处理第 1 个 chunk
        return render_inline_markdown_images(chunks[0], template, handwrite)

    return itertools.chain.from_iterable(
        render_inline_markdown_images(chunk, template, handwrite) for chunk in chunks
    )


def handle_exceptions[**P](f: Callable[P, Awaitable[Response]]) -> Callable[P, Awaitable[Response]]:
    """为异步请求保留原签名并返回结构化错误响应."""

    @wraps(f)
    async def decorated_function(*args: P.args, **kwargs: P.kwargs) -> Response:
        try:
            return await f(*args, **kwargs)
        except Exception as e:
            logger.exception("An error occurred during the request")
            return JSONResponse({"status": "error", "message": str(e)}, status_code=500)

    return decorated_function


# WebSocket 推送（仍需内存存储，仅同进程有效）
class ProgressHook(Protocol):
    """2026-10-15：生成进度的关键词契约."""

    def __call__(self, *, stage: str, message: str, progress: int) -> None:
        """上报当前生成阶段与百分比."""


class GenerationPayload(TypedDict):
    """2026-10-15：后台任务只持有内存文件与已校验表单."""

    params: GenerateHandwritingParams
    background_image: bytes | None
    font_file: bytes | None


_notification_tasks: set[asyncio.Task[None]] = set()
task_websocket_connections: dict[str, set[WebSocket]] = {}
task_websocket_connections_lock = asyncio.Lock()

# 同时执行的上限——控制 generate_handwriting_impl 的真正并发数
# 超出部分在 semaphore 处排队等待，避免 CPU 密集任务互相挤占
MAX_CONCURRENT_EXECUTIONS = 2
_generation_semaphore = asyncio.Semaphore(MAX_CONCURRENT_EXECUTIONS)


def build_task_status_payload(
    task_id: str, task: GenerationTask | None = None
) -> dict[str, object] | None:
    """组合任务快照与排队信息，未知任务返回 None."""
    if task is None:
        task = get_generation_task(task_id)
    if task is None:
        return None
    queue_metrics = get_generation_queue_metrics(task_id)
    return {
        "status": "success",
        "task_id": task_id,
        "task_status": task.get("status"),
        "task_stage": task.get("stage"),
        "task_message": task.get("message"),
        "task_progress": task.get("progress"),
        "created_at": task.get("created_at"),
        "updated_at": task.get("updated_at"),
        "error_message": task.get("error_message"),
        "queue_pending_count": queue_metrics.get("queue_pending_count"),
        "queue_ahead_count": queue_metrics.get("queue_ahead_count"),
        "processing_count": queue_metrics.get("processing_count"),
        "active_task_count": queue_metrics.get("active_task_count"),
    }


async def register_task_websocket(task_id: str, websocket: WebSocket) -> None:
    """注册任务对应的 WebSocket 连接."""
    async with task_websocket_connections_lock:
        if task_id not in task_websocket_connections:
            task_websocket_connections[task_id] = set()
        task_websocket_connections[task_id].add(websocket)


async def unregister_task_websocket(task_id: str, websocket: WebSocket) -> None:
    """移除已断开的任务连接."""
    async with task_websocket_connections_lock:
        sockets = task_websocket_connections.get(task_id)
        if sockets is None:
            return
        sockets.discard(websocket)
        if len(sockets) == 0:
            task_websocket_connections.pop(task_id, None)


async def push_task_status_update(task_id: str) -> None:
    """向在线连接发送任务快照并清理断开的连接."""
    task = get_generation_task(task_id)
    if task is None:
        return
    payload = build_task_status_payload(task_id, task=task)
    if payload is None:
        return
    async with task_websocket_connections_lock:
        sockets = list(task_websocket_connections.get(task_id, set()))
    if len(sockets) == 0:
        return

    dead_sockets: list[WebSocket] = []
    for socket in sockets:
        try:
            await socket.send_json(payload)
        except (OSError, RuntimeError, WebSocketDisconnect):
            dead_sockets.append(socket)

    if dead_sockets:
        async with task_websocket_connections_lock:
            current_sockets = task_websocket_connections.get(task_id, set())
            for socket in dead_sockets:
                current_sockets.discard(socket)
            if len(current_sockets) == 0 and task_id in task_websocket_connections:
                task_websocket_connections.pop(task_id, None)


def model_to_dict(model: GenerateHandwritingParams) -> dict[str, str]:
    """将已校验表单转换为字符串映射，第三方模型边界再次收窄."""
    raw: dict[str, object] = model.model_dump(exclude_none=True, by_alias=True)
    return {key: value for key, value in raw.items() if isinstance(value, str)}


async def _upload_bytes(source: UploadFile | str | bytes | None) -> bytes | None:
    if isinstance(source, StarletteUploadFile):
        return await source.read()
    return source if isinstance(source, bytes) else None


def _ink_color(source: str) -> int | tuple[int, int, int]:
    # 2026-10-15：只解析数字和 RGB(A) 字面量；RGB 底图忽略输入颜色的 Alpha 通道。
    try:
        value: object = ast.literal_eval(source)
    except (ValueError, SyntaxError) as error:
        raise HTTPException(status_code=400, detail="Invalid ink color") from error
    maximum_channel = 255
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= maximum_channel:
        return value
    if isinstance(value, tuple | list):
        items = cast("Sequence[object]", value)
        channels = [
            channel
            for channel in items
            if isinstance(channel, int)
            and not isinstance(channel, bool)
            and 0 <= channel <= maximum_channel
        ]
        if len(channels) in (3, 4) and len(channels) == len(items):
            return channels[0], channels[1], channels[2]
    raise HTTPException(
        status_code=400, detail="Ink color must contain RGB or RGBA channels in 0..255"
    )


def _nonnegative_float(data: dict[str, str], key: str) -> float:
    value = float(data.get(key, "0"))
    if not math.isfinite(value) or value < 0:
        raise HTTPException(status_code=400, detail=f"{key} must be a finite nonnegative number")
    return value


def _generation_rejection(data: dict[str, str]) -> Response | None:
    cpu_usage = psutil.cpu_percent(interval=1)
    if cpu_usage > float(get_environment_value("CPU_USAGE_LIMIT", "90")):
        return JSONResponse(
            {
                "status": "waiting",
                "message": f"CPU usage is too high. Please retry. Current usage: {cpu_usage}%",
            },
            status_code=429,
        )
    if int(data["line_spacing"]) <= 0 or int(data["font_size"]) <= 0:
        raise HTTPException(status_code=400, detail="Font size and line spacing must be positive")
    return None


def _background_for(data: dict[str, str], background: bytes | None) -> Image.Image:
    if "width" in data and "height" in data:
        layout = NotebookOptions(
            line_spacing=int(data["line_spacing"]),
            top_margin=int(data["top_margin"]),
            bottom_margin=int(data["bottom_margin"]),
            left_margin=int(data["left_margin"]),
            right_margin=int(data["right_margin"]),
            underlined=data.get("isUnderlined") == "true",
        )
        return create_notebook_image(int(data["width"]), int(data["height"]), layout)
    if background is None:
        raise HTTPException(status_code=400, detail="Missing required field: background_image")
    try:
        image = Image.open(io.BytesIO(background))
        image.load()
    except OSError as error:
        raise HTTPException(status_code=400, detail="Invalid image format") from error
    return image.convert("RGB") if image.mode in ("RGBA", "LA") else image


def _font_for(data: dict[str, str], uploaded: bytes | None) -> tuple[Font, str | None]:
    if uploaded is not None:
        return ImageFont.truetype(io.BytesIO(uploaded), size=int(data["font_size"])), None
    option = data.get("font_option", "")
    if option not in font_file_names:
        raise HTTPException(status_code=400, detail="Missing font file")
    path = str(Path(font_assets_dir) / option)
    return get_cached_image_font(path, int(data["font_size"])), path


def _template_for(data: dict[str, str], background: Image.Image, font: Font) -> Template:
    probability = _nonnegative_float(data, "strikethrough_probability")
    if probability > 1:
        raise HTTPException(status_code=400, detail="Strikethrough probability must be in 0..1")
    template_type = (
        RuledTemplate
        if data.get("isUnderlined") == "true" and "width" in data and "height" in data
        else Template
    )
    template = template_type(
        background=background,
        font=font,
        fill=_ink_color(data["fill"]),
        line_spacing=int(data["line_spacing"]),
        left_margin=int(data["left_margin"]),
        top_margin=int(data["top_margin"]),
        right_margin=int(data["right_margin"]) - int(data["word_spacing"]) * 2,
        bottom_margin=int(data["bottom_margin"]),
        word_spacing=int(data["word_spacing"]),
        line_spacing_sigma=_nonnegative_float(data, "line_spacing_sigma"),
        font_size_sigma=_nonnegative_float(data, "font_size_sigma"),
        word_spacing_sigma=_nonnegative_float(data, "word_spacing_sigma"),
        perturb_x_sigma=_nonnegative_float(data, "perturb_x_sigma"),
        perturb_y_sigma=_nonnegative_float(data, "perturb_y_sigma"),
        perturb_theta_sigma=_nonnegative_float(data, "perturb_theta_sigma"),
        strikethrough_probability=probability,
        strikethrough_length_sigma=_nonnegative_float(data, "strikethrough_length_sigma"),
        strikethrough_width_sigma=_nonnegative_float(data, "strikethrough_width_sigma"),
        strikethrough_angle_sigma=_nonnegative_float(data, "strikethrough_angle_sigma"),
        strikethrough_width=_nonnegative_float(data, "strikethrough_width"),
        ink_depth_sigma=_nonnegative_float(data, "ink_depth_sigma"),
    )
    if isinstance(template, RuledTemplate):
        template.ruled_origin = int(data["top_margin"])
    return template


def _english_spacing(text: str) -> str:
    english = re.compile(r"""^[a-zA-Z0-9.,!?;:\'\"()\-_]+$""")
    lines: list[str] = []
    for line in text.split("\n"):
        parts = line.split(" ")
        output = [parts[0]]
        for previous, current in itertools.pairwise(parts):
            output.extend(
                (
                    "  " if english.fullmatch(previous) and english.fullmatch(current) else " ",
                    current,
                )
            )
        lines.append("".join(output))
    return "\n".join(lines)


def _png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", compress_level=1)
    return buffer.getvalue()


def _preview_response(
    images: Iterable[Image.Image], background: Image.Image, *, single: bool, report: ReportProgress
) -> Response:
    if single:
        first = next(iter(images), None)
        result = Response(
            content=_png_bytes(first if first is not None else background), media_type="image/png"
        )
    else:
        encoded = [base64.b64encode(_png_bytes(image)).decode("ascii") for image in images]
        if not encoded:
            encoded.append(base64.b64encode(_png_bytes(background)).decode("ascii"))
        result = JSONResponse({"status": "success", "images": encoded})
    report("finalizing", "正在返回预览结果", 100)
    return result


def _zip_response(images: Iterable[Image.Image], report: ReportProgress) -> Response:
    base = Path("temp")
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=base) as temporary:
        directory = Path(temporary)
        pages = directory / "pages"
        pages.mkdir()
        for index, image in enumerate(images):
            report("rendering", f"正在处理第 {index + 1} 页", min(90, 60 + min(index, 30)))
            image.save(pages / f"{index}.png")
        report("packaging", "正在打包ZIP文件", 92)
        archive = shutil.make_archive(str(directory / "images"), "zip", pages)
        data = Path(archive).read_bytes()
    report("finalizing", "正在返回ZIP结果", 100)
    return Response(
        content=data,
        media_type="application/zip",
        headers={"Content-Disposition": "attachment; filename=images.zip"},
    )


def _pdf_response(images: Iterable[Image.Image], report: ReportProgress) -> Response:
    # 2026-10-15：PDF 引擎只在实际导出时载入，保留桌面冷启动的惰性依赖。
    exporter = cast(
        "Callable[[Iterable[Image.Image]], str | None]",
        member(importlib.import_module("pdf"), "generate_pdf"),
    )
    report("packaging", "正在导出PDF文件", 92)
    path = exporter(images)
    if path is None:
        return JSONResponse({"status": "error", "message": "PDF export failed"}, status_code=500)
    try:
        data = Path(path).read_bytes()
    finally:
        safe_remove_file(path)
    report("finalizing", "正在返回PDF结果", 100)
    return Response(
        content=data,
        media_type="application/pdf",
        headers={"Content-Disposition": "attachment; filename=images.pdf"},
    )


def _render_handwriting(
    params: GenerateHandwritingParams,
    background_image: bytes | None,
    font_file: bytes | None,
    progress_hook: ProgressHook | None,
) -> Response:
    def report(stage: str, message: str, progress: int) -> None:
        if progress_hook is not None:
            progress_hook(stage=stage, message=message, progress=progress)

    try:
        report("validating", "正在校验参数", 5)
        data = model_to_dict(params)
        report("system_check", "正在检查服务器负载", 10)
        rejection = _generation_rejection(data)
        if rejection is not None:
            return rejection
        report("prepare_background", "正在准备背景图", 20)
        background = _background_for(data, background_image)
        report("prepare_font", "正在加载字体", 30)
        font, path = _font_for(data, font_file)
        template = _template_for(data, background, font)
        text = (
            _english_spacing(data["text"])
            if data.get("enableEnglishSpacing") == "true"
            else data["text"]
        )
        preview, pdf = data["preview"] == "true", data.get("pdf_save") == "true"
        single = preview and data.get("full_preview") == "false" and not pdf
        report("rendering", "正在生成手写图像", 45)
        images = handwrite_with_page_breaks(
            text, template, font_path=path, is_single_page_preview=single
        )
        if pdf:
            return _pdf_response(images, report)
        if preview:
            return _preview_response(images, background, single=single, report=report)
        return _zip_response(images, report)
    except HTTPException as error:
        return JSONResponse(
            {"status": "fail", "message": str(error.detail)}, status_code=error.status_code
        )
    except (ValueError, TypeError, OverflowError) as error:
        return JSONResponse(
            {"status": "fail", "message": f"Invalid generation parameters: {error}"},
            status_code=400,
        )


async def generate_handwriting_impl(
    params: GenerateHandwritingParams,
    background_image: UploadFile | str | bytes | None = None,
    font_file: UploadFile | str | bytes | None = None,
    progress_hook: ProgressHook | None = None,
) -> Response:
    """2026-10-15：异步读取上传文件，在线程完整消费惰性渲染结果与导出文件."""
    background = await _upload_bytes(background_image)
    font = await _upload_bytes(font_file)
    return await asyncio.to_thread(_render_handwriting, params, background, font, progress_hook)


async def run_generation_task(task_id: str, payload: GenerationPayload) -> None:
    """通过并发信号量执行任务并持久化进度和结果."""
    started_at = time.perf_counter()
    logger.info("Generation task started, task_id=%s elapsed=0.000s", task_id)
    set_generation_task(
        task_id,
        status="processing",
        stage="started",
        message="任务已开始",
        progress=1,
    )
    await push_task_status_update(task_id)
    loop = asyncio.get_running_loop()

    def schedule_notification() -> None:
        notification = asyncio.create_task(push_task_status_update(task_id))
        _notification_tasks.add(notification)
        notification.add_done_callback(_notification_tasks.discard)

    try:

        def progress_notify(*, stage: str, message: str, progress: int) -> None:
            set_generation_task(task_id, stage=stage, message=message, progress=progress)
            loop.call_soon_threadsafe(schedule_notification)

        async with _generation_semaphore:
            # 拿到信号量后，将阶段更新为"正在执行" 由于这里是协程，所以并不会占据很多资源 4.17.2026
            set_generation_task(task_id, stage="executing", message="正在生成中")
            await push_task_status_update(task_id)

            response = await generate_handwriting_impl(
                progress_hook=progress_notify,
                **payload,
            )
        response_body = bytes(response.body)
        response_headers: dict[str, str] = {}
        if "content-disposition" in response.headers:
            response_headers["Content-Disposition"] = response.headers["content-disposition"]
        set_generation_task(
            task_id,
            status="completed",
            response_status_code=response.status_code,
            response_content_type=response.headers.get("content-type")
            or response.media_type
            or "application/octet-stream",
            response_headers=response_headers,
            response_body=response_body,
            stage="completed",
            message="任务处理完成",
            progress=100,
        )
        await push_task_status_update(task_id)
    except Exception as e:
        logger.exception(
            "Generation task failed, task_id=%s elapsed=%.3fs",
            task_id,
            time.perf_counter() - started_at,
        )
        set_generation_task(
            task_id,
            status="failed",
            error_message=str(e),
            stage="failed",
            message="任务处理失败",
        )
        await push_task_status_update(task_id)
    else:
        logger.info(
            "Generation task completed, task_id=%s elapsed=%.3fs",
            task_id,
            time.perf_counter() - started_at,
        )


@app.post("/api/generate_handwriting")
@limiter.limit("200 per 5 minute")
@handle_exceptions  # 错误捕获的装饰器7.15
async def generate_handwriting(
    request: Request,
    background_tasks: BackgroundTasks,
    params: Annotated[
        GenerateHandwritingParams, Depends(form_dependency_from_model(GenerateHandwritingParams))
    ],
    background_image: Annotated[UploadFile | str | None, File()] = None,
    font_file: Annotated[UploadFile | str | None, File()] = None,
) -> JSONResponse:
    """接收生成请求并返回可轮询的持久化任务 ID."""
    # 2026-10-15：保留请求参数供限流装饰器使用，业务入队不依赖部署域名。
    del request
    cleanup_expired_generation_tasks()

    # ── 并发上限检查 ────────────────────────────────────────────────────
    max_active_tasks = 8  # pending + processing 总数上限，根据服务器配置调整
    # 队列满时给用户的建议等待时间（秒），固定值比瞎算可靠
    estimated_wait_seconds = 60

    active_count = get_generation_active_task_count()
    if active_count >= max_active_tasks:
        return JSONResponse(
            {
                "status": "queue_full",
                "message": "当前服务器队列已满，请稍后再试",
                "active_task_count": active_count,
                "max_active_tasks": max_active_tasks,
                "estimated_wait_seconds": estimated_wait_seconds,
            },
            status_code=503,
        )
    # ────────────────────────────────────────────────────────────────────

    background_image_bytes = None
    # 注意：starlette.datastructures.UploadFile 可能是 fastapi.UploadFile 的运行时类型
    # 用 hasattr 兼容两者：检查是否有 read 方法（UploadFile 特征）
    if isinstance(background_image, StarletteUploadFile):
        background_image_bytes = await background_image.read()

    font_file_bytes = None
    # 同样用 hasattr 兼容 starlette 和 fastapi 的 UploadFile
    if isinstance(font_file, StarletteUploadFile):
        font_file_bytes = await font_file.read()

    payload: GenerationPayload = {
        "params": params,
        "background_image": background_image_bytes,
        "font_file": font_file_bytes,
    }

    task_id = uuid4().hex
    now = time.time()
    set_generation_task(
        task_id,
        status="pending",
        stage="queued",
        message="任务排队中",
        progress=0,
        created_at=now,
        updated_at=now,
        response_status_code=None,
        response_content_type=None,
        response_headers={},
        error_message="",
    )
    background_tasks.add_task(run_generation_task, task_id, payload)

    return JSONResponse({"status": "accepted", "task_id": task_id})


@app.websocket("/api/generate_handwriting/ws/{task_id}")
async def generate_handwriting_task_websocket(websocket: WebSocket, task_id: str) -> None:
    # WebSocket 不走 HTTP 中间件，也不受 CORS 约束，必须自己校验来源
    """校验来源并建立任务状态订阅连接."""
    if foreign_origin(
        websocket.headers.get("origin"),
        websocket.headers.get("referer"),
        websocket.headers.get("sec-fetch-site"),
    ):
        await websocket.close(code=1008)
        return

    await websocket.accept()
    await register_task_websocket(task_id, websocket)
    try:
        task = get_generation_task(task_id)
        if task is None:
            await websocket.send_json(
                {"status": "error", "message": "Task not found", "task_id": task_id}
            )
            return
        await websocket.send_json(build_task_status_payload(task_id, task=task))

        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await unregister_task_websocket(task_id, websocket)


@app.get("/api/generate_handwriting/task/{task_id}")
@limiter.limit("600 per 5 minute")
@handle_exceptions
async def get_generate_handwriting_task_status(request: Request, task_id: str) -> Response:
    """读取任务状态和排队信息."""
    del request
    cleanup_expired_generation_tasks()
    task = get_generation_task(task_id)
    if task is None:
        return JSONResponse(
            {"status": "error", "message": "Task not found"},
            status_code=404,
        )
    return JSONResponse(build_task_status_payload(task_id, task=task))


@app.get("/api/generate_handwriting/task/{task_id}/result")
@limiter.limit("600 per 5 minute")
@handle_exceptions
async def get_generate_handwriting_task_result(request: Request, task_id: str) -> Response:
    """幂等读取生成结果，过期结果由 TTL 回收."""
    del request
    cleanup_expired_generation_tasks()
    task = get_generation_task(task_id)
    if task is None:
        return JSONResponse(
            {"status": "error", "message": "Task not found"},
            status_code=404,
        )

    task_status = task.get("status")
    if task_status in ("pending", "processing"):
        return JSONResponse(
            {"status": "processing", "message": "Task is still running"},
            status_code=409,
        )
    if task_status == "failed":
        pop_generation_task(task_id)
        return JSONResponse(
            {"status": "error", "message": task.get("error_message", "Task failed")},
            status_code=500,
        )

    # 从磁盘文件读取响应体
    result_file_path = task.get("result_file_path")
    response_body = read_result_file(result_file_path) if result_file_path else b""
    if response_body is None:
        response_body = b""

    # 这里**不能** pop 掉任务：GET 带销毁副作用的话，一个跨站的 <img>/<script>
    # 只要 URL 里带对 task_id 就能把用户的结果吃掉（来源头齐全时会被 foreign_origin
    # 挡掉，但老浏览器/WebView 可能三个头都不发）。读取保持幂等，回收交给 TTL ——
    # 「取过但没删」和「压根没取过」走的是同一条 cleanup_expired 路径，磁盘不会多占用。
    # 顺带也修了重试丢结果的问题：下载中途断线时 axios-retry 会重取，以前第二次必 404。
    return Response(
        content=response_body,
        media_type=task.get("response_content_type") or "application/octet-stream",
        status_code=task.get("response_status_code") or 200,
        headers=task.get("response_headers") or {},
    )


# @app.after_request
# def cleanup(response):
#     # 从请求上下文中获取文件路径
#     if temp_file_path is not None:
#         # 尝试删除文件
#     # 返回原始响应


def _process_text_upload(filename: str, content: bytes) -> Response:
    suffix = Path(filename).suffix.lower()
    allowed = {".docx", ".pdf", ".doc", ".txt", ".rtf"}
    if suffix not in allowed:
        return JSONResponse({"error": "Invalid file type"}, status_code=400)
    path = Path("textfileprocess") / f"{uuid4().hex}-{secure_filename(filename)}"
    try:
        path.write_bytes(content)
        if suffix == ".docx":
            text = convert_docx_to_text(str(path))
        elif suffix == ".pdf":
            text = read_pdf(str(path))
        elif suffix in (".txt", ".rtf"):
            text = path.read_text(encoding="utf-8", errors="replace")
        else:
            text = "doc文件暂不支持"
        return JSONResponse({"text": text})
    except Exception as error:
        logger.exception("Failed to read uploaded document %s", filename)
        return JSONResponse({"error": f"Error reading file: {error}"}, status_code=500)
    finally:
        safe_remove_file(str(path))


@app.post("/api/textfileprocess")
@limiter.limit("200 per 5 minute")
async def textfileprocess(request: Request, file: Annotated[UploadFile, File()]) -> Response:
    """在线程解析上传文本，避免文档转换阻塞请求事件循环."""
    del request
    if not file.filename:
        return JSONResponse({"error": "No file part in the request"}, status_code=400)
    return await asyncio.to_thread(_process_text_upload, file.filename, await file.read())


def _process_image_upload(filename: str, content: bytes) -> Response:
    if Path(filename).suffix.lower() not in {".jpf", ".png", ".jpg", ".jpeg"}:
        return JSONResponse({"error": "Invalid file type"}, status_code=400)
    path = Path("imagefileprocess") / f"{uuid4().hex}-{secure_filename(filename)}"
    try:
        path.write_bytes(content)
        detector = cast(
            "Callable[[str], tuple[float, float, float, float, float]]",
            member(importlib.import_module("identify"), "identify_distance"),
        )
        left, right, top, bottom, spacing = detector(str(path))
        return JSONResponse(
            {
                "marginLeft": left,
                "marginRight": right,
                "marginTop": top,
                "marginBottom": bottom,
                "lineSpacing": spacing,
            }
        )
    finally:
        safe_remove_file(str(path))


@app.post("/api/imagefileprocess")
@limiter.limit("200 per 5 minute")
async def imagefileprocess(request: Request, file: Annotated[UploadFile, File()]) -> Response:
    """按需载入图片检测引擎，在线程中读取边距与行距."""
    del request
    if not file.filename:
        return JSONResponse({"error": "No file part in the request"}, status_code=400)
    return await asyncio.to_thread(_process_image_upload, file.filename, await file.read())


def get_filenames_in_dir(directory: str) -> list[str]:
    """列出字体目录中的 TrueType 文件名."""
    return [
        path.name for path in Path(directory).iterdir() if path.is_file() and path.suffix == ".ttf"
    ]


@app.get("/api/fonts_info")
def get_fonts_info() -> JSONResponse:
    """返回可用字体文件名列表."""
    filenames = get_filenames_in_dir(font_assets_dir)
    logger.info("filenames: %s", filenames)
    if filenames == []:
        return JSONResponse({"error": "fontfile not found"}, status_code=400)
    return JSONResponse(filenames)


@app.get("/api/version")
def get_version() -> JSONResponse:
    """给前端页面展示的版本号."""
    return JSONResponse({"version": app_version})


@app.middleware("http")
async def after_request(request: Request, call_next: RequestResponseEndpoint) -> Response:
    """转发请求并保持统一响应中间件入口."""
    return await call_next(request)


# ── 桌面版：托管打包进 exe 的前端构建产物 ────────────────────────────
# 由 desktop_main.py 指向随包分发的 frontend/dist；仓库内运行时不设该变量，
# 路由行为与改动前完全一致（仍是纯 API 服务，静态资源交给 nginx）。
DIST_DIR = get_environment_value("HANDWRITING_DIST_DIR", "")


def _resolve_dist_file(rel_path: str) -> str | None:
    """在静态资源根目录内解析文件，阻止路径穿越与符号链接逃逸."""
    if not DIST_DIR:
        return None
    root = Path(DIST_DIR).resolve()
    target = (root / rel_path).resolve()
    if not target.is_relative_to(root):
        return None
    return str(target) if target.is_file() else None


if DIST_DIR and Path(DIST_DIR).is_dir():
    _NO_STORE = {"Cache-Control": "no-store"}

    @app.get("/{full_path:path}", include_in_schema=False)
    def serve_spa(full_path: str) -> FileResponse:
        # 未匹配的 /api 路径应返回 404，而不是回落到 index.html
        """返回桌面应用静态文件或 SPA 入口页面."""
        if full_path == "api" or full_path.startswith("api/"):
            raise HTTPException(status_code=404, detail="Not Found")

        file_path = _resolve_dist_file(full_path)
        if file_path is None:
            # history 模式路由（/About、/Introduce 等）回落到 index.html
            index_path = Path(DIST_DIR) / "index.html"
            if not index_path.is_file():
                raise HTTPException(status_code=404, detail="Not Found")
            return FileResponse(index_path, media_type="text/html", headers=_NO_STORE)

        media_type = mimetypes.guess_type(file_path)[0]
        # index.html 不缓存，与 nginx.conf 的 no-store 保持一致
        headers = _NO_STORE if Path(file_path).name == "index.html" else None
        return FileResponse(file_path, media_type=media_type, headers=headers)


def main() -> None:
    """启动本地开发服务，监听地址可由 HOST 环境变量指定."""
    cleanup_marked_directories()
    uvicorn.run(app, host=get_environment_value("HOST", "127.0.0.1"), port=5005, log_config=None)


if __name__ == "__main__":
    main()
