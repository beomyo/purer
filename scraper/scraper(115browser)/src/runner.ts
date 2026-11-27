import type { Grid } from './sprite'
import type { ScraperSettings } from './settings'
import type { Mode, Row, VideoItem } from './types'
import { AccountVerifyError, getMasterText, masterUrl, NoHlsError, PlaylistRequestError } from './api115'
import { cacheBaseName, createCacheLookup } from './cacheName'
import { HlsError } from './hls'
import { getImageResize } from './image'
import { M3U8ClipperNew } from './clipper/m3u8Clipper'
import { DecoderFlowError } from './clipper/DecoderFlowError'
import { promiseDelay } from './promise'
import { composeSprite, composeThumbnail, parseGrid, spritePositions } from './sprite'
import { joinFile, joinFolder, WebDavClient, WebDavError } from './webdav'

/** 取消令牌 */
export interface CancelToken {
  cancelled: boolean
}

/** 用户取消 */
export class CancelledError extends Error {
  constructor(message = '已取消') {
    super(message)
    this.name = 'CancelledError'
  }
}

/** 视频时长低于雪碧图阈值，按规则只生成缩略图 */
export class SpriteShortSkipError extends Error {
  constructor(
    readonly duration: number,
    readonly threshold: number = SPRITE_DURATION_THRESHOLD_SECONDS,
  ) {
    super(`时长 ${Math.round(duration)}s 低于 ${threshold}s，跳过雪碧图`)
    this.name = 'SpriteShortSkipError'
  }
}

/** 浏览器解码失败 */
export class DecodeError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message)
    this.name = 'DecodeError'
  }
}

/** 雪碧图最短时长（秒）：低于这个时长的视频只生成缩略图，不生成雪碧图 */
export const SPRITE_DURATION_THRESHOLD_SECONDS = 300

/** 是否因为时长太短而只生成缩略图（threshold 为 0 表示不限；时长未知时按需要处理） */
export function isShortForSprite(
  durationSeconds: number,
  threshold: number = SPRITE_DURATION_THRESHOLD_SECONDS,
): boolean {
  return Number.isFinite(durationSeconds)
    && durationSeconds > 0
    && threshold > 0
    && durationSeconds < threshold
}

/** 单帧取不到时，依次尝试的时间偏移（秒）：先原时间点，再向后/向前换附近帧 */
const FRAME_RETRY_OFFSETS = [0, 0.5, -0.5]

/**
 * 计算一帧失败后的候选时间点
 * @description 去掉重复点，并限制在 [0, duration) 内，避免换帧越界
 */
export function frameRetryTimes(
  time: number,
  duration: number,
  offsets: readonly number[] = FRAME_RETRY_OFFSETS,
): number[] {
  const maxTime = Math.max(0, duration - 0.05)
  const seen = new Set<number>()
  const times: number[] = []
  for (const offset of offsets) {
    const candidate = Math.min(maxTime, Math.max(0, time + offset))
    const key = Math.round(candidate * 1000)
    if (seen.has(key)) {
      continue
    }
    seen.add(key)
    times.push(candidate)
  }
  return times
}

/** 合并实际需要的输出模式 */
function combineMode(wantSprite: boolean, wantThumb: boolean): Mode | null {
  if (wantSprite && wantThumb) {
    return 'both'
  }
  if (wantSprite) {
    return 'sprite'
  }
  if (wantThumb) {
    return 'thumb'
  }
  return null
}

/**
 * 生成实际需要的模式
 * @param durationSeconds 115 给出的时长；0/未知时先按允许处理，解码后再按真实时长判断
 */
export function effectiveModeFor(
  requested: Mode,
  existing: { sprite: boolean, thumb: boolean },
  skipExisting: boolean,
  durationSeconds = 0,
  spriteThreshold = SPRITE_DURATION_THRESHOLD_SECONDS,
): Mode | null {
  // 低于阈值的视频只生成缩略图，雪碧图只给时长足够的视频
  const wantSprite = requested !== 'thumb' && !isShortForSprite(durationSeconds, spriteThreshold)
  const wantThumb = requested !== 'sprite'

  if (!skipExisting) {
    return combineMode(wantSprite, wantThumb)
  }
  const needSprite = wantSprite && !existing.sprite
  const needThumb = wantThumb && !existing.thumb
  return combineMode(needSprite, needThumb)
}

