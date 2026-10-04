# KiroCrew + Tailscale (Docker, macOS/Linux)

> 🇰🇷 **한국어: [README.ko.md](README.ko.md)**

Run the KiroCrew gateway as a **headless Docker container**, with a Tailscale
sidecar so people on your tailnet can reach the dashboard by its MagicDNS name.

- Each instance = one `kirocrew-home` volume = its own isolated config, sessions,
  and credentials. It never touches other files on the host. This is how you give
  a separate person their own KiroCrew: one instance per tenant.

Validated on macOS (arm64) + Rancher Desktop (dockerd/moby backend).

---

## 0. Prerequisites

| Item | Requirement |
| --- | --- |
| Container engine | Rancher Desktop or Docker Desktop, on the **`dockerd(moby)` backend** (not containerd — required for seccomp/compose) |
| `docker` + `docker compose` | On PATH. Rancher ships shims in `~/.rd/bin` (the script auto-detects) |
| Tailscale account | One tailnet. Anyone who connects must be on the **same tailnet** |
| Port | Default `15476` on `127.0.0.1` |

Check the Rancher backend at **Preferences → Container Engine → dockerd(moby)**.

---

## 1. Files

| File | Role |
| --- | --- |
| `docker-compose.yml` | Two containers: `tailscale` (owns the netns, publishes the port) + `kirocrew` (the gateway, shares the netns) |
| `kirocrew.sh` | Helper: preflight → up → **auto netns repair** → verify. Subcommands `tsauth` / `login` / `check` / `down` |
| `.env.example` | Config template — copy to `.env` and fill in |
| `kirocrew-seccomp.json` | seccomp profile (includes arm64), for the kirocrew container's inner sandbox |
| `.gitignore` | Excludes `.env`, `*.pem`, `*.crt`, local state |

> `.env` holds your Tailscale auth key, tailnet name, and node IP — it is
> gitignored and must never be committed.

---

## 2. Quick start

```bash
cp .env.example .env            # change ports via HOST_PORT/KIROCREW_PORT only

./kirocrew.sh                   # preflight → up → netns repair → verify

./kirocrew.sh tsauth            # if no TS_AUTHKEY: open the printed URL, approve "Connect"

# after approval, read the tailnet name/IP:
docker compose exec tailscale tailscale status --json \
  | grep -E '"DNSName"|"TailscaleIPs"' | head -3
#   -> Self DNSName = kirocrew.<tailnet>.ts.net.  /  TailscaleIPs = 100.x.y.z

# fill CORS with that name/IP (section 3) → docker compose up -d

./kirocrew.sh login             # connect the gateway to the Kiro model

./kirocrew.sh check             # status only
./kirocrew.sh down              # stop (volumes preserved)
```

For local-only use, skip the tailnet steps and just open `http://127.0.0.1:15476`.

---

## 3. Reaching it by tailnet name — `KIROCREW_CORS_ORIGINS` (required)

The gateway rejects any `Host` header it doesn't serve with **403 "Host header
not allowed"** (DNS-rebinding defense). The default allowlist is only
`localhost/127.0.0.1/::1/kirocrew.localhost`, so a tailnet FQDN must be added.

Add **all three forms** — the allowlist is an exact hostname match, and Tailscale
may hand over the FQDN, the short name, or the node IP depending on the client:

```bash
# replace <FQDN> and <IP> with the values from section 2 (status --json)
LINE='KIROCREW_CORS_ORIGINS=http://kirocrew.tailXXXX.ts.net:15476,http://kirocrew:15476,http://100.x.y.z:15476'

if grep -q '^KIROCREW_CORS_ORIGINS=' .env; then
  sed -i.bak "s|^KIROCREW_CORS_ORIGINS=.*|$LINE|" .env && rm -f .env.bak
else
  printf '\n%s\n' "$LINE" >> .env
fi

docker compose up -d            # an env change requires recreating the container
./kirocrew.sh                   # netns repair + verify
```

