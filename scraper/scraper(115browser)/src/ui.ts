import type { DavEntry } from './webdav'
import type { FailureRecord, Mode, Row } from './types'
import type { CancelToken, RunEvent } from './runner'
import type { ScraperSettings } from './settings'
import type { CidResolution } from './api115'
import type { SourceTarget } from './sourceFolder'
import { GM_addStyle, GM_getValue, GM_registerMenuCommand, GM_setValue } from '$'
import { AccountVerifyError, listVideos, probeRootApi, resolveCidByPathDetailed } from './api115'
import { walkFolders } from './collector'
import {
  addFailure,
  clearFailures as clearFailuresStore,
  loadFailures,
  removeFailure,
} from './failures'
import {
  buildRows,
  buildTargetFolder,
  effectiveModeFor,
  listExisting,
  messageOf,
  reasonLabel,
  runRows,
} from './runner'
import { DEFAULT_SETTINGS, loadSettings, saveSettings } from './settings'
import { parseSourceFolder } from './sourceFolder'
import { parseGrid } from './sprite'
import { normalizeFolder, WebDavClient } from './webdav'

/* -------------------------------------------------------------------------- */
/* 样式                                                                        */
/* -------------------------------------------------------------------------- */

const STYLE = `
#ts-root, #ts-root * { box-sizing: border-box; }
#ts-root { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif; font-size: 13px; line-height: 1.5; color: #111827; }
.ts-launcher { position: fixed; right: 24px; bottom: 84px; z-index: 2147483000; border: 0; border-radius: 999px; padding: 10px 16px; background: #2563eb; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; box-shadow: 0 6px 20px rgba(37,99,235,.35); }
.ts-launcher.ts-running { background: #0f766e; box-shadow: 0 6px 20px rgba(15,118,110,.35); }
.ts-launcher.ts-alert { background: #dc2626; box-shadow: 0 6px 20px rgba(220,38,38,.4); }
.ts-verify { margin-bottom: 12px; border: 1px solid #fca5a5; border-radius: 8px; background: #fef2f2; padding: 10px 12px; }
.ts-verify-title { font-size: 13px; font-weight: 700; color: #b91c1c; }
.ts-verify-text { margin-top: 4px; font-size: 12px; color: #7f1d1d; word-break: break-all; }
.ts-verify .ts-actions-row { padding: 8px 0 0; }
.ts-overlay { display: none; position: fixed; inset: 0; z-index: 2147483000; align-items: center; justify-content: center; background: rgba(15,23,42,.55); padding: 16px; }
.ts-overlay.ts-show { display: flex; }
.ts-panel { display: flex; flex-direction: column; width: min(1180px, 96vw); max-height: 92vh; overflow: hidden; border-radius: 12px; background: #fff; color: #111827; box-shadow: 0 24px 80px rgba(0,0,0,.35); }
.ts-header { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid #e5e7eb; background: #f8fafc; }
.ts-title { font-size: 15px; font-weight: 700; }
.ts-header-status { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: #64748b; }
.ts-header-status.ts-running { color: #0f766e; }
.ts-close { margin-left: auto; width: 28px; height: 28px; border: 0; border-radius: 6px; background: transparent; color: #475569; font-size: 22px; line-height: 1; cursor: pointer; }
.ts-close:hover { background: #e2e8f0; }
.ts-scroll { overflow: auto; padding: 14px 16px 24px; }
.ts-section { border-bottom: 1px solid #eef2f7; padding: 10px 0 14px; }
.ts-section:last-child { border-bottom: 0; }
.ts-section-title { margin-bottom: 8px; font-size: 12px; font-weight: 700; color: #334155; letter-spacing: .02em; }
.ts-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
@media (max-width: 900px) { .ts-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 560px) { .ts-grid { grid-template-columns: 1fr; } }
.ts-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ts-field > span { font-size: 11px; color: #64748b; }
.ts-span-2 { grid-column: span 2; }
.ts-input, .ts-select { width: 100%; height: 30px; border: 1px solid #cbd5e1; border-radius: 6px; padding: 0 8px; background: #fff; color: #111827; font-size: 12px; outline: none; }
.ts-input:focus, .ts-select:focus { border-color: #2563eb; box-shadow: 0 0 0 3px rgba(37,99,235,.12); }
.ts-input[readonly] { background: #f8fafc; color: #475569; }
.ts-input:disabled, .ts-select:disabled { background: #f1f5f9; color: #94a3b8; }
.ts-btn { border: 1px solid #cbd5e1; border-radius: 6px; padding: 6px 12px; background: #fff; color: #111827; font-size: 12px; cursor: pointer; white-space: nowrap; }
.ts-btn:hover:not(:disabled) { background: #f8fafc; border-color: #94a3b8; }
.ts-btn:disabled { cursor: not-allowed; opacity: .5; }
.ts-primary { border-color: #2563eb; background: #2563eb; color: #fff; }
.ts-primary:hover:not(:disabled) { background: #1d4ed8; border-color: #1d4ed8; }
.ts-danger { border-color: #ef4444; color: #b91c1c; }
.ts-danger:hover:not(:disabled) { background: #fef2f2; }
.ts-actions-row { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; padding: 10px 0; }
.ts-hint { font-size: 11px; color: #64748b; word-break: break-all; }
.ts-status { font-size: 12px; color: #475569; word-break: break-all; }
.ts-ok { color: #15803d; }
.ts-err { color: #b91c1c; }
.ts-warn { color: #b45309; }
.ts-summary { margin-left: auto; font-size: 11px; color: #64748b; }
.ts-table-wrap { max-height: 340px; overflow: auto; border: 1px solid #e5e7eb; border-radius: 8px; }
.ts-table { width: 100%; border-collapse: collapse; font-size: 11px; }
.ts-table th, .ts-table td { padding: 6px 8px; border-bottom: 1px solid #f1f5f9; text-align: left; vertical-align: top; }
.ts-table th { position: sticky; top: 0; background: #f8fafc; color: #475569; font-weight: 600; z-index: 1; }
.ts-table tr:last-child td { border-bottom: 0; }
.ts-name { max-width: 360px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ts-message { max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #475569; }
.ts-empty { padding: 18px; text-align: center; color: #94a3b8; }
.ts-badge { display: inline-block; padding: 1px 6px; border-radius: 999px; font-size: 10px; white-space: nowrap; }
.ts-badge-pending { background: #f1f5f9; color: #475569; }
.ts-badge-running { background: #dbeafe; color: #1d4ed8; }
.ts-badge-success { background: #dcfce7; color: #15803d; }
.ts-badge-skipped { background: #f1f5f9; color: #64748b; }
.ts-badge-error { background: #fee2e2; color: #b91c1c; }
.ts-progress { width: 90px; height: 6px; border-radius: 999px; background: #e5e7eb; overflow: hidden; margin-top: 3px; }
.ts-progress > span { display: block; height: 100%; background: #2563eb; transition: width .2s linear; }
.ts-progress-text { font-size: 10px; color: #94a3b8; }
.ts-failure-list { max-height: 220px; overflow: auto; border: 1px solid #e5e7eb; border-radius: 8px; margin-top: 8px; }
.ts-failure-item { padding: 6px 8px; border-bottom: 1px solid #f1f5f9; font-size: 11px; }
.ts-failure-item:last-child { border-bottom: 0; }
.ts-failure-reason { color: #b91c1c; font-weight: 600; }
.ts-log-tabs { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
.ts-log-tab { border: 1px solid #cbd5e1; border-radius: 6px; background: #fff; color: #334155; padding: 4px 10px; font-size: 11px; cursor: pointer; }
.ts-log-tab.ts-active { border-color: #2563eb; background: #eff6ff; color: #1d4ed8; }
.ts-log-count { opacity: .65; margin-left: 2px; }
.ts-log-output { margin-left: 8px; color: #64748b; font-weight: 400; font-size: 11px; }
.ts-log-list { max-height: 280px; overflow: auto; border: 1px solid #e5e7eb; border-radius: 8px; }
.ts-log-item { padding: 6px 8px; border-bottom: 1px solid #f1f5f9; font-size: 11px; }
.ts-log-item:last-child { border-bottom: 0; }
.ts-log-meta { color: #64748b; font-size: 10px; }
.ts-log-name { font-weight: 600; }
.ts-log-folder { color: #64748b; }
.ts-log-message { color: #475569; word-break: break-all; }
.ts-folder-row { display: flex; gap: 8px; align-items: center; }
.ts-folder-row .ts-input { flex: 1; }
.ts-picker { display: none; position: absolute; inset: 0; z-index: 2147483001; align-items: center; justify-content: center; background: rgba(15,23,42,.5); padding: 16px; }
.ts-picker.ts-show { display: flex; }
.ts-picker-panel { display: flex; flex-direction: column; width: min(760px, 94vw); max-height: 82vh; overflow: hidden; border-radius: 10px; background: #fff; box-shadow: 0 20px 60px rgba(0,0,0,.35); }
.ts-picker-header { display: flex; align-items: center; padding: 10px 14px; border-bottom: 1px solid #e5e7eb; font-weight: 700; background: #f8fafc; }
.ts-picker-content { overflow: auto; padding: 12px 14px 16px; }
.ts-picker-url { margin-bottom: 8px; font-size: 11px; color: #64748b; word-break: break-all; }
.ts-picker-error { margin: 8px 0; color: #b91c1c; font-size: 11px; }
.ts-dir-list { border: 1px solid #e5e7eb; border-radius: 8px; max-height: 360px; overflow: auto; }
.ts-dir-item { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid #f1f5f9; font-size: 12px; }
.ts-dir-item:last-child { border-bottom: 0; }
.ts-dir-item .ts-dir-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ts-dir-item button { border: 1px solid #cbd5e1; background: #fff; border-radius: 5px; padding: 3px 8px; font-size: 11px; cursor: pointer; }
.ts-picker-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }

`

