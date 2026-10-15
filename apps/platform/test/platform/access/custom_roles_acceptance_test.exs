defmodule Platform.Access.CustomRolesAcceptanceTest do
  use PlatformWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access
  alias Platform.Access.{IdpGroupRoles, Restrictions, RoleAssignment, Roles, Scope}
  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{ExternalGrants, OrgMembership}

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    %{root: Tenancy.get_org!(acme_org_id())}
  end

  describe "restricting finance to admins" do
    test "the same marker becomes unreadable to the member and their agent while an admin retains it",
         %{conn: conn, root: root} do
      member = create_user!()
      admin = create_user!()
      plain_member!(member, root)
      plain_member!(admin, root, "admin")
      finance = channel!(%{name: "Finance", org_id: root.id})
      participant = add_user!(finance.id, admin.id)
      marker = "accept-finance-#{System.unique_integer([:positive])}"
      post!(finance.id, participant.id, marker)

      agent =
        Repo.insert!(%Agent{
          slug: "accept-#{System.unique_integer([:positive])}",
          name: "Acceptance Agent",
          status: "active"
        })

      add_agent!(finance.id, agent.id)

      runtime =
        Repo.insert!(%AgentRuntime{
          agent_id: agent.id,
          owner_user_id: member.id,
          runtime_id: "accept-#{System.unique_integer([:positive])}",
          status: "active"
        })

      context = %{agent_id: agent.id, runtime_id: runtime.runtime_id}
      args = %{"space_id" => finance.id}
      member_conn = login(conn, member.id)
      assert {:ok, _, before_html} = live(member_conn, ~p"/chat/#{finance.id}")
      assert before_html =~ marker
      assert {:ok, before_tool} = ToolSurface.execute("space_get_messages", args, context)
      assert Jason.encode!(before_tool) =~ marker
      assert {:ok, _, admin_before} = live(login(conn, admin.id), ~p"/chat/#{finance.id}")
      assert admin_before =~ marker

      assert {:ok, _} = Restrictions.restrict_space(finance, ["admin"], admin.id)
      assert {:ok, _, locked_html} = live(member_conn, "/chat")
      assert locked_html =~ ~s(data-role="restricted-channel-row")
      assert locked_html =~ ~s(data-space-id="#{finance.id}")
      assert locked_html =~ "Restricted, ask an admin"
      refute locked_html =~ marker

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(member_conn, ~p"/chat/#{finance.id}")

      assert {:error, denial} = ToolSurface.execute("space_get_messages", args, context)
      assert denial.restricted == true
      refute Jason.encode!(denial) =~ marker
      assert {:ok, _, admin_after} = live(login(conn, admin.id), ~p"/chat/#{finance.id}")
      assert admin_after =~ marker
    end
  end

  describe "two mapped OIDC groups" do
    test "both custom roles are assigned and an Ops-only channel is readable", %{
      conn: conn,
      root: root
    } do
      {:ok, finance} = Roles.create_custom_role(root, %{name: "Finance"})
      {:ok, ops} = Roles.create_custom_role(root, %{name: "Ops"})

      {:ok, _} =
        IdpGroupRoles.create(%{
          group_value: "finance-team",
          role_key: finance.key,
          org_id: root.id
        })

      {:ok, _} =
        IdpGroupRoles.create(%{group_value: "ops-team", role_key: ops.key, org_id: root.id})

      ops_channel = channel!(%{name: "Ops only", org_id: root.id})
      {:ok, _} = Restrictions.restrict_space(ops_channel, [ops.key], nil)

      response =
        oidc_callback(conn, "accept-two", "accept-two@example.com", ["finance-team", "ops-team"])

      assert redirected_to(response, 302) == "/"
      user_id = get_session(response, :current_user_id)
      assert idp_keys(user_id) == MapSet.new([finance.key, ops.key])
      scope = Scope.for_user(Accounts.get_user(user_id))
      assert Access.holds_role?(scope, finance.key, root.id)
      assert Access.holds_role?(scope, ops.key, root.id)
      assert Access.can?(scope, "chat.read", ops_channel.id)
    end
  end

  describe "the default external group" do
    test "a staged guest sees only its granted channel, and an unstaged guest remains in holding",
         %{conn: conn, root: root} do
      granted = channel!(%{org_id: root.id})
      other = channel!(%{org_id: root.id})

      {:ok, _} =
        ExternalGrants.create_grant(%{
          email: "accept-guest@example.com",
          oidc_sub: "accept-guest",
          target_org_id: root.id,
          space_grants: [%{"space_id" => granted.id, "role" => "member"}],
          dm_allowlist_org_ids: [root.id]
        })

      full = oidc_callback(conn, "accept-guest", "accept-guest@example.com", ["sxi-external"])
      assert redirected_to(full, 302) == "/"
      user_id = get_session(full, :current_user_id)
      assert get_session(full, :external_admission) == nil

      assert Repo.exists?(
               from(m in OrgMembership, where: m.user_id == ^user_id and m.external == true)
             )

      scope = Scope.for_user(Accounts.get_user(user_id))
      assert Scope.guest?(scope)
      ids = Chat.list_spaces(kind: "channel", scope: scope) |> Enum.map(& &1.id)
      assert granted.id in ids
      refute other.id in ids

      holding =
        oidc_callback(
          Phoenix.ConnTest.build_conn(),
          "accept-no-grant",
          "accept-no-grant@example.com",
          ["sxi-external"]
        )

      assert redirected_to(holding, 302) == "/welcome"

      assert %{state: :holding, reason: :awaiting_grant} =
               get_session(holding, :external_admission)

      holding_id = get_session(holding, :current_user_id)
      assert scoped_counts(holding_id) == {0, 0}
    end
  end

  describe "absent group claim" do
    test "the callback keeps the identity-only baseline and creates no scoped rows", %{conn: conn} do
      before = census()
      response = oidc_callback(conn, "accept-no-groups", "accept-no-groups@example.com", :absent)
      assert redirected_to(response, 302) == "/"
      user_id = get_session(response, :current_user_id)
      assert idp_keys(user_id) == MapSet.new()
      assert scoped_counts(user_id) == {0, 0}
      assert census() == {elem(before, 0), elem(before, 1) + 1, elem(before, 2)}
      user = Accounts.get_user(user_id)
      assert Scope.for_user(user) == Scope.for_user(Repo.preload(user, org_memberships: :org))
    end
  end

  defp oidc_callback(conn, sub, email, groups) do
    claims = %{"sub" => sub, "email" => email, "name" => "Acceptance User"}
    claims = if groups == :absent, do: claims, else: Map.put(claims, "groups", groups)

    Application.put_env(:platform, :oidc_mock_response, {
      :ok,
      %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "test-id-token"}}
    })

    conn
    |> init_test_session(oidc_session_params: %{state: "expected-state", nonce: "n"})
    |> get("/auth/oidc/callback?code=test-code&state=expected-state")
  end

  defp idp_keys(user_id) do
    Repo.all(
      from(a in RoleAssignment,
        where: a.principal_type == "user" and a.principal_id == ^user_id and a.source == "idp",
        select: a.role_key
      )
    )
    |> MapSet.new()
  end

  defp scoped_counts(user_id) do
    {Repo.aggregate(
       from(m in OrgMembership, where: m.user_id == ^user_id and m.external == true),
       :count
     ),
     Repo.aggregate(
       from(p in Platform.Chat.Participant,
         where: p.participant_type == "user" and p.participant_id == ^user_id
       ),
       :count
     )}
  end

  defp census do
    {Repo.aggregate(RoleAssignment, :count), Repo.aggregate(OrgMembership, :count),
     Repo.aggregate(Platform.Chat.Participant, :count)}
  end
end
