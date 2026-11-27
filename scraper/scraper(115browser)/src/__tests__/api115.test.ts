import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  AccountVerifyError,
  getMasterText,
  isAccountVerifyMessage,
  listDir,
  listSubfolders,
  listVideos,
  NoHlsError,
  PlaylistRequestError,
  resetPlaylistCooldown,
  resolveCidByPath,
  resolveCidByPathDetailed,
} from '../api115'

function jsonResponse(data: unknown): any {
  return {
    ok: true,
    status: 200,
    json: async () => data,
    text: async () => JSON.stringify(data),
  }
}

function textResponse(text: string): any {
  return {
    ok: true,
    status: 200,
    json: async () => JSON.parse(text),
    text: async () => text,
  }
}

/** 带状态码的响应（GM 回退会读 arrayBuffer） */
function statusResponse(status: number, text: string): any {
  const buffer = new TextEncoder().encode(text).buffer
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => JSON.parse(text),
    text: async () => text,
    arrayBuffer: async () => buffer,
  }
}

afterEach(() => {
  resetPlaylistCooldown()
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('listVideos', () => {
  it('过滤非视频并保留时长', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [
        { cid: '0', name: '根目录' },
        { cid: '123', name: '测试' },
      ],
      data: [
        { n: 'a.mp4', pc: 'pc1', play_long: 600, file_type: 1 },
        { n: 'b.txt', pc: 'pc2', play_long: 0, file_type: 1 },
        { n: 'c.mkv', pc: 'pc3', play_long: '700', file_type: 1 },
      ],
    })))

    const result = await listVideos('123')
    expect(result.videos).toEqual([
      { name: 'a.mp4', pickCode: 'pc1', duration: 600, relativeDir: '' },
      { name: 'c.mkv', pickCode: 'pc3', duration: 700, relativeDir: '' },
    ])
    expect(result.path.map(item => item.name)).toEqual(['根目录', '测试'])
  })
})

describe('listDir', () => {
  it('同时返回文件夹和文件', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [{ cid: '0', name: '根目录' }],
      data: [
        { n: '子目录', file_type: 0, cate_id: '456' },
        { n: 'a.mp4', pc: 'pc1', play_long: 600, file_type: 1 },
        { n: 'b.txt', pc: 'pc2', file_type: 1 },
      ],
    })))

    const result = await listDir('0')
    expect(result.items).toEqual([
      { name: '子目录', pickCode: '', isFolder: true, folderId: '456', duration: 0 },
      { name: 'a.mp4', pickCode: 'pc1', isFolder: false, folderId: '', duration: 600 },
      { name: 'b.txt', pickCode: 'pc2', isFolder: false, folderId: '', duration: 0 },
    ])
  })
})

describe('listSubfolders', () => {
  it('识别 file_type=0 的目录', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [{ cid: '0', name: '根目录' }],
      data: [
        { n: '子目录', file_type: 0, cate_id: '456' },
        { n: 'a.mp4', pc: 'pc1', file_type: 1 },
      ],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '456', name: '子目录' }])
  })

  it('兼容只有 cid、没有 file_type/pickcode 的目录', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [{ n: '只有cid的目录', cid: '999' }],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '999', name: '只有cid的目录' }])
  })

  it('带 pickcode 的条目一律按文件处理，即使 file_type=0', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [{ n: 'a.mp4', pc: 'pc1', file_type: 0 }],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([])
  })

  it('data 里混排时：cid 与父目录不同的条目是目录', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [
        { n: 'Pack From Shared', cid: '10', pc: 'folder-pc' },
        { n: 'a.mp4', cid: '0', pc: 'pc1' },
      ],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '10', name: 'Pack From Shared' }])
  })

  it('目录同时带 cid 和 fid 时优先用 cid 作为目录 id', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [{ n: 'Movie', cid: '22', fid: 'f_folder', pc: 'folder-pc' }],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '22', name: 'Movie' }])
  })

  it('data 里混排时：cate_id 且没有 fid 的条目是目录', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [
        { n: 'Movie', cid: '0', cate_id: '11', pc: 'folder-pc' },
        { n: 'a.mp4', cid: '0', fid: 'f_1', pc: 'pc1' },
      ],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '11', name: 'Movie' }])
  })

  it('folders 字段里的目录即使带 pickcode 也按目录处理', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [{ n: 'a.mp4', pc: 'pc1' }],
      folders: [{ n: 'Pack From Shared', cid: '10', pc: 'folder-pc' }],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '10', name: 'Pack From Shared' }])
  })

  it('目录放在 folders 字段时也能读到', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [],
      folders: [{ n: 'Pack From Shared', cate_id: '10' }],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '10', name: 'Pack From Shared' }])
  })

  it('兼容缺失 file_type 但带 cate_id、没有 pickcode 的目录', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: true,
      path: [],
      data: [
        { n: '另一个目录', cate_id: '789' },
        { n: 'b.mp4', pc: 'pc2' },
      ],
    })))

    const result = await listSubfolders('0')
    expect(result.folders).toEqual([{ id: '789', name: '另一个目录' }])
  })
})

