defmodule Platform.Social.Analytics.FollowersClientTest do
  use Platform.DataCase, async: false
  alias Platform.Social.Analytics.Zernio
  alias Platform.Social.Publisher.Zernio, as: Publisher

  setup do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "follower-fixture-key",
        scope: {:integration, nil},
        provider: "social"
      )

    :ok
  end

  defp row(date, followers) do
    %{
      "date" => date,
      "accountId" => "account-A",
      "profileId" => "profile-A",
      "platform" => "youtube",
      "username" => "example",
      "metrics" => %{"followers" => followers}
    }
  end

  defp body(rows) do
    %{
      "data" => rows,
      "pagination" => %{"nextCursor" => nil, "hasMore" => false},
      "meta" => %{
        "entity" => "accounts",
        "granularity" => "day",
        "groupBy" => "account",
        "attribution" => "publish",
        "fromDate" => "2026-11-01",
        "toDate" => "2026-11-21",
        "stale" => false,
        "staleSince" => nil
      }
    }
  end

  defp read do
    Zernio.account_followers("account-A", from_date: ~D[2026-11-01], to_date: ~D[2026-11-21])
  end

  defp stub(body, status \\ 200, headers \\ []) do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      send(parent, {:request, conn.request_path, URI.decode_query(conn.query_string)})

      conn =
        Enum.reduce(headers, conn, fn {key, value}, c ->
          Plug.Conn.put_resp_header(c, key, value)
        end)

      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  test "requests daily followers for one exact account and preserves zero, null and dates" do
    stub(body([row("2026-11-20", 97), row("2026-11-13", 0), row("2026-11-21", nil)]))
    assert {:ok, result} = read()

    assert Enum.map(result.data, &{&1.date, &1.followers}) == [
             {~D[2026-11-20], 97},
             {~D[2026-11-13], 0},
             {~D[2026-11-21], nil}
           ]

    assert result.stale == false
    assert_received {:request, "/api/v1/metrics/accounts", query}

    assert query == %{
             "accountId" => "account-A",
             "metrics" => "followers",
             "granularity" => "day",
             "groupBy" => "account",
             "attribution" => "publish",
             "fromDate" => "2026-11-01",
             "toDate" => "2026-11-21",
             "limit" => "100"
           }
  end

  test "rejects totals, other accounts, out-of-window dates, fractional counts and incomplete pages" do
    valid = body([row("2026-11-20", 97)])

    invalid = [
      put_in(valid, ["meta", "granularity"], "total"),
      put_in(valid, ["meta", "fromDate"], "2026-10-31"),
      body([%{row("2026-11-20", 97) | "accountId" => "account-B"}]),
      body([row("2026-10-31", 97)]),
      body([row("2026-11-22", 97)]),
      body([row("2026-11-20", 1.5)]),
      body([row("2026-11-20", -1)]),
      body([row("not-a-date", 97)]),
      body([row("2026-11-20", 97), row("2026-11-20", 98)]),
      put_in(valid, ["pagination"], %{"nextCursor" => "more", "hasMore" => true})
    ]

    for value <- invalid do
      stub(value)
      assert {:error, :invalid_response} = read()
    end
  end

  test "retains vendor stale metadata without calling it a same-day observation" do
    value = body([row("2026-11-13", 97)])

    stub(%{
      value
      | "meta" =>
          Map.merge(value["meta"], %{"stale" => true, "staleSince" => "2026-11-20T10:00:00Z"})
    })

    assert {:ok,
            %{stale: true, stale_since: "2026-11-20T10:00:00Z", data: [%{date: ~D[2026-11-13]}]}} =
             read()
  end

  test "rate limits have bounded durable delays and are never retried inside the HTTP client" do
    for {header, seconds} <- [
          {"60", 60},
          {"0", 1},
          {"-1", 86_400},
          {"invalid", 86_400},
          {"31536000", 31_536_000},
          {"31536001", 86_400}
        ] do
      stub(%{}, 429, [{"retry-after", header}])
      assert {:error, {:retry_after, 429, ^seconds}} = read()
      assert_received {:request, "/api/v1/metrics/accounts", _}
      refute_received {:request, "/api/v1/metrics/accounts", _}
    end
  end

  test "transport timeout is an error without an automatic second request" do
    parent = self()

    Req.Test.stub(Publisher, fn conn ->
      send(parent, :attempt)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:transport, _}} = read()
    assert_received :attempt
    refute_received :attempt
  end

  test "invalid date arguments refuse before any network request" do
    assert {:error, :invalid_request} = Zernio.account_followers("account-A", to_date: "invalid")
    assert {:error, :invalid_request} = Zernio.account_followers("account-A", from_date: nil)
  end

  test "a redirect does not spend the one-read budget on additional requests" do
    stub(%{}, 302, [{"location", "/api/v1/metrics/accounts?redirected=true"}])
    assert {:error, {:http_status, 302}} = read()
    assert_received {:request, "/api/v1/metrics/accounts", _}
    refute_received {:request, _, _}
  end

  test "refuses a ninety-one-day window without a provider call and accepts exactly ninety" do
    stub(body([]))

    assert {:error, :invalid_request} =
             Zernio.account_followers("account-A",
               from_date: ~D[2026-08-23],
               to_date: ~D[2026-11-21]
             )

    refute_received {:request, _, _}
    response = body([]) |> put_in(["meta", "fromDate"], "2026-08-24")
    stub(response)

    assert {:ok, _} =
             Zernio.account_followers("account-A",
               from_date: ~D[2026-08-24],
               to_date: ~D[2026-11-21]
             )

    assert_received {:request, _, %{"fromDate" => "2026-08-24", "toDate" => "2026-11-21"}}
  end
end
