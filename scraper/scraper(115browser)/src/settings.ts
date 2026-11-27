import { GM_getValue, GM_setValue } from '$'
import { parseSourceFolder } from './sourceFolder'
import type { Mode } from './types'

/** 设置结构版本，用于一次性迁移旧默认值 */
const SETTINGS_VERSION = 2

/** 浏览器生成器设置 */
export interface ScraperSettings {
  /** 设置结构版本 */
  settingsVersion: number
  /** 是否已经完成过一次配置 */
  configured: boolean
  /** 缓存根地址，例如 http://10.2.31.10/dav/UC/cache */
  cacheRoot: string
  /** 115 在源 WebDAV 中的根地址，用于从 sourceFolder 推导路径（默认 http://10.2.31.10/dav/115） */
  sourceWebdavRoot: string
  username: string
  password: string
  /** 115 在 WebDAV 中的路径前缀，例如 115 */
  sourcePrefix: string
  /** 要处理的 115 文件夹（WebDAV 地址，例如 http://10.2.31.10/dav/115/要处理的文件夹） */
  sourceFolder: string
  /** 由 sourceFolder 推导出的 115 内路径（不单独编辑） */
  folderPath: string
  mode: Mode
  grid: string
  cellWidth: number
  /** 雪碧图大小上限 KB */
  maxKB: number
  /** 雪碧图最短时长（秒）；低于则只生成缩略图，0 表示不限 */
  spriteMinDuration: number
  /** 普通缩略图取帧位置百分比 */
  percent: number
  videoConcurrency: number
  frameConcurrency: number
  skipExisting: boolean
  /** 是否递归处理子文件夹 */
  recursive: boolean
}

/** 默认设置 */
export const DEFAULT_SETTINGS: ScraperSettings = {
  settingsVersion: SETTINGS_VERSION,
  configured: false,
  cacheRoot: 'http://10.2.31.10/dav/UC/cache',
  sourceWebdavRoot: 'http://10.2.31.10/dav/115',
  username: 'admin',
  password: '',
  sourcePrefix: '115',
  sourceFolder: '',
  folderPath: '',
  mode: 'both',
  grid: '5x5',
  cellWidth: 320,
  maxKB: 1024,
  spriteMinDuration: 300,
  percent: 80,
  videoConcurrency: 3,
  frameConcurrency: 3,
  skipExisting: true,
  recursive: true,
}

const SETTINGS_KEY = 'THUMB_SCRAPER_SETTINGS'

/** 读取设置 */
export function loadSettings(): ScraperSettings {
  const saved = GM_getValue<Partial<ScraperSettings>>(SETTINGS_KEY, {}) ?? {}
  const merged = { ...DEFAULT_SETTINGS, ...saved }
  // 旧版本并发默认是 2×2，且不允许超过 4；升级时把未改动过的旧默认值换成 3×3
  const savedVersion = Number(saved.settingsVersion) || 0
  if (savedVersion < 2 && merged.videoConcurrency === 2 && merged.frameConcurrency === 2) {
    merged.videoConcurrency = 3
    merged.frameConcurrency = 3
  }
  merged.settingsVersion = SETTINGS_VERSION
  // 旧版本没有保存 sourceFolder；folderPath 始终由地址重新推导，避免读到过期值
  merged.sourceFolder = String(merged.sourceFolder ?? '').trim()
  if (merged.sourceFolder) {
    try {
      merged.folderPath = parseSourceFolder(merged.sourceFolder, merged).path
    }
    catch {
      merged.folderPath = ''
    }
  }
  else {
    merged.folderPath = ''
    // 新版必须填写「要处理的 115 文件夹」地址；旧配置打开时直接弹配置面板
    merged.configured = false
  }
  merged.videoConcurrency = Math.min(4, Math.max(1, Math.round(Number(merged.videoConcurrency) || 3)))
  merged.frameConcurrency = Math.min(4, Math.max(1, Math.round(Number(merged.frameConcurrency) || 3)))
  // 旧版本保存的字段名是 spriteMaxDuration（同为「雪碧图时长阈值」），迁移到新字段
  const legacy = (saved as { spriteMaxDuration?: unknown }).spriteMaxDuration
  if ((saved as { spriteMinDuration?: unknown }).spriteMinDuration === undefined && legacy !== undefined) {
    merged.spriteMinDuration = Number(legacy)
  }
  // 雪碧图最短时长：0 表示不限，必须保留 0，不能像并发那样用 || 兜底
  const rawSpriteMin = Number(merged.spriteMinDuration)
  merged.spriteMinDuration = Number.isFinite(rawSpriteMin)
    ? Math.min(86400, Math.max(0, Math.round(rawSpriteMin)))
    : DEFAULT_SETTINGS.spriteMinDuration
  return merged
}

/** 保存设置 */
export function saveSettings(settings: ScraperSettings): void {
  GM_setValue(SETTINGS_KEY, { ...settings })
}