describe('路径与 cid 校正', () => {
  function folderResponse(cid: string): any {
    if (cid === '0') {
      return {
        state: true,
        path: [{ cid: '0', name: '根目录' }],
        data: [{ n: 'Pack From Shared', cate_id: '10', file_type: 0 }],
      }
    }
    if (cid === '10') {
      return {
        state: true,
        path: [{ cid: '0', name: '根目录' }, { cid: '10', name: 'Pack From Shared' }],
        data: [{ n: 'V_Uncensored', cate_id: '11', file_type: 0 }],
      }
    }
    return { state: true, path: [], data: [] }
  }

  it('按显示路径逐级反查 cid', async () => {
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL) => {
      const url = new URL(String(input))
      return jsonResponse(folderResponse(url.searchParams.get('cid') || '0'))
    }))

    await expect(resolveCidByPath('Pack From Shared')).resolves.toBe('10')
    await expect(resolveCidByPath('Pack From Shared/V_Uncensored')).resolves.toBe('11')
    await expect(resolveCidByPath('不存在的目录')).resolves.toBeNull()
  })

})

describe('列表请求参数', () => {
  it('与 115 网页一致：show_dir=1、snap=0、type=0', async () => {
    let requested = ''
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL) => {
      requested = String(input)
      return jsonResponse({ state: true, path: [], data: [] })
    }))

    await listSubfolders('0')
    expect(requested).toContain('show_dir=1')
    expect(requested).toContain('snap=0')
    expect(requested).toContain('type=0')
    expect(requested).toContain('cid=0')
  })
})

describe('resolveCidByPathDetailed', () => {
  function stubTree(tree: Record<string, { name: string, id: string }[]>): void {
    vi.stubGlobal('fetch', vi.fn(async (input: string | URL) => {
      const url = new URL(String(input))
      const cid = url.searchParams.get('cid') || '0'
      const folders = tree[cid] ?? []
      return jsonResponse({
        state: true,
        path: [],
        data: folders.map(folder => ({
          n: folder.name,
          file_type: 0,
          cate_id: folder.id,
        })),
      })
    }))
  }

  it('名字里的 NBSP/连续空格不影响匹配', async () => {
    stubTree({
      '0': [{ name: 'Pack\u00A0From  Shared', id: '10' }],
    })
    const result = await resolveCidByPathDetailed('Pack From Shared')
    expect(result.cid).toBe('10')
    expect(result.viaSuffixSearch).toBeUndefined()
  })

  it('精确路径找不到时，按路径后缀在整棵目录树里唯一定位', async () => {
    stubTree({
      '0': [{ name: 'Archive', id: '1' }],
      '1': [{ name: 'Pack From Shared', id: '10' }],
    })
    const result = await resolveCidByPathDetailed('Pack From Shared')
    expect(result).toMatchObject({
      cid: '10',
      apiPath: 'Archive/Pack From Shared',
      viaSuffixSearch: true,
    })
  })

  it('完全找不到时返回失败位置和该级已有目录名', async () => {
    stubTree({
      '0': [{ name: 'Videos', id: '1' }],
      '1': [],
    })
    const result = await resolveCidByPathDetailed('Missing')
    expect(result.cid).toBeNull()
    expect(result.failedSegment).toBe('Missing')
    expect(result.available).toEqual(['Videos'])
  })
})

describe('分页', () => {
  it('服务端页大小小于请求的 limit 时仍能读全', async () => {
    const all = Array.from({ length: 5 }, (_, index) => ({
      n: `v${index}.mp4`,
      pc: `pc${index}`,
      play_long: 600,
      file_type: 1,
    }))
    const fetchMock = vi.fn(async (input: string | URL) => {
      const url = new URL(String(input))
      const offset = Number(url.searchParams.get('offset'))
      // 服务端只给每页 2 条，但同时告诉我们总数是 5
      return jsonResponse({
        state: true,
        path: [],
        count: all.length,
        data: all.slice(offset, offset + 2),
      })
    })
    vi.stubGlobal('fetch', fetchMock)

    const result = await listVideos('0')
    expect(result.videos.map(video => video.name)).toEqual([
      'v0.mp4', 'v1.mp4', 'v2.mp4', 'v3.mp4', 'v4.mp4',
    ])
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })
})

