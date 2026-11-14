defmodule AppBlockListTest do
  use ExUnit.Case, async: true

  alias AppBlockList.{App, Client, Error, Response}

  # No network: tests parse sample JSON, or use Req's :adapter option to
  # answer requests in-process.

  @found """
  {
    "found": true,
    "name": "TikTok - Videos, Shop & LIVE",
    "developer": "TikTok Ltd.",
    "bundle_id": "com.zhiliaoapp.musically",
    "app_store_id": "835599320",
    "android_package": "com.zhiliaoapp.musically",
    "app_store_genre": "Entertainment",
    "age_rating": "12+",
    "filtering_categories": ["Social Networking", "Streaming Media"],
    "developer_domain": "tiktok.com",
    "iab_category": "Technology & Computing > Computing > Internet > Social Networking"
  }
  """

  defp client_with(fun, opts \\ []) do
    adapter = fn request -> {request, fun.(request)} end

    Client.new(
      Keyword.merge(
        [api_key: "test-key", retry_delay: 0, req_options: [adapter: adapter]],
        opts
      )
    )
  end

  defp resp(status, body), do: Req.Response.new(status: status, body: body)

  describe "Response.parse/2" do
    test "found app" do
      assert {:ok, %App{} = app} = Response.parse(200, @found)
      assert app.found
      assert app.developer == "TikTok Ltd."
      assert app.app_store_id == "835599320"
      assert app.filtering_categories == ["Social Networking", "Streaming Media"]
      assert App.primary_category(app) == "Social Networking"
      assert App.minimum_age(app) == 12
      assert App.has_category?(app, "streaming media")
      assert App.blocked_by?(app, ["Gambling", "Social Networking"])
      refute App.blocked_by?(app, ["Gambling"])
      assert App.matching_categories(app, ["Streaming Media"]) == ["Streaming Media"]
    end

    test "404 is a result with found: false" do
      assert {:ok, app} = Response.parse(404, ~s({"found": false, "error": "App not found."}))
      refute app.found
      assert app.error == "App not found."
      assert app.filtering_categories == []
      assert App.primary_category(app) == nil
      refute App.pending_android?(app)
    end

    test "Google Play app not yet categorized" do
      body =
        ~s({"found": false, "android_package": "com.example.newapp", ) <>
          ~s("error": "Listed on Google Play, not yet in the categorized database."})

      assert {:ok, app} = Response.parse(404, body)
      assert App.pending_android?(app)
      assert app.android_package == "com.example.newapp"
    end

    test "error statuses map to reasons" do
      for {status, reason} <- [
            {400, :invalid_id},
            {401, :unauthorized},
            {403, :quota_exceeded},
            {500, :server_error},
            {418, :unexpected}
          ] do
        assert {:error, %Error{reason: ^reason, status: ^status}} =
                 Response.parse(status, ~s({"error": "x"}))
      end
    end

    test "403 exposes monthly_lookups" do
      {:error, err} = Response.parse(403, ~s({"error": "Monthly lookups used.", "monthly_lookups": 100000}))
      assert Error.monthly_lookups(err) == 100_000
      refute Error.retryable?(err)
    end

    test "non-JSON 502 is a retryable server error" do
      assert {:error, %Error{reason: :server_error} = err} = Response.parse(502, "<html>Bad gateway</html>")
      assert Error.retryable?(err)
    end

    test "to_map round trip" do
      {:ok, app} = Response.parse(200, @found)
      map = app |> App.to_map() |> Jason.encode!() |> Jason.decode!()
      assert App.from_map(map).bundle_id == "com.zhiliaoapp.musically"
      assert map["age_rating"] == "12+"
    end
  end

  describe "Client.lookup/2 with an in-process adapter" do
    test "sends id, key and user agent" do
      parent = self()

      client =
        client_with(fn req ->
          send(parent, {:request, req})
          resp(200, @found)
        end)

      assert {:ok, %App{found: true}} = Client.lookup(client, "  id835599320 ")
      assert_received {:request, req}
      assert URI.decode_query(req.url.query) == %{"id" => "id835599320"}
      assert Req.Request.get_header(req, "x-api-key") == ["test-key"]

      assert Req.Request.get_header(req, "user-agent") ==
               ["appblocklist-elixir/1.0.0 (+https://www.appblocklist.com)"]
    end

    test "retries server errors" do
      counter = :counters.new(1, [])

      client =
        client_with(fn _req ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) < 3,
            do: resp(500, ~s({"error": "temporary"})),
            else: resp(200, @found)
        end)

      assert {:ok, %App{found: true}} = Client.lookup(client, "com.zhiliaoapp.musically")
      assert :counters.get(counter, 1) == 3
    end

    test "rejects an over-long id without a request" do
      client = client_with(fn _ -> flunk("no request expected") end)
      assert {:error, %Error{reason: :invalid_id}} = Client.lookup(client, String.duplicate("a", 201))
    end

    test "lookup_many de-duplicates and stops on quota" do
      client =
        client_with(fn req ->
          case URI.decode_query(req.url.query) do
            %{"id" => "over.quota"} -> resp(403, ~s({"error": "Monthly lookups used."}))
            _ -> resp(200, @found)
          end
        end)

      assert {:ok, [{"com.zhiliaoapp.musically", {:ok, _}}]} =
               Client.lookup_many(client, ["com.zhiliaoapp.musically", "com.zhiliaoapp.musically", ""])

      assert {:error, %Error{reason: :quota_exceeded}, [{"a.b", {:ok, _}}]} =
               Client.lookup_many(client, ["a.b", "over.quota", "c.d"])
    end
  end

  describe "Queue" do
    test "serves repeated lookups from cache" do
      counter = :counters.new(1, [])

      client =
        client_with(fn _req ->
          :counters.add(counter, 1, 1)
          resp(200, @found)
        end)

      name = :"queue_#{System.unique_integer([:positive])}"
      start_supervised!({AppBlockList.Queue, name: name, client: client, interval: 0})

      assert {:ok, _} = AppBlockList.Queue.lookup(name, "com.zhiliaoapp.musically")
      assert {:ok, _} = AppBlockList.Queue.lookup(name, "com.zhiliaoapp.musically")
      assert :counters.get(counter, 1) == 1
    end
  end

  test "missing key raises" do
    previous = System.get_env("APPBLOCKLIST_API_KEY")
    System.delete_env("APPBLOCKLIST_API_KEY")

    try do
      assert_raise ArgumentError, fn -> Client.new() end
    after
      if previous, do: System.put_env("APPBLOCKLIST_API_KEY", previous)
    end
  end
end
