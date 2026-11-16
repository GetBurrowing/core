defmodule Platform.Social.TrendsIdeaConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Idea, Profile, Trends}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    {root, own_root?} =
      case Repo.one(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1)) do
        nil ->
          {Repo.insert!(%Platform.Tenancy.Org{
             name: "Trends root #{n}",
             slug: "trends-root-#{n}"
           }), true}

        existing ->
          {existing, false}
      end

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Trends #{n}",
        slug: "trends-#{n}",
        parent_org_id: root.id
      })

    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "trends-#{n}@example.com",
        oidc_sub: "trends-#{n}",
        name: "Trends"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      user_id: user.id,
      org_id: org.id,
      role: "member"
    })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Trends #{n}", org_id: org.id})

    {:ok, profile} =
      Social.create_profile(org.id, %{
        name: "Trends #{n}",
        project_id: project.id,
        home_url: "https://example.com",
        approver_user_ids: [user.id]
      })

    {:ok, _} = Social.Studio.set_enabled(org.id, profile.id, user.id, true)
    source = "test_#{n}"

    {:ok, _} =
      Trends.record_snapshot(%{
        source: source,
        limit: 1,
        complete: true,
        observed_at: DateTime.utc_now(),
        items: [
          %{
            id: "item",
            rank: 1,
            title: "Synthetic",
            url: "https://example.com",
            points: 1,
            comments: 0
          }
        ]
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      steps = [
        fn -> Repo.delete_all(from(s in Trends.Snapshot, where: s.source == ^source)) end,
        fn -> Repo.delete_all(from(i in Idea, where: i.profile_id == ^profile.id)) end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^profile.id)) end,
        fn ->
          Repo.delete_all(from(g in Platform.Access.Grant, where: g.principal_id == ^user.id))
        end,
        fn -> Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn -> Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^user.id)) end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end,
        fn ->
          if own_root?,
            do: Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^root.id))
        end
      ]

      errors =
        Enum.flat_map(steps, fn step ->
          try do
            step.()
            []
          rescue
            error -> [{error, __STACKTRACE__}]
          end
        end)

      Sandbox.mode(Repo, :manual)

      case errors do
        [{error, stacktrace} | _] -> reraise(error, stacktrace)
        [] -> :ok
      end
    end)

    %{
      org: org,
      user: user,
      project: project,
      profile: profile,
      source: source,
      snapshot: Trends.latest(source).current.id
    }
  end

  test "simultaneous clicks commit one idea and return its id to both callers", ctx do
    parent = self()
    key = "social:trend:idea:#{ctx.profile.id}:#{ctx.source}:item"

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
          send(parent, :lock_held)

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :lock_held, 5_000

    worker = fn ->
      send(parent, {:ready, self()})

      receive do
        :go ->
          Trends.turn_into_idea(
            ctx.org.id,
            ctx.profile.id,
            ctx.source,
            "item",
            ctx.user.id,
            ctx.snapshot
          )
      end
    end

    a = Task.async(worker)
    b = Task.async(worker)
    assert_receive {:ready, _}, 5_000
    assert_receive {:ready, _}, 5_000
    send(a.pid, :go)
    send(b.pid, :go)
    assert_waiters!(key, 2)
    assert Repo.aggregate(from(i in Idea, where: i.profile_id == ^ctx.profile.id), :count) == 0
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:ok, first} = Task.await(a, 10_000)
    assert {:ok, second} = Task.await(b, 10_000)
    assert first.id == second.id
    assert Repo.aggregate(from(i in Idea, where: i.profile_id == ^ctx.profile.id), :count) == 1
  end

  @tag timeout: 45_000
  @tag :slow_transaction
  test "a valid response after the default transaction timeout still commits" do
    keys = [:trends, :trends_wikimedia, :trends_req_options]
    old = Map.new(keys, &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(s in Trends.Snapshot, where: s.source == "wikimedia_pageviews"))
      Repo.delete_all(from(s in Trends.SourceState, where: s.source == "wikimedia_pageviews"))

      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:social, key),
          else: Application.put_env(:social, key, value)
      end)
    end)

    Application.put_env(:social, :trends,
      enabled: true,
      source: "wikimedia_pageviews",
      fetch_timeout_ms: 25_000
    )

    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Trends.Wikimedia})
    fixture = File.read!("test/fixtures/wikimedia/top-en-2026-11-13.json")

    Req.Test.stub(Trends.Wikimedia, fn conn ->
      Process.sleep(16_000)
      Plug.Conn.send_resp(conn, 200, fixture)
    end)

    assert {:ok, :updated} = Trends.Refresher.refresh(~U[2026-11-14 12:00:00Z])
    assert %{current: %{reporting_date: ~D[2026-11-13]}} = Trends.latest("wikimedia_pageviews")
  end

  test "a timed out response releases its task and transaction so a later refresh can succeed" do
    keys = [:trends, :trends_wikimedia, :trends_req_options]
    old = Map.new(keys, &{&1, Application.get_env(:social, &1)})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(s in Trends.Snapshot, where: s.source == "wikimedia_pageviews"))
      Repo.delete_all(from(s in Trends.SourceState, where: s.source == "wikimedia_pageviews"))

      Enum.each(old, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:social, key),
          else: Application.put_env(:social, key, value)
      end)
    end)

    Application.put_env(:social, :trends,
      enabled: true,
      source: "wikimedia_pageviews",
      fetch_timeout_ms: 300
    )

    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Trends.Wikimedia})
    parent = self()

    Req.Test.stub(Trends.Wikimedia, fn conn ->
      send(parent, {:source_task, self()})
      Process.sleep(10_000)
      Plug.Conn.send_resp(conn, 500, "too late")
    end)

    assert {:error, :unavailable} = Trends.Refresher.refresh(~U[2026-11-14 12:00:00Z])
    assert_receive {:source_task, source_task}
    refute Process.alive?(source_task)
    Req.Test.stub(Trends.Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 500, "failed") end)
    assert {:error, {:http, 500}} = Trends.Refresher.refresh(~U[2026-11-14 12:00:01Z])
    fixture = File.read!("test/fixtures/wikimedia/top-en-2026-11-13.json")
    Req.Test.stub(Trends.Wikimedia, fn conn -> Plug.Conn.send_resp(conn, 200, fixture) end)
    assert {:ok, :updated} = Trends.Refresher.refresh(~U[2026-11-14 12:00:02Z])
  end

  test "replay waits for a profile disable and refuses without returning the idea", ctx do
    assert {:ok, idea} =
             Trends.turn_into_idea(
               ctx.org.id,
               ctx.profile.id,
               ctx.source,
               "item",
               ctx.user.id,
               ctx.snapshot
             )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Social.lock_profile(ctx.org.id, ctx.profile.id, :update)
          send(parent, :profile_locked)

          receive do
            :disable ->
              {:ok, _} = Social.Studio.set_enabled(ctx.org.id, ctx.profile.id, ctx.user.id, false)
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :profile_locked, 5_000

    replay =
      Task.async(fn ->
        Trends.turn_into_idea(
          ctx.org.id,
          ctx.profile.id,
          ctx.source,
          "item",
          ctx.user.id,
          ctx.snapshot
        )
      end)

    assert Task.yield(replay, 400) == nil
    send(holder.pid, :disable)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:error, :studio_disabled} = Task.await(replay, 10_000)
    assert Repo.get!(Idea, idea.id).title == "Synthetic"
    assert Repo.aggregate(from(i in Idea, where: i.profile_id == ^ctx.profile.id), :count) == 1
  end

  test "a new idea refuses when approver authority is removed while it waits", ctx do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          profile = Social.lock_profile(ctx.org.id, ctx.profile.id, :update)
          send(parent, :profile_locked)

          receive do
            :remove -> profile |> Ecto.Changeset.change(approver_user_ids: []) |> Repo.update!()
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :profile_locked, 5_000

    writer =
      Task.async(fn ->
        Trends.turn_into_idea(
          ctx.org.id,
          ctx.profile.id,
          ctx.source,
          "item",
          ctx.user.id,
          ctx.snapshot
        )
      end)

    assert Task.yield(writer, 400) == nil
    send(holder.pid, :remove)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:error, reason} = Task.await(writer, 10_000)
    assert reason in [:not_an_approver, :approver_no_access]
    assert Repo.aggregate(from(i in Idea, where: i.profile_id == ^ctx.profile.id), :count) == 0
  end

  test "a replay refuses when social.use is denied while it waits", ctx do
    assert {:ok, idea} =
             Trends.turn_into_idea(
               ctx.org.id,
               ctx.profile.id,
               ctx.source,
               "item",
               ctx.user.id,
               ctx.snapshot
             )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Social.lock_profile(ctx.org.id, ctx.profile.id, :update)
          send(parent, :profile_locked)

          receive do
            :deny ->
              {:ok, _} =
                Platform.Access.Grants.deny(%{
                  principal: {:user, ctx.user.id},
                  permission: "social.use",
                  resource: {:project, ctx.project.id}
                })
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :profile_locked, 5_000

    replay =
      Task.async(fn ->
        Trends.turn_into_idea(
          ctx.org.id,
          ctx.profile.id,
          ctx.source,
          "item",
          ctx.user.id,
          ctx.snapshot
        )
      end)

    assert Task.yield(replay, 400) == nil
    send(holder.pid, :deny)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:error, :no_social_access} = Task.await(replay, 10_000)
    assert Repo.get!(Idea, idea.id)
  end

  test "one refresher owns the request and disabling the last profile waits for it", ctx do
    old_trends = Application.get_env(:social, :trends)
    old_wiki = Application.get_env(:social, :trends_wikimedia)
    old_req = Application.get_env(:social, :trends_req_options)

    Application.put_env(:social, :trends,
      enabled: true,
      source: "wikimedia_pageviews",
      max_items: 2
    )

    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Trends.Wikimedia})

    on_exit(fn ->
      for {key, value} <- [
            trends: old_trends,
            trends_wikimedia: old_wiki,
            trends_req_options: old_req
          ] do
        if is_nil(value),
          do: Application.delete_env(:social, key),
          else: Application.put_env(:social, key, value)
      end

      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(s in Trends.Snapshot, where: s.source == "wikimedia_pageviews"))
      Repo.delete_all(from(s in Trends.SourceState, where: s.source == "wikimedia_pageviews"))
    end)

    parent = self()
    fixture = Path.expand("../../fixtures/wikimedia/top-en-2026-11-13.json", __DIR__)

    Req.Test.stub(Trends.Wikimedia, fn conn ->
      send(parent, {:http_started, self()})

      receive do
        :finish -> :ok
      after
        10_000 -> raise "test HTTP timeout"
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(fixture))
    end)

    first =
      Task.async(fn ->
        receive do
          :start -> Trends.Refresher.refresh(~U[2026-11-14 12:00:00Z])
        end
      end)

    Req.Test.allow(Trends.Wikimedia, self(), first.pid)
    send(first.pid, :start)
    assert_receive {:http_started, request_pid}, 5_000

    second =
      Task.async(fn ->
        receive do
          :start -> Trends.Refresher.refresh(~U[2026-11-14 12:00:00Z])
        end
      end)

    Req.Test.allow(Trends.Wikimedia, self(), second.pid)
    send(second.pid, :start)
    assert {:ok, {:error, :refresh_in_progress}} = Task.yield(second, 400)

    disable =
      Task.async(fn ->
        Social.Studio.set_enabled(ctx.org.id, ctx.profile.id, ctx.user.id, false)
      end)

    assert Task.yield(disable, 400) == nil
    send(request_pid, :finish)
    assert {:ok, :updated} = Task.await(first, 10_000)
    assert {:ok, _} = Task.await(disable, 10_000)
    assert {:error, :no_enabled_profile} = Trends.Refresher.refresh(~U[2026-11-15 12:00:00Z])
  end

  test "a disable that commits first prevents the pending fetch", ctx do
    old_trends = Application.get_env(:social, :trends)
    old_wiki = Application.get_env(:social, :trends_wikimedia)
    old_req = Application.get_env(:social, :trends_req_options)
    Application.put_env(:social, :trends, enabled: true, source: "wikimedia_pageviews")
    Application.put_env(:social, :trends_wikimedia, contact: "https://example.com/contact")
    Application.put_env(:social, :trends_req_options, plug: {Req.Test, Trends.Wikimedia})

    on_exit(fn ->
      for {key, value} <- [
            trends: old_trends,
            trends_wikimedia: old_wiki,
            trends_req_options: old_req
          ] do
        if is_nil(value),
          do: Application.delete_env(:social, key),
          else: Application.put_env(:social, key, value)
      end
    end)

    parent = self()

    Req.Test.stub(Trends.Wikimedia, fn conn ->
      send(parent, :unexpected_http)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Social.lock_profile(ctx.org.id, ctx.profile.id, :update)
          send(parent, :locked)

          receive do
            :disable ->
              {:ok, _} = Social.Studio.set_enabled(ctx.org.id, ctx.profile.id, ctx.user.id, false)
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000

    fetch =
      Task.async(fn ->
        receive do
          :start -> Trends.Refresher.refresh(~U[2026-11-14 12:00:00Z])
        end
      end)

    Req.Test.allow(Trends.Wikimedia, self(), fetch.pid)
    send(fetch.pid, :start)
    assert Task.yield(fetch, 400) == nil
    send(holder.pid, :disable)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:error, :no_enabled_profile} = Task.await(fetch, 10_000)
    refute_receive :unexpected_http
  end

  defp assert_waiters!(key, count, tries \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND NOT granted AND objsubid = 1
          AND classid::bigint = ((hashtextextended($1, 0) >> 32) & 4294967295)
          AND objid::bigint = (hashtextextended($1, 0) & 4294967295)
        """,
        [key]
      )

    cond do
      waiting >= count ->
        :ok

      tries == 0 ->
        flunk("both callers did not wait on the per-story lock")

      true ->
        Process.sleep(50)
        assert_waiters!(key, count, tries - 1)
    end
  end
end
