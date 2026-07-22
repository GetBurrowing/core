defmodule PlatformWeb.Plugs.ExternalUserScopeTest do
  @moduledoc """
  Tests for the `ExternalUserScope` authorization plug (rbac-external-users
  M6). The plug is driven directly on a `Plug.Test`-built conn with the
  assigns `RequireAuth` would have set already pre-populated — the router
  wiring is exercised by `router_external_scope_test.exs`.

  Invariants under test:

    * internal users are a complete no-op (pass through unhalted, any path)
    * external users reach ONLY the chat surface (`/`, `/chat`, and a
      `/chat/:slug` they are scoped to)
    * every other route, an out-of-scope space, and a nonexistent space all
      halt with a uniform `403` — no existence oracle
    * the DM allowlist branch grants access to a DM with an allowlisted org
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Plugs.ExternalUserScope

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "ext-scope-#{n}@example.com",
          name: "ExtScope #{n}",
          oidc_sub: "oidc-ext-scope-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_scope_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp channel!(org, kind \\ "channel") do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{n}",
        slug: "scope-space-#{n}",
        kind: kind,
        org_id: org.id
      })

    space
  end

  defp join!(space, user_id) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  # Build a conn for `path` with the assigns RequireAuth would have set,
  # then run the plug. `format: "html"` so the deny path can render :"403".
  defp run(path, current_user, membership) do
    Phoenix.ConnTest.build_conn(:get, path)
    |> Plug.Conn.put_private(:phoenix_format, "html")
    |> Plug.Conn.assign(:current_user, current_user)
    |> Plug.Conn.assign(:current_user_org_membership, membership)
    |> ExternalUserScope.call(ExternalUserScope.init([]))
  end

  # Full authenticated user + membership assign shape, mirroring
  # `Tenancy.load_membership/1` (a map, NOT an %OrgMembership{}).
  defp authed(user, org, role) do
    user = Accounts.get_user(user.id)
    {user, %{org: org, role: role}}
  end

  setup do
    org = tenant_org!()

    ext = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

    internal = create_user!()
    membership!(internal, org, "member")

    space_a = channel!(org)
    space_b = channel!(org)
    join!(space_a, ext.id)

    {ext_user, ext_membership} = authed(ext, org, :member)
    {int_user, int_membership} = authed(internal, org, :member)

    %{
      org: org,
      ext_user: ext_user,
      ext_membership: ext_membership,
      int_user: int_user,
      int_membership: int_membership,
      space_a: space_a,
      space_b: space_b
    }
  end

  describe "internal users (no-op)" do
    test "pass through unhalted on every path", ctx do
      for path <- ["/", "/chat", "/tasks", "/admin", "/org_memory", "/chat/" <> ctx.space_b.slug] do
        conn = run(path, ctx.int_user, ctx.int_membership)
        refute conn.halted, "expected internal user unhalted on #{path}"
      end
    end

    test "no telemetry emitted for internal user", ctx do
      ref = attach_telemetry()
      run("/tasks", ctx.int_user, ctx.int_membership)
      refute_receive {:access_blocked, _}, 50
      detach_telemetry(ref)
    end
  end

  describe "external users — chat surface allowlist" do
    test "unhalted on root and chat index", ctx do
      refute run("/", ctx.ext_user, ctx.ext_membership).halted
      refute run("/chat", ctx.ext_user, ctx.ext_membership).halted
    end

    test "unhalted on a scoped space (participant of A)", ctx do
      conn = run("/chat/" <> ctx.space_a.slug, ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end
  end

  describe "external users — denials" do
    test "403 on an out-of-scope existing space (B)", ctx do
      conn = run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)
      assert conn.halted
      assert conn.status == 403
    end

    test "403 on a nonexistent space — indistinguishable from out-of-scope", ctx do
      missing = run("/chat/does-not-exist-zzz", ctx.ext_user, ctx.ext_membership)
      out_of_scope = run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)

      assert missing.halted and missing.status == 403
      assert out_of_scope.halted and out_of_scope.status == 403
    end

    test "403 on non-chat routes", ctx do
      for path <- ["/tasks", "/admin", "/org_memory", "/files", "/meetings"] do
        conn = run(path, ctx.ext_user, ctx.ext_membership)
        assert conn.halted and conn.status == 403, "expected 403 on #{path}"
      end
    end

    test "emits access_blocked telemetry with reason external_out_of_scope (space)", ctx do
      ref = attach_telemetry()
      run("/chat/" <> ctx.space_b.slug, ctx.ext_user, ctx.ext_membership)
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_out_of_scope"
      assert meta.actor_id == ctx.ext_user.id
      assert meta.resource_type == "route"
      detach_telemetry(ref)
    end

    test "emits access_blocked telemetry with reason external_non_chat_route (route)", ctx do
      ref = attach_telemetry()
      run("/tasks", ctx.ext_user, ctx.ext_membership)
      assert_receive {:access_blocked, meta}
      assert meta.reason == "external_non_chat_route"
      detach_telemetry(ref)
    end
  end

  describe "external users — DM allowlist branch" do
    test "allowed to open a DM with a counterpart whose org is allowlisted", ctx do
      counterpart_org = tenant_org!()
      counterpart = create_user!()
      membership!(counterpart, counterpart_org, "member")

      dm = channel!(ctx.org, "dm")
      join!(dm, counterpart.id)
      # external user is NOT a participant of the DM, but may DM the org.
      {:ok, _} = Tenancy.allow_dm(ctx.ext_user, counterpart_org)

      conn = run("/chat/" <> dm.slug, ctx.ext_user, ctx.ext_membership)
      refute conn.halted
    end

    test "403 on a DM with a non-allowlisted counterpart org", ctx do
      counterpart_org = tenant_org!()
      counterpart = create_user!()
      membership!(counterpart, counterpart_org, "member")

      dm = channel!(ctx.org, "dm")
      join!(dm, counterpart.id)

      conn = run("/chat/" <> dm.slug, ctx.ext_user, ctx.ext_membership)
      assert conn.halted and conn.status == 403
    end
  end

  describe "defensive no-op" do
    test "no current_user assign → conn unchanged", _ctx do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/tasks")
        |> ExternalUserScope.call(ExternalUserScope.init([]))

      refute conn.halted
    end
  end

  # ── Telemetry test plumbing ────────────────────────────────────────────

  defp attach_telemetry do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "ext-scope-test-#{inspect(ref)}",
      [:platform, :auth, :access_blocked],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:access_blocked, metadata})
      end,
      nil
    )

    ref
  end

  defp detach_telemetry(ref), do: :telemetry.detach("ext-scope-test-#{inspect(ref)}")
end
