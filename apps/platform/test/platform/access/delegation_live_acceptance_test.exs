defmodule Platform.Access.DelegationLiveAcceptanceTest do
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Access.{Change, Changes, Grant, Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  defp unique, do: System.unique_integer([:positive])

  defp user!(name) do
    n = unique()

    %User{}
    |> User.changeset(%{email: "accept-#{n}@example.com", name: name, oidc_sub: "accept-#{n}"})
    |> Repo.insert!()
  end

  defp org! do
    n = unique()

    %Org{}
    |> Org.changeset(%{
      name: "Acceptance #{n}",
      slug: "acceptance_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("acme").id
    })
    |> Repo.insert!()
  end

  defp member!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()

    user
  end

  defp conn_for(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp rail_keys(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Enum.flat_map(&Floki.attribute(&1, "data-destination"))
    |> MapSet.new()
  end

  defp snapshots(org) do
    Repo.all(from(g in Grant, where: g.org_id == ^org.id, order_by: [asc: g.id]))
    |> Enum.map(&Grant.snapshot/1)
  end

  describe "a project admin cannot grant outside their project" do
    test "Q is refused without rows and P succeeds" do
      org = org!()
      pa = member!(user!("Project admin"), org, "guest")
      recipient = user!("Recipient")
      {:ok, p} = Tasks.create_project(%{name: "Allowed #{unique()}", org_id: org.id})
      {:ok, q} = Tasks.create_project(%{name: "Outside #{unique()}", org_id: org.id})

      for permission <- ~w(access.manage tasks.read) do
        assert {:ok, _} =
                 Grants.grant(%{principal: pa, permission: permission, resource: p})
      end

      actor = Scope.for_user(Platform.Accounts.get_user(pa.id))
      before = {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count)}

      assert {:error, %{rule: :not_granted, resource: {:project, q_id}}} =
               Grants.grant(%{principal: recipient, permission: "tasks.read", resource: q},
                 actor: actor
               )

      assert q_id == q.id
      assert {Repo.aggregate(Grant, :count), Repo.aggregate(Change, :count)} == before

      assert {:ok, %Grant{resource_id: p_id}} =
               Grants.grant(%{principal: recipient, permission: "tasks.read", resource: p},
                 actor: actor
               )

      assert p_id == p.id
    end
  end

  describe "view-as matches the real user's rail" do
    test "root and member rails agree with their view-as result and differ from each other" do
      org = Tenancy.get_org_by_slug!("acme")
      root = member!(user!("Root"), org, "admin")
      member = member!(user!("Member"), org, "member")

      {:ok, _root_live, root_html} = conn_for(root) |> live("/tasks")
      {:ok, _member_live, member_html} = conn_for(member) |> live("/tasks")
      real_root = rail_keys(root_html, "[data-icon-rail] [data-destination]")
      real_member = rail_keys(member_html, "[data-icon-rail] [data-destination]")
      assert real_root != real_member

      for {target, real} <- [{root, real_root}, {member, real_member}] do
        {:ok, _view, html} = conn_for(root) |> live("/access/view-as/user/#{target.id}")
        assert rail_keys(html, "[data-role=view-as-rail] [data-destination]") == real
      end
    end
  end

  describe "a revoked channel disappears from an open session within seconds" do
    test "the same guest view keeps D while C disappears in under two seconds" do
      org = org!()
      guest = user!("Guest")
      assert {:ok, _} = Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org.id})
      Tenancy.allow_dm(guest, org)
      n = unique()
      {:ok, c} = Chat.create_space(%{name: "Acceptance C #{n}", slug: "accept-c-#{n}", kind: "channel", org_id: org.id})
      {:ok, d} = Chat.create_space(%{name: "Acceptance D #{n}", slug: "accept-d-#{n}", kind: "channel", org_id: org.id})
      assert {:ok, c_grant} = Grants.grant(%{principal: guest, permission: "chat.read", resource: c})
      assert {:ok, _} = Grants.grant(%{principal: guest, permission: "chat.read", resource: d})

      assert {:ok, _} =
               Chat.add_participant(d.id, %{
                 participant_type: "user",
                 participant_id: guest.id,
                 joined_at: DateTime.utc_now()
               })

      conn = conn_for(guest) |> Map.put(:host, "chat.localhost")
      {:ok, view, html} = live(conn, "/chat/#{d.slug}")
      assert html =~ c.name
      assert html =~ d.name
      pid = view.pid

      started = System.monotonic_time(:millisecond)
      assert {:ok, _} = Grants.revoke(c_grant)
      after_html = render(view)
      elapsed_ms = System.monotonic_time(:millisecond) - started

      refute after_html =~ c.name
      assert after_html =~ d.name
      assert view.pid == pid
      assert Process.alive?(pid)
      assert elapsed_ms < 2000, "live revoke took #{elapsed_ms} ms"
    end
  end

  describe "undo restores the exact prior grant set" do
    test "a multi-row ledger change restores every snapshot including original ids" do
      org = org!()
      user = user!("Grant holder")
      {:ok, project} = Tasks.create_project(%{name: "Undo #{unique()}", org_id: org.id})
      assert {:ok, _} = Grants.grant(%{principal: user, permission: "tasks.read", resource: project})
      before = snapshots(org)

      rows = [
        %{principal_type: "user", principal_id: user.id, org_id: org.id,
          permission: "tasks.read", resource_type: "project", resource_id: project.id,
          effect: "deny"},
        %{principal_type: "user", principal_id: user.id, org_id: org.id,
          permission: "chat.read", resource_type: "project", resource_id: project.id,
          effect: "allow"}
      ]

      query = from(g in Grant, where: g.org_id == ^org.id and g.principal_id == ^user.id and g.resource_id == ^project.id)
      keys = Enum.map(rows, &Grant.tuple_key(Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end)))

      assert {:ok, %{change: %Change{} = change}} =
               Changes.commit(Scope.system(), "acceptance_multi", fn ->
                 Repo.delete_all(query)
                 inserted = Enum.map(rows, fn attrs -> %Grant{} |> Grant.changeset(attrs) |> Repo.insert!() end)
                 {:ok, inserted}
               end, query: query, keys: keys, org_id: org.id)

      refute snapshots(org) == before
      assert {:ok, %{change: %Change{}}} = Changes.undo(change.id, Scope.system())
      assert snapshots(org) == before
    end
  end
end
