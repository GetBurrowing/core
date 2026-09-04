defmodule PlatformWeb.ControlCenter.AddAgentToSpacePickerTest do
  @moduledoc """
  Covers the "Add Agent to Space" modal's Space `<select>` on the Control
  Center federation panel for an EXTERNAL agent (task `01a06e01`, stage 2).

  ## What this guards

  `control_center_live.ex`'s `show_add_space_modal` handler calls
  `Platform.Chat.list_spaces/1` with `:kind` omitted, which returns every
  non-archived, non-execution space — `meeting` and `guest_meeting` spaces
  included, and they mint one per call so they flood the picker fast. The
  fix (`Platform.Chat.MeetingSpaces.partition_for_picker/1`, stage 1)
  splits that list into `others` (unchanged shape and order) and
  `meetings` (newest first), and `agent_detail.ex` renders `meetings` into
  a trailing `<optgroup label="Meetings">` instead of dropping them.

  A `<select>` has no rows to collapse, so REJECTED alternatives were (a)
  filtering meeting spaces out of the query entirely — which would make
  them unreachable, and (b) a `disabled` optgroup, which disables every
  option inside it and is (a) in a costume. Assertions below close both:
  every meeting space must still render as a plain, submittable
  `<option>`, just grouped last.

  ## Anti-vacuity

  A test that only asserts `optgroup[label="Meetings"]` renders passes
  against an implementation that renders an EMPTY optgroup and silently
  drops every meeting option — accidentally reintroducing rejected option
  (a). "GROUPED" (each meeting id renders inside the optgroup) and
  "NOTHING LOST" (total option count is conserved) are both required;
  neither alone would catch that regression.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo

  import Ecto.Query

  @select "select[name='space_id']"

  # ── fixtures ─────────────────────────────────────────────────────

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "picker_test_#{System.unique_integer([:positive])}@example.com",
        name: "Picker Test User",
        oidc_sub: "oidc-picker-test-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs) do
    defaults = %{
      slug: "picker-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Picker Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      runtime_type: "external",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    %Agent{}
    |> Agent.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp create_space(attrs) do
    default = %{
      name: "Space #{System.unique_integer([:positive, :monotonic])}",
      slug: "space-#{System.unique_integer([:positive, :monotonic])}",
      kind: "channel"
    }

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  # `LazyHTML.query/2` descends the whole tree; `LazyHTML.filter/2` matches
  # only the fragment's root nodes, so it is not used here for anything
  # nested (per CLAUDE.md's debugging note).
  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp open_modal(view) do
    render_click(view, "show_add_space_modal", %{})
  end

  defp mount_external_agent(conn, agent_attrs \\ %{}) do
    agent = create_agent(agent_attrs)
    conn = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")
    {agent, view}
  end

  # ── tests ────────────────────────────────────────────────────────

  describe "the Meetings optgroup" do
    test "GROUPED: every meeting and guest_meeting space renders inside optgroup[label='Meetings']",
         %{conn: conn} do
      {_agent, view} = mount_external_agent(conn)

      standup = create_space(%{name: "Standup", kind: "meeting"})
      retro = create_space(%{name: "Retro", kind: "meeting"})
      guest_call = create_space(%{name: "Guest Call", kind: "guest_meeting"})

      html = open_modal(view)

      assert has_element?(view, "optgroup[label='Meetings']")

      for space <- [standup, retro, guest_call] do
        assert has_element?(view, "optgroup[label='Meetings'] option[value='#{space.id}']")
      end

      # Not just each id individually — the group holds exactly these three
      # and nothing else, closing the "optgroup renders but is empty (or
      # partially empty)" hole per-id assertions alone would leave open.
      meeting_option_values =
        html
        |> q("optgroup[label='Meetings'] option")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
        |> MapSet.new()

      assert meeting_option_values ==
               MapSet.new([standup.id, retro.id, guest_call.id])
    end

    test "NOT SWEPT IN: channel and group spaces render outside the optgroup", %{conn: conn} do
      {_agent, view} = mount_external_agent(conn)

      channel = create_space(%{name: "General", kind: "channel"})
      group = create_space(%{name: "Crew", kind: "group"})
      # A meeting space in the mix so the optgroup actually exists — a
      # channel "not swept in" is meaningless if there is nowhere to be
      # swept into.
      _meeting = create_space(%{name: "Standup", kind: "meeting"})

      open_modal(view)

      for space <- [channel, group] do
        assert has_element?(view, "#{@select} > option[value='#{space.id}']")
        refute has_element?(view, "optgroup option[value='#{space.id}']")
      end
    end

    test "NOTHING LOST: total option count minus the placeholder equals the qualifying space count",
         %{conn: conn} do
      {agent, view} = mount_external_agent(conn)

      channel = create_space(%{kind: "channel"})
      group = create_space(%{kind: "group"})
      meeting = create_space(%{kind: "meeting"})
      guest = create_space(%{kind: "guest_meeting"})
      # Excluded by `show_add_space_modal`'s own filter or by
      # `Chat.list_spaces/1` — must NOT count toward the total.
      _dm = create_space(%{kind: "dm"})
      _execution = create_space(%{kind: "execution"})
      _archived = create_space(%{kind: "channel", archived_at: DateTime.utc_now()})

      html = open_modal(view)

      qualifying = [channel, group, meeting, guest]
      assert length(qualifying) == 4

      option_count = html |> q("#{@select} option") |> Enum.count()

      # -1 for the "Select a space..." placeholder.
      assert option_count - 1 == length(qualifying)

      # Sanity: the agent fixture itself never becomes a space.
      refute is_nil(agent.id)
    end

    test "STILL SELECTABLE: nothing is disabled, and submitting a meeting space id seats the agent",
         %{conn: conn} do
      {agent, view} = mount_external_agent(conn)

      meeting = create_space(%{name: "Standup", kind: "meeting"})

      html = open_modal(view)

      refute has_element?(view, "optgroup[disabled]")
      refute has_element?(view, "optgroup[label='Meetings'] option[disabled]")

      # Belt and suspenders on the raw markup too — `disabled` on the
      # optgroup tag itself disables every option inside it even without a
      # separate `disabled` attribute rendering on each `<option>`.
      optgroup_disabled_attrs =
        html |> q("optgroup[label='Meetings']") |> LazyHTML.attribute("disabled")

      assert optgroup_disabled_attrs == []

      html =
        view
        |> form("form[phx-submit='add_agent_to_space']", %{
          "space_id" => meeting.id,
          "role" => "member"
        })
        |> render_submit()

      assert html =~ "Agent added to space."

      participant =
        Repo.one(
          from(p in Participant,
            where:
              p.space_id == ^meeting.id and
                p.participant_type == "agent" and
                p.participant_id == ^agent.id
          )
        )

      assert participant != nil
      assert participant.role == "member"
    end

    test "ORDER: the optgroup is the last child of the select, after every ungrouped option",
         %{conn: conn} do
      {_agent, view} = mount_external_agent(conn)

      _channel = create_space(%{kind: "channel"})
      _group = create_space(%{kind: "group"})
      _meeting = create_space(%{kind: "meeting"})

      html = open_modal(view)

      select = q(html, @select)
      child_tags = select |> LazyHTML.child_nodes() |> LazyHTML.tag()

      assert List.last(child_tags) == "optgroup"
      # And it appears exactly once, not interleaved.
      assert Enum.count(child_tags, &(&1 == "optgroup")) == 1
    end

    test "EMPTY CASE: with no meeting-kind spaces, no optgroup renders at all", %{conn: conn} do
      {_agent, view} = mount_external_agent(conn)

      _channel = create_space(%{kind: "channel"})
      _group = create_space(%{kind: "group"})

      open_modal(view)

      refute has_element?(view, "optgroup")
      refute has_element?(view, "optgroup[label='Meetings']")
    end
  end
end
