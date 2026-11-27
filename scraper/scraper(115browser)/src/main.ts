import { initUi } from './ui'

/** 启动 */
function boot(): void {
  // 只在顶层窗口注入，避免 115 的 iframe 里出现多个面板
  if (window.top !== window) {
    return
  }
  initUi()
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot, { once: true })
}
else {
  boot()
}
