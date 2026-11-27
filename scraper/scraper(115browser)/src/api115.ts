import type { PathItem, VideoItem } from './types'
import { gmRequest } from './gm'
import { promiseDelay } from './promise'

/** 115 网页 API */
const WEB_API = 'https://webapi.115.com'
/** 115 主站 */
const NORMAL_URL = 'https://115.com'

/** 与 purer-scraper 一致的视频扩展名 */
const VIDEO_EXT_RE = /\.(?:mp4|m4v|mkv|webm|mov|avi|wmv|flv|ts|m2ts|mpg|mpeg|3gp|3g2|ogv|m3u8)$/i

/** 115 没有转码播放列表 */
export class NoHlsError extends Error {
  constructor(
    message: string,
    readonly code?: number,
  ) {
    super(message)
    this.name = 'NoHlsError'
  }
}

/** 请求播放列表失败（网络/HTTP/CORS），与“没有转码”区分开，便于提示用户重试 */
export class PlaylistRequestError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'PlaylistRequestError'
  }
}

/** 原生 fetch 在当前网络下不可用的站点，后续直接走 GM 请求，避免每次多一次失败请求 */
const gmOnlyHosts = new Set<string>()

/** 记录某个 URL 的 host */
function hostOf(url: string): string {
  try {
    return new URL(url).host
  }
  catch {
    return url
  }
}

/** 列表接口的宽松类型 */
type RawItem = Record<string, any>

/** 文件名 */
function nameOf(raw: RawItem): string {
  return String(raw?.n ?? raw?.file_name ?? '')
}

/** pickcode */
function pickCodeOf(raw: RawItem): string {
  return String(raw?.pc ?? raw?.pick_code ?? '')
}

/**
 * 是否目录
 * @description 不同版本的 115 API 字段形态不一致：有的给 file_type，有的省略；
 * 有的目录带 cid 自身的 id，有的目录甚至也带 pickcode。按以下顺序判断：
 * 1. file_type 明确时直接采用；
 * 2. 目录自身的 cid 与当前父目录不同（文件条目的 cid 是父目录）；
 * 3. cate_id 只出现在目录上，文件用 fid；
 * 4. 有 sha（文件哈希）一定是文件；
 * 5. 兜底：没有 pickcode 的是目录。
 */
function isFolder(raw: RawItem, parentCid?: string): boolean {
  if (!nameOf(raw)) {
    return false
  }
  const type = raw?.file_type
  if (type === 0 || type === '0') {
    return true
  }
  if (type === 1 || type === '1') {
    return false
  }

  const cid = String(raw?.cid ?? '')
  const cateId = String(raw?.cate_id ?? '')
  const fid = String(raw?.fid ?? '')
  const pickCode = pickCodeOf(raw)

  if (cid && parentCid !== undefined && cid !== parentCid) {
    return true
  }
  if (cateId && !fid) {
    return true
  }
  if (raw?.sha) {
    return false
  }
  return !pickCode
}

/**
 * 目录 id
 * @description 优先采用「与父目录不同的 cid」（115 的目录自身 id）；
 * cid 就是父目录时退回 cate_id / fid。
 */
function folderIdOf(raw: RawItem, parentCid?: string): string {
  const cid = String(raw?.cid ?? '')
  const cateId = String(raw?.cate_id ?? '')
  const fid = String(raw?.fid ?? '')
  if (cid && (parentCid === undefined || cid !== parentCid)) {
    return cid
  }
  return cateId || cid || fid
}

/** 路径项 */
function pathItemsOf(response: any): PathItem[] {
  const rawPath = Array.isArray(response?.path) ? response.path : []
  return rawPath
    .map((item: any) => ({
      cid: String(item?.cid ?? ''),
      name: String(item?.name ?? ''),
    }))
    .filter((item: PathItem) => item.name)
}

/**
 * 读取 JSON；原生 fetch 失败（CORS 等）时回退到 GM 请求
 */
