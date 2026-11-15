defmodule Platform.Memory.Insights.BriefingSectionsTest do
  use Platform.DataCase, async: false
  import Platform.InsightFixtures
  alias Platform.Access.Scope
  alias Platform.FixtureExtension
  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.{Briefings, BriefingSections, Disseminator}
  @date ~D[2026-11-15]
  @now ~U[2026-11-15 13:00:00Z]

  defmodule PushRecorder do
    def fan_out_to_user(id, payload), do: send(self(), {:push, id, payload})
  end

  setup do
    FixtureExtension.register([])
    Application.put_env(:platform, :fixture_extension_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:platform, :fixture_briefing_section)
      Application.delete_env(:platform, :fixture_extension_test_pid)
    end)

    :ok
  end

  defp section(user, values) do
    FixtureExtension.register()
    Application.put_env(:platform, :fixture_briefing_section, %{user.id => values})
  end

  defp row(user), do: Repo.insert!(%Briefing{user_id: user.id, digest_date: @date, items: %{}})

  test "no extensions leaves delivery result intact and summaries issue no query" do
    id = "brief-sections-#{System.unique_integer()}"
    pid = self()

    :telemetry.attach(
      id,
      [:platform, :repo, :query],
      fn _, _, metadata, _ ->
        send(pid, {:query, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    assert BriefingSections.summaries(Ecto.UUID.generate(), @date) == []
    assert BriefingSections.prepare(Ecto.UUID.generate(), @date) == 0
    refute_received {:query, _}
    assert {:ok, %{users: 0, items: 0}} = Disseminator.run(now: @now)
    assert_received {:query, settings_query}
    assert settings_query =~ "install_insight_settings"
    refute_received {:query, _}
    Repo.query!("SELECT 1")
    assert_received {:query, "SELECT 1"}
    assert Repo.aggregate(Briefing, :count) == 0
  end

  test "counts merge without changing core count keys and other readers never call summary" do
    user = person!()
    other = person!()
    briefing = row(user)
    before = Briefings.view(briefing, Scope.for_user(user))
    section(user, %{summary: %{total: 3, open: 2, calls: 1}})
    after_view = Briefings.view(briefing, Scope.for_user(user))

    assert after_view.counts == %{
             total: before.counts.total + 3,
             open: before.counts.open + 2,
             calls: before.counts.calls + 1,
             handled: before.counts.handled + 1
           }

    assert [%{key: "fixture"}] = after_view.sections
    assert_received {:fixture_briefing, :summary, _, @date}
    assert Briefings.view(briefing, Scope.for_user(other)).sections == []
    refute_received {:fixture_briefing, :summary, _, _}
  end

  test "silent, empty, raising and exiting summaries are absent" do
    user = person!()

    for value <- [
          nil,
          %{total: 0},
          fn -> raise "fixture failure" end,
          fn -> exit(:fixture) end,
          :bad
        ] do
      section(user, %{summary: value})
      assert BriefingSections.summaries(user.id, @date) == []
    end
  end

  test "section delivery creates a brief on an empty digest and pushes only on creation" do
    user = person!()
    other = person!()
    section(user, %{prepare: 2, summary: %{total: 2, open: 2, calls: 1}})

    assert {:ok, %{sections: %{users: 1, items: 2}}} =
             Disseminator.run(now: @now, notifications_module: PushRecorder)

    assert briefing = Briefings.for_user_on(user.id, @date)
    assert Briefings.for_user_on(other.id, @date) == nil
    assert [_] = Platform.Inbox.list_unread_for_user(user.id, kind: "briefing")
    assert_received {:push, id, _}
    assert id == user.id
    section(user, %{prepare: 1, summary: %{total: 3, open: 3, calls: 1}})

    assert {:ok, %{sections: %{users: 1, items: 1}}} =
             Disseminator.run(now: @now, notifications_module: PushRecorder)

    refute_received {:push, _, _}
    section(user, %{summary: %{total: 3, open: 0, calls: 0}})
    Phoenix.PubSub.subscribe(Platform.PubSub, Platform.Inbox.topic(user.id))
    assert :ok = BriefingSections.changed(user.id, @date)
    assert_received {:inbox_changed, ^id}

    assert [%{body: "All done · nothing waiting"}] =
             Platform.Inbox.list_unread_for_user(user.id, kind: "briefing")

    assert Briefings.for_user_on(user.id, @date).id == briefing.id
    assert :ok = BriefingSections.changed(other.id, @date)
    assert Briefings.for_user_on(other.id, @date) == nil
  end

  test "external and opted-out readers are not prepared; a failing prepare is contained" do
    guest = person!("member", external: true)
    opted = person!()
    user = person!()
    Platform.Accounts.update_user_preference(opted.id, "insight_delivery_opt_out", true)
    section(user, %{prepare: fn -> raise "fixture" end})
    assert {:ok, %{sections: %{items: 0}}} = Disseminator.run(now: @now)
    guest_id = guest.id
    refute_received {:fixture_briefing, :prepare, ^guest_id, _}
    opted_id = opted.id
    refute_received {:fixture_briefing, :prepare, ^opted_id, _}
  end
end
