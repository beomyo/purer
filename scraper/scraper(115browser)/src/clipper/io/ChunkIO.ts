import type { FetchIO } from './FetchIO'

/**
 * 分块读取器
 */
export class ChunkReader {
  static readonly DEFAULT_LIMIT = 188 * 1024 * 2
  private offset: number = 0
  private limit: number = 0
  private io: FetchIO
  private url: string
  private count: number = 0
  private stoped: boolean = false
  private doned: boolean = false

  constructor(
    url: string,
    io: FetchIO,
    offset: number,
    limit: number = ChunkReader.DEFAULT_LIMIT,
  ) {
    this.url = url
    this.io = io
    this.offset = offset
    this.limit = limit
  }

  get isStoped() {
    return this.stoped
  }

  get isDoned() {
    return this.doned
  }

  from(offset: number) {
    this.offset = offset
    return this
  }

  take(limit: number) {
    this.limit = limit
    return this
  }

  stop() {
    this.stoped = true
  }

  async _read(start: number, end: number) {
    return await this.io.fetchBufferRange(this.url, start, end)
  }

  async next(): Promise<ArrayBuffer | undefined> {
    if (this.doned) {
      throw new Error('chunk reader is done')
    }

    this.count++
    const start = this.offset
    const end = this.limit === 0 ? undefined : this.offset + this.limit - 1
    const res = await this._read(start, end ?? start)

    if (res.status === 200) {
      // 服务器忽略了 Range，返回了完整响应；只消费一次，避免反复读整个文件
      this.doned = true
      return res.data
    }

    if (res.status === 206) {
      this.offset += this.limit
      if (res.contentLength < this.limit) {
        this.doned = true
      }
      return res.data
    }

    if (res.status === 416) {
      this.doned = true
      return undefined
    }

    throw new Error(`读取分片失败 HTTP ${res.status}`)
  }
}
