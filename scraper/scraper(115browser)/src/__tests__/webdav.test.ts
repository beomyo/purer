import type { AddressInfo } from 'node:net'
import { Buffer } from 'node:buffer'
import { createServer } from 'node:http'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { joinFile, joinFolder, WebDavClient } from '../webdav'

const files = new Map<string, Buffer>()
const dirs = new Set<string>(['/dav/'])
const mkcolPaths: string[] = []
let server: ReturnType<typeof createServer>
let base = ''
let lastAuth = ''

function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function directChildren(folder: string, candidates: string[]): string[] {
  return candidates.filter((item) => {
    if (!item.startsWith(folder) || item === folder) {
      return false
    }
    return !item.slice(folder.length).replace(/\/$/, '').includes('/')
  })
}

function propfindResponse(folder: string): string {
  const directDirs = directChildren(folder, [...dirs])
  const directFiles = directChildren(folder, [...files.keys()])
  if (!dirs.has(folder) && directDirs.length === 0 && directFiles.length === 0) {
    return ''
  }

  const items: string[] = []
  items.push(`<D:response><D:href>${escapeXml(encodeURI(folder))}</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`)

  for (const dir of directDirs) {
    items.push(`<D:response><D:href>${escapeXml(encodeURI(dir))}</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`)
  }
  for (const file of directFiles) {
    const data = files.get(file)!
    items.push(`<D:response><D:href>${escapeXml(encodeURI(file))}</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>${data.length}</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>`)
  }

  return `<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">${items.join('')}</D:multistatus>`
}

beforeAll(async () => {
  server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url ?? '/', 'http://localhost').pathname)
    const folder = path.endsWith('/') ? path : `${path}/`
    if (req.headers.authorization) {
      lastAuth = req.headers.authorization
    }

    if (req.method === 'MKCOL') {
      dirs.add(folder)
      mkcolPaths.push(folder)
      req.resume()
      res.writeHead(201)
      res.end()
      return
    }

    if (req.method === 'PUT') {
      const chunks: Buffer[] = []
      req.on('data', chunk => chunks.push(chunk))
      req.on('end', () => {
        files.set(path, Buffer.concat(chunks))
        res.writeHead(201)
        res.end()
      })
      return
    }

    if (req.method === 'PROPFIND') {
      const xml = propfindResponse(folder)
      req.resume()
      if (!xml) {
        res.writeHead(404)
        res.end()
        return
      }
      res.writeHead(207, { 'Content-Type': 'application/xml; charset=utf-8' })
      res.end(xml)
      return
    }

    req.resume()
    res.writeHead(404)
    res.end()
  })

  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve)
  })
  const address = server.address() as AddressInfo
  base = `http://127.0.0.1:${address.port}/dav/`
})

afterAll(async () => {
  await new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve())
  })
})

describe('路径编码', () => {
  it('目录/文件名只编码一次：%20 不会变成 %2520，字面 % 正确编码为 %25', () => {
    const folder = joinFolder('http://host/dav/UC/cache', '115', 'Pack From Shared', '100% 目录')
    expect(folder).toBe(
      'http://host/dav/UC/cache/115/Pack%20From%20Shared/100%25%20%E7%9B%AE%E5%BD%95/',
    )
    expect(decodeURIComponent(new URL(folder).pathname)).toBe(
      '/dav/UC/cache/115/Pack From Shared/100% 目录/',
    )

    const file = joinFile(folder, '00.10.00_100% 完成.mp4.jpg')
    expect(new URL(file).pathname.endsWith(
      '/00.10.00_100%25%20%E5%AE%8C%E6%88%90.mp4.jpg',
    )).toBe(true)
    expect(decodeURIComponent(new URL(file).pathname).endsWith(
      '/00.10.00_100% 完成.mp4.jpg',
    )).toBe(true)
  })
})

describe('WebDavClient', () => {
  const root = () => `${base}UC/cache/`

  it('创建多级目录并带 Basic 认证上传', async () => {
    const client = new WebDavClient(root(), 'admin', 'pass')
    const target = joinFolder(root(), '115', '测试 文件夹')
    await client.ensureTree(target, root())

    const fileUrl = joinFile(target, '00.10.00_视频.mp4~5x5.jpg')
    const data = new Uint8Array([1, 2, 3]).buffer
    await client.put(fileUrl, data, root())

    const storedPath = decodeURIComponent(new URL(fileUrl).pathname)
    expect(files.get(storedPath)).toEqual(Buffer.from([1, 2, 3]))
    expect(lastAuth).toBe(`Basic ${Buffer.from('admin:pass').toString('base64')}`)

    const entries = await client.list(target)
    expect(entries.map(entry => entry.name)).toContain('00.10.00_视频.mp4~5x5.jpg')
  })

  it('创建中文/空格目录时不会重复百分号编码', async () => {
    mkcolPaths.length = 0
    const client = new WebDavClient(root(), 'admin', 'pass')
    const target = joinFolder(root(), '115', '测试 文件夹')
    await client.ensureTree(target, root())

    // 假服务器会把请求 pathname 解码一次，所以这里应看到原文而不是 %E6... / %25...
    expect(mkcolPaths).toContain('/dav/UC/cache/115/测试 文件夹/')
    expect(mkcolPaths.some(path => path.includes('%E6') || path.includes('%2520'))).toBe(false)
  })

  it('上传到不存在的目录时自动补建', async () => {
    const client = new WebDavClient(root(), 'admin', 'pass')
    const target = joinFolder(root(), '115', '新目录', '子目录')
    const fileUrl = joinFile(target, 'x.jpg')
    await client.put(fileUrl, new Uint8Array([9]).buffer, root())
    expect(files.get(decodeURIComponent(new URL(fileUrl).pathname))).toEqual(Buffer.from([9]))
  })

  it('目录不存在时返回空列表', async () => {
    const client = new WebDavClient(root(), 'admin', 'pass')
    await expect(client.list(`${root()}missing/`)).resolves.toEqual([])
  })

  it('strict 模式对缺失目录抛 404', async () => {
    const client = new WebDavClient(root(), 'admin', 'pass')
    await expect(
      client.list(`${root()}missing/`, { missingAsEmpty: false }),
    ).rejects.toMatchObject({ status: 404 })
  })
})
