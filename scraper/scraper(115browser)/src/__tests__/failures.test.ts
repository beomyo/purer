import type { FailureRecord } from '../types'
import { beforeEach, describe, expect, it } from 'vitest'
import { addFailure, clearFailures, loadFailures, removeFailure } from '../failures'

function record(overrides: Partial<FailureRecord> = {}): FailureRecord {
  return {
    time: '2026-11-26T12:00:00.000Z',
    name: 'a.mp4',
    pickCode: 'pc1',
    folder: 'Pack From Shared/V_Uncensored',
    reason: 'decode',
    message: '解码失败',
    ...overrides,
  }
}

beforeEach(() => {
  clearFailures()
})

describe('失败记录', () => {
  it('同一目录下同一个视频只保留最新一条', () => {
    addFailure(record({ reason: 'decode' }))
    addFailure(record({ reason: 'upload' }))

    const records = loadFailures()
    expect(records).toHaveLength(1)
    expect(records[0]?.reason).toBe('upload')
  })

  it('不同目录的同名视频分别保留', () => {
    addFailure(record())
    addFailure(record({ folder: 'Pack From Shared/V_Censord' }))
    expect(loadFailures()).toHaveLength(2)
  })

  it('重试成功后可以按 pickCode + 目录移除', () => {
    addFailure(record())
    addFailure(record({ pickCode: 'pc2', name: 'b.mp4' }))

    const next = removeFailure('pc1', 'Pack From Shared/V_Uncensored', 'a.mp4')
    expect(next).toHaveLength(1)
    expect(next[0]?.pickCode).toBe('pc2')
    expect(loadFailures()).toHaveLength(1)
  })

  it('没有 pickCode 时用名称作为键', () => {
    addFailure(record({ pickCode: '', name: 'no-pc.mp4' }))
    addFailure(record({ pickCode: '', name: 'no-pc.mp4', reason: 'network' }))
    expect(loadFailures()).toHaveLength(1)
    expect(loadFailures()[0]?.reason).toBe('network')
  })
})
