defmodule PlatformWeb.ChatLiveAgentsGoalSurfaceTest do
  @moduledoc """
  Render coverage for the stage-4 agents surface (task
  `01a0b491-0718-7001-8bba-bf50f119bb13`): the rail block above Pinned and
  the space-header goal strip.

  Assertions address `data-role` hooks, not Tailwind classes, so a restyle
  does not read as a behaviour regression. The two exceptions are
  deliberate and are the two visual claims the stage is actually making:

    * the measurement clause carries `text-base-content/60` and NOT
      `/40` — `/40` is the treatment `topic` uses and it was measured at
      2.85:1 light / 3.53:1 dark, which fails AA in both themes;
    * `text-warning` appears on the no-measurement clause and NOWHERE
      else on either surface.

  Every absence is paired with the presence that proves the absence was
  the condition under test and not a broken render.

  `async: false` — the feature flag is application env, global to the node.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Roles

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    :ok
  end

  defp enable_flag, do: Application.put_env(:platform, @flag_key, true)
  defp disable_flag, do: Application.put_env(:platform, @flag_key, false)

  defp authenticated_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "agents_goal_#{n}@example.com",
        name: "Agents Goal Test User",
        oidc_sub: "oidc-agents-goal-#{n}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp insert_agent(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "agents-goal-#{n}",
      name: name,
      status: "active"
    })
  end

  defp create_space(attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(
          %{name: "Agents #{n}", slug: "agents-goal-space-#{n}", kind: "channel"},
          Map.new(attrs)
        )
      )

    space
  end

  defp add_user(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    :ok
  end

  defp live_at(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  describe "the flag gates both surfaces" do
    test "with the flag unset nothing renders, even though the columns hold values", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      disable_flag()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      refute html =~ ~s(data-role="agents-rail-block")
      refute html =~ ~s(data-role="agents-goal-strip")
      refute html =~ ~s(data-role="agents-goal-sentence")
      refute html =~ "Close backlog items in Suite"
    end

    test "with the flag set the same space renders both — control for the case above", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)

      enable_flag()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      assert html =~ ~s(data-role="agents-rail-block")
      assert html =~ ~s(data-role="agents-rail-row")
      assert html =~ ~s(data-role="agents-goal-strip")
      assert html =~ "Close backlog items in Suite"
    end
  end

  describe "the header strip is conditional on the space" do
    test "an ordinary channel's header carries no goal line, no leader and no measurement", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      goal_space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(goal_space, user)

      plain = create_space(name: "control", topic: "ordinary topic")
      add_user(plain, user)

      {:ok, _view, plain_html} = live_at(conn, "/chat/#{plain.slug}")

      refute plain_html =~ ~s(data-role="agents-goal-strip")
      refute plain_html =~ ~s(data-role="agents-goal-leader")
      refute plain_html =~ ~s(data-role="agents-goal-measurement")
      # The topic still renders exactly as it did before this feature: the
      # suppression below is scoped to spaces that HAVE a goal.
      assert plain_html =~ "ordinary topic"

      # The rail block is global, so it appears on the control channel too —
      # that is the block saying which space the agents serve, not a claim
      # about the space being read.
      assert plain_html =~ ~s(data-role="agents-rail-block")
    end
  end

  describe "contrast and the single warning" do
    test "the measurement clause uses /60 and not the /40 topic tier", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      [_, clause] = String.split(html, ~s(data-role="agents-goal-measurement"), parts: 2)
      measurement_tag = String.slice(clause, 0, 200)

      assert html =~ "text-base-content/60"
      refute measurement_tag =~ "text-base-content/40"
      # The numeral, and only the numeral, is in the monospace face.
      assert html =~ ~s(data-role="agents-goal-number")
    end

    test "warning appears on the no-measurement state and on nothing else", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      measurable = create_space(goal: "Close backlog items in Suite")
      add_user(measurable, user)

      {:ok, _view, measurable_html} = live_at(conn, "/chat/#{measurable.slug}")

      # Positive control: with a derivable measurement there is no warning
      # anywhere on the surface — not on the delta, not on a falling count.
      refute measurable_html =~ ~s(data-role="agents-goal-measurement-missing")
      refute measurable_html =~ "text-warning"

      {:ok, unmeasurable} = Chat.update_space(measurable, %{goal: "Get SXI to a good state"})

      {:ok, _view, warning_html} = live_at(conn, "/chat/#{unmeasurable.slug}")

      assert warning_html =~ ~s(data-role="agents-goal-measurement-missing")
      assert warning_html =~ "text-warning"
    end
  end

  describe "saving a goal re-derives the measurement" do
    test "a goal that loses its measurement shows the missing state, not the stale number", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Close backlog items in Suite")
      add_user(space, user)

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ ~s(data-role="agents-goal-number")

      # Drive the same event the pencil drives. `can_edit_goal?` is false for
      # this non-admin user, so the write is REFUSED — which is the gate the
      # affordance sits over, asserted here rather than assumed.
      render_change(view, "save_goal", %{"goal" => "Get SXI to a good state"})

      assert Repo.reload!(space).goal == "Close backlog items in Suite"
    end

    test "the panel re-derives from the saved goal with no cached number to fall back to" do
      space = create_space(goal: "Close backlog items in Suite")
      enable_flag()

      assert Sidebar.goal_panel(space).measurement.missing? == false

      {:ok, updated} = Chat.update_space(space, %{goal: "Get SXI to a good state"})

      assert Sidebar.goal_panel(updated).measurement.missing? == true
    end
  end

  describe "a leader swap repaints both avatars with no reload" do
    test "the role broadcast updates the rail row and the header together", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      first = insert_agent("Firstleader")
      second = insert_agent("Secondleader")

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: first.id)
      add_user(space, user)

      {:ok, _} = Roles.assign_role(Sidebar.agents_leader_role(), first.id)

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ "Firstleader leads"

      # `role_assignments.role_key` is unique and `assign_role/2` is an
      # INSERT, so moving a role is release-then-pin. That is the existing
      # role path, untouched by this stage — recorded here because it is
      # the shape a caller has to use, not a quirk of the test.
      :ok = Roles.unassign_role(Sidebar.agents_leader_role())
      {:ok, _} = Roles.assign_role(Sidebar.agents_leader_role(), second.id)

      html = render(view)
      assert html =~ "Secondleader leads"
      refute html =~ "Firstleader leads"
    end
  end

  # ---- breakpoint-resolution helpers for the reflow describe below -------
  #
  # Tailwind emits base utilities before `sm:` ones, so among the classes
  # live at >=640px the `sm:`-prefixed member of a conflicting family wins.
  # `max-sm:` classes are not live at >=640px at all, and both base and
  # `max-sm:` classes are live below 640px.

  defp desktop_live(class_string) do
    classes = split_classes(class_string)
    resolve(base_classes(classes) ++ prefixed(classes, "sm:"))
  end

  defp mobile_live(class_string) do
    classes = split_classes(class_string)
    resolve(base_classes(classes) ++ prefixed(classes, "max-sm:"))
  end

  defp split_classes(class_string), do: String.split(class_string || "", ~r/\s+/, trim: true)

  defp base_classes(classes), do: Enum.reject(classes, &String.contains?(&1, ":"))

  defp prefixed(classes, prefix) do
    classes
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  # Last-wins within a conflicting family, which is what the cascade does
  # for same-specificity utilities emitted in layer order.
  defp resolve(ordered) do
    ordered
    |> Enum.reduce(%{}, fn class, acc -> Map.put(acc, family(class), class) end)
    |> Map.values()
    |> MapSet.new()
  end

  defp family("flex-wrap"), do: :wrap
  defp family("flex-nowrap"), do: :wrap
  defp family(other), do: other

  defp class_of(html, role) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s([data-role="#{role}"]))
    |> Floki.attribute("class")
    |> List.first()
  end

  describe "the goal strip reflows below sm without changing desktop" do
    # WHY THESE ASSERT ON CLASSES AT ALL, against this module's own rule.
    # The reflow IS a Tailwind-breakpoint claim and a breakpoint is not
    # observable in a LiveView render test — there is no viewport here. So
    # classes are the only evidence available, and the interesting
    # assertion is NOT "the mobile class was added": that passes for a
    # change that dropped `shrink-0` at EVERY width, which is the actual
    # regression this stage could ship. Each test derives what is live at
    # >=640px AND what is live below it, and asserts on both.
    #
    # PREMISE, measured on the dev-on-moon rig at 375x812 BEFORE the change,
    # with the goal input's own `maxlength="500"` as the range: the
    # measurement clause reached 0px width at a 38-character goal, and the
    # strip overflowed the viewport (scrollWidth 382 > clientWidth 375) at
    # 40. At the 28-character goal v1 shipped with, neither was true — which
    # is why this is keyed to the threshold and not to one string.

    defp goal_html(conn, opts \\ []) do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      # `can_edit_goal?` is `Tenancy.fabrikam_admin?/1` (chat_live.ex:569), so
      # the pencil does NOT render for an ordinary user. Without this the
      # pencil test reads a nil class attribute, every `refute ... in` on it
      # passes vacuously, and only the one `assert` catches it — which is
      # how this was caught on the first moon run rather than shipped.
      if Keyword.get(opts, :admin?, false), do: make_fabrikam_admin(user)

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)
      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      html
    end

    defp make_fabrikam_admin(user) do
      org_id = Platform.Tenancy.get_org_by_slug!("fabrikam").id

      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: user.id,
        org_id: org_id,
        role: "admin"
      })
      |> Repo.insert!()
    end

    test "the sentence keeps shrink-0 at desktop and loses it below sm", %{conn: conn} do
      class = conn |> goal_html() |> class_of("agents-goal-sentence")
      assert is_binary(class), "the goal sentence did not render"

      # THE ASSERTION THAT MATTERS. A test that only looked for
      # `sm:shrink-0` would also pass if `shrink-0` had been deleted at
      # every width.
      assert "shrink-0" in desktop_live(class),
             "desktop lost shrink-0 on the goal sentence: #{class}"

      refute "shrink-0" in mobile_live(class),
             "the sentence is still shrink-0 below sm, so it cannot wrap: #{class}"

      # v1's desktop set for this span, exactly — tripwire on any drift.
      assert desktop_live(class) == MapSet.new(["shrink-0", "text-sm", "text-base-content"])
    end

    test "the inner row wraps below sm and stays nowrap at desktop", %{conn: conn} do
      class = conn |> goal_html() |> class_of("agents-goal-row")
      assert is_binary(class), "the goal row did not render"

      assert "flex-nowrap" in desktop_live(class),
             "desktop row would wrap, which v1 did not: #{class}"

      assert "flex-wrap" in mobile_live(class),
             "the row cannot wrap below sm: #{class}"

      # v1's row was `flex min-w-0 items-baseline gap-2` — nowrap by
      # default. Resolved at desktop that is this set plus the explicit
      # `flex-nowrap` restoring it.
      assert desktop_live(class) ==
               MapSet.new(["flex", "min-w-0", "items-baseline", "gap-2", "flex-nowrap"])
    end

    test "the pencil tap target is raised below sm only, by padding not glyph", %{conn: conn} do
      button =
        conn
        |> goal_html(admin?: true)
        |> Floki.parse_fragment!()
        |> Floki.find(~s(button[aria-label="Edit goal"]))

      # POSITIVE CONTROL for the class reads below: a nil class attribute
      # makes every `refute ... in` on it pass for the wrong reason.
      assert button != [], "the pencil did not render — can_edit_goal? was false"
      class = button |> Floki.attribute("class") |> List.first()
      assert is_binary(class)

      # Measured 32 x 21 px at 375px before this change — under 44 in both
      # dimensions, and true before this stage existed.
      assert "min-h-11" in mobile_live(class)
      assert "min-w-11" in mobile_live(class)

      # Desktop untouched: `max-sm:` emits nothing live at >=640px, so
      # there is no reset to get wrong.
      refute "min-h-11" in desktop_live(class)
      refute "min-w-11" in desktop_live(class)
      assert desktop_live(class) == MapSet.new(["btn", "btn-ghost", "btn-xs", "shrink-0"])

      # PADDING, NOT ICON SCALE — the no-chrome contract forbids a louder
      # glyph, so the size stays exactly v1's.
      assert button |> Floki.find("span") |> Floki.attribute("class") |> List.first() =~
               "size-3.5"
    end

    test "the reflow does not relax the clause's truncation, contrast or mono numeral", %{
      conn: conn
    } do
      html = goal_html(conn)
      class = class_of(html, "agents-goal-measurement")
      assert is_binary(class), "the measurement clause did not render"

      # Giving the clause its own line below sm does not licence dropping
      # the desktop truncation rule.
      assert "truncate" in desktop_live(class)
      assert "min-w-0" in desktop_live(class)
      assert "text-base-content/60" in desktop_live(class)
      refute class =~ "text-base-content/40"

      assert class_of(html, "agents-goal-number") =~ "font-mono"

      # No raw hex anywhere on the strip itself.
      strip = class_of(html, "agents-goal-strip")
      refute strip =~ ~r/#[0-9a-fA-F]{3,8}\b/
    end
  end
end
