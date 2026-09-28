const fs = require("fs");
const path = require("path");

const ROOT = path.join(process.cwd(), "data", "users");

function safeName(name) {
  return name.replace(/[^a-zA-Z0-9_.-]/g, "_").slice(0, 32);
}

class UserStore {
  constructor() {
    fs.mkdirSync(ROOT, { recursive: true });
  }

  file(uid) {
    const dir = path.join(ROOT, uid);
    fs.mkdirSync(dir, { recursive: true });
    return path.join(dir, "profile.json");
  }

  getUser(uid) {
    const f = this.file(uid);
    if (!fs.existsSync(f)) {
      const fresh = { accountLimit: 1, accounts: [], servers: [] };
      fs.writeFileSync(f, JSON.stringify(fresh, null, 2));
      return fresh;
    }
    const data = JSON.parse(fs.readFileSync(f, "utf8"));
    if (!Number.isInteger(data.accountLimit) || data.accountLimit < 1) data.accountLimit = 1;
    return data;
  }

  save(uid, data) {
    fs.writeFileSync(this.file(uid), JSON.stringify(data, null, 2));
  }

  createAccount(uid, account) {
    const data = this.getUser(uid);
    if (data.accounts.length >= data.accountLimit)
      return { ok: false, message: `❌ You reached your account limit (${data.accountLimit}).` };
    if (data.accounts.some(a => a.name.toLowerCase() === account.name.toLowerCase()))
      return { ok: false, message: "❌ That account name already exists in your session." };

    data.accounts.push({
      name: safeName(account.name),
      type: account.type,
      createdAt: new Date().toISOString(),
    });
    this.save(uid, data);
    return { ok: true, message: `✅ Created **${account.name}** (${account.type}).` };
  }

  setAccountLimit(uid, limit) {
    const data = this.getUser(uid);
    data.accountLimit = limit;
    this.save(uid, data);
    return { ok: true, message: `✅ Account limit for <@${uid}> is now **${limit}**.` };
  }

  addServer(uid, server) {
    const data = this.getUser(uid);
    if (data.servers.some(s => s.name.toLowerCase() === server.name.toLowerCase()))
      return { ok: false, message: "❌ A server with that name already exists." };

    const port = server.port ?? 25565;
    data.servers.push({
      name: safeName(server.name),
      address: server.address,
      port,
      createdAt: new Date().toISOString(),
    });
    this.save(uid, data);
    return { ok: true, message: `✅ Saved server **${server.name}** → \`${server.address}:${port}\`.` };
  }

  setAccountPassword(uid, accountName, password) {
    const data = this.getUser(uid);
    const acc = data.accounts.find(a => a.name.toLowerCase() === accountName.toLowerCase());
    if (!acc) return;
    acc.lastPassword = password;
    acc.lastPasswordAt = new Date().toISOString();
    this.save(uid, data);
  }

  listAllUsers() {
    if (!fs.existsSync(ROOT)) return [];
    return fs.readdirSync(ROOT, { withFileTypes: true })
      .filter(d => d.isDirectory())
      .map(d => ({ uid: d.name, ...this.getUser(d.name) }));
  }
}

module.exports = { UserStore };