/** 目标缓存目录 */
export function buildTargetFolder(settings: ScraperSettings, relativeDir = ''): string {
  const parts: string[] = []
  const prefix = settings.sourcePrefix.trim().replace(/^\/+|\/+$/g, '')
  if (prefix) {
    parts.push(prefix)
  }
  const folder = settings.folderPath.trim().replace(/^\/+|\/+$/g, '')
  if (folder) {
    parts.push(folder)
  }
  const relative = relativeDir.trim().replace(/^\/+|\/+$/g, '')
  if (relative) {
    parts.push(relative)
  }
  return joinFolder(settings.cacheRoot, ...parts)
}

/** 列出目标目录已有的 jpg */
export async function listExisting(client: WebDavClient, folderUrl: string): Promise<string[]> {
  try {
    const entries = await client.list(folderUrl)
    return entries
      .filter(entry => !entry.isDir && entry.name.toLowerCase().endsWith('.jpg'))
      .map(entry => entry.name)
  }
  catch (error) {
    if (error instanceof WebDavError && error.status === 404) {
      return []
    }
    throw error
  }
}

/** 根据视频和缓存文件构建任务行 */
export function buildRows(
  videos: VideoItem[],
  cacheFilesByDir: Map<string, string[]>,
  settings: ScraperSettings,
): Row[] {
  const grid = parseGrid(settings.grid)
  // 每个目录只建一次索引，避免「视频数 × 缓存文件数」的重复遍历
  const lookups = new Map<string, (name: string) => { sprite: boolean, thumb: boolean }>()
  const lookupFor = (dir: string) => {
    let lookup = lookups.get(dir)
    if (!lookup) {
      lookup = createCacheLookup(cacheFilesByDir.get(dir) ?? [], grid)
      lookups.set(dir, lookup)
    }
    return lookup
  }
  return videos.map((video, index) => {
    const existing = lookupFor(video.relativeDir)(video.name)
    const threshold = settings.spriteMinDuration
    const mode = effectiveModeFor(
      settings.mode,
      existing,
      settings.skipExisting,
      video.duration,
      threshold,
    )
    const shortVideo = isShortForSprite(video.duration, threshold) && settings.mode !== 'thumb'
    const message = mode
      ? ''
      : shortVideo && settings.mode === 'sprite'
        ? `时长低于 ${threshold}s，跳过雪碧图`
        : '缓存已存在'
    return {
      id: `${video.pickCode}-${index}`,
      name: video.name,
      pickCode: video.pickCode,
      duration: video.duration,
      status: mode ? 'pending' : 'skipped',
      message,
      progress: 0,
      progressText: '',
      existing,
      effectiveMode: mode,
      relativeDir: video.relativeDir,
    }
  })
}

/** 提取参数 */
interface ExtractOptions {
  pickCode: string
  videoName: string
  grid: Grid
  mode: Mode
  cellWidth: number
  maxBytes: number
  percent: number
  frameConcurrency: number
  /** 雪碧图最短时长（秒），0 表示不限 */
  spriteThreshold: number
  cancel: CancelToken
  onProgress?: (done: number, total: number) => void
}

/** 提取结果 */
interface ExtractedImages {
  duration: number
  sprite?: Blob
  thumb?: Blob
  /** 解码后发现时长低于阈值，雪碧图被跳过（缩略图仍生成） */
  spriteSkippedForShort?: boolean
  /** 雪碧图中取不到的帧数（格子留黑） */
  spriteMissing?: number
}

/** 检查取消 */
function ensureNotCancelled(cancel: CancelToken): void {
  if (cancel.cancelled) {
    throw new CancelledError()
  }
}

/**
 * 限制并发
 * @description 某一项失败后不再启动新项，但要等所有在途任务结束才返回，
 * 避免调用方提前清理解码器/帧资源，留下后台任务和泄漏。
 */
async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
  onDone?: () => void,
): Promise<R[]> {
  const results: R[] = []
  let nextIndex = 0
  let firstError: unknown
  let failed = false
  const workerCount = Math.max(1, Math.min(limit, items.length))

  const workers = Array.from({ length: workerCount }, async () => {
    while (!failed) {
      const index = nextIndex++
      if (index >= items.length) {
        return
      }
      try {
        results[index] = await fn(items[index]!)
        onDone?.()
      }
      catch (error) {
        if (!failed) {
          failed = true
          firstError = error
        }
        return
      }
    }
  })

  await Promise.all(workers)
  if (failed) {
    throw firstError
  }
  return results
}

