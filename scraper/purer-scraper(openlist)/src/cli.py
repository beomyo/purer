"""命令行入口：解析参数、选择目录并启动刮削。"""
from __future__ import annotations

import argparse
import base64
import sys
import time
from pathlib import Path

from . import runtime
from .browse import browse_folder
from .cache import shorten
from .console import (
    bold,
    cyan,
    dim,
    green,
    hr,
    log,
    log_failure,
    log_line,
    log_short,
    log_success,
    red,
    setup_console,
    yellow,
)
from .constants import (
    CONFIG_VERSION,
    DEFAULT_JOBS,
    DEFAULT_PERCENT,
    DEFAULT_RATE,
    DEFAULT_RETRIES,
    DEFAULT_SPRITE_GRID,
    DEFAULT_SPRITE_MIN_DURATION,
    DEFAULT_SPRITE_WIDTH,
    DEFAULT_UNSUPPORTED_CODECS,
    EXTRACT_TIMEOUT,
    MAX_JOBS,
    MAX_RATE,
    MAX_SPRITE_CELL,
    MIN_RATE,
    MIN_SPRITE_CELL,
    PROBE_TIMEOUT,
    SPRITE_INDEX_ENABLED,
    SPRITE_TS_WINDOW_ENABLED,
    STALL_TIMEOUT,
    VERSION,
    WINDOW_BYTES,
)
from .failures import (
    FailureStore,
    RetryContext,
    collect_all_failures,
    interactive_retry,
)
from .ffmpeg import find_tool
from .paths import DEFAULT_CONFIG, DEFAULT_FAILED, DEFAULT_LOG
from .rate import RateLimiter
from .scrape import scrape
from .settings import (
    config_number,
    config_text,
    format_duration,
    load_config,
    password_for,
    print_run_summary,
    prompt,
    remember_credentials,
    save_config,
    validate_selection,
)
from .urls import (
    display_url,
    is_under,
    normalize_folder,
    parse_sprite_grid,
    same_location,
)
from .webdav import WebDav, WebDavError

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Purer 桌面端缩略图刮削器：通过 WebDAV 把缩略图写入共用缓存文件夹。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--server", help="源 WebDAV 服务地址（与 App 中的服务地址一致），如 https://host/dav/")
    parser.add_argument("--user", help="源 WebDAV 用户名")
    parser.add_argument("--password", help="源 WebDAV 密码；不填则使用已保存的密码，没有保存时才询问（明文保存到配置）")
    parser.add_argument("--cache-server", help="缓存所在的 WebDAV 地址；默认与源服务相同")
    parser.add_argument("--cache-user", help="缓存 WebDAV 用户名；默认与源服务相同")
    parser.add_argument("--cache-password", help="缓存 WebDAV 密码；默认与源服务相同；不填则使用已保存的密码")
    parser.add_argument("--cache-folder", help="缓存根文件夹的完整 URL")
    parser.add_argument("--source-folder", help="要刮削的文件夹完整 URL")
    parser.add_argument(
        "--percent", type=float, default=None,
        help=f"取帧位置（视频时长的百分比，默认 {DEFAULT_PERCENT:g}）",
    )
    parser.add_argument(
        "--rate", type=float, default=None,
        help=f"每个文件夹每秒最多抽帧次数（{MIN_RATE:g}–{MAX_RATE:g}，默认 {DEFAULT_RATE:g}）",
    )
    parser.add_argument("--width", type=int, default=None, help="缩略图最大边长，默认 320 像素")
    parser.add_argument(
        "--sprite", action="store_true",
        help="生成雪碧图（同时写一张普通缩略图，取雪碧图最后一帧；默认只生成缩略图）；交互运行时也会询问",
    )
    parser.add_argument(
        "--sprite-grid", default=None,
        help=f"雪碧图格子，格式 列x行，默认 {DEFAULT_SPRITE_GRID}",
    )
    parser.add_argument(
        "--sprite-width", type=int, default=None,
        help=f"雪碧图单格最大边长，默认 {DEFAULT_SPRITE_WIDTH} 像素",
    )
    parser.add_argument(
        "--sprite-min-duration", type=float, default=None,
        help=(
            "雪碧图只处理时长超过该秒数的视频，默认 "
            f"{DEFAULT_SPRITE_MIN_DURATION:g}（缩略图模式不限制）；0 表示不限制"
        ),
    )
    parser.add_argument(
        "--no-sprite-window", action="store_true",
        help=(
            "关闭雪碧图的 TS/M2TS/AVI 数据窗口快速路径：默认只读每帧附近的窗口后本地抽帧；"
            "关闭后恢复逐帧远程顺序读取（非常慢）"
        ),
    )
    parser.add_argument(
        "--no-sprite-index", action="store_true",
        help=(
            "关闭雪碧图的 MP4 索引快速路径：默认只读一次索引，按样本表取每帧所需字节后"
            "本地抽帧；关闭后恢复逐帧远程读取"
        ),
    )
    parser.add_argument(
        "--jobs", type=int, default=None,
        help=f"同时处理的视频数（1–{MAX_JOBS}，默认 {DEFAULT_JOBS}；App 上限为 {MAX_JOBS}）",
    )
    parser.add_argument(
        "--retries", type=int, default=DEFAULT_RETRIES,
        help=f"网络类失败的重试次数，默认 {DEFAULT_RETRIES}；0 表示不重试（永久性失败始终不重试）",
    )
    parser.add_argument("--fallback-seconds", type=float, default=3.0, help="读不到时长/抽帧超时时改用的取帧秒数，默认 3")
    parser.add_argument(
        "--no-fallback-retry", action="store_true",
        help="关闭失败兜底（读不到时长时取 fallback-seconds 帧、抽帧超时后改用接近开头的位置重试）",
    )
    parser.add_argument(
        "--no-window-fallback", action="store_true",
        help=(
            "关闭卡死兜底：默认当远端读取卡住时，只读索引和取帧位置附近约 "
            f"{WINDOW_BYTES // 1048576}MB 拼成本地文件抽帧"
        ),
    )
    parser.add_argument(
        "--probe-timeout", type=float, default=None,
        help=f"读取视频时长的超时秒数；未指定时使用配置或默认 {PROBE_TIMEOUT:g}",
    )
    parser.add_argument(
        "--extract-timeout", type=float, default=None,
        help=f"单次抽帧的超时秒数；未指定时使用配置或默认 {EXTRACT_TIMEOUT:g}",
    )
    parser.add_argument(
        "--stall-timeout", type=float, default=None,
        help=(
            "连续多少秒没有任何进展就判定该视频卡死并中止；"
            f"未指定时使用配置或默认 {STALL_TIMEOUT:g}，0 表示关闭卡死检测"
        ),
    )
    parser.add_argument("--limit", type=int, default=None, help="本次最多处理多少个视频（重试模式下限制重试数；用于试跑）")
    parser.add_argument("--insecure", action="store_true", help="忽略 HTTPS 证书错误（自签名证书时使用）")
    parser.add_argument("--proxy", help="WebDAV 与 ffmpeg 使用的代理地址，如 http://127.0.0.1:7890；默认不使用系统代理")
    parser.add_argument("--dry-run", action="store_true", help="只列出待处理视频、待删除的无效缩略图或失败标记，不抽帧、不上传、不删除")
    parser.add_argument("--retry-failed", action="store_true", help="只处理失败标记中的视频（交互选择，非交互时全部重试；可与 --dry-run 组合查看）")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="配置文件路径")
    parser.add_argument("--log-file", default=str(DEFAULT_LOG), help="日志文件路径")
    parser.add_argument("--no-log", action="store_true", help="不写日志文件")
    parser.add_argument("--ffmpeg", help="ffmpeg 可执行文件路径")
    parser.add_argument("--ffprobe", help="ffprobe 可执行文件路径")
    parser.add_argument("--version", action="version", version=f"Purer 桌面刮削器 {VERSION}")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    setup_console()
    args = parse_args(argv)
    if args.no_log:
        runtime.log_path = None
        runtime.success_log_path = None
        runtime.failure_log_path = None
        runtime.short_log_path = None
    else:
        runtime.log_path = Path(args.log_file)
        suffix = runtime.log_path.suffix or ".log"
        stem = runtime.log_path.name[: -len(suffix)] if runtime.log_path.suffix else runtime.log_path.name
        runtime.success_log_path = runtime.log_path.with_name(f"{stem}_success{suffix}")
        runtime.failure_log_path = runtime.log_path.with_name(f"{stem}_failure{suffix}")
        runtime.short_log_path = runtime.log_path.with_name(f"{stem}_short{suffix}")
    runtime.ffmpeg_proxy = args.proxy
    runtime.cancel_event.clear()
    runtime.run_summary = None
    runtime.board = None
    runtime.failure_store = FailureStore(DEFAULT_FAILED)
    if runtime.log_path is not None:
        started = f"===== 运行开始 {time.strftime('%Y-%m-%d %H:%M:%S')} · v{VERSION} ====="
        log_line(started)
        log_success(started)
        log_failure(started)
        log_short(started)

    config_path = Path(args.config)
    config = load_config(config_path)

    percent = args.percent if args.percent is not None else config_number(config, "percent", DEFAULT_PERCENT, float)
    rate = args.rate if args.rate is not None else config_number(config, "rate", DEFAULT_RATE, float)
    width = args.width if args.width is not None else config_number(config, "width", 320, int)
    sprite_width = (
        args.sprite_width
        if args.sprite_width is not None
        else config_number(config, "sprite_width", DEFAULT_SPRITE_WIDTH, int)
    )
    sprite_min_duration = (
        args.sprite_min_duration
        if args.sprite_min_duration is not None
        else config_number(
            config, "sprite_min_duration", DEFAULT_SPRITE_MIN_DURATION, float
        )
    )
    try:
        sprite_grid = parse_sprite_grid(
            args.sprite_grid or config_text(config, "sprite_grid") or DEFAULT_SPRITE_GRID
        )
    except ValueError as exc:
        print(exc)
        runtime.run_summary = "参数无效：sprite-grid"
        return 2
    mode = "sprite" if args.sprite else (config_text(config, "mode") or "thumb")
    if mode not in ("thumb", "sprite"):
        mode = "thumb"
    probe_timeout = (
        args.probe_timeout
        if args.probe_timeout is not None
        else config_number(config, "probe_timeout", float(PROBE_TIMEOUT), float)
    )
    extract_timeout = (
        args.extract_timeout
        if args.extract_timeout is not None
        else config_number(config, "extract_timeout", float(EXTRACT_TIMEOUT), float)
    )
    stall_timeout = (
        args.stall_timeout
        if args.stall_timeout is not None
        else config_number(config, "stall_timeout", float(STALL_TIMEOUT), float)
    )
    # 旧配置没有 config_version 时使用当前默认并发（2）；
    # 用户显式设置的 --jobs 会写入新配置并沿用。
    config_is_current = config.get("config_version") == CONFIG_VERSION
    if args.jobs is not None:
        jobs = args.jobs
    elif config_is_current and isinstance(config.get("jobs"), (int, float)):
        jobs = int(config["jobs"])
    else:
        if config_is_current and config.get("jobs") is not None:
            print(f"配置项 jobs 无效（{config.get('jobs')!r}），使用默认值 {DEFAULT_JOBS}。")
        jobs = DEFAULT_JOBS
    percent = min(99.0, max(1.0, percent))
    if width < 1:
        print("--width 必须大于 0。")
        runtime.run_summary = "参数无效：width"
        return 2
    if sprite_width < MIN_SPRITE_CELL or sprite_width > MAX_SPRITE_CELL:
        print(f"--sprite-width 必须在 {MIN_SPRITE_CELL}–{MAX_SPRITE_CELL} 之间。")
        runtime.run_summary = "参数无效：sprite-width"
        return 2
    if sprite_min_duration < 0:
        print("--sprite-min-duration 不能为负数（0 表示不限制）。")
        runtime.run_summary = "参数无效：sprite-min-duration"
        return 2
    if args.limit is not None and args.limit < 1:
        print("--limit 必须是正整数。")
        runtime.run_summary = "参数无效：limit"
        return 2
    if probe_timeout <= 0 or extract_timeout <= 0:
        print("--probe-timeout 和 --extract-timeout 必须大于 0。")
        runtime.run_summary = "参数无效：timeout"
        return 2
    if stall_timeout < 0:
        print("--stall-timeout 不能为负数（0 表示关闭卡死检测）。")
        runtime.run_summary = "参数无效：stall-timeout"
        return 2
    if args.fallback_seconds < 0:
        print("--fallback-seconds 不能为负数。")
        runtime.run_summary = "参数无效：fallback-seconds"
        return 2

    print()
    print(f"  {bold(cyan('Purer 桌面端缩略图刮削器'))}  {dim('v' + VERSION)}")
    print(dim("  缩略图写入与手机端相同的共用缓存目录；失败项记录到 failed_videos.json，永久性失败再写 <视频名>.failed-<原因> 标记。"))
    print()

    if rate < MIN_RATE or rate > MAX_RATE:
        print(f"限速按 App 的范围限制为 {MIN_RATE:g}–{MAX_RATE:g} 次/秒。")
    rate = min(MAX_RATE, max(MIN_RATE, rate))
    if jobs > MAX_JOBS:
        print(f"并发按 App 的上限限制为 {MAX_JOBS}。")
    jobs = min(MAX_JOBS, max(1, jobs))

    server = args.server or config_text(config, "server") or prompt("源 WebDAV 地址（必须与 App 中的服务地址一致，如 https://host/dav/）")
    if not server:
        print("必须填写 WebDAV 地址。")
        runtime.run_summary = "缺少 WebDAV 地址"
        return 2
    user = args.user if args.user is not None else (config_text(config, "user") or prompt("源 WebDAV 用户名（无则回车）", ""))
    saved_password = config_text(config, "password")
    if args.password is not None:
        password = args.password
    elif saved_password is not None:
        password = saved_password
    else:
        password = password_for("源 WebDAV ", None)

    cache_server = args.cache_server or config_text(config, "cache_server") or server
    same_server = same_location(cache_server, server)
    if same_server:
        cache_user = user
        cache_password = password
    else:
        cache_user = args.cache_user if args.cache_user is not None else (config_text(config, "cache_user") or prompt("缓存 WebDAV 用户名（无则回车）", ""))
        saved_cache_password = config_text(config, "cache_password")
        if args.cache_password is not None:
            cache_password = args.cache_password
        elif saved_cache_password is not None:
            cache_password = saved_cache_password
        else:
            cache_password = password_for("缓存 WebDAV ", None)

    # 首次输入后立即保存；即使本次连接失败，下次也不用重新输入
    remember_credentials(config_path, config, server, user, cache_server, cache_user, password, cache_password)

    try:
        source_client = WebDav(server, user, password, insecure=args.insecure, proxy=args.proxy)
        cache_client = (
            source_client
            if same_server
            else WebDav(cache_server, cache_user, cache_password, insecure=args.insecure, proxy=args.proxy)
        )
        log("正在测试源 WebDAV 连接…")
        source_client.test_connection()
        log(f"{green('✓')} 源 WebDAV 连接成功")
        if not same_server:
            log("正在测试缓存 WebDAV 连接…")
            cache_client.test_connection()
            log(f"{green('✓')} 缓存 WebDAV 连接成功")
    except (WebDavError, ValueError) as exc:
        print(f"连接失败：{exc}")
        print("如果保存的密码不正确，可用 --password 新密码 重新运行一次。")
        runtime.run_summary = "连接失败"
        return 2

    source_base = source_client.base_url
    cache_base = cache_client.base_url

    try:
        ffmpeg = find_tool("ffmpeg", args.ffmpeg)
        ffprobe = find_tool("ffprobe", args.ffprobe)
    except FileNotFoundError as exc:
        print(exc)
        runtime.run_summary = "找不到 ffmpeg/ffprobe"
        return 2

    source_token_bytes = base64.b64encode(f"{user}:{password}".encode("utf-8")) if (user or password) else None
    source_token = source_token_bytes.decode("ascii") if source_token_bytes else None
    retries = max(0, args.retries)
    window_fallback = not args.no_window_fallback
    stored_index = config.get("sprite_index", SPRITE_INDEX_ENABLED)
    sprite_index = (not args.no_sprite_index) and (
        stored_index if isinstance(stored_index, bool) else SPRITE_INDEX_ENABLED
    )
    stored_window = config.get("sprite_window", SPRITE_TS_WINDOW_ENABLED)
    sprite_window = (not args.no_sprite_window) and (
        stored_window if isinstance(stored_window, bool) else SPRITE_TS_WINDOW_ENABLED
    )
    raw_codecs = config.get("unsupported_codecs", list(DEFAULT_UNSUPPORTED_CODECS))
    if isinstance(raw_codecs, str):
        codec_items = [raw_codecs]
    elif isinstance(raw_codecs, (list, tuple)):
        codec_items = raw_codecs
    else:
        codec_items = list(DEFAULT_UNSUPPORTED_CODECS)
    unsupported_codecs = frozenset(
        str(item).strip().upper() for item in codec_items if str(item).strip()
    )

    cache_folder = args.cache_folder or config_text(config, "cache_folder")

    if args.retry_failed:
        if not cache_folder:
            cache_folder = browse_folder(cache_client, "选择缓存根文件夹", cache_base, cache_base)
        cache_folder = normalize_folder(cache_folder)
        if not is_under(cache_folder, cache_base):
            print(f"缓存文件夹必须位于缓存 WebDAV 服务 {display_url(cache_base)} 之内。")
            runtime.run_summary = "缓存文件夹无效"
            return 2
        print(f"缓存根：{display_url(cache_folder)}")
        config["cache_folder"] = cache_folder
        config["probe_timeout"] = probe_timeout
        config["extract_timeout"] = extract_timeout
        config["stall_timeout"] = stall_timeout
        config["mode"] = mode
        config["sprite_grid"] = f"{sprite_grid[0]}x{sprite_grid[1]}"
        config["sprite_width"] = sprite_width
        config["sprite_min_duration"] = sprite_min_duration
        config["sprite_index"] = sprite_index
        config["sprite_window"] = sprite_window
        config["unsupported_codecs"] = sorted(unsupported_codecs)
        save_config(config_path, config)
        markers = collect_all_failures(cache_client, cache_folder, source_base)
        if not markers:
            print("没有失败记录。")
            runtime.run_summary = "没有失败记录"
            return 0
        print(f"发现 {bold(str(len(markers)))} 个失败记录。")
        if mode == "sprite" or args.sprite:
            print("提示：失败标记只由缩略图模式写入；--retry-failed 将按缩略图重试。雪碧图请直接再运行一次雪碧图模式。")
        ctx = RetryContext(
            cache_client=cache_client,
            cache_root=cache_folder,
            ffmpeg=ffmpeg,
            ffprobe=ffprobe,
            source_token=source_token,
            insecure=args.insecure,
            percent=percent,
            width=width,
            fallback_seconds=args.fallback_seconds,
            retries=retries,
            limiter=RateLimiter(rate),
            probe_timeout=probe_timeout,
            extract_timeout=extract_timeout,
            fallback_retry=not args.no_fallback_retry,
            source_client=source_client,
            stall_timeout=stall_timeout,
            window_fallback=window_fallback,
            mode="thumb",
            sprite_grid=sprite_grid,
            sprite_width=sprite_width,
            sprite_min_duration=sprite_min_duration,
            sprite_index=sprite_index,
            sprite_window=sprite_window,
            unsupported_codecs=unsupported_codecs,
        )
        if args.dry_run:
            interactive_retry(ctx, markers, limit=args.limit, list_only=True)
            runtime.run_summary = f"列出 {len(markers)} 个失败记录（dry-run）"
            return 0
        interactive_retry(ctx, markers, limit=args.limit)
        runtime.run_summary = f"失败记录 {len(markers)} 个 · 重试结束"
        return 0

    if not cache_folder:
        cache_folder = browse_folder(cache_client, "选择缓存根文件夹", cache_base, cache_base)
    cache_folder = normalize_folder(cache_folder)

    source_folder = args.source_folder or config_text(config, "source_folder")
    if not source_folder:
        source_folder = browse_folder(source_client, "选择要刮削的文件夹", source_base, source_base)
    source_folder = normalize_folder(source_folder)

    error_message = validate_selection(cache_folder, cache_base, source_folder, source_base)
    if error_message:
        print(error_message)
        runtime.run_summary = "文件夹选择无效"
        return 2

    interactive = sys.stdin.isatty() and not args.dry_run
    if interactive and not args.sprite:
        default_choice = "2" if mode == "sprite" else "1"
        try:
            answer = input(f"生成内容 [1] 缩略图 [2] 雪碧图 [{default_choice}]：").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            runtime.run_summary = "已中止"
            return 130
        if answer == "1":
            mode = "thumb"
        elif answer == "2":
            mode = "sprite"
        if mode == "sprite":
            print(
                f"  {dim('雪碧图')} {sprite_grid[0]}x{sprite_grid[1]}"
                f"（{sprite_grid[0] * sprite_grid[1]} 帧）· 单格上限 {sprite_width}px"
            )
    if interactive:
        print_run_summary(
            server, cache_server, cache_folder, source_folder,
            percent, rate, width, jobs, mode, sprite_grid, sprite_width,
            sprite_min_duration,
        )
        try:
            choice = input("按 Enter 开始刮削，输入 m 重新选择文件夹：").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            runtime.run_summary = "已中止"
            return 130
        if choice == "m":
            cache_folder = normalize_folder(
                browse_folder(cache_client, "选择缓存根文件夹", cache_folder, cache_base)
            )
            source_folder = normalize_folder(
                browse_folder(source_client, "选择要刮削的文件夹", source_folder, source_base)
            )
            error_message = validate_selection(cache_folder, cache_base, source_folder, source_base)
            if error_message:
                print(error_message)
                runtime.run_summary = "文件夹选择无效"
                return 2
            print_run_summary(
                server, cache_server, cache_folder, source_folder,
                percent, rate, width, jobs, mode, sprite_grid, sprite_width,
                sprite_min_duration,
            )
    else:
        print_run_summary(
            server, cache_server, cache_folder, source_folder,
            percent, rate, width, jobs, mode, sprite_grid, sprite_width,
            sprite_min_duration,
        )

    # 缓存根目录可能还没创建：逐级建好（WebDAV 的 MKCOL 不会自动建父目录）
    if not args.dry_run:
        try:
            cache_client.ensure_tree(cache_folder, cache_base)
        except WebDavError as exc:
            print(f"无法创建缓存根目录 {display_url(cache_folder)}：{exc}")
            runtime.run_summary = "无法创建缓存根目录"
            return 2

    save_config(
        config_path,
        {
            "config_version": CONFIG_VERSION,
            "server": server,
            "user": user,
            "cache_server": cache_server,
            "cache_user": cache_user,
            "cache_folder": cache_folder,
            "source_folder": source_folder,
            "percent": percent,
            "rate": rate,
            "width": width,
            "jobs": jobs,
            "mode": mode,
            "sprite_grid": f"{sprite_grid[0]}x{sprite_grid[1]}",
            "sprite_width": sprite_width,
            "sprite_min_duration": sprite_min_duration,
            "sprite_index": sprite_index,
            "sprite_window": sprite_window,
            "unsupported_codecs": sorted(unsupported_codecs),
            "probe_timeout": probe_timeout,
            "extract_timeout": extract_timeout,
            "stall_timeout": stall_timeout,
            "password": password,
            "cache_password": cache_password,
        },
    )

    try:
        stats = scrape(
            source_client=source_client,
            cache_client=cache_client,
            source_folder=source_folder,
            source_base=source_base,
            cache_root=cache_folder,
            ffmpeg=ffmpeg,
            ffprobe=ffprobe,
            source_token=source_token,
            insecure=args.insecure,
            percent=percent,
            rate=rate,
            width=width,
            jobs=jobs,
            retries=retries,
            fallback_seconds=args.fallback_seconds,
            limit=args.limit,
            dry_run=args.dry_run,
            probe_timeout=probe_timeout,
            extract_timeout=extract_timeout,
            fallback_retry=not args.no_fallback_retry,
            stall_timeout=stall_timeout,
            window_fallback=window_fallback,
            mode=mode,
            sprite_grid=sprite_grid,
            sprite_width=sprite_width,
            sprite_min_duration=sprite_min_duration,
            sprite_index=sprite_index,
            sprite_window=sprite_window,
            unsupported_codecs=unsupported_codecs,
        )
    except KeyboardInterrupt:
        runtime.cancel_running()
        if runtime.board is not None:
            runtime.board.done()
            runtime.board = None
        print()
        print("已中止。已经写入的缩略图会保留，下次运行会自动跳过。")
        runtime.run_summary = "已中止"
        return 130
    finally:
        if runtime.board is not None:
            runtime.board.done()
            runtime.board = None

    elapsed = format_duration(time.monotonic() - stats.started_at)
    print()
    hr("═")
    print(f"  {bold(green('完成'))} · 用时 {elapsed}")
    short_note = (
        f"   {dim('时长不足跳过')} {stats.skipped_short}"
        if stats.skipped_short
        else ""
    )
    unsupported_note = (
        f"   {dim('编码不支持跳过')} {stats.skipped_unsupported}"
        if stats.skipped_unsupported
        else ""
    )
    average = stats.average_seconds()
    average_note = f"   平均 {average:.1f}s/个（已处理 {stats.timed} 个）" if stats.timed else ""
    print(
        f"  {green('新增')} {stats.generated}   {dim('已存在')} {stats.skipped}   "
        f"{dim('失败跳过')} {stats.skipped_failed}   {yellow('本次失败')} {stats.failed}   "
        f"{dim('删除无效文件')} {stats.removed}   {dim('文件夹')} {stats.folders}"
        f"{short_note}{unsupported_note}{average_note}"
    )
    print(f"  {dim('缓存根')}  {display_url(cache_folder)}")
    hr("═")
    runtime.run_summary = (
        f"用时 {elapsed} · 新增 {stats.generated} · 已存在 {stats.skipped} · "
        f"失败跳过 {stats.skipped_failed} · 本次失败 {stats.failed} · "
        f"删除无效文件 {stats.removed} · 文件夹 {stats.folders}"
        + (f" · 时长不足跳过 {stats.skipped_short}" if stats.skipped_short else "")
        + (
            f" · 编码不支持跳过 {stats.skipped_unsupported}"
            if stats.skipped_unsupported
            else ""
        )
        + (
            f" · 平均 {stats.average_seconds():.1f}s/个（已处理 {stats.timed} 个）"
            if stats.timed
            else ""
        )
        + ("（dry-run）" if args.dry_run else "")
    )
    if args.dry_run:
        print("（dry-run：未抽帧、未上传、未删除）")
    if stats.failures:
        print()
        print(bold(red("本次失败项：")))
        for url, reason in stats.failures:
            print(f"  {red('·')} {display_url(url)}")
            print(f"    {dim(shorten(reason, 200))}")
    if stats.recorded:
        print()
        print(f"已写入 {yellow(str(stats.recorded))} 个失败标记（<视频名>.failed-<原因>），后续运行会自动跳过。")
    if stats.recorded_local:
        print()
        print(f"失败记录已写入 {yellow(str(DEFAULT_FAILED))}，后续运行会自动跳过。")
        print("单独重试：运行 python purer_scraper.py --retry-failed")
    if stats.recorded or stats.recorded_local:
        if not args.dry_run and sys.stdin.isatty():
            try:
                answer = input("是否现在查看并单独重试失败视频？[y/N] ").strip()
            except (EOFError, KeyboardInterrupt):
                answer = ""
            if answer.lower().startswith("y"):
                ctx = RetryContext(
                    cache_client=cache_client,
                    cache_root=cache_folder,
                    ffmpeg=ffmpeg,
                    ffprobe=ffprobe,
                    source_token=source_token,
                    insecure=args.insecure,
                    percent=percent,
                    width=width,
                    fallback_seconds=args.fallback_seconds,
                    retries=retries,
                    limiter=RateLimiter(rate),
                    probe_timeout=probe_timeout,
                    extract_timeout=extract_timeout,
                    fallback_retry=not args.no_fallback_retry,
                    source_client=source_client,
                    stall_timeout=stall_timeout,
                    window_fallback=window_fallback,
                    mode=mode,
                    sprite_grid=sprite_grid,
                    sprite_width=sprite_width,
                    sprite_min_duration=sprite_min_duration,
                    sprite_index=sprite_index,
                    sprite_window=sprite_window,
                    unsupported_codecs=unsupported_codecs,
                )
                interactive_retry(ctx, collect_all_failures(cache_client, cache_folder, source_base))
    if runtime.log_path:
        print(f"日志：{runtime.log_path}")
        print(f"      成功：{runtime.success_log_path}")
        print(f"      失败：{runtime.failure_log_path}")
        print(f"      短片：{runtime.short_log_path}")
    else:
        print("日志：未写入文件")
    return 0 if stats.failed == 0 else 1


def entry(argv: list[str] | None = None) -> int:
    code = 0
    try:
        code = main(argv)
    except KeyboardInterrupt:
        print("\n已中止。")
        runtime.cancel_running()
        code = 130
    except SystemExit as exc:
        value = exc.code
        if value is None:
            code = 0
        elif isinstance(value, int):
            code = value
        else:
            print(value)
            code = 1
    except BaseException:
        code = 1
        raise
    finally:
        log_line(f"===== 运行结束 · 退出码 {code} · {runtime.run_summary or '未完成'} =====")
    return code
