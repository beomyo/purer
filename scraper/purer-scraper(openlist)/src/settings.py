"""配置文件、交互提示与运行摘要。"""
from __future__ import annotations

import getpass
import json
from pathlib import Path

from .console import bold, cyan, dim, hr
from .constants import DEFAULT_SPRITE_WIDTH
from .urls import display_url, is_under, same_location

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------


def load_config(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError) as exc:
        print(f"读取配置文件失败（将忽略）：{exc}")
        return {}


def save_config(path: Path, data: dict) -> None:
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
    except OSError as exc:
        print(f"保存配置失败（不影响本次刮削）：{exc}")


def config_number(config: dict, key: str, default, cast):
    value = config.get(key, default)
    try:
        return cast(value)
    except (TypeError, ValueError):
        print(f"配置项 {key} 无效（{value!r}），使用默认值 {default}。")
        return default


def config_text(config: dict, key: str) -> str | None:
    value = config.get(key)
    if value is None:
        return None
    if isinstance(value, str):
        return value
    print(f"配置项 {key} 无效（不是字符串），将忽略。")
    return None


def remember_credentials(
    path: Path,
    config: dict,
    server: str,
    user: str,
    cache_server: str,
    cache_user: str,
    password: str,
    cache_password: str,
) -> None:
    """把服务地址和密码合并进现有配置（明文，按用户要求不考虑安全性）。"""
    config.update(
        {
            "server": server,
            "user": user,
            "cache_server": cache_server,
            "cache_user": cache_user,
            "password": password,
            "cache_password": cache_password,
        }
    )
    save_config(path, config)


def prompt(text: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    try:
        value = input(f"{text}{suffix}：").strip()
    except (EOFError, KeyboardInterrupt):
        raise SystemExit(0)
    return value or (default or "")


def password_for(label: str, explicit: str | None) -> str:
    if explicit is not None:
        return explicit
    try:
        return getpass.getpass(f"{label}密码（输入不回显；首次输入后保存到 scraper_config.json；无密码直接回车）：")
    except (EOFError, KeyboardInterrupt):
        raise SystemExit(0)


def format_duration(seconds: float) -> str:
    seconds = int(seconds)
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours} 小时 {minutes} 分 {secs} 秒"
    if minutes:
        return f"{minutes} 分 {secs} 秒"
    return f"{secs} 秒"


def print_run_summary(
    server: str,
    cache_server: str,
    cache_folder: str,
    source_folder: str,
    percent: float,
    rate: float,
    width: int,
    jobs: int,
    mode: str = "thumb",
    sprite_grid: tuple[int, int] = (3, 3),
    sprite_width: int = DEFAULT_SPRITE_WIDTH,
    sprite_min_duration: float = 0.0,
    sprite_min_seconds: float = 0.0,
) -> None:
    print()
    hr("═")
    print(f"  {bold(cyan('本次刮削'))}")
    hr("═")
    print(f"  {dim('源服务')}    {display_url(server)}")
    if not same_location(cache_server, server):
        print(f"  {dim('缓存服务')}  {display_url(cache_server)}")
    print(f"  {dim('缓存根')}    {display_url(cache_folder)}")
    print(f"  {dim('刮削目录')}  {display_url(source_folder)}")
    if mode == "sprite":
        duration_note = (
            f" · 仅时长 > {sprite_min_duration:g}s" if sprite_min_duration > 0 else ""
        )
        pace_note = (
            f" · 每视频至少 {sprite_min_seconds:g}s" if sprite_min_seconds > 0 else ""
        )
        params = (
            f"雪碧图 {sprite_grid[0]}x{sprite_grid[1]}"
            f"（{sprite_grid[0] * sprite_grid[1]} 帧）{duration_note} · "
            f"单格上限 {sprite_width}px · 限速 {rate:g} 次/秒 · 并发 {jobs}{pace_note}"
        )
    else:
        params = f"取帧 {percent:g}% · 限速 {rate:g} 次/秒 · 缩略图 {width}px · 并发 {jobs}"
    print(f"  {dim('参数')}      {params}")
    hr("═")
    print()


def validate_selection(
    cache_folder: str,
    cache_base: str,
    source_folder: str,
    source_base: str,
) -> str | None:
    if not is_under(cache_folder, cache_base):
        return f"缓存文件夹必须位于缓存 WebDAV 服务 {display_url(cache_base)} 之内。"
    if not is_under(source_folder, source_base):
        return f"要刮削的文件夹必须位于源 WebDAV 服务 {display_url(source_base)} 之内。"
    if same_location(source_folder, cache_folder):
        return "源文件夹和缓存根目录不能是同一个文件夹。"
    if is_under(source_folder, cache_folder) and not same_location(cache_folder, source_base):
        return "要刮削的文件夹位于缓存根目录内部，没有可刮削的内容。"
    return None
