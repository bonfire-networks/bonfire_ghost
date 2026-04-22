# Bonfire.Ghost — Architecture & Implementation Notes

Companion to `README.md`. The README is the user-facing config/usage guide; this document is for developers who need to touch the sync pipelines, the webhook pipeline, or the gated login integration.

## 1. What this extension does

Two distinct things, bundled because they share the Ghost Admin API client:

1. **Read-only blog integration.** List/show Ghost posts, surface member data
   in an admin settings page. *(Pre-existing; see `lib/integration.ex` and
   `lib/web/components/ghost_posts_live*`.)*
2. **Gated-community sync** — the focus of this document. Ghost can drive
   membership on Bonfire:
   - Ghost **tiers** → Bonfire **circles** (`ghost_tier:<slug>`).
   - Ghost **members** → Bonfire **accounts + users + circle memberships**,
     auto-provisioned on first sign-in or via webhook.
   - Login can be put into **passwordless (gated) mode**: no password field,
     no sign-up link, one-time email link only.

**Join key is email.** There is no persistent Ghost ↔ Bonfire mapping table;
the Ghost payload and `Accounts.get_by_email/1` are enough.

## 2. Scope & non-goals

| In scope | Out of scope |
|---|---|
| Syncing tier → circle names & metadata | Creating roles/ACLs/grants from tiers |
| Provisioning accounts/users/memberships | Deleting Bonfire accounts when Ghost members vanish |
| Webhook signature verification | Exposing a bi-directional sync (Bonfire → Ghost) |
| Passwordless email login (piggy-backing `:forgot_password`) | A true `:magic_login` confirm_action — follow-up |
| One provider pattern (Ghost) for unknown-email fallback | Multi-source conflict resolution |

The non-goals are deliberate — see §6 "Key decisions" for the reasoning.

## 3. High-level architecture

```
┌─ Ghost CMS ───────────────────┐      ┌─ Bonfire ───────────────────────────────┐
│                               │      │                                         │
│  tiers  ──────── admin ───────┼──────►  GhostSettingsLive  ──► Sync.Tiers  ──► Circles
│                               │      │                                         │
│  members (add/edit/del) ──────┼──────►  POST /ghost/webhook/:event             │
│          HMAC-signed          │      │    │                                    │
│                               │      │    ▼ (VerifyGhostSignature plug)        │
│                               │      │  WebhookController  ──► MemberWebhook-  │
│                               │      │                        Worker (Oban) ──► Sync.Members
│                               │      │                                    │    │
│                               │      │                                    ▼    │
│                               │      │                    Accounts + Users + Circles
│                               │      │                                         │
│                               │      │   LoginLive ──► ForgotPasswordController │
│                               │      │                     │                   │
│                               │      │                     ▼ (unknown email)   │
│                               │      │                LoginEmailProvider ──► Ghost.LoginEmailProvider ──► Sync.Members
└───────────────────────────────┘      └─────────────────────────────────────────┘
```

Three hot paths:

- **Sync tiers** — admin clicks *Sync* in settings → `Sync.Tiers.sync_all/1`
  returns `{:ok, summary, tiers}`. Summary counts `created/updated/unchanged/archived/errors`. Nothing is ever deleted upstream or downstream; vanished tiers get "(archived)" appended to their circle summary.
- **Member webhook** — Ghost POSTs to `/ghost/webhook/:event`. Signature plug
  runs synchronously (fast); controller enqueues an Oban job and returns 200
  in the same request. The `MemberWebhookWorker` dispatches to
  `Sync.Members.{provision_from_ghost_member, remove_member}/1` with retries.
- **Gated login** — if `[:bonfire_ui_me, :login, :passwordless_only]` is true,
  `LoginLive` shows only the email field. Submit posts to
  `ForgotPasswordController.create/2`, which runs
  `LoginEmailProvider.ensure/1` for unknown emails (Ghost provider
  provisions the account on the fly), then sends a magic link via the
  existing `request_confirm_email(..., confirm_action: :login)` path.

## 4. File map

