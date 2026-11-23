defmodule Platform.Social.Analytics.PublicationsClientTest do
  use Platform.DataCase, async: false

  alias Platform.Social.Analytics.Zernio
  alias Platform.Social.Publisher.Zernio, as: Publisher

  @opts [from_date: ~D[2026-11-01], to_date: ~D[2026-11-22], profile_ref: "profile-A"]

  setup do
    saved = Application.fetch_env(:social, :youtube_publications_enabled)
    Application.put_env(:social, :youtube_publications_enabled, true)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:social, :youtube_publications_enabled, value)
        :error -> Application.delete_env(:social, :youtube_publications_enabled)
      end
    end)

    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "synthetic-publications-key",
        scope: {:integration, nil},
        provider: "social"
      )

    :ok
  end

  defp row do
    %{
      "postId" => "publisher-id",
      "externalPostId" => "analytics-id",
      "platformPostId" => "abcdefghijk",
      "accountId" => "account-A",
      "profileId" => "profile-A",
      "platform" => "youtube",
      "publishedAt" => "2026-11-16T01:33:50Z",
      "lastSyncedAt" => "2026-11-22T05:06:00Z",
      "syncStatus" => "synced",
      "metrics" => %{"views" => 66, "likes" => 5},
      "isOwner" => true,
      "isAd" => false,
      "platformPostUrl" => "https://untrusted.example/watch"
    }
  end

  defp page do
    %{
      "data" => [row()],
      "pagination" => %{"hasMore" => false, "nextCursor" => nil},
      "meta" => %{
        "fromDate" => "2026-11-01",
        "toDate" => "2026-11-22",
        "stale" => false,
        "staleSince" => nil,
        "missingIds" => []
      }
    }
  end

  defp stub(body, status \\ 200, headers \\ []) do
    owner = self()

    Req.Test.stub(Publisher, fn conn ->
      send(owner, {:request, conn.request_path, URI.decode_query(conn.query_string)})

      conn =
        Enum.reduce(headers, conn, fn {key, value}, conn ->
          Plug.Conn.put_resp_header(conn, key, value)
        end)

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  test "direct publication-list callers cannot override the default-off gate" do
    stub(page())

    for setting <- [:unset, false, "invalid", "true"] do
      if setting == :unset,
        do: Application.delete_env(:social, :youtube_publications_enabled),
        else: Application.put_env(:social, :youtube_publications_enabled, setting)

      assert {:error, :disabled} =
               Zernio.publications("account-A", Keyword.put(@opts, :enabled, true))

      refute_received {:request, _, _}
    end
  end

  test "account list sends only the documented frozen query and opaque cursor" do
    stub(page())

    assert {:ok, %{data: [result], has_more: false, next_cursor: nil}} =
             Zernio.publications("account-A", Keyword.put(@opts, :cursor, "opaque+/= ?"))

    assert_received {:request, "/api/v1/metrics/posts", query}

    assert query == %{
             "accountId" => "account-A",
             "fromDate" => "2026-11-01",
             "toDate" => "2026-11-22",
             "sort" => "published-desc",
             "limit" => "50",
             "origin" => "all",
             "cursor" => "opaque+/= ?"
           }

    assert result.native_id == "abcdefghijk"
    assert result.external_id == "analytics-id"
    assert result.published_at == ~U[2026-11-16 01:33:50.000000Z]
    assert result.vendor_synced_at == ~U[2026-11-22 05:06:00.000000Z]
    assert result.sync_status == "synced"
    assert result.is_owner == true
    assert result.is_ad == false
    assert result.vendor_url == "https://untrusted.example/watch"
  end

  test "null observations remain unknown while genuine zero remains zero" do
    nullable =
      row()
      |> Map.merge(%{
        "postId" => nil,
        "externalPostId" => nil,
        "publishedAt" => nil,
        "lastSyncedAt" => nil,
        "isOwner" => nil,
        "isAd" => nil,
        "metrics" => %{"views" => nil}
      })

    stub(%{page() | "data" => [nullable, %{row() | "metrics" => %{"views" => 0}}]})

    assert {:ok, %{data: [unknown, zero], stale: false, stale_since: nil, missing_ids: []}} =
             Zernio.publications("account-A", @opts)

    assert unknown.metrics["views"] == nil
    assert unknown.external_id == nil
    assert unknown.published_at == nil
    assert unknown.vendor_synced_at == nil
    assert unknown.is_owner == nil
    assert zero.metrics["views"] == 0
  end

  test "explicit stale and missing metadata survives independently of row status" do
    body =
      put_in(page(), ["meta"], %{
        "fromDate" => "2026-11-01",
        "toDate" => "2026-11-22",
        "stale" => true,
        "staleSince" => "2026-11-20T00:00:00Z",
        "missingIds" => ["missing"]
      })

    for status <- ["pending", "unavailable"] do
      stub(put_in(body, ["data"], [%{row() | "syncStatus" => status}]))
      assert {:ok, result} = Zernio.publications("account-A", @opts)
      assert result.stale == true
      assert result.stale_since == "2026-11-20T00:00:00Z"
      assert result.missing_ids == ["missing"]
      assert hd(result.data).sync_status == status
    end
  end

  test "rejects an entire page for wrong identity invalid native IDs or out of window dates" do
    for {field, value} <- [
          {"accountId", "wrong"},
          {"profileId", "wrong"},
          {"platform", "instagram"},
          {"platformPostId", "bad/id"},
          {"platformPostId", "short"},
          {"publishedAt", "2026-10-31T23:59:59Z"},
          {"publishedAt", "2026-11-23T00:00:00Z"},
          {"lastSyncedAt", "invalid"}
        ] do
      stub(%{page() | "data" => [row(), Map.put(row(), field, value)]})
      assert {:error, :invalid_response} = Zernio.publications("account-A", @opts)
    end
  end

  test "requires exact date echoes and a coherent explicit pagination envelope" do
    for body <- [
          Map.delete(page(), "meta"),
          put_in(page(), ["meta", "fromDate"], "2026-11-02"),
          put_in(page(), ["meta", "toDate"], nil),
          Map.delete(page(), "pagination"),
          put_in(page(), ["pagination"], %{"hasMore" => false}),
          put_in(page(), ["pagination"], %{"hasMore" => false, "nextCursor" => "next"}),
          put_in(page(), ["pagination"], %{"hasMore" => true, "nextCursor" => nil}),
          put_in(page(), ["pagination"], %{"hasMore" => true, "nextCursor" => "  "}),
          put_in(page(), ["pagination"], %{"hasMore" => true, "nextCursor" => "current"})
        ] do
      stub(body)

      assert {:error, :invalid_response} =
               Zernio.publications("account-A", Keyword.put(@opts, :cursor, "current"))
    end
  end

  test "empty continuing and same-day lists retain their successor without implying absence" do
    body = %{
      page()
      | "data" => [],
        "pagination" => %{"hasMore" => true, "nextCursor" => "next"},
        "meta" => %{
          "fromDate" => "2026-11-16",
          "toDate" => "2026-11-16",
          "stale" => false,
          "staleSince" => nil,
          "missingIds" => []
        }
    }

    stub(body)

    assert {:ok, %{data: [], has_more: true, next_cursor: "next"}} =
             Zernio.publications("account-A",
               from_date: ~D[2026-11-16],
               to_date: ~D[2026-11-16],
               profile_ref: "profile-A"
             )
  end

  test "required metadata rejects absent null and wrong types without normalizing them" do
    for {field, bad_values} <- [
          {"stale", [nil, "false", 0]},
          {"missingIds", [nil, false, [1]]},
          {"staleSince", [false, 1, []]}
        ] do
      for body <- [
            update_in(page(), ["meta"], &Map.delete(&1, field))
            | Enum.map(bad_values, &put_in(page(), ["meta", field], &1))
          ] do
        stub(body)
        assert {:error, :invalid_response} = Zernio.publications("account-A", @opts)
      end
    end
  end

  test "malformed metric counts remain unavailable instead of zero or rounded values" do
    for value <- [-1, "66", 66.5, 66.0] do
      stub(put_in(page(), ["data"], [%{row() | "metrics" => %{"views" => value, "likes" => 0}}]))
      assert {:ok, %{data: [result]}} = Zernio.publications("account-A", @opts)
      refute Map.has_key?(result.metrics, "views")
      assert result.metrics["likes"] == 0
    end
  end

  test "request range is bounded to thirty inclusive days and scope is mandatory" do
    Req.Test.stub(Publisher, fn _ -> flunk("invalid request reached HTTP") end)

    for opts <- [
          Keyword.put(@opts, :from_date, ~D[2026-10-23]),
          Keyword.put(@opts, :to_date, ~D[2026-10-31]),
          Keyword.delete(@opts, :profile_ref),
          Keyword.put(@opts, :from_date, "2026-11-01")
        ] do
      assert {:error, :invalid_request} = Zernio.publications("account-A", opts)
    end

    assert {:error, :invalid_request} = Zernio.publications("", @opts)
  end

  test "thirty-day inclusive boundary is accepted and redirects are not followed" do
    stub(%{}, 302, [{"location", "https://untrusted.example"}])

    assert {:error, {:http_status, 302}} =
             Zernio.publications("account-A", Keyword.put(@opts, :from_date, ~D[2026-10-24]))

    assert_received {:request, _, _}
    refute_received {:request, _, _}
  end

  test "pending unavailable and bounded Retry-After never turn into empty success or immediate retry" do
    for {status, expected} <- [
          {202, {:error, :sync_pending}},
          {424, {:error, :analytics_unavailable}},
          {429, {:error, {:retry_after, 429, 75}}},
          {503, {:error, {:retry_after, 503, 75}}}
        ] do
      stub(page(), status, [{"retry-after", "75"}])
      assert Zernio.publications("account-A", @opts) == expected
      assert_received {:request, _, _}
      refute_received {:request, _, _}
    end

    for value <- ["invalid", "9999999999999999999999999"] do
      stub(%{}, 429, [{"retry-after", value}])
      assert {:error, {:retry_after, 429, 86_400}} = Zernio.publications("account-A", @opts)
    end
  end
end
