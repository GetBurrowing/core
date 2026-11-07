defmodule PlatformWeb.ControlCenter.InSheetRefusalTest do
  @moduledoc """
  Task 01a1ae4b stage 2: a policy refusal raised while a sheet or modal is
  open renders inside that sheet as a role=alert, not as a page flash behind
  the overlay. The create refusal has its own message; ownership refusals keep
  "You can only manage your own agents."; with no sheet open the page flash
  path is unchanged.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.RuntimeProfiles
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tenancy.{Org, OrgMembership}

  @create_refused "You don&#39;t have permission to add agents to this org."
  @create_refused_text "You don't have permission to add agents to this org."
  @ownership "You can only manage your own agents."

  describe "member with the Add overlay open" do
    setup %{conn: conn} do
      user = user!("member")
      {:ok, view, _} = live(as_user(conn, user), ~p"/control")
      render_click(view, "open_onboarding_chooser", %{})
      %{view: view}
    end

    test "a forged submit_external is refused inside the overlay, not in the flash", %{
      view: view
    } do
      before = Repo.aggregate(Agent, :count)

      render_submit(view, "submit_external", %{
        "external_agent" => external_params("Member Forged")
      })

      assert has_element?(
               view,
               ~s(#onboarding-overlay #sheet-refusal[role="alert"].alert-error),
               @create_refused_text
             )

      refute has_element?(view, "#flash-error")
      refute render(view) =~ @ownership
      # Exactly one alert carries the message: the in-sheet one.
      assert count(render(view), @create_refused) == 1
      refute Repo.get_by(Agent, slug: "member-forged")
      assert Repo.aggregate(Agent, :count) == before
    end

    test "the alert sits at the top of the sheet body, above the chooser", %{view: view} do
      render_submit(view, "submit_external", %{"external_agent" => external_params("X")})
      html = view |> element("#onboarding-overlay") |> render()
      # It takes focus when it appears, so a sheet scrolled to its submit
      # button scrolls back to the alert.
      assert has_element?(view, ~s(#sheet-refusal[tabindex="-1"][phx-mounted]))
      {alert_at, _} = :binary.match(html, ~s(id="sheet-refusal"))
      {chooser_at, _} = :binary.match(html, ~s(id="add-agent-chooser"))
      assert alert_at < chooser_at
    end

    test "forged create_from_template and submit_import show the same in-sheet message", %{
      view: view
    } do
      for {event, params} <- [
            {"create_from_template", %{"template" => %{"name" => "Forged"}}},
            {"submit_import", %{}},
            {"create_agent", %{"create_agent" => %{"name" => "Forged"}}}
          ] do
        render_click(view, event, params)

        assert has_element?(
                 view,
                 ~s(#onboarding-overlay #sheet-refusal[role="alert"]),
                 @create_refused_text
               ),
               "#{event} did not render in the sheet"

        refute has_element?(view, "#flash-error")
      end
    end

    test "the alert clears on the next permitted event and on closing the sheet", %{
      view: view
    } do
      render_submit(view, "submit_external", %{"external_agent" => external_params("X")})
      assert has_element?(view, "#sheet-refusal")

      render_change(view, "external_agent_change", %{"external_agent" => %{"name" => "Y"}})
      refute has_element?(view, "#sheet-refusal")

      render_submit(view, "submit_external", %{"external_agent" => external_params("X")})
      assert has_element?(view, "#sheet-refusal")
      render_click(view, "close_onboarding", %{})
      render_click(view, "open_onboarding_chooser", %{})
      assert has_element?(view, "#add-agent-chooser")
      refute has_element?(view, "#sheet-refusal")
    end
  end

  test "with no sheet open a forged create event still flashes the new message", %{conn: conn} do
    {:ok, view, _} = live(as_user(conn, user!("member")), ~p"/control")
    refute has_element?(view, "#onboarding-overlay")

    html = render_submit(view, "submit_external", %{"external_agent" => external_params("Z")})

    assert html =~ @create_refused
    assert has_element?(view, "#flash-error", @create_refused_text)
    refute has_element?(view, "#sheet-refusal")
    refute html =~ @ownership
  end

  test "an admin demoted while the External Agent sheet is open is refused in the sheet, typed values kept",
       %{conn: conn} do
    admin = user!("admin")
    {:ok, view, _} = live(as_user(conn, admin), ~p"/control")
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    view
    |> form("#external-agent-form", external_agent: external_params("Relay bot"))
    |> render_change()

    demote!(admin)

    view
    |> form("#external-agent-form", external_agent: external_params("Relay bot"))
    |> render_submit()

    assert has_element?(
             view,
             ~s(#onboarding-overlay #sheet-refusal[role="alert"]),
             @create_refused_text
           )

    refute has_element?(view, "#flash-error")
    # The form is not rebuilt: what was typed is still in the fields.
    assert has_element?(
             view,
             ~s(#external-agent-form input[name="external_agent[name]"][value="Relay bot"])
           )

    assert has_element?(
             view,
             ~s(#external-agent-form input[name="external_agent[base_url]"][value="https://api.example.test/v1"])
           )

    refute Repo.get_by(Agent, slug: "relay-bot")
  end

  test "ownership: a refusal with the Add-to-Space modal open renders inside the modal", %{
    conn: conn
  } do
    owner = user!("member")
    other = user!("member")
    {agent, runtime} = federated_agent!(owner)
    {:ok, view, _} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")

    render_click(view, "show_add_space_modal", %{})
    assert has_element?(view, "#add-space-modal")

    # The agent changes hands while the modal is open: the next submit is an
    # ownership refusal on an agent this user no longer owns.
    runtime |> AgentRuntime.changeset(%{owner_user_id: other.id}) |> Repo.update!()
    space = Platform.Chat.list_spaces() |> Enum.find(&(&1.kind != "dm"))
    participants = participants(agent)

    render_submit(view, "add_agent_to_space", %{
      "space_id" => (space && space.id) || Ecto.UUID.generate(),
      "role" => "member"
    })

    assert has_element?(view, ~s(#add-space-modal #sheet-refusal[role="alert"]), @ownership)
    refute has_element?(view, "#flash-error")
    refute render(view) =~ @create_refused
    assert participants(agent) == participants
  end

  test "the Add-to-Space modal closes when another agent is selected", %{conn: conn} do
    owner = user!("member")
    {agent, _} = federated_agent!(owner)
    {other_agent, _} = federated_agent!(owner)
    {:ok, view, _} = live(as_user(conn, owner), ~p"/control/#{agent.slug}")

    render_click(view, "show_add_space_modal", %{})
    assert has_element?(view, "#add-space-modal")

    render_patch(view, ~p"/control/#{other_agent.slug}")
    refute has_element?(view, "#add-space-modal")
  end

  test "access_admin: a refusal with the grant panel open renders inside the panel", %{
    conn: conn
  } do
    owner = user!("member")
    admin = user!("admin")
    {agent, runtime} = federated_agent!(owner)
    {:ok, _} = RuntimeProfiles.set_tool_profile(runtime, ["prototype", "task"])
    {:ok, view, _} = live(as_user(conn, admin), ~p"/control/#{agent.slug}")

    render_hook(view, "open_grant_panel", %{
      "bundle" => "prototype",
      "permission" => "prototypes.publish"
    })

    assert has_element?(view, ~s([data-role="grant-panel"]))
    demote!(admin)

    render_change(view, "grant_path_change", %{"path" => "new"})

    assert has_element?(
             view,
             ~s([data-role="grant-panel"] #sheet-refusal[role="alert"]),
             "Only an org admin can grant this."
           )

    refute has_element?(view, "#flash-error")
  end

  test "admin: submit_external creates the agent and shows no refusal", %{conn: conn} do
    {:ok, view, _} = live(as_user(conn, root_admin!()), ~p"/control")
    render_click(view, "open_onboarding_chooser", %{})
    render_click(view, "choose_onboarding", %{"flow" => "external"})

    view
    |> form("#external-agent-form", external_agent: external_params("Admin Sheet"))
    |> render_submit()

    assert %Agent{kind: "external"} = Repo.get_by(Agent, slug: "admin-sheet")
    refute has_element?(view, "#sheet-refusal")
    refute render(view) =~ @create_refused
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

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  defp user!(role) do
    user = World.create_user!()
    World.plain_member!(user, Repo.get!(Org, acme_org_id()), role)
    user
  end

  defp demote!(user) do
    Repo.get_by!(OrgMembership, user_id: user.id, org_id: acme_org_id())
    |> Ecto.Changeset.change(role: "member")
    |> Repo.update!()
  end

  defp participants(agent) do
    import Ecto.Query

    Repo.aggregate(
      from(p in Platform.Chat.Participant, where: p.participant_id == ^agent.id),
      :count
    )
  end

  defp as_user(conn, user), do: Plug.Test.init_test_session(conn, current_user_id: user.id)

  defp federated_agent!(user) do
    n = System.unique_integer([:positive])
    {:ok, runtime} = Federation.register_runtime(user.id, %{runtime_id: "sheet-test-#{n}"})

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "sheet-test-#{n}",
        name: "Sheet Agent #{n}",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert()

    runtime = runtime |> AgentRuntime.changeset(%{agent_id: agent.id}) |> Repo.update!()
    {agent, runtime}
  end
end