### This extension (`extensions/bonfire_ghost/`)

| Path | Role |
|---|---|
| `lib/sync/tiers.ex` | Tier → circle reconciliation. `sync_all/1`, `sync_tiers/2`. |
| `lib/sync/members.ex` | Member → account/user/circle reconciliation. `provision_from_ghost_member/1`, `reconcile_circles/2`, `remove_member/1`. |
| `lib/workers/member_webhook_worker.ex` | `use Oban.Worker, queue: :ghost_webhooks, max_attempts: 5`. Dispatches by `event` arg. |
| `lib/web/controllers/webhook_controller.ex` | One `:member` action, routed by `:event` URL segment. Enqueues Oban job, returns 200. |
| `lib/web/plugs/verify_ghost_signature.ex` | HMAC-SHA256 of `body <> timestamp_ms`, 5-min replay window, 401 on mismatch, 503 if no secret. |
| `lib/web/plugs/body_reader.ex` | Custom `Plug.Parsers` body_reader that stashes raw JSON in `conn.private[:bonfire_raw_body]`. Delegates to `DigestPlug` so ActivityPub still works. |
| `lib/web/live_handler.ex` | `GhostSettingsLive` event handlers — `sync_tiers`, `load_more`, parallel Ghost fetches. |
| `lib/web/components/ghost_settings_live.{ex,sface}` | Admin settings page: sync button, gated-mode toggle, last-sync summary. |
| `lib/web/routes.ex` | Routes — `/ghost` (public), `/ghost/settings` (admin), `/ghost/webhook/:event` (pipe: `:basic_json`). |
| `lib/login_email_provider.ex` | Adapter implementing `Bonfire.UI.Me.LoginEmailProvider`. Calls `Ghost.get_member_by_email/2` → `Sync.Members.provision_from_ghost_member/1`. |
| `lib/runtime_config.ex` | Reads env vars, sets `passwordless_only` when `GHOST_GATED_MODE` is truthy. |

### Outside the extension (touched by this feature)

| Path | Why |
|---|---|
| `config/runtime.exs:247` | Registers the `:ghost_webhooks` Oban queue. |
| `extensions/bonfire_ui_common/lib/endpoint_template.ex:249-254` | Reads `body_reader` MFA from config, default unchanged. |
| `extensions/jacobin/config/jacobin.exs:36-38` | Jacobin flavour opt-in: `body_reader: {Bonfire.Ghost.BodyReader, :read_body, []}`. |
| `extensions/bonfire_ui_me/lib/views/login/login_live.{ex,sface}` | `@passwordless_only?` assign; template branches on it. |
| `extensions/bonfire_ui_me/lib/views/forgot_password/forgot_password_controller.ex` | Runs `LoginEmailProvider.ensure/1` on unknown emails; uses `confirm_action: :login` in passwordless mode. |
| `extensions/bonfire_ui_me/lib/login_email_provider.ex` | `ExtensionBehaviour` — defines callback, auto-discovers implementing modules, runs `ensure/1` |

## 5. Configuration

### Environment variables

| Var | Purpose | Required? |
|---|---|---|
| `GHOST_URL` | Ghost instance URL (e.g. `https://blog.example.com`) | Read integration |
| `GHOST_CONTENT_API_KEY` | Content API key, for posts | Read integration |
| `GHOST_ADMIN_API_KEY` | Admin API key (`id:secret`), for members/tiers | Sync + gated login |
| `GHOST_WEBHOOK_SECRET` | Shared secret; matches the one set in Ghost → Integrations → webhook "Secret" field | Webhooks |
| `GHOST_GATED_MODE` | `true`/`1`/`yes` enables passwordless login globally | Opt-in |

### Instance settings (live-toggleable, override env)

| Path | Effect |
|---|---|
| `[:bonfire_ui_me, :login, :passwordless_only]` | Same as `GHOST_GATED_MODE`. Admin toggles this from the Ghost settings page. |

### Ghost-side setup

