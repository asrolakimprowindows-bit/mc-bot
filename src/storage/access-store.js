const fs = require("fs");
const path = require("path");

const DIR = path.join(process.cwd(), "data");
const FILE = path.join(DIR, "access.json");

function load() {
  fs.mkdirSync(DIR, { recursive: true });
  if (!fs.existsSync(FILE)) {
    const fresh = { approved: {}, applications: {} };
    fs.writeFileSync(FILE, JSON.stringify(fresh, null, 2));
    return fresh;
  }
  return JSON.parse(fs.readFileSync(FILE, "utf8"));
}

function save(data) {
  fs.writeFileSync(FILE, JSON.stringify(data, null, 2));
}

class AccessStore {
  isApproved(uid) {
    const data = load();
    return !!data.approved[uid];
  }

  approve(uid) {
    const data = load();
    data.approved[uid] = { approvedAt: new Date().toISOString() };
    if (data.applications[uid]) data.applications[uid].status = "approved";
    save(data);
    return { ok: true, message: `✅ <@${uid}> approved. They can now use \`/mc start\`.` };
  }

  revoke(uid) {
    const data = load();
    delete data.approved[uid];
    save(data);
    return { ok: true, message: `✅ <@${uid}> access revoked.` };
  }

  addApplication(uid, discordTag) {
    const data = load();
    data.applications[uid] = { discordTag, status: "pending", appliedAt: new Date().toISOString() };
    save(data);
  }

  listApplications(status) {
    const data = load();
    return Object.entries(data.applications)
      .filter(([, a]) => !status || a.status === status)
      .map(([uid, a]) => ({ uid, ...a }));
  }
}

module.exports = { AccessStore };
