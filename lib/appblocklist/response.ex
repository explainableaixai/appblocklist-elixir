defmodule AppBlockList.Response do
  @moduledoc """
  Pure translation of an HTTP status and body into a result. No network.
  """

  alias AppBlockList.{App, Error}

  @doc """
  Parses a raw response body (binary or already decoded map).

  Returns `{:ok, %AppBlockList.App{}}` for 200 and 404 (with `found: false`),
  and `{:error, %AppBlockList.Error{}}` for everything else.
  """
  @spec parse(non_neg_integer(), binary() | map()) :: {:ok, App.t()} | {:error, Error.t()}
  def parse(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        parse(status, map)

      _ when status >= 500 ->
        {:error, %Error{reason: :server_error, status: status, message: "HTTP #{status} from AppBlockList"}}

      _ ->
        {:error,
         %Error{reason: :transport, status: status, message: "Unexpected non-JSON response (HTTP #{status})"}}
    end
  end

  def parse(200, map) when is_map(map), do: {:ok, App.from_map(map)}
  def parse(404, map) when is_map(map), do: {:ok, App.from_map(Map.put(map, "found", false))}

  def parse(status, map) when is_map(map) do
    {:error,
     %Error{
       reason: reason(status),
       status: status,
       message: Map.get(map, "error", "HTTP #{status}") |> to_string(),
       body: map
     }}
  end

  defp reason(400), do: :invalid_id
  defp reason(401), do: :unauthorized
  defp reason(403), do: :quota_exceeded
  defp reason(s) when s >= 500 and s <= 599, do: :server_error
  defp reason(_), do: :unexpected
end