1. Ghost admin → **Settings → Integrations → Add custom integration**.
2. Copy **Content API Key** → `GHOST_URL`/`GHOST_CONTENT_API_KEY`.
3. Copy **Admin API Key** (`id:secret`) → `GHOST_ADMIN_API_KEY`.
4. **Add webhook** on the integration (three separate webhooks, one per event):
   - `POST https://<bonfire-host>/ghost/webhook/member-added` — event `member.added`
   - `POST https://<bonfire-host>/ghost/webhook/member-edited` — event `member.edited`
   - `POST https://<bonfire-host>/ghost/webhook/member-deleted` — event `member.deleted`
5. Set the **Secret** field on each webhook to the same value as `GHOST_WEBHOOK_SECRET`.

### Oban queue

Set `QUEUE_SIZE_GHOST_WEBHOOKS` (default 2) to control concurrency. Jobs retry
up to 5 times with Oban's default backoff.

## 6. Key decisions — why it's built this way

### 6.1 Oban over `Task.Supervisor` for webhook work

Bonfire uses Oban which gives retries/backoff/dead-lettering for free — important for a webhook receiver that can't afford to silently drop a `member.added` event if the database is briefly unavailable. We rejected the original plan's `Task.Supervisor` approach for consistency and reliability.

### 6.2 Circles only, no roles/ACLs from tier sync

Early plan revisions created a role + ACL + grant per tier. We dropped that:

- Bonfire's boundaries system is already composable — admins can grant any
  existing circle into any existing ACL.
- Seeding roles *should not* require atom coinage (`String.to_atom("ghost_tier_" <> slug)`) and rescuing `:role_verbs` config corruption.
- Duplicating boundaries primitives would invite drift from the main UI.

The extension now syncs **only** circles. Admins compose access policy
themselves using those circles as subjects.

### 6.3 Email as join key, no mapping table

Ghost payloads include `email`. Bonfire accounts are unique by email. A
separate mapping table would add a migration, a consistency problem on email
changes, and nothing the email itself doesn't already give us.
`member.edited` with an email change is handled by treating the new email as
an upsert — the old account stays, the new email becomes the sync anchor for
that member going forward.

### 6.4 HMAC over `body <> timestamp_ms`, **concatenated**

Ghost's webhook signing is undocumented. The working format (verified via
community writeups) is:

```
X-Ghost-Signature: sha256=<hex>, t=<unix-ms>
mac = HMAC-SHA256(secret, body || integer_to_string(ts))
```

The landmine is the concatenation — naive "hash the body only"
implementations fail silently. 5-minute replay window is stricter than
Bonfire's ActivityPub plug (which uses 1 hour) — HMAC webhooks warrant
tighter replay protection than signed HTTP traffic.

### 6.5 Raw body via flavour-scoped `body_reader`, not a custom plug

`Plug.Parsers` runs at the endpoint level and consumes the body stream before
any router pipeline. You cannot "add a plug before Parsers" from a router
scope. Instead:

- `endpoint_template.ex` reads `body_reader` from
  `Application.compile_env(:bonfire_ui_common, :body_reader, {ActivityPub.Web.Plugs.DigestPlug, :read_body, []})`.
- The default is the AP digest plug — **every flavour gets the same behaviour
  as before.**
- Jacobin adds one config line to swap in `Bonfire.Ghost.BodyReader`, which
  wraps DigestPlug and stashes raw bytes in `conn.private[:bonfire_raw_body]`
  — but only for `application/json` requests, to avoid buffering large
  uploads.
- Every other flavour is untouched.

### 6.6 Piggy-backing `:forgot_password` for magic-link login

The login flow doesn't need a dedicated `:magic_login` `confirm_action`
(yet). We reuse `Accounts.request_confirm_email/2` with
`confirm_action: :login`, which sends an email whose URL lands on
`ForgotPasswordController.index/2` — the same controller that handles
password resets.

Mail template URL trace (verified before shipping): `bonfire_me/lib/mails/mails.ex:143-169` → `url_path(ForgotPasswordController) <> "/" <> token` → `/login/forgot-password/:token`. Matches the controller's `:login_token` param.

