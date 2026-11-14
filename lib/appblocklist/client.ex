defmodule AppBlockList.Client do
  @moduledoc """
  HTTP client for the App Lookup API.

      client = AppBlockList.Client.new()            # reads APPBLOCKLIST_API_KEY
      {:ok, app} = AppBlockList.Client.lookup(client, "com.zhiliaoapp.musically")

  One ID per request. For many IDs, use `lookup_many/3` (sequential) or run
  an `AppBlockList.Queue` so that every process in your app shares one
  ordered stream of requests.
  """

  alias AppBlockList.{App, Error, Response}

  @version "1.0.0"
  @default_base_url "https://www.appblocklist.com/api/v1/app"
  @max_id_length 200

  defstruct api_key: nil,
            base_url: @default_base_url,
            receive_timeout: 15_000,
            retries: 2,
            retry_delay: 1_000,
            user_agent: "appblocklist-elixir/#{@version} (+https://www.appblocklist.com)",
            req_options: []

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          receive_timeout: pos_integer(),
          retries: non_neg_integer(),
          retry_delay: non_neg_integer(),
          user_agent: String.t(),
          req_options: keyword()
        }

  @doc """
  Builds a client.

  Options: `:api_key` (default `System.get_env("APPBLOCKLIST_API_KEY")`, then
  `Application.get_env(:appblocklist, :api_key)`), `:base_url`,
  `:receive_timeout` (ms, default 15000), `:retries` (default 2),
  `:retry_delay` (ms before the first retry, doubled each time, default 1000),
  `:user_agent`, `:req_options` (extra options passed to `Req.request/1`).

  Raises `ArgumentError` when no key can be found.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    key =
      Keyword.get(opts, :api_key) ||
        System.get_env("APPBLOCKLIST_API_KEY") ||
        Application.get_env(:appblocklist, :api_key)

    if key in [nil, ""] do
      raise ArgumentError, "no API key: pass :api_key or set APPBLOCKLIST_API_KEY"
    end

    struct!(__MODULE__, Keyword.put(opts, :api_key, key))
  end

  @doc """
  Looks up one app by iOS bundle ID, App Store ID (`"835599320"` or
  `"id835599320"`) or Android package name.

  Returns `{:ok, %AppBlockList.App{}}` (with `found: false` for a 404) or
  `{:error, %AppBlockList.Error{}}`. Server and transport errors are retried.
  """
  @spec lookup(t(), String.t()) :: {:ok, App.t()} | {:error, Error.t()}
  def lookup(%__MODULE__{} = client, id) do
    with {:ok, id} <- normalize_id(id) do
      do_lookup(client, id, 0, client.retry_delay)
    end
  end

  @doc "Like `lookup/2` but returns the app or raises `AppBlockList.Error`."
  @spec lookup!(t(), String.t()) :: App.t()
  def lookup!(client, id) do
    case lookup(client, id) do
      {:ok, app} -> app
      {:error, err} -> raise err
    end
  end

  @doc """
  Looks up IDs strictly one after another. Blank and duplicate IDs are
  skipped. Returns `{:ok, results}` where `results` is a list of
  `{id, {:ok, app} | {:error, error}}` in input order, or stops early with
  `{:error, error, partial_results}` on `:unauthorized` or `:quota_exceeded`.

  Option `:pause` (ms) waits between requests.
  """
  @spec lookup_many(t(), Enumerable.t(), keyword()) ::
          {:ok, list()} | {:error, Error.t(), list()}
  def lookup_many(%__MODULE__{} = client, ids, opts \\ []) do
    pause = Keyword.get(opts, :pause, 0)

    ids
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {id, i}, {:ok, acc} ->
      if i > 0 and pause > 0, do: Process.sleep(pause)

      case lookup(client, id) do
        {:error, %Error{reason: r} = err} when r in [:unauthorized, :quota_exceeded] ->
          {:halt, {:error, err, Enum.reverse(acc)}}

        result ->
          {:cont, {:ok, [{id, result} | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  @doc "Trims an ID and enforces the 200 character limit without a request."
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" ->
        {:error, %Error{reason: :invalid_id, message: "id is empty"}}

      String.length(id) > @max_id_length ->
        {:error, %Error{reason: :invalid_id, message: "id is longer than #{@max_id_length} characters"}}

      true ->
        {:ok, id}
    end
  end

  def normalize_id(_), do: {:error, %Error{reason: :invalid_id, message: "id must be a string"}}

  defp do_lookup(client, id, attempt, delay) do
    case request(client, id) do
      {:error, %Error{} = err} = result ->
        if Error.retryable?(err) and attempt < client.retries do
          if delay > 0, do: Process.sleep(delay)
          do_lookup(client, id, attempt + 1, delay * 2)
        else
          result
        end

      ok ->
        ok
    end
  end

  defp request(client, id) do
    opts =
      [
        method: :get,
        url: client.base_url,
        params: [id: id],
        headers: [
          {"x-api-key", client.api_key},
          {"accept", "application/json"},
          {"user-agent", client.user_agent}
        ],
        receive_timeout: client.receive_timeout,
        decode_body: false,
        retry: false
      ]
      |> Keyword.merge(client.req_options)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        Response.parse(status, body)

      {:error, exception} ->
        {:error,
         %Error{reason: :transport, message: "request failed: " <> Exception.message(exception)}}
    end
  end
end
