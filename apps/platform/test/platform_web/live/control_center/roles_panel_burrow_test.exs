defmodule PlatformWeb.ControlCenter.RolesPanelBurrowTest do
  @moduledoc """
  Roles panel grouped by holder (task 01a1b741 stage 4): "Held by Burrow",
  the one-step "Hand to a specialist" control, Clear handing a role back to
  Burrow, and the "Ask Burrow about splitting roles" link.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.{Agent, Burrow}
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.Role

  # Verbatim from the design canvas roles table. Written out here, NOT read
  # from `Roles.plain_line/1`, so a drift in the single copy goes red.
  @canvas_lines %{
    "historian" =>
      "Keeps the team's long-term memory: daily summaries, decisions from meetings, and people profiles.",
    "meeting_scribe" =>
      "Takes notes in meetings, writes the summary and action items, and follows up afterward.",
    "meeting_producer" =>
      "Listens to live meetings and passes each request to the agent best placed to handle it.",
    "triage_officer" =>
      "Keeps the task list in order: sorts new tasks, unblocks stuck ones, takes in outside feedback, and writes a weekly review.",
    "designer" =>
      "Reviews visual design, writes design direction for new work, and checks it against the brand.",
    "security_guard" =>
      "Scans regularly for vulnerable dependencies, risky code, drifted deploy settings, and leaked secrets.",
    "architect" =>
      "Reviews plans and code changes so work across tasks fits together, with a weekly check for drift.",
    "agents_leader" => "Owns the agents space's goal and checks progress against it every day.",
    "scientist" => "Runs experiments on how the platform makes decisions and reads the results.",
    "janitor" =>
      "Clears small internal chores once a week, including fixes the Architect's weekly sweep turns up."
  }

  @ten ~w(designer historian meeting_scribe meeting_producer triage_officer security_guard architect agents_leader scientist janitor)

  defp owner!, do: Platform.TenancyFixtures.root_admin!()

  defp create_agent(name) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "roles-panel-#{System.unique_integer([:positive, :monotonic])}",
        name: name,
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  defp doc(html), do: LazyHTML.from_document(html)
  defp q(html, sel), do: html |> doc() |> LazyHTML.query(sel) |> Enum.to_list()
  defp squish(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp row_keys(html, section_id) do
    html
    |> q("##{section_id} li[data-role-key]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-role-key"))
    |> Enum.sort()
  end

  defp open_panel(conn, user) do
    {:ok, view, html} = live(init_test_session(conn, current_user_id: user.id), ~p"/control")
    {view, html}
  end

  # The whole panel's markup, from the default (non-advanced) view.
  defp panel_html(html), do: html |> q("#roles-panel") |> hd() |> LazyHTML.to_html()

  describe "with Burrow holding every role" do
    setup do
      previous_token = Application.get_env(:platform, :agent_host_token)
      Application.put_env(:platform, :agent_host_token, "test-host-token")

      on_exit(fn ->
        if previous_token,
          do: Application.put_env(:platform, :agent_host_token, previous_token),
          else: Application.delete_env(:platform, :agent_host_token)
      end)

      for key <- Role.valid_keys(), do: :ok = Roles.unassign_role(key)
      owner = owner!()
      {:ok, burrow} = Burrow.ensure(owner.id, "claude_code")
      for key <- Role.valid_keys(), do: assert(Roles.agent_id_for_role(key) == burrow.id)

      %{owner: owner, burrow: burrow}
    end

    test "fresh install: all 10 rows under Held by Burrow, nothing reads as unfinished",
         %{conn: conn, owner: owner} do
      {_view, html} = open_panel(conn, owner)

      # Floor: the 10 literal keys, so a shrunken roster cannot pass vacuously.
      assert Enum.sort(Role.valid_keys()) == Enum.sort(@ten)
      assert row_keys(html, "roles-held-by-burrow") == Enum.sort(@ten)
      assert [header] = q(html, ~s(#roles-held-by-burrow h3 [data-role="group-label"]))
      assert squish(header) == "Held by Burrow"
      assert q(html, "#roles-held-by-specialists") == []
      assert q(html, "#roles-not-held") == []

      panel = panel_html(html)
      refute panel =~ "UNFILLED"
      refute panel =~ "hero-exclamation-triangle"
      refute panel =~ "warning"
      refute panel =~ ~r/runs —|last —|avg —|\$\/run —/
      refute panel =~ ~r/\b\d+ of \d+\b/
      refute panel =~ ~r/missing|incomplete|unfilled/i

      # Every Burrow row offers the handover picker and never Clear.
      for key <- @ten do
        assert [_picker] =
                 q(html, ~s(#role-row-#{key} [data-role="hand-to-specialist-picker"]))

        assert q(html, ~s(#role-row-#{key} [data-role="clear-role-btn"])) == []
      end

      assert [option] = q(html, ~s(#role-row-designer select option[value=""]))
      assert squish(option) == "Hand to a specialist"
    end

    test "subtitle and the Why add a specialist? note carry the canvas copy",
         %{conn: conn, owner: owner} do
      {_view, html} = open_panel(conn, owner)

      assert [subtitle] = q(html, ~s([data-role="roles-subtitle"]))

      assert squish(subtitle) ==
               "Each role is a set of recurring work. One agent holds each role."

      assert [note] = q(html, "#roles-specialist-note")
      text = squish(note)
      assert text =~ "Why add a specialist?"

      assert text =~
               "Burrow holds every role, so all of this work runs from day one. You can hand any role to a dedicated agent when it suits you. A specialist:"

      bullets = note |> LazyHTML.query("li") |> Enum.map(&squish/1)

      assert bullets == [
               "can run a different model or tools",
               "keeps its context on one kind of work",
               "works at the same time as Burrow"
             ]

      assert [link] = q(html, "#roles-specialist-note #ask-burrow-about-roles")
      assert squish(link) == "Ask Burrow about splitting roles"
      # Exactly one note, above the list, not per row.
      assert length(q(html, "#roles-specialist-note")) == 1
      assert q(html, "li[data-role-key] #roles-specialist-note") == []
    end

    test "each row leads with its role icon and never an empty bordered box",
         %{conn: conn, owner: owner} do
      {_view, html} = open_panel(conn, owner)
      roles = Map.new(Roles.list_roles(), &{&1.key, &1})

      for key <- @ten do
        assert [slot] = q(html, ~s(#role-row-#{key} [data-role="role-leading-slot"]))
        slot_html = LazyHTML.to_html(slot)
        assert "hero-" <> _ = roles[key].icon
        assert slot_html =~ roles[key].icon
        assert slot_html =~ "text-primary"
        refute slot_html =~ "border"

        # Nothing checkbox-like anywhere in the row.
        assert q(html, ~s(#role-row-#{key} input[type="checkbox"])) == []

        for child <- LazyHTML.query(slot, "*") do
          refute LazyHTML.attribute(child, "class") |> Enum.join(" ") =~ "border"
        end
      end
    end

    test "every seeded role icon is in the panel source, so Tailwind builds its CSS" do
      source = File.read!("lib/platform_web/live/control_center/roles_panel.ex")

      for role <- Roles.list_roles() do
        assert source =~ ~r/\b#{Regex.escape(role.icon)}\b/,
               "#{role.icon} (#{role.key}) is not in roles_panel.ex, so it paints blank"
      end
    end

    test "each row's plain line is the canvas copy, and bundle keys show two plus +N",
         %{conn: conn, owner: owner} do
      {_view, html} = open_panel(conn, owner)

      for key <- @ten do
        assert [line] = q(html, ~s(#role-row-#{key} [data-role="role-plain-line"]))
        assert squish(line) == @canvas_lines[key], "plain line for #{key}"

        bundle = Roles.bundle_for(key)

        case q(html, ~s(#role-row-#{key} [data-role="role-bundle-keys"])) do
          [] ->
            assert bundle == []

          [keys] ->
            {shown, rest} = Enum.split(bundle, 2)
            expected = Enum.join(shown, " · ")
            expected = if rest == [], do: expected, else: expected <> " · +#{length(rest)}"
            assert squish(keys) == expected
        end
      end
    end

    test "hand_role moves designer to the specialist in one step; Clear hands it back",
         %{conn: conn, owner: owner, burrow: burrow} do
      sam = create_agent("Sam-agent")
      {view, html} = open_panel(conn, owner)

      # Burrow is never offered as a specialist.
      options =
        html
        |> q(~s(#role-row-designer [data-role="hand-to-specialist-picker"] option))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

      assert sam.id in options
      refute burrow.id in options

      html =
        view
        |> element(~s(#role-row-designer form[data-role="handover-control"]))
        |> render_change(%{"role_key" => "designer", "agent_id" => sam.id})

      assert Roles.agent_id_for_role("designer") == sam.id
      refute "designer" in Enum.map(Roles.roles_for(burrow.id), & &1.key)
      assert html =~ "Handed Designer to Sam-agent."
      refute html =~ "clear it before reassigning"

      assert row_keys(html, "roles-held-by-specialists") == ["designer"]
      refute "designer" in row_keys(html, "roles-held-by-burrow")
      assert [header] = q(html, ~s(#roles-held-by-specialists h3 [data-role="group-label"]))
      assert squish(header) == "Held by specialists"
      assert [holder] = q(html, ~s(#role-row-designer [data-role="specialist-holder"]))
      assert squish(holder) =~ "Sam-agent"
      assert [_clear] = q(html, ~s(#role-row-designer [data-role="clear-role-btn"]))
      assert q(html, ~s(#role-row-designer [data-role="hand-to-specialist-picker"])) == []

      html =
        view
        |> element(~s(#role-row-designer [data-role="clear-role-btn"]))
        |> render_click()

      assert Roles.agent_id_for_role("designer") == burrow.id
      assert html =~ "Designer is back with Burrow."
      assert "designer" in row_keys(html, "roles-held-by-burrow")
      assert q(html, "#roles-held-by-specialists") == []
    end

    test "Ask Burrow opens Burrow's DM with the composer pre-filled and sends nothing",
         %{conn: conn, owner: owner, burrow: burrow} do
      {view, _html} = open_panel(conn, owner)

      {path, _flash} =
        view
        |> element("#ask-burrow-about-roles")
        |> render_click()
        |> follow_redirect_path()

      %URI{path: "/chat/" <> segment, query: query} = URI.parse(path)

      assert URI.decode_query(query)["draft"] ==
               "Why might I split some of your roles off, and how would I do it?"

      space =
        Platform.Chat.get_space(segment) ||
          Platform.Chat.get_space_by_slug(segment)

      assert space.kind == "dm"

      assert {:ok, dm} = Platform.Chat.find_or_create_dm(owner.id, "agent", burrow.id)
      assert dm.id == space.id

      {:ok, _chat, chat_html} =
        live(init_test_session(build_conn(), current_user_id: owner.id), path)

      assert [field] = q(chat_html, ~s(textarea[name="compose[text]"]))

      assert squish(field) ==
               "Why might I split some of your roles off, and how would I do it?"

      assert Platform.Chat.list_messages(space.id) == []
    end

    defp follow_redirect_path({:error, {:live_redirect, %{to: to} = opts}}),
      do: {to, Map.get(opts, :flash)}

    defp follow_redirect_path({:error, {:redirect, %{to: to} = opts}}),
      do: {to, Map.get(opts, :flash)}
  end

  describe "with no Burrow" do
    setup do
      for key <- Role.valid_keys(), do: :ok = Roles.unassign_role(key)
      :ok
    end

    test "an unheld role shows a plain picker, no UNFILLED badge and no warning hue",
         %{conn: conn} do
      _alex = create_agent("Alex-agent")
      {_view, html} = open_panel(conn, owner!())

      assert row_keys(html, "roles-not-held") == Enum.sort(@ten)
      assert q(html, "#roles-specialist-note") == []

      panel = panel_html(html)
      refute panel =~ "UNFILLED"
      refute panel =~ "hero-exclamation-triangle"
      refute panel =~ "warning"
      refute panel =~ ~r/missing|incomplete|unfilled/i
      assert [_ | _] = q(html, ~s(#role-row-designer [data-role="fill-role-picker"]))
    end

    test "Clear with no Burrow unassigns", %{conn: conn} do
      alex = create_agent("Alex-agent")
      {:ok, _} = Roles.assign_role("designer", alex.id)
      {view, _html} = open_panel(conn, owner!())

      html =
        view
        |> element(~s(#role-row-designer [data-role="clear-role-btn"]))
        |> render_click()

      assert Roles.agent_id_for_role("designer") == nil
      assert html =~ "Cleared assignment for designer"
      assert "designer" in row_keys(html, "roles-not-held")
    end
  end
end