async function requestJson(url: string): Promise<any> {
  const host = hostOf(url)
  let firstError: unknown

  if (!gmOnlyHosts.has(host)) {
    try {
      const response = await fetch(url, { credentials: 'include' })
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }
      return await response.json()
    }
    catch (error) {
      firstError = error
      // HTTP 错误说明原生请求本身是通的；只有网络/CORS 类失败才记住这个 host
      if (!(error instanceof Error && /^HTTP \d+/.test(error.message))) {
        gmOnlyHosts.add(host)
      }
    }
  }

  try {
    const response = await gmRequest({ url, responseType: 'text', timeout: 30_000 })
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`HTTP ${response.status}`)
    }
    return JSON.parse(response.text)
  }
  catch {
    throw firstError ?? new Error('115 文件列表获取失败')
  }
}

/** 构造文件列表 URL */
function filesUrl(cid: string, type: number, showDir: number, offset: number, limit: number): string {
  const url = new URL('/files', WEB_API)
  const params: Record<string, string | number> = {
    aid: 1,
    cid,
    offset,
    limit,
    show_dir: showDir,
    nf: '',
    qid: 0,
    type,
    source: '',
    format: 'json',
    star: '',
    is_q: '',
    is_share: '',
    r_all: 1,
    o: 'user_ptime',
    asc: 1,
    cur: 1,
    snap: 0,
    natsort: 1,
  }
  Object.entries(params).forEach(([key, value]) => {
    url.searchParams.set(key, String(value))
  })
  return url.href
}

/** 读取一页文件列表 */
async function fetchFilesPage(
  cid: string,
  type: number,
  showDir: number,
  offset: number,
  limit: number,
): Promise<any> {
  const data = await requestJson(filesUrl(cid, type, showDir, offset, limit))
  if (data?.state === false) {
    throw new Error(data?.error || '115 文件列表获取失败')
  }
  return data
}

/** 115 目录中的一个条目（文件夹或文件） */
export interface Dir115Item {
  name: string
  pickCode: string
  isFolder: boolean
  folderId: string
  duration: number
}

/**
 * 逐页读取完整列表
 * @description 以服务端实际返回的条数推进 offset；如果响应带 count（总数）且还有剩余，
 * 即使单页比请求的 limit 小也继续翻页，避免服务端悄悄限制页大小时漏条目。
 */
/** 条目来源：folders 字段里的条目一定是目录 */
type EntrySource = 'data' | 'folders'

async function forEachFilesPage(
  cid: string,
  type: number,
  showDir: number,
  visit: (raw: RawItem, source: EntrySource) => void,
): Promise<PathItem[]> {
  const limit = 1000
  let offset = 0
  let path: PathItem[] = []

  for (let page = 0; page < 50; page++) {
    const response = await fetchFilesPage(cid, type, showDir, offset, limit)
    path = pathItemsOf(response)
    const data: RawItem[] = Array.isArray(response?.data) ? response.data : []

    for (const raw of data) {
      visit(raw, 'data')
    }

    // 某些 115 API 版本把目录单独放在 folders 里；这些条目即使带 pickcode 也一定是目录
    const folders: RawItem[] = Array.isArray(response?.folders) ? response.folders : []
    for (const raw of folders) {
      visit(raw, 'folders')
    }

    const total = Number(response?.count)
    const hasMoreByTotal = Number.isFinite(total) && total > 0 && offset + data.length < total
    if (data.length === 0 || (!hasMoreByTotal && data.length < limit)) {
      break
    }
    offset += data.length
  }

  return path
}

/**
 * 列出文件夹中的视频
 */
export async function listVideos(cid: string): Promise<{ path: PathItem[], videos: VideoItem[] }> {
  const videos: VideoItem[] = []
  const seen = new Set<string>()

  const path = await forEachFilesPage(cid, 4, 0, (raw) => {
    const name = nameOf(raw)
    const pickCode = pickCodeOf(raw)
    if (!name || !pickCode || !VIDEO_EXT_RE.test(name) || seen.has(pickCode)) {
      return
    }
    seen.add(pickCode)
    videos.push({
      name,
      pickCode,
      duration: Number(raw?.play_long ?? raw?.duration ?? 0) || 0,
      relativeDir: '',
    })
  })

  return { path, videos }
}