/* -------------------------------------------------------------------------- */
/* 状态                                                                        */
/* -------------------------------------------------------------------------- */

type LogCategory = 'success' | 'skip' | 'error' | 'notranscode' | 'info'
type LogTab = 'running' | LogCategory

interface ActivityEvent {
  time: string
  category: LogCategory
  folder: string
  name: string
  message: string
}

const MAX_EVENTS = 1000
const MAX_VISIBLE_ROWS = 300
const MAX_RENDERED_EVENTS = 300
const RUN_LOCK_KEY = 'THUMB_SCRAPER_RUN_LOCK'
const RUN_LOCK_TTL = 15_000
const TAB_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`

let settings = loadSettings()
let rows: Row[] = []
let failureRecords: FailureRecord[] = loadFailures()
let events: ActivityEvent[] = []
const totals = { success: 0, skip: 0, error: 0, notranscode: 0 }
/** 成功产出的文件数：一个视频可能同时产出缩略图和雪碧图 */
const outputs = { thumb: 0, sprite: 0 }
let videoErrors = 0
let folderErrors = 0
let activeLogTab: LogTab = 'running'
let logRenderTimer: number | null = null

let running = false
let starting = false
let scanning = false
let cancelToken: CancelToken = { cancelled: false }
let panelOpen = false
let renderTimer: number | null = null
let foldersSeen = 0
let discoveredVideos = 0
let runStartTime = 0
let progressTimer: number | null = null
let lockTimer: number | null = null
let lastBusy: boolean | null = null
let renderedRowsRef: Row[] | null = null
/** 115 要求验证账号：面板/悬浮按钮保持红色提醒，直到下次开始处理 */
let verifyNeeded = false
/** 本次运行已经播放过验证提醒音 */
let verifyNoticeShown = false
let alertAudio: AudioContext | null = null
const rowElements = new Map<string, HTMLTableRowElement>()

interface RunLock {
  id: string
  time: number
}

interface PickerWebdav {
  url: string
  entries: DavEntry[]
  loading: boolean
  error: string
}

let picker: PickerWebdav | null = null
let pickerRequestId = 0


/* -------------------------------------------------------------------------- */
/* HTML                                                                        */
/* -------------------------------------------------------------------------- */

const PANEL_HTML = `
<button id="ts-launcher" class="ts-launcher" type="button">缩略图</button>
<div id="ts-overlay" class="ts-overlay">
  <div class="ts-panel">
    <div class="ts-header">
      <div class="ts-title">批量生成缩略图 / 雪碧图</div>
      <div id="ts-header-status" class="ts-header-status">空闲</div>
      <button id="ts-close" class="ts-close" type="button" title="关闭">×</button>
    </div>
    <div class="ts-scroll">
      <div id="ts-verify-notice" class="ts-verify" style="display:none">
        <div class="ts-verify-title">115 要求验证账号，已停止处理</div>
        <div id="ts-verify-text" class="ts-verify-text"></div>
        <div class="ts-actions-row">
          <button id="ts-verify-open" class="ts-btn ts-danger" type="button">打开 115 网页完成验证</button>
          <button id="ts-verify-dismiss" class="ts-btn" type="button">知道了</button>
        </div>
      </div>
      <section class="ts-section">
        <div class="ts-section-title">保存地址</div>
        <div class="ts-grid">
          <label class="ts-field ts-span-2"><span>WebDAV 缓存根（与 Purer 的 cache_folder 一致）</span><input id="ts-cache-root" class="ts-input" data-ts-config autocomplete="off"></label>
          <div class="ts-field ts-span-2"><span>要处理的 115 文件夹（WebDAV 地址）</span><div class="ts-folder-row"><input id="ts-source-folder" class="ts-input" data-ts-config autocomplete="off" placeholder="http://10.2.31.10/dav/115/要处理的文件夹"><button id="ts-browse-folder" class="ts-btn" data-ts-config type="button">浏览 DAV</button></div></div>
          <label class="ts-field"><span>用户名</span><input id="ts-user" class="ts-input" data-ts-config autocomplete="off"></label>
          <label class="ts-field"><span>密码（保存在脚本本地）</span><input id="ts-pass" class="ts-input" data-ts-config type="password" autocomplete="off"></label>
          <div class="ts-field"><span>&nbsp;</span><div class="ts-actions-row" style="padding:0"><button id="ts-test" class="ts-btn" data-ts-config type="button">测试连接</button></div></div>
        </div>
        <div id="ts-conn-status" class="ts-hint"></div>
        <div id="ts-target" class="ts-hint" style="margin-top:6px"></div>
        <div class="ts-hint" style="margin-top:2px">可以直接填地址，也可以点「浏览 DAV」从 115 挂载里选择；缓存会镜像到「缓存根/115/该文件夹相对路径/」，不依赖 115 页面当前目录。</div>
      </section>

      <section class="ts-section">
        <div class="ts-section-title">参数</div>
        <div class="ts-grid">
          <label class="ts-field"><span>模式</span><select id="ts-mode" class="ts-select" data-ts-config><option value="both">雪碧图 + 缩略图</option><option value="sprite">只生成雪碧图</option><option value="thumb">只生成缩略图</option></select></label>
          <label class="ts-field"><span>格子（列x行）</span><input id="ts-grid" class="ts-input" data-ts-config placeholder="5x5"></label>
          <label class="ts-field"><span>雪碧图单格最大边长 px</span><input id="ts-cell" class="ts-input" data-ts-config type="number" min="64" max="640"></label>
          <label class="ts-field"><span>雪碧图上限 KB</span><input id="ts-maxkb" class="ts-input" data-ts-config type="number" min="100" max="4096"></label>
          <label class="ts-field"><span>雪碧图最短时长 秒（低于只出缩略图，0 = 不限）</span><input id="ts-sprite-min" class="ts-input" data-ts-config type="number" min="0" max="86400"></label>
          <label class="ts-field"><span>缩略图取帧位置 %</span><input id="ts-percent" class="ts-input" data-ts-config type="number" min="1" max="99"></label>
          <label class="ts-field"><span>视频并发</span><input id="ts-video-conc" class="ts-input" data-ts-config type="number" min="1" max="4"></label>
          <label class="ts-field"><span>单视频解码并发</span><input id="ts-frame-conc" class="ts-input" data-ts-config type="number" min="1" max="4"></label>
          <label class="ts-field"><span>跳过已存在</span><span style="height:30px;display:flex;align-items:center"><input id="ts-skip" data-ts-config type="checkbox" style="width:16px;height:16px"></span></label>
          <label class="ts-field"><span>递归子文件夹</span><span style="height:30px;display:flex;align-items:center"><input id="ts-recursive" data-ts-config type="checkbox" style="width:16px;height:16px"></span></label>
        </div>
        <div class="ts-hint" style="margin-top:6px">视频并发与单视频解码并发各自可用 1–4，默认 3 × 3。时长低于「雪碧图最短时长」的视频只生成缩略图（默认 300s，0 = 不限）；有雪碧图时缩略图直接用雪碧图最后一帧，不再单独取帧；单独取帧的缩略图固定 320px 长边，与 Purer 一致。</div>
        <div id="ts-param-error" class="ts-err" style="font-size:11px;margin-top:6px"></div>
      </section>

      <section class="ts-section">
        <div class="ts-actions-row">
          <button id="ts-scan" class="ts-btn" data-ts-config type="button">扫描目标文件夹</button>
          <button id="ts-start" class="ts-btn ts-primary" data-ts-config type="button">开始处理（逐文件夹）</button>
          <button id="ts-cancel" class="ts-btn ts-danger" type="button" disabled>取消</button>
          <button id="ts-retry-failures" class="ts-btn" type="button" disabled title="只重试失败记录中、目标文件夹下的视频">重试失败项</button>
          <span id="ts-summary" class="ts-summary"></span>
        </div>
        <div id="ts-task-status" class="ts-status"></div>
        <div class="ts-hint" style="margin-top:4px">开始处理会一次只扫描并处理一个文件夹；当前文件夹的视频显示在下表，成功/跳过/失败在下方分类日志里累计。</div>
        <div class="ts-table-wrap" style="margin-top:8px">
          <table class="ts-table">
            <thead><tr><th style="width:34px">#</th><th>视频</th><th style="width:60px">状态</th><th style="width:100px">进度</th><th>说明</th></tr></thead>
            <tbody id="ts-rows"></tbody>
          </table>
        </div>
      </section>

      <details class="ts-section" id="ts-failures-details">
        <summary style="cursor:pointer;font-weight:700;font-size:12px;color:#334155">失败记录 <span id="ts-failure-count">0</span></summary>
        <div class="ts-actions-row">
          <button id="ts-export-failures" class="ts-btn" type="button">导出 JSON</button>
          <button id="ts-clear-failures" class="ts-btn ts-danger" type="button">清空</button>
        </div>
        <div id="ts-failures-list" class="ts-failure-list"></div>
      </details>

      <section class="ts-section">
        <div class="ts-section-title">日志<span id="ts-output-counts" class="ts-log-output">缩略图成功 0 · 雪碧图成功 0</span></div>
        <div id="ts-log-tabs" class="ts-log-tabs">
          <button type="button" class="ts-log-tab" data-log-tab="running">进行中 <span id="ts-count-running" class="ts-log-count">0</span></button>
          <button type="button" class="ts-log-tab" data-log-tab="success">成功 <span id="ts-count-success" class="ts-log-count">0</span></button>
          <button type="button" class="ts-log-tab" data-log-tab="skip">跳过 <span id="ts-count-skip" class="ts-log-count">0</span></button>
          <button type="button" class="ts-log-tab" data-log-tab="notranscode">未转码 <span id="ts-count-notranscode" class="ts-log-count">0</span></button>
          <button type="button" class="ts-log-tab" data-log-tab="error">失败 <span id="ts-count-error" class="ts-log-count">0</span></button>
          <button type="button" class="ts-log-tab" data-log-tab="info">信息 <span id="ts-count-info" class="ts-log-count">0</span></button>
        </div>
        <div id="ts-log-list" class="ts-log-list"></div>
      </section>
    </div>
  </div>

  <div id="ts-picker" class="ts-picker">
    <div class="ts-picker-panel">
      <div class="ts-picker-header"><span id="ts-picker-title">从 DAV 选择 115 文件夹</span><button id="ts-picker-close" class="ts-close" type="button">×</button></div>
      <div id="ts-picker-content" class="ts-picker-content"></div>
    </div>
  </div>
