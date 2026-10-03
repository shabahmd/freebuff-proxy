# Run freebuff-proxy from your home machine

**Why home?** Freebuff judges an account partly by its exit IP. A VPS/cloud IP is
a datacenter ASN, and datacenter IPs are the main reason accounts get banned.
Your home connection (PTCL broadband) is residential, so running the gateway at
home is the safe setup — **and you need no proxy at all**.

Result: an OpenAI-compatible endpoint at `http://127.0.0.1:8787/v1` that OpenCode
can use as a provider.

---

## Quick start

```bash
git clone https://github.com/HengXin666/freebuff-proxy.git
cd freebuff-proxy
./setup-freebuff.sh
```

The script installs, verifies, and tells you your exit IP. It is safe to re-run —
existing files are left alone.

**If it prints `STOP — this exit IP looks like a DATACENTER`, do not add your
Freebuff account.** That means you are not on a residential connection. It exits
with code `10`; the install itself still succeeded.

Options:

```bash
./setup-freebuff.sh --dry-run     # show the plan, change nothing
./setup-freebuff.sh --port 9000   # different port
./setup-freebuff.sh --dir ~/fb    # install elsewhere
```

### Requirements

Docker + Compose v2, x86_64 Linux:

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker "$USER"
newgrp docker        # or log out and back in
```

### What the script checks

1. Docker, Compose, disk space, port conflicts
2. Clones the repo (skips if present)
3. Creates `.env` with a generated admin password (**prints it once**)
4. Installs `bun` — verifies the download against a pinned SHA256
5. Adds the `bun` mount to `docker-compose.yml`
6. Pulls and starts the container, waits for healthy
7. Verifies `/healthz`, admin login, `/v1/models`
8. **Verifies `bun` actually executes inside the container** — see below
9. Checks your exit IP against known datacenter providers

---

## Then, in the console

Open `http://127.0.0.1:8787` and log in with the password the script printed.

> Not reachable from your browser and SSH'd in? Tunnel it:
> `ssh -L 8787:127.0.0.1:8787 <host>` then browse `http://127.0.0.1:8787`.

1. **代理设置** — save nothing. An empty box is correct. You are the exit; a proxy
   here would only add risk.
2. **总览 → ＋ 添加账号** — sign in to Freebuff in the browser. This runs in your
   browser over your home connection, so it looks like a normal sign-in.
3. **测试对话** — send one short message to confirm end to end.

Your API key (`sk-fb-...`) is under **用户管理**. That is what OpenCode
authenticates with.

---

## Point OpenCode at it

In `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "freebuff": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Freebuff (home)",
      "options": {
        "baseURL": "http://127.0.0.1:8787/v1",
        "apiKey": "sk-fb-..."
      },
      "models": {
        "deepseek/deepseek-v4-flash": { "name": "DeepSeek V4 Flash" },
        "mimo/mimo-v2.5": { "name": "MiMo v2.5" },
        "openai/gpt-5.6-luna": { "name": "GPT-5.6 Luna" }
      }
    }
  }
}
```

Model ids must match `/v1/models` exactly:

```bash
curl -s -H "Authorization: Bearer sk-fb-..." http://127.0.0.1:8787/v1/models
```

Restart OpenCode, then pick the provider from `/models`.

---

## Why `bun` is required

The gateway does not use Node for upstream calls. For the expensive `chat`
endpoint it hands the request to the **official client's own bun runtime**, so the
TLS Client Hello matches the real client instead of looking like a script. Their
reverse-engineering notes found Node and bun are distinguishable at the TLS
layer, and they chose alignment over spoofing.

The prebuilt image ships **without** this binary — it is 76MB and not in git — so
it must be supplied and mounted. The script does this automatically.

**Use the musl build.** The image is `node:22-alpine` (musl). A glibc `bun` — the
one inside the official Freebuff AppImage — cannot execute there:

```
$ docker run --rm -v ./appimage-bun:/b:ro <image> /b --version
su-exec: /b: No such file or directory
```

So the script fetches `bun-linux-x64-musl.zip` (bun 1.4.2) and mounts it at
`/app/cli-bridge/bun`, which is where `cli-bridge/bridge.mjs` looks.

Both builds produce an identical Client Hello, verified by JA3:

```
glibc (official AppImage)  JA3 5260242a2eb12c71995767c24569bff5  17 ciphers
musl (upstream 1.4.2)      JA3 5260242a2eb12c71995767c24569bff5  17 ciphers
```

Same ciphers, extensions, curves and ALPN — so the fingerprint-parity goal holds.
(JA3 covers version, ciphers, extensions, curves and point formats; it does not
cover key shares or signature algorithms.)

If you deliberately want the AppImage's glibc binary, you must fork the
Dockerfile onto a glibc base (`node:22-slim`) and replace `su-exec`. Not worth it
— the fingerprint is the same either way.

### The check people skip

`bridge.mjs` decides availability with `existsSync` only, so the service reports
**healthy even when `bun` cannot execute**. Every chat request then fails while
everything looks fine. The script therefore runs:

```bash
docker compose exec freebuff-proxy /app/cli-bridge/bun --version   # want: 1.4.2
```

Run that any time you are unsure.

---

## Cost awareness

- One upstream session `admit` **buys a full hour and is charged immediately**.
  Quota is consumed by the admit, not by how many messages you send.
- So a retry loop can burn a day's quota in a few requests. Test with one short
  message, not an agent loop.
- Each account allows roughly one concurrent stream.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bun did not run inside the container` | glibc binary in an alpine image — delete `cli-bridge/bun` and re-run the script |
| `cannot execute: required file not found` on the host | Expected: it is a musl binary and only needs to run in the container |
| Healthy, but chat requests fail | `bun` missing — rerun the version check above |
| `401 Invalid proxy API key` | Use the `sk-fb-…` key from 用户管理, not the admin password |
| `502` / upstream unreachable | Dead entry in 代理设置 — clear it |
| `STOP — this exit IP looks like a DATACENTER` | Not on a home connection. Do not add an account. |
| Container healthy, console won't load | Check `FREEBUFF_PROXY_HOST` |

---

## Security

`FREEBUFF_PROXY_HOST: 0.0.0.0` publishes the admin console on every interface. At
home that means your whole LAN. If you do not need LAN access, set it to
`127.0.0.1` in `docker-compose.yml` and use an SSH tunnel.

---

## Updating

```bash
git pull && docker compose pull && docker compose up -d
```

`bun` lives in `cli-bridge/bun`, which is not tracked by git, so it survives a
pull. If a future release pins a new bun version, re-run `./setup-freebuff.sh`
after deleting `cli-bridge/bun`.