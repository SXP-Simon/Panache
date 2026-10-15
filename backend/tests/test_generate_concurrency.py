# Copyright (c) 2026 Simon and Handwriting Web contributors.
import logging
import os
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

import pytest
import requests

logger = logging.getLogger(__name__)


def http_json(method: str, url: str, data: dict | None = None, timeout: float = 30.0):
    with requests.request(method, url, data=data, timeout=timeout) as response:
        response.raise_for_status()
        return response.status_code, response.headers, response.json()


def http_binary(method: str, url: str, timeout: float = 60.0):
    with requests.request(method, url, timeout=timeout) as response:
        response.raise_for_status()
        return response.status_code, response.headers, response.content


@dataclass
class TaskResult:
    idx: int
    ok: bool
    total_seconds: float
    task_id: str
    status_code: int
    message: str


def _run_one_request(
    idx: int,
    base_url: str,
    form_base: dict,
    poll_interval: float,
    task_timeout: float,
) -> TaskResult:
    start = time.time()
    task_id = ""
    try:
        form_data = dict(form_base)
        form_data["text"] = f"[REQ-{idx}] " + form_data["text"]
        status_code, _, submit_json = http_json(
            "POST",
            f"{base_url}/api/generate_handwriting",
            data=form_data,
            timeout=30.0,
        )
        if status_code != 200 or submit_json.get("status") != "accepted":
            return TaskResult(
                idx=idx,
                ok=False,
                total_seconds=time.time() - start,
                task_id="",
                status_code=status_code,
                message=f"submit failed: {submit_json}",
            )
        task_id = submit_json["task_id"]

        deadline = time.time() + task_timeout
        while True:
            if time.time() > deadline:
                return TaskResult(
                    idx=idx,
                    ok=False,
                    total_seconds=time.time() - start,
                    task_id=task_id,
                    status_code=408,
                    message="task timeout while polling",
                )
            status_code, _, task_json = http_json(
                "GET",
                f"{base_url}/api/generate_handwriting/task/{task_id}",
                data=None,
                timeout=20.0,
            )
            if status_code != 200:
                return TaskResult(
                    idx=idx,
                    ok=False,
                    total_seconds=time.time() - start,
                    task_id=task_id,
                    status_code=status_code,
                    message=f"poll failed: {task_json}",
                )
            task_status = task_json.get("task_status")
            if task_status == "completed":
                break
            if task_status == "failed":
                return TaskResult(
                    idx=idx,
                    ok=False,
                    total_seconds=time.time() - start,
                    task_id=task_id,
                    status_code=500,
                    message=f"task failed: {task_json.get('error_message')}",
                )
            time.sleep(poll_interval)

        status_code, headers, body = http_binary(
            "GET",
            f"{base_url}/api/generate_handwriting/task/{task_id}/result",
            timeout=120.0,
        )
        ok = 200 <= status_code < 300 and len(body) > 0
        return TaskResult(
            idx=idx,
            ok=ok,
            total_seconds=time.time() - start,
            task_id=task_id,
            status_code=status_code,
            message=f"content_type={headers.get('Content-Type', '')}, bytes={len(body)}",
        )
    except Exception as error:
        logger.exception("Concurrent handwriting request failed")
        status_code = 0
        message = f"exception: {error}"
        if isinstance(error, requests.HTTPError) and error.response is not None:
            status_code = error.response.status_code
            message = f"http error: {error.response.text}"
        return TaskResult(
            idx=idx,
            ok=False,
            total_seconds=time.time() - start,
            task_id=task_id,
            status_code=status_code,
            message=message,
        )


@pytest.mark.load
def test_generate_handwriting_concurrency():
    base_url = os.getenv("HANDWRITING_BASE_URL", "http://127.0.0.1:5005").rstrip("/")
    total_requests = int(os.getenv("HANDWRITING_LOAD_REQUESTS", "6"))
    concurrency = int(os.getenv("HANDWRITING_LOAD_CONCURRENCY", "4"))
    poll_interval = float(os.getenv("HANDWRITING_POLL_INTERVAL", "1.0"))
    task_timeout = float(os.getenv("HANDWRITING_TASK_TIMEOUT", "300"))
    text_repeat = int(os.getenv("HANDWRITING_TEXT_REPEAT", "200"))

    if total_requests < 4:
        pytest.fail("HANDWRITING_LOAD_REQUESTS should be >= 4 to cover the 3+ requests scenario.")

    try:
        status_code, _, fonts = http_json(
            "GET", f"{base_url}/api/fonts_info", data=None, timeout=20.0
        )
    except requests.RequestException as e:
        pytest.fail(f"Failed to connect backend at {base_url}: {e}")

    if status_code != 200 or not isinstance(fonts, list) or len(fonts) == 0:
        pytest.fail(f"/api/fonts_info failed: status={status_code}, body={fonts}")
    font_option = fonts[0]

    sample_text = ("测试并发生成性能 ABC 123。\n" * text_repeat).strip()
    form_base = {
        "text": sample_text,
        "font_size": "120",
        "line_spacing": "180",
        "fill": "(0, 0, 0, 255)",
        "left_margin": "80",
        "top_margin": "80",
        "right_margin": "80",
        "bottom_margin": "80",
        "word_spacing": "1",
        "line_spacing_sigma": "0",
        "font_size_sigma": "2",
        "word_spacing_sigma": "2",
        "perturb_x_sigma": "2",
        "perturb_y_sigma": "2",
        "perturb_theta_sigma": "0.05",
        "preview": "true",
        "strikethrough_probability": "0",
        "strikethrough_length_sigma": "0",
        "strikethrough_width_sigma": "0",
        "strikethrough_angle_sigma": "0",
        "strikethrough_width": "0",
        "ink_depth_sigma": "10",
        "width": "2481",
        "height": "3507",
        "isUnderlined": "false",
        "enableEnglishSpacing": "false",
        "font_option": font_option,
        "pdf_save": "false",
        "full_preview": "false",
    }

    start = time.time()
    results: list[TaskResult] = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(
                _run_one_request,
                i + 1,
                base_url,
                form_base,
                poll_interval,
                task_timeout,
            )
            for i in range(total_requests)
        ]
        results.extend(future.result() for future in as_completed(futures))
    suite_seconds = time.time() - start

    failed = [r for r in results if not r.ok]
    totals = [r.total_seconds for r in results]
    p95 = sorted(totals)[max(0, int(len(totals) * 0.95) - 1)] if totals else 0.0
    avg = statistics.mean(totals) if totals else 0.0

    debug_lines = [
        f"base_url={base_url}",
        f"total_requests={total_requests}, concurrency={concurrency}",
        f"suite_time={suite_seconds:.2f}s, avg={avg:.2f}s, p95={p95:.2f}s",
    ]
    if failed:
        debug_lines.append("failed requests:")
        debug_lines.extend(
            f"- req={result.idx}, task={result.task_id}, status={result.status_code}, "
            f"time={result.total_seconds:.2f}s, msg={result.message}"
            for result in failed
        )

    assert len(failed) == 0, "\n".join(debug_lines)
