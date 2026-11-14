# AppBlockList for Elixir

An Elixir client for the [AppBlockList mobile app categorization API](https://www.appblocklist.com/app-categorization-api.php). Pass in a bundle ID, an App Store ID or a Google Play package name and get back a struct describing the app: name, developer, App Store genre, age rating, ranked filtering categories, IAB category and the matching package on the other store.

| | |
|---|---|
| Package | `:appblocklist` |
| Version | 1.0.0 |
| Elixir | 1.13 or newer |
| Dependencies | `req`, `jason` |
| Return style | `{:ok, %AppBlockList.App{}}` or `{:error, %AppBlockList.Error{}}` |
| Concurrency model | one request at a time, enforced by `AppBlockList.Queue` |
| License | MIT |

---

## Installation

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:appblocklist, "~> 1.0"}
  ]
end
```

To track the repository directly instead:

```elixir
{:appblocklist, github: "explainableaixai/appblocklist-elixir", tag: "v1.0.0"}
```

Fetch and compile:

```bash
mix deps.get
```

### Configuring the key

The client looks for the key in this order:

1. the `:api_key` option you pass
2. the `APPBLOCKLIST_API_KEY` environment variable
3. `config :appblocklist, api_key: ...`

In a Phoenix release, keep it in `config/runtime.exs`:

```elixir
# config/runtime.exs
config :appblocklist, api_key: System.fetch_env!("APPBLOCKLIST_API_KEY")
```

`AppBlockList.Client.new/1` raises `ArgumentError` when no key is found. Inside a supervision tree that means a misconfigured node fails at boot, which is where you want it to fail.

---

## First lookup in IEx

```elixir
iex> {:ok, app} = AppBlockList.lookup("com.zhiliaoapp.musically")
iex> app.name
"TikTok - Videos, Shop & LIVE"
iex> app.developer
"TikTok Ltd."
iex> app.age_rating
"12+"
iex> AppBlockList.App.minimum_age(app)
12
iex> app.app_store_id
"835599320"
iex> app.android_package
"com.zhiliaoapp.musically"
iex> AppBlockList.App.primary_category(app)
"Social Networking"
```

The App Store ID works with or without its prefix, and Android package names are accepted the same way:

```elixir
AppBlockList.lookup("835599320")
AppBlockList.lookup("id835599320")
AppBlockList.lookup("com.openai.chatgpt")
```

Identifiers are trimmed and must be at most 200 characters. Longer ones return `{:error, %AppBlockList.Error{reason: :invalid_id}}` without a request.

---

## Return values, by pattern

Because results are tagged tuples, the whole response space fits in one `case`:

```elixir
case AppBlockList.Client.lookup(client, id) do
  {:ok, %AppBlockList.App{found: true} = app} ->
    {:known, app}

  {:ok, %AppBlockList.App{found: false, android_package: pkg}} when pkg != "" ->
    {:pending_google_play, pkg}

  {:ok, %AppBlockList.App{found: false}} ->
    :unknown

  {:error, %AppBlockList.Error{reason: :quota_exceeded} = e} ->
    {:pause_until_next_month, AppBlockList.Error.monthly_lookups(e)}

  {:error, %AppBlockList.Error{reason: :unauthorized}} ->
    raise "AppBlockList key is missing or invalid"

  {:error, %AppBlockList.Error{} = e} ->
    {:retry_later, e}
