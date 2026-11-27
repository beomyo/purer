import { describe, expect, it } from 'vitest'
import { AccountVerifyError, NoHlsError, PlaylistRequestError } from '../api115'
import {
  buildRows,
  buildTargetFolder,
  effectiveModeFor,
  frameRetryTimes,
  isShortForSprite,
  reasonLabel,
  reasonOf,
  SPRITE_DURATION_THRESHOLD_SECONDS,
} from '../runner'
import { DEFAULT_SETTINGS } from '../settings'
import { parseSourceFolder } from '../sourceFolder'

const settings = {
  ...DEFAULT_SETTINGS,
  cacheRoot: 'http://host/dav/UC/cache/',
  sourcePrefix: '115',
  folderPath: 'Pack From Shared/獣会',
  mode: 'both' as const,
  skipExisting: true,
}

describe('buildTargetFolder', () => {
  it('镜像所选目录与相对子目录', () => {
    const url = buildTargetFolder(settings, '子目录/更多')
    expect(decodeURIComponent(url)).toBe(
      'http://host/dav/UC/cache/115/Pack From Shared/獣会/子目录/更多/',
    )
  })

  it('根目录不附加多余路径', () => {
    const url = buildTargetFolder(settings, '')
    expect(decodeURIComponent(url)).toBe(
      'http://host/dav/UC/cache/115/Pack From Shared/獣会/',
    )
  })

  it('地址里的 %20 只解码一次，不会把 %2520 写进缓存路径', () => {
    const source = parseSourceFolder('http://10.2.31.10/dav/115/Pack%20From%20Shared/', {
      sourceWebdavRoot: 'http://10.2.31.10/dav/115',
      sourcePrefix: '115',
    })
    expect(source.path).toBe('Pack From Shared')
    const url = buildTargetFolder({ ...settings, folderPath: source.path }, '')
    expect(url).not.toContain('%2520')
    expect(decodeURIComponent(url)).toBe(
      'http://host/dav/UC/cache/115/Pack From Shared/',
    )
  })

  it('从「要处理的 115 文件夹」地址直接镜像到缓存根', () => {
    const source = parseSourceFolder('http://10.2.31.10/dav/115/要处理的文件夹', {
      sourceWebdavRoot: 'http://10.2.31.10/dav/115',
      sourcePrefix: '115',
    })
    const url = buildTargetFolder(
      { ...settings, folderPath: source.path },
      '',
    )
    expect(decodeURIComponent(url)).toBe(
      'http://host/dav/UC/cache/115/要处理的文件夹/',
    )
  })
})

describe('buildRows', () => {
  it('按相对目录读取已有缓存', () => {
    const videos = [
      { name: 'a.mp4', pickCode: 'p1', duration: 400, relativeDir: 'sub' },
    ]
    const cacheByDir = new Map<string, string[]>([
      ['sub', ['00.10.00_a.mp4.jpg']],
    ])
    const rows = buildRows(videos, cacheByDir, settings)
    expect(rows[0]?.existing).toEqual({ sprite: false, thumb: true })
    expect(rows[0]?.effectiveMode).toBe('sprite')
    expect(rows[0]?.relativeDir).toBe('sub')
  })
})

