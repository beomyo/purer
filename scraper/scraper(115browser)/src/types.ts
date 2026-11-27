import type { ExistingFlags } from './cacheName'

/** 生成模式 */
export type Mode = 'both' | 'sprite' | 'thumb'

/** 文件夹中的视频 */
export interface VideoItem {
  name: string
  pickCode: string
  duration: number
  /** 相对于所选处理文件夹的目录，根目录为空字符串 */
  relativeDir: string
}

/** 115 路径项 */
export interface PathItem {
  cid: string
  name: string
}

/** 行状态 */
export type RowStatus = 'pending' | 'running' | 'success' | 'skipped' | 'error'

/** 任务行 */
export interface Row {
  id: string
  name: string
  pickCode: string
  duration: number
  status: RowStatus
  message: string
  progress: number
  progressText: string
  existing: ExistingFlags
  effectiveMode: Mode | null
  /** 相对于所选处理文件夹的目录，根目录为空字符串 */
  relativeDir: string
  filename?: string
}

/** 失败记录 */
export interface FailureRecord {
  time: string
  name: string
  pickCode: string
  folder: string
  reason: string
  message: string
  /** 115 提供的时长（秒），用于重试时保持文件名前缀一致 */
  duration?: number
}