**Verify** (same gate a real tailnet request hits, tested locally):

```bash
for H in kirocrew.tailXXXX.ts.net:15476 kirocrew:15476 100.x.y.z:15476; do
  printf '%-40s -> ' "$H"
  curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $H" http://127.0.0.1:15476/
done
# all three 200 (or 401) = OK. 403 = that form isn't in the allowlist yet.
```

Connect: someone on the same tailnet opens `http://kirocrew.tailXXXX.ts.net:15476`.
Dashboard token: `docker compose exec kirocrew kirocrew token`.

> **The node IP changes if the node is recreated.** It stays put while the state
> volume survives; if it changes, update only the third CORS entry (100.x).
>
> **Name collision:** if the tailnet already has a node with that name, Tailscale
> appends `-N` (e.g. `kirocrew-1`). Delete the old node and rename in the
> [admin console](https://login.tailscale.com/admin/machines), then redo CORS with
> the new name.

---

## 4. The netns-sharing pitfall (the one that bites most)

`kirocrew` runs with `network_mode: service:tailscale`, sharing the tailscale
container's network namespace. **If the tailscale container restarts later** (while
waiting for interactive login, a manual restart, etc.) a fresh netns is created and
the already-running kirocrew is left **holding a dead netns**.

- Confusing symptom: loopback still works so the healthcheck stays `healthy`, but
  the **routing table is empty and DNS is dead** → every outbound call in the
  container fails with `Could not resolve host` / `dispatch failure`.
- `kiro-cli login`'s `dispatch failure` looks like a CA problem but is **usually this.**

**Fix:** run `./kirocrew.sh` (no args). It compares `started_epoch` of the two
containers, detects "tailscale is newer than kirocrew", and **restarts kirocrew
only** to re-attach the netns. `./kirocrew.sh check` reports the routing-entry count.

> Order tip: authenticate tailscale first (`tsauth`) to stop the restart loop,
> *then* repair the netns (`./kirocrew.sh`) — so you don't have to repair twice.

---

## 5. Persisting the login session (survives restart / redeploy)

**Short answer: it already persists — you log in once.** Both logins are stored
in named volumes, so a `restart`, a `down`/`up`, and an **image upgrade** all keep
you authenticated. You only re-authenticate if you *delete the volume*.

| What | Where it's stored (in-container) | Volume that persists it |
| --- | --- | --- |
| **kiro-cli** (Kiro model auth) — IAM Identity Center / device-flow token | `~/.aws/sso/cache/` + kiro-cli's state under `$HOME`, and `/home/kirocrew` **is** the mount | `kirocrew-home` |
| **Tailscale** (tailnet node identity) | `/var/lib/tailscale` | `kirocrew-tailscale-state` |

The compose mounts the container user's **entire home** as the volume
(`kirocrew-home:/home/kirocrew`), so anything kiro-cli writes under `$HOME` — its
token cache included — lands in the volume automatically. Nothing extra to wire.

**What breaks persistence (and the fix):**

