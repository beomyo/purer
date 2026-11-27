import { describe, expect, it } from 'vitest'
import { parseSourceFolder, SourceFolderError } from '../sourceFolder'

const options = {
  sourceWebdavRoot: 'http://10.2.31.10/dav/115',
  sourcePrefix: '115',
}

describe('parseSourceFolder', () => {
  it('从用户输入的 115 文件夹地址得到 WebDAV 地址与 115 内路径', () => {
    const target = parseSourceFolder('http://10.2.31.10/dav/115/要处理的文件夹', options)
    expect(target.path).toBe('要处理的文件夹')
    expect(target.url).toBe('http://10.2.31.10/dav/115/%E8%A6%81%E5%A4%84%E7%90%86%E7%9A%84%E6%96%87%E4%BB%B6%E5%A4%B9/')
  })

  it('保留多级相对路径并做 Unicode 解码', () => {
    const target = parseSourceFolder(
      'http://10.2.31.10/dav/115/Pack%20From%20Shared/%E7%8D%A3%E4%BC%9A',
      options,
    )
    expect(target.path).toBe('Pack From Shared/獣会')
  })

  it('115 挂载根本身对应空路径', () => {
    expect(parseSourceFolder('http://10.2.31.10/dav/115/', options).path).toBe('')
    expect(parseSourceFolder('http://10.2.31.10/dav/115', options).path).toBe('')
  })

  it('地址在别的域名下也能按挂载名定位', () => {
    const target = parseSourceFolder('http://nas.local/dav/115/要处理的文件夹/', options)
    expect(target.path).toBe('要处理的文件夹')
  })

  it('路径里没有挂载名时退回按源 115 根剥离', () => {
    const target = parseSourceFolder('http://10.2.31.10/dav/115-cloud/子目录', {
      sourceWebdavRoot: 'http://10.2.31.10/dav/115-cloud',
      sourcePrefix: '115',
    })
    expect(target.path).toBe('子目录')
  })

  it('空地址给出可操作的提示', () => {
    expect(() => parseSourceFolder('', options)).toThrow(SourceFolderError)
    expect(() => parseSourceFolder('', options)).toThrow(/请填写要处理的 115 文件夹地址/)
  })

  it('非 http 地址明确拒绝', () => {
    expect(() => parseSourceFolder('115/要处理的文件夹', options)).toThrow(/http:\/\//)
  })

  it('无法判断 115 内路径时报错，而不是退回根目录', () => {
    expect(() => parseSourceFolder('http://10.2.31.10/dav/other/子目录', options)).toThrow(
      SourceFolderError,
    )
  })
})
