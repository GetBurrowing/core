defmodule Platform.Social.Analytics.ZernioTest do
  use Platform.DataCase, async: false

  alias Platform.Social.Analytics.Zernio
  alias Platform.Social.Publisher.Zernio, as: Publisher

  @fixture_dir Path.expand("../../../fixtures/analytics", __DIR__)
  @key "analytics-fixture-key-not-real"

  setup do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, @key,
        scope: {:integration, nil},
        provider: "social"
      )

    :ok
  end

  defp fixture(name),
    do: @fixture_dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()

  defp stub(body, status \\ 200, headers \\ []) do
    owner = self()

    Req.Test.stub(Publisher, fn conn ->
      send(owner, {:request, conn.method, conn.request_path, conn.query_string, conn.req_headers})

      conn =
        Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  test "OpenAPI delta page retains identity, cursor and only the six metrics" do
    stub(fixture("delta"))

    assert {:ok, %{data: [snapshot], next_cursor: cursor, has_more: true}} =
             Zernio.delta("opaque+/= ?", profile_id: "profile-A", limit: 50)

    assert cursor == fixture("delta")["nextCursor"]
    assert snapshot.post_id == "65f1c0a9e2b5af0012ab34cd"
    assert snapshot.platform_post_id == "dQw4w9WgXcQ"
    assert snapshot.account_id == "64e1f0a9e2b5af0012ab34cd"
    assert snapshot.profile_id == "64e1f0a9e2b5af0012ab34aa"
    assert snapshot.platform == "youtube"
    assert snapshot.synced_at == ~U[2026-09-01 17:11:38.000000Z]
    assert {:ok, _} = Ecto.Type.dump(:utc_datetime_usec, snapshot.synced_at)
    refute snapshot.deleted?

    assert snapshot.metrics == %{
             "views" => 9310,
             "likes" => 342,
             "comments" => 28,
             "shares" => 45,
             "saves" => 12,
             "reach" => 12350
           }

    assert_received {:request, "GET", "/api/v1/analytics/delta", query, headers}

    assert URI.decode_query(query) == %{
             "cursor" => "opaque+/= ?",
             "profileId" => "profile-A",
             "limit" => "50"
           }

    assert {"authorization", "Bearer " <> @key} in headers
  end

  test "bootstrap omits cursor and preserves an empty page's current position" do
    stub(fixture("bootstrap"))
    assert {:ok, %{data: [], next_cursor: cursor, has_more: false}} = Zernio.delta()
    assert cursor == fixture("bootstrap")["nextCursor"]
    assert_received {:request, "GET", "/api/v1/analytics/delta", "", _}
  end

  test "baseline reads each platform, never aggregate analytics, and retains alternate post id" do
    body = fixture("single_post")
    [entry] = body["platformAnalytics"]

    body = %{
      body
      | "analytics" => %{"views" => 999_999_999},
        "latePostId" => "original-publisher-id",
        "platformAnalytics" => [
          put_in(entry, ["analytics", "views"], 12_400),
          %{
            entry
            | "platformPostId" => "second-id",
              "accountId" => "second-account",
              "analytics" => %{"views" => 0, "lastUpdated" => "2024-11-02T08:30:00Z"}
          }
        ]
    }

    stub(body)
    assert {:ok, result} = Zernio.post("original-publisher-id")
    assert result.post_id == "65f1c0a9e2b5af0012ab34cd"
    assert result.late_post_id == "original-publisher-id"
    assert [first, second] = result.data
    assert first.metrics["views"] == 12_400
    assert second.metrics["views"] == 0
    assert first.profile_id == nil
    assert second.platform_post_id == "second-id"
    assert_received {:request, "GET", "/api/v1/analytics", query, _}
    assert URI.decode_query(query) == %{"postId" => "original-publisher-id"}
  end

  test "absent, null or invalid views never become zero or impressions" do
    body = fixture("delta")
    [snapshot] = body["data"]

    for metrics <- [
          %{"impressions" => 12400},
          %{"views" => nil},
          %{"views" => -1},
          %{"views" => "12400"},
          %{"views" => 1.2}
        ] do
      stub(%{body | "data" => [%{snapshot | "metrics" => metrics}]})
      assert {:ok, %{data: [result]}} = Zernio.delta("C")
      refute Map.has_key?(result.metrics, "views")
    end

    stub(%{body | "data" => [%{snapshot | "metrics" => %{"views" => 0}}]})
    assert {:ok, %{data: [%{metrics: %{"views" => 0}}]}} = Zernio.delta("C")
  end

  test "feed order is preserved even when syncedAt goes backwards; deletion is explicit" do
    body = fixture("delta")
    [snapshot] = body["data"]
    older = %{snapshot | "syncedAt" => "2026-08-31T00:00:00Z", "isDeleted" => true}
    stub(%{body | "data" => [snapshot, older]})
    assert {:ok, %{data: [first, second]}} = Zernio.delta("C")
    assert DateTime.compare(first.synced_at, second.synced_at) == :gt
    assert second.deleted?
  end

  test "malformed pages cannot silently drop snapshots and advance a cursor" do
    body = fixture("delta")
    [snapshot] = body["data"]

    for malformed <- [
          Map.delete(body, "nextCursor"),
          %{body | "hasMore" => nil},
          %{body | "data" => [Map.delete(snapshot, "postId")]},
          %{body | "data" => [%{snapshot | "syncedAt" => "bad"}]},
          %{body | "data" => [%{snapshot | "platformPostId" => ""}]}
        ] do
      stub(malformed)
      assert {:error, :invalid_response} = Zernio.delta("C")
    end
  end

  test "baseline skips unsynced platforms without replacing their last values" do
    body = fixture("single_post")
    [entry] = body["platformAnalytics"]

    stub(%{
      body
      | "platformAnalytics" => [
          %{entry | "syncStatus" => "pending"},
          %{entry | "syncStatus" => "unavailable"}
        ]
    })

    assert {:ok, %{data: []}} = Zernio.post("post-id")
  end

  test "202/424 return no snapshots, even if their body contains metrics" do
    stub(fixture("single_post"), 202)
    assert {:error, :sync_pending} = Zernio.post("post-id")
    stub(fixture("single_post"), 424)
    assert {:error, :analytics_unavailable} = Zernio.post("post-id")
  end

  test "429 and 503 expose Retry-After and do not retry inside the client" do
    for status <- [429, 503] do
      stub(%{"error" => "try later"}, status, [{"retry-after", "75"}])
      assert {:error, {:retry_after, ^status, 75}} = Zernio.delta("C")
      assert_received {:request, "GET", _, _, _}
      refute_received {:request, _, _, _, _}
    end
  end

  test "HTTP date Retry-After is decoded; missing or malformed metadata stays nil" do
    stub(%{}, 503, [{"retry-after", "Thu, 29 Oct 2037 19:00:00 GMT"}])
    assert {:error, {:retry_after, 503, seconds}} = Zernio.delta("C")
    assert seconds > 0

    for headers <- [[], [{"retry-after", "invalid"}]] do
      stub(%{}, 503, headers)
      assert {:error, {:retry_after, 503, nil}} = Zernio.delta("C")
    end
  end

  test "HTTP errors and network failures do not masquerade as empty pages" do
    stub(%{}, 400)
    assert {:error, {:http_status, 400}} = Zernio.delta("expired")
    Req.Test.stub(Publisher, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, {:transport, %Req.TransportError{reason: :timeout}}} = Zernio.delta("C")
  end

  test "missing credentials fail closed before HTTP" do
    Platform.Repo.delete_all(Platform.Vault.Credential)
    Req.Test.stub(Publisher, fn _ -> flunk("analytics requested without a key") end)
    assert {:error, :credentials_unavailable} = Zernio.delta()
    assert {:error, :credentials_unavailable} = Zernio.post("post-id")
  end
end