| Action | Login survives? |
| --- | --- |
| `docker compose restart` / `./kirocrew.sh` | ✅ yes |
| `docker compose down` → `up -d` | ✅ yes (down keeps named volumes) |
| image upgrade (`pull` + `up -d`) | ✅ yes |
| `docker compose down -v` | ❌ **no** — `-v` deletes the volumes. Never use `-v` unless you mean to wipe the tenant. (`./kirocrew.sh down` is plain `down`, so it's safe.) |
| `docker volume rm kirocrew-home` | ❌ no — same effect |

**Verify it yourself** (confirms the token is actually in the volume, not just
container-local). Run in your shell:

```bash
cd ~/repos/kirocrew-docker

# 1) container user + home, and the kiro-cli token cache
docker compose exec kirocrew sh -c 'id; echo HOME=$HOME; ls -la ~/.aws/sso/cache/ 2>/dev/null'

# 2) confirm /home/kirocrew is the named volume (not an ephemeral layer)
docker inspect kirocrew \
  --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'
#   -> expect: volume kirocrew-home -> /home/kirocrew

# 3) the real test: bounce the gateway and confirm no re-login is needed
docker compose restart kirocrew && ./kirocrew.sh check
#   the dashboard should answer without ./kirocrew.sh login again
```

> **Token expiry is a separate thing from volume persistence.** An IAM Identity
> Center access token is short-lived; kiro-cli refreshes it using the stored
> refresh token (also in the volume). If the whole SSO session expires (org policy,
> weeks idle), the dashboard shows "session expired" and you re-run
> `./kirocrew.sh login` once — that is normal SSO lifetime, not a volume problem.
>
> **For zero interactive logins at all,** a reusable Tailscale `TS_AUTHKEY` in
> `.env` removes the tailscale step; the kiro-cli SSO device flow still needs a
> human the first time (and whenever the SSO session fully expires) — that is by
> design, there is no non-interactive IdC device-flow login.

---

## 6. `./kirocrew.sh` subcommands

| Command | What it does |
| --- | --- |
| `./kirocrew.sh` | preflight → `up -d` → netns repair → `check` (default) |
| `./kirocrew.sh check` | status only: containers / tailscale auth / netns routing / egress / dashboard |
| `./kirocrew.sh check <host>` | the above plus a TLS-reachability probe to `<host>` |
| `./kirocrew.sh tsauth` | print the tailscale interactive login URL |
| `./kirocrew.sh login` | `kiro-cli login --use-device-flow` (asks for Start URL / Region) |
| `./kirocrew.sh down` | `docker compose down` (volumes preserved) |

---

## 7. Multi-tenant — several people on one host

Clone this bundle **per tenant**. Four things to separate:

| Per tenant | How |
| --- | --- |
| compose project | separate directory, or `docker compose -p <name>` |
| volumes | the `name:` of `kirocrew-home` / `kirocrew-tailscale-state` in `docker-compose.yml` (`kirocrew-home-alice`, …) |
| ports | `HOST_PORT`/`KIROCREW_PORT` in `.env` (15476, 15477, …) |
| Tailscale node | `TS_HOSTNAME` in `.env`, plus each one's own `tsauth`/`TS_AUTHKEY` |
| login | one `./kirocrew.sh login` per container |

The isolation boundary is the volume + container + seccomp. Each tenant sees only
its own `kirocrew-home`.

---

## 8. Public access + Google (Gmail) login — Funnel + OAuth2 Proxy

The tailnet FQDN (section 3) only reaches people **already on your tailnet**. To
let someone **outside** the tailnet in — over the public internet, no port
forwarding, no public IP — use **Tailscale Funnel** with an **OAuth2 Proxy** in
front so only allow-listed Gmail accounts get through.

```
external user → Funnel(443) → oauth2-proxy(:4180) → [Google login + email allowlist] → kirocrew(:PORT)
                              (all three containers share the tailscale netns, same 127.0.0.1)
```

Three pieces are already wired into `docker-compose.yml`:
- the `oauth2-proxy` service (listens on `127.0.0.1:4180`, upstream = kirocrew),
- `tailscale-serve.json` — declares Funnel 443 → 4180, auto-applied on every boot
  (so it survives reboot/redeploy with no manual `tailscale funnel` command),
- `.env` keys for the Google client + cookie secret + public FQDN.

### Setup (once)

**1) Create a Google OAuth client** — [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials):
- "OAuth 2.0 Client ID", Application type: **Web application**
- **Authorized redirect URI** (exact): `https://<your-FQDN>/oauth2/callback`
  (e.g. `https://kirocrew.tailXXXX.ts.net/oauth2/callback`)

