# Usage:
#   APPBLOCKLIST_API_KEY=your_key mix run examples/batch.exs com.zhiliaoapp.musically 835599320 com.openai.chatgpt
#
# Looks the IDs up one after another through a supervised AppBlockList.Queue
# and prints a verdict for each.

blocked = ["Social Networking", "Gaming", "Gambling", "Dating", "Adult", "VPN / Proxy / Anonymizers"]

ids =
  case System.argv() do
    [] -> ["com.zhiliaoapp.musically"]
    list -> list
  end

{:ok, _pid} = AppBlockList.Queue.start_link(interval: 200)

for id <- ids do
  case AppBlockList.Queue.lookup(id) do
    {:ok, %AppBlockList.App{found: true} = app} ->
      verdict =
        case AppBlockList.App.matching_categories(app, blocked) do
          [] -> "allow"
          hits -> "BLOCK (" <> Enum.join(hits, ", ") <> ")"
        end

      IO.puts("#{id}: #{app.name} | #{app.age_rating} | #{Enum.join(app.filtering_categories, ", ")} | #{verdict}")

    {:ok, app} ->
      IO.puts("#{id}: not found (#{app.error})")

    {:error, err} ->
      IO.puts(:stderr, "#{id}: #{err.reason} #{err.message}")
  end
end
