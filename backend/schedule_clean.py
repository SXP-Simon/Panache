# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Schedule daily cleanup of generated temporary data."""

import logging
import shutil
import threading
import time
from pathlib import Path

import schedule

logger = logging.getLogger(__name__)


def clear_temp_dir() -> None:
    """Remove files and subdirectories from the configured temporary directory."""
    directory = Path("temp")
    if not directory.exists():
        return
    for path in directory.iterdir():
        try:
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
        except OSError:
            logger.exception("Unable to remove temporary path: %s", path)


schedule.every().day.at("00:00").do(clear_temp_dir)


def run_schedule() -> None:
    """Run scheduled cleanup jobs until the daemon thread exits."""
    schedule.every().day.at("00:00").do(clear_temp_dir)
    while True:
        schedule.run_pending()
        time.sleep(1000)


def start_schedule_thread() -> None:
    """Start the cleanup scheduler without keeping the application alive."""
    threading.Thread(target=run_schedule, daemon=True).start()