/**
 * 列出子文件夹（用于浏览选择）
 */
export async function listSubfolders(cid: string): Promise<{ path: PathItem[], folders: { id: string, name: string }[] }> {
  const folders: { id: string, name: string }[] = []
  const seen = new Set<string>()

  const path = await forEachFilesPage(cid, 0, 1, (raw, source) => {
    if (source !== 'folders' && !isFolder(raw, cid)) {
      return
    }
    const name = nameOf(raw)
    const id = folderIdOf(raw, cid)
    if (!name || !id || seen.has(id)) {
      return
    }
    seen.add(id)
    folders.push({ id, name })
  })

  return { path, folders }
}

/**
 * 列出一个 115 文件夹的全部条目（文件夹 + 文件）
 * @description 递归扫描时用一次请求同时拿到子文件夹和视频，靠名称与源 WebDAV 树匹配。
 */
export async function listDir(cid: string): Promise<{ path: PathItem[], items: Dir115Item[] }> {
  const items: Dir115Item[] = []
  const seen = new Set<string>()

  const path = await forEachFilesPage(cid, 0, 1, (raw, source) => {
    const name = nameOf(raw)
    if (!name) {
      return
    }
    const folder = source === 'folders' || isFolder(raw, cid)
    const pickCode = pickCodeOf(raw)
    const folderId = folder ? folderIdOf(raw, cid) : ''
    const key = folder ? `dir:${folderId || name}` : `file:${pickCode || name}`
    if (seen.has(key)) {
      return
    }
    seen.add(key)
    items.push({
      name,
      pickCode,
      isFolder: folder,
      folderId,
      duration: Number(raw?.play_long ?? raw?.duration ?? 0) || 0,
    })
  })

  return { path, items }
}

/**
 * 名称归一化
 * @description NFC + 把所有 Unicode 空白（含 NBSP、全角空格）折叠成单个半角空格，
 * 避免 WebDAV 与 115 API 对同一个名字的空白写法不同导致匹配失败。
 */
