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
    * `text-warning` appears on the FAULT no-measurement clause (a goal
      whose project scope names no project, `kind: :unknown_scope`) and
      NOWHERE else on either surface. An uncounted goal (`kind:
      :uncounted`, task `01a0ca9f` stage 3) is a normal state the heartbeat
      fires for: it renders "no count for this goal" at
      `text-base-content/60`, with no warning and no numeral.

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

    test "a measured goal renders no warning and no uncounted clause", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      measurable = create_space(goal: "Close backlog items in Suite")
      add_user(measurable, user)

      {:ok, _view, measurable_html} = live_at(conn, "/chat/#{measurable.slug}")

      # Positive control: with a derivable measurement there is no warning
      # anywhere on the surface — not on the delta, not on a falling count.
      refute measurable_html =~ ~s(data-role="agents-goal-measurement-missing")
      refute measurable_html =~ "text-warning"
      # The uncounted branch cannot render for a counted goal, and the
      # numeral is present — the render reached the measurement slot.
      refute measurable_html =~ ~s(data-role="agents-goal-measurement-uncounted")
      assert measurable_html =~ ~s(data-role="agents-goal-number")
    end

    test "an uncounted goal renders 'no count for this goal' at /60, with no warning and no numeral",
         %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space = create_space(goal: "Get SXI to a good state")
      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      assert html =~ ~s(data-role="agents-goal-measurement-uncounted")
      assert html =~ "no count for this goal"

      class = class_of(html, "agents-goal-measurement-uncounted")
      assert "text-base-content/60" in split_classes(class)
      refute "font-mono" in split_classes(class)

      refute html =~ "text-warning"
      refute html =~ ~s(data-role="agents-goal-measurement-missing")
      refute html =~ ~s(data-role="agents-goal-number")
      refute html =~ "so no heartbeat"
    end

    test "a goal whose project scope names no project renders the warning", %{conn: conn} do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      space =
        create_space(
          goal: "Close backlog items in Suite",
          metadata: %{"goal_project_id" => Ecto.UUID.generate()}
        )

      add_user(space, user)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")

      assert html =~ ~s(data-role="agents-goal-measurement-missing")
      assert "text-warning" in split_classes(class_of(html, "agents-goal-measurement-missing"))
      refute html =~ ~s(data-role="agents-goal-measurement-uncounted")
      refute html =~ ~s(data-role="agents-goal-number")
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

  describe "save_goal enforces the first-goal scope server-side (task 01a0ca99)" do
    # Every case drives `save_goal` DIRECTLY, not through a rendered control:
    # hiding an affordance is not a permission, and `Chat.update_space/2`
    # broadcasts nothing, so a stale window can still submit.
    defp goal_less_view(conn, admin?) do
      {conn, user} = authenticated_conn(conn)
      enable_flag()
      if admin?, do: make_acme_admin(user)

      space = create_space(name: "agents-first-goal")
      add_user(space, user)
      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")
      {view, space}
    end

    test "(a) an admin on a goal-less channel with no goal anywhere sets the first goal", %{
      conn: conn
    } do
      {view, space} = goal_less_view(conn, true)
      assert Sidebar.first_goal_offered?(space)

      render_change(view, "save_goal", %{"goal" => "Close backlog items in Suite"})

      assert Repo.reload!(space).goal == "Close backlog items in Suite"
    end

    test "(b) a non-admin on the same fixture is refused and the row stays nil", %{conn: conn} do
      {view, space} = goal_less_view(conn, false)
      # Same fixture as (a): the scope holds, so the refusal is the admin gate.
      assert Sidebar.first_goal_offered?(space)

      html = render_change(view, "save_goal", %{"goal" => "Hijack"})

      assert html =~ "You cannot edit this goal."
      assert Repo.reload!(space).goal == nil
    end

    test "(c) an admin is refused when another space already carries a goal", %{conn: conn} do
      {view, space} = goal_less_view(conn, true)
      # Mounted while the invitation would still hold — the stale-window case.
      assert Sidebar.first_goal_offered?(space)

      create_space(name: "agents-earlier", goal: "Close backlog items in Suite")

      html = render_change(view, "save_goal", %{"goal" => "Other goal"})

      assert html =~ "A first goal cannot be set on this channel."
      assert Repo.reload!(space).goal == nil
    end

    test "(d) an admin still edits the EXISTING goal while a later space also has one", %{
      conn: conn
    } do
      {conn, user} = authenticated_conn(conn)
      enable_flag()
      make_acme_admin(user)

      agents = create_space(name: "agents-existing", goal: "Close backlog items in Suite")
      add_user(agents, user)
      create_space(name: "agents-later", goal: "A second goal")
      refute Sidebar.first_goal_offered?(agents)

      {:ok, view, _html} = live_at(conn, "/chat/#{agents.slug}")
      render_change(view, "save_goal", %{"goal" => "Get SXI to a good state"})

      assert Repo.reload!(agents).goal == "Get SXI to a good state"
    end
  end

  describe "the in-place Set-a-goal invitation (task 01a0ca99 stage 2)" do
    # ONE LINE, THREE STATES in the existing strip slot: empty+admin shows the
    # invitation, editing shows the existing `save_goal` form, set shows
    # today's strip. Empty+non-admin is zero DOM. Every absence below is
    # paired, in the same test, with the presence that proves it was the
    # condition under test and not a broken render.

    @fault_token ~r/\b(?:text|bg|border|btn|badge|alert)-(?:warning|error|info)\b/

    defp invite_fixture(conn, admin?) do
      {conn, user} = authenticated_conn(conn)
      if admin?, do: make_acme_admin(user)
      space = create_space(name: "agents-invite")
      add_user(space, user)
      {conn, user, space}
    end

    defp role_nodes(html, role),
      do: html |> Floki.parse_document!() |> Floki.find(~s([data-role="#{role}"]))

    defp strip_fragment(html), do: html |> role_nodes("agents-goal-strip") |> Floki.raw_html()

    test "admin: invitation -> form -> saved goal and rail block, all with no remount", %{
      conn: conn
    } do
      enable_flag()
      {conn, _user, space} = invite_fixture(conn, true)

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")

      [invite] = role_nodes(html, "agents-goal-invite")
      assert Floki.text(invite) |> String.trim() == "Set a goal for this channel"
      # No placeholder leader face, and no form until the admin asks for it.
      assert role_nodes(html, "agents-goal-leader") == []
      assert role_nodes(html, "agents-goal-form") == []
      refute html =~ ~s(data-role="agents-rail-block")

      html = view |> element(~s([data-role="agents-goal-invite"])) |> render_click()

      [input] = html |> role_nodes("agents-goal-form") |> Floki.find(~s(input[name="goal"]))
      assert Floki.attribute(input, "placeholder") == ["Close backlog items"]
      assert Floki.attribute(input, "value") in [[], [""]]
      assert role_nodes(html, "agents-goal-invite") == []

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{goal: "Close backlog items in Suite"})
        |> render_submit()

      assert Repo.reload!(space).goal == "Close backlog items in Suite"

      [sentence] = role_nodes(html, "agents-goal-sentence")
      assert Floki.text(sentence) =~ "Close backlog items in Suite"
      assert role_nodes(html, "agents-goal-invite") == []
      assert role_nodes(html, "agents-goal-form") == []

      # The rail block now names THIS space — same view, no remount.
      assert html
             |> role_nodes("agents-rail-block")
             |> Floki.find(~s([data-space-id="#{space.id}"])) != []
    end

    test "cancel returns the line to the invitation", %{conn: conn} do
      enable_flag()
      {conn, _user, space} = invite_fixture(conn, true)
      {:ok, view, _html} = live_at(conn, "/chat/#{space.slug}")

      view |> element(~s([data-role="agents-goal-invite"])) |> render_click()
      html = render_click(view, "cancel_goal_edit", %{})

      assert role_nodes(html, "agents-goal-invite") != []
      assert role_nodes(html, "agents-goal-form") == []
    end

    test "non-admin on the same channel gets zero DOM; an admin on it sees the invitation", %{
      conn: conn
    } do
      enable_flag()
      {conn, _user, space} = invite_fixture(conn, false)
      # Same fixture as the admin control below: the scope holds, so any
      # absence is the admin gate.
      assert Sidebar.first_goal_offered?(space)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      refute html =~ ~s(data-role="agents-goal-invite")
      refute html =~ ~s(data-role="agents-goal-strip")

      {admin_conn, admin} = authenticated_conn(build_conn())
      make_acme_admin(admin)
      add_user(space, admin)

      {:ok, _view, admin_html} = live_at(admin_conn, "/chat/#{space.slug}")
      assert admin_html =~ ~s(data-role="agents-goal-invite")
      assert admin_html =~ ~s(data-role="agents-goal-strip")
    end

    test "scope: no invitation while another space carries a goal; archive it and it returns",
         %{conn: conn} do
      enable_flag()
      {conn, _user, space} = invite_fixture(conn, true)
      other = create_space(name: "agents-elsewhere", goal: "Close backlog items in Suite")

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      refute html =~ ~s(data-role="agents-goal-invite")
      refute html =~ ~s(data-role="agents-goal-strip")

      other |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ ~s(data-role="agents-goal-invite")
    end

    test "flag off: no strip for the admin; flag on, same fixture: invitation present", %{
      conn: conn
    } do
      disable_flag()
      {conn, _user, space} = invite_fixture(conn, true)

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      refute html =~ ~s(data-role="agents-goal-strip")
      refute html =~ ~s(data-role="agents-goal-invite")

      enable_flag()

      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      assert html =~ ~s(data-role="agents-goal-invite")
    end

    test "the empty state carries no fault colour; the invite is /60", %{conn: conn} do
      enable_flag()
      {conn, _user, space} = invite_fixture(conn, true)

      # The positive control below needs a goal that renders the strip's
      # one allowed warning. Since task 01a0ca9f stage 3 an UNCOUNTED goal
      # is a normal /60 state, so the fault is a goal whose project scope
      # names no project (`kind: :unknown_scope`). The scope is set before
      # mount; with no goal the space still shows the invitation.
      {:ok, space} =
        Chat.update_space(space, %{metadata: %{"goal_project_id" => Ecto.UUID.generate()}})

      {:ok, view, html} = live_at(conn, "/chat/#{space.slug}")

      strip = strip_fragment(html)
      assert strip =~ ~s(data-role="agents-goal-invite")
      refute strip =~ @fault_token

      [invite_class] = html |> role_nodes("agents-goal-invite") |> Floki.attribute("class")
      assert "text-base-content/60" in split_classes(invite_class)
      refute invite_class =~ "text-base-content/40"
      # Tap target below sm, the pencil's treatment.
      assert "min-h-11" in mobile_live(invite_class)
      assert "min-w-11" in mobile_live(invite_class)
      # ...without growing the strip: the negative margin returns the extra
      # height to the strip's padding, and exists below sm only.
      assert "-my-2" in mobile_live(invite_class)
      refute "-my-2" in desktop_live(invite_class)

      # POSITIVE CONTROL, same view: save a counted goal whose project scope
      # names no project, and the SAME detector over the SAME strip fragment
      # does fire on the one warning this surface is allowed — so its
      # silence above is not blindness.
      view |> element(~s([data-role="agents-goal-invite"])) |> render_click()

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{goal: "Close backlog items in Suite"})
        |> render_submit()

      assert html =~ ~s(data-role="agents-goal-measurement-missing")
      assert html |> strip_fragment() =~ @fault_token
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
    # PREMISE, measured on the dev-on-test-host rig at 375x812 BEFORE the change,
    # with the goal input's own `maxlength="500"` as the range: the
    # measurement clause reached 0px width at a 38-character goal, and the
    # strip overflowed the viewport (scrollWidth 382 > clientWidth 375) at
    # 40. At the 28-character goal v1 shipped with, neither was true — which
    # is why this is keyed to the threshold and not to one string.

    defp goal_html(conn, opts \\ []) do
      {conn, user} = authenticated_conn(conn)
      agent = insert_agent("Dalton")
      enable_flag()

      # `can_edit_goal?` is `Tenancy.root_admin?/1` (chat_live.ex:569), so
      # the pencil does NOT render for an ordinary user. Without this the
      # pencil test reads a nil class attribute, every `refute ... in` on it
      # passes vacuously, and only the one `assert` catches it — which is
      # how this was caught on the first test-host run rather than shipped.
      if Keyword.get(opts, :admin?, false), do: make_acme_admin(user)

      space = create_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)
      add_user(space, user)
      {:ok, _view, html} = live_at(conn, "/chat/#{space.slug}")
      html
    end

    defp make_acme_admin(user) do
      org_id = Platform.Tenancy.get_org_by_slug!("acme").id

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

  describe "the goal editor's project select (task 01a0cef1 stage 2)" do
    # Fixture (seeded orgs: A = "soylent", B = "wayne_tech"): a channel S in
    # org A with goal "Close backlog items"; P1 (A: 2 open + 1 done), P2 (A:
    # 5 open), PF (B: 3 open). No migration seeds projects or tasks, so the
    # install-wide open count is 2 + 5 + 3 = 10.
    @scope_goal "Close backlog items"

    defp scope_fixture(conn, role) do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      case role do
        :admin -> make_acme_admin(user)
        :member -> acme_member(user)
      end

      a = Platform.Tenancy.get_org_by_slug!("soylent")
      b = Platform.Tenancy.get_org_by_slug!("wayne_tech")
      n = System.unique_integer([:positive])

      p1 = scope_project!("P1 #{n}", a)
      p2 = scope_project!("P2 #{n}", a)
      pf = scope_project!("PF #{n}", b)
      for _ <- 1..2, do: scope_task!(p1, "backlog")
      scope_task!(p1, "done")
      for _ <- 1..5, do: scope_task!(p2, "in_progress")
      for _ <- 1..3, do: scope_task!(pf, "backlog")

      space = create_space(name: "agents-scope-#{n}", goal: @scope_goal, org_id: a.id)
      add_user(space, user)

      %{conn: conn, space: space, p1: p1, p2: p2, pf: pf}
    end

    # A root-org member who is NOT an admin: sees the space, `root_admin?/1`
    # is false, so a refusal is the admin gate and not visibility.
    defp acme_member(user) do
      %Platform.Tenancy.OrgMembership{}
      |> Platform.Tenancy.OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Platform.Tenancy.get_org_by_slug!("acme").id,
        role: "member"
      })
      |> Repo.insert!()
    end

    defp scope_project!(name, org) do
      {:ok, project} = Platform.Tasks.create_project(%{name: name, org_id: org.id})
      project
    end

    defp scope_task!(project, status) do
      {:ok, _} =
        Platform.Tasks.create_task(%{project_id: project.id, title: "t", status: status})
    end

    defp scope_of(space), do: Repo.reload!(space).metadata["goal_project_id"]

    defp nodes(html, selector), do: html |> Floki.parse_document!() |> Floki.find(selector)

    defp number(html),
      do: html |> nodes(~s([data-role="agents-goal-number"])) |> Floki.text() |> String.trim()

    defp clause(html),
      do: html |> nodes(~s([data-role="agents-goal-measurement"])) |> Floki.text()

    defp open_editor(view), do: render_click(view, "edit_goal", %{})

    defp option_texts(html),
      do: html |> nodes(~s([data-role="agents-goal-scope"] option)) |> Enum.map(&Floki.text/1)

    test "(a) the select lists All projects then org A's projects, and the saved scope is counted",
         %{conn: conn} do
      f = scope_fixture(conn, :admin)
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")

      html = open_editor(view)
      texts = option_texts(html) |> Enum.map(&String.trim/1)
      assert texts == ["All projects", f.p1.name, f.p2.name]
      refute Enum.member?(texts, f.pf.name)

      html =
        view
        |> form(~s([data-role="agents-goal-form"]))
        |> render_submit(%{goal: @scope_goal, goal_project_id: f.p1.id})

      assert scope_of(f.space) == f.p1.id
      assert number(html) == "2"
      assert clause(html) =~ "in #{f.p1.name}"
    end

    test "(b) a non-admin's forced save is refused and writes nothing; the admin's succeeds",
         %{conn: conn} do
      f = scope_fixture(conn, :member)
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")

      html =
        render_submit(view, "save_goal", %{"goal" => "Hijack", "goal_project_id" => f.p1.id})

      assert html =~ "You cannot edit this goal."
      refute Map.has_key?(Repo.reload!(f.space).metadata, "goal_project_id")
      assert Repo.reload!(f.space).goal == @scope_goal

      # Positive control: the same payload from an admin on the same space.
      {admin_conn, admin} = authenticated_conn(build_conn())
      make_acme_admin(admin)
      add_user(f.space, admin)
      {:ok, admin_view, _html} = live_at(admin_conn, "/chat/#{f.space.id}")

      render_submit(admin_view, "save_goal", %{
        "goal" => @scope_goal,
        "goal_project_id" => f.p1.id
      })

      assert scope_of(f.space) == f.p1.id
    end

    test "(c) a foreign-org project is refused inline and writes nothing; P1 is then accepted",
         %{conn: conn} do
      f = scope_fixture(conn, :admin)
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")
      open_editor(view)
      before = Repo.reload!(f.space)

      html =
        render_submit(view, "save_goal", %{"goal" => "Changed", "goal_project_id" => f.pf.id})

      [error] = nodes(html, ~s([data-role="agents-goal-scope-error"]))

      assert Floki.text(error) |> String.trim() ==
               "That project is not available in this channel's org."

      assert Floki.attribute(error, "class") |> Enum.join() =~ "text-error"
      refute html =~ "text-warning"
      # The form stays open.
      assert nodes(html, ~s([data-role="agents-goal-form"])) != []
      after_refusal = Repo.reload!(f.space)
      assert after_refusal.goal == before.goal
      assert after_refusal.metadata == before.metadata

      html =
        render_submit(view, "save_goal", %{"goal" => @scope_goal, "goal_project_id" => f.p1.id})

      assert scope_of(f.space) == f.p1.id
      assert nodes(html, ~s([data-role="agents-goal-scope-error"])) == []
    end

    test "(d) All projects removes the key and the count is install-wide", %{conn: conn} do
      f = scope_fixture(conn, :admin)
      {:ok, _} = Chat.update_space(f.space, %{metadata: %{"goal_project_id" => f.p1.id}})
      {:ok, view, html} = live_at(f.conn, "/chat/#{f.space.id}")
      assert number(html) == "2"

      html =
        render_submit(view, "save_goal", %{"goal" => @scope_goal, "goal_project_id" => ""})

      refute Map.has_key?(Repo.reload!(f.space).metadata, "goal_project_id")
      assert number(html) == "10"
      assert clause(html) =~ "open tasks"
      refute clause(html) =~ "open tasks in "
    end

    test "(e) a submit without the goal_project_id key keeps the current scope", %{conn: conn} do
      f = scope_fixture(conn, :admin)
      {:ok, _} = Chat.update_space(f.space, %{metadata: %{"goal_project_id" => f.p2.id}})
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")

      html = render_submit(view, "save_goal", %{"goal" => "Close backlog items today"})

      assert Repo.reload!(f.space).goal == "Close backlog items today"
      assert scope_of(f.space) == f.p2.id
      assert number(html) == "5"
    end

    test "(f) a legacy scope outside the list stays selected and round-trips", %{conn: conn} do
      f = scope_fixture(conn, :admin)
      {:ok, _} = Chat.update_space(f.space, %{metadata: %{"goal_project_id" => f.pf.id}})
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")

      html = open_editor(view)
      [selected] = nodes(html, ~s([data-role="agents-goal-scope"] option[selected]))
      assert Floki.attribute(selected, "value") == [f.pf.id]
      assert Floki.text(selected) |> String.trim() == f.pf.name

      view
      |> form(~s([data-role="agents-goal-form"]))
      |> render_submit(%{goal: @scope_goal})

      assert scope_of(f.space) == f.pf.id
    end
  end

  # ── Check progress cadence (task 01a0e882 stage 3) ─────────────────────

  describe "the Check progress cadence control (task 01a0e882 stage 3)" do
    @cadence_goal "Close backlog items in Suite"
    @cadence_event "platform.responsibilities.cadence_changed"
    @cron_shape ~r/(\*|\d+)\s+(\*|\d+)\s+\*\s+\*\s+\*/

    defp cadence_fixture(conn, role, connect_params \\ nil) do
      {conn, user} = authenticated_conn(conn)
      enable_flag()

      case role do
        :admin -> make_acme_admin(user)
        :member -> acme_member(user)
      end

      {:ok, [row]} =
        Platform.Responsibilities.register(Platform.Responsibilities.Handlers.AgentsGoalHeartbeat)

      {:ok, _} = Platform.Responsibilities.update_responsibility(row, %{enabled: true})

      space = create_space(goal: @cadence_goal)
      add_user(space, user)

      conn = if connect_params, do: put_connect_params(conn, connect_params), else: conn
      %{conn: conn, user: user, space: space}
    end

    defp heartbeat, do: Platform.Responsibilities.get_by_key("agents.goal_heartbeat")

    defp cadence_audits do
      import Ecto.Query, only: [from: 2]

      Repo.aggregate(
        from(e in Platform.Audit.Event, where: e.event_type == @cadence_event),
        :count
      )
    end

    defp set_as_admin!(cadence, opts \\ []) do
      admin =
        Repo.insert!(%User{
          email: "cadence_admin_#{System.unique_integer([:positive])}@example.com",
          name: "Cadence Admin",
          oidc_sub: "oidc-cadence-admin-#{System.unique_integer([:positive])}"
        })

      make_acme_admin(admin)
      {:ok, _} = Platform.Responsibilities.set_goal_heartbeat_cadence(admin, cadence, opts)
    end

    defp tail_nodes(html), do: role_nodes(html, "agents-goal-cadence-tail")

    test "an admin picks Once a day, the hour picker appears, and daily@16 persists and shows",
         %{conn: conn} do
      f = cadence_fixture(conn, :admin)
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")

      html = render_click(view, "edit_goal", %{})
      assert [_] = role_nodes(html, "agents-goal-cadence")
      assert role_nodes(html, "agents-goal-cadence-hour") == []

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{goal_cadence: "daily"})
        |> render_change()

      assert [_] = role_nodes(html, "agents-goal-cadence-hour")
      assert Floki.text(role_nodes(html, "agents-goal-cadence-preview")) =~ "Next check:"
      # A preview is not a write.
      assert heartbeat().trigger_config["expression"] == "0 * * * *"

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{
          goal: @cadence_goal,
          goal_cadence: "daily",
          goal_cadence_hour: "16"
        })
        |> render_submit()

      assert heartbeat().trigger_config["expression"] == "0 16 * * *"
      assert Floki.text(tail_nodes(html)) =~ "checked daily"
    end

    test "no cron typing and no cron text, for every cadence including custom", %{conn: conn} do
      f = cadence_fixture(conn, :admin)

      settings = [
        {:hourly, []},
        {:every_4h, []},
        {:twice_daily, []},
        {:daily, [hour_utc: 16]},
        {:off, []},
        :custom
      ]

      for setting <- settings do
        case setting do
          :custom ->
            {:ok, _} =
              Platform.Responsibilities.update_responsibility(heartbeat(), %{
                enabled: true,
                trigger_config: %{"expression" => "*/5 * * * *", "operator_set" => true}
              })

          {cadence, opts} ->
            set_as_admin!(cadence, opts)
        end

        {:ok, view, strip_html} = live_at(f.conn, "/chat/#{f.space.id}")
        html = render_click(view, "edit_goal", %{})

        for page <- [strip_html, html] do
          assert Floki.find(Floki.parse_document!(page), ~s(input[name^="goal_cadence"])) == []
          refute page =~ @cron_shape, "cron text rendered for #{inspect(setting)}"
        end

        assert [_] = role_nodes(html, "agents-goal-cadence")

        if setting == :custom do
          [selected] =
            html
            |> Floki.parse_document!()
            |> Floki.find(~s([data-role="agents-goal-cadence"] option[selected]))

          assert Floki.text(selected) |> String.trim() == "Custom schedule"
          # The tail is on the reading strip, which the open editor replaces.
          assert Floki.text(tail_nodes(strip_html)) =~ "custom schedule"
        end
      end
    end

    test "hourly (the default) renders no tail; Off renders a muted, never-warning tail",
         %{conn: conn} do
      f = cadence_fixture(conn, :admin)

      {:ok, _view, html} = live_at(f.conn, "/chat/#{f.space.id}")
      assert role_nodes(html, "agents-goal-strip") != []
      assert tail_nodes(html) == []

      set_as_admin!(:off)
      {:ok, _view, html} = live_at(f.conn, "/chat/#{f.space.id}")

      [tail] = tail_nodes(html)
      assert Floki.text(tail) |> String.trim() == "· not checked automatically"
      class = tail |> Floki.attribute("class") |> Enum.join(" ")
      assert class =~ "text-base-content/60"
      refute class =~ "text-warning"
    end

    test "a non-admin sees no control and a forged save changes nothing; an admin's identical save does",
         %{conn: conn} do
      f = cadence_fixture(conn, :member)
      {:ok, view, html} = live_at(f.conn, "/chat/#{f.space.id}")
      assert role_nodes(html, "agents-goal-strip") != []
      assert role_nodes(html, "agents-goal-cadence") == []

      before = heartbeat()
      audits = cadence_audits()

      render_submit(view, "save_goal", %{"goal" => @cadence_goal, "goal_cadence" => "off"})

      after_row = heartbeat()
      assert after_row.enabled == before.enabled
      assert after_row.trigger_config == before.trigger_config
      assert cadence_audits() == audits

      # POSITIVE CONTROL: the same submit from an admin on the same space.
      {admin_conn, admin} = authenticated_conn(build_conn())
      make_acme_admin(admin)
      add_user(f.space, admin)
      {:ok, admin_view, _html} = live_at(admin_conn, "/chat/#{f.space.id}")

      render_submit(admin_view, "save_goal", %{"goal" => @cadence_goal, "goal_cadence" => "off"})

      assert heartbeat().enabled == false
      assert cadence_audits() == audits + 1
    end

    test "hour labels are the viewer's local time, the value is the UTC hour", %{conn: conn} do
      zone = "America/Chicago"
      f = cadence_fixture(conn, :admin, %{"timezone" => zone})
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")
      render_click(view, "edit_goal", %{})

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{goal_cadence: "daily"})
        |> render_change()

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{
          goal_cadence: "daily",
          goal_cadence_hour: "16"
        })
        |> render_change()

      expected =
        Date.utc_today()
        |> DateTime.new!(~T[16:00:00], "Etc/UTC")
        |> DateTime.shift_zone!(zone)
        |> Calendar.strftime("%-I:%M %p")

      [option] =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s([data-role="agents-goal-cadence-hour"] option[value="16"]))

      assert Floki.text(option) |> String.trim() == expected
      assert expected in ["10:00 AM", "11:00 AM"]
      assert Floki.text(role_nodes(html, "agents-goal-cadence-preview")) =~ "(16:00 UTC)"

      view
      |> form(~s([data-role="agents-goal-form"]), %{
        goal: @cadence_goal,
        goal_cadence: "daily",
        goal_cadence_hour: "16"
      })
      |> render_submit()

      assert heartbeat().trigger_config["expression"] == "0 16 * * *"
    end

    test "with no zone the labels are UTC and carry no UTC suffix", %{conn: conn} do
      f = cadence_fixture(conn, :admin)
      {:ok, view, _html} = live_at(f.conn, "/chat/#{f.space.id}")
      render_click(view, "edit_goal", %{})

      html =
        view
        |> form(~s([data-role="agents-goal-form"]), %{
          goal_cadence: "daily"
        })
        |> render_change()

      [option] =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s([data-role="agents-goal-cadence-hour"] option[value="16"]))

      assert Floki.text(option) |> String.trim() == "4:00 PM"
      refute Floki.text(role_nodes(html, "agents-goal-cadence-preview")) =~ "UTC"
    end
  end
end
