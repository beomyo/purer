import type { Dir115Item } from './api115'
import type { ScraperSettings } from './settings'
import type { VideoItem } from './types'
import type { DavEntry, WebDavClient } from './webdav'
import { listDir, normalizeFolderName } from './api115'
import { joinFolder, normalizeFolder } from './webdav'

/** 与 purer-scraper 一致的视频扩展名 */
const VIDEO_EXT_RE = /\.(?:mp4|m4v|mkv|webm|mov|avi|wmv|flv|ts|m2ts|mpg|mpeg|3gp|3g2|ogv|m3u8)$/i

/** 防止异常目录结构导致无限递归 */
const MAX_DEPTH = 30

/** 子文件夹 */
export interface ChildFolder {
  cid: string
  relativeDir: string
  sourceUrl: string | null
}

/** 一个文件夹的扫描结果 */
export interface FolderNode {
  cid: string
  relativeDir: string
  /** 只属于当前文件夹的视频（不含子文件夹） */
  videos: VideoItem[]
  /** 待递归的子文件夹 */
  children: ChildFolder[]
}

/** 递归扫描参数 */
export interface WalkOptions {
  settings: ScraperSettings
  /** 源 WebDAV 客户端（http://10.2.31.10/dav/115），为空时只用 115 API 递归 */
  sourceClient: WebDavClient | null
  /** 起始 115 文件夹 cid（由源文件夹地址按路径解析） */
  startCid: string
  /** 取消令牌 */
  cancel?: { cancelled: boolean }
  onLog?: (message: string, level?: 'info' | 'error') => void
  onProgress?: (folders: number, videos: number) => void
  /** 每扫描完一个文件夹调用一次；返回后才继续进入子文件夹 */
  onFolder: (folder: FolderNode) => void | Promise<void>
}

/** 错误信息 */
function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** 名称归一化（NFC + 空白折叠，兼容 NBSP/全角空格），与 115 API 匹配规则一致 */
function normalizeName(name: string): string {
  return normalizeFolderName(name)
}

/** 更宽松的键：忽略全部空白并转小写 */
function compactName(name: string): string {
  return normalizeName(name).replace(/\s+/g, '').toLowerCase()
}

/** 拼接相对目录 */
function joinRelative(parent: string, name: string): string {
  return parent ? `${parent}/${name}` : name
}

/** 按名称建立索引 */
function indexByName(items: Dir115Item[]): Map<string, Dir115Item[]> {
  const result = new Map<string, Dir115Item[]>()
  for (const item of items) {
    const key = normalizeName(item.name)
    const list = result.get(key)
    if (list) {
      list.push(item)
    }
    else {
      result.set(key, [item])
    }
  }
  return result
}

/** 查找同名条目 */
function candidatesFor(
  index: Map<string, Dir115Item[]>,
  items: Dir115Item[],
  name: string,
): Dir115Item[] {
  const key = normalizeName(name)
  const exact = index.get(key)
  if (exact && exact.length > 0) {
    return exact
  }
  const lower = key.toLowerCase()
  const exactLower = items.filter(item => normalizeName(item.name).toLowerCase() === lower)
  if (exactLower.length > 0) {
    return exactLower
  }
  const compact = compactName(name)
  return items.filter(item => compactName(item.name) === compact)
}

/** 在 115 条目中找文件夹 */
function findFolderItem(
  index: Map<string, Dir115Item[]>,
  items: Dir115Item[],
  name: string,
): Dir115Item | undefined {
  const candidates = candidatesFor(index, items, name)
  return candidates.find(item => item.isFolder && item.folderId)
    ?? candidates.find(item => item.folderId && !item.pickCode)
}

/** 在 115 条目中找视频 */
function findVideoItem(
  index: Map<string, Dir115Item[]>,
  items: Dir115Item[],
  name: string,
): Dir115Item | undefined {
  const candidates = candidatesFor(index, items, name)
  return candidates.find(item => item.pickCode && !item.isFolder)
    ?? candidates.find(item => item.pickCode)
}

