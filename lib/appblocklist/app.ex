defmodule AppBlockList.App do
  @moduledoc """
  One answer from the App Lookup API.

  A 200 answer gives `found: true`. A 404 answer gives `found: false`; for a
  Google Play app that is not yet categorized, `android_package` is set and
  `pending_android?/1` returns true.
  """

  @string_fields ~w(name developer bundle_id app_store_id android_package app_store_genre
                    age_rating developer_domain iab_category)a

  defstruct found: false,
            name: "",
            developer: "",
            bundle_id: "",
            app_store_id: "",
            android_package: "",
            app_store_genre: "",
            age_rating: "",
            filtering_categories: [],
            developer_domain: "",
            iab_category: "",
            error: nil,
            raw: %{}

  @type t :: %__MODULE__{
          found: boolean(),
          name: String.t(),
          developer: String.t(),
          bundle_id: String.t(),
          app_store_id: String.t(),
          android_package: String.t(),
          app_store_genre: String.t(),
          age_rating: String.t(),
          filtering_categories: [String.t()],
          developer_domain: String.t(),
          iab_category: String.t(),
          error: String.t() | nil,
          raw: map()
        }

  @doc "Builds a struct from a decoded JSON map (string keys)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    strings =
      Enum.map(@string_fields, fn field ->
        {field, to_str(Map.get(map, Atom.to_string(field)))}
      end)

    cats =
      case Map.get(map, "filtering_categories") do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end

    struct!(
      __MODULE__,
      strings ++
        [
          found: Map.get(map, "found") == true,
          filtering_categories: cats,
          error: map |> Map.get("error") |> nil_or_string(),
          raw: map
        ]
    )
  end

  @doc "The most descriptive filtering category, or nil."
  @spec primary_category(t()) :: String.t() | nil
  def primary_category(%__MODULE__{filtering_categories: [first | _]}), do: first
  def primary_category(%__MODULE__{}), do: nil

  @doc "Case-insensitive test for one category."
  @spec has_category?(t(), String.t()) :: boolean()
  def has_category?(%__MODULE__{filtering_categories: cats}, category) do
    needle = normalize(category)
    Enum.any?(cats, &(normalize(&1) == needle))
  end

  @doc "Categories of the app that appear in `blocked`, in ranked order."
  @spec matching_categories(t(), Enumerable.t()) :: [String.t()]
  def matching_categories(%__MODULE__{filtering_categories: cats}, blocked) do
    set = MapSet.new(blocked, &normalize/1)
    Enum.filter(cats, &MapSet.member?(set, normalize(&1)))
  end

  @doc "True when at least one category of the app is in `blocked`."
  @spec blocked_by?(t(), Enumerable.t()) :: boolean()
  def blocked_by?(app, blocked), do: matching_categories(app, blocked) != []

  @doc ~S'The numeric part of the age rating: 12 for "12+", nil when missing.'
  @spec minimum_age(t()) :: non_neg_integer() | nil
  def minimum_age(%__MODULE__{age_rating: rating}) do
    case Regex.run(~r/^(\d+)\+?$/, rating) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @doc "Listed on Google Play but not yet in the categorized database."
  @spec pending_android?(t()) :: boolean()
  def pending_android?(%__MODULE__{found: false, android_package: pkg}) when pkg != "", do: true
  def pending_android?(%__MODULE__{}), do: false

  @doc "Map with the API field names, ready for Jason.encode!/1."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = app) do
    app
    |> Map.from_struct()
    |> Map.drop([:raw])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp normalize(s), do: s |> to_string() |> String.trim() |> String.downcase()
  defp to_str(nil), do: ""
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v), do: to_string(v)
  defp nil_or_string(nil), do: nil
  defp nil_or_string(v), do: to_string(v)
end