end
```

### Status codes and reasons

| HTTP | Meaning | Returned |
|---|---|---|
| 200 | app found | `{:ok, %App{found: true}}` |
| 404 | not in the database | `{:ok, %App{found: false, error: "App not found."}}` |
| 404 | on Google Play, not yet categorized | `{:ok, %App{found: false, android_package: "..."}}` |
| 400 | `id` missing or not a bundle ID, App Store ID or package name | `{:error, %Error{reason: :invalid_id}}` |
| 401 | missing or invalid `api_key` | `{:error, %Error{reason: :unauthorized}}` |
| 403 | monthly lookups used (body has `monthly_lookups`) | `{:error, %Error{reason: :quota_exceeded}}` |
| 500 | temporary error | retried, then `{:error, %Error{reason: :server_error}}` |
| none | connection, TLS, timeout, non-JSON body | retried, then `{:error, %Error{reason: :transport}}` |

`AppBlockList.Error` is an exception struct, so the bang variants (`AppBlockList.lookup!/2`, `Client.lookup!/2`) simply `raise` it. `Error.retryable?/1` is true for `:server_error` and `:transport`.

### The App struct

| Field | Type | Notes |
|---|---|---|
| `found` | `boolean` | false for 404 |
| `name`, `developer` | `String.t` | store listing |
| `bundle_id` | `String.t` | iOS bundle ID |
| `app_store_id` | `String.t` | digits, as a string |
| `android_package` | `String.t` | Google Play twin, `""` if none |
| `app_store_genre` | `String.t` | one of 26 App Store genres |
| `age_rating` | `String.t` | `4+`, `9+`, `12+`, `17+` |
| `filtering_categories` | `[String.t]` | ranked, most descriptive first |
| `developer_domain` | `String.t` | e.g. `tiktok.com` |
| `iab_category` | `String.t` | IAB taxonomy path |
| `error` | `String.t \| nil` | service message on 404 |
| `raw` | `map` | decoded JSON as received |

Helpers in `AppBlockList.App`: `primary_category/1`, `has_category?/2`, `matching_categories/2`, `blocked_by?/2`, `minimum_age/1`, `pending_android?/1`, `to_map/1` and `from_map/1`.

The filtering categories belong to a fixed set of 58, the same set applied to 120 million web domains. One `@blocked` module attribute can therefore govern your DNS filter and your app policy.

---

## Rate limiting on the BEAM: one request at a time

Elixir makes it trivially easy to fire 5,000 lookups at once with `Task.async_stream`. Do not. The App Lookup API takes one ID per request and asks that requests be sent one after another, without parallel bursts.

`AppBlockList.Queue` is a GenServer that owns a client and performs lookups inside `handle_call/3`. Since a GenServer processes one message at a time, every caller in the node, whether a LiveView, a controller, an Oban job or a Broadway stage, shares a single ordered stream. A configurable `:interval` adds spacing, and a TTL cache absorbs repeats.

```elixir
# lib/my_app/application.ex
children = [
  MyAppWeb.Telemetry,
  MyApp.Repo,
  {AppBlockList.Queue, interval: 150, ttl: :timer.hours(24)},
  MyAppWeb.Endpoint
]
```

```elixir
{:ok, app} = AppBlockList.Queue.lookup("com.roblox.robloxmobile")
```

| Queue option | Default | Meaning |
|---|---|---|
| `:name` | `AppBlockList.Queue` | registered name |
| `:interval` | `100` | minimum milliseconds between upstream requests |
| `:ttl` | 24 hours | cache lifetime for `{:ok, _}` answers, including not-found |
| `:client` | `Client.new()` | a prebuilt `%AppBlockList.Client{}` |
| others | | passed to `AppBlockList.Client.new/1` |

Errors are never cached, so a transient 500 does not stick. Call `AppBlockList.Queue.clear_cache/1` after you change policy if you want fresh data.

Because calls queue up behind each other, pick a `GenServer.call` timeout that fits your traffic. `Queue.lookup/3` takes it as the third argument (default 60 seconds).

---

## Example 1: a Phoenix endpoint for a device enrollment portal

A district IT team wants teachers to check an app before requesting it for classroom tablets. A JSON endpoint returns a decision and the reason.

```elixir
# lib/my_app/app_policy.ex
defmodule MyApp.AppPolicy do
  alias AppBlockList.App

  @blocked ["Social Networking", "Gaming", "Gambling", "Dating", "Adult",
            "AI / LLM Tools", "VPN / Proxy / Anonymizers"]
  @max_age 12

  def decide(id) do
    case AppBlockList.Queue.lookup(id) do
      {:ok, %App{found: false} = app} ->
        %{decision: "review", reason: app.error}

      {:ok, app} ->
        cond do
          App.blocked_by?(app, @blocked) ->
            %{decision: "blocked", reason: App.matching_categories(app, @blocked), app: App.to_map(app)}

          (age = App.minimum_age(app)) && age > @max_age ->
            %{decision: "blocked", reason: ["Age rating " <> app.age_rating], app: App.to_map(app)}

          true ->
            %{decision: "allowed", app: App.to_map(app)}
        end

      {:error, %AppBlockList.Error{reason: :invalid_id}} ->
        %{decision: "invalid"}

      {:error, _} ->
        %{decision: "unavailable"}
    end
  end
