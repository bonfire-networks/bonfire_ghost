# Bonfire.Ghost

Ghost blog integration for Bonfire. This extension connects your Bonfire instance to a Ghost CMS blog via both the Content API (public posts) and Admin API (members, drafts, etc.).

## Features

- Display Ghost blog posts in your Bonfire instance.
- Backfill existing articles and automatically mirror publish, edit, unpublish, delete, and republish events.
- Filter article imports by Ghost tags and route them into a Bonfire group or topic.
- Embed a federated Bonfire discussion on Ghost articles (`data-canonical-slug` / `data-canonical-id`).
- Provision passwordless Bonfire accounts for eligible Ghost members and staff.
- Link Ghost authors to stable Bonfire profiles for article attribution.
- Sync Ghost membership tiers to Bonfire circles and use them to protect paid articles.
- Gate new account creation by selected Ghost membership tiers.
- Configure and monitor the integration from an administrator-only settings screen.
- Configure credentials through environment variables and feature behavior through instance settings.

## Setup

### Get your Ghost API keys

1. Go to your Ghost Admin panel
2. Navigate to **Settings -> Integrations**
3. Click **Add custom integration**
4. Give it a name (e.g., "Bonfire")
5. Copy the **Content API Key** for reading public posts
6. Copy the **Admin API Key** for accessing members (format: `id:secret`)

## Configure your instance

Set these environment variables:

```bash
# Required for reading public posts
GHOST_URL=https://your-blog.ghost.io
GHOST_CONTENT_API_KEY=your_content_api_key_here

# Member access (tiers, memberships, provisioning)
GHOST_ADMIN_API_KEY=id:secret_hex

# Verify Ghost-signed webhooks (member sync + article auto-import). Without it, webhooks are rejected.
GHOST_WEBHOOK_SECRET=your_webhook_secret
```

Feature behaviour is set per-instance in **Admin settings → Ghost** (settings override the env defaults):

- **Default author**: fallback identity used when a Ghost article's author can't be resolved.
- **Post into group or topic**: where imported articles are posted.
- **Only import articles matching a topic**: import only when the article's primary tag matches a Bonfire topic.
- **Auto-import on publish**: import and mirror articles as Ghost publishes/edits/deletes them (via webhook).
- **Membership tiers**: which Ghost tiers may have a login-capable account (the tier gate; leave all off to allow any member).
- **Gated login (Ghost members only)** + a login message: hides password login so eligible Ghost members/staff use passwordless login.


### Embed comments on Ghost articles

Add this env var to your Bonfire instance, it is required for the iframe to render at all (CSP `frame-ancestors`):

```
IFRAME_ALLOWED_ORIGINS="your-ghost-blog.com"
```

Add this script tag to your Ghost theme's `post.hbs`:

```html
<script
  src="https://your-bonfire.example/js/comments_embed.js?v1.4"
  data-canonical-slug="{{slug}}"
></script>
```

Options:

- `data-canonical-slug`: the Ghost post slug (deduplicates via URL; use `data-canonical-id` for the Ghost ID instead)

Loading the embed is read-only. It shows the thread of an article already imported by the webhook or the backfill, and never imports the article itself.


### Who an imported article belongs to, and where it goes

The embed runs on your blog, so **anyone** can craft its iframe URL. It therefore accepts no attribute that chooses a post's author, audience or destination, as those are decided by the instance, in **Ghost settings**, and only apply through the trusted import paths (webhook and backfill):

| Setting | Replaces the old attribute | What it does |
|---|---|---|
| Import author (`auto_import_as`) | `data-creator` | Fallback identity used when the Ghost article author cannot be resolved. Without either a resolvable Ghost author or this fallback, no thread is created. |
| Post into group (`post_into_group`) | `data-group-id` | The group/topic imported articles are posted into. |
| Require topic (`require_topic`) | `data-require-topic` | Only import when the article's primary tag matches a Bonfire topic. |
| (none; derived from Ghost `visibility`) | `data-boundary` | Public/members/paid articles get their audience from Ghost itself; paid articles are `:see`-only with `:read` gated to the `ghost_tier:*` circles. |