**2) Fill `.env`:**
```bash
cd ~/repos/kirocrew-docker

OAUTH2_PUBLIC_FQDN=kirocrew.tailXXXX.ts.net   # into .env
OAUTH2_GOOGLE_CLIENT_ID=...                   # into .env
OAUTH2_GOOGLE_CLIENT_SECRET=...               # into .env

# cookie secret — must be exactly 16/24/32 BYTES.
# PITFALL: `openssl rand -base64 32` prints 44 chars → read as 44 bytes → REJECTED.
# use a 32-char plaintext instead:
echo "OAUTH2_COOKIE_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)" >> .env
```

**3) Set CORS to the public HTTPS origin** (Funnel is 443, no port):
```bash
sed -i.bak 's|^KIROCREW_CORS_ORIGINS=.*|KIROCREW_CORS_ORIGINS=https://kirocrew.tailXXXX.ts.net|' .env && rm -f .env.bak
```

**4) Allow-list the Gmail accounts:**
```bash
cp authenticated_emails.txt.example authenticated_emails.txt
#   edit: one allowed Gmail per line. A login outside this list is rejected.
```

**5) Bring it up** (Funnel auto-starts from `tailscale-serve.json`):
```bash
docker compose up -d
./kirocrew.sh                                 # netns repair
docker compose exec tailscale tailscale funnel status   # expect: 443 → 127.0.0.1:4180
```

### Access

External users open **`https://<your-FQDN>`** (no port, https) → oauth2-proxy
Sign-In → "Sign in with Google" → an allow-listed Gmail → KiroCrew dashboard
(then the dashboard token: `docker compose exec kirocrew kirocrew token`).

> `curl https://<FQDN>/` returning **403** with a `<title>Sign In</title>` body is
> **normal** — that is the proxy's login page for a cookieless request. A browser
> gets the real Google flow. **502** means the proxy isn't up (see Troubleshooting).

### Adding a person later (the only recurring task)
```bash
echo "them@gmail.com" >> authenticated_emails.txt
docker compose up -d          # re-read the list
```

### Turning public access off
```bash
# stop advertising Funnel for this boot:
docker compose exec tailscale tailscale funnel --https=443 off
# or permanently: comment out TS_SERVE_CONFIG + its mount in docker-compose.yml,
# and stop the oauth2-proxy service.
```

> Needs Funnel enabled in your tailnet ACL (`nodeAttrs` → `funnel`) and HTTPS certs
> on (usually default). `tailscale funnel status` showing `No serve config` just
> means nothing is advertised yet — not an error.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `docker not found` | Rancher Desktop off, or `~/.rd/bin` not on PATH |
| `routing table is empty` | dead netns → `./kirocrew.sh` to re-attach (section 4) |
| `kiro-cli login: dispatch failure` | dead netns (section 4) — check routing/egress with `./kirocrew.sh check` |
| tailnet FQDN gives 403 | CORS not applied → section 3; confirm you ran `up -d` to recreate |
| public FQDN gives **502** | oauth2-proxy down → `docker compose logs oauth2-proxy`. Common: `cookie_secret ... 44 bytes` (use a 32-char secret, section 8), or missing Google client id/secret, or `authenticated_emails.txt` not created |
| public FQDN gives **403** + "Sign In" page | **normal** — proxy login page; open in a browser (section 8) |
| Google `redirect_uri_mismatch` | Console redirect URI must be exactly `https://<FQDN>/oauth2/callback` |
| `403 Forbidden` after Google login | that Gmail isn't in `authenticated_emails.txt` |
| tailscale `Logged out` | `./kirocrew.sh tsauth` → approve the URL |
| node named `kirocrew-1` | a same-named node exists → clean up in the console (section 3) |
| had to log in again after `down` | you used `down -v`; `-v` wipes volumes (section 5). Use plain `down` |
| dashboard "session expired" | SSO session fully expired → `./kirocrew.sh login` once (section 5) |

---

## License

MIT. See `LICENSE`.
