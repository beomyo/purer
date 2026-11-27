/** HLS 解析失败类型 */
export type HlsErrorKind
  = | 'no-hls'
    | 'encrypted'
    | 'fmp4'
    | 'byte-range'
    | 'empty'
    | 'unsupported'

/** HLS 错误 */
export class HlsError extends Error {
  constructor(
    readonly kind: HlsErrorKind,
    message: string,
  ) {
    super(message)
    this.name = 'HlsError'
  }
}

/** 主播放列表中的变体 */
export interface HlsVariant {
  url: string
  bandwidth: number
  name?: string
}

/** 分片 */
export interface HlsSegment {
  url: string
  duration: number
  /** 分片开始时间（秒） */
  timestamp: number
  /** 分片结束时间（秒） */
  endTime: number
}

/** 媒体播放列表 */
export interface MediaPlaylist {
  segments: HlsSegment[]
  duration: number
  encrypted: boolean
  hasMap: boolean
  hasByteRange: boolean
}

/**
 * 解析主播放列表
 * @description 只关心 #EXT-X-STREAM-INF 的 BANDWIDTH 和紧随其后的 URL。
 * 如果传入的是媒体播放列表，返回空数组。
 */
export function parseMasterPlaylist(text: string, baseUrl: string): HlsVariant[] {
  const lines = text.split(/\r?\n/).map(line => line.trim())
  const variants: HlsVariant[] = []

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!
    if (!line.startsWith('#EXT-X-STREAM-INF:')) {
      continue
    }
    const bandwidthMatch = /BANDWIDTH=(\d+)/i.exec(line)
    const nameMatch = /NAME="([^"]*)"/.exec(line)
    let next = index + 1
    while (next < lines.length) {
      const candidate = lines[next]!
      if (candidate && !candidate.startsWith('#')) {
        try {
          variants.push({
            url: new URL(candidate, baseUrl).href,
            bandwidth: bandwidthMatch ? Number(bandwidthMatch[1]) : Number.POSITIVE_INFINITY,
            name: nameMatch?.[1],
          })
        }
        catch {
          // 跳过无法解析的 URL
        }
        break
      }
      next++
    }
  }

  return variants
}

/**
 * 解析媒体播放列表
 */
export function parseMediaPlaylist(text: string, baseUrl: string): MediaPlaylist {
  const lines = text.split(/\r?\n/).map(line => line.trim())
  const segments: HlsSegment[] = []
  let duration = 0
  let pendingDuration: number | null = null
  let encrypted = false
  let hasMap = false
  let hasByteRange = false

  for (const line of lines) {
    if (!line) {
      continue
    }
    if (line.startsWith('#EXTINF:')) {
      const value = Number.parseFloat(line.slice('#EXTINF:'.length).split(',')[0] ?? '')
      pendingDuration = Number.isFinite(value) ? value : 0
      continue
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      hasMap = true
      continue
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      hasByteRange = true
      continue
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      const method = /METHOD=([^,]+)/.exec(line)?.[1]?.trim().toUpperCase()
      if (method && method !== 'NONE') {
        encrypted = true
      }
      continue
    }
    if (line.startsWith('#')) {
      continue
    }

    let url: string
    try {
      url = new URL(line, baseUrl).href
    }
    catch {
      continue
    }
    const segmentDuration = pendingDuration ?? 0
    segments.push({
      url,
      duration: segmentDuration,
      timestamp: duration,
      endTime: duration + segmentDuration,
    })
    duration += segmentDuration
    pendingDuration = null
  }

  return { segments, duration, encrypted, hasMap, hasByteRange }
}