> **Upgrading:** `data-creator`, `data-boundary`, `data-group-id`, `data-to-circles` and `data-require-topic` are now **ignored** (they let a visitor forge a post's author, or publish a paid article publicly). Old snippets keep working (the params are just dropped, with a warning logged) but if your theme relied on `data-group-id` or `data-require-topic`, set the equivalent instance setting above or that behaviour is silently lost.

## How members and staff map to accounts

Ghost keeps **staff** (authors/editors/admins) and **members** (subscribers) as separate entities with separate ID spaces; the same person can be both. Bonfire links each person to one local account by Ghost ID (email is only a fallback), so:

- **Email changes follow the person.** Changing an email in Ghost updates the linked Bonfire account instead of forking a duplicate; changing it in Bonfire is respected and never clobbered back. Lookups are case-insensitive.
- **Attribution is stable.** An author's imported articles stay attributed to the same linked profile across email changes.
- **The tier gate** (Admin settings → Ghost → Membership tiers) decides which member tiers may have a login-capable account. No tier toggled on means the gate is off. Staff bypass it; only staff *suspended* in Ghost (`inactive`) are refused, a `locked` status is not offboarding (it just means an imported user with no Ghost password).
- **Revocation removes access, not accounts.** A cancelled/deleted membership only drops the `ghost_tier:*` circles; the person's account, profile, posts and follows remain.

The mechanics live in the module docs: `Bonfire.Ghost.Identities`, `Bonfire.Ghost.TierGate`, `Bonfire.Ghost.Sync.Members`, `Bonfire.Ghost.LoginEmailProvider`.

## Advanced operations

### First activation on an already active instance

Run once, in order:

1. Add env vars & deploy the extension (the `bonfire_ghost_identity` migration runs).
2. Admin settings → Ghost → **Sync members** (backfill: walks tiers → active staff → members, writing identity rows keyed on everyone's current emails).

> Note: Only after step 2 should you change any emails in Ghost (e.g. giving bulk-imported contributors their real addresses), as the links recorded by the backfill make each change follow the existing account instead of forking a duplicate. If you're not changing emails, there's nothing more to do.

New authors need no manual step: their identity row is written at first article import or first sign-in.

### Programmatic access

Use `Bonfire.Ghost.client/0` or `Bonfire.Ghost.admin_client/0` to get a client, then call the underlying API modules directly:

```elixir
# Check if configured
Bonfire.Ghost.configured?()       # Content API
Bonfire.Ghost.admin_configured?() # Admin API

# --- Content API (public posts) ---
{:ok, c} = Bonfire.Ghost.client()

Bonfire.Ghost.API.list_posts(c, limit: 5)
Bonfire.Ghost.API.get_post_by_slug(c, "my-post-slug")
Bonfire.Ghost.API.get_settings(c)

# --- Admin API (members, requires admin_api_key) ---
{:ok, c} = Bonfire.Ghost.admin_client()

Bonfire.Ghost.AdminAPI.list_members(c, limit: 100, include: "labels,newsletters,subscriptions")
Bonfire.Ghost.AdminAPI.list_members(c, filter: "status:paid")
Bonfire.Ghost.AdminAPI.get_member(c, "member-id-here")
Bonfire.Ghost.AdminAPI.get_member_by_email(c, "user@example.com")
Bonfire.Ghost.AdminAPI.list_tiers(c)
Bonfire.Ghost.AdminAPI.list_newsletters(c)
```

### Audit accounts created before the tier gate

Existing accounts are never gated at sign-in (the local lookup wins), so closing the gate doesn't remove ungated accounts made earlier. To list local accounts whose Ghost member record fails the current gate (in `bin/bonfire remote`):

```elixir
alias Bonfire.Ghost.{AdminAPI, TierGate}
repo = Bonfire.Common.Repo
import Ecto.Query

{:ok, c} = Bonfire.Ghost.admin_client()

repo.all(from(e in Bonfire.Data.Identity.Email, select: e.email_address))
|> Enum.filter(fn email ->
  case AdminAPI.get_member_by_email(c, email, include: "tiers") do
    {:ok, %{"members" => [m | _]}} -> not TierGate.allowed?(m, client: c)
    _ -> false   # not a member (staff / local-only), leave alone
  end
end)
```

Deleting an account is a real deletion (posts, follows, federated identity), so only remove ones clearly created in error and unused.

### Repair a split identity (duplicated author profiles)

Symptoms: two profiles for one person, the original stranded on an unreachable email, new articles attributed to the takeover profile. In `bin/bonfire remote`:

```elixir
alias Bonfire.Me.Users
alias Bonfire.Ghost.Identities
alias Bonfire.Data.Identity.Email
repo = Bonfire.Common.Repo

# 1. DIAGNOSE: accounts/emails behind the two profiles
for username <- ["OriginalAuthor", "TakeoverProfile"] do
  {:ok, u} = Users.by_username(username)
  u = repo.maybe_preload(u, accounted: [account: [:email]])
  %{username: username, account: u.accounted.account_id, email: u.accounted.account.email.email_address}
end

# 2. RE-KEY the ORIGINAL account to the person's real email
#    (if that email is on the takeover account, move that one to a throwaway first, the same way)
{:ok, original} = Users.by_username("OriginalAuthor")
account = repo.maybe_preload(original, accounted: [account: [:email]]).accounted.account

{:ok, _} =
  account.email
  |> Email.changeset(%{email_address: "person@example.com"}, must_confirm?: false)
  |> repo.update()

# 3. LINK the Ghost IDs to the original account + author profile
Identities.link(account,
  staff_id: "<ghost staff id>",
  member_id: "<ghost member id, if also a member>",
  user: original,
  ghost_email: "<the email currently in Ghost>"
)
```

Articles already attributed to the takeover profile: attribution is fixed at creation, so delete the wrong post and re-import the article (webhook re-send or backfill) so it re-creates under the right author. That drops comments on the wrong post's thread, so decide per article.

## Copyright and license

Copyright (c) 2025 Bonfire Contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public
License along with this program.  If not, see <https://www.gnu.org/licenses/>.
