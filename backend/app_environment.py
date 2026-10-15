# Copyright (c) 2026 HandwritingWeb contributors
"""在导入应用组件前读取环境文件，并提供统一环境变量入口."""

import os

from dotenv import load_dotenv

load_dotenv()
get_environment_value = os.getenv