/** 单帧 seek 失败时是否值得重试（只有编解码器配置/初始化错误换帧也无用） */
function isRetryableSeekError(error: unknown): boolean {
  if (error instanceof CancelledError || error instanceof HlsError) {
    return false
  }
  if (error instanceof DecoderFlowError) {
    return error.name !== 'DecoderFlowDecoderConfiguration'
      && error.name !== 'DecoderFlowNotInitialized'
  }
  return true
}

/** 分片读取失败多半是网络抖动，同一时间点可以先重试一次 */
function isDataReadError(error: unknown): boolean {
  return error instanceof DecoderFlowError && error.name === 'DecoderFlowDataRead'
}

/**
 * 从 115 转码 HLS 解码出雪碧图/缩略图
 */
async function extractImages(options: ExtractOptions): Promise<ExtractedImages> {
  const {
    pickCode,
    videoName,
    grid,
    mode,
    cellWidth,
    maxBytes,
    percent,
    frameConcurrency,
    spriteThreshold,
    cancel,
    onProgress,
  } = options

  let wantsSprite = mode === 'sprite' || mode === 'both'
  const wantsThumb = mode === 'thumb' || mode === 'both'
  let spriteCount = wantsSprite ? grid.cols * grid.rows : 0
  // 有雪碧图时缩略图直接用最后一帧，不需要单独取帧
  let totalSteps = spriteCount + (wantsThumb && !wantsSprite ? 1 : 0)
  let doneSteps = 0
  let spriteSkippedForShort = false

  const reportProgress = () => {
    doneSteps++
    onProgress?.(doneSteps, totalSteps)
  }

  ensureNotCancelled(cancel)

  const masterText = await getMasterText(pickCode)
  const clipper = new M3U8ClipperNew({
    url: masterUrl(pickCode),
    text: masterText,
  })
  const acquired: ImageBitmap[] = []

  try {
    await clipper.open()
    ensureNotCancelled(cancel)

    const duration = clipper.hlsIo.duration
    if (!Number.isFinite(duration) || duration <= 0) {
      throw new HlsError('empty', '读取 HLS 时长失败')
    }

    // 115 没给时长（duration=0）时，打开 HLS 后才知道真实时长：同样执行阈值规则
    if (wantsSprite && isShortForSprite(duration, spriteThreshold)) {
      if (!wantsThumb) {
        throw new SpriteShortSkipError(duration, spriteThreshold)
      }
      wantsSprite = false
      spriteCount = 0
      totalSteps = 1
      doneSteps = 0
      spriteSkippedForShort = true
      console.debug(`[Thumb] ${videoName} 时长 ${duration.toFixed(1)}s 低于 ${spriteThreshold}s，只生成缩略图`)
    }

    const decodeFrameOnce = async (
      time: number,
      maxSize: number,
      firstFramePriority = false,
    ): Promise<ImageBitmap> => {
      ensureNotCancelled(cancel)
      const result = await clipper.seek(time, firstFramePriority, 1)
      if (!result) {
        throw new Error(`未取到 ${time.toFixed(1)}s 的画面`)
      }
      try {
        const resize = getImageResize(
          result.videoFrame.displayWidth,
          result.videoFrame.displayHeight,
          maxSize,
          maxSize,
        )
        const bitmap = await createImageBitmap(result.videoFrame, {
          // 视频帧是照片类内容，像素化（最近邻）缩小会有明显锯齿
          resizeQuality: 'high',
          resizeWidth: resize.width,
          resizeHeight: resize.height,
        })
        acquired.push(bitmap)
        reportProgress()
        return bitmap
      }
      finally {
        result.videoFrame.close()
      }
    }

    // 单帧失败时：网络抖动先在同一时间点重试一次，再换附近的帧重试
    const decodeFrame = async (time: number, maxSize: number): Promise<ImageBitmap> => {
      const candidates = frameRetryTimes(time, duration)
      let lastError: unknown
      for (let index = 0; index < candidates.length; index++) {
        const candidate = candidates[index]!
        try {
          return await decodeFrameOnce(candidate, maxSize)
        }
        catch (error) {
          if (!isRetryableSeekError(error) || cancel.cancelled) {
            throw error
          }
          lastError = error
        }

        // 分片读取失败（网络抖动）：同一时间点再试一次
        if (index === 0 && isDataReadError(lastError)) {
          await promiseDelay(300)
          ensureNotCancelled(cancel)
          try {
            return await decodeFrameOnce(candidate, maxSize)
          }
          catch (error) {
            if (!isRetryableSeekError(error) || cancel.cancelled) {
              throw error
            }
            lastError = error
          }
        }

        const next = candidates[index + 1]
        if (next !== undefined) {
          console.debug(`[Thumb] ${videoName} 取 ${candidate.toFixed(1)}s 失败，换 ${next.toFixed(1)}s 重试：${messageOf(lastError)}`)
          await promiseDelay(200)
          ensureNotCancelled(cancel)
        }
      }

      // 最后兜底：接受该分片里解码出的第一帧（可能略早于目标时间），
      // 避免个别时间点匹配不到帧导致整条视频失败
      try {
        console.debug(`[Thumb] ${videoName} ${time.toFixed(1)}s 仍取不到，改用分片首帧`)
        return await decodeFrameOnce(time, maxSize, true)
      }
      catch (error) {
        if (!isRetryableSeekError(error) || cancel.cancelled) {
          throw error
        }
        throw lastError ?? error
      }
    }

    let sprite: Blob | undefined
    let lastSpriteFrame: ImageBitmap | undefined
    let spriteMissing = 0
    if (wantsSprite) {
      const positions = spritePositions(duration, spriteCount)
      // 缺太多帧说明整条视频/分片都有问题，不再生成残缺雪碧图
      const required = Math.max(1, Math.ceil(positions.length * 2 / 3))
      const allowedMissing = positions.length - required
      const frames = await mapLimit(
        positions,
        frameConcurrency,
        async (time) => {
          try {
            return await decodeFrame(time, cellWidth)
          }
          catch (error) {
            // 取消/HLS 级错误仍然终止整条视频；单帧失败只留空格子
            if (error instanceof CancelledError || error instanceof HlsError) {
              throw error
            }
            spriteMissing++
            // 这一帧已经尝试过，让进度条继续前进
            reportProgress()
            // 已经不可能达到可用帧数时立刻停手，避免整条视频卡在超时上
            if (spriteMissing > allowedMissing) {
              throw new Error(`雪碧图取帧失败：已缺 ${spriteMissing}/${positions.length} 帧`)
            }
            console.warn(`[Thumb] ${videoName} ${time.toFixed(1)}s 取帧失败，跳过该帧：${messageOf(error)}`)
            return undefined
          }
        },
      )
      ensureNotCancelled(cancel)
      const usable = frames.filter((frame): frame is ImageBitmap => !!frame)
      if (usable.length < required) {
        throw new Error(`雪碧图取帧失败：只取到 ${usable.length}/${frames.length} 帧`)
      }
      lastSpriteFrame = usable[usable.length - 1]
      sprite = await composeSprite(frames, grid, maxBytes)
    }

    let thumb: Blob | undefined
    if (wantsThumb) {
      if (lastSpriteFrame) {
        // 已经有雪碧图时不再单独抽取：直接用雪碧图最后一帧当缩略图
        thumb = await composeThumbnail(lastSpriteFrame)
      }
      else {
        const thumbTime = Math.max(0, Math.min(duration - 0.05, duration * percent / 100))
        // 普通缩略图固定 320px 长边，与 Purer / 手机 App 一致
        const frame = await decodeFrame(thumbTime, 320)
        thumb = await composeThumbnail(frame)
      }
    }

    console.debug(`[Thumb] ${videoName} 解码完成：${duration.toFixed(1)}s`)
    return { duration, sprite, thumb, spriteSkippedForShort, spriteMissing }
  }
  catch (error) {
    if (error instanceof CancelledError
      || error instanceof HlsError
      || error instanceof SpriteShortSkipError) {
      throw error
    }
    throw new DecodeError(error instanceof Error ? error.message : String(error), error)
  }
  finally {
    acquired.forEach(bitmap => bitmap.close())
    clipper.destroy()
  }
}

