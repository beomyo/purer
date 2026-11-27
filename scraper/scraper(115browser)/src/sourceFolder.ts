import { normalizeFolder } from './webdav'

/** 要处理的 115 文件夹（由用户填写的 WebDAV 地址解析而来） */
export interface SourceTarget {
  /** 规范化后的 WebDAV 地址（带结尾斜杠） */
  url: string
  /** 115 内的相对路径（已解码，根目录为空字符串） */
  path: string
}

/** 源文件夹地址无法使用 */
export class SourceFolderError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SourceFolderError'
  }
}

/** 拆出解码后的路径片段（用于与 WebDAV 地址逐段比较） */
function decodedSegments(url: string): string[] {
  return new URL(url).pathname
    .split('/')
    .filter(Boolean)
    .map((segment) => {
      try {
        return decodeURIComponent(segment)
      }
      catch {
        return segment
      }
    })
    .map(segment => segment.normalize('NFC'))
}

/** prefix 是否等于 segments 的前缀 */
function isSegmentPrefix(prefix: string[], segments: string[]): boolean {
  if (prefix.length > segments.length) {
    return false
  }
  return prefix.every((segment, index) => segment === segments[index])
}

/**
 * 从「要处理的 115 文件夹」WebDAV 地址解析出 115 内相对路径
 * @description 不再依赖浏览器当前目录：以用户填写的地址为准。
 * 地址路径必须在 115 挂载点（sourcePrefix，默认 115）之下，这样缓存目标与
 * 115 API 的路径都能由地址直接得出，不需要再选择文件夹。
 */
export function parseSourceFolder(
  input: string,
  options: { sourceWebdavRoot?: string, sourcePrefix?: string } = {},
): SourceTarget {
  const raw = input.trim()
  if (!raw) {
    throw new SourceFolderError(
      '请填写要处理的 115 文件夹地址，例如 http://10.2.31.10/dav/115/要处理的文件夹',
    )
  }

  let url: string
  try {
    url = normalizeFolder(raw)
  }
  catch {
    throw new SourceFolderError('要处理的 115 文件夹地址必须以 http:// 或 https:// 开头')
  }

  // 地址里带查询串/锚点时去掉，避免影响路径判断
  const parsed = new URL(url)
  parsed.search = ''
  parsed.hash = ''
  url = normalizeFolder(parsed.href)

  const segments = decodedSegments(url)
  const prefix = (options.sourcePrefix ?? '').trim().replace(/^\/+|\/+$/g, '')

  // 优先按挂载名定位：/dav/115/要处理的文件夹 → 要处理的文件夹
  if (prefix) {
    const index = segments.indexOf(prefix.normalize('NFC'))
    if (index >= 0) {
      return { url, path: segments.slice(index + 1).join('/') }
    }
  }

  // 没有挂载名时，按源 115 根逐段剥离
  const rootInput = (options.sourceWebdavRoot ?? '').trim()
  if (rootInput) {
    let rootUrl: string | null = null
    try {
      rootUrl = normalizeFolder(rootInput)
    }
    catch {
      // 源根无效时忽略，只在最后给出地址解析失败
    }
    if (rootUrl) {
      const rootSegments = decodedSegments(rootUrl)
      if (isSegmentPrefix(rootSegments, segments)) {
        return { url, path: segments.slice(rootSegments.length).join('/') }
      }
      throw new SourceFolderError(
        `要处理的文件夹必须位于源 115 根 ${rootInput} 之下（或在地址路径中包含 /${prefix || '115'}/）：${url}`,
      )
    }
  }

  throw new SourceFolderError(
    `无法从地址确定 115 内路径（路径中没有 /${prefix || '115'}/）：${url}`,
  )
}
