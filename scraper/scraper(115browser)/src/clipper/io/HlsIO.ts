import type { HlsSegment } from '../../hls'
import { HlsError, parseMasterPlaylist, parseMediaPlaylist } from '../../hls'
import { FetchIO } from './FetchIO'

/**
 * 请求信息
 */
interface FetchInfo {
  url: string
  headers?: Record<string, string>
  fetchOptions?: RequestInit
}

/**
 * 分段
 */
export type Segment = HlsSegment

/**
 * HlsIO 类 - 负责解析 m3u8 并按时间定位分片
 */
export class HlsIO extends FetchIO {
  info: FetchInfo | undefined
  segments: Segment[] = []
  duration = 0

  /**
   * 打开并解析播放列表
   */
  async open(info: FetchInfo): Promise<void> {
    this.info = info
    this.headers = info.headers ?? {}
    await this.loadPlaylist(info.url)
  }

  /**
   * 使用已经取到的播放列表文本（避免重复请求主列表）
   */
  async openWithText(text: string, url: string, headers?: Record<string, string>): Promise<void> {
    this.info = { url, headers }
    this.headers = headers ?? {}
    await this.loadPlaylist(url, text)
  }

  /**
   * 读取分片
   * @param time 时间/秒
   */
  readSegment(time: number): Segment {
    const index = this.segments.findIndex(
      segment => segment.timestamp <= time && time <= segment.endTime,
    )
    if (index === -1) {
      throw new Error('时间超出范围')
    }
    return this.segments[index]!
  }

  /** 销毁 */
  destroy(): void {
    this.segments = []
    this.duration = 0
    this.info = undefined
    this.headers = {}
  }

  /**
   * 解析主列表/媒体列表
   */
  private async loadPlaylist(url: string, initialText?: string): Promise<void> {
    let text = initialText ?? await this.fetchText(url)
    if (!text.trim().startsWith('#')) {
      throw new HlsError('no-hls', '115 未生成转码播放列表')
    }

    let mediaUrl = url
    let mediaText = text
    const variants = parseMasterPlaylist(text, url)
    if (variants.length > 0) {
      const chosen = [...variants].sort((a, b) => a.bandwidth - b.bandwidth)[0]!
      mediaUrl = chosen.url
      mediaText = await this.fetchText(mediaUrl)
    }

    const media = parseMediaPlaylist(mediaText, mediaUrl)
    if (media.encrypted) {
      throw new HlsError('encrypted', 'HLS 已加密，浏览器无法解码')
    }
    if (media.hasMap) {
      throw new HlsError('fmp4', 'HLS 分片是 fMP4，浏览器解码器暂不支持')
    }
    if (media.hasByteRange) {
      throw new HlsError('byte-range', 'HLS 使用了 BYTERANGE，暂不支持')
    }
    if (media.segments.length === 0) {
      throw new HlsError('empty', 'HLS 播放列表为空')
    }

    this.segments = media.segments
    this.duration = media.duration
  }
}
