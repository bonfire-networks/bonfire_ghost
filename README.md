# Bonfire.Ghost

Ghost blog integration for Bonfire. This extension connects your Bonfire instance to a Ghost CMS blog via both the Content API (public posts) and Admin API (members, drafts, etc.).

## Features

- Display Ghost blog posts in your Bonfire instance
- Embed a Bonfire comment thread on Ghost articles (`data-canonical-slug` / `data-canonical-id`)
- Auto-provision Ghost authors and members as Bonfire users on first login
- Sync Ghost membership tiers to Bonfire circles
- Configurable via environment variables

## Configuration

Set these environment variables:

```bash
# Required for posts
GHOST_URL=https://your-blog.ghost.io
GHOST_CONTENT_API_KEY=your_content_api_key_here

# Optional - for member access
GHOST_ADMIN_API_KEY=id:secret_hex
```

### Getting API Keys

1. Go to your Ghost Admin panel
2. Navigate to **Settings -> Integrations**
3. Click **Add custom integration**
4. Give it a name (e.g., "Bonfire")
5. Copy the **Content API Key** for reading public posts
6. Copy the **Admin API Key** for accessing members (format: `id:secret`)

## Usage

Once configured, visit `/ghost` in your Bonfire instance to see your Ghost blog posts.

### Embed comments on Ghost articles

Add this script tag to your Ghost theme's `post.hbs`:

```html
<script
  src="https://your-bonfire.example/js/comments_embed.js?v1.4"
  data-canonical-slug="{{slug}}"
  data-group-id="optional-bonfire-group-id"
  data-require-topic="true"
></script>
```

- `data-canonical-slug` — Ghost post slug (deduplicates via URL; `data-canonical-id` for Ghost ID)
- `data-group-id` — post the thread inside a Bonfire group/topic
- `data-require-topic` — only create a thread if the article's primary tag matches a Bonfire topic

### Programmatic Access

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


## Copyright and License

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
# bonfire_ghost
