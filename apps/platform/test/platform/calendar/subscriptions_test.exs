defmodule Platform.Calendar.SubscriptionsTest do
  use Platform.DataCase, async: false
  alias Platform.Calendar.{Subscriptions, ICal, ExternalFetch}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Repo
  @from ~U[2026-10-29 00:00:00Z]
  @to ~U[2026-11-06 00:00:00Z]
  defp scope do
    id = System.unique_integer([:positive])

    Scope.for_user(
      Repo.insert!(%User{email: "sub#{id}@example.com", oidc_sub: "sub#{id}", name: "Subscriber"})
    )
  end

  defp feed(event),
    do:
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n" <>
        event <> "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

  defp event(extra \\ ""),
    do:
      "UID:external-1\r\nSUMMARY:External appointment\r\nDTSTART:20261030T190000Z\r\nDTEND:20261030T200000Z" <>
        extra

  setup do
    old_resolver = Application.get_env(:platform, :calendar_subscription_resolver)
    old_opts = Application.get_env(:platform, :calendar_subscription_req_options)

    Application.put_env(:platform, :calendar_subscription_resolver, %{
      "calendar.example" => [{93, 184, 216, 34}]
    })

    Application.put_env(:platform, :calendar_subscription_req_options,
      plug: {Req.Test, ExternalFetch}
    )

    on_exit(fn ->
      if old_resolver,
        do: Application.put_env(:platform, :calendar_subscription_resolver, old_resolver),
        else: Application.delete_env(:platform, :calendar_subscription_resolver)

      if old_opts,
        do: Application.put_env(:platform, :calendar_subscription_req_options, old_opts),
        else: Application.delete_env(:platform, :calendar_subscription_req_options)
    end)

    :ok
  end

  defp stub(body, status \\ 200) do
    Req.Test.stub(ExternalFetch, fn conn ->
      assert conn.method == "GET"
      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  test "owner-only overlay, atomic updates, cancellation and revocation" do
    owner = scope()
    outsider = scope()

    {:ok, sub} =
      Subscriptions.create(owner, %{name: "Work", url: "https://calendar.example/private-token"})

    assert [] == Subscriptions.list(outsider)
    assert {:error, :not_found} = Subscriptions.refresh(outsider, sub.id)
    assert {:error, :not_found} = Subscriptions.delete(outsider, sub.id)
    assert {:error, :external_coverage_unknown} = Subscriptions.availability(owner, @from, @to)
    stub(feed(event()))
    assert {:ok, refreshed} = Subscriptions.refresh(owner, sub.id)
    assert Subscriptions.fresh?(refreshed)

    assert [%{title: "External appointment", kind: :external}] =
             Platform.Calendar.list_entries(owner, @from, @to)

    assert [] == Platform.Calendar.list_entries(outsider, @from, @to)

    assert {:ok, [%{starts_at: ~U[2026-10-30 19:00:00Z]}]} =
             Subscriptions.availability(owner, @from, @to)

    stub(feed(String.replace(event("\r\nSEQUENCE:2"), "External appointment", "Updated")))
    assert {:ok, _} = Subscriptions.refresh(owner, sub.id)
    assert [%{title: "Updated"}] = Subscriptions.entries(owner, @from, @to)
    stub(feed("UID:external-1\r\nSTATUS:CANCELLED\r\nSEQUENCE:3"))
    assert {:ok, _} = Subscriptions.refresh(owner, sub.id)
    assert [] == Subscriptions.entries(owner, @from, @to)
    assert {:ok, _} = Subscriptions.delete(owner, sub.id)
    assert [] == Subscriptions.list(owner)
    assert {:error, :not_found} = Subscriptions.refresh(owner, sub.id)
  end

  test "malformed and oversized snapshots keep last data but invalidate availability" do
    owner = scope()

    {:ok, sub} =
      Subscriptions.create(owner, %{name: "Work", url: "https://calendar.example/feed"})

    stub(feed(event()))
    assert {:ok, _} = Subscriptions.refresh(owner, sub.id)

    for body <- [
          "not a calendar",
          String.duplicate("x", 1_048_577),
          feed(event("\r\nRRULE:FREQ=WEEKLY;BYDAY=MO"))
        ] do
      stub(body)
      assert {:ok, failed} = Subscriptions.refresh(owner, sub.id)
      assert failed.error
      assert [%{stale: true}] = Subscriptions.entries(owner, @from, @to)
      assert {:error, :external_coverage_unknown} = Subscriptions.availability(owner, @from, @to)
    end
  end

  test "stale refresh never asserts free, transparent entries do not block" do
    owner = scope()

    {:ok, sub} =
      Subscriptions.create(owner, %{name: "Work", url: "https://calendar.example/feed"})

    stub(feed(event("\r\nTRANSP:TRANSPARENT")))
    {:ok, sub} = Subscriptions.refresh(owner, sub.id)
    assert {:ok, []} = Subscriptions.availability(owner, @from, @to)

    Repo.update!(
      Ecto.Changeset.change(sub, refreshed_at: DateTime.add(DateTime.utc_now(), -3601))
    )

    assert {:error, :external_coverage_unknown} = Subscriptions.availability(owner, @from, @to)
  end

  test "URL validation rejects private/mixed DNS and never follows redirects" do
    for url <- [
          "http://calendar.example/feed",
          "https://127.0.0.1/feed",
          "https://[::1]/feed",
          "https://169.254.169.254/latest",
          "https://10.0.0.1",
          "https://user:pass@calendar.example/feed"
        ] do
      assert {:error, _} = ExternalFetch.fetch(url)
    end

    Application.put_env(:platform, :calendar_subscription_resolver, %{
      "calendar.example" => [{93, 184, 216, 34}, {192, 168, 1, 1}]
    })

    assert {:error, _} = ExternalFetch.fetch("https://calendar.example/feed")

    Application.put_env(:platform, :calendar_subscription_resolver, %{
      "calendar.example" => [{93, 184, 216, 34}]
    })

    Req.Test.stub(ExternalFetch, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://127.0.0.1/secrets")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :http_status} = ExternalFetch.fetch("https://calendar.example/feed")
  end

  test "bounded recurrence, all-day, IANA zones, folding, UID update and exceptions" do
    assert {:ok, [row]} =
             ICal.parse(feed(event("\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEXDATE;VALUE=DATE:20261031")))

    expanded = ICal.event(row, "sub") |> Platform.Calendar.Recurrence.occurrences(@from, @to)
    assert Enum.map(expanded, &DateTime.to_date(&1.starts_at)) == [~D[2026-10-30], ~D[2026-11-01]]

    assert {:ok, [day]} =
             ICal.parse(
               feed(
                 "UID:day\r\nDTSTART;VALUE=DATE:20261030\r\nDTEND;VALUE=DATE:20261101\r\nSUMMARY:Off\r\n site"
               )
             )

    assert day["all_day"] and day["title"] == "Offsite"

    assert {:ok, [zone]} =
             ICal.parse(
               feed(
                 "UID:zone\r\nDTSTART;TZID=America/Chicago:20261030T140000\r\nDTEND;TZID=America/Chicago:20261030T150000"
               )
             )

    assert zone["starts_at"] == "2026-10-30T19:00:00Z"

    for extra <- [
          "\r\nRRULE:FREQ=DAILY",
          "\r\nRRULE:FREQ=YEARLY;COUNT=2",
          "\r\nRDATE:20261101T190000Z",
          "\r\nRECURRENCE-ID:20261030T190000Z",
          "\r\nDURATION:PT1H"
        ] do
      assert {:error, _} = ICal.parse(feed(event(extra)))
    end

    assert {:error, _} =
             ICal.parse(feed("UID:floating\r\nDTSTART:20261030T140000\r\nDTEND:20261030T150000"))

    assert {:error, _} = ICal.parse(feed(event("\r\nUID:duplicate")))
  end
end