end
```

```elixir
# lib/my_app_web/controllers/app_check_controller.ex
defmodule MyAppWeb.AppCheckController do
  use MyAppWeb, :controller

  def show(conn, %{"id" => id}) do
    result = MyApp.AppPolicy.decide(id)

    status =
      case result.decision do
        "invalid" -> 422
        "unavailable" -> 503
        _ -> 200
      end

    conn |> put_status(status) |> json(result)
  end
end
```

```elixir
# lib/my_app_web/router.ex
scope "/api", MyAppWeb do
  pipe_through [:api, :require_staff]
  get "/app-check/:id", AppCheckController, :show
end
```

Each teacher request is answered from the queue's cache when someone already asked about the same app that day. For US schools this check is one piece of a wider Internet Safety Policy under the [Children's Internet Protection Act](https://www.fcc.gov/consumers/guides/childrens-internet-protection-act). AppBlockList keeps a starter page on [blocking apps on school iPads](https://www.appblocklist.com/schools/apps-to-block-on-school-ipads.php).

---

## Example 2: a GenServer that drains an inventory backlog

MDM exports often contain tens of thousands of installed-app rows. This worker loads distinct identifiers, then processes one per tick through the queue, writing results to the database as it goes. A restart resumes from whatever is still unchecked.

```elixir
defmodule MyApp.InventoryWorker do
  use GenServer
  require Logger

  alias MyApp.{Repo, InstalledApp}
  import Ecto.Query

  @tick 250  # ms between items; the Queue enforces its own interval too

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    send(self(), :next)
    {:ok, %{done: 0}}
  end

  @impl true
  def handle_info(:next, state) do
    case next_unchecked() do
      nil ->
        Logger.info("inventory check complete: #{state.done} apps")
        Process.send_after(self(), :next, :timer.hours(6))
        {:noreply, state}

      row ->
        handle_row(row, state)
    end
  end

  defp handle_row(row, state) do
    case AppBlockList.Queue.lookup(row.identifier) do
      {:ok, app} ->
        row
        |> InstalledApp.changeset(%{
          checked_at: DateTime.utc_now(),
          found: app.found,
          name: app.name,
          age_rating: app.age_rating,
          categories: app.filtering_categories,
          android_package: app.android_package
        })
        |> Repo.update!()

        Process.send_after(self(), :next, @tick)
        {:noreply, %{state | done: state.done + 1}}

      {:error, %AppBlockList.Error{reason: :invalid_id}} ->
        Repo.update!(InstalledApp.changeset(row, %{checked_at: DateTime.utc_now(), found: false}))
        send(self(), :next)
        {:noreply, state}

      {:error, %AppBlockList.Error{reason: :quota_exceeded}} ->
        Logger.warning("AppBlockList monthly lookups used, pausing 24h")
        Process.send_after(self(), :next, :timer.hours(24))
        {:noreply, state}

      {:error, err} ->
        Logger.warning("lookup failed (#{err.reason}), retrying in a minute")
        Process.send_after(self(), :next, :timer.minutes(1))
        {:noreply, state}
    end
  end

  defp next_unchecked do
    InstalledApp
    |> where([a], is_nil(a.checked_at))
    |> limit(1)
    |> Repo.one()
  end
