defmodule PlatformWeb.GoalsPageTest do
  @moduledoc """
  The goal page and the short read (task 01a1dfc1, Goals 4/8 stage 3),
  against canvas 01a15ef6 node `p` screens `goal`, `goal-es`, `goal-rd` and
  `read`. Every number is a REAL `goal_readings` row written through
  `Platform.Goals.log_reading/3` or `measure_goal/2`; nothing about how the
  number is read is stubbed. Sets the global `:goals, :enabled`, so not
  async.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.GoalsFixtures

  alias Platform.Goals

  setup do
    enable_goals!()
    org_id = org_id!()
    owner = member!(org_id)
    grant_goals_use!(owner, org_id)
    {:ok, org_id: org_id, owner: owner}
  end

  defp grant_goals_use!(user, org_id) do
    space = space!(org_id)

    {:ok, _} =
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space.id}
      })

    user
  end

  defp open(conn, user, query) do
    {:ok, view, _html} =
      live(Plug.Test.init_test_session(conn, current_user_id: user.id), "/m/goals?" <> query)

    find_live_child(view, "ext-page-goals")
  end

  defp page(conn, user, goal), do: open(conn, user, "goal=#{goal.id}")

  defp text(child, selector),
    do:
      child
      |> element(selector)
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> squash()

  defp squash(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp readings(user, goal) do
    {:ok, rows} = Goals.list_readings(user, goal.id)
    rows
  end

  test "workers section shows coach and contributors read-only, absent without coach", c do
    coach = agent!()
    x = agent!()
    y = agent!()
    manager = root_admin!()
    space = space!(c.org_id)
    for user <- [c.owner, manager], do: join_space!(space.id, :user, user.id)
    for agent <- [coach, x, y], do: join_space!(space.id, :agent, agent.id)
    goal = goal!(c.owner, c.org_id, %{coach_agent_id: coach.id, agent_mode: "do"})
    {:ok, _} = Goals.open_goal(c.owner, goal.id, {:space, space.id})
    {:ok, _} = Goals.hand_goal_to_space(manager, goal.id, space.id)
    viewer = enabled_user_for_workers!(member!(c.org_id), c.org_id)
    join_space!(space.id, :user, viewer.id)
    child = page(c.conn, viewer, goal)
    for copy <- ["Who's working on it", coach.name, "leads", x.name, y.name],
      do: assert(has_element?(child, "[data-role=goal-workers]", copy))
    refute has_element?(child, "[data-role=goal-workers] button")
    plain = goal!(c.owner, c.org_id)
    refute has_element?(page(c.conn, c.owner, plain), "[data-role=goal-workers]")
    assert PlatformWeb.GoalsWork.status("blocked") == "Blocked"
    assert PlatformWeb.GoalsWork.status("done") == "Done"
    assert PlatformWeb.GoalsWork.status("cancelled") == "Cancelled"
    assert PlatformWeb.GoalsWork.status("in_progress") == "Open"
  end

  defp enabled_user_for_workers!(user, org), do: grant_goals_use!(user, org)

  defp first(name), do: name |> String.split() |> hd()

  # The full fixture: three stops (one reached), two actions (one linked to
  # a takeaway), two takeaways, a theme with criteria, and one entry of each
  # other notebook kind.
  defp full_goal!(owner, org_id) do
    coach = agent!()

    goal =
      goal!(owner, org_id, %{
        title: "Grow How to Computer",
        why: "Plain-language computer help.",
        agent_mode: "do",
        source_key: "self_reported",
        unit: "subscribers",
        target_value: 1_000_000,
        rhythm: "weekly",
        rhythm_weekday: 1
      })

    {:ok, _} = Goals.update_goal(owner, goal.id, %{coach_agent_id: coach.id})

    {:ok, _} =
      Goals.put_stops(owner, goal.id, [
        %{label: "Start", target_value: 100, reached_on: ~D[2026-10-01]},
        %{
          label: "First 1,000",
          target_value: 1000,
          due_on: ~D[2026-12-01],
          theme: "learning",
          criteria: [
            %{"text" => "Try 4 kinds of video", "needed" => 4, "found" => 4},
            %{"text" => "Find 3 kinds that bring subscribers", "needed" => 3, "found" => 1}
          ]
        },
        %{label: "1 million", target_value: 1_000_000, caption: "the big one"}
      ])

    {:ok, short} =
      Goals.add_entry(coach, goal.id, %{
        kind: "takeaway",
        title: "Short videos bring in new viewers",
        body: "Channels that post shorts grow faster.",
        sources: [%{"name" => "Creator Academy"}, %{"name" => "A 2025 survey"}],
        details: %{"doing" => "Two shorts a week."}
      })

    {:ok, own} =
      Goals.add_entry(coach, goal.id, %{
        kind: "takeaway",
        title: "Viewers' own questions make the best topics",
        body: "Comment questions are ready-made videos.",
        sources: [%{"name" => "Help channel notes"}],
        details: %{"doing" => "A video per common question."}
      })

    {:ok, linked} =
      Goals.add_entry(coach, goal.id, %{
        kind: "action",
        title: "Short fixes under 6 minutes",
        body: "is editing a cache video",
        prediction: "People who watch them subscribe more.",
        takeaway_id: short.id
      })

    {:ok, plain} =
      Goals.add_entry(owner, goal.id, %{
        kind: "action",
        title: "Weekly livestreams",
        body: "One a week."
      })

    for {kind, title} <- [
          {"wake_up", "Morning check"},
          {"ask", "Which thumbnail?"},
          {"wait", "Waiting on edits"},
          {"retro", "October retro"}
        ] do
      {:ok, _} =
        Goals.add_entry(coach, goal.id, %{kind: kind, title: title, body: "#{title} body"})
    end

    %{goal: goal, coach: coach, short: short, own: own, linked: linked, plain: plain}
  end

  describe "the goal page inventory" do
    test "every built row for the full fixture", %{conn: conn, owner: owner, org_id: org_id} do
      f = full_goal!(owner, org_id)
      {:ok, _} = Goals.log_reading(owner, f.goal.id, %{value: 640})
      child = page(conn, owner, f.goal)

      # Back link (phone only: lg:hidden), title, why.
      assert has_element?(
               child,
               "a[data-role='goal-back'][href='/m/goals'].lg\\:hidden",
               "‹ Goals"
             )

      assert text(child, "[data-role='goal-title']") == "Grow How to Computer"
      assert text(child, "[data-role='goal-why']") == "Plain-language computer help."

      # Meta line: owner, coach in the agent's colour slot, source label.
      assert text(child, "[data-role='goal-meta']") ==
               "#{first(owner.name)}'s goal · #{f.coach.name} leads · Self-reported"

      assert has_element?(
               child,
               "[data-role='goal-meta'] [data-agent-slot][data-role='agent-name']"
             )

      assert has_element?(child, "[data-goals-slot='privacy']")

      # Journey: reached, current, upcoming; solid path after the reached stop.
      assert has_element?(child, "[data-role='goal-stop'][data-state='reached']", "Start")
      assert has_element?(child, "[data-role='goal-stop'][data-state='current']", "64%")
      assert has_element?(child, "[data-role='goal-stop'][data-state='current']", "by 1 Dec")
      assert has_element?(child, "[data-role='goal-stop'][data-state='upcoming']", "1M")
      assert has_element?(child, "[data-role='goal-stop'][data-state='upcoming']", "the big one")
      assert has_element?(child, "[data-role='goal-path'].border-solid")
      assert has_element?(child, "[data-role='goal-path'].border-dashed")

      assert String.starts_with?(
               text(child, "[data-role='goal-number']"),
               "640 of 1,000 subscribers. Self-reported."
             )

      assert has_element?(child, "[data-role='goal-pace']", "We'd hoped for about")

      assert has_element?(child, "[data-role='goal-progress'] i[style*='width: 64%']")

      # What we're trying.
      assert has_element?(child, "[data-role='goal-trying'] h3", "What we're trying · 2")

      assert has_element?(
               child,
               "[data-role='goal-trying-card'][data-entry-id='#{f.linked.id}']",
               "People who watch them subscribe more."
             )

      assert has_element?(
               child,
               "a[data-role='goal-trying-from'][href='/m/goals?goal=#{f.goal.id}&read=#{f.short.id}']",
               "From: Short videos bring in new viewers"
             )

      assert has_element?(child, "[data-role='goal-trying-doing']", "is editing a cache video")

      assert has_element?(
               child,
               "[data-role='goal-trying-doing'] [data-agent-slot]",
               f.coach.name
             )

      # The owner's plain action: body as the sentence, no From and no doing line.
      plain = "[data-role='goal-trying-card'][data-entry-id='#{f.plain.id}']"
      assert has_element?(child, plain, "One a week.")
      refute has_element?(child, plain <> " [data-role='goal-trying-from']")
      refute has_element?(child, plain <> " [data-role='goal-trying-doing']")

      # What we've learned.
      assert has_element?(child, "[data-role='goal-learned'] h3", "What we've learned")

      assert text(child, "[data-role='goal-learned-intro']") ==
               "From #{f.coach.name}'s research when the goal was set. Everything we try says which of these it came from."

      assert has_element?(
               child,
               "[data-role='goal-takeaway'][data-entry-id='#{f.short.id}']",
               "Sources: Creator Academy · A 2025 survey"
             )

      assert has_element?(
               child,
               "a[data-role='goal-read-more'][href='/m/goals?goal=#{f.goal.id}&read=all']",
               "Read more"
             )

      # This stop is about.
      assert has_element?(
               child,
               "[data-role='goal-stop-theme'] h3",
               "This stop is about learning"
             )

      assert has_element?(child, "[data-role='goal-criterion'][data-met='true']", "(done)")
      assert has_element?(child, "[data-role='goal-criterion'][data-met='false']", "(1 found)")

      # How we check in.
      assert text(child, "[data-role='goal-rhythm']") ==
               "Mondays, in your briefing. Nudges: gentle."

      assert text(child, "[data-role='goal-roles']") ==
               "#{f.coach.name} does the work and asks before anything goes public."

      # Notebook: every non-takeaway kind, with its tag, author and time.
      for {kind, tag} <- [
            {"wake_up", "Woke up"},
            {"action", "Did"},
            {"ask", "Asked"},
            {"wait", "Waiting"},
            {"retro", "Retro"}
          ] do
        assert has_element?(child, "[data-role='goal-notebook-entry'][data-kind='#{kind}']", tag)
      end

      refute has_element?(child, "[data-role='goal-notebook-entry'][data-kind='takeaway']")

      assert has_element?(
               child,
               "[data-role='goal-notebook-entry'][data-kind='retro']",
               f.coach.name
             )

      assert has_element?(
               child,
               "[data-role='goal-notebook-entry'][data-kind='retro']",
               "just now"
             )
    end

    test "copy for coach and advise modes, shared goals and other rhythms", %{
      conn: conn,
      owner: owner,
      org_id: org_id
    } do
      coach = agent!()

      practice =
        goal!(owner, org_id, %{
          agent_mode: "coach",
          rhythm: "daily",
          outreach: "pushy",
          source_key: "self_reported"
        })

      {:ok, _} = Goals.update_goal(owner, practice.id, %{coach_agent_id: coach.id})
      child = page(conn, owner, practice)
      assert text(child, "[data-role='goal-meta']") =~ "#{coach.name} coaches · Self-reported"

      assert text(child, "[data-role='goal-rhythm']") ==
               "Every day, in your briefing. Nudges: pushy."

      assert text(child, "[data-role='goal-roles']") ==
               "You practise. #{coach.name} plans and prepares."

      shared = goal!(owner, org_id, %{rhythm: "biweekly", rhythm_weekday: 4, outreach: "off"})
      {:ok, _} = Goals.update_goal(owner, shared.id, %{coach_agent_id: coach.id})
      {:ok, _} = Goals.open_goal(owner, shared.id, {:team, org_id})
      child = page(conn, owner, shared)

      assert text(child, "[data-role='goal-meta']") ==
               "Shared by #{first(owner.name)} and #{coach.name}"

      assert text(child, "[data-role='goal-rhythm']") ==
               "Every other Thursday, in your briefing. Nudges: off."

      assert text(child, "[data-role='goal-roles']") == "#{coach.name} advises. You do the work."

      alone = goal!(owner, org_id, %{rhythm: "weekdays"})
      child = page(conn, owner, alone)
      assert text(child, "[data-role='goal-meta']") == "#{first(owner.name)}'s goal"

      assert text(child, "[data-role='goal-rhythm']") ==
               "On weekdays, in your briefing. Nudges: gentle."

      refute has_element?(child, "[data-role='goal-roles']")
      refute has_element?(child, "[data-role='goal-journey']")
      refute has_element?(child, "[data-role='goal-trying']")
      refute has_element?(child, "[data-role='goal-learned']")
      refute has_element?(child, "[data-role='goal-stop-theme']")
      refute has_element?(child, "[data-role='goal-notebook']")
      assert text(child, "[data-role='goal-number']") == "No number to follow yet"
    end
  end

  describe "the number" do
    setup %{owner: owner, org_id: org_id} do
      goal =
        goal!(owner, org_id, %{source_key: "self_reported", unit: "words", target_value: 2000})

      {:ok, _} =
        Goals.put_stops(owner, goal.id, [
          %{label: "300 words", target_value: 300},
          %{label: "2,000"}
        ])

      %{goal: goal}
    end

    test "Target before a reading; value, 60% circle and 60% bar after one", %{
      conn: conn,
      owner: owner,
      goal: goal
    } do
      child = page(conn, owner, goal)
      assert text(child, "[data-role='goal-number']") == "Target: 300 words. Self-reported."
      refute has_element?(child, "[data-role='goal-progress']")
      assert text(child, "[data-role='goal-stop'][data-state='current'] div:first-child") == "300"

      {:ok, _} = Goals.log_reading(owner, goal.id, %{value: 180})
      child = page(conn, owner, goal)
      assert text(child, "[data-role='goal-number']") == "180 of 300 words. Self-reported."
      assert text(child, "[data-role='goal-stop'][data-state='current'] div:first-child") == "60%"
      assert has_element?(child, "[data-role='goal-progress'] i[style='width: 60%']")
    end

    test "the owner logs a value; a non-number shows Enter a number and writes nothing", %{
      conn: conn,
      owner: owner,
      goal: goal
    } do
      child = page(conn, owner, goal)
      assert has_element?(child, "[data-role='goal-log-submit']", "Log a value")

      child |> form("#goal-log-form", %{"value" => "195"}) |> render_submit()
      assert [%{value: value}] = readings(owner, goal)
      assert Decimal.equal?(value, 195)
      assert text(child, "[data-role='goal-number']") == "195 of 300 words. Self-reported."

      child |> form("#goal-log-form", %{"value" => "abc"}) |> render_submit()
      assert has_element?(child, "[data-role='goal-log-error']", "Enter a number")
      assert length(readings(owner, goal)) == 1
    end

    test "a viewer sees the number and no form; a crafted submit writes nothing", %{
      conn: conn,
      owner: owner,
      org_id: org_id,
      goal: goal
    } do
      viewer = grant_goals_use!(member!(org_id), org_id)
      {:ok, _} = Goals.open_goal(owner, goal.id, {:user, viewer.id})
      {:ok, _} = Goals.log_reading(owner, goal.id, %{value: 180})

      child = page(conn, viewer, goal)
      assert text(child, "[data-role='goal-number']") == "180 of 300 words. Self-reported."
      refute has_element?(child, "[data-role='goal-log-form']")

      render_hook(child, "log_value", %{"value" => "999"})
      assert length(readings(owner, goal)) == 1
      assert text(child, "[data-role='goal-number']") == "180 of 300 words. Self-reported."
    end

    test "a task-count goal: no form, a crafted submit writes nothing, and an archived project reads Target only",
         %{conn: conn, owner: owner, org_id: org_id} do
      project =
        Platform.Repo.insert!(%Platform.Tasks.Project{
          org_id: org_id,
          name: "Redesign",
          slug: "rd-#{unique()}"
        })

      for i <- 1..2,
          do:
            Platform.Repo.insert!(%Platform.Tasks.Task{
              project_id: project.id,
              title: "p#{i}",
              status: "backlog"
            })

      goal =
        goal!(owner, org_id, %{
          source_key: "task_count",
          source_settings: %{"project_id" => project.id, "count" => "open"},
          unit: "pieces",
          target_value: 24
        })

      {:ok, {:reading, _}} = Goals.measure_goal(owner, goal.id)
      child = page(conn, owner, goal)
      assert text(child, "[data-role='goal-number']") =~ "2 of 24 pieces."
      refute has_element?(child, "[data-role='goal-log-form']")

      render_hook(child, "log_value", %{"value" => "7"})
      assert length(readings(owner, goal)) == 1

      project |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Platform.Repo.update!()
      child = page(conn, owner, goal)
      number = text(child, "[data-role='goal-number']")
      assert String.starts_with?(number, "Target: 24 pieces.")
      refute number =~ ~r/\b2 of/
      refute has_element?(child, "[data-role='goal-progress']")
      assert length(readings(owner, goal)) == 1
    end

    test "no source: Target with no source text and no source in the meta line", %{
      conn: conn,
      owner: owner,
      org_id: org_id
    } do
      goal = goal!(owner, org_id, %{unit: "pages", target_value: 24})
      child = page(conn, owner, goal)
      assert text(child, "[data-role='goal-number']") == "Target: 24 pages."
      refute has_element?(child, "[data-role='goal-number-source']")
      refute has_element?(child, "[data-role='goal-meta-source']")
      refute has_element?(child, "[data-role='goal-log-form']")
    end
  end

  describe "the short read" do
    test "From: focuses its takeaway, Read more opens unfocused, backs return, the row is selected",
         %{conn: conn, owner: owner, org_id: org_id} do
      f = full_goal!(owner, org_id)

      child = open(conn, owner, "goal=#{f.goal.id}&read=#{f.short.id}")
      assert has_element?(child, "[data-role='goal-read'] h2", "What we've learned")
      assert has_element?(child, "[data-role='goal-read']", "Short read")
      assert has_element?(child, "[data-role='goal-read-by']", "Researched by #{f.coach.name}")

      assert has_element?(
               child,
               "[data-role='goal-read-card'][data-entry-id='#{f.short.id}'][data-focused='true']"
             )

      assert has_element?(
               child,
               "[data-role='goal-read-card'][data-entry-id='#{f.own.id}'][data-focused='false']"
             )

      assert has_element?(
               child,
               "[data-role='goal-read-card'][data-entry-id='#{f.short.id}'] [data-role='goal-read-doing']",
               "What we're doing about it: Two shorts a week."
             )

      assert has_element?(
               child,
               "[data-role='goal-read-card']",
               "Sources: Creator Academy · A 2025 survey"
             )

      assert has_element?(
               child,
               "a[data-role='goal-read-back'][href='/m/goals?goal=#{f.goal.id}']",
               "‹ Back"
             )

      assert has_element?(
               child,
               "[data-role='goals-row'][data-goal-id='#{f.goal.id}'][data-selected='true']"
             )

      for read <- ["all", "not-an-entry"] do
        child = open(conn, owner, "goal=#{f.goal.id}&read=#{read}")
        refute has_element?(child, "[data-role='goal-read-card'][data-focused='true']")
        assert has_element?(child, "[data-role='goal-read-card']")
      end

      # The page itself: selected row, back link to the list.
      child = page(conn, owner, f.goal)

      assert has_element?(
               child,
               "[data-role='goals-row'][data-goal-id='#{f.goal.id}'][data-selected='true']"
             )

      assert has_element?(child, "a[data-role='goal-back'][href='/m/goals']")
    end
  end
end