A separate `:magic_login` action is a follow-up if we ever want to skip the
change-password screen entirely (currently users land there after confirming;
they can set a password or continue requesting magic links).

### 6.7 Unknown-email fallback via `LoginEmailProvider` extension point

`ForgotPasswordController.create/2` runs
`Bonfire.UI.Me.LoginEmailProvider.ensure(email)` when the email isn't
already in the database. This is a plug-point — any extension can implement
`@behaviour Bonfire.UI.Me.LoginEmailProvider` with an `ensure_account/1`
callback and get registered automatically.

Ghost's implementation:

```elixir
def ensure_account(email) do
  case Ghost.get_member_by_email(email) do
    {:ok, %{"members" => [member | _]}} -> Members.provision_from_ghost_member(member)
    {:ok, _} -> :no_match
    {:error, reason} -> {:error, reason}
  end
end
```

Neutral response either way — the controller always renders the same "check
your email" page, so snoopers can't probe membership.

### 6.8 Handle collision suffixing (`_2`..`_9`)

`Users.create/2` requires a unique handle. We slugify the email local part;
on collision, try `_2`, `_3`, … up to `_9`. Beyond that we fail — nine users
sharing an email local part is rare enough that the alternative (random
suffix, UUID, opaque id) isn't worth the readability cost.

## 7. Sync contract details

### 7.1 `Sync.Tiers.sync_all/1`

```elixir
@spec sync_all(keyword()) :: {:ok, summary, [tier_map]} | {:error, term()}
# summary :: %{created, updated, unchanged, archived, errors: [{slug, reason}]}
```

- Fetches with `include: "benefits,monthly_price,yearly_price"` so the UI can
  render cards without a second round-trip. The LiveHandler drops the returned
  list straight into the socket assigns.
- Idempotent. Re-runs only refresh display-name metadata when Ghost's name
  drifts from the stored circle name.
- Slugs are validated against `~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/`. Rejected
  slugs become `errors` entries, not circle names.
- Orphans (local `ghost_tier:*` with no upstream match) get "(archived)"
  appended to their summary. Never deleted.

### 7.2 `Sync.Members.provision_from_ghost_member/1`

```elixir
@spec provision_from_ghost_member(map()) :: {:ok, User.t()} | {:error, term()}
```

Pipeline: `ensure_account` → `ensure_user` → `reconcile_circles`.

- **Account**: `Accounts.signup/2` with a high-entropy random password and
  `must_confirm?: false` (verified present via `accounts.ex:218-239`). The
  member will log in via magic link — they never see this password, and can
  set their own later via the change-password flow.
- **User**: `Users.by_account!/1` returns a list. We take the first user if
  present (Ghost members are 1:1 with accounts for our use), otherwise
  `Users.create/2` with a derived handle.
- **Circles**: `reconcile_circles/2` diffs target circles (from
  `ghost_member["tiers"]`) against current `ghost_tier:*` memberships. Tiers
  with no local circle yet are silently skipped — the next `Sync.Tiers` run
  picks them up; we never block provisioning on a missing tier.

### 7.3 `Sync.Members.remove_member/1`

Called on `member.deleted`. Removes the user from **every**
`ghost_tier:*` circle. The Bonfire account and user are **preserved** (the
plan decision — deleting user-generated content tied to an account is
outside our scope).

## 8. Webhook receiver flow

```
Ghost ──POST──► /ghost/webhook/:event
                    │
                    ▼
          Plug.Parsers (Ghost.BodyReader)  ──► raw body stashed
                    │
                    ▼
          VerifyGhostSignature plug  ──► 401 / 503 on failure
                    │
                    ▼
          WebhookController.member/2
                    │  extracts member.current or member.previous
                    │  based on URL event
                    ▼
          MemberWebhookWorker.new(%{event, member, previous}) ──► Oban.insert
                    │
                    ▼
          send_resp(200, "ok")   (returns while Oban processes async)
                    │
                    ▼ (later, in worker)
          Sync.Members.provision_from_ghost_member / remove_member
```

