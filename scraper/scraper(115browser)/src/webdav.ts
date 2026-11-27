import type { GmResponse } from './gm'
import { gmRequest } from './gm'
import { promiseDelay } from './promise'

/** WebDAV 错误 */
export class WebDavError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message)
    this.name = 'WebDavError'
  }
}

/** 目录项 */
export interface DavEntry {
  url: string
  name: string
  isDir: boolean
}

/** PROPFIND 请求体 */
const PROPFIND_BODY = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
  </D:prop>
</D:propfind>`

/** 统一目录 URL（结尾加斜杠） */
export function normalizeFolder(url: string): string {
  const parsed = new URL(url.trim())
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('WebDAV 地址必须以 http:// 或 https:// 开头')
  }
  if (!parsed.pathname.endsWith('/')) {
    parsed.pathname += '/'
  }
  return parsed.href
}

/** 拼接目录 URL */
export function joinFolder(base: string, ...segments: string[]): string {
  const folder = normalizeFolder(base)
  const path = segments
    .flatMap(segment => segment.split('/'))
    .filter(Boolean)
    .map(segment => encodeURIComponent(segment))
    .join('/')
  return path ? `${folder}${path}/` : folder
}

/** 拼接文件 URL */
export function joinFile(folder: string, name: string): string {
  return `${normalizeFolder(folder)}${encodeURIComponent(name)}`
}

/** 可以重试的临时错误状态码 */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500
}

/** UTF-8 Basic 认证头 */
function basicAuth(username: string, password: string): string {
  const bytes = new TextEncoder().encode(`${username}:${password}`)
  let binary = ''
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return `Basic ${btoa(binary)}`
}

/** 按 localName 查找元素（兼容不同命名空间前缀） */
function elementsByLocalName(root: Element | Document, localName: string): Element[] {
  const byNamespace = root.getElementsByTagNameNS('DAV:', localName)
  if (byNamespace.length > 0) {
    return Array.from(byNamespace)
  }
  return Array.from(root.getElementsByTagName('*')).filter(
    element => element.localName === localName,
  )
}

/** 取第一个子元素 */
function firstByLocalName(root: Element | Document, localName: string): Element | undefined {
  return elementsByLocalName(root, localName)[0]
}

/**
 * 简单 WebDAV 客户端
 * @description 用 GM_xmlhttpRequest 绕过 CORS，上传时直接带 Basic 认证。
 */
export class WebDavClient {
  readonly baseUrl: string
  private readonly authHeader: string
  private readonly ensured = new Set<string>()
  /** 正在创建的目录，避免并发上传时对同一目录重复 MKCOL */
  private readonly ensuring = new Map<string, Promise<void>>()

  constructor(
    baseUrl: string,
    username: string,
    password: string,
  ) {
    this.baseUrl = normalizeFolder(baseUrl)
    this.authHeader = username || password ? basicAuth(username, password) : ''
  }

  /** 请求 */
  private async request(
    method: string,
    url: string,
    headers: Record<string, string> = {},
    data?: string | ArrayBuffer,
    responseType: 'text' | 'arraybuffer' = 'text',
  ) {
    const mergedHeaders: Record<string, string> = { ...headers }
    if (this.authHeader) {
      mergedHeaders.Authorization = this.authHeader
    }
    return gmRequest({
      method,
      url,
      headers: mergedHeaders,
      data,
      responseType,
      timeout: method === 'PROPFIND' ? 30_000 : 120_000,
    })
  }

  /** 列出目录（Depth: 1） */
  async list(url: string, options: { missingAsEmpty?: boolean } = {}): Promise<DavEntry[]> {
    const folder = normalizeFolder(url)
    const response = await this.request(
      'PROPFIND',
      folder,
      {
        Depth: '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      PROPFIND_BODY,
    )

    if (response.status === 404) {
      if (options.missingAsEmpty === false) {
        throw new WebDavError('目录不存在', 404)
      }
      return []
    }
    if (response.status === 401 || response.status === 403) {
      throw new WebDavError('WebDAV 认证失败', response.status)
    }
    if (response.status !== 200 && response.status !== 207) {
      throw new WebDavError(`列目录失败 HTTP ${response.status}`, response.status)
    }

    const document = new DOMParser().parseFromString(response.text, 'application/xml')
    const requested = new URL(folder)
    const result: DavEntry[] = []

    for (const node of elementsByLocalName(document, 'response')) {
      const hrefElement = firstByLocalName(node, 'href')
      const href = hrefElement?.textContent?.trim()
      if (!href) {
        continue
      }
      let childUrl: URL
      try {
        childUrl = new URL(href, folder)
      }
      catch {
        continue
      }
      if (childUrl.pathname.replace(/\/$/, '') === requested.pathname.replace(/\/$/, '')) {
        continue
      }
      const resourceType = firstByLocalName(node, 'resourcetype')
      const isDir = resourceType
        ? elementsByLocalName(resourceType, 'collection').length > 0
        : childUrl.pathname.endsWith('/')
      const rawName = childUrl.pathname.replace(/\/$/, '').split('/').pop() || ''
      let name = rawName
      try {
        name = decodeURIComponent(rawName)
      }
      catch {
        // 服务器返回了非法的百分号编码时不要整页失败，按原样使用
        name = rawName
      }
      if (!name) {
        continue
      }
      result.push({
        url: isDir ? normalizeFolder(childUrl.href) : childUrl.href,
        name,
        isDir,
      })
    }

    return result.sort((a, b) => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1
      }
      return a.name.localeCompare(b.name, 'zh-CN')
    })
  }

  /** 创建单个目录 */
  async ensureDir(url: string): Promise<void> {
    const folder = normalizeFolder(url)
    if (this.ensured.has(folder)) {
      return
    }
    const pending = this.ensuring.get(folder)
    if (pending) {
      return pending
    }
    const task = this.createDir(folder).finally(() => {
      this.ensuring.delete(folder)
    })
    this.ensuring.set(folder, task)
    return task
  }

  /** 真正发起 MKCOL */
  private async createDir(folder: string): Promise<void> {
    const response = await this.request('MKCOL', folder)
    if (response.status === 401 || response.status === 403) {
      throw new WebDavError('WebDAV 认证失败', response.status)
    }
    // 201 创建成功；405/301/302 表示已经存在
    if (![200, 201, 204, 301, 302, 405].includes(response.status)) {
      throw new WebDavError(`创建目录失败 HTTP ${response.status}`, response.status)
    }
    this.ensured.add(folder)
  }

  /** 逐级创建目录 */
  async ensureTree(folderUrl: string, rootUrl: string): Promise<void> {
    const folder = normalizeFolder(folderUrl)
    const root = normalizeFolder(rootUrl)
    const folderPath = new URL(folder).pathname
    const rootPath = new URL(root).pathname

    if (!folderPath.startsWith(rootPath)) {
      await this.ensureDir(folder)
      return
    }

    await this.ensureDir(root)
    let current = root
    const segments = folderPath.slice(rootPath.length).split('/').filter(Boolean)
    for (const segment of segments) {
      // pathname 里已经是百分号编码后的片段，这里不能再 encodeURIComponent 一次，
      // 否则「测试 文件夹」会被编码成 %25E6...%2520...，在 WebDAV 上创建出乱码目录。
      current = new URL(`${segment}/`, current).href
      await this.ensureDir(current)
    }
  }

  /**
   * 上传文件
   * @param fileUrl 目标文件 URL
   * @param data JPEG 数据
   * @param rootUrl 缓存根，用于失败时重建目录
   */
  async put(fileUrl: string, data: ArrayBuffer, rootUrl: string): Promise<void> {
    const parent = `${fileUrl.slice(0, fileUrl.lastIndexOf('/') + 1)}`
    await this.ensureTree(parent, rootUrl)

    const upload = () => this.putWithRetry(fileUrl, data)
    let response = await upload()
    if (response.status >= 200 && response.status < 300) {
      return
    }
    if (response.status === 401 || response.status === 403) {
      throw new WebDavError('WebDAV 认证失败', response.status)
    }
    if (response.status === 404 || response.status === 409) {
      this.ensured.delete(parent)
      await this.ensureTree(parent, rootUrl)
      response = await upload()
      if (response.status >= 200 && response.status < 300) {
        return
      }
    }
    throw new WebDavError(`上传失败 HTTP ${response.status}`, response.status)
  }

  /** 上传时对 5xx/超时/网络错误做短退避重试，避免批量任务末尾被偶发失败打断 */
  private async putWithRetry(fileUrl: string, data: ArrayBuffer): Promise<GmResponse> {
    let lastResponse: GmResponse | undefined
    let lastError: unknown
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await this.request(
          'PUT',
          fileUrl,
          { 'Content-Type': 'image/jpeg' },
          data,
        )
        if (!isTransientStatus(response.status) || attempt === 2) {
          return response
        }
        lastResponse = response
      }
      catch (error) {
        lastError = error
      }
      await promiseDelay(400 * (attempt + 1))
    }
    if (lastError) {
      const message = lastError instanceof Error ? lastError.message : String(lastError)
      throw new WebDavError(`上传失败：${message}`)
    }
    if (lastResponse) {
      return lastResponse
    }
    throw new WebDavError('上传失败', 0)
  }

  /** 测试连接并列出缓存根 */
  async test(): Promise<DavEntry[]> {
    await this.ensureDir(this.baseUrl)
    return this.list(this.baseUrl)
  }
}