end
```

Why a tick loop instead of `Enum.each`? The GenServer stays responsive to supervision and code reloads, a crash loses at most one item, and quota or error back-off is just a longer `send_after`. With 250 ms per item the worker handles about 14,000 distinct apps an hour, comfortably inside a 100,000 lookup month for most fleets.

Once statuses are in the database, the blocked bundle IDs go into the iOS Restrictions payload and blocked packages into managed Google Play policy. [Android Enterprise for developers](https://developer.android.com/work) covers the Android side; AppBlockList has walkthroughs for [Intune](https://www.appblocklist.com/mdm/block-apps-intune.php), [Jamf](https://www.appblocklist.com/mdm/block-apps-jamf.php) and [a hand-built .mobileconfig](https://www.appblocklist.com/mdm/mobileconfig-block-apps.php).

---

## Example 3: a Mix task that fails CI when an approved app drifts

Some organizations keep their approved-apps list in Git, reviewed like code. This task re-checks every entry and exits non-zero when one now falls in a blocked category, so the pipeline turns red before the list is pushed to devices.

```elixir
# lib/mix/tasks/apps.audit.ex
defmodule Mix.Tasks.Apps.Audit do
  use Mix.Task
  @shortdoc "Fails if any approved app is in a blocked category"

  @blocked ["Gambling", "Dating", "Adult", "VPN / Proxy / Anonymizers"]

  @impl true
  def run([path]) do
    Mix.Task.run("app.start")
    ids = path |> File.read!() |> String.split("\n", trim: true)
    client = AppBlockList.Client.new(retries: 3)

    case AppBlockList.Client.lookup_many(client, ids, pause: 100) do
      {:ok, results} ->
        report(results)

      {:error, err, _partial} ->
        Mix.raise("audit aborted: #{err.reason} #{err.message}")
    end
  end

  defp report(results) do
    offenders =
      for {id, {:ok, app}} <- results, AppBlockList.App.blocked_by?(app, @blocked) do
        {id, app.name, AppBlockList.App.matching_categories(app, @blocked)}
      end

    unknown = for {id, {:ok, %{found: false}}} <- results, do: id

    Enum.each(unknown, &Mix.shell().info("unknown: #{&1}"))

    if offenders == [] do
      Mix.shell().info("#{length(results)} approved apps checked, none blocked")
    else
      for {id, name, cats} <- offenders,
          do: Mix.shell().error("#{id} (#{name}): #{Enum.join(cats, ", ")}")

      exit({:shutdown, 1})
    end
  end
end
```

```yaml
# .github/workflows/apps.yml (excerpt)
- run: mix apps.audit priv/approved_ios_apps.txt
  env:
    APPBLOCKLIST_API_KEY: ${{ secrets.APPBLOCKLIST_API_KEY }}
