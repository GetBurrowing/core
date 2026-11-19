defmodule PlatformWeb.ControlCenter.OwnerTransferLiveTest do
  @moduledoc """
  The Owner line and Owner control on `/control/<slug>` for an install-managed
  agent (task 01a1f42d stage 4).

  The control renders for the runtime's owner and for an install admin, and for
  nobody else. Rendering is an affordance: both events go through
  `NativeAgents.transfer_owner/4`, so a forged event from anyone else is
  refused and changes nothing.

  Mutants these name:

    * render the control for every viewer (drop the `can_transfer_owner?`
      gate in `RuntimePanel.assign_owner_control/1`) -> "a member sees the
      owner but not the control" goes red;
    * call `transfer_owner/4` with the agent's owner instead of the signed-in
      user -> "a forged confirm from a member is refused" goes red;
    * skip the reload after a transfer -> "an admin transfers ownership"
      goes red: the Owner line keeps the previous name.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.{AgentRuntime, NativeAgents}
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @refused "Only the agent&#39;s owner or an admin can do that."

  defp user!(label, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %User{
          email: "owner-lv-#{label}-#{n}@example.com",
          name: "Owner LV #{label} #{n}",
          oidc_sub: "oidc-owner-lv-#{label}-#{n}"
        },
        attrs
      )
    )
  end

  defp member!(role, label \\ nil, attrs \\ %{}) do
    user = user!(label || role, attrs)

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp as(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp native!(owner, name) do
    {:ok, agent, runtime} = NativeAgents.create(owner.id, %{name: name, harness: "claude_code"})
    {agent, runtime}
  end

  defp owner_id(runtime), do: Repo.get!(AgentRuntime, runtime.id).owner_user_id

  defp owner_changed_events(runtime) do
    Repo.all(
      from(e in Platform.Audit.Event,
        where:
          e.event_type == ^NativeAgents.owner_changed_event() and
            e.resource_id == ^runtime.id
      )
    )
  end

  defp owner_line(view),
    do: view |> element(~s{[data-role="agent-owner-name"]}) |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, "agent-host-token-01a1f42d-s4-live")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    owner = member!("member", "owner")
    {agent, runtime} = native!(owner, "Keeper")
    %{owner: owner, agent: agent, runtime: runtime}
  end

  describe "who sees the Owner control" do
    test "the owner sees the owner line and the control", %{conn: conn} = ctx do
      {:ok, view, _html} = live(as(conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")

      assert owner_line(view) == ctx.owner.name
      assert has_element?(view, "#owner-transfer-form")

      assert has_element?(
               view,
               "#owner-transfer-select option[value='#{ctx.owner.id}'][selected]"
             )
    end

    test "an admin who is not the owner sees the control", %{conn: conn} = ctx do
      admin = member!("admin")

      {:ok, view, _html} = live(as(conn, admin), ~p"/control/#{ctx.agent.slug}")

      assert owner_line(view) == ctx.owner.name
      assert has_element?(view, "#owner-transfer-form")
      assert has_element?(view, "#owner-transfer-select option[value='#{admin.id}']")
    end

    test "a member sees the owner but not the control", %{conn: conn} = ctx do
      member = member!("member", "bystander")

      {:ok, view, _html} = live(as(conn, member), ~p"/control/#{ctx.agent.slug}")

      assert owner_line(view) == ctx.owner.name
      refute has_element?(view, "#owner-transfer-form")
      refute has_element?(view, "#owner-transfer-select")
      refute has_element?(view, "#owner-transfer-confirm")
    end

    test "the picker offers only non-archived root-org members", %{conn: conn} = ctx do
      archived = member!("member", "archived", %{archived_at: DateTime.utc_now()})
      outsider = user!("outsider")

      {:ok, view, _html} = live(as(conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")

      refute has_element?(view, "#owner-transfer-select option[value='#{archived.id}']")
      refute has_element?(view, "#owner-transfer-select option[value='#{outsider.id}']")
    end

    test "a federated agent has no owner card at all", %{conn: conn, owner: owner} do
      {:ok, agent, _runtime, _token} =
        Federation.provision_agent_runtime(
          owner.id,
          %{
            slug: "fed-own-#{System.unique_integer([:positive])}",
            name: "FedOwn",
            status: "active"
          },
          %{runtime_id: "fed-own-rt-#{System.unique_integer([:positive])}"}
        )

      {:ok, view, html} = live(as(conn, owner), ~p"/control/#{agent.slug}")

      assert html =~ "Federation Connection"
      refute has_element?(view, "#agent-owner")
      refute has_element?(view, "#owner-transfer-form")
    end
  end

  describe "refused on the server" do
    test "a forged confirm from a member is refused and the owner stays", %{conn: conn} = ctx do
      member = member!("member", "forger")

      {:ok, view, _html} = live(as(conn, member), ~p"/control/#{ctx.agent.slug}")

      html = render_hook(view, "owner_transfer_confirm", %{"new_owner_id" => member.id})

      assert html =~ @refused
      assert owner_id(ctx.runtime) == ctx.owner.id
      assert owner_changed_events(ctx.runtime) == []
      assert owner_line(view) == ctx.owner.name
    end

    test "a forged review from a member opens no confirm", %{conn: conn} = ctx do
      member = member!("member", "peeker")

      {:ok, view, _html} = live(as(conn, member), ~p"/control/#{ctx.agent.slug}")

      html = render_hook(view, "owner_transfer_review", %{"new_owner_id" => member.id})

      assert html =~ @refused
      refute has_element?(view, "#owner-transfer-confirm")
    end
  end

  describe "transferring" do
    test "an admin transfers ownership; the owner line updates without reload",
         %{conn: conn} = ctx do
      admin = member!("admin")
      target = member!("member", "target")

      {:ok, view, _html} = live(as(conn, admin), ~p"/control/#{ctx.agent.slug}")

      view
      |> form("#owner-transfer-form", %{"new_owner_id" => target.id})
      |> render_submit()

      assert has_element?(view, "#owner-transfer-confirm", target.name)
      refute has_element?(view, "#owner-transfer-form")
      # Nothing changes until the confirm.
      assert owner_id(ctx.runtime) == ctx.owner.id

      html = view |> element(~s{[data-role="owner-transfer-confirm"]}) |> render_click()

      assert html =~ "#{target.name} now owns Keeper."
      assert owner_line(view) == target.name
      assert owner_id(ctx.runtime) == target.id
      assert [%{actor_id: actor_id}] = owner_changed_events(ctx.runtime)
      assert actor_id == admin.id
      refute has_element?(view, "#owner-transfer-confirm")
      assert has_element?(view, "#owner-transfer-select option[value='#{target.id}'][selected]")
    end

    test "Cancel closes the confirm and changes nothing", %{conn: conn} = ctx do
      target = member!("member", "untouched")

      {:ok, view, _html} = live(as(conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")

      view
      |> form("#owner-transfer-form", %{"new_owner_id" => target.id})
      |> render_submit()

      view |> element(~s{[data-role="owner-transfer-cancel"]}) |> render_click()

      refute has_element?(view, "#owner-transfer-confirm")
      assert has_element?(view, "#owner-transfer-form")
      assert owner_id(ctx.runtime) == ctx.owner.id
    end

    test "choosing the current owner says so in plain words", %{conn: conn} = ctx do
      {:ok, view, _html} = live(as(conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")

      html =
        view
        |> form("#owner-transfer-form", %{"new_owner_id" => ctx.owner.id})
        |> render_submit()

      assert html =~ "#{ctx.owner.name} already owns Keeper."
      refute has_element?(view, "#owner-transfer-confirm")

      html = render_hook(view, "owner_transfer_confirm", %{"new_owner_id" => ctx.owner.id})
      assert html =~ "#{ctx.owner.name} already owns Keeper."
      assert owner_changed_events(ctx.runtime) == []
    end

    test "an ineligible new owner gets a plain-language refusal", %{conn: conn} = ctx do
      outsider = user!("outsider")

      {:ok, view, _html} = live(as(conn, ctx.owner), ~p"/control/#{ctx.agent.slug}")

      for bad <- [outsider.id, Ecto.UUID.generate(), "not-a-uuid"] do
        html = render_hook(view, "owner_transfer_confirm", %{"new_owner_id" => bad})

        assert html =~
                 "That person can&#39;t own this agent. Pick someone who belongs to this install and hasn&#39;t been archived."
      end

      assert owner_id(ctx.runtime) == ctx.owner.id
      assert owner_changed_events(ctx.runtime) == []
    end
  end
end
