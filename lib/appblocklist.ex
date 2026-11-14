defmodule AppBlockList do
  @moduledoc """
  Elixir client for the AppBlockList App Lookup API (https://www.appblocklist.com).

      {:ok, app} = AppBlockList.lookup("com.zhiliaoapp.musically")
      app.filtering_categories
      #=> ["Social Networking", "Streaming Media"]

  See `AppBlockList.Client` for options, `AppBlockList.Queue` for a
  supervised, rate-limited lookup process, `AppBlockList.App` for the result
  struct and `AppBlockList.Error` for error reasons.
  """

  alias AppBlockList.Client

  @version "1.0.0"

  @doc """
  Looks up one app with a client built from `opts` (or the environment).
  Returns `{:ok, %AppBlockList.App{}}` or `{:error, %AppBlockList.Error{}}`.
  """
  @spec lookup(String.t(), keyword()) ::
          {:ok, AppBlockList.App.t()} | {:error, AppBlockList.Error.t()}
  def lookup(id, opts \\ []), do: opts |> Client.new() |> Client.lookup(id)

  @doc "Like `lookup/2` but returns the app or raises."
  @spec lookup!(String.t(), keyword()) :: AppBlockList.App.t()
  def lookup!(id, opts \\ []), do: opts |> Client.new() |> Client.lookup!(id)

  @doc "Library version."
  @spec version() :: String.t()
  def version, do: @version
end
