defmodule PlatformWeb.AppApiBriefingTest do
  @moduledoc """
  Task 01a161f9 stage 1: `GET /api/app/briefing`, today's briefing counts
  for the bearer's OWN user, read by the Android cover-screen widget.
  Counts, a summary line and the Inbox deep link only, never items; every
  query param is ignored; an app never gets a redirect.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.InsightFixtures

  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Mobile
  alias Platform.Repo

  @receipt %{"verb" => "dismiss", "at" => "2026-10-22T08:00:00Z", "undo" => %{}}
  @keys ~w(date total open calls handled summary url)

  defp app_token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp today, do: Disseminator.local_date(DateTime.utc_now())

  defp briefing!(user, date, calls, fyi, done) do
    needs = for _ <- 1..calls//1, do: insight!(addressee: user, tier: "needs_call")
    fyis = for _ <- 1..fyi//1, do: insight!(addressee: user)
    dones = for _ <- 1..done//1, do: insight!(addressee: user, state: "dismissed")
    key = &BriefingCard.node_key(&1.id)

    Repo.insert!(%Briefing{
      user_id: user.id,
      digest_date: date,
      items: Map.new(needs ++ fyis ++ dones, &{key.(&1), &1.id}),
      receipts: Map.new(dones, &{key.(&1), @receipt})
    })
  end

  defp get_briefing(conn, token, params \\ %{}) do
    conn |> bearer(token) |> get("/api/app/briefing", params)
  end

  setup do
    user = person!()
    %{token: token, session: session} = app_token!(user)
    %{user: user, token: token, session: session}
  end

  test "needs-call items: counts, summary and deep link", %{conn: conn, user: user, token: token} do
    briefing!(user, today(), 3, 0, 9)
    date = Date.to_iso8601(today())

    assert json_response(get_briefing(conn, token), 200) == %{
             "today" => date,
             "zone" => "America/Chicago",
             "briefing" => %{
               "date" => date,
               "total" => 12,
               "open" => 3,
               "calls" => 3,
               "handled" => 9,
               "summary" => "12 items · 3 need your call",
               "url" => "/inbox/briefing/" <> date
             }
           }
  end

  test "FYI only", %{conn: conn, user: user, token: token} do
    briefing!(user, today(), 0, 4, 1)

    b = json_response(get_briefing(conn, token), 200)["briefing"]
    assert b["summary"] == "5 items · FYI only"
    assert {b["open"], b["calls"], b["handled"]} == {4, 0, 1}
  end

  test "all handled", %{conn: conn, user: user, token: token} do
    briefing!(user, today(), 0, 0, 6)

    b = json_response(get_briefing(conn, token), 200)["briefing"]
    assert b["summary"] == "All done · nothing waiting"
    assert {b["total"], b["open"], b["calls"], b["handled"]} == {6, 0, 0, 6}
  end

  test "no briefing today is null", %{conn: conn, user: user, token: token} do
    briefing!(user, Date.add(today(), -1), 2, 0, 0)

    assert json_response(get_briefing(conn, token), 200) == %{
             "today" => Date.to_iso8601(today()),
             "zone" => "America/Chicago",
             "briefing" => nil
           }
  end

  test "the payload carries exactly the seven count keys, never items",
       %{conn: conn, user: user, token: token} do
    briefing!(user, today(), 2, 2, 2)

    json = json_response(get_briefing(conn, token), 200)
    assert Enum.sort(Map.keys(json)) == ~w(briefing today zone)
    assert Enum.sort(Map.keys(json["briefing"])) == Enum.sort(@keys)
  end

  describe "owner scope" do
    test "another user's briefing is never served", %{conn: conn, user: a} do
      b = person!()
      %{token: b_token} = app_token!(b)
      briefing!(a, today(), 3, 0, 9)

      assert json_response(get_briefing(conn, b_token), 200)["briefing"] == nil

      briefing!(b, today(), 1, 2, 0)

      assert %{"total" => 3, "open" => 3, "calls" => 1, "handled" => 0} =
               json_response(get_briefing(conn, b_token), 200)["briefing"]
    end

    test "user_id and date params change nothing", %{conn: conn, user: a} do
      b = person!()
      %{token: b_token} = app_token!(b)
      briefing!(a, today(), 3, 0, 9)
      briefing!(a, Date.add(today(), -1), 5, 0, 0)

      plain = json_response(get_briefing(conn, b_token), 200)

      for params <- [
            %{"user_id" => a.id},
            %{"date" => Date.to_iso8601(Date.add(today(), -1))},
            %{"user_id" => a.id, "date" => Date.to_iso8601(today())}
          ] do
        assert json_response(get_briefing(conn, b_token, params), 200) == plain,
               inspect(params)
      end

      assert plain["briefing"] == nil
    end

    test "no bearer and a revoked bearer get 401 JSON, never a redirect",
         %{conn: conn, user: user, token: token, session: session} do
      briefing!(user, today(), 1, 0, 0)

      conn1 = get(conn, "/api/app/briefing")
      assert json_response(conn1, 401) == %{"error" => "unauthorized"}

      {:ok, _} = Mobile.revoke_session(session)
      conn2 = get_briefing(conn, token)
      assert json_response(conn2, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn2, "location") == []
    end
  end
end