export function normalizeFolderName(name: string): string {
  return name
    .normalize('NFC')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** 再宽松一档：忽略全部空白并转小写，用于兜底匹配 */
function compactFolderName(name: string): string {
  return normalizeFolderName(name).replace(/\s+/g, '').toLowerCase()
}

/** 在文件夹列表里按名称查找 */
function matchFolder(
  folders: { id: string, name: string }[],
  name: string,
): { id: string, name: string } | undefined {
  const target = normalizeFolderName(name)
  return folders.find(folder => normalizeFolderName(folder.name) === target)
    ?? folders.find(folder => normalizeFolderName(folder.name).toLowerCase() === target.toLowerCase())
    ?? folders.find(folder => compactFolderName(folder.name) === compactFolderName(name))
}

/** cid 解析结果（带诊断信息） */
export interface CidResolution {
  /** 成功时为 cid；失败为 null */
  cid: string | null
  /** 已解析到的 API 路径（成功时为完整路径） */
  apiPath: string
  /** 失败时缺失的那一段 */
  failedSegment?: string
  /** 失败那一级 115 API 里实际存在的文件夹名（最多 20 个） */
  available?: string[]
  /** 失败那一级 115 API 返回的原始条目数（目录 + 文件） */
  entryCount?: number
  /** 失败那一级返回的条目名示例，便于判断账号/目录是否对应 */
  sampleEntries?: string[]
  /** 是否通过「路径后缀」在整棵目录树中定位到 */
  viaSuffixSearch?: boolean
}

/** 后缀搜索的边界，避免在大目录里无限遍历 */
const SUFFIX_SEARCH_MAX_FOLDERS = 400
const SUFFIX_SEARCH_MAX_DEPTH = 5

/** apiPath 是否以 names 结尾 */
function endsWithSegments(apiPath: string[], names: string[]): boolean {
  if (names.length === 0 || apiPath.length < names.length) {
    return false
  }
  const tail = apiPath.slice(apiPath.length - names.length)
  return tail.every((segment, index) => segment === names[index])
}

/**
 * 在整棵 115 目录树里查找「以给定路径结尾」的文件夹
 * @description 仅当精确路径解析失败时使用：WebDAV 挂载根可能只是 115 账号里的某个子目录，
 * 这时 API 里的真实路径会多出前缀。只有唯一匹配才返回，避免猜错目录。
 */
async function findCidByPathSuffix(names: string[]): Promise<{ cid: string, path: string } | null> {
  if (names.length === 0) {
    return null
  }
  const queue: { cid: string, path: string[], depth: number }[] = [
    { cid: '0', path: [], depth: 0 },
  ]
  const matches: { cid: string, path: string }[] = []
  let visited = 0

  while (queue.length > 0 && visited < SUFFIX_SEARCH_MAX_FOLDERS && matches.length < 2) {
    const node = queue.shift()!
    if (node.depth >= SUFFIX_SEARCH_MAX_DEPTH) {
      continue
    }
    let folders: { id: string, name: string }[]
    try {
      folders = (await listSubfolders(node.cid)).folders
    }
    catch {
      // 单个目录读失败不影响其他分支
      continue
    }
    for (const folder of folders) {
      visited++
      const childPath = [...node.path, normalizeFolderName(folder.name)]
      if (endsWithSegments(childPath, names)) {
        matches.push({ cid: folder.id, path: childPath.join('/') })
        if (matches.length >= 2) {
          break
        }
      }
      queue.push({ cid: folder.id, path: childPath, depth: node.depth + 1 })
      if (visited >= SUFFIX_SEARCH_MAX_FOLDERS) {
        break
      }
    }
  }

  return matches.length === 1 ? matches[0]! : null
}

/**
 * 按显示路径逐级解析出 115 的 cid，并在失败时给出诊断信息
 */
export async function resolveCidByPathDetailed(path: string): Promise<CidResolution> {
  const names = path
    .split('/')
    .map(normalizeFolderName)
    .filter(Boolean)

  let cid = '0'
  const resolved: string[] = []
  for (const name of names) {
    const { folders } = await listSubfolders(cid)
    const match = matchFolder(folders, name)
    if (!match) {
      const bySuffix = await findCidByPathSuffix(names)
      if (bySuffix) {
        return { cid: bySuffix.cid, apiPath: bySuffix.path, viaSuffixSearch: true }
      }
      // 失败时再读一次原始条目，区分「API 返回空」和「有内容但名字对不上」
      let entryCount: number | undefined
      let sampleEntries: string[] | undefined
      try {
        const { items } = await listDir(cid)
        entryCount = items.length
        sampleEntries = items.slice(0, 8).map(item => item.name)
      }
      catch {
        // 诊断信息拿不到不影响返回失败
      }
      return {
        cid: null,
        apiPath: resolved.join('/'),
        failedSegment: name,
        available: folders.slice(0, 20).map(folder => folder.name),
        entryCount,
        sampleEntries,
      }
    }
    cid = match.id
    resolved.push(name)
  }
  return { cid, apiPath: resolved.join('/') }
}

/**
 * 按显示路径逐级解析出 115 的 cid
 * @description 兼容旧调用方；失败返回 null。
 */
export async function resolveCidByPath(path: string): Promise<string | null> {
  return (await resolveCidByPathDetailed(path)).cid
}

/** 根目录探测中的单条示例 */
export interface RootProbeSample {
  name: string
  fileType: unknown
  cid: string
  cateId: string
  fid: string
  hasPickCode: boolean
  isFolder: boolean
}

/** 115 API 根目录探测结果 */
export interface RootProbe {
  entryCount: number
  folderCount: number
  /** data 字段的条目数 */
  dataCount: number
  /** folders 字段的条目数 */
  foldersCount: number
  /** 前几个条目，便于判断 API 到底看到了什么、为什么没被识别成目录 */
  sample: RootProbeSample[]
  /** 首条原始数据（截断），字段形态和预期不一致时用于排查 */
  rawSample: string
}

/**
 * 探测 115 API 的根目录
 * @description 用于测试连接：如果 WebDAV 有内容、但 API 根目录是空的，
 * 说明浏览器登录的 115 账号与 WebDAV 挂载不是同一份数据。
 */
export async function probeRootApi(cid = '0'): Promise<RootProbe> {
  const response = await fetchFilesPage(cid, 0, 1, 0, 500)
  const data: RawItem[] = Array.isArray(response?.data) ? response.data : []
  const folders: RawItem[] = Array.isArray(response?.folders) ? response.folders : []
  const entries = [...data, ...folders].filter(raw => !!nameOf(raw))

  return {
    entryCount: entries.length,
    folderCount:
      folders.length + data.filter(raw => isFolder(raw, cid)).length,
    dataCount: data.length,
    foldersCount: folders.length,
    sample: entries.slice(0, 5).map(raw => ({
      name: nameOf(raw),
      fileType: raw?.file_type,
      cid: String(raw?.cid ?? ''),
      cateId: String(raw?.cate_id ?? ''),
      fid: String(raw?.fid ?? ''),
      hasPickCode: !!pickCodeOf(raw),
      isFolder: folders.includes(raw) || isFolder(raw, cid),
    })),
    rawSample: entries.length > 0 ? JSON.stringify(entries[0]).slice(0, 600) : '',
  }
}

/** m3u8 主列表地址 */
export function masterUrl(pickCode: string): string {
  return new URL(`/api/video/m3u8/${encodeURIComponent(pickCode)}.m3u8`, NORMAL_URL).href
}

/** 播放列表请求重试间隔（毫秒）：403 多半是 115 的频率限制/临时风控 */
const PLAYLIST_RETRY_DELAYS = [800, 2000]

/** GM 请求播放列表时补上来源头，减少 115 的防盗链/风控误判 */
const PLAYLIST_HEADERS: Record<string, string> = {
  Referer: `${NORMAL_URL}/`,
  Origin: NORMAL_URL,
}

/** 播放列表频控冷却：出现 403/网络错误后，所有视频的播放列表请求一起等一等，避免并发重试继续触发风控 */
let playlistCooldownUntil = 0

/** 等待全局冷却结束 */
async function waitForPlaylistCooldown(): Promise<void> {
  const wait = playlistCooldownUntil - Date.now()
  if (wait > 0) {
    // 加一点随机抖动，避免多个视频冷却结束后同时打到 115
    await promiseDelay(wait + Math.floor(Math.random() * 300))
  }
}

/** 仅用于测试：清空播放列表频控冷却 */
export function resetPlaylistCooldown(): void {
  playlistCooldownUntil = 0
}

/** 115 返回的 JSON 错误里，这些字样说明是临时/授权问题，应该重试而不是当成未转码 */
const TRANSIENT_115_MESSAGE_RE = /登录|失效|过期|权限|禁止|频繁|过快|稍后|风控|too many|forbidden|unauthorized|timeout/i

/** 播放列表请求结果 */
interface PlaylistResponse {
  status: number
  text: string
}

/** 尝试从正文里解析 115 的 JSON 错误 */
function tryParseJson(text: string): any {
  try {
    return JSON.parse(text)
  }
  catch {
    return null
  }
}

/**
 * 发一次播放列表请求
 * @description 优先页面原生 fetch；失败/403 时回退 GM 请求。
 * 非 2xx 但正文是 JSON 时也保留下来，交给上层判断是「未转码」还是临时错误。
 */
async function requestPlaylist(url: string): Promise<PlaylistResponse> {
  await waitForPlaylistCooldown()
  let firstStatus = 0

  try {
    const response = await fetch(url, { credentials: 'include' })
    const text = await response.text()
    if (response.ok || text.trim().startsWith('{')) {
      return { status: response.status, text }
    }
    firstStatus = response.status
  }
  catch {
    // 原生请求失败（CORS/网络）时继续尝试 GM 请求
  }

  try {
    const response = await gmRequest({
      url,
      headers: PLAYLIST_HEADERS,
      responseType: 'text',
      timeout: 30_000,
    })
    if ((response.status >= 200 && response.status < 300) || response.text.trim().startsWith('{')) {
      return { status: response.status, text: response.text }
    }
    throw new Error(`HTTP ${response.status}`)
  }
  catch (error) {
    // 原生请求已经拿到明确的 HTTP 状态时，优先保留状态码
    if (firstStatus > 0) {
      throw new Error(`HTTP ${firstStatus}`)
    }
    throw error instanceof Error ? error : new Error(String(error))
  }
}

/**
 * 解释播放列表正文
 * @description 2xx 且是 m3u8 时直接返回；JSON 错误里区分「未转码」和可重试的临时错误。
 */
function interpretPlaylist(status: number, text: string): string {
  const trimmed = text.trim()
  const ok = status >= 200 && status < 300
  if (ok && trimmed.startsWith('#')) {
    return text
  }

  const data = tryParseJson(trimmed)
  if (data && data.state === false) {
    const message = String(data.error ?? data.msg ?? '115 未生成转码播放列表')
    if (TRANSIENT_115_MESSAGE_RE.test(message)) {
      throw new PlaylistRequestError(`HTTP ${status} ${message}`.trim())
    }
    throw new NoHlsError(message, Number(data.code) || undefined)
  }

  if (ok) {
    throw new NoHlsError('115 返回的不是播放列表')
  }
  throw new PlaylistRequestError(`HTTP ${status}`)
}

/** 播放列表失败是否值得再试 */
function isRetryablePlaylistError(error: unknown): boolean {
  if (error instanceof NoHlsError) {
    return false
  }
  if (error instanceof PlaylistRequestError) {
    // 正文明确提示登录失效/请求过快等临时问题时，无论 HTTP 码是多少都重试
    if (TRANSIENT_115_MESSAGE_RE.test(error.message)) {
      return true
    }
    const status = /HTTP (\d{3})/.exec(error.message)?.[1]
    if (status === undefined) {
      return true
    }
    const code = Number(status)
    return code === 0 || code === 403 || code === 408 || code === 425 || code === 429 || code >= 500
  }
  return true
}

/**
 * 读取 m3u8 主列表文本
 * @description 115 未转码时会返回 JSON 错误；这里转成 NoHlsError。
 * 403/429/5xx 或网络抖动会退避重试，避免一次频率限制就把整条视频判失败。
 */
export async function getMasterText(pickCode: string): Promise<string> {
  const url = masterUrl(pickCode)
  let lastError: unknown
  let attempts = 0

  for (let attempt = 0; attempt <= PLAYLIST_RETRY_DELAYS.length; attempt++) {
    attempts++
    try {
      const response = await requestPlaylist(url)
      return interpretPlaylist(response.status, response.text)
    }
    catch (error) {
      if (error instanceof NoHlsError) {
        throw error
      }
      lastError = error
      const delay = PLAYLIST_RETRY_DELAYS[attempt]
      if (delay === undefined || !isRetryablePlaylistError(error)) {
        break
      }
      // 让同一时间在跑的其他视频也一起退避，减少继续触发 115 频控
      playlistCooldownUntil = Math.max(playlistCooldownUntil, Date.now() + delay)
      await waitForPlaylistCooldown()
    }
  }

  const reason = lastError instanceof Error ? lastError.message : String(lastError)
  const retried = attempts > 1 ? `（已尝试 ${attempts} 次）` : ''
  // 115 对没有转码文件的视频会在 m3u8 接口返回 403；
  // 重试后仍是 403、且正文没有提示登录/频控时，按「未转码」处理
  if (/HTTP 403/.test(reason) && !TRANSIENT_115_MESSAGE_RE.test(reason)) {
    const detail = attempts > 1 ? `HTTP 403，已尝试 ${attempts} 次` : 'HTTP 403'
    throw new NoHlsError(`115 未生成转码播放列表（${detail}）`)
  }
  throw new PlaylistRequestError(`读取 115 播放列表失败：${reason}${retried}`)
}
