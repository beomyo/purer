/** 极简日志，保留 clipper 需要的接口 */
export interface Logger {
  debug: (...args: unknown[]) => void
  info: (...args: unknown[]) => void
  warn: (...args: unknown[]) => void
  error: (...args: unknown[]) => void
  clearLogs: () => void
  printLogsUsingTable: (...args: unknown[]) => void
  enableSilentMode: () => void
  sub: (name: string) => Logger
}

class LoggerImpl implements Logger {
  private silent = false

  constructor(private readonly name: string) {}

  private prefix(): string {
    return `[${this.name}]`
  }

  debug(...args: unknown[]): void {
    if (!this.silent) {
      console.debug(this.prefix(), ...args)
    }
  }

  info(...args: unknown[]): void {
    if (!this.silent) {
      console.info(this.prefix(), ...args)
    }
  }

  warn(...args: unknown[]): void {
    if (!this.silent) {
      console.warn(this.prefix(), ...args)
    }
  }

  error(...args: unknown[]): void {
    if (!this.silent) {
      console.error(this.prefix(), ...args)
    }
  }

  clearLogs(): void {}

  printLogsUsingTable(...args: unknown[]): void {
    if (!this.silent && typeof console.table === 'function') {
      console.table(args)
    }
  }

  enableSilentMode(): void {
    this.silent = true
  }

  sub(name: string): Logger {
    const logger = new LoggerImpl(`${this.name}:${name}`)
    logger.silent = this.silent
    return logger
  }
}

export const appLogger: Logger = new LoggerImpl('Thumb')
