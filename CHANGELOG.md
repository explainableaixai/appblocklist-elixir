# Changelog

## 1.0.0 (2026-11-14)

First release of the Elixir client for the AppBlockList App Lookup API.

- `AppBlockList.lookup/2` and `AppBlockList.Client.lookup/2` accept iOS bundle IDs, App Store IDs (with or without `id`) and Android package names, returning `{:ok, %AppBlockList.App{}}` or `{:error, %AppBlockList.Error{}}`.
- A 404 answer is `{:ok, %App{found: false}}`, never an error.
- `AppBlockList.Client.lookup_many/3` runs lookups one after another, skips blanks and duplicates, and halts on `:unauthorized` or `:quota_exceeded` with partial results.
- `AppBlockList.Queue`, a supervised GenServer that serializes every lookup in the node with a minimum interval and caches answers.
- `AppBlockList.App` helpers: `primary_category/1`, `has_category?/2`, `matching_categories/2`, `blocked_by?/2`, `minimum_age/1`, `pending_android?/1`, `to_map/1`.
- `AppBlockList.Error` with reasons `:invalid_id`, `:unauthorized`, `:quota_exceeded` (plus `monthly_lookups/1`), `:server_error`, `:transport`, `:unexpected`.
- Retries with exponential backoff on 5xx and transport errors.
- API key from options, `APPBLOCKLIST_API_KEY` or `config :appblocklist, api_key: ...`.
- Depends on `req` and `jason` only. Test suite runs without network.