</div>
`

/* -------------------------------------------------------------------------- */
/* 工具                                                                        */
/* -------------------------------------------------------------------------- */

function $id<T extends HTMLElement = HTMLElement>(id: string): T | null {
  return document.getElementById(id) as T | null
}

function must<T extends HTMLElement = HTMLElement>(id: string): T {
  const element = $id<T>(id)
  if (!element) {
    throw new Error(`缺少元素 #${id}`)
  }
  return element
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function clampNumber(value: number, min: number, max: number, fallback: number): number {
  if (!Number.isFinite(value)) {
    return fallback
  }
  return Math.min(max, Math.max(min, Math.round(value)))
}

function numberValue(id: string, fallback: number): number {
  const element = $id<HTMLInputElement>(id)
  const value = Number(element?.value)
  return Number.isFinite(value) ? value : fallback
}

/** 允许空输入回退默认值的数字（用于 0 = 不限的字段） */
function optionalNumberValue(id: string, fallback: number): number {
  const text = $id<HTMLInputElement>(id)?.value.trim() ?? ''
  if (!text) {
    return fallback
  }
  const value = Number(text)
  return Number.isFinite(value) ? value : fallback
}

function decodeUrlForDisplay(url: string): string {
  try {
    return decodeURIComponent(url)
  }
  catch {
    return url
  }
}

/**
 * WebDAV 地址的可读形式
 * @description 逐段解码中文/空格，但保留 # ? % 等 URL 保留字符的编码，
 * 避免把地址写回输入框后再次解析时被当成查询串或锚点。
 */
