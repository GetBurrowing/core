defmodule PlatformWeb.ControlCenter.AddChooserPermissionTest do
  @moduledoc """
  Task 01a1ae4b stage 1: the Agents > Add chooser shows the create paths
  (External Agent, Import, Create Custom; From a Template is gone since task
  01a1b6ad stage 2, whose character builder is now the Add entry and puts
  these cards behind its Advanced link) closed to a user
  without agents.manage_all, with the reason, before they type. Federate
  stays open. Server side, a forged flow or roles-picker sentinel never opens
  a create form, and field validation no longer fires a refusal per keystroke.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tenancy.Org
  alias PlatformWeb.ControlCenter.Onboarding

  @admin_line "Only org admins can add external agents. Ask an admin to add it or to grant you agent management."
  @locked_flows ~w(import create external)

  describe "member" do
    setup %{conn: conn} do
      user = member!()
      %{user: user, conn: as_user(conn, user)}
    end

    test "sees the create paths locked with the admin line once, and Federate open", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)

      for flow <- @locked_flows do
        card = "#add-agent-chooser #choose-#{flow}"
        assert has_element?(view, ~s(#{card}[aria-disabled="true"]))
        assert has_element?(view, ~s(#{card}[aria-describedby="add-chooser-admin-line"]))
        assert has_element?(view, "#{card} .hero-lock-closed.text-info")
        refute has_element?(view, "#{card}[phx-click]")
        refute has_element?(view, "#{card}[phx-value-flow]")
        # Readable, not faded: base-200 surface with the AA muted text slot.
        assert has_element?(view, "#{card}.bg-base-200")
        refute render(element(view, card)) =~ ~r/opacity-|btn-disabled|text-primary/
      end

      chooser = view |> element("#add-agent-chooser") |> render()
      assert Onboarding.admin_line() == @admin_line
      assert count(chooser, ~s(data-role="admin-line")) == 1
      assert has_element?(view, "#add-agent-chooser #add-chooser-admin-line")

      assert has_element?(
               view,
               ~s(#add-agent-chooser #choose-federate[phx-click="choose_onboarding"][phx-value-flow="federate"])
             )

      refute has_element?(view, "#choose-federate[aria-disabled]")
    end

    test "the line text renders verbatim in the chooser", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)

      text =
        view
        |> element("#add-chooser-admin-line")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.text(sep: " ")
        |> String.split()
        |> Enum.join(" ")

      assert text == @admin_line
    end

    test "a forged choose_onboarding for a create flow keeps the chooser", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)

      for flow <- @locked_flows do
        html = render_click(view, "choose_onboarding", %{"flow" => flow})
        assert has_element?(view, "#add-agent-chooser")
        refute has_element?(view, "#external-agent-form")
        refute html =~ "You can only manage your own agents."
      end

      # Federate is gated separately and still opens.
      render_click(view, "choose_onboarding", %{"flow" => "federate"})
      assert has_element?(view, "#federate-form")
    end

    test "the roles picker offers no create sentinel, and a forged one opens the chooser", %{
      conn: conn,
      user: user
    } do
      _ = federated_agent!(user)
      :ok = Roles.unassign_role("designer")

      {:ok, view, _} = live(conn, ~p"/control")
      assert has_element?(view, ~s(select[data-role="fill-role-picker"]))
      refute has_element?(view, ~s(option[value="__new_external__"]))

      render_change(view, "assign_role", %{
        "role_key" => "designer",
        "agent_id" => "__new_external__"
      })

      assert has_element?(view, "#add-agent-chooser")
      refute has_element?(view, "#external-agent-form")
    end

    test "external_agent_change is validation only: no refusal on a keystroke", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)

      html =
        render_change(view, "external_agent_change", %{
          "external_agent" => %{"name" => "Typed Name", "slug" => ""}
        })

      refute html =~ "You can only manage your own agents."
      refute has_element?(view, "#flash-error")
    end

    test "submit_external stays refused and creates nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")

      html =
        render_submit(view, "submit_external", %{
          "external_agent" => external_params("Member Forged")
        })

      # Stage 2: the create refusal has its own message.
      assert html =~ "You don&#39;t have permission to add agents to this org."
      refute html =~ "You can only manage your own agents."
      refute Repo.get_by(Agent, slug: "member-forged")
    end
  end

  describe "admin" do
    setup %{conn: conn} do
      %{conn: as_user(conn, root_admin!())}
    end

    test "sees every card enabled and no admin line", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)

      for flow <- ["federate" | @locked_flows] do
        assert has_element?(
                 view,
                 ~s(#add-agent-chooser #choose-#{flow}[phx-click="choose_onboarding"][phx-value-flow="#{flow}"])
               )

        refute has_element?(view, "#choose-#{flow}[aria-disabled]")
      end

      refute has_element?(view, ~s([data-role="admin-line"]))
      refute render(view) =~ "Only org admins can add external agents."
    end

    test "chooses External Agent, fills it in and creates the agent", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/control")
      open_advanced(view)
      render_click(view, "choose_onboarding", %{"flow" => "external"})
      assert has_element?(view, "#external-agent-form")

      view
      |> form("#external-agent-form", external_agent: external_params("Admin External"))
      |> render_change()

      view
      |> form("#external-agent-form", external_agent: external_params("Admin External"))
      |> render_submit()

      assert %Agent{kind: "external"} = Repo.get_by(Agent, slug: "admin-external")
    end
  end

  defp external_params(name) do
    %{
      name: name,
      slug: "",
      endpoint_kind: "openai_compat",
      base_url: "https://api.example.test/v1",
      model: "model-a",
      default_behavior: "chat",
      vault_mode: "paste",
      vault_key: "",
      secret: "",
      save_to_vault: "false"
    }
  end

  # Add opens the character builder; the chooser is behind its Advanced link.
  defp open_advanced(view) do
    render_click(view, "open_onboarding_chooser", %{})
    view |> element("#ba-advanced") |> render_click()
  end

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  defp member! do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()))
    user
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(user) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "chooser-test-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "chooser-test-#{n}",
        name: "Chooser Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    runtime
    |> Platform.Agents.AgentRuntime.changeset(%{agent_id: agent.id})
    |> Repo.update!()

    {agent, runtime}
  end
end
