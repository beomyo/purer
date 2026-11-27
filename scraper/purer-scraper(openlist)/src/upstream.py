"""全局上游请求限制：同一 115/OpenList 账号同一时间只发 1 路 Range 请求。

115 对同一文件的并发超过 2 路会返回 403；账号层面的下载/链接生成也有频率限制。
快速路径刚上线时同一文件 2 路、jobs=2 时会到 4 路，实测可能触发 115 的风控。
这里把全局上限压到 1：任何时刻只向上游发一个 Range 请求，宁可慢一点，也不要
再出现 WAF 拦截。需要更快时再改这个常量。
"""
from __future__ import annotations

import threading

# 进程内共享；进入/退出开销很小，直接用信号量
UPSTREAM_LIMIT = threading.BoundedSemaphore(1)
