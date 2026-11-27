/** 与 purer-scraper / 手机 App 保持一致 */
export const SPRITE_START = 0.10
export const SPRITE_END = 0.95
export const MAX_SPRITE_FRAMES = 25

/** 格子 */
export interface Grid {
  cols: number
  rows: number
}

/** 解析 5x5 这类格子 */
export function parseGrid(text: string): Grid {
  const match = /^\s*(\d{1,2})\s*[x×]\s*(\d{1,2})\s*$/i.exec(text || '')
  if (!match) {
    throw new Error('格子格式应为 列x行，例如 5x5')
  }
  const cols = Number(match[1])
  const rows = Number(match[2])
  if (cols < 1 || rows < 1 || cols * rows < 2 || cols * rows > MAX_SPRITE_FRAMES) {
    throw new Error(`雪碧图总帧数必须在 2–${MAX_SPRITE_FRAMES} 之间`)
  }
  return { cols, rows }
}

/** 格式化格子 */
export function formatGrid(grid: Grid): string {
  return `${grid.cols}x${grid.rows}`
}

/**
 * 在视频 10%–95% 区间内均匀取 count 个时间点（含两端）
 */
export function spritePositions(duration: number, count: number): number[] {
  const start = duration * SPRITE_START
  const end = duration * SPRITE_END
  if (count <= 1) {
    return [(start + end) / 2]
  }
  const step = (end - start) / (count - 1)
  return Array.from({ length: count }, (_, index) => start + step * index)
}

/** 创建画布 */
function createCanvas(width: number, height: number): HTMLCanvasElement {
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(width))
  canvas.height = Math.max(1, Math.round(height))
  return canvas
}

/** 画布转 JPEG */
export function canvasToJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (blob) {
          resolve(blob)
        }
        else {
          reject(new Error('JPEG 编码失败'))
        }
      },
      'image/jpeg',
      quality,
    )
  })
}

/** 按比例缩小画布 */
function resizeCanvas(source: HTMLCanvasElement, scale: number): HTMLCanvasElement {
  const canvas = createCanvas(source.width * scale, source.height * scale)
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    throw new Error('无法创建 Canvas 上下文')
  }
  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(source, 0, 0, canvas.width, canvas.height)
  return canvas
}

/**
 * 编码 JPEG，并保证不超过 maxBytes
 */
export async function encodeJpegWithLimit(
  canvas: HTMLCanvasElement,
  maxBytes: number,
  qualities: number[] = [0.92, 0.85, 0.78, 0.7, 0.62],
): Promise<Blob> {
  let best: Blob | null = null

  for (const quality of qualities) {
    const blob = await canvasToJpeg(canvas, quality)
    if (!best || blob.size < best.size) {
      best = blob
    }
    if (blob.size <= maxBytes) {
      return blob
    }
  }

  let scale = 0.85
  // 尽量压到上限以内；0.1 倍仍超限时由调用方在任务行里提示
  while (scale >= 0.1) {
    const resized = resizeCanvas(canvas, scale)
    const blob = await canvasToJpeg(resized, 0.72)
    if (!best || blob.size < best.size) {
      best = blob
    }
    if (blob.size <= maxBytes) {
      return blob
    }
    scale *= 0.85
  }

  if (!best) {
    throw new Error('JPEG 编码失败')
  }
  return best
}

/**
 * 把多帧拼成雪碧图
 */
export async function composeSprite(
  frames: Array<ImageBitmap | undefined>,
  grid: Grid,
  maxBytes: number,
): Promise<Blob> {
  const usable = frames.filter((frame): frame is ImageBitmap => !!frame)
  if (usable.length === 0) {
    throw new Error('没有可拼接的帧')
  }

  const cellWidth = Math.max(...usable.map(frame => frame.width))
  const cellHeight = Math.max(...usable.map(frame => frame.height))
  const canvas = createCanvas(cellWidth * grid.cols, cellHeight * grid.rows)
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    throw new Error('无法创建 Canvas 上下文')
  }

  ctx.fillStyle = '#000'
  ctx.fillRect(0, 0, canvas.width, canvas.height)

  const total = grid.cols * grid.rows
  for (let index = 0; index < total; index++) {
    const frame = frames[index]
    if (!frame) {
      continue
    }
    const cellX = (index % grid.cols) * cellWidth
    const cellY = Math.floor(index / grid.cols) * cellHeight
    const dx = cellX + (cellWidth - frame.width) / 2
    const dy = cellY + (cellHeight - frame.height) / 2
    ctx.drawImage(frame, dx, dy, frame.width, frame.height)
  }

  return encodeJpegWithLimit(canvas, maxBytes)
}

/**
 * 把单帧编码成普通缩略图
 */
export async function composeThumbnail(frame: ImageBitmap, quality = 0.9): Promise<Blob> {
  const canvas = createCanvas(frame.width, frame.height)
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    throw new Error('无法创建 Canvas 上下文')
  }
  ctx.drawImage(frame, 0, 0)
  return canvasToJpeg(canvas, quality)
}
