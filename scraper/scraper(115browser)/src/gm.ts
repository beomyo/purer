import { GM_xmlhttpRequest } from '$'

/** GM 请求选项 */
export interface GmRequestOptions {
  method?: string
  url: string
  headers?: Record<string, string>
  data?: string | ArrayBuffer | Blob
  responseType?: 'text' | 'arraybuffer'
  timeout?: number
}

/** GM 响应 */
export interface GmResponse {
  status: number
  statusText: string
  headers: Record<string, string>
  text: string
  data: ArrayBuffer | null
  finalUrl: string
}

/** 解析响应头 */
function parseHeaders(raw: string): Record<string, string> {
  const result: Record<string, string> = {}
  for (const line of (raw || '').split(/\r?\n/)) {
    const index = line.indexOf(':')
    if (index <= 0) {
      continue
    }
    result[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim()
  }
  return result
}

/**
 * 用 GM_xmlhttpRequest 发请求
 * @description 绕过 CORS，并自动带上目标站点的 Cookie。
 */
export function gmRequest(options: GmRequestOptions): Promise<GmResponse> {
  return new Promise((resolve, reject) => {
    const details: Record<string, unknown> = {
      method: options.method ?? 'GET',
      url: options.url,
      headers: options.headers,
      timeout: options.timeout ?? 60_000,
      onload: (res: any) => {
        const data = res.response instanceof ArrayBuffer ? res.response : null
        resolve({
          status: Number(res.status) || 0,
          statusText: res.statusText || '',
          headers: parseHeaders(res.responseHeaders || ''),
          text: typeof res.responseText === 'string' ? res.responseText : '',
          data,
          finalUrl: res.finalUrl || options.url,
        })
      },
      onerror: (event: any) => {
        reject(new Error(`请求失败：${options.url}${event?.error ? `（${event.error}）` : ''}`))
      },
      ontimeout: () => {
        reject(new Error(`请求超时：${options.url}`))
      },
    }

    if (options.data !== undefined) {
      details.data = options.data
    }
    if (options.responseType) {
      details.responseType = options.responseType
    }

    GM_xmlhttpRequest(details as any)
  })
}
