import type { Grid } from './sprite'

/** 时长前缀，例如 00.10.00_ */
const DURATION_PREFIX_RE = /^\d{2}\.\d{2}\.\d{2}_/

/** 缓存中已存在的产物 */
export interface ExistingFlags {
  sprite: boolean
  thumb: boolean
}

/**
 * 生成时长前缀，与 purer-scraper / 手机 App 一致
 */
export function durationPrefix(seconds: number): string {
  const total = Math.floor(seconds + 0.5)
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const secs = total % 60
  return `${String(hours).padStart(2, '0')}.${String(minutes).padStart(2, '0')}.${String(secs).padStart(2, '0')}_`
}

/**
 * 缓存文件名的基础部分（带时长前缀，除非视频名本身已经带了）
 */
export function cacheBaseName(videoName: string, durationSeconds?: number | null): string {
  if (DURATION_PREFIX_RE.test(videoName)) {
    return videoName
  }
  if (durationSeconds == null || durationSeconds <= 0) {
    return videoName
  }
  return `${durationPrefix(durationSeconds)}${videoName}`
}

/** 普通缩略图文件名 */
export function thumbFileName(videoName: string, durationSeconds?: number | null): string {
  return `${cacheBaseName(videoName, durationSeconds)}.jpg`
}

/** 雪碧图文件名 */
export function spriteFileName(
  videoName: string,
  durationSeconds: number | null | undefined,
  grid: Grid,
): string {
  return `${cacheBaseName(videoName, durationSeconds)}~${grid.cols}x${grid.rows}.jpg`
}

/** 拆出雪碧图的 ~列x行 后缀 */
export function splitSpriteSuffix(base: string): { plain: string, grid?: Grid } {
  const match = /~(\d{1,2})x(\d{1,2})$/.exec(base)
  if (!match) {
    return { plain: base }
  }
  return {
    plain: base.slice(0, match.index),
    grid: {
      cols: Number(match[1]),
      rows: Number(match[2]),
    },
  }
}

/**
 * 判断缓存文件名是否对应某个视频
 */
export function cacheNameMatchesVideo(cacheName: string, videoName: string): boolean {
  if (!cacheName.toLowerCase().endsWith('.jpg')) {
    return false
  }
  const base = cacheName.slice(0, -4)
  const { plain } = splitSpriteSuffix(base)
  const target = videoName.toLowerCase()

  if (DURATION_PREFIX_RE.test(videoName)) {
    return plain.toLowerCase() === target
  }

  const candidates = new Set([
    plain.toLowerCase(),
    plain.replace(DURATION_PREFIX_RE, '').toLowerCase(),
  ])
  return candidates.has(target)
}

/**
 * 为一次文件夹扫描建立缓存索引，避免每个视频都重新遍历整份缓存文件列表
 * @param cacheFiles 目录中的缓存文件名
 * @param grid 目标格子（只有同样格子的雪碧图才算已存在）
 */
export function createCacheLookup(
  cacheFiles: string[],
  grid: Grid,
): (videoName: string) => ExistingFlags {
  const thumbs = new Set<string>()
  const sprites = new Set<string>()

  for (const cacheName of cacheFiles) {
    if (!cacheName.toLowerCase().endsWith('.jpg')) {
      continue
    }
    const base = cacheName.slice(0, -4)
    const { plain, grid: fileGrid } = splitSpriteSuffix(base)
    if (fileGrid && (fileGrid.cols !== grid.cols || fileGrid.rows !== grid.rows)) {
      continue
    }
    // 同时登记「带时长前缀」和「去掉时长前缀」两种写法，兼容不同来源的缓存
    const keys = new Set([
      plain.toLowerCase(),
      plain.replace(DURATION_PREFIX_RE, '').toLowerCase(),
    ])
    for (const key of keys) {
      if (fileGrid) {
        sprites.add(key)
      }
      else {
        thumbs.add(key)
      }
    }
  }

  return (videoName: string): ExistingFlags => {
    const target = videoName.toLowerCase()
    return {
      sprite: sprites.has(target),
      thumb: thumbs.has(target),
    }
  }
}

/**
 * 在缓存文件名列表里查找某个视频已有的产物
 */
export function findExisting(
  cacheFiles: string[],
  videoName: string,
  grid: Grid,
): ExistingFlags {
  return createCacheLookup(cacheFiles, grid)(videoName)
}