/** 上传结果 */
interface UploadedFile {
  filename: string
  size: number
  /** 该文件是雪碧图还是普通缩略图 */
  part: 'sprite' | 'thumb'
}

/** 生成并上传单个视频 */
async function runVideo(options: {
  settings: ScraperSettings
  client: WebDavClient
  video: VideoItem
  grid: Grid
  mode: Mode
  cancel: CancelToken
  onProgress?: (done: number, total: number) => void
}): Promise<{ uploaded: UploadedFile[], duration: number, note: string }> {
  const { settings, client, video, grid, mode, cancel, onProgress } = options
  const maxBytes = settings.maxKB * 1024

  const images = await extractImages({
    pickCode: video.pickCode,
    videoName: video.name,
    grid,
    mode,
    cellWidth: settings.cellWidth,
    maxBytes,
    percent: settings.percent,
    frameConcurrency: settings.frameConcurrency,
    spriteThreshold: settings.spriteMinDuration,
    cancel,
    onProgress,
  })

  const reportDuration = video.duration > 0 ? video.duration : images.duration
  const base = cacheBaseName(video.name, reportDuration)
  const targetFolder = buildTargetFolder(settings, video.relativeDir)
  const uploaded: UploadedFile[] = []
  const tasks: Promise<void>[] = []
  const notes: string[] = []

  if (images.sprite) {
    const filename = `${base}~${grid.cols}x${grid.rows}.jpg`
    const data = await images.sprite.arrayBuffer()
    uploaded.push({ filename, size: images.sprite.size, part: 'sprite' })
    tasks.push(client.put(joinFile(targetFolder, filename), data, settings.cacheRoot))
    if (images.sprite.size > maxBytes) {
      notes.push(`雪碧图 ${formatSize(images.sprite.size)} 超过上限`)
    }
  }

  if (images.thumb) {
    const filename = `${base}.jpg`
    const data = await images.thumb.arrayBuffer()
    uploaded.push({ filename, size: images.thumb.size, part: 'thumb' })
    tasks.push(client.put(joinFile(targetFolder, filename), data, settings.cacheRoot))
  }

  if (images.spriteMissing) {
    notes.push(`雪碧图缺少 ${images.spriteMissing} 帧`)
  }

  // 时长低于阈值、雪碧图按规则跳过时，把原因写进任务行说明
  if (images.spriteSkippedForShort
    || (settings.mode !== 'thumb'
      && !images.sprite
      && isShortForSprite(reportDuration, settings.spriteMinDuration))) {
    notes.push(`时长低于 ${settings.spriteMinDuration}s，只生成缩略图`)
  }

  // 两个文件并行上传，省一个往返；等两边都落定再抛错，避免留下后台 PUT
  const results = await Promise.allSettled(tasks)
  const rejected = results.find(result => result.status === 'rejected')
  if (rejected && rejected.status === 'rejected') {
    throw rejected.reason
  }

  return { uploaded, duration: images.duration, note: notes.join('；') }
}

