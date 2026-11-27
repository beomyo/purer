import { gmRequest } from '../../gm'
import { ChunkReader } from './ChunkIO'

/** Range 请求结果 */
export interface RangeResponse {
  status: number
  contentLength: number
  data: ArrayBuffer
}

/** 原生 fetch 不可用的站点；后续直接走 GM 请求，避免每个分片都先失败一次 */
const gmOnlyHosts = new Set<string>()

/** 取 URL 的 host */
function hostOf(url: string): string {
  try {
    return new URL(url).host
  }
  catch {
    return url
  }
}

/**
 * FetchIO 类 - 读取远程播放列表和分片
 * @description 优先用页面原生 fetch（与 115Master 的行为一致），
 * 跨域被拦或 401/403 时回退到 GM_xmlhttpRequest。
 */
export class FetchIO {
  /** 默认请求头 */
  headers: Record<string, string> = {}

  /**
   * 创建分块读取器
   */
  createChunkReader(url: string, start: number, limit: number = ChunkReader.DEFAULT_LIMIT): ChunkReader {
    return new ChunkReader(url, this, start, limit)
  }

  /**
   * 读取文本（播放列表）
   */
  async fetchText(url: string, headers?: Record<string, string>): Promise<string> {
    const mergedHeaders: Record<string, string> = {
      Referer: 'https://115.com/',
      ...this.headers,
      ...headers,
    }

    const host = hostOf(url)
    if (!gmOnlyHosts.has(host)) {
      try {
        const response = await fetch(url, { headers: mergedHeaders })
        if (response.ok) {
          return await response.text()
        }
        if (response.status !== 401 && response.status !== 403) {
          throw new Error(`读取播放列表失败 HTTP ${response.status}`)
        }
        // 原生请求拿不到授权，之后同站点直接用 GM 请求
        gmOnlyHosts.add(host)
      }
      catch (error) {
        if (error instanceof Error && error.message.startsWith('读取播放列表失败 HTTP')) {
          throw error
        }
        gmOnlyHosts.add(host)
      }
    }

    const response = await gmRequest({
      url,
      headers: mergedHeaders,
      responseType: 'text',
      timeout: 30_000,
    })
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`读取播放列表失败 HTTP ${response.status}`)
    }
    return response.text
  }

  /**
   * 读取指定字节范围
   */
  async fetchBufferRange(
    url: string,
    start: number,
    end?: number,
    headers?: Record<string, string>,
  ): Promise<RangeResponse> {
    const mergedHeaders: Record<string, string> = {
      Referer: 'https://115.com/',
      ...this.headers,
      ...headers,
      Range: `bytes=${start}-${end ?? ''}`,
    }

    const host = hostOf(url)
    if (!gmOnlyHosts.has(host)) {
      try {
        const response = await fetch(url, { headers: mergedHeaders })
        if (response.status === 200 || response.status === 206) {
          const data = await response.arrayBuffer()
          const headerLength = Number.parseInt(response.headers.get('content-length') ?? '0', 10) || 0
          return {
            status: response.status,
            contentLength: headerLength || data.byteLength,
            data,
          }
        }
        if (response.status !== 401 && response.status !== 403) {
          throw new Error(`读取分片失败 HTTP ${response.status}`)
        }
        // 原生请求拿不到授权，之后同站点直接用 GM 请求
        gmOnlyHosts.add(host)
      }
      catch (error) {
        if (error instanceof Error && error.message.startsWith('读取分片失败 HTTP')) {
          throw error
        }
        gmOnlyHosts.add(host)
      }
    }

    const response = await gmRequest({
      url,
      headers: mergedHeaders,
      responseType: 'arraybuffer',
      timeout: 60_000,
    })
    const headerLength = Number.parseInt(response.headers['content-length'] ?? '0', 10) || 0
    const contentLength = headerLength || response.data?.byteLength || 0
    return {
      status: response.status,
      contentLength,
      data: response.data ?? new ArrayBuffer(0),
    }
  }
}
