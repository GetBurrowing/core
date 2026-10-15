defmodule Platform.Access.IdpGroupRolesTest do
  use PlatformWeb.ConnCase, async: false
  import Ecto.Query

  alias Platform.Access.{IdpGroupRoles, RoleAssignment, Roles}
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    %{root: Tenancy.get_org_by_slug!("acme")}
  end

  test "real OIDC callback applies every mapped custom role, then revokes stale IdP rows without touching manual rows",
       %{conn: conn, root: root} do
    watch_admission()
    {:ok, finance} = Roles.create_custom_role(root, %{name: "Finance"})
    {:ok, engineering} = Roles.create_custom_role(root, %{name: "Engineering"})
    {:ok, _} = IdpGroupRoles.create(%{group_value: " Finance-Team ", role_key: finance.key, org_id: root.id})
    {:ok, _} = IdpGroupRoles.create(%{group_value: "eng-team", role_key: engineering.key, org_id: root.id})

    conn = callback(conn, ["FINANCE-TEAM", "eng-team"])
    assert redirected_to(conn, 302) == "/"
    user_id = get_session(conn, :current_user_id)
    assert user_id
    assert assignments(user_id, "idp") == MapSet.new([finance.key, engineering.key])
    assert_receive {:admission, %{idp_roles_applied: 2, idp_roles_revoked: 0}}

    {:ok, _} = Roles.assign(%{principal: {:user, user_id}, role: finance})
    conn = callback(Phoenix.ConnTest.build_conn(), ["eng-team"])
    assert redirected_to(conn, 302) == "/"
    assert get_session(conn, :current_user_id) == user_id
    assert assignments(user_id, "idp") == MapSet.new([engineering.key])
    assert assignments(user_id, "manual") == MapSet.new([finance.key])
    assert_receive {:admission, %{idp_roles_applied: 0, idp_roles_revoked: 1}}

    conn = callback(Phoenix.ConnTest.build_conn(), [])
    assert redirected_to(conn, 302) == "/"
    assert assignments(user_id, "idp") == MapSet.new()
    assert assignments(user_id, "manual") == MapSet.new([finance.key])
    assert_receive {:admission, %{idp_roles_applied: 0, idp_roles_revoked: 1}}
  end

  test "absent groups claim leaves existing IdP assignments untouched", %{conn: conn, root: root} do
    {:ok, role} = Roles.create_custom_role(root, %{name: "ClaimPresent"})
    {:ok, _} = IdpGroupRoles.create(%{group_value: "claim-present", role_key: role.key, org_id: root.id})
    conn = callback(conn, ["claim-present"])
    user_id = get_session(conn, :current_user_id)
    assert assignments(user_id, "idp") == MapSet.new([role.key])
    before = assignment_ids(user_id)

    conn = callback(Phoenix.ConnTest.build_conn(), :absent)
    assert redirected_to(conn, 302) == "/"
    assert assignments(user_id, "idp") == MapSet.new([role.key])
    assert assignment_ids(user_id) == before
  end

  test "implicit sxi-external and stored guest groups hold without assigning custom roles", %{conn: conn, root: root} do
    {:ok, role} = Roles.create_custom_role(root, %{name: "UnappliedGuestRole"})
    {:ok, _} = IdpGroupRoles.create(%{group_value: "sxi-external", role_key: role.key, org_id: root.id})
    assert IdpGroupRoles.guest_group?([" SXI-EXTERNAL "])

    conn = callback(conn, ["sxi-external"])
    assert redirected_to(conn, 302) == "/welcome"
    user_id = get_session(conn, :current_user_id)
    assert %{state: :holding} = get_session(conn, :external_admission)
    assert assignments(user_id, "idp") == MapSet.new()

    {:ok, _} = IdpGroupRoles.create(%{group_value: "partners-ext", role_key: "guest"})
    assert IdpGroupRoles.guest_group?(["Partners-Ext"])
    conn = callback(Phoenix.ConnTest.build_conn(), ["partners-ext"])
    assert redirected_to(conn, 302) == "/welcome"
    assert %{state: :holding} = get_session(conn, :external_admission)
    assert assignments(user_id, "idp") == MapSet.new()
  end

  test "built-in admin/member mappings are refused and guest requires no org", %{root: root} do
    for key <- ~w(admin member) do
      assert {:error, :builtin_role} =
               IdpGroupRoles.create(%{group_value: "forbidden", role_key: key, org_id: root.id})
    end

    assert {:error, :guest_has_no_org} =
             IdpGroupRoles.create(%{group_value: "guest-with-org", role_key: "guest", org_id: root.id})

    assert {:error, :implicit_mapping} =
             IdpGroupRoles.create(%{group_value: "sxi-external", role_key: "guest"})

    {:ok, mapping} = IdpGroupRoles.create(%{group_value: "partners-ext", role_key: "guest"})
    assert Enum.any?(IdpGroupRoles.mappings(), &(&1.group_value == "partners-ext"))
    assert {:ok, _} = IdpGroupRoles.delete(mapping)
    refute IdpGroupRoles.guest_group?(["partners-ext"])
  end

  test "pre-staged sxi-external login is full but its other mapped roles are not synced",
       %{conn: conn, root: root} do
    {:ok, role} = Roles.create_custom_role(root, %{name: "GuestOtherGroup"})
    {:ok, _} = IdpGroupRoles.create(%{group_value: "other-group", role_key: role.key, org_id: root.id})
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{kind: "channel", name: "Guest #{n}", slug: "guest-#{n}", org_id: root.id})

    {:ok, _} =
      ExternalGrants.create_grant(%{
        email: "idp-roles@example.com",
        oidc_sub: "idp-role-subject",
        target_org_id: root.id,
        space_grants: [%{"space_id" => space.id, "role" => "member"}],
        dm_allowlist_org_ids: [root.id]
      })

    conn = callback(conn, ["sxi-external", "other-group"])
    assert redirected_to(conn, 302) == "/"
    user_id = get_session(conn, :current_user_id)
    assert get_session(conn, :external_admission) == nil
    assert assignments(user_id, "idp") == MapSet.new()
  end

  defp assignments(user_id, source) do
    Repo.all(
      from(a in RoleAssignment,
        where: a.principal_type == "user" and a.principal_id == ^user_id and a.source == ^source,
        select: a.role_key
      )
    )
    |> MapSet.new()
  end

  defp assignment_ids(user_id) do
    Repo.all(
      from(a in RoleAssignment,
        where: a.principal_type == "user" and a.principal_id == ^user_id and a.source == "idp",
        select: a.id
      )
    )
  end

  defp watch_admission do
    handler = "idp-role-admission-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :auth, :external_admission],
        fn _, _, metadata, _ -> send(test_pid, {:admission, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp callback(conn, groups) do
    claims = %{"sub" => "idp-role-subject", "email" => "idp-roles@example.com", "name" => "IdP Roles"}
    claims = if groups == :absent, do: claims, else: Map.put(claims, "groups", groups)

    Application.put_env(:platform, :oidc_mock_response, {
      :ok,
      %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test-id-token"}}
    })

    conn
    |> init_test_session(oidc_session_params: %{state: "expected-state", nonce: "n"})
    |> get("/auth/oidc/callback?code=test-code&state=expected-state")
  end
end
