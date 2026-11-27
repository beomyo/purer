import { describe, expect, it } from 'vitest'
import {
  cacheBaseName,
  cacheNameMatchesVideo,
  createCacheLookup,
  findExisting,
  spriteFileName,
  thumbFileName,
} from '../cacheName'
import { formatGrid, parseGrid, spritePositions } from '../sprite'

describe('spritePositions', () => {
  it('在 10%–95% 区间均匀取点并包含两端', () => {
    expect(spritePositions(100, 5)).toEqual([10, 31.25, 52.5, 73.75, 95])
  })

  it('单帧时取区间中点', () => {
    expect(spritePositions(100, 1)).toEqual([52.5])
  })

  it('与 purer-scraper 的取点公式一致', () => {
    const positions = spritePositions(600, 25)
    expect(positions).toHaveLength(25)
    expect(positions[0]).toBeCloseTo(60)
    expect(positions[24]).toBeCloseTo(570)
  })
})

describe('parseGrid', () => {
  it('解析常见写法', () => {
    expect(parseGrid('5x5')).toEqual({ cols: 5, rows: 5 })
    expect(parseGrid('3X4')).toEqual({ cols: 3, rows: 4 })
    expect(parseGrid(' 5×5 ')).toEqual({ cols: 5, rows: 5 })
    expect(formatGrid({ cols: 3, rows: 4 })).toBe('3x4')
  })

  it('拒绝非法格子', () => {
    expect(() => parseGrid('1x1')).toThrow()
    expect(() => parseGrid('6x5')).toThrow()
    expect(() => parseGrid('abc')).toThrow()
  })
})

describe('缓存命名', () => {
  it('带时长前缀', () => {
    expect(cacheBaseName('vid.mp4', 600)).toBe('00.10.00_vid.mp4')
    expect(thumbFileName('vid.mp4', 600)).toBe('00.10.00_vid.mp4.jpg')
    expect(spriteFileName('vid.mp4', 600, { cols: 5, rows: 5 })).toBe('00.10.00_vid.mp4~5x5.jpg')
  })

  it('视频名本身已有前缀时不再叠加', () => {
    expect(cacheBaseName('00.10.00_vid.mp4', 600)).toBe('00.10.00_vid.mp4')
  })

  it('没有时长时不加前缀', () => {
    expect(cacheBaseName('vid.mp4', null)).toBe('vid.mp4')
  })

  it('匹配缓存文件名', () => {
    expect(cacheNameMatchesVideo('00.10.00_vid.mp4.jpg', 'vid.mp4')).toBe(true)
    expect(cacheNameMatchesVideo('00.10.00_vid.mp4~5x5.jpg', 'vid.mp4')).toBe(true)
    expect(cacheNameMatchesVideo('00.10.00_other.mp4.jpg', 'vid.mp4')).toBe(false)
    expect(cacheNameMatchesVideo('00.10.00_VID.MP4.jpg', 'vid.mp4')).toBe(true)
  })

  it('索引化查找与逐个查找结果一致', () => {
    const files = [
      '00.10.00_vid.mp4.jpg',
      '00.10.00_vid.mp4~5x5.jpg',
      '00.10.00_other.mp4~3x3.jpg',
    ]
    const grid = { cols: 5, rows: 5 }
    const lookup = createCacheLookup(files, grid)
    expect(lookup('vid.mp4')).toEqual(findExisting(files, 'vid.mp4', grid))
    expect(lookup('other.mp4')).toEqual(findExisting(files, 'other.mp4', grid))
    expect(lookup('missing.mp4')).toEqual({ sprite: false, thumb: false })
  })

  it('查找已有产物', () => {
    const grid = { cols: 5, rows: 5 }
    expect(findExisting(['00.10.00_vid.mp4~5x5.jpg'], 'vid.mp4', grid)).toEqual({ sprite: true, thumb: false })
    expect(findExisting(['00.10.00_vid.mp4~3x3.jpg'], 'vid.mp4', grid)).toEqual({ sprite: false, thumb: false })
    expect(findExisting(['00.10.00_vid.mp4.jpg'], 'vid.mp4', grid)).toEqual({ sprite: false, thumb: true })
    expect(findExisting(
      ['00.10.00_vid.mp4.jpg', '00.10.00_vid.mp4~5x5.jpg'],
      'vid.mp4',
      grid,
    )).toEqual({ sprite: true, thumb: true })
  })
})