/** 读取文件夹的 115 条目与源 WebDAV 子项（并行） */
async function readFolder(
  cid: string,
  sourceClient: WebDavClient | null,
  sourceUrl: string | null,
  relativeDir: string,
  onLog?: (message: string, level?: 'info' | 'error') => void,
): Promise<{ items115: Dir115Item[], itemsOk: boolean, entries: DavEntry[] | null }> {
  const [itemsResult, entriesResult] = await Promise.allSettled([
    listDir(cid),
    sourceClient && sourceUrl
      ? sourceClient.list(sourceUrl, { missingAsEmpty: false })
      : Promise.resolve(null),
  ])

  const itemsOk = itemsResult.status === 'fulfilled'
  let items115: Dir115Item[] = []
  if (itemsOk) {
    items115 = itemsResult.value.items
  }
  else {
    onLog?.(`读取 115 目录失败（${relativeDir || '根目录'}）：${messageOf(itemsResult.reason)}`, 'error')
  }

  let entries: DavEntry[] | null = null
  if (entriesResult.status === 'fulfilled') {
    entries = entriesResult.value
  }
  else {
    onLog?.(
      `读取源 WebDAV 目录失败（${relativeDir || '根目录'}）：${messageOf(entriesResult.reason)}，改用 115 目录结构`,
    )
  }

  return { items115, itemsOk, entries }
}

/**
 * 逐文件夹递归扫描
 * @description 每扫描完一个文件夹调用 onFolder；onFolder 返回后才进入子文件夹。
 * 这样调用方可以一次只处理一个文件夹，避免一次性收集整棵树造成卡顿。
 */