/** 失败原因 */
export function reasonOf(error: unknown): string {
  if (error instanceof AccountVerifyError) {
    return 'verify'
  }
  if (error instanceof NoHlsError) {
    return 'no-hls'
  }
  if (error instanceof PlaylistRequestError) {
    return 'network'
  }
  if (error instanceof HlsError) {
    return error.kind === 'no-hls' ? 'no-hls' : `hls-${error.kind}`
  }
  if (error instanceof WebDavError) {
    return error.status === 401 || error.status === 403 ? 'auth' : 'upload'
  }
  if (error instanceof DecodeError) {
    const cause = error.cause
    if (cause instanceof DecoderFlowError) {
      if (cause.name === 'DecoderFlowDataRead') {
        return 'network'
      }
      if (cause.name === 'DecoderFlowTimeout') {
        return 'timeout'
      }
    }
    if (cause instanceof Error && /读取播放列表失败|读取分片失败/.test(cause.message)) {
      return 'network'
    }
    return 'decode'
  }
  if (error instanceof CancelledError) {
    return 'cancelled'
  }
  return 'error'
}

/** 失败原因的中文名（给界面/日志用） */
export function reasonLabel(reason: string): string {
  const labels: Record<string, string> = {
    'verify': '需要验证 115 账号',
    'no-hls': '未转码',
    'network': '网络/授权失败',
    'timeout': '取帧超时',
    'auth': '认证失败',
    'upload': '上传失败',
    'decode': '解码失败',
    'cancelled': '已取消',
    'hls-encrypted': 'HLS 已加密',
    'hls-fmp4': 'HLS 是 fMP4',
    'hls-byte-range': 'HLS 使用 BYTERANGE',
    'hls-empty': 'HLS 为空',
    'hls-unsupported': '不支持的 HLS',
    'error': '未知错误',
  }
  return labels[reason] ?? reason
}

