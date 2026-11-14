defmodule AppBlockList.Queue do
  @moduledoc """
  A GenServer that owns one client and sends lookups one at a time.

  Every caller in your application goes through the same process, so the
  service sees an ordered stream of requests with at least `:interval`
  milliseconds between them, no matter how many LiveViews, Oban jobs or
  Broadway stages ask at once. Answers (including not-found answers) are
  cached for `:ttl` milliseconds.

      children = [
        {AppBlockList.Queue, interval: 150, ttl: :timer.hours(24)}
      ]

      {:ok, app} = AppBlockList.Queue.lookup("com.zhiliaoapp.musically")

  Options: `:name` (default `AppBlockList.Queue`), `:interval` (ms, default
  100), `:ttl` (ms, default 24 hours), `:client` (an `AppBlockList.Client`;
  default `AppBlockList.Client.new()` at start), any other option is passed
  to `AppBlockList.Client.new/1`.
  """

  use GenServer

  alias AppBlockList.Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Looks up an ID through the queue. Same return values as `AppBlockList.Client.lookup/2`."
  @spec lookup(GenServer.server(), String.t(), timeout()) ::
          {:ok, AppBlockList.App.t()} | {:error, AppBlockList.Error.t()}
  def lookup(server \\ __MODULE__, id, timeout \\ 60_000) do
    GenServer.call(server, {:lookup, id}, timeout)
  end

  @doc "Drops every cached answer."
  def clear_cache(server \\ __MODULE__), do: GenServer.cast(server, :clear_cache)

  @impl true
  def init(opts) do
    {interval, opts} = Keyword.pop(opts, :interval, 100)
    {ttl, opts} = Keyword.pop(opts, :ttl, :timer.hours(24))
    {client, opts} = Keyword.pop(opts, :client)

    {:ok,
     %{
       client: client || Client.new(opts),
       interval: interval,
       ttl: ttl,
       last_at: nil,
       cache: %{}
     }}
  end

  @impl true
  def handle_call({:lookup, id}, _from, state) do
    key = id |> to_string() |> String.trim()
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      {expires, result} when expires > now ->
        {:reply, result, state}

      _ ->
        wait(state, now)
        result = Client.lookup(state.client, key)
        done = System.monotonic_time(:millisecond)
        cache = maybe_cache(state.cache, key, result, done + state.ttl)
        {:reply, result, %{state | last_at: done, cache: cache}}
    end
  end

  @impl true
  def handle_cast(:clear_cache, state), do: {:noreply, %{state | cache: %{}}}

  defp wait(%{last_at: nil}, _now), do: :ok

  defp wait(%{last_at: last, interval: interval}, now) do
    remaining = interval - (now - last)
    if remaining > 0, do: Process.sleep(remaining)
    :ok
  end

  defp maybe_cache(cache, key, {:ok, _} = result, expires), do: Map.put(cache, key, {expires, result})
  defp maybe_cache(cache, _key, _error, _expires), do: cache
end