export async function walkFolders(options: WalkOptions): Promise<void> {
  const { settings, sourceClient, cancel, onLog, onProgress, onFolder } = options
  const visited = new Set<string>()
  let folders = 0
  let foundVideos = 0

  let startSourceUrl: string | null = null
  if (sourceClient) {
    try {
      // 以用户填写的「要处理的 115 文件夹」地址为准；旧配置没有该地址时按源根 + 路径拼
      startSourceUrl = settings.sourceFolder.trim()
        ? normalizeFolder(settings.sourceFolder.trim())
        : joinFolder(
            settings.sourceWebdavRoot.trim(),
            ...settings.folderPath.split('/').filter(Boolean),
          )
    }
    catch (error) {
      onLog?.(`源 WebDAV 地址无效：${messageOf(error)}，将只使用 115 API 递归`)
    }
  }

  const walk = async (
    cid: string,
    relativeDir: string,
    sourceUrl: string | null,
    depth: number,
  ): Promise<void> => {
    if (cancel?.cancelled) {
      return
    }
    if (depth > MAX_DEPTH) {
      onLog?.(`目录层数超过 ${MAX_DEPTH}，跳过：${relativeDir || '根目录'}`, 'error')
      return
    }
    if (visited.has(cid)) {
      return
    }
    visited.add(cid)

    const { items115, itemsOk, entries } = await readFolder(
      cid,
      sourceClient,
      sourceUrl,
      relativeDir,
      onLog,
    )

    // 115 列表失败时无法拿到 pickcode，继续遍历只会对每个条目刷一条“找不到”，直接跳过
    if (!itemsOk) {
      // 失败原因已由上一步的 error 日志给出，这里只补一条跳过提示，不重复计错
      onLog?.(`已跳过该文件夹：${relativeDir || '根目录'}`)
      return
    }

    const videos: VideoItem[] = []
    const children: ChildFolder[] = []

    // 源 WebDAV 读到了空目录、但 115 里明明有内容：多半是源根地址填错/读到了别的空目录，
    // 这时回退到 115 目录结构，而不是静默地什么都不处理。
    let effectiveEntries = entries
    if (effectiveEntries !== null && effectiveEntries.length === 0 && items115.length > 0) {
      onLog?.(
        `源 WebDAV 目录为空但 115 有 ${items115.length} 项，改用 115 目录结构：${relativeDir || '根目录'}`,
      )
      effectiveEntries = null
    }

    // 源 WebDAV 目录读取成功且非空：以它的条目为准（名称能与 115 对上）
    if (effectiveEntries !== null) {
      const index = indexByName(items115)
      let candidates = 0
      let matched = 0
      const missing: string[] = []

      for (const entry of effectiveEntries) {
        if (cancel?.cancelled) {
          return
        }
        if (entry.isDir) {
          if (!settings.recursive) {
            continue
          }
          candidates++
          const folder = findFolderItem(index, items115, entry.name)
          if (!folder?.folderId) {
            missing.push(`子文件夹 ${joinRelative(relativeDir, entry.name)}`)
            continue
          }
          matched++
          children.push({
            cid: folder.folderId,
            relativeDir: joinRelative(relativeDir, entry.name),
            sourceUrl: entry.url,
          })
          continue
        }

        if (!VIDEO_EXT_RE.test(entry.name)) {
          continue
        }
        candidates++
        const video = findVideoItem(index, items115, entry.name)
        if (!video?.pickCode) {
          missing.push(`视频 ${joinRelative(relativeDir, entry.name)}`)
          continue
        }
        matched++
        videos.push({
          name: entry.name,
          pickCode: video.pickCode,
          duration: video.duration,
          relativeDir,
        })
      }

      if (candidates > 0 && matched === 0) {
        // 一个都对不上：只报一条，避免几百条“找不到”把日志刷满
        onLog?.(
          `源 WebDAV 与 115 目录完全不匹配（${relativeDir || '根目录'}）：`
          + `${missing.slice(0, 5).join('、')}${missing.length > 5 ? ' 等' : ''}。`
          + `请确认「要处理的 115 文件夹」填写的是 115 账号内的同一目录（${settings.sourceFolder || settings.folderPath || '根目录'}）`,
          'error',
        )
      }
      else {
        for (const item of missing) {
          onLog?.(`115 中找不到：${item}`, 'error')
        }
      }
    }
    else {
      // 源 WebDAV 不可用（或为空）：只使用 115 目录结构
      for (const item of items115) {
        if (cancel?.cancelled) {
          return
        }
        if (item.isFolder) {
          if (!settings.recursive) {
            continue
          }
          if (!item.folderId) {
            onLog?.(`115 子文件夹缺少 id：${joinRelative(relativeDir, item.name)}`, 'error')
            continue
          }
          children.push({
            cid: item.folderId,
            relativeDir: joinRelative(relativeDir, item.name),
            sourceUrl: null,
          })
          continue
        }
        if (item.pickCode && VIDEO_EXT_RE.test(item.name)) {
          videos.push({
            name: item.name,
            pickCode: item.pickCode,
            duration: item.duration,
            relativeDir,
          })
        }
      }
    }

    folders++
    foundVideos += videos.length
    onProgress?.(folders, foundVideos)

    await onFolder({
      cid,
      relativeDir,
      videos,
      children,
    })

    if (cancel?.cancelled) {
      return
    }

    for (const child of children) {
      await walk(child.cid, child.relativeDir, child.sourceUrl, depth + 1)
      if (cancel?.cancelled) {
        return
      }
    }
  }

  await walk(options.startCid || '0', '', startSourceUrl, 0)
}

/** 递归收集全部视频（保留给测试/其他调用方） */
export async function collectVideos(
  options: Omit<WalkOptions, 'onFolder'>,
): Promise<VideoItem[]> {
  const videos: VideoItem[] = []
  await walkFolders({
    ...options,
    onFolder: (folder) => {
      videos.push(...folder.videos)
    },
  })
  return videos
}