function displayFolderUrl(url: string): string {
  try {
    const parsed = new URL(url)
    parsed.pathname = parsed.pathname
      .split('/')
      .map((segment) => {
        let decoded: string
        try {
          decoded = decodeURIComponent(segment)
        }
        catch {
          return segment
        }
        return decoded.replace(/[%?#]/g, char => encodeURIComponent(char))
      })
      .join('/')
    return parsed.href
  }
  catch {
    return url
  }
}

function logCategoryLabel(tab: LogTab): string {
  switch (tab) {
    case 'running': return '进行中'
    case 'success': return '成功'
    case 'skip': return '跳过'
    case 'error': return '失败'
    case 'notranscode': return '未转码'
    case 'info': return '信息'
  }
}

function scheduleLogs(): void {
  if (logRenderTimer !== null) {
    return
  }
  logRenderTimer = window.setTimeout(() => {
    logRenderTimer = null
    renderLogs()
  }, 100)
}

function resetTotals(): void {
  totals.success = 0
  totals.skip = 0
  totals.error = 0
  totals.notranscode = 0
  outputs.thumb = 0
  outputs.sprite = 0
}

function addEvent(
  category: LogCategory,
  detail: { folder?: string, name?: string, message: string },
): void {
  if (category === 'success') {
    totals.success++
  }
  else if (category === 'skip') {
    totals.skip++
  }
  else if (category === 'error') {
    totals.error++
  }
  else if (category === 'notranscode') {
    totals.notranscode++
  }
  events.push({
    time: new Date().toLocaleTimeString(),
    category,
    folder: detail.folder || '',
    name: detail.name || '',
    message: detail.message,
  })
  if (events.length > MAX_EVENTS) {
    events.splice(0, events.length - MAX_EVENTS)
  }
  scheduleLogs()
}

function addInfo(message: string): void {
  addEvent('info', { message })
}

function scheduleRows(): void {
  if (renderTimer !== null) {
    return
  }
  renderTimer = window.setTimeout(() => {
    renderTimer = null
    renderRows()
  }, 300)
}

function setConnectionStatus(text: string, kind: 'ok' | 'warn' | 'error' | '' = ''): void {
  const element = $id('ts-conn-status')
  if (!element) {
    return
  }
  element.textContent = text
  const suffix = kind === 'ok' ? ' ts-ok' : kind === 'warn' ? ' ts-warn' : kind === 'error' ? ' ts-err' : ''
  element.className = `ts-hint${suffix}`
}

function setTaskStatus(text: string, kind: 'ok' | 'error' | '' = ''): void {
  const element = $id('ts-task-status')
  if (!element) {
    return
  }
  element.textContent = text
  element.className = `ts-status${kind === 'ok' ? ' ts-ok' : kind === 'error' ? ' ts-err' : ''}`
}

/** 预创建 AudioContext：点击「开始处理」属于用户手势，之后才能可靠地播放提示音 */
function prepareAlertAudio(): void {
  try {
    const Ctor = window.AudioContext
      ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctor) {
      return
    }
    alertAudio ??= new Ctor()
    if (alertAudio.state === 'suspended') {
      void alertAudio.resume().catch(() => {})
    }
  }
  catch {
    // 浏览器不支持/不允许音频时静默处理
  }
}

/** 提醒音：三声短促提示音（Web Audio，不依赖外部资源） */
function playAlertSound(): void {
  try {
    prepareAlertAudio()
    const ctx = alertAudio
    if (!ctx) {
      return
    }
    const start = ctx.currentTime + 0.02
    const notes: [number, number][] = [[0, 880], [0.28, 1174.66], [0.56, 880]]
    for (const [offset, frequency] of notes) {
      const oscillator = ctx.createOscillator()
      const gain = ctx.createGain()
      oscillator.type = 'sine'
      oscillator.frequency.value = frequency
      const at = start + offset
      gain.gain.setValueAtTime(0.0001, at)
      gain.gain.exponentialRampToValueAtTime(0.25, at + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, at + 0.22)
      oscillator.connect(gain)
      gain.connect(ctx.destination)
      oscillator.start(at)
      oscillator.stop(at + 0.24)
    }
  }
  catch {
    // 忽略音频播放失败
  }
}

/**
 * 115 要求验证账号：停止处理并醒目提醒
 * @description 继续请求只会让每个视频都失败，因此先中止整批任务，
 * 打开面板显示红色提示，并播放提示音；用户完成验证后重新开始即可。
 */
function showVerifyNotice(message: string): void {
  if (verifyNoticeShown) {
    return
  }
  verifyNoticeShown = true
  verifyNeeded = true

  const notice = $id<HTMLElement>('ts-verify-notice')
  const text = $id<HTMLElement>('ts-verify-text')
  if (notice) {
    notice.style.display = ''
  }
  if (text) {
    text.textContent = `115 返回：${message || '请验证账号'}。请在 115 网页完成账号验证（如手机/短信验证），验证成功后再点「开始处理」继续；已生成的视频会按「跳过已存在」跳过。`
  }

  if (!panelOpen) {
    openPanel()
  }
  setTaskStatus('115 要求验证账号，已停止处理；请完成验证后再继续', 'error')
  updateStatusText()
  addEvent('error', { message: `115 要求验证账号，已停止处理：${message || '请验证账号'}` })
  activeLogTab = 'error'
  renderLogs()
  playAlertSound()
  notice?.scrollIntoView?.({ block: 'nearest' })
}

/** 用户点「知道了」：只隐藏提示，本次运行不再重复提醒 */
function dismissVerifyNotice(): void {
  verifyNeeded = false
  const notice = $id<HTMLElement>('ts-verify-notice')
  if (notice) {
    notice.style.display = 'none'
  }
  updateStatusText()
}

/** 开始新任务时清掉验证提醒，让下一次失败可以重新提醒 */
function hideVerifyNotice(): void {
  verifyNoticeShown = false
  dismissVerifyNotice()
}

/* -------------------------------------------------------------------------- */
/* 表单                                                                        */
/* -------------------------------------------------------------------------- */

function writeForm(): void {
  must<HTMLInputElement>('ts-cache-root').value = settings.cacheRoot
  must<HTMLInputElement>('ts-source-folder').value = displayFolderUrl(settings.sourceFolder)
  must<HTMLInputElement>('ts-user').value = settings.username
  must<HTMLInputElement>('ts-pass').value = settings.password
  must<HTMLSelectElement>('ts-mode').value = settings.mode
  must<HTMLInputElement>('ts-grid').value = settings.grid
  must<HTMLInputElement>('ts-cell').value = String(settings.cellWidth)
  must<HTMLInputElement>('ts-maxkb').value = String(settings.maxKB)
  must<HTMLInputElement>('ts-sprite-min').value = String(settings.spriteMinDuration)
  must<HTMLInputElement>('ts-percent').value = String(settings.percent)
  must<HTMLInputElement>('ts-video-conc').value = String(settings.videoConcurrency)
  must<HTMLInputElement>('ts-frame-conc').value = String(settings.frameConcurrency)
  must<HTMLInputElement>('ts-skip').checked = settings.skipExisting
  must<HTMLInputElement>('ts-recursive').checked = settings.recursive
  updateTarget()
}

function writeFolder(): void {
  must<HTMLInputElement>('ts-source-folder').value = settings.sourceFolder
  updateTarget()
  updateRetryButton()
}

function readForm(): ScraperSettings {
  return {
    ...settings,
    cacheRoot: must<HTMLInputElement>('ts-cache-root').value.trim(),
    sourceFolder: must<HTMLInputElement>('ts-source-folder').value.trim(),
    username: must<HTMLInputElement>('ts-user').value.trim(),
    password: must<HTMLInputElement>('ts-pass').value,
    mode: must<HTMLSelectElement>('ts-mode').value as Mode,
    grid: must<HTMLInputElement>('ts-grid').value.trim(),
    cellWidth: numberValue('ts-cell', settings.cellWidth),
    maxKB: numberValue('ts-maxkb', settings.maxKB),
    spriteMinDuration: optionalNumberValue('ts-sprite-min', settings.spriteMinDuration),
    percent: numberValue('ts-percent', settings.percent),
    videoConcurrency: numberValue('ts-video-conc', settings.videoConcurrency),
    frameConcurrency: numberValue('ts-frame-conc', settings.frameConcurrency),
    skipExisting: must<HTMLInputElement>('ts-skip').checked,
    recursive: must<HTMLInputElement>('ts-recursive').checked,
  }
}

function normalizeSettings(input: ScraperSettings): ScraperSettings {
  const result: ScraperSettings = { ...input }
  result.cacheRoot = normalizeFolder(result.cacheRoot)
  result.sourceWebdavRoot = result.sourceWebdavRoot.trim()
    ? normalizeFolder(result.sourceWebdavRoot)
    : ''
  result.sourcePrefix = result.sourcePrefix.replace(/^\/+|\/+$/g, '')
  result.sourceFolder = result.sourceFolder.trim()
  if (result.sourceFolder) {
    // 保留用户输入的地址原样，方便阅读；folderPath 由地址推导
    result.folderPath = parseSourceFolder(result.sourceFolder, result).path
  }
  else {
    result.folderPath = ''
  }
  result.grid = result.grid.trim()
  parseGrid(result.grid)
  result.cellWidth = clampNumber(result.cellWidth, 64, 640, 320)
  result.maxKB = clampNumber(result.maxKB, 100, 4096, 1024)
  result.spriteMinDuration = Math.round(clampNumber(result.spriteMinDuration, 0, 86400, 300))
  result.percent = clampNumber(result.percent, 1, 99, 80)
  result.videoConcurrency = clampNumber(result.videoConcurrency, 1, 4, 3)
  result.frameConcurrency = clampNumber(result.frameConcurrency, 1, 4, 3)
  result.mode = ['both', 'sprite', 'thumb'].includes(result.mode) ? result.mode : 'both'
  return result
}

function readAndNormalize(): ScraperSettings {
  const normalized = normalizeSettings(readForm())
  settings = normalized
  saveSettings(settings)
  writeForm()
  return normalized
}

function updateTarget(): void {
  const element = $id('ts-target')
  if (!element) {
    return
  }
  try {
    const raw = readForm()
    const source = parseSourceFolder(raw.sourceFolder, raw)
    const target = buildTargetFolder({
      ...settings,
      cacheRoot: normalizeFolder(raw.cacheRoot),
      sourcePrefix: raw.sourcePrefix,
      folderPath: source.path,
    })
    element.textContent = `目标：${decodeUrlForDisplay(target)}${settings.recursive ? '（子文件夹按相对路径镜像）' : ''}`
    element.className = 'ts-hint'
  }
  catch (error) {
    element.textContent = `目标：${messageOf(error)}`
    element.className = 'ts-hint ts-err'
  }
}

/* -------------------------------------------------------------------------- */
/* 运行状态                                                                    */
/* -------------------------------------------------------------------------- */

function isBusy(): boolean {
  return running || starting || scanning
}

function formatElapsed(seconds: number): string {
  const total = Math.max(0, Math.round(seconds))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
    : `${minutes}:${String(secs).padStart(2, '0')}`
}

/** 头部/悬浮按钮状态文字（含整体进度、已用时间与粗略剩余时间） */
function updateStatusText(): void {
  const header = $id<HTMLDivElement>('ts-header-status')
  const launcher = $id<HTMLButtonElement>('ts-launcher')
  let headerText = '空闲'
  let headerRunning = false
  let launcherText = '缩略图'
  let launcherRunning = false

  if (verifyNeeded) {
    headerText = '需要验证 115 账号，处理已停止'
    launcherText = '需要验证账号'
  }
  else if (starting) {
    headerText = '准备中…'
    headerRunning = true
    launcherText = '准备中…'
    launcherRunning = true
  }
  else if (running) {
    const done = totals.success + totals.skip + videoErrors
    const known = Math.max(discoveredVideos, done)
    // 跳过的是缓存已存在，不计入成功占比的总数
    const counted = Math.max(0, known - totals.skip)
    const percent = counted > 0 ? Math.round((totals.success / counted) * 100) : 0
    const elapsed = Math.max(1, Math.floor((Date.now() - runStartTime) / 1000))
    const rate = done > 0 ? done / elapsed : 0
    const remaining = Math.max(0, known - done)
    const eta = rate > 0 ? Math.round(remaining / rate) : 0
    const folderPart = foldersSeen > 0 ? ` · 目录 ${foldersSeen}` : ''
    const successPart = counted > 0
      ? `成功 ${totals.success}/${counted}（${percent}%）`
      : `成功 ${totals.success}`
    const notranscodePart = totals.notranscode > 0 ? ` · 未转码 ${totals.notranscode}` : ''
    headerText = `生成中${folderPart} · ${successPart}${notranscodePart} · 失败 ${totals.error} · 已用 ${formatElapsed(elapsed)}${eta > 0 ? ` · 约剩 ${formatElapsed(eta)}` : ''}`
    headerRunning = true
    launcherText = counted > 0
      ? `生成中 ${totals.success}/${counted}（${percent}%）`
      : `生成中 ${totals.success}`
    launcherRunning = true
  }
  else if (scanning) {
    headerText = '扫描中'
    headerRunning = true
  }

  if (header) {
    header.textContent = headerText
    header.title = headerText
    header.className = `ts-header-status${headerRunning ? ' ts-running' : ''}`
  }
  if (launcher) {
    launcher.textContent = launcherText
    launcher.title = launcherText
    launcher.classList.toggle('ts-running', launcherRunning)
    launcher.classList.toggle('ts-alert', verifyNeeded)
  }
}

function updateRetryButton(): void {
  const button = $id<HTMLButtonElement>('ts-retry-failures')
  if (!button) {
    return
  }
  const count = failureRecords.filter(record => failureRelativeDir(record.folder) !== null).length
  button.disabled = isBusy() || count === 0
  button.textContent = count > 0 ? `重试失败项（${count}）` : '重试失败项'
}

function setBusyUi(force = false): void {
  const busy = isBusy()
  // 只在忙碌状态切换时批量改 disabled，避免进度刷新时反复触碰所有控件
  if (force || busy !== lastBusy) {
    document.querySelectorAll<HTMLElement>('#ts-root [data-ts-config]').forEach((element) => {
      if (element instanceof HTMLInputElement || element instanceof HTMLSelectElement || element instanceof HTMLButtonElement) {
        element.disabled = busy
      }
    })
    lastBusy = busy
  }
  const cancelButton = $id<HTMLButtonElement>('ts-cancel')
  if (cancelButton) {
    cancelButton.disabled = !(running || starting)
  }
  updateRetryButton()
  updateStatusText()
}

/* -------------------------------------------------------------------------- */
/* 多标签页互斥（只做提示，不强行阻止）                                        */
/* -------------------------------------------------------------------------- */

function readRunLock(): RunLock | null {
  const value = GM_getValue<RunLock | null>(RUN_LOCK_KEY, null)
  if (!value || typeof value.id !== 'string' || typeof value.time !== 'number') {
    return null
  }
  return value
}

function writeRunLock(): void {
  GM_setValue(RUN_LOCK_KEY, { id: TAB_ID, time: Date.now() })
}

function acquireRunLock(): boolean {
  const lock = readRunLock()
  if (lock && lock.id !== TAB_ID && Date.now() - lock.time < RUN_LOCK_TTL) {
    if (!window.confirm('检测到另一个 115 标签页正在处理任务，同时运行会重复解码和上传。仍要继续吗？')) {
      return false
    }
  }
  writeRunLock()
  if (lockTimer === null) {
    lockTimer = window.setInterval(writeRunLock, 5000)
  }
  return true
}

function releaseRunLock(): void {
  if (lockTimer !== null) {
    window.clearInterval(lockTimer)
    lockTimer = null
  }
  if (readRunLock()?.id === TAB_ID) {
    GM_setValue(RUN_LOCK_KEY, null)
  }
}

function startProgressTimer(): void {
  stopProgressTimer()
  progressTimer = window.setInterval(updateStatusText, 1000)
}

function stopProgressTimer(): void {
  if (progressTimer !== null) {
    window.clearInterval(progressTimer)
    progressTimer = null
  }
}

/* -------------------------------------------------------------------------- */
/* 渲染                                                                        */
/* -------------------------------------------------------------------------- */

function statusLabel(status: Row['status']): string {
  switch (status) {
    case 'pending': return '等待'
    case 'running': return '生成中'
    case 'success': return '成功'
    case 'skipped': return '跳过'
    case 'error': return '失败'
  }
}

function badgeClass(status: Row['status']): string {
  return `ts-badge ts-badge-${status === 'pending' ? 'pending' : status === 'running' ? 'running' : status === 'success' ? 'success' : status === 'skipped' ? 'skipped' : 'error'}`
}

function modeLabel(mode: Mode | null): string {
  if (!mode) {
    return '已跳过'
  }
  if (mode === 'both') {
    return '雪碧图 + 缩略图'
  }
  return mode === 'sprite' ? '雪碧图' : '缩略图'
}

function rowProgressHtml(row: Row): string {
  if (row.status === 'running') {
    return `<div class="ts-progress"><span style="width:${row.progress}%"></span></div><div class="ts-progress-text">${escapeHtml(row.progressText)}</div>`
  }
  if (row.progressText) {
    return `<div class="ts-progress-text">${escapeHtml(row.progressText)}</div>`
  }
  return '—'
}

function rowMessageHtml(row: Row): string {
  const message = row.message || row.filename || '—'
  return `<div class="ts-message" title="${escapeHtml(message)}">${escapeHtml(message)}</div>`
}

/** 只更新一行的状态/进度/说明，避免整表重排 */
function updateRowCells(row: Row, tr: HTMLTableRowElement): void {
  const statusCell = tr.querySelector<HTMLElement>('.ts-cell-status')
  if (statusCell) {
    statusCell.innerHTML = `<span class="${badgeClass(row.status)}">${statusLabel(row.status)}</span>`
  }
  const progressCell = tr.querySelector<HTMLElement>('.ts-cell-progress')
  if (progressCell) {
    progressCell.innerHTML = rowProgressHtml(row)
  }
  const messageCell = tr.querySelector<HTMLElement>('.ts-cell-message')
  if (messageCell) {
    messageCell.innerHTML = rowMessageHtml(row)
  }
}

/** 整表重建（只在切换文件夹/行集合变化时发生） */
function renderRowsFull(visibleRows: Row[]): void {
  const tbody = $id<HTMLElement>('ts-rows')
  if (!tbody) {
    return
  }
  rowElements.clear()
  tbody.innerHTML = visibleRows.map((row, index) => `
    <tr data-row-id="${escapeHtml(row.id)}">
      <td>${index + 1}</td>
      <td><div class="ts-name" title="${escapeHtml(row.name)}">${escapeHtml(row.name)}</div><div class="ts-progress-text" title="${escapeHtml(row.relativeDir)}">${row.relativeDir ? `${escapeHtml(row.relativeDir)} · ` : ''}${escapeHtml(modeLabel(row.effectiveMode))}</div></td>
      <td class="ts-cell-status"><span class="${badgeClass(row.status)}">${statusLabel(row.status)}</span></td>
      <td class="ts-cell-progress">${rowProgressHtml(row)}</td>
      <td class="ts-cell-message">${rowMessageHtml(row)}</td>
    </tr>
  `).join('') + (rows.length > MAX_VISIBLE_ROWS
    ? `<tr><td colspan="5" class="ts-empty">只显示前 ${MAX_VISIBLE_ROWS} 条，共 ${rows.length} 条；完整结果见下方分类日志。</td></tr>`
    : '')
  tbody.querySelectorAll<HTMLTableRowElement>('tr[data-row-id]').forEach((tr) => {
    const id = tr.dataset.rowId
    if (id) {
      rowElements.set(id, tr)
    }
  })
}

function renderRows(): void {
  const tbody = $id<HTMLElement>('ts-rows')
  if (!tbody) {
    return
  }

  if (rows.length === 0) {
    if (renderedRowsRef !== rows) {
      tbody.innerHTML = '<tr><td colspan="5" class="ts-empty">还没有视频。点「开始处理」会逐文件夹扫描；或点「扫描目标文件夹」预览直接视频。</td></tr>'
      rowElements.clear()
      renderedRowsRef = rows
    }
  }
  else {
    const visibleRows = rows.slice(0, MAX_VISIBLE_ROWS)
    if (renderedRowsRef !== rows || rowElements.size !== visibleRows.length) {
      renderRowsFull(visibleRows)
      renderedRowsRef = rows
    }
    else {
      for (const row of visibleRows) {
        const tr = rowElements.get(row.id)
        if (tr) {
          updateRowCells(row, tr)
        }
      }
    }
  }

  const counts = { pending: 0, running: 0, success: 0, skipped: 0, error: 0 }
  for (const row of rows) {
    counts[row.status]++
  }
  const summary = $id('ts-summary')
  if (summary) {
    summary.textContent = `视频 ${rows.length} · 等待 ${counts.pending} · 生成中 ${counts.running} · 成功 ${counts.success} · 跳过 ${counts.skipped} · 失败 ${counts.error}`
  }

  if (running || starting) {
    updateStatusText()
  }
  if (activeLogTab === 'running') {
    renderLogs()
  }
  else {
    renderLogCounts()
  }
}

function formatFailureTime(time: string): string {
  const date = new Date(time)
  return Number.isNaN(date.getTime()) ? time : date.toLocaleString()
}

function renderFailures(): void {
  const count = $id('ts-failure-count')
  if (count) {
    count.textContent = failureRecords.length >= 500
      ? '(500，仅保留最新)'
      : `(${failureRecords.length})`
  }
  const list = $id<HTMLElement>('ts-failures-list')
  if (!list) {
    return
  }
  if (failureRecords.length === 0) {
    list.innerHTML = '<div class="ts-empty">暂无失败记录</div>'
    updateRetryButton()
    return
  }
  list.innerHTML = failureRecords.slice().reverse().map(record => `
    <div class="ts-failure-item">
      <div><span class="ts-failure-reason">${escapeHtml(reasonLabel(record.reason))}</span> · ${escapeHtml(record.name)}</div>
      <div style="color:#64748b">${escapeHtml(formatFailureTime(record.time))} · ${escapeHtml(record.folder || '(根目录)')}</div>
      <div style="color:#475569;word-break:break-all">${escapeHtml(record.message)}</div>
    </div>
  `).join('')
  updateRetryButton()
}

function renderLogCounts(): void {
  const counts: Record<LogTab, number> = {
    running: rows.filter(row => row.status === 'running').length,
    success: totals.success,
    skip: totals.skip,
    error: totals.error,
    notranscode: totals.notranscode,
    info: events.filter(event => event.category === 'info').length,
  }
  for (const key of Object.keys(counts) as LogTab[]) {
    const element = $id(`ts-count-${key}`)
    if (element) {
      element.textContent = String(counts[key])
    }
  }
  const outputCounts = $id('ts-output-counts')
  if (outputCounts) {
    outputCounts.textContent = `缩略图成功 ${outputs.thumb} · 雪碧图成功 ${outputs.sprite}`
  }
  document.querySelectorAll<HTMLElement>('#ts-log-tabs [data-log-tab]').forEach((button) => {
    button.classList.toggle('ts-active', button.dataset.logTab === activeLogTab)
  })
}

function renderLogs(): void {
  const list = $id<HTMLElement>('ts-log-list')
  if (!list) {
    return
  }
  renderLogCounts()

  const runningRows = rows.filter(row => row.status === 'running')
  if (activeLogTab === 'running') {
    if (runningRows.length === 0) {
      list.innerHTML = '<div class="ts-empty">暂无进行中的任务</div>'
      return
    }
    list.innerHTML = runningRows.map(row => `
      <div class="ts-log-item">
        <div><span class="ts-log-name">${escapeHtml(row.name)}</span> <span class="ts-log-folder">${escapeHtml(row.relativeDir || '根目录')}</span></div>
        <div class="ts-progress"><span style="width:${row.progress}%"></span></div>
        <div class="ts-log-meta">${escapeHtml(row.progressText || '')} ${escapeHtml(row.message || '')}</div>
      </div>
    `).join('')
    return
  }

  const items = events.filter(event => event.category === activeLogTab).slice().reverse()
  if (items.length === 0) {
    list.innerHTML = `<div class="ts-empty">暂无${logCategoryLabel(activeLogTab)}记录</div>`
    return
  }
  const visible = items.slice(0, MAX_RENDERED_EVENTS)
  list.innerHTML = visible.map(event => `
    <div class="ts-log-item">
      <div>
        <span class="ts-log-meta">${escapeHtml(event.time)}</span>
        ${event.folder ? `<span class="ts-log-folder"> · ${escapeHtml(event.folder)}</span>` : ''}
        ${event.name ? `<span class="ts-log-name"> · ${escapeHtml(event.name)}</span>` : ''}
      </div>
      <div class="ts-log-message">${escapeHtml(event.message)}</div>
    </div>
  `).join('') + (items.length > visible.length
    ? `<div class="ts-empty">只显示最近 ${MAX_RENDERED_EVENTS} 条，共 ${items.length} 条</div>`
    : '')
}

/* -------------------------------------------------------------------------- */
/* 扫描与运行                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * 把「要处理的 115 文件夹」解析成 115 API 的 cid
 * @description 只按地址里的路径在 115 API 中逐级查找，不再读取浏览器当前目录。
 */
async function resolveTargetCid(path: string): Promise<CidResolution> {
  if (!path) {
    return { cid: '0', apiPath: '' }
  }
  return resolveCidByPathDetailed(path)
}

/** 115 API 定位失败时的可操作提示（附带该级实际存在的目录名） */
function cidFailureMessage(target: SourceTarget, resolution: CidResolution): string {
  const level = `115 API 的「${resolution.apiPath || '根目录'}」`
  let detail = ''
  if (resolution.available && resolution.available.length > 0) {
    detail = `；${level}下有文件夹：${resolution.available.slice(0, 8).join('、')}`
  }
  else if (resolution.entryCount === 0) {
    detail = resolution.apiPath
      ? `；${level}返回了 0 个条目`
      : '；115 API 根目录为空：浏览器登录的 115 账号与 WebDAV 挂载的 115 不是同一份数据（或 115 登录已失效 / 挂载的是分享目录），pickcode 无处可取。请确认两边是同一个 115 账号和文件根目录'
  }
  else if (resolution.entryCount !== undefined) {
    const sample = resolution.sampleEntries && resolution.sampleEntries.length > 0
      ? `：${resolution.sampleEntries.join('、')}`
      : ''
    detail = `；${level}返回了 ${resolution.entryCount} 个条目，但没有文件夹${sample}`
  }
  else {
    detail = `；${level}没有返回文件夹`
  }
  return `115 API 中找不到「${resolution.failedSegment ?? target.path}」（来自 ${decodeUrlForDisplay(target.url)}）${detail}`
}

function folderDisplay(folderPath: string, relativeDir: string): string {
  return [folderPath, relativeDir].filter(Boolean).join('/') || '(根目录)'
}

/** 扫描目标文件夹的直接视频（不递归），只用于快速预览 */
async function scan(): Promise<void> {
  if (running || scanning || starting) {
    return
  }
  hideVerifyNotice()
  scanning = true
  rows = []
  events = []
  resetTotals()
  videoErrors = 0
  folderErrors = 0
  activeLogTab = 'skip'
  renderRows()
  renderLogs()
  setBusyUi()
  setTaskStatus('正在扫描目标文件夹…')
  setConnectionStatus('')

  try {
    const normalized = readAndNormalize()
    const target = parseSourceFolder(normalized.sourceFolder, normalized)
    setTaskStatus(`正在定位 115 路径：${target.path || '(根目录)'}…`)
    const resolution = await resolveTargetCid(target.path)
    if (resolution.cid === null) {
      const message = cidFailureMessage(target, resolution)
      setTaskStatus(message, 'error')
      addEvent('error', { message })
      activeLogTab = 'error'
      renderLogs()
      return
    }
    const cid = resolution.cid
    settings = normalized
    saveSettings(settings)
    writeFolder()

    const result = await listVideos(cid)

    let cacheFiles: string[] = []
    let cacheError = ''
    if (settings.skipExisting) {
      try {
        const client = new WebDavClient(settings.cacheRoot, settings.username, settings.password)
        cacheFiles = await listExisting(client, buildTargetFolder(settings))
      }
      catch (error) {
        cacheError = messageOf(error)
      }
    }

    rows = buildRows(result.videos, new Map([['', cacheFiles]]), settings)

    for (const row of rows) {
      if (row.status === 'skipped') {
        addEvent('skip', {
          folder: folderDisplay(settings.folderPath, ''),
          name: row.name,
          message: row.message || '缓存已存在（目标文件夹预览）',
        })
      }
    }

    activeLogTab = totals.skip > 0 ? 'skip' : 'info'
    settings.configured = true
    saveSettings(settings)
    renderRows()
    renderLogs()
    setTaskStatus(`目标文件夹预览：${result.videos.length} 个视频（开始处理会逐文件夹递归）`, 'ok')
    addInfo(`目标文件夹预览：${result.videos.length} 个视频`)
    if (cacheError) {
      addInfo(`缓存目录读取失败：${cacheError}；本次预览不标记已存在`)
      setConnectionStatus(`缓存目录读取失败：${cacheError}（预览仍可用，开始处理前请检查）`, 'warn')
    }
    else if (!settings.skipExisting) {
      setConnectionStatus('已关闭「跳过已存在」，未读取缓存目录')
    }
    else {
      setConnectionStatus('WebDAV 缓存目录可读', 'ok')
    }
  }
  catch (error) {
    if (error instanceof AccountVerifyError) {
      showVerifyNotice(messageOf(error))
      return
    }
    setTaskStatus(`扫描失败：${messageOf(error)}`, 'error')
    setConnectionStatus(`扫描失败：${messageOf(error)}`, 'error')
    addEvent('error', { message: `扫描失败：${messageOf(error)}` })
    activeLogTab = 'error'
    renderLogs()
  }
  finally {
    scanning = false
    setBusyUi(true)
    renderRows()
    renderLogs()
  }
}

/** 清除某个视频在某个目录下的失败记录（成功后调用） */
function clearFailureFor(pickCode: string, folder: string, name: string): void {
  const exists = failureRecords.some(record =>
    record.folder === folder
    && (record.pickCode === pickCode || (!record.pickCode && record.name === name)),
  )
  if (!exists) {
    return
  }
  failureRecords = removeFailure(pickCode, folder, name)
  renderFailures()
}

/** 视频成功/失败时统一更新日志、失败记录和总数 */
function handleVideoEvent(event: RunEvent): void {
  const eventFolder = folderDisplay(settings.folderPath, event.row.relativeDir)
  if (event.produced) {
    if (event.produced.thumb) {
      outputs.thumb++
    }
    if (event.produced.sprite) {
      outputs.sprite++
    }
  }
  // 115 没有转码的视频无法获取，单独计入「未转码」；其余雪碧图/解码问题按失败记录
  const category: LogCategory = event.reason === 'no-hls' ? 'notranscode' : event.category
  addEvent(category, {
    folder: eventFolder,
    name: event.row.name,
    message: event.reason ? `${reasonLabel(event.reason)} · ${event.message}` : event.message,
  })
  if (event.category === 'error') {
    videoErrors++
    // 账号验证失败是整批问题，不写进按视频重试的失败记录，改为提醒用户去验证
    if (event.reason === 'verify') {
      showVerifyNotice(event.message)
      return
    }
    failureRecords = addFailure({
      time: new Date().toISOString(),
      name: event.row.name,
      pickCode: event.row.pickCode,
      folder: eventFolder,
      reason: event.reason || 'error',
      message: event.message,
      duration: event.row.duration,
    })
    renderFailures()
  }
  else {
    clearFailureFor(event.row.pickCode, eventFolder, event.row.name)
  }
}

/** 逐文件夹扫描并处理 */
async function start(): Promise<void> {
  if (running || scanning || starting) {
    return
  }
  if (!acquireRunLock()) {
    return
  }

  hideVerifyNotice()
  // 先占住状态，避免启动阶段的 await 期间被双击/扫描插入第二套任务
  starting = true
  cancelToken = { cancelled: false }
  runStartTime = Date.now()
  foldersSeen = 0
  discoveredVideos = 0
  rows = []
  events = []
  resetTotals()
  videoErrors = 0
  folderErrors = 0
  activeLogTab = 'running'
  startProgressTimer()
  renderRows()
  renderLogs()
  setBusyUi()
  setConnectionStatus('')
  setTaskStatus('正在准备…')

  try {
    const normalized = readAndNormalize()
    const target = parseSourceFolder(normalized.sourceFolder, normalized)
    setTaskStatus(`正在定位 115 路径：${target.path || '(根目录)'}…`)
    const resolution = await resolveTargetCid(target.path)
    if (resolution.cid === null) {
      const message = cidFailureMessage(target, resolution)
      setTaskStatus(message, 'error')
      addEvent('error', { message })
      activeLogTab = 'error'
      return
    }
    const cid = resolution.cid
    settings = normalized
    saveSettings(settings)
    writeFolder()

    const cacheClient = new WebDavClient(settings.cacheRoot, settings.username, settings.password)
    const sourceClient = new WebDavClient(target.url, settings.username, settings.password)

    if (cancelToken.cancelled) {
      setTaskStatus('已取消')
      addInfo('已取消，未开始处理')
      return
    }

    // 先确认缓存目录可写，避免每个文件夹都因认证/路径失败
    await cacheClient.ensureTree(buildTargetFolder(settings), settings.cacheRoot)

    if (cancelToken.cancelled) {
      setTaskStatus('已取消')
      addInfo('已取消，未开始处理')
      return
    }

    running = true
    starting = false
    setBusyUi()
    setTaskStatus('开始逐文件夹扫描并处理…')
    addInfo(
      `开始处理：${decodeUrlForDisplay(target.url)} → ${decodeUrlForDisplay(buildTargetFolder(settings))}`
      + ` · ${settings.recursive ? '递归子文件夹' : '仅当前目录'}`
      + ` · 并发 ${settings.videoConcurrency} × ${settings.frameConcurrency}`,
    )
    settings.configured = true
    saveSettings(settings)

    let folderIndex = 0
    await walkFolders({
      settings,
      startCid: cid,
      sourceClient,
      cancel: cancelToken,
      onLog: (message, level) => {
        if (level === 'error') {
          folderErrors++
        }
        addEvent(level === 'error' ? 'error' : 'info', { message })
      },
      onProgress: (folders, count) => {
        foldersSeen = Math.max(foldersSeen, folders)
        discoveredVideos = Math.max(discoveredVideos, count)
        setTaskStatus(`扫描：已发现 ${folders} 个文件夹 / ${count} 个视频`)
        updateStatusText()
      },
      onFolder: async (folder) => {
        if (cancelToken.cancelled) {
          return
        }
        folderIndex++
        foldersSeen = Math.max(foldersSeen, folderIndex)
        const relative = folder.relativeDir
        const folderLabel = folderDisplay(settings.folderPath, relative)

        rows = []
        renderRows()
        renderLogs()

        if (folder.videos.length === 0) {
          addInfo(`文件夹 ${folderLabel}：没有视频`)
          return
        }

        setTaskStatus(`处理文件夹 ${folderIndex}：${folderLabel}（${folder.videos.length} 个视频）`)
        addInfo(`文件夹 ${folderLabel}：${folder.videos.length} 个视频`)

        // 单个文件夹失败（WebDAV 临时故障等）只跳过该文件夹，不终止整批
        try {
          const cacheFiles = settings.skipExisting
            ? await listExisting(cacheClient, buildTargetFolder(settings, relative))
            : []
          const folderRows = buildRows(
            folder.videos,
            new Map([[relative, cacheFiles]]),
            settings,
          )
          rows = folderRows

          for (const row of folderRows) {
            if (row.status === 'skipped') {
              addEvent('skip', {
                folder: folderLabel,
                name: row.name,
                message: row.message || '缓存已存在',
              })
              clearFailureFor(row.pickCode, folderLabel, row.name)
            }
          }
          renderRows()

          const queue = folderRows.filter(
            row => row.effectiveMode && (row.status === 'pending' || row.status === 'error'),
          )
          if (queue.length === 0) {
            addInfo(`文件夹 ${folderLabel}：全部跳过或已完成`)
            return
          }

          await runRows({
            settings,
            rows: folderRows,
            client: cacheClient,
            cancel: cancelToken,
            onRowUpdate: scheduleRows,
            onEvent: handleVideoEvent,
          })

          const success = folderRows.filter(row => row.status === 'success').length
          const error = folderRows.filter(row => row.status === 'error').length
          const skipped = folderRows.filter(row => row.status === 'skipped').length
          addInfo(`文件夹 ${folderLabel} 完成：成功 ${success} · 跳过 ${skipped} · 失败 ${error}`)
          renderRows()
          renderLogs()
        }
        catch (error) {
          if (cancelToken.cancelled) {
            return
          }
          // 账号验证失败：中止整批任务，不再继续后面的文件夹
          if (error instanceof AccountVerifyError) {
            throw error
          }
          const message = messageOf(error)
          folderErrors++
          addEvent('error', { folder: folderLabel, message: `文件夹处理失败，已继续下一个：${message}` })
          setTaskStatus(`文件夹 ${folderLabel} 处理失败：${message}`, 'error')
          renderLogs()
        }
      },
    })

    const summary = `处理结束：成功 ${totals.success} · 跳过 ${totals.skip} · 未转码 ${totals.notranscode} · 失败 ${totals.error} · 目录错误 ${folderErrors}`
    setTaskStatus(
      cancelToken.cancelled ? `已取消 · ${summary}` : summary,
      totals.error || folderErrors ? 'error' : 'ok',
    )
    addInfo(cancelToken.cancelled ? `已取消 · ${summary}` : summary)
    activeLogTab = (totals.error || folderErrors) > 0
      ? 'error'
      : totals.notranscode > 0
        ? 'notranscode'
        : totals.success > 0
          ? 'success'
          : totals.skip > 0 ? 'skip' : 'info'
    settings.configured = true
    saveSettings(settings)
  }
  catch (error) {
    if (error instanceof AccountVerifyError) {
      showVerifyNotice(messageOf(error))
      return
    }
    const label = running ? '处理中断' : '启动失败'
    setTaskStatus(`${label}：${messageOf(error)}`, 'error')
    addEvent('error', { message: `${label}：${messageOf(error)}` })
    activeLogTab = 'error'
  }
  finally {
    running = false
    starting = false
    stopProgressTimer()
    setBusyUi(true)
    renderRows()
    renderLogs()
    releaseRunLock()
  }
}

/** 把失败记录里的完整目录换算成相对于目标文件夹的 relativeDir */
function failureRelativeDir(folder: string): string | null {
  const base = settings.folderPath.trim()
  if (!base) {
    return folder === '(根目录)' ? '' : folder
  }
  if (folder === base) {
    return ''
  }
  const prefix = `${base}/`
  return folder.startsWith(prefix) ? folder.slice(prefix.length) : null
}

/** 只重试失败记录中属于目标文件夹的视频 */
async function retryFailures(): Promise<void> {
  if (running || scanning || starting || failureRecords.length === 0) {
    return
  }
  if (!acquireRunLock()) {
    return
  }

  hideVerifyNotice()
  starting = true
  cancelToken = { cancelled: false }
  runStartTime = Date.now()
  foldersSeen = 0
  discoveredVideos = 0
  rows = []
  events = []
  resetTotals()
  videoErrors = 0
  folderErrors = 0
  activeLogTab = 'running'
  startProgressTimer()
  renderRows()
  renderLogs()
  setBusyUi()
  setTaskStatus('正在准备重试失败项…')

  try {
    const normalized = readAndNormalize()
    settings = normalized
    saveSettings(settings)
    writeFolder()

    const cacheClient = new WebDavClient(settings.cacheRoot, settings.username, settings.password)
    await cacheClient.ensureTree(buildTargetFolder(settings), settings.cacheRoot)
    if (cancelToken.cancelled) {
      setTaskStatus('已取消')
      return
    }

    const retryRows: Row[] = []
    const seen = new Set<string>()
    let shortSkipped = 0
    failureRecords.forEach((record, index) => {
      const relativeDir = failureRelativeDir(record.folder)
      if (relativeDir === null) {
        return
      }
      const key = `${record.folder}\u0000${record.pickCode || record.name}`
      if (seen.has(key)) {
        return
      }
      seen.add(key)
      const mode = effectiveModeFor(
        settings.mode,
        { sprite: false, thumb: false },
        false,
        record.duration ?? 0,
        settings.spriteMinDuration,
      )
      if (!mode) {
        shortSkipped++
        return
      }
      retryRows.push({
        id: `retry-${record.pickCode || record.name}-${index}`,
        name: record.name,
        pickCode: record.pickCode,
        duration: record.duration ?? 0,
        status: 'pending',
        message: '',
        progress: 0,
        progressText: '',
        existing: { sprite: false, thumb: false },
        effectiveMode: mode,
        relativeDir,
      })
    })
    if (shortSkipped > 0) {
      addInfo(`重试失败项：${shortSkipped} 个视频时长低于 ${settings.spriteMinDuration}s，跳过雪碧图`)
    }

    if (retryRows.length === 0) {
      setTaskStatus('目标文件夹下没有可重试的失败记录', 'error')
      addInfo('目标文件夹下没有可重试的失败记录')
      return
    }

    rows = retryRows
    discoveredVideos = retryRows.length
    running = true
    starting = false
    setBusyUi()
    addInfo(`重试失败项：${retryRows.length} 个视频 · ${modeLabel(settings.mode)}`)
    renderRows()

    await runRows({
      settings,
      rows: retryRows,
      client: cacheClient,
      cancel: cancelToken,
      onRowUpdate: scheduleRows,
      onEvent: handleVideoEvent,
    })

    const summary = `重试结束：成功 ${totals.success} · 未转码 ${totals.notranscode} · 失败 ${totals.error}`
    setTaskStatus(cancelToken.cancelled ? `已取消 · ${summary}` : summary, totals.error ? 'error' : 'ok')
    addInfo(cancelToken.cancelled ? `已取消 · ${summary}` : summary)
    activeLogTab = totals.error > 0 ? 'error' : totals.notranscode > 0 ? 'notranscode' : 'success'
  }
  catch (error) {
    if (error instanceof AccountVerifyError) {
      showVerifyNotice(messageOf(error))
      return
    }
    const label = running ? '重试中断' : '重试启动失败'
    setTaskStatus(`${label}：${messageOf(error)}`, 'error')
    addEvent('error', { message: `${label}：${messageOf(error)}` })
    activeLogTab = 'error'
  }
  finally {
    running = false
    starting = false
    stopProgressTimer()
    setBusyUi(true)
    renderRows()
    renderLogs()
    releaseRunLock()
  }
}

function cancel(): void {
  if (!running && !starting) {
    return
  }
  cancelToken.cancelled = true
  if (starting) {
    setTaskStatus('已请求取消，准备完成后会停止')
    addInfo('已请求取消，准备完成后会停止')
    return
  }
  setTaskStatus('已请求取消：正在解码的帧会处理完当前分片后停止（网络中的 seek 最长约 15 秒）')
  addInfo('已请求取消：正在解码的帧会处理完当前分片后停止')
  updateStatusText()
}

/* -------------------------------------------------------------------------- */
/* DAV 文件夹选择器                                                            */
/* -------------------------------------------------------------------------- */

function showPicker(): void {
  must<HTMLDivElement>('ts-picker').classList.add('ts-show')
}

function closePicker(): void {
  picker = null
  pickerRequestId++
  must<HTMLDivElement>('ts-picker').classList.remove('ts-show')
}

/** 选择器的起点：当前已填的 115 文件夹，或源 115 根 */
function pickerStartUrl(): string {
  const form = readForm()
  if (form.sourceFolder) {
    try {
      return parseSourceFolder(form.sourceFolder, form).url
    }
    catch {
      // 当前地址无效时从源根开始
    }
  }
  const root = form.sourceWebdavRoot.trim() || DEFAULT_SETTINGS.sourceWebdavRoot
  try {
    return normalizeFolder(root)
  }
  catch {
    return ''
  }
}

async function openSourcePicker(): Promise<void> {
  const url = pickerStartUrl()
  if (!url) {
    setConnectionStatus('源 115 根地址无效，无法浏览 DAV', 'error')
    return
  }
  picker = { url, entries: [], loading: true, error: '' }
  showPicker()
  renderPicker()
  await loadWebdavPicker(url)
}

async function loadWebdavPicker(url: string): Promise<void> {
  if (!picker) {
    return
  }
  const requestId = ++pickerRequestId
  picker.url = url
  picker.loading = true
  picker.error = ''
  renderPicker()

  try {
    const form = readForm()
    const client = new WebDavClient(url, form.username, form.password)
    const entries = await client.list(url)
    if (!picker || requestId !== pickerRequestId) {
      return
    }
    picker.entries = entries.filter(entry => entry.isDir)
    picker.loading = false
    renderPicker()
  }
  catch (error) {
    if (picker && requestId === pickerRequestId) {
      picker.loading = false
      picker.error = messageOf(error)
      renderPicker()
    }
  }
}

function parentWebdavUrl(url: string): string {
  const parsed = new URL(url)
  const parts = parsed.pathname.split('/').filter(Boolean)
  parts.pop()
  parsed.pathname = `/${parts.join('/')}${parts.length ? '/' : ''}`
  parsed.search = ''
  parsed.hash = ''
  return parsed.href
}

function selectSourceFolder(): void {
  if (!picker || picker.loading) {
    return
  }
  const form = readForm()
  let target: SourceTarget
  try {
    // 只允许选择 115 挂载下的文件夹，否则缓存目标无法镜像
    target = parseSourceFolder(picker.url, form)
  }
  catch (error) {
    picker.error = messageOf(error)
    renderPicker()
    return
  }
  // 显示解码后的地址，避免中文目录名变成 %E8...
  must<HTMLInputElement>('ts-source-folder').value = displayFolderUrl(picker.url)
  try {
    settings = normalizeSettings(readForm())
  }
  catch (error) {
    picker.error = messageOf(error)
    renderPicker()
    return
  }
  saveSettings(settings)
  closePicker()
  writeForm()
  setConnectionStatus(`已选择 115 文件夹：${target.path || '(根目录)'}`, 'ok')
}

function renderPicker(): void {
  const title = $id('ts-picker-title')
  const content = $id<HTMLElement>('ts-picker-content')
  if (!title || !content || !picker) {
    return
  }

  title.textContent = '从 DAV 选择要处理的 115 文件夹'
  content.innerHTML = `
    <div class="ts-picker-url">${escapeHtml(displayFolderUrl(picker.url))}</div>
    <div class="ts-hint" style="margin-bottom:8px">选中的文件夹会写入上面的地址；只有 115 挂载下的文件夹可以作为处理目录。</div>
    ${picker.error ? `<div class="ts-picker-error">${escapeHtml(picker.error)}</div>` : ''}
    ${picker.loading
      ? '<div class="ts-empty">加载中…</div>'
      : picker.entries.length === 0
        ? '<div class="ts-empty">没有子文件夹</div>'
        : `<div class="ts-dir-list">${picker.entries.map(entry => `
            <div class="ts-dir-item">
              <span class="ts-dir-name" title="${escapeHtml(entry.name)}">${escapeHtml(entry.name)}</span>
              <button type="button" data-ts-action="webdav-enter" data-url="${escapeHtml(entry.url)}">进入</button>
            </div>
          `).join('')}</div>`}
    <div class="ts-picker-actions">
      <button class="ts-btn" type="button" data-ts-action="webdav-up">上级</button>
      <button class="ts-btn ts-primary" type="button" data-ts-action="webdav-select">选择当前文件夹</button>
      <button class="ts-btn" type="button" data-ts-action="close">取消</button>
    </div>
  `
}

/* -------------------------------------------------------------------------- */
/* 测试连接 / 导出失败                                                         */
/* -------------------------------------------------------------------------- */

async function testConnection(): Promise<void> {
  setConnectionStatus('正在连接…')
  try {
    const normalized = readAndNormalize()
    const messages: string[] = []
    let failed = false

    try {
      const client = new WebDavClient(normalized.cacheRoot, normalized.username, normalized.password)
      const entries = await client.test()
      messages.push(`缓存根：连接成功（${entries.length} 项）`)
    }
    catch (error) {
      failed = true
      messages.push(`缓存根：失败（${messageOf(error)}）`)
    }

    if (normalized.sourceFolder) {
      const target = parseSourceFolder(normalized.sourceFolder, normalized)

      try {
        const source = new WebDavClient(target.url, normalized.username, normalized.password)
        const entries = await source.list(target.url, { missingAsEmpty: false })
        messages.push(`115 文件夹：连接成功（${entries.length} 项）`)
      }
      catch (error) {
        failed = true
        messages.push(`115 文件夹：失败（${messageOf(error)}）`)
      }

      try {
        const probe = await probeRootApi()
        const sample = probe.folderCount === 0 && probe.sample.length > 0
          ? `；示例：${probe.sample.map(item => `${item.name}[cid=${item.cid || '空'},cate_id=${item.cateId || '空'},fid=${item.fid || '空'},file_type=${String(item.fileType ?? '空')}${item.hasPickCode ? ',有pc' : ''}]`).join('、')}`
          : ''
        messages.push(
          `115 API 根目录：${probe.entryCount} 个条目（data=${probe.dataCount}，folders=${probe.foldersCount}；识别为文件夹 ${probe.folderCount}）${sample}`
          + (probe.entryCount === 0 ? '（请确认 115 登录账号与 WebDAV 的 115 挂载是同一份数据）' : ''),
        )
        if (probe.folderCount === 0 && probe.rawSample) {
          addInfo(`115 API 首条原始数据：${probe.rawSample}`)
        }
      }
      catch (error) {
        failed = true
        messages.push(`115 API 根目录读取失败：${messageOf(error)}`)
      }

      try {
        const resolution = await resolveTargetCid(target.path)
        if (resolution.cid === null) {
          failed = true
          messages.push(cidFailureMessage(target, resolution))
        }
        else if (resolution.viaSuffixSearch) {
          messages.push(`115 API：已按路径后缀定位到「${resolution.apiPath}」（cid=${resolution.cid}）`)
        }
        else {
          messages.push(`115 API：已定位（cid=${resolution.cid}）`)
        }
      }
      catch (error) {
        failed = true
        messages.push(`115 API：失败（${messageOf(error)}）`)
      }
    }
    else {
      messages.push('115 文件夹：未填写')
      failed = true
    }

    if (!failed) {
      settings.configured = true
      saveSettings(settings)
    }
    setConnectionStatus(messages.join('；'), failed ? 'error' : 'ok')
  }
  catch (error) {
    setConnectionStatus(`连接失败：${messageOf(error)}`, 'error')
  }
}

function exportFailures(): void {
  const blob = new Blob([JSON.stringify(failureRecords, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `thumb-failures-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  document.body.appendChild(link)
  link.click()
  link.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

function clearFailures(): void {
  if (!window.confirm('清空失败记录？')) {
    return
  }
  clearFailuresStore()
  failureRecords = []
  renderFailures()
}

/* -------------------------------------------------------------------------- */
/* 打开 / 关闭                                                                 */
/* -------------------------------------------------------------------------- */

function openPanel(): void {
  panelOpen = true
  must<HTMLDivElement>('ts-overlay').classList.add('ts-show')
  updateTarget()
  renderRows()
  renderFailures()
  renderLogs()
}

function closePanel(): void {
  panelOpen = false
  must<HTMLDivElement>('ts-overlay').classList.remove('ts-show')
  closePicker()
  // 运行中不重读表单，避免中途替换 settings 对象影响正在进行的任务
  if (running || starting || scanning) {
    return
  }
  try {
    settings = normalizeSettings(readForm())
  }
  catch {
    settings = readForm()
  }
  saveSettings(settings)
}

/* -------------------------------------------------------------------------- */
/* 事件                                                                        */
/* -------------------------------------------------------------------------- */

function bindEvents(): void {
  $id('ts-launcher')?.addEventListener('click', openPanel)
  $id('ts-close')?.addEventListener('click', closePanel)
  $id('ts-scan')?.addEventListener('click', () => {
    prepareAlertAudio()
    void scan()
  })
  $id('ts-start')?.addEventListener('click', () => {
    prepareAlertAudio()
    void start()
  })
  $id('ts-cancel')?.addEventListener('click', cancel)
  $id('ts-retry-failures')?.addEventListener('click', () => {
    prepareAlertAudio()
    void retryFailures()
  })
  $id('ts-test')?.addEventListener('click', () => { void testConnection() })
  $id('ts-browse-folder')?.addEventListener('click', () => { void openSourcePicker() })
  $id('ts-picker-close')?.addEventListener('click', closePicker)
  $id('ts-log-tabs')?.addEventListener('click', (event) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-log-tab]')
    const tab = target?.dataset.logTab as LogTab | undefined
    if (!tab) {
      return
    }
    activeLogTab = tab
    renderLogs()
  })
  $id('ts-export-failures')?.addEventListener('click', exportFailures)
  $id('ts-clear-failures')?.addEventListener('click', clearFailures)
  $id('ts-verify-open')?.addEventListener('click', () => {
    window.open('https://115.com/', '_blank', 'noopener')
  })
  $id('ts-verify-dismiss')?.addEventListener('click', dismissVerifyNotice)

  must<HTMLDivElement>('ts-overlay').addEventListener('click', (event) => {
    if (event.target === $id('ts-overlay')) {
      closePanel()
    }
  })

  // 刷新/关闭页面时尽量释放运行锁，避免下次打开误提示“另一个标签页正在处理”
  window.addEventListener('beforeunload', releaseRunLock)

  // Esc：先关文件夹选择器，再关面板
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') {
      return
    }
    if (picker) {
      closePicker()
      return
    }
    if (panelOpen) {
      closePanel()
    }
  })

  $id('ts-cache-root')?.addEventListener('input', () => {
    setConnectionStatus('')
    updateTarget()
  })
  $id('ts-source-folder')?.addEventListener('input', () => {
    setConnectionStatus('')
    updateTarget()
  })
  $id('ts-user')?.addEventListener('input', () => setConnectionStatus(''))
  $id('ts-pass')?.addEventListener('input', () => setConnectionStatus(''))
  $id('ts-grid')?.addEventListener('input', () => {
    const error = $id('ts-param-error')
    if (!error) {
      return
    }
    try {
      parseGrid(must<HTMLInputElement>('ts-grid').value)
      error.textContent = ''
    }
    catch (gridError) {
      error.textContent = messageOf(gridError)
    }
  })

  must<HTMLElement>('ts-picker-content').addEventListener('click', (event) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-ts-action]')
    if (!target || !picker) {
      return
    }
    const action = target.dataset.tsAction
    if (action === 'close') {
      closePicker()
      return
    }
    if (action === 'webdav-enter') {
      const url = target.dataset.url
      if (url) {
        void loadWebdavPicker(url)
      }
      return
    }
    if (action === 'webdav-up') {
      void loadWebdavPicker(parentWebdavUrl(picker.url))
      return
    }
    if (action === 'webdav-select') {
      selectSourceFolder()
    }
  })
}

/* -------------------------------------------------------------------------- */
/* 初始化                                                                      */
/* -------------------------------------------------------------------------- */

export function initUi(): void {
  if (document.getElementById('ts-root')) {
    return
  }
  GM_addStyle(STYLE)
  const host = document.createElement('div')
  host.id = 'ts-root'
  host.innerHTML = PANEL_HTML
  document.body.appendChild(host)

  bindEvents()
  writeForm()
  renderRows()
  renderFailures()
  renderLogs()
  setBusyUi()

  GM_registerMenuCommand('打开缩略图/雪碧图生成器', openPanel)

  if (!settings.configured) {
    window.setTimeout(() => {
      if (!panelOpen) {
        openPanel()
      }
    }, 600)
  }

  addInfo('脚本已加载')
  if (settings.configured) {
    addInfo(`已加载配置：${settings.cacheRoot}`)
  }
  activeLogTab = 'info'
  renderLogs()
}
