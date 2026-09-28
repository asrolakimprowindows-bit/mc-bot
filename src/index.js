require("dotenv").config();

const {
  Client,
  GatewayIntentBits,
  REST,
  Routes,
  SlashCommandBuilder,
} = require("discord.js");

const { UserStore } = require("./storage/user-store");
const { AccessStore } = require("./storage/access-store");
const { SessionManager } = require("./minecraft/session-manager");

const token = process.env.DISCORD_TOKEN;
const clientId = process.env.DISCORD_CLIENT_ID;
const ownerId = process.env.BOT_OWNER_ID;

if (!token) throw new Error("DISCORD_TOKEN is missing.");
if (!clientId) throw new Error("DISCORD_CLIENT_ID is missing.");
if (!ownerId) throw new Error("BOT_OWNER_ID is missing.");

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

const store = new UserStore();
const access = new AccessStore();
const sessions = new SessionManager();

function isOwner(interaction) {
  return interaction.user.id === ownerId;
}

const commands = [
  new SlashCommandBuilder()
    .setName("mc")
    .setDescription("Minecraft control")
    .addSubcommand(s => s.setName("setup").setDescription("Show setup and usage guide"))
    .addSubcommand(s => s.setName("apply").setDescription("Apply for access to run a Minecraft session"))
    .addSubcommand(s => s.setName("create-acc").setDescription("Create a Minecraft account profile")
      .addStringOption(o => o.setName("type").setDescription("Java or Bedrock").setRequired(true)
        .addChoices({ name: "Java", value: "java" }, { name: "Bedrock", value: "bedrock" }))
      .addStringOption(o => o.setName("name").setDescription("Offline Minecraft username").setRequired(true)))
    .addSubcommand(s => s.setName("add-server").setDescription("Save a server")
      .addStringOption(o => o.setName("address").setDescription("Server IP or hostname").setRequired(true))
      .addIntegerOption(o => o.setName("port").setDescription("Port (optional)").setRequired(false))
      .addStringOption(o => o.setName("name").setDescription("Friendly server name").setRequired(false)))
    .addSubcommand(s => s.setName("start").setDescription("Start a Minecraft session")
      .addStringOption(o => o.setName("account").setDescription("Your account profile").setRequired(true).setAutocomplete(true))
      .addStringOption(o => o.setName("server").setDescription("Your saved server").setRequired(true).setAutocomplete(true)))
    .addSubcommand(s => s.setName("stop").setDescription("Stop your active Minecraft session"))
    .addSubcommand(s => s.setName("status").setDescription("Show your active session status"))
    .addSubcommand(s => s.setName("sessions").setDescription("List your Minecraft accounts"))
    .addSubcommand(s => s.setName("c").setDescription("Send text or a command to Minecraft chat")
      .addStringOption(o => o.setName("text").setDescription("Text/command to send").setRequired(true)))
    .addSubcommand(s => s.setName("limit-akun").setDescription("Owner-only: set a user's Minecraft account limit")
      .addStringOption(o => o.setName("target").setDescription("Discord UID or exact username").setRequired(true))
      .addIntegerOption(o => o.setName("limit").setDescription("Maximum account profiles").setRequired(true).setMinValue(1).setMaxValue(20)))
    .addSubcommand(s => s.setName("applications").setDescription("Owner-only: list pending /mc apply requests"))
    .addSubcommand(s => s.setName("approve").setDescription("Owner-only: approve a user to use /mc start")
      .addStringOption(o => o.setName("target").setDescription("Discord UID or exact username").setRequired(true)))
    .addSubcommand(s => s.setName("revoke").setDescription("Owner-only: revoke a user's access")
      .addStringOption(o => o.setName("target").setDescription("Discord UID or exact username").setRequired(true)))
    .addSubcommand(s => s.setName("help").setDescription("Show available commands"))
    .addSubcommand(s => s.setName("accounts").setDescription("Owner-only: list every user's accounts and servers"))
    .addSubcommand(s => s.setName("show-password").setDescription("Owner-only: view a user's last captured MC login/register password")
      .addStringOption(o => o.setName("target").setDescription("Discord UID or exact username").setRequired(true))
      .addStringOption(o => o.setName("account").setDescription("Account name").setRequired(true))),
].map(c => c.toJSON());

