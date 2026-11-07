defmodule Platform.GameStream.NativeSessionsTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Platform.{Repo, Federation, Tasks}
  alias Platform.Accounts.User
  alias Platform.Chat.Space

  alias Platform.GameStream.{
    GameChannels,
    NativeBuild,
    NativeSessions,
    NativeSessionRecord,
    JoinToken
  }

  alias Platform.Tenancy.OrgMembership

  defmodule FakeProvider do
    @behaviour Platform.GameStream.Provider
    def start(id, build, limits) do
      send(
        Application.fetch_env!(:game_stream, :native_test_owner),
        {:native_start, id, build, limits}
      )

      {:ok, %{session_id: id}}
    end

    def status(_), do: :ok

    def stop(h, reason) do
      send(
        Application.fetch_env!(:game_stream, :native_test_owner),
        {:native_stop, h.session_id, reason}
      )

      :ok
    end

    def reconcile(id) do
      send(Application.fetch_env!(:game_stream, :native_test_owner), {:native_reconcile, id})
      :ok
    end
  end

  setup do
    # Real committed rows + one connection per concurrent caller. A shared
    # sandbox connection would serialize callers before they reach our locks.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    saved =
      Map.new(
        [:enabled, :native_provider, :native_test_owner],
        &{&1, Application.fetch_env(:game_stream, &1)}
      )

    Application.put_env(:game_stream, :enabled, true)
    Application.put_env(:game_stream, :native_provider, FakeProvider)
    Application.put_env(:game_stream, :native_test_owner, self())
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "native-#{n}@example.com",
        name: "Native",
        oidc_sub: "native-#{n}"
      })

    org = Platform.TenancyFixtures.acme_org_id()

    membership =
      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{user_id: user.id, org_id: org, role: "member"})
      )

    {:ok, project} =
      Tasks.create_project(%{
        name: "Native #{n}",
        slug: "native-#{n}",
        org_id: org,
        repo_url: "https://github.com/example/native-#{n}"
      })

    channel =
      Repo.insert!(
        Space.changeset(%Space{}, %{
          name: "Native #{n}",
          slug: "native-#{n}",
          org_id: org,
          kind: "channel"
        })
      )

    {:ok, _} = GameChannels.configure(user, channel.id, project.id)

    manifest = %{
      "id" => "native-#{n}",
      "repo_url" => project.repo_url,
      "engine" => "godot",
      "protocol_version" => 1,
      "capacity" => 4,
      "server_image" => "registry.example/voltron@sha256:" <> String.duplicate("a", 64)
    }

    {:ok, build} = NativeBuild.register(project.id, manifest)
    agent = Platform.PrototypeFixtures.agent!()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "native-test-#{n}",
        tool_profile: [],
        agent_id: agent.id
      })

    {:ok, runtime, _token} = Federation.activate_runtime(runtime)
    Platform.Federation.RuntimePresence.track(runtime.runtime_id)
    # Discovery reads persisted client_info, not only Presence metadata.
    runtime =
      Repo.update!(
        Ecto.Changeset.change(runtime,
          metadata: %{"client_info" => %{"features" => ["game_native_host"]}}
        )
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(t in JoinToken, where: t.channel_id == ^channel.id))
        Repo.delete_all(from(s in NativeSessionRecord, where: s.channel_id == ^channel.id))
        Repo.delete_all(from(b in GameChannels, where: b.id == ^channel.id))
        Repo.delete_all(from(b in NativeBuild, where: b.project_id == ^project.id))
        Repo.delete_all(from(s in Space, where: s.id == ^channel.id))
        Repo.delete_all(from(r in Platform.Agents.AgentRuntime, where: r.id == ^runtime.id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id))
        Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id))
        Repo.delete_all(from(m in OrgMembership, where: m.id == ^membership.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)

      Platform.Federation.RuntimePresence.untrack(runtime.runtime_id)

      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:game_stream, key, v)
          :error -> Application.delete_env(:game_stream, key)
        end
      end
    end)

    %{user: user, project: project, channel: channel, build: build, runtime: runtime}
  end

  defp concurrent(n, fun) do
    for _ <- 1..n do
      Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end)
    end
    |> Enum.map(&Task.await(&1, 15_000))
  end

  defp running(ctx) do
    assert {:ok, status} = NativeSessions.play(ctx.user, ctx.channel.id)
    credential = JoinToken.mint()

    assert :ok =
             NativeSessions.host_status(ctx.runtime.runtime_id, %{
               "session_id" => status.id,
               "generation" => 1,
               "state" => "running",
               "endpoint" => "native.example:24973",
               "credential_hash" => JoinToken.hash(credential),
               "admissions" => []
             })

    {Repo.get!(NativeSessionRecord, status.id), credential}
  end

  test "concurrent Play persists one session and pins its build across latest changes and reconciler restart",
       ctx do
    results = concurrent(8, fn -> NativeSessions.play(ctx.user, ctx.channel.id) end)
    ids = Enum.map(results, fn {:ok, r} -> r.id end) |> Enum.uniq()
    assert [id] = ids

    assert Repo.aggregate(
             from(s in NativeSessionRecord, where: s.channel_id == ^ctx.channel.id),
             :count
           ) == 1

    {:ok, _} =
      NativeBuild.register(
        ctx.project.id,
        Map.put(ctx.build.manifest, "id", ctx.build.id <> "-new")
      )

    assert {:ok, %{id: ^id, build_id: build_id}} = NativeSessions.play(ctx.user, ctx.channel.id)
    assert build_id == ctx.build.id
    assert :ok = NativeSessions.tick()
    assert_receive {:native_reconcile, ^id}
    assert Repo.get!(Space, ctx.channel.id).kind == "channel"
  end

  test "atomic consume permits one slot once and never returns secrets in status", ctx do
    {row, credential} = running(ctx)
    assert {:ok, handoff} = NativeSessions.mint(ctx.user, row.id)
    claims = handoff |> Jason.encode!() |> Jason.decode!()
    outcomes = concurrent(8, fn -> NativeSessions.consume(row.id, credential, claims) end)
    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &match?({:error, :unauthorized}, &1)) == 7
    assert {:error, :already_reserved} = NativeSessions.mint(ctx.user, row.id)
    {:ok, status} = NativeSessions.status(ctx.user, ctx.channel.id)
    refute Jason.encode!(status) =~ handoff.token
    refute Jason.encode!(status) =~ credential
    refute Jason.encode!(status) =~ "digest"
  end

  test "false host, altered claims, expired token and revoked membership fail closed", ctx do
    {row, credential} = running(ctx)
    {:ok, handoff} = NativeSessions.mint(ctx.user, row.id)
    claims = handoff |> Jason.encode!() |> Jason.decode!()
    assert {:error, :unauthorized} = NativeSessions.consume(row.id, "wrong-host", claims)

    assert {:error, :unauthorized} =
             NativeSessions.consume(
               row.id,
               credential,
               Map.put(claims, "token", JoinToken.mint())
             )

    for {key, value} <- [
          {"build_id", "wrong"},
          {"channel_id", Ecto.UUID.generate()},
          {"user_id", Ecto.UUID.generate()},
          {"generation", 2}
        ] do
      assert {:error, :unauthorized} =
               NativeSessions.consume(row.id, credential, Map.put(claims, key, value))
    end

    token = Repo.one!(from(t in JoinToken, where: t.session_id == ^row.id))
    Repo.update!(Ecto.Changeset.change(token, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    assert {:error, :unauthorized} = NativeSessions.consume(row.id, credential, claims)
    Repo.update!(Ecto.Changeset.change(token, expires_at: DateTime.add(DateTime.utc_now(), 60)))
    Repo.delete_all(from(m in OrgMembership, where: m.user_id == ^ctx.user.id))
    assert {:error, :unauthorized} = NativeSessions.consume(row.id, credential, claims)
  end

  test "reservation protects idle session; expiry and no players allow stop; old token never joins successor",
       ctx do
    {row, credential} = running(ctx)
    {:ok, handoff} = NativeSessions.mint(ctx.user, row.id)
    Repo.update!(Ecto.Changeset.change(row, idle_since: DateTime.add(DateTime.utc_now(), -601)))
    assert :ok = NativeSessions.tick()
    refute_received {:native_stop, _, _}

    Repo.update_all(from(t in JoinToken, where: t.session_id == ^row.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    NativeSessions.tick()
    assert_receive {:native_stop, id, "idle"}
    assert id == row.id
    claims = handoff |> Jason.encode!() |> Jason.decode!()
    assert {:error, :unauthorized} = NativeSessions.consume(id, credential, claims)
  end

  test "cross-org channel linking does not infer game access or change channel kind", ctx do
    other_org =
      Repo.insert!(
        Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
          name: "Native Other",
          slug: "native-other-#{System.unique_integer([:positive])}",
          parent_org_id: Platform.TenancyFixtures.acme_org_id()
        })
      )

    other = other_org.id

    {:ok, project} =
      Tasks.create_project(%{
        name: "Other",
        org_id: other,
        repo_url: "https://github.com/private/game"
      })

    assert {:error, :unauthorized} = GameChannels.configure(ctx.user, ctx.channel.id, project.id)
    assert Repo.get!(GameChannels, ctx.channel.id).project_id == ctx.project.id
    Repo.delete!(project)
    Repo.delete!(other_org)
    assert {:error, :unauthorized} = GameChannels.authorize(ctx.user, "sixteen-char-xxx")
  end

  test "concurrent users reserve each slot once and excess join fails full", ctx do
    {row, _credential} = running(ctx)

    users =
      for n <- 1..5 do
        suffix = System.unique_integer([:positive])

        user =
          Repo.insert!(%User{
            email: "capacity-#{suffix}@example.com",
            name: "Pilot #{n}",
            oidc_sub: "capacity-#{suffix}"
          })

        Repo.insert!(
          OrgMembership.changeset(%OrgMembership{}, %{
            user_id: user.id,
            org_id: ctx.project.org_id,
            role: "member"
          })
        )

        user
      end

    try do
      results =
        users
        |> Enum.map(fn user ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              NativeSessions.mint(user, row.id)
            end)
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 4
      assert Enum.count(results, &match?({:error, :full}, &1)) == 1

      assert Repo.all(
               from(t in JoinToken,
                 where: t.session_id == ^row.id,
                 order_by: t.slot,
                 select: t.slot
               )
             ) == [0, 1, 2, 3]

      assert {:error, :active_session} =
               GameChannels.configure(ctx.user, ctx.channel.id, ctx.project.id)
    after
      ids = Enum.map(users, & &1.id)
      Repo.delete_all(from(t in JoinToken, where: t.user_id in ^ids))
      Repo.delete_all(from(m in OrgMembership, where: m.user_id in ^ids))
      Repo.delete_all(from(u in User, where: u.id in ^ids))
    end
  end

  test "native records do not block normal channel deletion", ctx do
    {row, credential} = running(ctx)
    assert {:ok, _handoff} = NativeSessions.mint(ctx.user, row.id)
    assert :ok = Platform.Chat.delete_abandoned_channel(ctx.channel)
    refute Repo.get(NativeSessionRecord, row.id)
    refute Repo.exists?(from(t in JoinToken, where: t.session_id == ^row.id))
    assert {:error, :unauthorized} = NativeSessions.control(row.id, credential)
  end

  test "org-scoped idle data resolves once and remains pinned", ctx do
    alias Platform.Experiments.SurfaceDefault

    base = %{
      surface_key: "game_stream.native_idle",
      surface_target: "native_session.start",
      org_id: ctx.project.org_id,
      kind: "promote"
    }

    first =
      Repo.insert!(
        SurfaceDefault.changeset(
          %SurfaceDefault{},
          Map.merge(base, %{seq: 1, payload: %{"idle_timeout_s" => 300}})
        )
      )

    second_id = Ecto.UUID.generate()

    try do
      assert {:ok, status} = NativeSessions.play(ctx.user, ctx.channel.id)
      assert status.idle_timeout_s == 300

      Repo.insert!(
        SurfaceDefault.changeset(
          %SurfaceDefault{id: second_id},
          Map.merge(base, %{seq: 2, payload: %{"idle_timeout_s" => 900}})
        )
      )

      assert {:ok, reused} = NativeSessions.play(ctx.user, ctx.channel.id)
      assert reused.id == status.id
      assert reused.idle_timeout_s == 300
    after
      ids = [first.id, second_id]
      Repo.delete_all(from(d in SurfaceDefault, where: d.id in ^ids))
    end
  end
  test "complete immutable packages publish atomically and delayed older workflow cannot replace latest", ctx do
    artifacts = for {os, arch, role} <- [{"windows", "x86_64", "client"}, {"linux", "x86_64", "client"}, {"macos", "universal", "client"}, {"linux", "x86_64", "server"}] do
      %{"os" => os, "arch" => arch, "role" => role, "size" => 20, "asset_id" => 1, "sha256" => String.duplicate("a", 64), "executable" => "game", "filename" => os <> role <> ".zip"}
    end
    complete = Map.merge(ctx.build.manifest, %{"schema_version" => 1, "source_sha" => String.duplicate("b", 40), "build_number" => 42, "artifacts" => artifacts})
    newer = Map.put(complete, "id", ctx.build.id <> "-42")
    older = complete |> Map.put("id", ctx.build.id <> "-41") |> Map.put("build_number", 41)
    assert {:ok, _} = NativeBuild.register(ctx.project.id, newer)
    assert {:ok, _} = NativeBuild.register(ctx.project.id, older)
    assert NativeBuild.latest(ctx.project.id).id == newer["id"]
    assert {:ok, _} = NativeBuild.register(ctx.project.id, newer)
    assert {:error, :immutable_conflict} = NativeBuild.register(ctx.project.id, Map.put(newer, "engine", "other"))
    incomplete = complete |> Map.put("id", ctx.build.id <> "-43") |> Map.put("build_number", 43) |> Map.put("artifacts", tl(artifacts))
    assert {:error, :invalid_build} = NativeBuild.register(ctx.project.id, incomplete)
    assert NativeBuild.latest(ctx.project.id).id == newer["id"]
    assert Repo.get!(NativeBuild, older["id"]).manifest == older
    assert {:ok, _} = Platform.GameStream.NativeAssets.manifest(ctx.user, ctx.channel.id, older["id"])
    assert {:error, :unauthorized} = Platform.GameStream.NativeAssets.manifest(ctx.user, Ecto.UUID.generate(), older["id"])
    # Rollback can install the retained older immutable package without rewriting latest.
    assert NativeBuild.latest(ctx.project.id).id == newer["id"]
  end

end
