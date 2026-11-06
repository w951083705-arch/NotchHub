/**
 * dsh-agent-hud-approval
 *
 * 在 DSH 的 approval/request waterfall 上挂一个应答者：
 * 把请求通过 Unix socket 发给 Agent HUD（原生 macOS 窗口），
 * 用户在 HUD 上点 Allow once / Deny，结果原样返回给 DSH。
 *
 * 任何异常 / 超时都 fall through 到 next()，也就是回到 DSH 自带的审批 UI，
 * 所以这个插件挂上之后最坏情况 = 行为和没装一样，不会卡死。
 */
import net from 'node:net'
import { randomUUID } from 'node:crypto'

const DEFAULT_SOCKET = '/tmp/agenthud-approval.sock'

function askHud(payload, socketPath, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { socket.destroy() } catch {}
      resolve(value)
    }

    const socket = net.createConnection({ path: socketPath })
    const timer = setTimeout(() => finish(null), timeoutMs)
    let buffer = ''

    socket.setEncoding('utf8')
    socket.on('connect', () => {
      socket.write(JSON.stringify(payload) + '\n')
    })
    socket.on('data', (chunk) => {
      buffer += chunk
      if (Buffer.byteLength(buffer, 'utf8') > 65536) return finish(null)
      const nl = buffer.indexOf('\n')
      if (nl < 0) return
      try {
        const reply = JSON.parse(buffer.slice(0, nl))
        finish(reply.id === payload.id ? reply.decision ?? null : null)
      } catch {
        finish(null)
      }
    })
    socket.on('error', () => finish(null))
    socket.on('close', () => finish(null))
  })
}

export const name = 'agent-hud-approval'

export function apply(ctx, config = {}) {
  const socketPath = config.socket ?? DEFAULT_SOCKET
  const timeoutMs = Number.isFinite(config.timeoutMs) && config.timeoutMs > 0 ? config.timeoutMs : 120_000
  const enabled = config.enabled !== false
  if (!enabled) return

  ctx.on('approval/request', async (request, next) => {
    const decision = await askHud({
      id: randomUUID(),
      timeoutMs,
      tool: request.toolName ?? 'tool',
      command: typeof request.reason === 'string' ? request.reason : '',
      reason: request.displayReason?.zh ?? request.displayReason?.en ?? request.reason ?? '',
      agent: 'DSH',
    }, socketPath, timeoutMs)

    if (decision === 'allowed-once') return 'allowed-once'
    if (decision === 'rejected') return 'rejected'
    return next()
  })
}