- URL path disambiguates event (`member-added` / `member-edited` /
  `member-deleted`). We chose per-event URLs over payload-shape inference
  because the `current`/`previous` pattern can be fragile on non-trivial
  edits (e.g. simultaneous tier + email change).
- Unknown event paths return 404.
- Malformed payloads (no `member.current` or `member.previous`) return 400.
- Oban insert failures return 500 — Ghost will retry.

## 9. Test coverage

| File | Cases | Covers |
|---|---|---|
| `test/sync/tiers_test.exs` | 7 | Payload validation (missing fields, regex-rejected slugs), circle creation on first run, idempotency on re-run, display-name refresh when Ghost renames a tier, archived marker on orphans, error aggregation per slug without halting the batch. |
| `test/sync/members_test.exs` | 10 | Provisioning a fresh member (account + user + circles), skipping unsynced tiers, idempotency, handle collision suffixing, `:missing_email` rejection, reconciliation on tier moves, dropping all tiers, `remove_member/1` keeping the account, no-op removal for unknown accounts. |
| `test/web/plugs/verify_ghost_signature_test.exs` | 8 | Missing header, malformed header, HMAC mismatch, stale timestamp, missing raw body, happy path, case-insensitive hex, 503 when secret unset. |

Total: 25 test cases.

Run just the bonfire_ghost suite:

```bash
just test extensions/bonfire_ghost
```

Or individual files, e.g.:

```bash
just test extensions/bonfire_ghost/test/sync/members_test.exs
```

The `ForgotPasswordController` integration test lives in
`extensions/bonfire_ui_me/test/controllers/forgot_password_test.exs` (3
cases: unknown email, known email, blank email — all verify the neutral
response guarantee). Unit tests for the provider runner logic live in
`extensions/bonfire_ui_me/test/login/login_email_providers_test.exs`.

## 10. Known gaps & follow-ups

| Gap | Impact | Why deferred |
|---|---|---|
| No `test/web/webhook_controller_test.exs` | Controller's event-routing & Oban enqueue path uncovered | Signature plug (the tricky part) is tested; controller logic is thin. Follow-up. |
| `sync_flash/1` has two near-duplicate message arms | Cleanup | Touches `l()`-wrapped strings — cost of re-translation > value. |
| `load_more` pagination uses `socket.assigns.members ++ new` | O(n) per page | Only bites past ~100 members; fix opportunistically. |
| No dedicated `:magic_login` `confirm_action` | Users land on change-password screen after first magic-link click | Scoped as follow-up; current flow still works (they can set a password or keep using magic links). |
| Handle collision beyond `_9` suffix | `{:error, :handle_collision}` | Extremely unlikely; error is explicit. |

## 11. Operator playbook (deploy checklist)

1. Add to the instance's environment:
   - `GHOST_URL`, `GHOST_ADMIN_API_KEY`, `GHOST_WEBHOOK_SECRET`.
   - Optional: `GHOST_GATED_MODE=true` to start in passwordless mode.
2. Deploy. The `:ghost_webhooks` Oban queue starts automatically.
3. Visit `/ghost/settings` as an admin → press **Sync tiers**. Confirm the
   flash summary reports the right number of `created` circles.
4. In Ghost → Integrations → your integration → add three webhooks
   (see §5). Use the same `GHOST_WEBHOOK_SECRET` value as the "Secret".
5. Trigger a test event in Ghost (e.g. add a test member). Tail logs for the
   Oban job and confirm the member appears via Tidewave:
   ```elixir
   Bonfire.Me.Accounts.get_by_email("test@example.com")
   ```
6. Verify gated login at `/login` with the test email — should receive a
   magic link and complete sign-in.

If a webhook 401s, check:
- `GHOST_WEBHOOK_SECRET` matches the Ghost-side integration secret.
- System clock drift is under 5 minutes (the replay window).
- The flavour config has the `body_reader` override (Jacobin does; other
  flavours don't by default).
