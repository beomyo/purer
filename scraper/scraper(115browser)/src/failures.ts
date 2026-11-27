import { GM_getValue, GM_setValue } from '$'
import type { FailureRecord } from './types'

const FAILURES_KEY = 'THUMB_SCRAPER_FAILURES'
const MAX_FAILURES = 500

/** 读取失败记录 */
export function loadFailures(): FailureRecord[] {
  const value = GM_getValue<FailureRecord[]>(FAILURES_KEY, [])
  return Array.isArray(value) ? value : []
}

/** 保存失败记录 */
export function saveFailures(records: FailureRecord[]): void {
  GM_setValue(FAILURES_KEY, records.slice(-MAX_FAILURES))
}

/** 失败记录的唯一键：同一目录下的同一个视频只保留一条 */
function failureKey(record: Pick<FailureRecord, 'pickCode' | 'folder' | 'name'>): string {
  return `${record.folder}\u0000${record.pickCode || record.name}`
}

/** 追加或更新失败记录（同一目录下同一视频只保留最新一条） */
export function addFailure(record: FailureRecord): FailureRecord[] {
  const key = failureKey(record)
  const records = loadFailures().filter(item => failureKey(item) !== key)
  records.push(record)
  const trimmed = records.slice(-MAX_FAILURES)
  saveFailures(trimmed)
  return trimmed
}

/** 移除某个视频的失败记录（重试成功后调用） */
export function removeFailure(pickCode: string, folder: string, name = ''): FailureRecord[] {
  const records = loadFailures()
  const key = failureKey({ pickCode, folder, name })
  const next = records.filter(item => failureKey(item) !== key)
  if (next.length === records.length) {
    return records
  }
  saveFailures(next)
  return next
}

/** 清空失败记录 */
export function clearFailures(): void {
  saveFailures([])
}
