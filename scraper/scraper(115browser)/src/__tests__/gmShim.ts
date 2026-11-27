/** Vitest 下用于替代 vite-plugin-monkey 的 $ 模块 */
const values = new Map<string, unknown>()

export function GM_getValue<T>(key: string, defaultValue?: T): T {
  return (values.has(key) ? values.get(key) : defaultValue) as T
}

export function GM_setValue(key: string, value: unknown): void {
  values.set(key, value)
}

export function GM_addStyle(_css: string): void {}

export function GM_registerMenuCommand(_name: string, _fn: () => void): void {}

export function GM_xmlhttpRequest(details: any): void {
  const method = details.method || 'GET'
  const headers: Record<string, string> = details.headers || {}
  let body: BodyInit | undefined
  if (details.data instanceof ArrayBuffer) {
    body = Buffer.from(details.data)
  }
  else if (typeof details.data === 'string') {
    body = details.data
  }

  fetch(details.url, {
    method,
    headers,
    body,
    redirect: 'manual',
  })
    .then(async (response) => {
      const buffer = await response.arrayBuffer()
      const text = new TextDecoder().decode(buffer)
      const responseHeaders = [...response.headers]
        .map(([key, value]) => `${key}: ${value}`)
        .join('\r\n')
      details.onload?.({
        status: response.status,
        statusText: response.statusText,
        responseHeaders,
        response: details.responseType === 'arraybuffer' ? buffer : text,
        responseText: details.responseType === 'arraybuffer' ? '' : text,
        finalUrl: response.url,
      })
    })
    .catch((error) => {
      details.onerror?.({ error })
    })
}
