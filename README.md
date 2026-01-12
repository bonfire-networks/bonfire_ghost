# Bonfire.Ghost

Ghost blog integration for Bonfire. This extension connects your Bonfire instance to a Ghost CMS blog via both the Content API (public posts) and Admin API (members, drafts, etc.).

## Features

- Display Ghost blog posts in your Bonfire instance
- Access members/subscribers data via Admin API
- List tiers (membership levels) and newsletters
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

### Programmatic Access

```elixir
# Check if configured
Bonfire.Ghost.configured?()       # Content API
Bonfire.Ghost.admin_configured?() # Admin API

# --- Content API (public posts) ---

# List recent posts
Bonfire.Ghost.list_posts(limit: 5)

# Get a specific post by slug
Bonfire.Ghost.get_post("my-post-slug")

# Get site settings
Bonfire.Ghost.get_settings()

# --- Admin API (members, requires admin_api_key) ---

# List all members with full data
Bonfire.Ghost.list_members(limit: 100, include: "labels,newsletters,subscriptions")

# Filter members
Bonfire.Ghost.list_members(filter: "status:paid")
Bonfire.Ghost.list_members(filter: "subscribed:true")

# Get member by ID
Bonfire.Ghost.get_member("member-id-here")

# Get member by email
Bonfire.Ghost.get_member_by_email("user@example.com")

# List membership tiers
Bonfire.Ghost.list_tiers()

# List newsletters
Bonfire.Ghost.list_newsletters()
```

### Member Data Fields

When fetching members, each member includes:
- `id`, `uuid`, `email`, `name`
- `status` (free, paid, comped)
- `subscribed` (newsletter subscription status)
- `created_at`, `updated_at`
- `labels` (if included)
- `newsletters` (if included)
- `subscriptions` (if included) - paid subscription details


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