```

`lookup_many/3` runs sequentially and halts with partial results on `:unauthorized` or `:quota_exceeded`, so a misconfigured secret fails fast instead of producing a misleading green build.

---

## Why this data

- **Policies that read like policies.** "Block Gambling and VPN / Proxy / Anonymizers" survives new app releases; a list of 400 bundle IDs does not.
- **Two stores, one record.** About 800,000 iOS apps carry their Google Play twin and 3.9 million Google Play package names are tracked.
- **Web and app alignment.** The 58 categories are shared with the website database, so your network filter and MDM agree.
- **Explainable outcomes.** `matching_categories/2` returns the exact reason for every refusal.

On the governance side, [NIST SP 800-124 Rev. 2](https://csrc.nist.gov/pubs/sp/800/124/r2/final) treats application vetting and allow or deny lists as standard controls for managed mobile devices. Responses are standard [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) JSON, decoded with Jason.

---

## Plans

| Product | Price |
|---|---|
| App Lookup API | $99 per month for 100,000 lookups, higher volumes quoted |
| App Blocklists for MDM, School or Business | $99/month or $990/year per organization |
| Districts and IT Providers | $249/month or $2,490/year, unlimited schools or clients, API with 100,000 lookups a month included |
| Mobile App Database | $999 for the top 100,000 apps, $1,999 for the top 500,000, one-time |

Only 200 answers count as lookups. Full terms on the [pricing page](https://www.appblocklist.com/pricing.php).

---

## FAQ

### Why not use Task.async_stream for speed?

The service asks for requests one after another, not in parallel. Route lookups through `AppBlockList.Queue` and size the job to run over time. For bulk work across the whole catalog, the licensed [App Store metadata database](https://www.appblocklist.com/mobile-app-database.php) covers 1,874,397 iPhone and iPad apps.

### Does a 404 count against my monthly lookups?

No. One lookup is counted per 200 answer.

### Can I use Finch or Mint directly instead of Req?

The client calls `Req.request/1`, which runs on Finch. Pass `req_options:` to `Client.new/1` to set a custom Finch pool, a proxy or connection options.

### How do I test code that calls the API?

Use Req's `:adapter` option to answer in-process, as the package's own tests do:

```elixir
adapter = fn req -> {req, Req.Response.new(status: 404, body: ~s({"found": false, "error": "App not found."}))} end
client = AppBlockList.Client.new(api_key: "test", req_options: [adapter: adapter])
```

Or skip HTTP entirely and build results with `AppBlockList.Response.parse/2`.

### Is there a list I can import without writing code?

Yes. The [MDM app blocklist feed](https://www.appblocklist.com/mdm-app-blocklist-feed.php) is refreshed monthly in six formats, including Intune and Jamf import files. There are also curated pages for [AI apps](https://www.appblocklist.com/lists/ai-apps-list.php) and [VPN and proxy apps](https://www.appblocklist.com/lists/vpn-proxy-apps-list.php).

### How do I find an identifier for one app?

Use the [iOS bundle ID lookup](https://www.appblocklist.com/tools/bundle-id-lookup.php) or the [Google Play package lookup](https://www.appblocklist.com/tools/package-name-lookup.php), or the [Google Admin guide](https://www.appblocklist.com/mdm/google-admin-block-apps.php) for Chromebook and Android fleets.

---

## Running the tests

```bash
mix deps.get
mix test
```

No network or key is needed.

---

## Links

- [AppBlockList](https://www.appblocklist.com/)
- [Support](https://www.appblocklist.com/contact.php), info@alpha-quantum.com
- [Source on GitHub](https://github.com/explainableaixai/appblocklist-elixir)

The network half of the same policy, from Alpha Quantum:

- [AI tool domain list for firewalls](https://www.aitoolsblocklist.com)
- [CIPA filtering for K-12 networks](https://www.cipawebfiltering.com)
- [120 million domain web filtering dataset](https://www.webfilteringdatabase.com)
- [URL categorization data](https://www.urlcategorizationdatabase.com)
- [real-time website categorization](https://www.websitecategorizationapi.com)

---

## Related packages

- [appblocklist on npm](https://www.npmjs.com/package/appblocklist) for Node.js
- [appblocklist on PyPI](https://pypi.org/project/appblocklist/) for Python
- [appblocklist-php](https://github.com/explainableaixai/appblocklist-php) for PHP
- [appblocklist-ruby](https://github.com/explainableaixai/appblocklist-ruby) for Ruby
- [appblocklist-dart](https://github.com/explainableaixai/appblocklist-dart) for Dart and Flutter
- [appblocklist-go](https://github.com/explainableaixai/appblocklist-go) for Go
- [appblocklist-java](https://github.com/explainableaixai/appblocklist-java) for Java
- [appblocklist-rust](https://github.com/explainableaixai/appblocklist-rust) for Rust
- [appblocklist-dotnet](https://github.com/explainableaixai/appblocklist-dotnet) for C# and .NET
- [explainableaixai/appblocklist](https://github.com/explainableaixai/appblocklist), also on [GitLab](https://gitlab.com/url-classifications/appblocklist)

---

## License

MIT. Copyright (c) 2026 Alpha Quantum.
