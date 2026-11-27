#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Purer 桌面端缩略图刮削器 —— 启动脚本。

具体实现位于 ``src/`` 包；配置文件、日志与失败记录仍保存在本文件所在目录。
用法与原版一致，例如 ``python purer_scraper.py``、``--retry-failed``、``--help``。
"""
from __future__ import annotations

from src.cli import entry

if __name__ == "__main__":
    raise SystemExit(entry())
