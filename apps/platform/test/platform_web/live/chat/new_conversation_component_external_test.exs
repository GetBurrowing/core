defmodule PlatformWeb.ChatLive.NewConversationComponentExternalTest do
  @moduledoc """
  rbac-external-users M5 stage 3 — the New-Conversation (DM) picker must SHOW
  only what M8 (`Chat.external_dm_permitted?/3`) would permit, so the UI can't
  offer a DM the backend will reject. In external mode the picker drops agents
  entirely and filters humans to the external user's allowlisted org(s), in BOTH
  the open render (`update/2`) and every keystroke (`new_conversation_search/2`).
  Internal mode is unchanged: all users + agents.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  # A wrapper LiveView so we can drive the LiveComponent's handle_event
  # (`new_conversation_search`) — a component can't be event-driven standalone.
  defmodule PickerHostLive do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok,
       Phoenix.Component.assign(socket,
         user_id: session["user_id"],
         external?: session["external?"] == true
       )}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={PlatformWeb.ChatLive.NewConversationComponent}
          id="picker"
          open={true}
          user_id={@user_id}
          external?={@external?}
        />
      </div>
      """
    end

    # The component sends close/navigate/flash messages to its parent; swallow.
    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  # ── Helpers (mirror chat_dm_allowlist_test seed vocabulary) ─────────────

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "nc-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-nc-#{n}"
    })
    |> Repo.insert!()
  end

  defp tenant_org! do
    n = System.unique_integer([:positive])

    %Org{}
    |> Org.changeset(%{
      name: "Tenant #{n}",
      slug: "tenant_nc_#{n}",
      parent_org_id: Tenancy.get_org_by_slug!("fabrikam").id
    })
    |> Repo.insert!()
  end

  defp membership!(user, org) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
    |> Repo.insert!()
  end

  defp external_user!(org) do
    user = create_user!("Xavier External")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
    Tenancy.allow_dm(user, org)
    user
  end

  defp active_agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "nc-agent-#{n}",
      name: "Zeta Bot",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  setup %{conn: conn} do
    org_a = tenant_org!()
    org_b = tenant_org!()

    ext = external_user!(org_a)

    allowed = create_user!("Amy Allowed")
    membership!(allowed, org_a)

    denied = create_user!("Dan Denied")
    membership!(denied, org_b)

    agent = active_agent!()

    %{conn: conn, ext: ext, allowed: allowed, denied: denied, agent: agent}
  end

  defp mount_picker(conn, session) do
    live_isolated(conn, PickerHostLive, session: session)
  end

  describe "external mode" do
    test "open render lists the allowlisted human, refutes the non-allowlisted human and the agent",
         %{conn: conn, ext: ext, allowed: allowed, denied: denied, agent: agent} do
      {:ok, _view, html} =
        mount_picker(conn, %{"user_id" => ext.id, "external?" => true})

      assert html =~ allowed.name
      refute html =~ denied.name
      refute html =~ agent.name
      # The whole "Agents" section header is suppressed (agents == []).
      refute html =~ "Agents"
    end

    test "typing a query that matches the non-allowlisted human still never surfaces them",
         %{conn: conn, ext: ext, allowed: allowed, denied: denied} do
      {:ok, view, _html} =
        mount_picker(conn, %{"user_id" => ext.id, "external?" => true})

      html =
        view
        |> element("#picker input")
        |> render_keyup(%{"value" => "Dan"})

      refute html =~ denied.name
      # And the allowlisted human is filtered out only because the query doesn't
      # match them — searching their name still surfaces them.
      html2 =
        view
        |> element("#picker input")
        |> render_keyup(%{"value" => "Amy"})

      assert html2 =~ allowed.name
    end
  end

  describe "internal mode (control)" do
    test "lists all users AND agents unchanged", %{
      conn: conn,
      ext: ext,
      allowed: allowed,
      denied: denied,
      agent: agent
    } do
      {:ok, _view, html} =
        mount_picker(conn, %{"user_id" => ext.id, "external?" => false})

      # Internal picker is unrestricted: both humans (from any org) AND the agent.
      assert html =~ allowed.name
      assert html =~ denied.name
      assert html =~ agent.name
      assert html =~ "Agents"
    end
  end
end
