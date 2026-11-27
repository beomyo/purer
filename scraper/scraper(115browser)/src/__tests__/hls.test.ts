import { describe, expect, it } from 'vitest'
import { parseMasterPlaylist, parseMediaPlaylist } from '../hls'

describe('parseMasterPlaylist', () => {
  it('解析变体并按带宽排序输入', () => {
    const text = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1000000,NAME="HD"
hd.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=300000,NAME="SD"
sd.m3u8
`
    const variants = parseMasterPlaylist(text, 'https://example.com/a/master.m3u8')
    expect(variants).toHaveLength(2)
    expect(variants[0]).toEqual({
      url: 'https://example.com/a/hd.m3u8',
      bandwidth: 1000000,
      name: 'HD',
    })
    expect(variants[1]?.bandwidth).toBe(300000)
  })

  it('媒体播放列表没有变体', () => {
    const text = '#EXTM3U\n#EXTINF:2,\nseg.ts\n'
    expect(parseMasterPlaylist(text, 'https://example.com/a/x.m3u8')).toEqual([])
  })
})

describe('parseMediaPlaylist', () => {
  it('累计时间戳', () => {
    const text = `#EXTM3U
#EXT-X-VERSION:3
#EXTINF:2.5,
seg0.ts
#EXTINF:3.0,
seg1.ts
`
    const media = parseMediaPlaylist(text, 'https://example.com/a/media.m3u8')
    expect(media.duration).toBe(5.5)
    expect(media.segments).toEqual([
      {
        url: 'https://example.com/a/seg0.ts',
        duration: 2.5,
        timestamp: 0,
        endTime: 2.5,
      },
      {
        url: 'https://example.com/a/seg1.ts',
        duration: 3,
        timestamp: 2.5,
        endTime: 5.5,
      },
    ])
    expect(media.encrypted).toBe(false)
    expect(media.hasMap).toBe(false)
    expect(media.hasByteRange).toBe(false)
  })

  it('识别 fMP4、加密和 BYTERANGE', () => {
    const text = `#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXT-X-MAP:URI="init.mp4"
#EXT-X-BYTERANGE:100@0
#EXTINF:2,
seg.m4s
`
    const media = parseMediaPlaylist(text, 'https://example.com/a/media.m3u8')
    expect(media.encrypted).toBe(true)
    expect(media.hasMap).toBe(true)
    expect(media.hasByteRange).toBe(true)
  })

  it('METHOD=NONE 不算加密', () => {
    const text = '#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:2,\nseg.ts\n'
    expect(parseMediaPlaylist(text, 'https://example.com/a/m.m3u8').encrypted).toBe(false)
  })
})
