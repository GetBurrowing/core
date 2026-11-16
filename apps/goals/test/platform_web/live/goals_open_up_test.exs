defmodule PlatformWeb.GoalsOpenUpTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures

  alias Platform.Goals

  setup do
    enable_goals!()
    org_id = org_id!()
    owner = enabled_user!(member!(org_id), org_id)
    viewer = enabled_user!(member!(org_id), org_id)
    %{org_id: org_id, owner: owner, viewer: viewer, goal: goal!(owner, org_id)}
  end

  defp enabled_user!(user, org_id) do
    space = space!(org_id)

    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space.id}
      })

    user
  end

  defp login(user),
    do: Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), current_user_id: user.id)

  defp open(user, path) do
    {:ok, parent, _} = live(login(user), path)
    find_live_child(parent, "ext-page-goals")
  end

  defp page(user, goal), do: open(user, "/m/goals?goal=#{goal.id}")
  defp event(view, name, args \\ %{}), do: render_hook(view, name, args)
  defp toggle(view, type, id), do: event(view, "toggle_audience", %{"type" => type, "id" => id})
  defp badge(view, label), do: assert(has_element?(view, "[data-role='privacy-badge']", label))
  defp row(goal), do: "[data-role='goals-row'][data-goal-id='#{goal.id}']"

  defp hidden(user, goal) do
    assert_error_sent(404, fn -> get(login(user), "/m/goals?goal=#{goal.id}") end)
    refute has_element?(open(user, "/m/goals"), row(goal))
  end

  test "space tick creates a card, a second tick closes it", c do
    space = space!(c.org_id)
    join_space!(space.id, :user, c.owner.id)
    view = page(c.owner, c.goal)
    event(view, "open_share")
    toggle(view, "space", space.id)
    assert [%{card_canvas_id: id}] = Platform.Repo.all(Platform.Goals.Grant)
    assert id
    assert Platform.Chat.get_canvas(id)
    toggle(view, "space", space.id)
    assert {:error, :not_found} = Goals.space_card(c.owner, id)
  end

  test "person sharing opens access, hides owner controls, and closing revokes access", c do
    hidden(c.viewer, c.goal)
    owner = page(c.owner, c.goal)
    badge(owner, "Only you")
    owner |> element("button", "Open up") |> render_click()
    assert has_element?(owner, "[data-role='share-sheet']", "Who can see this goal?")
    assert has_element?(owner, "[data-role='share-sheet']", "Only you can change the goal.")
    for tab <- ["People", "Team", "Space"], do: assert(has_element?(owner, "button", tab))
    toggle(owner, "user", c.viewer.id)
    assert Platform.Repo.aggregate(Platform.Chat.Canvas, :count) == 0
    badge(owner, "Shared: #{c.viewer.name}")
    assert has_element?(owner, "[data-role='share-sheet']", "Shared: #{c.viewer.name}")
    owner |> element("button", "Done") |> render_click()
    assert has_element?(owner, "button", "Change")
    assert has_element?(owner, "[role='status']", "Shared: #{c.viewer.name}")

    viewer = page(c.viewer, c.goal)
    badge(viewer, "Shared by #{c.owner.name}")

    for label <- ["Open up", "Change", "Edit", "Pause", "Finish"] do
      refute has_element?(viewer, "button", label)
    end

    assert has_element?(open(c.viewer, "/m/goals"), row(c.goal))
    event(owner, "open_share")
    toggle(owner, "user", c.viewer.id)
    badge(owner, "Only you")
    hidden(c.viewer, c.goal)
  end

  test "team sharing admits internal members only and can be revoked", c do
    external = enabled_user!(external_member!(c.org_id), c.org_id)
    other_org = org_id!()
    other = enabled_user!(member!(other_org), other_org)
    owner = page(c.owner, c.goal)
    event(owner, "open_share")
    event(owner, "share_tab", %{"tab" => "teams"})
    toggle(owner, "team", c.org_id)
    assert has_element?(page(c.viewer, c.goal), "[data-role='goal-title']")
    # Core rejects external users before the extension page mounts; both
    # existing and missing goal URLs get the same forbidden response.
    assert {:error, :not_found} = Goals.get_goal(external, c.goal.id)
    existing = get(login(external), "/m/goals?goal=#{c.goal.id}")
    missing = get(login(external), "/m/goals?goal=#{Ecto.UUID.generate()}")
    assert existing.status == 403
    assert missing.status == 403
    assert existing.resp_body == missing.resp_body
    refute existing.resp_body =~ c.goal.title
    hidden(other, c.goal)
    toggle(owner, "team", c.org_id)
    hidden(c.viewer, c.goal)
  end

  test "space sharing follows current participant rows", c do
    space = space!(c.org_id)
    join_space!(space.id, :user, c.owner.id)
    participant = join_space!(space.id, :user, c.viewer.id)
    owner = page(c.owner, c.goal)
    event(owner, "open_share")
    event(owner, "share_tab", %{"tab" => "spaces"})
    assert has_element?(owner, "[data-role='share-sheet']", "##{space.name}")
    toggle(owner, "space", space.id)
    assert has_element?(page(c.viewer, c.goal), "[data-role='goal-title']")
    leave_space!(participant)
    hidden(c.viewer, c.goal)
    toggle(owner, "space", space.id)
    assert {:ok, []} = Goals.list_audience(c.owner, c.goal.id)
  end

  test "a nonparticipant space is absent and a crafted tick cannot grant it", c do
    space = space!(c.org_id)
    owner = page(c.owner, c.goal)
    event(owner, "open_share")
    event(owner, "share_tab", %{"tab" => "spaces"})
    refute has_element?(owner, "[data-role='share-sheet']", space.name)
    toggle(owner, "space", space.id)
    assert {:ok, []} = Goals.list_audience(c.owner, c.goal.id)
    badge(owner, "Only you")
    assert has_element?(owner, "[role='status']", "That one can't be added")
  end

  test "viewer-crafted audience, settings and status events change nothing", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:user, c.viewer.id})
    {:ok, before} = Goals.get_goal(c.owner, c.goal.id)
    {:ok, grants} = Goals.list_audience(c.owner, c.goal.id)
    viewer = page(c.viewer, c.goal)
    event(viewer, "open_share")
    toggle(viewer, "team", c.org_id)
    toggle(viewer, "user", c.viewer.id)
    event(viewer, "open_settings")
    event(viewer, "settings_select", %{"field" => "rhythm", "value" => "daily"})

    event(viewer, "save_settings", %{
      "rhythm" => "daily",
      "outreach" => "off",
      "agent_mode" => "do"
    })

    for status <- ["paused", "finished"], do: event(viewer, "goal_status", %{"status" => status})
    assert {:ok, ^before} = Goals.get_goal(c.owner, c.goal.id)
    assert {:ok, ^grants} = Goals.list_audience(c.owner, c.goal.id)
    refute has_element?(viewer, "[data-role='share-sheet']")
    refute has_element?(viewer, "[data-role='settings-sheet']")
  end

  test "Done Undo restores a nonempty snapshot, and close keeps immediate changes", c do
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:team, c.org_id})
    {:ok, original} = Goals.list_audience(c.owner, c.goal.id)
    owner = page(c.owner, c.goal)
    event(owner, "open_share")
    toggle(owner, "team", c.org_id)
    assert has_element?(owner, "[data-role='share-sheet']", "Only you can see it")
    toggle(owner, "user", c.viewer.id)
    event(owner, "share_done")
    owner |> element("[role='status'] button", "Undo") |> render_click()
    {:ok, restored} = Goals.list_audience(c.owner, c.goal.id)

    assert Enum.map(restored, &{&1.audience_type, &1.org_id}) ==
             Enum.map(original, &{&1.audience_type, &1.org_id})

    event(owner, "open_share")
    toggle(owner, "user", c.viewer.id)
    event(owner, "close_share")
    refute has_element?(owner, "[data-role='share-sheet']")
    assert {:ok, grants} = Goals.list_audience(c.owner, c.goal.id)
    assert length(grants) == 2
  end

  test "settings save every rhythm, weekday, outreach and coach mode", c do
    coach = agent!()
    {:ok, _} = Goals.update_goal(c.owner, c.goal.id, %{coach_agent_id: coach.id})
    owner = page(c.owner, c.goal)

    for {rhythm, weekday, outreach, mode} <- [
          {"daily", nil, "off", "do"},
          {"weekdays", nil, "gentle", "advise"},
          {"weekly", 7, "pushy", "coach"},
          {"biweekly", 3, "off", "do"}
        ] do
      owner |> element("button", "Edit") |> render_click()
      assert has_element?(owner, "[data-role='settings-sheet']", "#{coach.name}'s part")

      for {field, value} <- [{"rhythm", rhythm}, {"outreach", outreach}, {"agent_mode", mode}] do
        owner
        |> element(
          "[data-role=settings-sheet] button[phx-value-field='#{field}'][value='#{value}']"
        )
        |> render_click()
      end

      if weekday,
        do:
          event(owner, "settings_select", %{
            "field" => "rhythm_weekday",
            "value" => to_string(weekday)
          })

      owner |> element("[data-role='settings-sheet'] button", "Save") |> render_click()
      {:ok, saved} = Goals.get_goal(c.owner, c.goal.id)
      assert saved.rhythm == rhythm
      assert saved.outreach == outreach
      assert saved.agent_mode == mode
      if weekday, do: assert(saved.rhythm_weekday == weekday)
      assert has_element?(owner, "[data-role='goal-rhythm']", "Nudges: #{outreach}.")
      refute has_element?(owner, "[data-role='settings-sheet']")
    end
  end

  test "settings without a coach omit the part group", c do
    owner = page(c.owner, c.goal)
    event(owner, "open_settings")
    assert has_element?(owner, "[data-role='settings-sheet']", "Check-in")
    assert has_element?(owner, "[data-role='settings-sheet']", "Nudges")
    refute has_element?(owner, "[data-role='settings-sheet']", "part")

    for label <- ["Every day", "Weekdays", "Weekly", "Every other week", "Off", "Gentle", "Pushy"] do
      assert has_element?(owner, "[data-role='settings-sheet'] button", label)
    end
  end

  test "pause, resume, finish and reopen update page and list; Undo restores active", c do
    owner = page(c.owner, c.goal)

    for {button, status, chip, next} <- [
          {"Pause", "paused", "Paused", "Resume"},
          {"Finish", "finished", "Finished", "Reopen"}
        ] do
      owner |> element("button", button) |> render_click()
      assert {:ok, %{status: ^status}} = Goals.get_goal(c.owner, c.goal.id)
      assert has_element?(owner, "[role='status']", "Goal #{status}")
      assert has_element?(owner, row(c.goal), chip)
      assert has_element?(open(c.owner, "/m/goals"), row(c.goal), chip)
      owner |> element("button", next) |> render_click()
      assert {:ok, %{status: "active"}} = Goals.get_goal(c.owner, c.goal.id)
      refute has_element?(owner, row(c.goal), chip)
    end

    event(owner, "goal_status", %{"status" => "paused"})
    owner |> element("[role='status'] button", "Undo") |> render_click()
    assert {:ok, %{status: "active"}} = Goals.get_goal(c.owner, c.goal.id)
  end

  test "all three empty tabs explain that there is nobody to add", c do
    # A retained owner goal and capability remain accessible after org membership ends.
    import Ecto.Query

    Platform.Repo.delete_all(
      from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^c.owner.id)
    )

    owner = page(c.owner, c.goal)
    event(owner, "open_share")

    for {tab, label} <- [
          {"people", "Nobody to add yet"},
          {"teams", "No teams to add yet"},
          {"spaces", "No spaces to add yet"}
        ] do
      event(owner, "share_tab", %{"tab" => tab})
      assert has_element?(owner, "[data-role='share-sheet']", label)
    end
  end

  test "agents channel alone has its distinct badge and option detail", c do
    previous = Application.fetch_env(:platform, :agents_goal_surface)
    Application.put_env(:platform, :agents_goal_surface, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :agents_goal_surface, value)
        :error -> Application.delete_env(:platform, :agents_goal_surface)
      end
    end)

    space = space!(c.org_id)
    {:ok, space} = Platform.Chat.update_space(space, %{goal: "Help the team ship"})
    join_space!(space.id, :user, c.owner.id)
    owner = page(c.owner, c.goal)
    event(owner, "open_share")
    event(owner, "share_tab", %{"tab" => "spaces"})
    assert has_element?(owner, "[data-role='share-sheet']", "Links the goal in ##{space.name}")
    toggle(owner, "space", space.id)
    badge(owner, "Shown in ##{space.name}")
    event(owner, "share_done")
    assert has_element?(owner, "[role='status']", "Shown in ##{space.name}")
  end

  defp private_snapshot(owner, goal) do
    {
      Goals.get_goal(owner, goal.id),
      Goals.list_audience(owner, goal.id),
      Goals.list_readings(owner, goal.id),
      Goals.list_stops(owner, goal.id),
      Goals.list_entries(owner, goal.id)
    }
  end

  test "private detail is masked from a permitted peer and root admin, including crafted list events",
       c do
    root = enabled_user!(root_admin!(), c.org_id)

    {:ok, goal} =
      Goals.update_goal(c.owner, c.goal.id, %{
        title: "Private launch plan",
        source_key: "self_reported",
        unit: "pages",
        target_value: 5000
      })

    {:ok, _} = Goals.log_reading(c.owner, goal.id, %{value: 4711})

    {:ok, _} =
      Goals.put_stops(c.owner, goal.id, [%{label: "Private checkpoint", target_value: 5000}])

    {:ok, _} =
      Goals.add_entry(c.owner, goal.id, %{
        kind: "action",
        title: "Private notebook action",
        body: "Private evidence"
      })

    before = private_snapshot(c.owner, goal)
    assert has_element?(page(c.owner, goal), "[data-role='goal-number']", "4,711")

    for actor <- [c.viewer, root] do
      responses =
        for query <- [
              "goal=#{goal.id}",
              "goal=#{goal.id}&read=all",
              "goal=#{Ecto.UUID.generate()}",
              "goal=malformed",
              "goal=malformed&read=all"
            ] do
          {404, _, body} =
            assert_error_sent(404, fn -> get(login(actor), "/m/goals?" <> query) end)

          for secret <- [
                goal.title,
                "Private checkpoint",
                "Private notebook action",
                "4711",
                "4,711"
              ] do
            refute body =~ secret
          end

          body
        end

      assert length(Enum.uniq(responses)) == 1
      list = open(actor, "/m/goals")

      for secret <- [
            goal.title,
            goal.id,
            "Private checkpoint",
            "Private notebook action",
            "4711",
            "4,711"
          ] do
        refute render(list) =~ secret
      end

      for {name, args} <- [
            {"open_share", %{}},
            {"toggle_audience", %{"type" => "user", "id" => actor.id}},
            {"share_done", %{}},
            {"close_share", %{}},
            {"undo", %{}},
            {"open_settings", %{}},
            {"settings_select", %{"field" => "rhythm", "value" => "daily"}},
            {"save_settings", %{"rhythm" => "daily", "outreach" => "off"}},
            {"goal_status", %{"status" => "paused"}},
            {"goal_status", %{"status" => "finished"}},
            {"log_value", %{"value" => "999"}}
          ] do
        event(list, name, Map.merge(args, %{"goal_id" => goal.id, "goal" => goal.id}))
        assert private_snapshot(c.owner, goal) == before
      end
    end
  end

  test "flag off masks list and detail and removes both rails even with goals.use", c do
    Application.put_env(:goals, :enabled, false)

    for actor <- [c.owner, c.viewer], path <- ["/m/goals", "/m/goals?goal=#{c.goal.id}"] do
      assert_error_sent(404, fn -> get(login(actor), path) end)
    end

    scope = Platform.Access.Scope.for_user(c.owner)

    for rows <- [
          PlatformWeb.Components.IconRail.desktop_more_rows(scope, false),
          PlatformWeb.Components.IconRail.more_sheet_rows(scope, false)
        ] do
      refute Enum.any?(rows, &(&1.key == :goals))
    end
  end

  test "permission gate denies both addresses even for an org-shared goal, and rails follow the grant",
       c do
    denied = member!(c.org_id)
    {:ok, _} = Goals.open_goal(c.owner, c.goal.id, {:team, c.org_id})
    # The context grants visibility, while the app still requires its module capability.
    assert {:ok, _} = Goals.get_goal(denied, c.goal.id)

    for path <- ["/m/goals", "/m/goals?goal=#{c.goal.id}"] do
      assert {:error, {:redirect, %{to: "/access-denied?module=goals"}}} =
               live(login(denied), path)
    end

    for {actor, expected} <- [{denied, false}, {c.owner, true}] do
      scope = Platform.Access.Scope.for_user(actor)

      for rows <- [
            PlatformWeb.Components.IconRail.desktop_more_rows(scope, false),
            PlatformWeb.Components.IconRail.more_sheet_rows(scope, false)
          ] do
        assert Enum.any?(rows, &(&1.key == :goals)) == expected
      end
    end

    assert has_element?(page(c.owner, c.goal), "[data-role='goal-title']")
  end
end
