"""交互式目录选择。"""
from __future__ import annotations

from .console import bold, cyan, dim, green, hr
from .errors import WebDavError
from .urls import (
    child_url,
    display_url,
    is_under,
    normalize_folder,
    parent_folder,
    same_location,
    video_mime,
)
from .webdav import WebDav

# ---------------------------------------------------------------------------
# 目录选择
# ---------------------------------------------------------------------------


def browse_folder(client: WebDav, title: str, start_url: str, server_base: str) -> str:
    current = normalize_folder(start_url or server_base)
    while True:
        try:
            entries = client.list(current)
        except WebDavError as exc:
            print(f"无法读取 {display_url(current)}：{exc}")
            if same_location(current, server_base):
                raise
            current = server_base
            continue
        dirs = [entry for entry in entries if entry.is_dir]
        videos = [entry for entry in entries if not entry.is_dir and video_mime(entry.name, entry.mime)]
        print()
        hr()
        print(f"  {bold(cyan(title))}")
        hr()
        print(f"  {dim('当前目录')}  {display_url(current)}")
        print(f"  {dim('内容')}      {len(dirs)} 个文件夹 · {len(videos)} 个视频")
        print()
        print(f"  {green('[0]')} 使用当前文件夹")
        for index, entry in enumerate(dirs, 1):
            print(f"  {green(f'[{index}]')} {entry.name}/")
        print()
        print(dim("  序号进入 · mkdir 名称 新建 · .. 上一级 · 粘贴完整 URL 跳转 · r 刷新 · q 退出"))
        try:
            choice = input("请选择：").strip()
        except (EOFError, KeyboardInterrupt):
            raise SystemExit(0)
        if choice in ("", "0"):
            return current
        if choice.lower() == "q":
            raise SystemExit(0)
        if choice.lower() == "r":
            continue
        if choice == "..":
            parent = parent_folder(current, server_base)
            if parent:
                current = parent
            continue
        if choice.lower().startswith(("http://", "https://")):
            target = normalize_folder(choice)
            if is_under(target, server_base):
                current = target
            else:
                print(f"地址必须在服务根目录之内：{display_url(server_base)}")
            continue
        if choice.lower().startswith("mkdir "):
            name = choice[6:].strip()
            if not name:
                print("用法：mkdir 文件夹名称")
                continue
            new_folder = child_url(current, name, True)
            try:
                client.ensure_dir(new_folder)
            except WebDavError as exc:
                print(f"创建失败：{exc}")
                continue
            current = new_folder
            continue
        try:
            index = int(choice)
        except ValueError:
            print("无效输入，请输入序号或命令。")
            continue
        if 1 <= index <= len(dirs):
            current = normalize_folder(dirs[index - 1].url)
        else:
            print("序号超出范围。")
