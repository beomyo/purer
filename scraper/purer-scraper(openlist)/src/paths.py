"""项目路径：配置、日志与失败记录都放在启动脚本所在的根目录。

实现代码在 ``src/`` 中，数据文件仍与启动脚本 ``purer_scraper.py`` 同级，
这样从任意工作目录启动都能找到上次保存的配置和日志。
"""
from __future__ import annotations

from pathlib import Path

# src/paths.py -> src/ -> 项目根目录（启动脚本所在目录）
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = PROJECT_ROOT / "scraper_config.json"
DEFAULT_LOG = PROJECT_ROOT / "scraper.log"
DEFAULT_FAILED = PROJECT_ROOT / "failed_videos.json"
