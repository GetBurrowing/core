defmodule PlatformWeb.RouterExternalScopeTest do
  @moduledoc """
  End-to-end router wiring for the `ExternalUserScope` plug (rbac-external
  users M6, stage 3). Drives real routes through the authenticated pipeline
  (`[:browser, :require_auth, :enforce_external_scope]`) via `init_test_session`
  and asserts HTTP status — the plug halts BEFORE the target LiveView mounts.

  Regression guard: the plug is a strict no-op for internal users, so every
  pre-existing route still resolves for them.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "router-scope-#{n}@example.com",
      name: "RouterScope #{n}",
      oidc_sub: "oidc-router-scope-#{n}"
    })
    |> Repo.insert!()
  end

  # Use a SEEDED tenant org (the plan's "Globex org"): its slug atom is
  # pre-registered, so TasksLive's scope-rail (`String.to_existing_atom`
  # over every active tenant) renders for the internal-user regression case.
  # A raw-inserted org with a novel slug would crash that unrelated path.
  defp globex_org, do: Tenancy.get_org_by_slug!("globex")

  defp membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp channel!(org) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{n}",
        slug: "router-space-#{n}",
        kind: "channel",
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

  setup %{conn: conn} do
    org = globex_org()

    ext = create_user!()
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})

    internal = create_user!()
    membership!(internal, org, "member")

    space_a = channel!(org)
    space_b = channel!(org)
    join!(space_a, ext.id)
    join!(space_a, internal.id)

    %{
      conn: conn,
      ext: ext,
      internal: internal,
      space_a: space_a,
      space_b: space_b
    }
  end

  describe "external user" do
    setup %{conn: conn, ext: ext} do
      %{conn: init_test_session(conn, current_user_id: ext.id)}
    end

    test "403 on /tasks", %{conn: conn} do
      assert get(conn, "/tasks").status == 403
    end

    test "403 on /admin", %{conn: conn} do
      assert get(conn, "/admin").status == 403
    end

    test "403 on /org_memory", %{conn: conn} do
      assert get(conn, "/org_memory").status == 403
    end

    test "403 on an out-of-scope space B", %{conn: conn, space_b: space_b} do
      assert get(conn, "/chat/#{space_b.slug}").status == 403
    end

    test "403 on a nonexistent space (no existence oracle)", %{conn: conn} do
      assert get(conn, "/chat/does-not-exist-zzz").status == 403
    end

    test "200 on the scoped space A", %{conn: conn, space_a: space_a} do
      assert get(conn, "/chat/#{space_a.slug}").status == 200
    end

    test "chat index is NOT blocked by the plug", %{conn: conn} do
      # ChatLive's :index action dead-render redirects into a concrete space
      # (302) rather than returning a 200 body — either way the plug allowed
      # it through (the invariant under test is "not a 403").
      assert get(conn, "/chat").status in [200, 302]
    end
  end

  describe "internal user (regression — plug is a no-op)" do
    setup %{conn: conn, internal: internal} do
      %{conn: init_test_session(conn, current_user_id: internal.id)}
    end

    test "200 on /tasks", %{conn: conn} do
      assert get(conn, "/tasks").status == 200
    end

    test "200 on the scoped space A", %{conn: conn, space_a: space_a} do
      assert get(conn, "/chat/#{space_a.slug}").status == 200
    end
  end
end
