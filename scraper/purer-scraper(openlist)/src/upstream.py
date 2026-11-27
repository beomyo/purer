"""全局上游请求限制：同一 115/OpenList 账号同时最多 2 路 Range 请求。

115 对同一文件的并发超过 2 路会返回 403；账号层面的下载/链接生成也有频率限制。
雪碧图快速路径虽然是同一文件 2 路并发，但 jobs=2 时会有 4 路，这里再兜一层
全局上限，避免把 OpenList/115 打出 5XX 或 WAF 拦截。
"""
from __future__ import annotations

import threading

# 进程内共享；进入/退出开销很小，直接用信号量
UPSTREAM_LIMIT = threading.BoundedSemaphore(2)
