defmodule PlatformWeb.ControlCenter.UnattachedRuntimesPanelTest do
  @moduledoc """
  Task 01a1b84c stage 2: the Unattached runtimes pane at
  `/control/unattached-runtimes`, its admin-only sidebar entry, and the
  federate-conflict pointer to it.

  Orphans are built with `Repo.delete!/1` on the agent row (FK
  `on_delete: :nilify_all`), never through `AgentData.delete_agent/1`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.Org

  @path "/control/unattached-runtimes"

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp rid, do: "gateway-example-#{System.unique_integer([:positive])}"

  defp attached!(owner, runtime_id) do
    n = System.unique_integer([:positive])

    {:ok, agent, runtime, _token} =
      Federation.provision_agent_runtime(
        owner.id,
        %{slug: "unatt-panel-#{n}", name: "Unattached Panel #{n}", status: "active"},
        %{runtime_id: runtime_id, tool_profile: AgentRuntime.default_tool_profile()}
      )

    {agent, runtime}
  end

  defp orphan!(owner, runtime_id) do
    {agent, runtime} = attached!(owner, runtime_id)
    Repo.delete!(agent)
    Federation.get_runtime(runtime.id)
  end

  defp row(runtime), do: "#unattached-runtime-#{runtime.id}"

  defp open_federate(view) do
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "federate"})
  end

  defp submit_federate(view, runtime_id) do
    view
    |> form("#federate-form",
      federate: %{
        runtime_id: runtime_id,
        display_name: "",
        agent_name: "Intruder #{System.unique_integer([:positive])}"
      }
    )
    |> render_submit()
  end

  describe "routing" do
    test "/control/unattached-runtimes is its own route, not an agent slug" do
      assert %{route: @path, plug_opts: :unattached_runtimes, path_params: params} =
               Phoenix.Router.route_info(PlatformWeb.Router, "GET", @path, "example.com")

      refute Map.has_key?(params, "agent_slug")

      # The catch-all is still there for real slugs.
      assert %{route: "/control/:agent_slug"} =
               Phoenix.Router.route_info(
                 PlatformWeb.Router,
                 "GET",
                 "/control/some-agent",
                 "example.com"
               )
    end
  end

  describe "admin" do
    test "sees the sidebar link with a count, the orphan row, and Revoke removes and revokes it",
         %{conn: conn} do
      orphan = orphan!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")
      assert has_element?(view, "#unattached-runtimes-link")
      assert has_element?(view, "#unattached-runtimes-count", "1")

      {:ok, view, _} = live(as_user(conn, root_admin!()), @path)
      assert has_element?(view, "#unattached-runtimes-panel")
      assert has_element?(view, row(orphan))
      assert has_element?(view, "#{row(orphan)} code", orphan.runtime_id)
      refute has_element?(view, "#unattached-runtimes-empty")

      view
      |> element("#{row(orphan)} button[phx-click=revoke_unattached_runtime]")
      |> render_click()

      refute has_element?(view, row(orphan))
      assert has_element?(view, "#unattached-runtimes-empty", "No unattached runtimes.")
      refute has_element?(view, "#unattached-runtimes-count")

      revoked = Federation.get_runtime(orphan.id)
      assert revoked.status == "revoked"
      assert revoked.auth_token_hash == nil
    end

    test "an attached runtime is never a row", %{conn: conn} do
      {_agent, attached} = attached!(member!(), rid())
      orphan = orphan!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, root_admin!()), @path)
      assert has_element?(view, row(orphan))
      refute has_element?(view, row(attached))
    end
  end

  describe "member" do
    test "sees neither the link nor rows at the URL", %{conn: conn} do
      orphan = orphan!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, member!()), ~p"/control")
      refute has_element?(view, "#unattached-runtimes-link")

      {:ok, view, _} = live(as_user(conn, member!()), @path)
      assert has_element?(view, "#unattached-runtimes-admins-only")
      refute has_element?(view, "#unattached-runtimes-panel")
      refute has_element?(view, row(orphan))
      refute has_element?(view, "button[phx-click=revoke_unattached_runtime]")

      assert Federation.get_runtime(orphan.id).status == "active"
    end
  end

  describe "federate conflict" do
    test "an admin gets the Unattached runtimes link when the holder is unattached",
         %{conn: conn} do
      orphan = orphan!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")
      open_federate(view)
      html = submit_federate(view, orphan.runtime_id)

      # The pre-existing flash is unchanged.
      assert html =~ "is in use by an active runtime"

      assert has_element?(
               view,
               "#federate-conflict-unattached",
               "It is not attached to any agent. Revoke it in"
             )

      assert has_element?(
               view,
               ~s(#federate-conflict-unattached-link[href="#{@path}"]),
               "Unattached runtimes"
             )

      # Closing the sheet clears it.
      render_click(view, "close_onboarding", %{})
      open_federate(view)
      refute has_element?(view, "#federate-conflict-unattached")
    end

    test "a member gets the sentence without a link", %{conn: conn} do
      orphan = orphan!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, member!()), ~p"/control")
      open_federate(view)
      submit_federate(view, orphan.runtime_id)

      assert has_element?(view, "#federate-conflict-unattached", "Ask an admin")
      refute has_element?(view, "#federate-conflict-unattached-link")
    end

    test "nothing new when the holder is attached", %{conn: conn} do
      {_agent, attached} = attached!(member!(), rid())

      {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")
      open_federate(view)
      html = submit_federate(view, attached.runtime_id)

      assert html =~ "is in use by an active runtime"
      refute has_element?(view, "#federate-conflict-unattached")
      refute has_element?(view, "#federate-conflict-unattached-link")
    end
  end
end