describe('effectiveModeFor', () => {
  const existing = { sprite: false, thumb: false }

  it('both 需要两张图', () => {
    expect(effectiveModeFor('both', existing, true)).toBe('both')
    expect(effectiveModeFor('both', { sprite: true, thumb: false }, true)).toBe('thumb')
    expect(effectiveModeFor('both', { sprite: false, thumb: true }, true)).toBe('sprite')
    expect(effectiveModeFor('both', { sprite: true, thumb: true }, true)).toBeNull()
  })

  it('关闭跳过时始终按请求模式', () => {
    expect(effectiveModeFor('both', { sprite: true, thumb: true }, false)).toBe('both')
  })

  it('低于 300s 的视频只生成缩略图，不生成雪碧图', () => {
    expect(SPRITE_DURATION_THRESHOLD_SECONDS).toBe(300)
    expect(isShortForSprite(300)).toBe(false)
    expect(isShortForSprite(299)).toBe(true)
    expect(effectiveModeFor('both', existing, true, 299)).toBe('thumb')
    expect(effectiveModeFor('both', existing, false, 299)).toBe('thumb')
    expect(effectiveModeFor('sprite', existing, true, 299)).toBeNull()
    expect(effectiveModeFor('sprite', existing, false, 299)).toBeNull()
    expect(effectiveModeFor('thumb', existing, true, 299)).toBe('thumb')
    expect(effectiveModeFor('both', existing, true, 300)).toBe('both')
  })

  it('时长未知(0)时先按允许处理', () => {
    expect(effectiveModeFor('both', existing, true, 0)).toBe('both')
    expect(effectiveModeFor('sprite', existing, true, 0)).toBe('sprite')
  })

  it('阈值可以自定义，0 表示不限', () => {
    expect(isShortForSprite(299, 400)).toBe(true)
    expect(isShortForSprite(401, 400)).toBe(false)
    expect(isShortForSprite(10, 0)).toBe(false)
    expect(effectiveModeFor('both', existing, true, 400, 500)).toBe('thumb')
    expect(effectiveModeFor('sprite', existing, true, 600, 500)).toBe('sprite')
  })
})

describe('短视频任务行', () => {
  it('只生成雪碧图时，低于 300s 直接标记跳过', () => {
    const rows = buildRows(
      [{ name: 'short.mp4', pickCode: 'p1', duration: 200, relativeDir: '' }],
      new Map(),
      { ...settings, mode: 'sprite' },
    )
    expect(rows[0]?.status).toBe('skipped')
    expect(rows[0]?.effectiveMode).toBeNull()
    expect(rows[0]?.message).toContain('300s')
  })

  it('使用自定义阈值判断任务行', () => {
    const videos = [
      { name: 'a.mp4', pickCode: 'p1', duration: 200, relativeDir: '' },
      { name: 'b.mp4', pickCode: 'p2', duration: 600, relativeDir: '' },
    ]
    const rows = buildRows(videos, new Map(), {
      ...settings,
      mode: 'sprite',
      spriteMinDuration: 500,
    })
    expect(rows[0]?.status).toBe('skipped')
    expect(rows[0]?.message).toContain('500s')
    expect(rows[1]?.effectiveMode).toBe('sprite')

    const unlimited = buildRows(videos, new Map(), {
      ...settings,
      mode: 'sprite',
      spriteMinDuration: 0,
    })
    expect(unlimited.map(row => row.status)).toEqual(['pending', 'pending'])
  })

  it('雪碧图 + 缩略图时，低于 300s 只做缩略图', () => {
    const rows = buildRows(
      [{ name: 'short.mp4', pickCode: 'p1', duration: 200, relativeDir: '' }],
      new Map(),
      settings,
    )
    expect(rows[0]?.status).toBe('pending')
    expect(rows[0]?.effectiveMode).toBe('thumb')
  })
})

describe('取帧重试时间点', () => {
  it('原时间点优先，失败后换附近帧', () => {
    expect(frameRetryTimes(10, 100)).toEqual([10, 10.5, 9.5])
    expect(frameRetryTimes(10, 100, [0, 2, -2])).toEqual([10, 12, 8])
  })

  it('不越界、不重复', () => {
    expect(frameRetryTimes(0, 100)).toEqual([0, 0.5])
    expect(frameRetryTimes(100, 100)).toEqual([99.95, 99.5])
  })
})

describe('失败原因', () => {
  it('网络失败与无转码分开', () => {
    expect(reasonOf(new NoHlsError('x'))).toBe('no-hls')
    expect(reasonOf(new PlaylistRequestError('x'))).toBe('network')
  })

  it('原因代码有中文名', () => {
    expect(reasonLabel('no-hls')).toBe('未转码')
    expect(reasonLabel('network')).toBe('网络/授权失败')
    expect(reasonLabel('something-else')).toBe('something-else')
  })

  it('账号验证单独归类', () => {
    expect(reasonOf(new AccountVerifyError('请验证账号'))).toBe('verify')
    expect(reasonLabel('verify')).toContain('验证')
  })
})
