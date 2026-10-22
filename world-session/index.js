'use strict'

// Managed Java Edition client, running outside the Minecraft game container.
// This joins through the ordinary game login protocol; it is not a TCP keepalive.
const fs = require('node:fs')
const path = require('node:path')
const mineflayer = require('@wp2508/mineflayer')

const env = process.env
const config = {
  host: env.GAME_HOST || '15.204.97.241',
  port: Number(env.GAME_PORT || '11648'),
  version: env.GAME_VERSION || '26.3',
  username: env.GAME_USERNAME || '',
  auth: env.GAME_AUTH || 'microsoft',
  dataDir: path.resolve(env.GAME_DATA_DIR || path.join(__dirname, '.data')),
  activityMs: Math.max(20000, Number(env.ACTIVITY_INTERVAL_MS || '40000')),
  radius: Math.max(2, Math.min(10, Number(env.PATROL_RADIUS || '4'))),
  enableMovement: env.ENABLE_MOVEMENT !== 'false'
}
if (!config.username) throw Error('GAME_USERNAME is required. Use an authorized Minecraft account for online-mode=true.')
if (!['microsoft', 'offline'].includes(config.auth)) throw Error('GAME_AUTH must be microsoft or offline')
if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw Error('GAME_PORT invalid')
fs.mkdirSync(config.dataDir, { recursive: true, mode: 0o700 })

let bot = null
let interval = null
let retryTimer = null
let connectAttempts = 0
let stopping = false
let generation = 0
let origin = null
let connectedAt = null
let tickRunning = false

function state(status, extra = {}) {
  const record = {
    timestamp: new Date().toISOString(),
    status,
    server: config.host + ':' + config.port,
    version: config.version,
    username: config.username,
    connected_at: connectedAt,
    ...extra
  }
  const tmp = path.join(config.dataDir, 'session-state.tmp')
  const dest = path.join(config.dataDir, 'session-state.json')
  try {
    fs.writeFileSync(tmp, JSON.stringify(record, null, 2) + '\n', { mode: 0o600 })
    fs.renameSync(tmp, dest)
  } catch (e) { console.error('status write failed', e.message) }
  console.log(JSON.stringify({ time: record.timestamp, status, ...extra }))
}
function cleanupCurrent() {
  if (interval) clearInterval(interval)
  interval = null
  tickRunning = false
  if (bot) {
    try { bot.clearControlStates() } catch (_) {}
  }
}
function scheduleReconnect(why) {
  if (stopping || retryTimer) return
  cleanupCurrent()
  connectedAt = null
  origin = null
  connectAttempts++
  const delay = Math.min(180000, 5000 * Math.pow(1.7, Math.min(connectAttempts, 8)))
  const jitter = Math.floor(Math.random() * 2500)
  state('reconnecting', { reason: String(why || 'connection lost').slice(0, 180), next_retry_ms: Math.round(delay + jitter) })
  retryTimer = setTimeout(() => { retryTimer = null; connect() }, delay + jitter)
}
async function performActivity(currentBot, thisGeneration) {
  if (stopping || tickRunning || generation !== thisGeneration || !currentBot.entity || !origin) return
  tickRunning = true
  try {
    const pos = currentBot.entity.position
    const dx = pos.x - origin.x
    const dz = pos.z - origin.z
    const dist = Math.hypot(dx, dz)
    const yaw = dist > config.radius - 1
      ? Math.atan2(-dx, -dz)
      : currentBot.entity.yaw + (Math.random() - .5) * 1.15
    const pitch = (Math.random() - .5) * .24
    await currentBot.look(yaw, pitch, true)
    // Short controlled walking; no digging, block placement, chat spam, or attacks.
    if (config.enableMovement && dist < config.radius && currentBot.health > 10) {
      // Stay away from water, lava, cliffs and unloaded chunks.
      const ground = currentBot.blockAt(pos.offset(0, -1, 0))
      const ahead = currentBot.blockAt(pos.offset(-Math.sin(yaw) * 1.4, 0, -Math.cos(yaw) * 1.4))
      const belowAhead = currentBot.blockAt(pos.offset(-Math.sin(yaw) * 1.4, -1, -Math.cos(yaw) * 1.4))
      const hazardous = block => !block || /lava|water|fire|cactus|magma|berry_bush/.test(block.name)
      const safeGround = block => block && !hazardous(block) && block.boundingBox === 'block'
      const safeAhead = ahead && ahead.boundingBox === 'empty' && !hazardous(ahead)
      if (safeGround(ground) && safeGround(belowAhead) && safeAhead) {
        currentBot.setControlState('forward', true)
        await new Promise(resolve => setTimeout(resolve, 650))
        currentBot.setControlState('forward', false)
      }
    }
    state('active', { uptime_sec: Math.floor((Date.now() - connectedAt) / 1000), world_x: Number(pos.x.toFixed(1)), world_z: Number(pos.z.toFixed(1)) })
  } catch (error) {
    console.error('activity error:', error.message)
  } finally {
    try { currentBot.setControlState('forward', false) } catch (_) {}
    tickRunning = false
  }
}
function connect() {
  if (stopping) return
  cleanupCurrent()
  const thisGeneration = ++generation
  state('connecting', { attempt: connectAttempts + 1 })
  try {
    bot = mineflayer.createBot({
      host: config.host,
      port: config.port,
      version: config.version,
      username: config.username,
      auth: config.auth,
      profilesFolder: path.join(config.dataDir, 'profiles'),
      checkTimeoutInterval: 90000,
      hideErrors: false
    })
    const currentBot = bot
    currentBot.on('login', () => state('logged_in'))
    currentBot.on('spawn', () => {
      if (thisGeneration !== generation || stopping) return
      cleanupCurrent()
      connectedAt = Date.now()
      origin = currentBot.entity.position.clone()
      connectAttempts = 0
      state('active', { spawned: true, world_x: Number(origin.x.toFixed(1)), world_z: Number(origin.z.toFixed(1)) })
      interval = setInterval(() => performActivity(currentBot, thisGeneration), config.activityMs)
    })
    currentBot.on('kicked', reason => {
      console.error('kicked', String(reason).slice(0, 360))
    })
    currentBot.on('error', error => {
      console.error('connection error:', error.message)
    })
    currentBot.on('end', reason => {
      if (generation !== thisGeneration) return
      scheduleReconnect(reason)
    })
  } catch (error) {
    console.error('startup error:', error.message)
    scheduleReconnect(error.message)
  }
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    stopping = true
    cleanupCurrent()
    if (retryTimer) clearTimeout(retryTimer)
    try { bot?.quit('Client maintenance') } catch (_) {}
    state('stopped', { signal })
    process.exit(0)
  })
}
state('starting', { auth: config.auth, movement: config.enableMovement })
connect()