/** 错误信息 */
export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** 文件大小 */
function formatSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes}B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(0)}KB`
  }
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`
}

/** 运行事件 */
export interface RunEvent {
  category: 'success' | 'error' | 'skip'
  row: Row
  message: string
  reason?: string
  /** 本次实际产出的文件类型（用于缩略图/雪碧图分开统计） */
  produced?: { sprite: boolean, thumb: boolean }
}

/** 运行参数 */
export interface RunOptions {
  settings: ScraperSettings
  rows: Row[]
  client: WebDavClient
  cancel: CancelToken
  onRowUpdate: (row: Row) => void
  onEvent: (event: RunEvent) => void
}

/**
 * 并发生成所有待处理视频
 */
export async function runRows(options: RunOptions): Promise<void> {
  const { settings, rows, client, cancel } = options
  const grid = parseGrid(settings.grid)
  const queue = rows.filter(
    row => row.effectiveMode && (row.status === 'pending' || row.status === 'error'),
  )
  if (queue.length === 0) {
    return
  }

  let nextIndex = 0
  // 115 要求验证账号时整批任务都会失败：记录第一个错误，停止派发新视频
  let verifyError: AccountVerifyError | null = null
  const workerCount = Math.max(1, Math.min(settings.videoConcurrency, queue.length))

  const workers = Array.from({ length: workerCount }, async () => {
    while (true) {
      if (cancel.cancelled || verifyError) {
        return
      }
      const index = nextIndex++
      if (index >= queue.length) {
        return
      }
      const row = queue[index]!
      row.status = 'running'
      row.progress = 0
      row.progressText = ''
      row.message = '解码中'
      options.onRowUpdate(row)

      try {
        const result = await runVideo({
          settings,
          client,
          video: {
            name: row.name,
            pickCode: row.pickCode,
            duration: row.duration,
            relativeDir: row.relativeDir,
          },
          grid,
          mode: row.effectiveMode!,
          cancel,
          onProgress: (done, total) => {
            row.progress = total > 0 ? Math.round((done / total) * 100) : 0
            row.progressText = `${done}/${total}`
            options.onRowUpdate(row)
          },
        })

        row.status = 'success'
        row.progress = 100
        const descriptions = result.uploaded.map(item =>
          `${item.part === 'sprite' ? '雪碧图' : '缩略图'} ${item.filename} ${formatSize(item.size)}`,
        )
        if (result.note) {
          descriptions.push(result.note)
        }
        row.message = descriptions.join('、')
        row.filename = result.uploaded[0]?.filename
        options.onRowUpdate(row)
        options.onEvent({
          category: 'success',
          row,
          message: row.message,
          produced: {
            sprite: result.uploaded.some(item => item.part === 'sprite'),
            thumb: result.uploaded.some(item => item.part === 'thumb'),
          },
        })
      }
      catch (error) {
        if (error instanceof CancelledError) {
          row.status = 'pending'
          row.progress = 0
          row.progressText = ''
          row.message = '已取消'
          options.onRowUpdate(row)
          return
        }

        if (error instanceof SpriteShortSkipError) {
          row.status = 'skipped'
          row.progress = 0
          row.progressText = ''
          row.message = error.message
          row.effectiveMode = null
          options.onRowUpdate(row)
          options.onEvent({ category: 'skip', row, message: row.message })
          continue
        }

        // 账号验证失败：这一条标记失败，并让所有 worker 停止派发新视频
        if (error instanceof AccountVerifyError) {
          row.status = 'error'
          row.progress = 0
          row.progressText = ''
          row.message = error.message
          options.onRowUpdate(row)
          options.onEvent({
            category: 'error',
            row,
            message: row.message,
            reason: 'verify',
          })
          verifyError = verifyError ?? error
          return
        }

        row.status = 'error'
        row.message = messageOf(error)
        options.onRowUpdate(row)
        options.onEvent({
          category: 'error',
          row,
          message: row.message,
          reason: reasonOf(error),
        })
      }
    }
  })

  await Promise.all(workers)
  // 抛给调用方：由界面中止后续文件夹并提醒用户验证账号
  if (verifyError) {
    throw verifyError
  }
}
