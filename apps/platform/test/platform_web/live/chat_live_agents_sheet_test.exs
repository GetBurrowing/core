defmodule PlatformWeb.ChatLiveAgentsSheetTest do
  @moduledoc """
  Render + event coverage for the Agents sheet (task 01a1557a-8f80 stage 2),
  which replaces the header agent eye.

  The sheet writes through the stage-1 writers in `Platform.Chat`: the master
  switch (`chat_spaces.agents_awake`), the attention policy
  (`chat_spaces.agent_attention_policy`) and per-agent silence
  (`chat_participants.silenced`). Stored values are asserted through `Repo`,
  not through the rendered state, so a sheet that merely looks right cannot
  pass.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Repo

  @sheet "#agents-sheet"
  @popover "#agents-popover"

  defp insert_user(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "agents_sheet_#{tag}_#{n}@example.com",
      name: "Agents Sheet #{tag}",
      oidc_sub: "oidc-agents-sheet-#{tag}-#{n}"
    })
  end

  defp insert_agent(name, color) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "agents-sheet-#{n}",
      name: name,
      color: color,
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp create_space(kind) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Agents Sheet #{n}",
        slug: "agents-sheet-#{kind}-#{n}",
        kind: kind
      })

    space
  end

  defp add_user(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp add_agent(space, name, color \\ "teal") do
    agent = insert_agent(name, color)

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp live_at(conn, user, space) do
    conn = init_test_session(conn, current_user_id: user.id)

    case live(conn, ~p"/chat/#{space.slug}") do
      {:error, {:live_redirect, %{to: redirect}}} -> live(conn, redirect)
      ok -> ok
    end
  end

  # A channel with a member and three agents (Ada teal, Bo amber, Cy purple),
  # Bo silenced.
  defp seeded(conn, kind \\ "channel") do
    user = insert_user("member")
    space = create_space(kind)
    add_user(space, user)
    ada = add_agent(space, "Ada", "teal")
    bo = add_agent(space, "Bo", "amber")
    cy = add_agent(space, "Cy", "purple")
    {:ok, _} = Chat.set_agent_silenced({:user, user.id}, space.id, bo.id, true)
    {:ok, view, _html} = live_at(conn, user, space)
    %{user: user, space: space, view: view, ada: ada, bo: bo, cy: cy}
  end

  defp open_agents(view), do: view |> element("[data-role='agents-open']") |> render_click()

  defp row(view, surface, participant) do
    view
    |> element("#{surface} [data-role='agent-row'][data-participant-id='#{participant.id}']")
    |> render()
  end

  defp silenced?(participant), do: Repo.get!(Participant, participant.id).silenced

  describe "opening" do
    test "the header entry opens the phone sheet and the desktop popover with every inventory string",
         %{conn: conn} do
      %{view: view} = seeded(conn)

      button = view |> element("[data-role='agents-open']") |> render()
      assert button =~ ~s(aria-label="Agents")
      assert button =~ ~s(aria-haspopup="dialog")
      assert button =~ "min-h-11 min-w-11"
      assert button =~ "hero-cpu-chip"
      assert button =~ "2/3 awake"

      refute has_element?(view, "#{@sheet}.sheet-open")
      refute has_element?(view, @popover)

      open_agents(view)

      assert has_element?(view, "#{@sheet}.sheet-open[data-swipe-dismiss='true']")
      assert has_element?(view, "#{@sheet} button.sheet-handle-button[aria-label='Close']")
      assert has_element?(view, "#{@sheet} p[aria-hidden='true']", "Agents in this space")
      assert has_element?(view, "#{@sheet} h2#agents-sheet-title", "Agents in this space")
      assert has_element?(view, "#{@popover}[phx-click-away='agents_close'][phx-key='Escape']")

      for surface <- [@sheet, @popover] do
        body = view |> element(surface) |> render()

        for copy <- [
              "Agents in this space",
              "Agents awake",
              "arm / clear all agents",
              "Attention policy",
              "On-mention",
              "reply only when @mentioned",
              "Directed",
              "reply only when a human directs them",
              "Collaborative",
              "may join in",
              "current",
              "Ada",
              "Bo",
              "Cy",
              "awake",
              "silenced",
              ~s(aria-label="Agents awake, on"),
              ~s(aria-label="Ada, awake"),
              ~s(aria-label="Bo, silenced"),
              ~s(role="radiogroup"),
              ~s(aria-label="Attention policy")
            ] do
          assert body =~ copy, "#{surface} lacks #{inspect(copy)}"
        end

        # Masters' order: On-mention, Directed, Collaborative.
        assert Regex.scan(~r/data-policy="([a-z_]+)"/, body) |> Enum.map(&List.last/1) ==
                 ["on_mention", "directed", "collaborative"]

        # Agents alphabetical.
        names = Regex.scan(~r/aria-label="(\w+), (?:awake|silenced)"/, body)
        assert Enum.map(names, &List.last/1) == ["Ada", "Bo", "Cy"]
      end
    end

    test "agents_close shuts both surfaces", %{conn: conn} do
      %{view: view} = seeded(conn)
      open_agents(view)
      render_hook(view, "agents_close", %{})
      refute has_element?(view, "#{@sheet}.sheet-open")
      refute has_element?(view, @popover)
    end

    test "an awake row carries its slot accent; the silenced row withholds it", %{conn: conn} do
      %{view: view, ada: ada, bo: bo} = seeded(conn)
      open_agents(view)

      ada_row = row(view, @sheet, ada)
      assert ada_row =~ ~s(data-agent-slot="teal")
      assert ada_row =~ "border-(--ag)"
      assert ada_row =~ "text-(--ag-text)"
      assert ada_row =~ ~s(data-state="awake")

      bo_row = row(view, @sheet, bo)
      assert bo_row =~ ~s(data-state="silenced")
      refute bo_row =~ "data-agent-slot"
      refute bo_row =~ "--ag"
      assert bo_row =~ "border-subtle"
      assert bo_row =~ "text-subtle"
    end
  end

  describe "per-agent switch" do
    test "toggling an agent silences it in the database and drops its accent", %{conn: conn} do
      %{view: view, ada: ada} = seeded(conn)
      open_agents(view)

      html =
        view
        |> element(
          "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{ada.id}']"
        )
        |> render_click()

      assert silenced?(ada)
      assert html =~ "Ada silenced"

      ada_row = row(view, @sheet, ada)
      assert ada_row =~ ~s(data-state="silenced")
      assert ada_row =~ ~s(aria-label="Ada, silenced")
      refute ada_row =~ "data-agent-slot"
      refute ada_row =~ "--ag"

      html =
        view
        |> element(
          "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{ada.id}']"
        )
        |> render_click()

      refute silenced?(ada)
      assert html =~ "Ada awake"
      assert row(view, @sheet, ada) =~ ~s(data-agent-slot="teal")
    end

    test "a forged toggle with another space's agent changes nothing", %{conn: conn} do
      %{view: view, user: user, space: space} = seeded(conn)
      # The viewer is a member of the other space too, so only the space id
      # taken from the socket (never from params) stops this write.
      other = create_space("channel")
      add_user(other, user)
      foreign = add_agent(other, "Foreign")

      html =
        render_hook(view, "agent_silence_toggle", %{
          "participant_id" => foreign.id,
          "space_id" => other.id
        })

      refute silenced?(foreign)
      assert html =~ "Could not change that"
      assert Repo.get!(Space, space.id).agents_awake
    end
  end

  describe "master switch" do
    test "off pauses every row without rewriting a per-agent value; on restores each row exactly",
         %{conn: conn} do
      %{view: view, space: space, ada: ada, bo: bo, cy: cy} = seeded(conn)
      open_agents(view)
      before = Enum.map([ada, bo, cy], &row(view, @sheet, &1))

      html = view |> element("#{@sheet} [data-role='agents-awake-switch']") |> render_click()

      assert html =~ "Agents cleared"
      refute Repo.get!(Space, space.id).agents_awake
      assert {silenced?(ada), silenced?(bo), silenced?(cy)} == {false, true, false}
      assert view |> element("[data-role='agents-open']") |> render() =~ "0/3 awake"

      assert has_element?(
               view,
               "#{@sheet} [data-role='agents-awake-switch'][aria-label='Agents awake, off']"
             )

      for p <- [ada, bo, cy] do
        r = row(view, @sheet, p)
        assert r =~ "Paused for this space"
        assert r =~ ~s(data-state="paused")
        refute r =~ "--ag"

        assert has_element?(
                 view,
                 "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{p.id}'][disabled]"
               )
      end

      # The disabled switch still shows the stored value.
      assert has_element?(
               view,
               "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{ada.id}'][checked]"
             )

      refute has_element?(
               view,
               "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{bo.id}'][checked]"
             )

      html = view |> element("#{@sheet} [data-role='agents-awake-switch']") |> render_click()

      assert html =~ "Agents armed"
      assert Repo.get!(Space, space.id).agents_awake
      assert {silenced?(ada), silenced?(bo), silenced?(cy)} == {false, true, false}
      assert Enum.map([ada, bo, cy], &row(view, @sheet, &1)) == before
    end

    test "on arms the sole awake agent and never a silenced one", %{conn: conn} do
      user = insert_user("arm")
      space = create_space("channel")
      add_user(space, user)
      lead = add_agent(space, "Lead")
      quiet = add_agent(space, "Quiet")
      {:ok, _} = Chat.set_agent_silenced({:user, user.id}, space.id, quiet.id, true)
      {:ok, _} = Chat.set_agents_awake({:user, user.id}, space.id, false)
      {:ok, view, _} = live_at(conn, user, space)
      open_agents(view)

      view |> element("#{@sheet} [data-role='agents-awake-switch']") |> render_click()

      assert ActiveAgentStore.get_active(space.id) == lead.id
    end
  end

  describe "attention policy" do
    test "agent_policy_set persists and the row shows 'current'", %{conn: conn} do
      %{view: view, space: space} = seeded(conn)
      open_agents(view)

      html =
        view
        |> element("#{@sheet} [data-role='agent-policy-row'][data-policy='collaborative'] input")
        |> render_click()

      assert html =~ "Policy: collaborative"
      assert Repo.get!(Space, space.id).agent_attention_policy == "collaborative"

      assert has_element?(
               view,
               "#{@sheet} [data-policy='collaborative'] [data-role='agent-policy-current']"
             )

      refute has_element?(
               view,
               "#{@sheet} [data-policy='on_mention'] [data-role='agent-policy-current']"
             )

      assert has_element?(view, "#{@sheet} [data-policy='collaborative'] input[checked]")
    end

    test "the radio is a base-content radio, never primary", %{conn: conn} do
      %{view: view} = seeded(conn)
      open_agents(view)

      radios =
        view |> element("#{@sheet} [data-role='agent-policy-group']") |> render()

      assert radios =~ ~s(class="radio radio-sm border-subtle text-base-content")
      refute radios =~ "primary"
    end

    test "an execution space hides the policy rows", %{conn: conn} do
      %{view: view} = seeded(conn, "execution")
      open_agents(view)
      assert has_element?(view, "#{@sheet} [data-role='agents-awake-switch']")
      refute has_element?(view, "#{@sheet} [data-role='agent-policy-group']")
      refute render(view) =~ "Attention policy"
    end
  end

  describe "live refresh" do
    test "another member's LiveView re-renders on the broadcast", %{conn: conn} do
      %{view: view, space: space, ada: ada} = seeded(conn)
      other = insert_user("other")
      add_user(space, other)
      {:ok, other_view, _} = live_at(build_conn(), other, space)
      open_agents(other_view)
      assert row(other_view, @sheet, ada) =~ ~s(data-state="awake")

      open_agents(view)

      view
      |> element(
        "#{@sheet} [data-role='agent-silence-switch'][phx-value-participant_id='#{ada.id}']"
      )
      |> render_click()

      assert row(other_view, @sheet, ada) =~ ~s(data-state="silenced")
    end
  end

  describe "removed surfaces" do
    # The eye's absence is held by chat/agents_members_sheets_removed_test.exs.
    test "no element is both a navigation link and a click", %{conn: conn} do
      %{view: view} = seeded(conn)
      html = open_agents(view)

      assert html =~ ~s(data-role="agents-open")

      doc = LazyHTML.from_document(html)
      assert LazyHTML.query(doc, "[data-phx-link][phx-click]") |> Enum.count() == 0
    end

    test "a DM renders no Agents entry", %{conn: conn} do
      user = insert_user("dm")
      space = create_space("dm")
      add_user(space, user)
      add_agent(space, "Dm")
      {:ok, _view, html} = live_at(conn, user, space)

      assert html =~ ~s(phx-click="settings_open")
      refute html =~ ~s(data-role="agents-open")
    end
  end

  describe "palette scan of agents_sheet.ex" do
    @source Path.expand("../../../lib/platform_web/live/chat/partials/agents_sheet.ex", __DIR__)

    test "no phone hover, no opacity text, no error text, no hex, no primary radio" do
      src = File.read!(@source)
      assert src =~ "toggle toggle-primary", "positive control: the scan reads the file"

      hovers = Regex.scan(~r/([a-z0-9:-]*)hover:/, src) |> Enum.map(&List.last/1)
      assert Enum.all?(hovers, &(&1 == "lg:")), "hover outside lg:hover: #{inspect(hovers)}"
      refute src =~ "text-base-content/"
      refute src =~ "text-error"
      refute src =~ "radio-primary"
      refute Regex.match?(~r/#[0-9a-fA-F]{3,8}\b/, src)
    end
  end
end