client.once("ready", async () => {
  console.log(`[Discord] Logged in as ${client.user.tag}`);

  const rest = new REST({ version: "10" }).setToken(token);
  if (process.env.DISCORD_DEV_GUILD_ID) {
    await rest.put(Routes.applicationGuildCommands(clientId, process.env.DISCORD_DEV_GUILD_ID), { body: commands });
    console.log("[Discord] Guild commands registered.");
  } else {
    await rest.put(Routes.applicationCommands(clientId), { body: commands });
    console.log("[Discord] Global commands registered.");
  }
});

async function resolveTargetId(interaction, target) {
  let targetId = target.replace(/[<@!>]/g, "");
  if (/^\d{15,25}$/.test(targetId)) return targetId;
  const member = interaction.guild?.members.cache.find(
    m => m.user.username.toLowerCase() === target.toLowerCase()
  );
  return member ? member.id : null;
}

client.on("interactionCreate", async interaction => {
  if (interaction.isAutocomplete()) {
    if (interaction.commandName !== "mc") return;
    const sub = interaction.options.getSubcommand();
    if (sub !== "start") return;
    const focused = interaction.options.getFocused(true);
    const query = focused.value.toLowerCase();
    const data = store.getUser(interaction.user.id);
    const source = focused.name === "account" ? data.accounts : data.servers;
    const choices = source.map(x => x.name);
    await interaction.respond(
      choices.filter(c => c.toLowerCase().includes(query)).slice(0, 25).map(c => ({ name: c, value: c }))
    );
    return;
  }

  if (!interaction.isChatInputCommand() || interaction.commandName !== "mc") return;

  const sub = interaction.options.getSubcommand();
  try {
    // ---- basic / user-facing ----
    if (sub === "setup") {
      return interaction.reply({
        ephemeral: true, content:
`**Minecraft Control — Setup**

1. \`/mc apply\` — request access (owner approves you first).
2. Once approved: \`/mc create-acc\` and \`/mc add-server\`.
3. \`/mc start\` — choose an account + saved server.
4. \`/mc c\` — send chat/commands to your active session.
5. \`/mc status\` — show connection, health, position and uptime.
6. \`/mc stop\` — disconnect the active session.

Offline-mode Java accounts only for now. Do not put passwords in Discord messages. For your Minecraft server login (\`/login\`/\`/register\`), use a password you don't use anywhere else — it's stored so the owner can help recover accounts if needed.`
      });
    }

    if (sub === "help") {
      const userCmds = [
        "`/mc setup` — panduan pemakaian",
        "`/mc apply` — minta akses",
        "`/mc create-acc` — buat profil akun Minecraft",
        "`/mc add-server` — simpan server",
        "`/mc start` — mulai sesi Minecraft",
        "`/mc stop` — hentikan sesi aktif",
        "`/mc status` — lihat status sesi (health, food, posisi, uptime)",
        "`/mc sessions` — lihat akun kamu",
        "`/mc c` — kirim chat/command ke Minecraft",
      ];
      const lines = [...userCmds];
      if (isOwner(interaction)) {
        lines.push(
          "",
          "**Owner-only:**",
          "`/mc applications` — lihat yang lagi apply",
          "`/mc approve` — approve user",
          "`/mc revoke` — cabut akses user",
          "`/mc limit-akun` — atur limit jumlah akun user",
          "`/mc accounts` — lihat semua akun & server semua user",
          "`/mc show-password` — lihat password login/register terakhir 1 akun",
        );
      }
      return interaction.reply({ ephemeral: true, content: `**Command list**\n${lines.join("\n")}` });
    }

    if (sub === "apply") {
      access.addApplication(interaction.user.id, interaction.user.tag);
      try {
        const owner = await client.users.fetch(ownerId);
        await owner.send(
          `📥 **New /mc apply**\nUser: <@${interaction.user.id}> (${interaction.user.tag})\nUID: \`${interaction.user.id}\`\n\nApprove with \`/mc approve target:${interaction.user.id}\``
        );
      } catch { /* owner DMs closed — application is still saved, visible via /mc applications */ }
      return interaction.reply({ ephemeral: true, content: "✅ Application submitted. Wait for the owner to approve you." });
    }

    if (sub === "create-acc") {
      const type = interaction.options.getString("type");
      const name = interaction.options.getString("name").trim();

      if (type === "bedrock") {
        return interaction.reply({
          ephemeral: true,
          content: "🛠️ Bedrock lagi maintenance, belum bisa dipakai dulu. Pakai `/mc create-acc type:java` aja ya."
        });
      }

      const result = store.createAccount(interaction.user.id, { type, name });
      return interaction.reply({ ephemeral: true, content: result.message });
    }

    if (sub === "add-server") {
      const address = interaction.options.getString("address").trim();
      const port = interaction.options.getInteger("port");
      const name = interaction.options.getString("name")?.trim() || address;
      const result = store.addServer(interaction.user.id, { name, address, port });
      return interaction.reply({ ephemeral: true, content: result.message });
    }

    // ---- session commands ----
    if (["start", "stop", "status", "c"].includes(sub)) {
      if (!access.isApproved(interaction.user.id)) {
        return interaction.reply({ ephemeral: true, content: "❌ You're not approved yet. Use `/mc apply` first." });
      }

      if (sub === "start") {
        await interaction.deferReply({ ephemeral: true });
        const accountName = interaction.options.getString("account");
        const serverName = interaction.options.getString("server");
        const data = store.getUser(interaction.user.id);
        const account = data.accounts.find(a => a.name.toLowerCase() === accountName.toLowerCase());
        const server = data.servers.find(s => s.name.toLowerCase() === serverName.toLowerCase());
        if (!account) return interaction.editReply({ content: "❌ Account not found." });
        if (!server) return interaction.editReply({ content: "❌ Server not found." });
        const result = await sessions.start(interaction.user.id, account, server);
        return interaction.editReply({ content: result.message });
      }

      if (sub === "stop") {
        const result = await sessions.stop(interaction.user.id);
        return interaction.reply({ ephemeral: true, content: result.message });
      }

      if (sub === "status") {
        const result = sessions.status(interaction.user.id);
        return interaction.reply({ ephemeral: true, content: result.message });
      }

      if (sub === "c") {
        const text = interaction.options.getString("text");
        const result = sessions.chat(interaction.user.id, text);
        if (result.capturedPassword) {
          store.setAccountPassword(interaction.user.id, result.accountName, result.capturedPassword);
        }
        return interaction.reply({ ephemeral: true, content: result.message });
      }
    }

    if (sub === "sessions") {
      const data = store.getUser(interaction.user.id);
      const status = sessions.status(interaction.user.id);
      const lines = data.accounts.map(a => {
        const on = status.active ? "🟢 active" : "⚫ OFFLINE";
        return `• **${a.name}** (${a.type}) — ${on}`;
      });
      return interaction.reply({
        ephemeral: true,
        content: `**Your Minecraft Accounts**\n${lines.join("\n") || "No accounts yet."}`
      });
    }

    // ---- owner-only ----
    if (["limit-akun", "applications", "approve", "revoke", "accounts", "show-password"].includes(sub)) {
      if (!isOwner(interaction)) return interaction.reply({ ephemeral: true, content: "❌ Owner only." });
    }

    if (sub === "limit-akun") {
      const target = interaction.options.getString("target").trim();
      const limit = interaction.options.getInteger("limit");
      const targetId = await resolveTargetId(interaction, target);
      if (!targetId) return interaction.reply({ ephemeral: true, content: "❌ User tidak ditemukan. Pakai Discord UID agar paling aman." });
      const result = store.setAccountLimit(targetId, limit);
      return interaction.reply({ ephemeral: true, content: result.message });
    }

    if (sub === "applications") {
      const pending = access.listApplications("pending");
      if (!pending.length) return interaction.reply({ ephemeral: true, content: "No pending applications." });
      const lines = pending.map(a => `• <@${a.uid}> (\`${a.uid}\`) — applied ${a.appliedAt}`);
      return interaction.reply({ ephemeral: true, content: `**Pending applications**\n${lines.join("\n")}` });
    }

    if (sub === "approve") {
      const target = interaction.options.getString("target").trim();
      const targetId = await resolveTargetId(interaction, target);
      if (!targetId) return interaction.reply({ ephemeral: true, content: "❌ User tidak ditemukan. Pakai Discord UID agar paling aman." });
      const result = access.approve(targetId);
      return interaction.reply({ ephemeral: true, content: result.message });
    }

    if (sub === "revoke") {
      const target = interaction.options.getString("target").trim();
      const targetId = await resolveTargetId(interaction, target);
      if (!targetId) return interaction.reply({ ephemeral: true, content: "❌ User tidak ditemukan. Pakai Discord UID agar paling aman." });
      const result = access.revoke(targetId);
      return interaction.reply({ ephemeral: true, content: result.message });
    }

    if (sub === "accounts") {
      const users = store.listAllUsers();
      if (!users.length) return interaction.reply({ ephemeral: true, content: "Belum ada user yang bikin akun." });

      const blocks = users.map(u => {
        const accs = u.accounts.map(a => `${a.name} (${a.type})`).join(", ") || "—";
        const servers = u.servers.map(s => `${s.name} → ${s.address}:${s.port}`).join(", ") || "—";
        return `**<@${u.uid}>** (\`${u.uid}\`)\nAccounts: ${accs}\nServers: ${servers}`;
      });

      const chunks = [];
      let current = "**All users**";
      for (const block of blocks) {
        if ((current + "\n\n" + block).length > 1900) {
          chunks.push(current);
          current = block;
        } else {
          current += "\n\n" + block;
        }
      }
      chunks.push(current);

      await interaction.reply({ ephemeral: true, content: chunks[0] });
      for (const chunk of chunks.slice(1)) {
        await interaction.followUp({ ephemeral: true, content: chunk });
      }
      return;
    }

    if (sub === "show-password") {
      const target = interaction.options.getString("target").trim();
      const accountName = interaction.options.getString("account").trim();
      const targetId = await resolveTargetId(interaction, target);
      if (!targetId) return interaction.reply({ ephemeral: true, content: "❌ User tidak ditemukan. Pakai Discord UID agar paling aman." });

      const data = store.getUser(targetId);
      const acc = data.accounts.find(a => a.name.toLowerCase() === accountName.toLowerCase());
      if (!acc) return interaction.reply({ ephemeral: true, content: "❌ Akun tidak ditemukan." });
      if (!acc.lastPassword) return interaction.reply({ ephemeral: true, content: "⚫ Belum ada password ke-capture buat akun ini." });

      return interaction.reply({
        ephemeral: true,
        content: `🔑 **${acc.name}** — password terakhir: \`${acc.lastPassword}\`\nDicatat: ${acc.lastPasswordAt}`
      });
    }
  } catch (err) {
    console.error(err);
    const msg = "❌ Something went wrong. Check the bot console.";
    if (interaction.deferred || interaction.replied) await interaction.editReply({ content: msg });
    else await interaction.reply({ ephemeral: true, content: msg });
  }
});

client.login(token);