describe('账号验证', () => {
  it('识别 115 的验证账号提示', () => {
    expect(isAccountVerifyMessage('请验证账号')).toBe(true)
    expect(isAccountVerifyMessage('请先完成身份验证')).toBe(true)
    expect(isAccountVerifyMessage('未转码')).toBe(false)
    expect(isAccountVerifyMessage('登录已失效')).toBe(false)
  })

  it('文件列表返回 state=false + 请验证账号 时抛出 AccountVerifyError', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      state: false,
      error: '请验证账号',
    })))
    await expect(listVideos('0')).rejects.toBeInstanceOf(AccountVerifyError)
  })

  it('HTTP 401 的正文提示验证账号时也抛出 AccountVerifyError，且不再回退请求', async () => {
    const fetchMock = vi.fn(async () => statusResponse(
      401,
      '{"state":false,"error":"请验证账号"}',
    ))
    vi.stubGlobal('fetch', fetchMock)
    await expect(listVideos('0')).rejects.toBeInstanceOf(AccountVerifyError)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('播放列表要求验证账号时不重试，直接抛 AccountVerifyError', async () => {
    const fetchMock = vi.fn(async () => textResponse(
      '{"state":false,"error":"请验证账号","code":401}',
    ))
    vi.stubGlobal('fetch', fetchMock)
    await expect(getMasterText('pc')).rejects.toBeInstanceOf(AccountVerifyError)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('getMasterText', () => {
  it('JSON state=false 转成 NoHlsError', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => textResponse(
      '{"state":false,"error":"未转码","code":911}',
    )))

    try {
      await getMasterText('pc')
      throw new Error('should fail')
    }
    catch (error) {
      expect(error).toBeInstanceOf(NoHlsError)
      expect((error as NoHlsError).code).toBe(911)
    }
  })

  it('返回播放列表文本', async () => {
    const text = '#EXTM3U\n#EXTINF:2,\nseg.ts\n'
    vi.stubGlobal('fetch', vi.fn(async () => textResponse(text)))
    await expect(getMasterText('pc')).resolves.toBe(text)
  })

  it('网络失败标记为 PlaylistRequestError 而不是无转码', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('fetch', vi.fn(async () => {
      throw new TypeError('Failed to fetch')
    }))
    const promise = getMasterText('pc')
    const expectation = expect(promise).rejects.toBeInstanceOf(PlaylistRequestError)
    await vi.advanceTimersByTimeAsync(1500)
    await vi.advanceTimersByTimeAsync(3000)
    await expectation
  })

  it('403 带「未转码」JSON 时直接归为 NoHlsError', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => statusResponse(
      403,
      '{"state":false,"error":"该视频未转码","code":911}',
    )))
    await expect(getMasterText('pc')).rejects.toBeInstanceOf(NoHlsError)
  })

  it('403 带临时错误 JSON 时退避重试，最终提示尝试次数', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('fetch', vi.fn(async () => statusResponse(
      403,
      '{"state":false,"error":"登录已失效"}',
    )))
    const promise = getMasterText('pc')
    const expectation = expect(promise).rejects.toThrow(/已尝试 3 次/)
    await vi.advanceTimersByTimeAsync(1500)
    await vi.advanceTimersByTimeAsync(3000)
    await expectation
  })

  it('重试后仍是 403 时归为未转码', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('fetch', vi.fn(async () => statusResponse(403, '')))
    const promise = getMasterText('pc')
    const expectation = expect(promise).rejects.toBeInstanceOf(NoHlsError)
    await vi.advanceTimersByTimeAsync(1500)
    await vi.advanceTimersByTimeAsync(3000)
    await expectation
    await expect(promise).rejects.toThrow(/HTTP 403/)
  })

  it('200 但正文提示请求过快时也会重试', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('fetch', vi.fn()
      .mockResolvedValueOnce(statusResponse(200, '{"state":false,"error":"请求过快"}'))
      .mockResolvedValueOnce(statusResponse(200, '#EXTM3U\n#EXTINF:2,\nseg.ts\n')))
    const promise = getMasterText('pc')
    await vi.advanceTimersByTimeAsync(1500)
    await expect(promise).resolves.toContain('#EXTM3U')
  })

  it('403 后重试成功时返回播放列表', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(statusResponse(403, ''))
      .mockResolvedValueOnce(statusResponse(403, ''))
      .mockResolvedValueOnce(statusResponse(200, '#EXTM3U\n#EXTINF:2,\nseg.ts\n'))
    vi.stubGlobal('fetch', fetchMock)
    const promise = getMasterText('pc')
    await vi.advanceTimersByTimeAsync(1500)
    await expect(promise).resolves.toContain('#EXTM3U')
  })
})
