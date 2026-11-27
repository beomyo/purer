import type { Dir115Item } from '../api115'
import type { DavEntry, WebDavClient } from '../webdav'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_SETTINGS } from '../settings'

const { listDirMock } = vi.hoisted(() => ({
  listDirMock: vi.fn(),
}))

vi.mock('../api115', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api115')>()
  return {
    ...actual,
    listDir: listDirMock,
  }
})

import { collectVideos } from '../collector'

function folder(name: string, folderId: string): Dir115Item {
  return { name, pickCode: '', isFolder: true, folderId, duration: 0 }
}

function video(name: string, pickCode: string, duration = 600): Dir115Item {
  return { name, pickCode, isFolder: false, folderId: '', duration }
}

function dav(name: string, url: string, isDir: boolean): DavEntry {
  return { name, url, isDir }
}

const settings = {
  ...DEFAULT_SETTINGS,
  folderPath: 'Pack From Shared/獣会',
  recursive: true,
  sourceWebdavRoot: 'http://10.2.31.10/dav/115',
}

beforeEach(() => {
  listDirMock.mockReset()
})

describe('collectVideos', () => {
  it('源 WebDAV 不可用时，按 115 目录递归', async () => {
    listDirMock.mockImplementation(async (cid: string) => {
      if (cid === 'root') {
        return {
          path: [],
          items: [folder('子目录', 'd1'), video('root.mp4', 'p1'), { name: 'x.txt', pickCode: 'p9', isFolder: false, folderId: '', duration: 0 }],
        }
      }
      if (cid === 'd1') {
        return { path: [], items: [folder('子目录2', 'd2'), video('a.mp4', 'p2')] }
      }
      return { path: [], items: [video('b.mp4', 'p3')] }
    })

    const videos = await collectVideos({ settings, startCid: 'root', sourceClient: null })
    expect(videos.map(item => `${item.relativeDir}|${item.name}`).sort()).toEqual([
      '|root.mp4',
      '子目录|a.mp4',
      '子目录/子目录2|b.mp4',
    ].sort())
    const byKey = Object.fromEntries(videos.map(item => [`${item.relativeDir}|${item.name}`, item.pickCode]))
    expect(byKey['|root.mp4']).toBe('p1')
    expect(byKey['子目录|a.mp4']).toBe('p2')
    expect(byKey['子目录/子目录2|b.mp4']).toBe('p3')
  })

  it('源 WebDAV 可用时，以它的目录树为准并用名称匹配 pickcode', async () => {
    listDirMock.mockImplementation(async (cid: string) => {
      if (cid === 'root') {
        return { path: [], items: [folder('子目录', 'd1'), video('root.mp4', 'p1')] }
      }
      return { path: [], items: [video('a.mp4', 'p2'), video('not-in-webdav.mp4', 'p3')] }
    })

    const sourceClient = {
      list: async (url: string): Promise<DavEntry[]> => {
        const decoded = decodeURIComponent(url)
        if (decoded.endsWith('/獣会/')) {
          return [
            dav('子目录', `${url}子目录/`, true),
            dav('root.mp4', `${url}root.mp4`, false),
            dav('ignore.txt', `${url}ignore.txt`, false),
          ]
        }
        return [dav('a.mp4', `${url}a.mp4`, false)]
      },
    } as unknown as WebDavClient

    const videos = await collectVideos({ settings, startCid: 'root', sourceClient })
    expect(videos.map(item => `${item.relativeDir}|${item.name}`).sort()).toEqual([
      '|root.mp4',
      '子目录|a.mp4',
    ].sort())
    const byKey = Object.fromEntries(videos.map(item => [`${item.relativeDir}|${item.name}`, item.pickCode]))
    expect(byKey['|root.mp4']).toBe('p1')
    expect(byKey['子目录|a.mp4']).toBe('p2')
  })

  it('115 列表失败时只跳过该文件夹，不逐条刷“找不到”', async () => {
    listDirMock.mockRejectedValue(new Error('115 不可用'))
    const sourceClient = {
      list: async (url: string): Promise<DavEntry[]> => [
        dav('V_Uncensored', `${url}V_Uncensored/`, true),
        dav('a.mp4', `${url}a.mp4`, false),
      ],
    } as unknown as WebDavClient

    const logs: string[] = []
    const videos = await collectVideos({
      settings,
      startCid: 'root',
      sourceClient,
      onLog: message => logs.push(message),
      onProgress: () => {},
    })

    expect(videos).toEqual([])
    expect(logs.some(message => message.includes('读取 115 目录失败'))).toBe(true)
    expect(logs.some(message => message.includes('已跳过该文件夹'))).toBe(true)
    expect(logs.some(message => message.includes('找不到子文件夹'))).toBe(false)
  })

  it('源 WebDAV 目录为空但 115 有内容时回退到 115 目录结构', async () => {
    listDirMock.mockImplementation(async (cid: string) => {
      if (cid === 'root') {
        return { path: [], items: [folder('子目录', 'd1'), video('root.mp4', 'p1')] }
      }
      return { path: [], items: [video('a.mp4', 'p2')] }
    })
    const sourceClient = {
      list: async (): Promise<DavEntry[]> => [],
    } as unknown as WebDavClient

    const logs: string[] = []
    const videos = await collectVideos({
      settings,
      startCid: 'root',
      sourceClient,
      onLog: message => logs.push(message),
      onProgress: () => {},
    })

    expect(videos.map(item => item.name).sort()).toEqual(['a.mp4', 'root.mp4'])
    expect(logs.some(message => message.includes('源 WebDAV 目录为空'))).toBe(true)
  })

  it('源 WebDAV 与 115 目录完全不匹配时只报一条汇总', async () => {
    listDirMock.mockResolvedValue({
      path: [],
      items: [video('other.mp4', 'p1')],
    })
    const sourceClient = {
      list: async (url: string): Promise<DavEntry[]> => [
        dav('V_Uncensored', `${url}V_Uncensored/`, true),
        dav('V_Censord', `${url}V_Censord/`, true),
      ],
    } as unknown as WebDavClient

    const logs: string[] = []
    await collectVideos({
      settings,
      startCid: 'root',
      sourceClient,
      onLog: message => logs.push(message),
      onProgress: () => {},
    })

    expect(logs.filter(message => message.includes('完全不匹配'))).toHaveLength(1)
    expect(logs.some(message => message.includes('找不到'))).toBe(false)
  })

  it('优先使用填写的 115 文件夹地址作为起始扫描地址', async () => {
    listDirMock.mockResolvedValue({
      path: [],
      items: [video('a.mp4', 'p1')],
    })
    const urls: string[] = []
    const sourceClient = {
      list: async (url: string): Promise<DavEntry[]> => {
        urls.push(url)
        return [dav('a.mp4', `${url}a.mp4`, false)]
      },
    } as unknown as WebDavClient

    await collectVideos({
      settings: {
        ...settings,
        sourceFolder: 'http://host/dav/115/要处理的文件夹/',
      },
      startCid: 'root',
      sourceClient,
    })

    expect(decodeURIComponent(urls[0] ?? '')).toBe('http://host/dav/115/要处理的文件夹/')
  })

  it('递归关闭时只处理当前目录的文件', async () => {
    listDirMock.mockResolvedValue({
      path: [],
      items: [folder('子目录', 'd1'), video('root.mp4', 'p1')],
    })

    const videos = await collectVideos({
      settings: { ...settings, recursive: false },
      startCid: 'root',
      sourceClient: null,
    })
    expect(videos.map(item => item.name)).toEqual(['root.mp4'])
  })
})
