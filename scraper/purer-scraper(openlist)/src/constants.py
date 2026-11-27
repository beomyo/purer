"""共享常量、默认参数与 App 兼容的失败原因定义。"""
from __future__ import annotations

import re

VERSION = "1.10.0"
USER_AGENT = f"PurerDesktopScraper/{VERSION}"

# ---- 失败标记（与 App 的 CloudMediaCache / CloudThumbnailScraper 一致） ----

# 标记文件名：`<视频名>.failed` 或 `<视频名>.failed-<原因>`，与缩略图放在同一目录
FAILURE_SUFFIX = ".failed"
FAILURE_NAME = re.compile(r"^(.*)\.failed(?:-([A-Za-z]+))?$")
# 与 CloudThumbnailScraper._recordsFailure 一致：只有永久性失败才写标记，
# 网络、超时、限流、认证、服务器错误属于临时失败，下次仍会重试
RECORDED_FAILURES = frozenset({"noframe", "notfound"})
# 永久性失败重试也不会成功；网络波动类失败默认再试一次
NON_RETRYABLE_FAILURES = frozenset({"noframe", "notfound", "auth"})
DEFAULT_RETRIES = 1
# 标记内容第二行使用 Dart 枚举名，方便与手机端日志对照
FAILURE_ENUM_NAMES = {
    "noframe": "noFrame",
    "notfound": "notFound",
    "timeout": "timeout",
    "ratelimited": "rateLimited",
    "auth": "auth",
    "server": "server",
    "upload": "upload",
    "unknown": "unknown",
}
FAILURE_LABELS = {
    "noframe": "无法解码视频（格式不支持或服务器不支持定位）",
    "notfound": "文件不存在（404）",
    "timeout": "服务器响应超时",
    "ratelimited": "服务器限流（429）",
    "auth": "认证失败（401/403），请检查账号密码",
    "server": "服务器错误（5xx）",
    "upload": "上传缩略图失败",
    "unknown": "未知错误",
}

# ---- 与 App 一致的抽帧频率与超时 ----

DEFAULT_PERCENT = 80.0      # 桌面端默认取 80% 位置（App 默认 20%；可用 --percent 改）
DEFAULT_RATE = 2.0          # 次/秒
MIN_RATE = 1.0
MAX_RATE = 20.0             # App 设置范围为 1–20
MAX_JOBS = 4                # App 同时最多 4 个抽帧
DEFAULT_JOBS = 2            # 桌面端默认 2，避免 WebDAV 服务端并发过载；需要时可用 --jobs 调到 4
PROBE_TIMEOUT = 20          # 读取时长的超时（秒）
EXTRACT_TIMEOUT = 45        # 单次抽帧的超时（秒）
MAX_RETRY_TIMEOUT = 300.0   # 重试时超时延长的上限（秒）
# 卡死检测：ffmpeg/ffprobe 连续这么多秒没有任何进展就判定卡住并终止。
# 避免服务器一直发送一点流量、进程却始终解析不出画面，把整次刮削拖住。0 表示不检测。
STALL_TIMEOUT = 75.0
# 远端卡死兜底：只读文件头（含 MP4 索引）和目标位置附近的一段数据。
# 少数大 MP4 交给 ffmpeg 远程打开会退化成顺序读整文件，这时改用这种方式取帧。
WINDOW_HEAD_BYTES = 24 * 1024 * 1024
WINDOW_BYTES = 48 * 1024 * 1024
# 单个视频运行中每隔多少秒写一条进度日志（显示已用时间、是否还有新进展）
HEARTBEAT_INTERVAL = 10.0
# 超大 AVI：从文件头读取时长，并在几个靠前的位置取帧，避免读尾索引/整文件
AVI_SAFE_DURATION = 3600.0
AVI_SAFE_POSITIONS = (120.0, 180.0, 300.0)
# AVI 专属输入参数：不让 OpenDML 索引把整个大文件读一遍
AVI_INPUT_OPTIONS = ["-use_odml", "0", "-probesize", "5000000", "-analyzeduration", "5000000"]
MIN_THUMBNAIL_BYTES = 1500
GOOD_THUMBNAIL_BYTES = 4000
# ---- 雪碧图（缩略图的增量模式） ----
# 文件名在普通缩略图名字后面加 `~列x行`，例如 00.10.00_vid.mp4~5x5.jpg。
# 帧在视频 10%–95% 区间内均匀取（含两端）：第 i 帧位置 =
# 时长 * (0.10 + 0.85 * i / (N-1))，N = 列*行。
# 所以帧间隔 = 0.85 * 时长 / (N-1)，App 只需从文件名读列/行，再结合时长前缀即可还原。
DEFAULT_SPRITE_GRID = "5x5"
SPRITE_START = 0.10
SPRITE_END = 0.95
DEFAULT_SPRITE_WIDTH = 320      # 单格最大边长（雪碧图总大小控制在 1MB 内）
# 雪碧图默认只处理时长超过该值（秒）的视频；普通缩略图不受此限制。
# 雪碧图每个视频要取 N 帧，短片生成的动画效果差且代价高，所以默认跳过短片。
# 设为 0 表示不限制。
DEFAULT_SPRITE_MIN_DURATION = 300.0
MIN_SPRITE_CELL = 64
MAX_SPRITE_CELL = 640
MAX_SPRITE_FRAMES = 25          # 列*行 的上限，避免一次取太多帧
MAX_SPRITE_BYTES = 1024 * 1024  # 雪碧图上限 1MB；超出时自动降质量/降分辨率
SPRITE_QUALITIES = (3, 5, 7, 10, 15, 22)
CONFIG_VERSION = 2          # 旧配置没有版本号，用来迁移过时的默认并发

PROPFIND_BODY = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<D:propfind xmlns:D="DAV:">'
    "<D:prop>"
    "<D:resourcetype/>"
    "<D:getcontenttype/>"
    "<D:getcontentlength/>"
    "<D:getlastmodified/>"
    "</D:prop>"
    "</D:propfind>"
)

# 与 cloud_mime.dart 的 cloudMimeForName 保持一致
# .m3u8（HLS 播放列表）是脚本额外支持的格式，App 端没有对应项
VIDEO_EXT_MIME = {
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
    ".mov": "video/quicktime",
    ".avi": "video/x-msvideo",
    ".wmv": "video/x-ms-wmv",
    ".flv": "video/x-flv",
    ".ts": "video/mp2t",
    ".m2ts": "video/mp2t",
    ".mpg": "video/mpeg",
    ".mpeg": "video/mpeg",
    ".3gp": "video/3gpp",
    ".3g2": "video/3gpp2",
    ".ogv": "video/ogg",
    ".m3u8": "application/vnd.apple.mpegurl",
}

# 与 CloudMediaCache._durationPrefix 完全一致：每段必须是两位数字，
# 这样日期形式的文件名不会被误认成时长
DURATION_PREFIX = re.compile(r"^(\d{2})\.(\d{2})\.(\d{2})_")
# 雪碧图在缩略图名字末尾加 `~列x行`（放在 .jpg 之前），长度只多 5 个字符左右
SPRITE_TAG = re.compile(r"~(\d{1,2})x(\d{1,2})$")
