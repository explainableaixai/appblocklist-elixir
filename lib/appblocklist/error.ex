defmodule AppBlockList.Error do
  @moduledoc """
  Error returned (or raised by the bang functions) for anything other than
  a 200 or 404 answer.

  | reason            | HTTP | meaning                                               |
  |-------------------|------|-------------------------------------------------------|
  | `:invalid_id`     | 400  | id missing, too long, or not a recognised identifier  |
  | `:unauthorized`   | 401  | missing or invalid API key                            |
  | `:quota_exceeded` | 403  | monthly lookups used; see `monthly_lookups/1`         |
  | `:server_error`   | 5xx  | temporary, safe to retry                              |
  | `:transport`      | none | network failure, timeout or a body that is not JSON   |
  | `:unexpected`     | other| any other status                                      |
  """

  defexception [:reason, :status, :message, body: %{}]

  @type reason ::
          :invalid_id | :unauthorized | :quota_exceeded | :server_error | :transport | :unexpected

  @type t :: %__MODULE__{
          reason: reason(),
          status: non_neg_integer() | nil,
          message: String.t(),
          body: map()
        }

  @doc "The `monthly_lookups` value from a 403 body, or nil."
  @spec monthly_lookups(t()) :: integer() | nil
  def monthly_lookups(%__MODULE__{body: %{"monthly_lookups" => n}}) when is_integer(n), do: n

  def monthly_lookups(%__MODULE__{body: %{"monthly_lookups" => n}}) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> int
      :error -> nil
    end
  end

  def monthly_lookups(%__MODULE__{}), do: nil

  @doc "True for errors worth retrying later (5xx and transport)."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{reason: r}), do: r in [:server_error, :transport]
end
