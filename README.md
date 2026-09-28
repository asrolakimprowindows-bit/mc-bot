# Minecraft Discord Bot — single process (VPS edition)

Back to one project, one process — no controller/worker split, no HTTP API
between them. This is the right shape now that everything runs on your own
VPS with enough RAM for several concurrent mineflayer sessions.

## Deploy

1. `npm install`
2. Copy `.env.example` to `.env`, fill in `DISCORD_TOKEN`, `DISCORD_CLIENT_ID`,
   `BOT_OWNER_ID` (your own Discord UID).
3. Run it, ideally under PM2 so it survives crashes/reboots:
   ```
   npm install -g pm2   # once
   pm2 start src/index.js --name mc-bot
   pm2 save
   pm2 startup          # follow the one printed command to enable on-boot
   ```

## Access flow

1. User runs `/mc apply` — owner gets a DM with their UID (also visible via
   `/mc applications`).
2. Owner runs `/mc approve target:<uid>`.
3. User can now `/mc create-acc`, `/mc add-server`, `/mc start`, `/mc c`,
   `/mc status`, `/mc stop`.
4. `/mc revoke target:<uid>` to take access back later.

## Owner tools

- `/mc help` — command list, expands with owner-only commands when the
  owner runs it.
- `/mc accounts` — every user's Minecraft account profiles and saved
  servers, in one place.
- `/mc show-password target:<uid> account:<name>` — shows the last
  password a user sent via `/login` or `/register` in Minecraft chat
  (`/mc c`). **Heads up:** this stores that password in plain text in
  `data/users/<uid>/profile.json`. People commonly reuse passwords, so
  treat this data like any other credential store — tell your users to
  pick something they don't use elsewhere for their in-game login.

## Notes

- One active Minecraft session per Discord UID at a time.
- Java offline-mode only — `/mc create-acc type:bedrock` is rejected with a
  maintenance message. Add Bedrock support later as its own module (it needs
  `bedrock-protocol`, a different protocol from mineflayer's Java support).
- Credential-bearing chat commands (`/login`, `/register`, `/reg`) are
  redacted from the console logs.
- Rough RAM budgeting on your VPS: ~100-250MB per active mineflayer session
  on top of a small Discord-bot base. With 12GB you have a lot of headroom,
  but keep an eye on it (`htop` / `pm2 monit`) as concurrent sessions grow.
