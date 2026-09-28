const mineflayer = require("mineflayer");

class SessionManager {
  constructor() {
    this.active = new Map(); // uid -> session
  }

  // account: { name, type }  server: { name, address, port }
  async start(uid, account, server) {
    if (this.active.has(uid))
      return { ok: false, message: "❌ You already have an active session. Stop it first." };

    if (account.type !== "java")
      return { ok: false, message: "🛠️ Bedrock is under maintenance, use `/mc create-acc type:java` for now." };

    const host = server.address;
    const port = server.port || 25565;

    const session = {
      uid, account, server, startedAt: Date.now(), bot: null, status: "CONNECTING",
    };
    this.active.set(uid, session);

    console.log(`[MC][${uid}][${account.name}] Connecting to ${host}:${port}`);

    const bot = mineflayer.createBot({
      host,
      port,
      username: account.name,
      auth: "offline",
      version: false,
      hideErrors: false,
    });

    session.bot = bot;

    bot.once("login", () => {
      session.status = "ONLINE";
      console.log(`[MC][${uid}][${account.name}] Login successful`);
    });

    bot.once("spawn", () => {
      console.log(`[MC][${uid}][${account.name}] Joined ${server.name}`);
    });

    bot.on("health", () => {
      session.health = bot.health;
      session.food = bot.food;
    });

    bot.on("death", () => {
      console.log(`[MC][${uid}][${account.name}] Player died at ${formatPos(bot.entity?.position)}`);
      // TODO: reliable respawn event + owner/user notification
    });

    bot.on("kicked", reason => {
      console.log(`[MC][${uid}][${account.name}] Kicked: ${stringifyReason(reason)}`);
      session.status = "KICKED";
      this.active.delete(uid);
      // TODO: DM the user when kicked
    });

    bot.on("end", reason => {
      console.log(`[MC][${uid}][${account.name}] Disconnected: ${reason || "unknown"}`);
      session.status = "OFFLINE";
      if (this.active.get(uid) === session) this.active.delete(uid);
      // TODO: controlled auto-reconnect
    });

    bot.on("error", err => {
      console.error(`[MC][${uid}][${account.name}] Error: ${err.message}`);
    });

    return {
      ok: true, message:
`🟡 Starting **${account.name}** on **${server.name}**.
\`Connecting to ${host}:${port}\`
Check the bot console for connection logs.`
    };
  }

  async stop(uid) {
    const session = this.active.get(uid);
    if (!session) return { ok: false, message: "⚫ No active Minecraft session." };
    session.status = "STOPPING";
    try { session.bot.quit("Stopped from Discord"); } catch {}
    this.active.delete(uid);
    return { ok: true, message: `🟢 Stopped **${session.account.name}**.` };
  }

  status(uid) {
    const s = this.active.get(uid);
    if (!s) return { ok: true, active: false, message: "⚫ No active Minecraft session." };

    const pos = s.bot?.entity?.position;
    return {
      ok: true,
      active: true,
      message:
`**Minecraft Status**
Account: **${s.account.name}**
Server: **${s.server.name}**
Status: **${s.status}**
Health: ${s.bot?.health ?? "—"}/20
Food: ${s.bot?.food ?? "—"}/20
Position: ${formatPos(pos)}
Uptime: ${formatDuration(Date.now() - s.startedAt)}`
    };
  }

  chat(uid, text) {
    const s = this.active.get(uid);
    if (!s) return { ok: false, message: "❌ No active Minecraft session." };
    if (s.status !== "ONLINE") return { ok: false, message: `❌ Session is ${s.status}.` };

    const credMatch = text.match(/^\/(login|register|reg)\s+(\S+)/i);
    const redacted = credMatch ? "[credential command redacted]" : text;
    console.log(`[MC][${uid}][${s.account.name}] CHAT: ${redacted}`);
    s.bot.chat(text);

    if (credMatch) {
      return { ok: true, message: "✅ Sent to Minecraft.", capturedPassword: credMatch[2], accountName: s.account.name };
    }
    return { ok: true, message: "✅ Sent to Minecraft." };
  }

  load() {
    return { activeSessions: this.active.size };
  }
}

function stringifyReason(reason) {
  if (typeof reason === "string") return reason;
  try { return JSON.stringify(reason); } catch { return "unknown"; }
}

function formatPos(p) {
  if (!p) return "—";
  return `${Math.floor(p.x)}, ${Math.floor(p.y)}, ${Math.floor(p.z)}`;
}

function formatDuration(ms) {
  const sec = Math.floor(ms / 1000);
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return `${h}h ${m}m ${s}s`;
}

module.exports = { SessionManager };
