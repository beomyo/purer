import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { initUi } from '../ui'

beforeEach(() => {
  document.body.innerHTML = ''
  vi.useFakeTimers()
})

afterEach(() => {
  vi.clearAllTimers()
  vi.useRealTimers()
  document.body.innerHTML = ''
})

describe('UI 初始化', () => {
  it('创建面板、主要控件和新按钮', () => {
    initUi()

    expect(document.getElementById('ts-root')).not.toBeNull()
    const ids = [
      'ts-launcher',
      'ts-overlay',
      'ts-start',
      'ts-scan',
      'ts-cancel',
      'ts-retry-failures',
      'ts-source-folder',
      'ts-sprite-min',
      'ts-browse-folder',
      'ts-picker',
      'ts-picker-content',
      'ts-test',
      'ts-rows',
      'ts-log-list',
      'ts-failures-list',
      'ts-count-notranscode',
      'ts-output-counts',
    ]
    for (const id of ids) {
      expect(document.getElementById(id), `缺少 #${id}`).not.toBeNull()
    }

    // 雪碧图最短时长默认 300s
    expect((document.getElementById('ts-sprite-min') as HTMLInputElement).value).toBe('300')

    // 日志成功分类与缩略图/雪碧图分开统计
    const successTab = document.querySelector<HTMLElement>('[data-log-tab="success"]')
    expect(successTab?.textContent).toContain('成功')
    expect(successTab?.textContent).not.toContain('成果')
    expect(document.getElementById('ts-output-counts')?.textContent).toContain('缩略图成功')
    expect(document.getElementById('ts-output-counts')?.textContent).toContain('雪碧图成功')

    // 没有失败记录时重试按钮应禁用
    expect((document.getElementById('ts-retry-failures') as HTMLButtonElement).disabled).toBe(true)
  })

  it('输入 115 文件夹地址后目标直接镜像到缓存根', () => {
    initUi()

    const input = document.getElementById('ts-source-folder') as HTMLInputElement
    input.value = 'http://10.2.31.10/dav/115/要处理的文件夹'
    input.dispatchEvent(new Event('input'))

    const target = document.getElementById('ts-target')
    expect(target?.textContent).toContain(
      'http://10.2.31.10/dav/UC/cache/115/要处理的文件夹/',
    )
  })

  it('不会重复注入面板', () => {
    initUi()
    initUi()
    expect(document.querySelectorAll('#ts-root')).toHaveLength(1)
  })
})
