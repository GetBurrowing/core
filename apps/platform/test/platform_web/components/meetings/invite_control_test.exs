defmodule PlatformWeb.Components.Meetings.InviteControlTest do
  @moduledoc """
  Render tests for the shared invite control (task 019fb955-1d7b stage 3).

  ## Why these assert elements, not substrings

  Two failure modes this suite is built to catch, both measured on this
  repo rather than assumed:

    * A page can contain your string from somewhere else — a `body =~
      name` assertion here passed off a raw placeholder attribute. So
      every assertion below selects the specific `data-role` element the
      component feeds and compares its TEXT NODE.
    * A substring assertion cannot detect a LONGER value: `=~ "expires
      in 24h"` passes on `"expires in 24hours ago"`. So the comparisons
      are `==` on the normalised text, never `=~`.

  `data-role` rather than a Tailwind class, for the same reason
  `IntentsCollapse` does: a class reshuffle must not be able to break a
  test.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias PlatformWeb.Components.Meetings.InviteControl

  # ── fixtures ───────────────────────────────────────────────────────────

  defp entry(overrides) do
    Map.merge(
      %{
        id: "entry-1",
        name: "Sam Ortiz",
        subtitle: nil,
        user_id: nil,
        email: nil,
        expires_at: nil,
        external: false,
        agent: false,
        avatar_url: nil,
        removable: false,
        copy_url: nil
      },
      Map.new(overrides)
    )
  end

  defp internal_entry(overrides \\ []),
    do: entry(Keyword.merge([user_id: "3f1a0b6e-0000-4000-8000-000000000001"], overrides))

  defp external_account_entry(overrides \\ []),
    do:
      entry(
        Keyword.merge(
          [user_id: "3f1a0b6e-0000-4000-8000-000000000002", external: true],
          overrides
        )
      )

  defp guest_entry(overrides \\ []),
    do: entry(Keyword.merge([expires_at: DateTime.utc_now()], overrides))

  defp pending_external_entry(overrides \\ []),
    do: entry(Keyword.merge([email: "jane@example.test"], overrides))

  defp agent_entry(overrides \\ []),
    do: entry(Keyword.merge([agent: true, subtitle: "meeting producer"], overrides))

  defp user(id, name, email), do: %User{id: id, name: name, email: email}

  # ── helpers ────────────────────────────────────────────────────────────

  # `LazyHTML`, not `Floki` — Phoenix.LiveViewTest 1.1 replaced the
  # parser and `floki` is no longer a dependency of this umbrella.
  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> q(selector) |> Enum.count()

  defp one(html, selector) do
    assert [el] = html |> q(selector) |> Enum.to_list()
    el
  end

  defp attr(lazy, name), do: LazyHTML.attribute(lazy, name)

  defp class_of(lazy), do: lazy |> attr("class") |> List.first()

  # Normalises the whitespace HEEx indentation introduces around a text
  # node WITHOUT relaxing the comparison: the result is still compared
  # with `==`, so a LONGER value fails.
  defp text_of(lazy) do
    lazy
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp text_at(html, selector), do: html |> q(selector) |> text_of()

  defp control(opts) do
    assigns = %{
      mode: Keyword.get(opts, :mode, :draft),
      query: Keyword.get(opts, :query, ""),
      candidates: Keyword.fetch!(opts, :candidates),
      email_option: Keyword.get(opts, :email_option),
      target: nil
    }

    assigns =
      if Keyword.has_key?(opts, :name), do: Map.put(assigns, :name, opts[:name]), else: assigns

    render_component(&InviteControl.invite_control/1, assigns)
  end

  defp row(entry, opts) do
    render_component(&InviteControl.invite_row/1, %{
      entry: entry,
      mode: Keyword.fetch!(opts, :mode),
      removable: Keyword.get(opts, :removable, false),
      copy_url: Keyword.get(opts, :copy_url),
      target: nil,
      id_prefix: Keyword.get(opts, :id_prefix, "meeting-invite"),
      time_zone: Keyword.get(opts, :time_zone)
    })
  end

  # ── the dropdown's three branches ──────────────────────────────────────

  describe "invite_control/1 — no candidates and no address" do
    test "renders the search box and no dropdown at all" do
      html = control(candidates: [], email_option: nil)

      assert count(html, "[data-role=meeting-invite-search]") == 1
      assert count(html, "[data-role=meeting-invite-dropdown]") == 0
      assert count(html, "[data-role=meeting-invite-option]") == 0
    end

    test "the search box refilters on every keystroke and clears 44px" do
      html = control(candidates: [], email_option: nil, query: "sam@")

      input = one(html, "[data-role=meeting-invite-search]")

      assert attr(input, "phx-keyup") == ["meeting_create_invite_search"]
      assert attr(input, "value") == ["sam@"]

      assert class_of(one(html, "[data-role=meeting-invite-control] label")) =~ "min-h-11"
    end
  end

  describe "invite_control/1 — members matched" do
    test "lists the members and the two options are ABSENT" do
      html =
        control(
          candidates: [
            user("11111111-0000-4000-8000-000000000001", "Dalton", "dalton@example.test"),
            user("11111111-0000-4000-8000-000000000002", "Robin", "robin@example.test")
          ],
          email_option: nil
        )

      assert count(html, "[data-role=meeting-invite-candidate]") == 2

      assert attr(q(html, "[data-role=meeting-invite-candidate]"), "data-user-id") == [
               "11111111-0000-4000-8000-000000000001",
               "11111111-0000-4000-8000-000000000002"
             ]

      # The whole point of stage 2's mutually-exclusive return shape: a
      # query that matches a colleague must never also offer to stage an
      # external grant for them.
      assert count(html, "[data-role=meeting-invite-option]") == 0

      assert attr(one(html, "[data-role=meeting-invite-dropdown]"), "data-dropdown-kind") ==
               ["candidates"]
    end
  end

  describe "invite_control/1 — an address matched nobody" do
    setup do
      %{html: control(candidates: [], email_option: "sam@example.test")}
    end

    test "renders EXACTLY two options, guest first", %{html: html} do
      options = q(html, "[data-role=meeting-invite-option]")

      # The count is the assertion. A missing-element crash would prove
      # nothing about how many rows the dropdown offers.
      assert Enum.count(options) == 2

      assert attr(options, "data-option") == ["guest", "external"]
    end

    test "the guest option is the highlighted default", %{html: html} do
      guest = one(html, "[data-role=meeting-invite-option][data-option=guest]")
      assert attr(guest, "data-default") == ["true"]

      external = one(html, "[data-role=meeting-invite-option][data-option=external]")
      assert attr(external, "data-default") == []
    end

    test "the guest option's copy is exactly the canvas's, both viewports", %{html: html} do
      guest = "[data-role=meeting-invite-option][data-option=guest] "

      assert text_at(html, guest <> "[data-role=meeting-invite-option-title]") ==
               "Invite as a guest"

      assert text_at(
               html,
               guest <> "[data-role=meeting-invite-option-detail] [data-viewport=wide]"
             ) ==
               "Personal link · expires in 24h · no account"

      assert text_at(
               html,
               guest <> "[data-role=meeting-invite-option-detail] [data-viewport=narrow]"
             ) ==
               "Personal link · 24h · no account"
    end

    test "the external option's copy is exactly the canvas's, both viewports", %{html: html} do
      ext = "[data-role=meeting-invite-option][data-option=external] "

      assert text_at(html, ext <> "[data-role=meeting-invite-option-title] [data-viewport=wide]") ==
               "Invite as an external member"

      assert text_at(
               html,
               ext <> "[data-role=meeting-invite-option-title] [data-viewport=narrow]"
             ) ==
               "Invite as external member"

      assert text_at(html, ext <> "[data-role=meeting-invite-option-detail] [data-viewport=wide]") ==
               "Signs in as themselves · needs an org grant"

      assert text_at(
               html,
               ext <> "[data-role=meeting-invite-option-detail] [data-viewport=narrow]"
             ) ==
               "Signs in · needs an org grant"
    end

    test "both short forms are rendered, not chosen — the row must not wrap at 375px", %{
      html: html
    } do
      # The canvas draws two strings. Picking one at render time would
      # ship the wrong one to half the viewports.
      narrow = q(html, "[data-role=meeting-invite-option] [data-viewport=narrow]")
      wide = q(html, "[data-role=meeting-invite-option] [data-viewport=wide]")

      assert Enum.count(narrow) == 3
      assert Enum.count(wide) == 3

      assert Enum.all?(attr(narrow, "class"), &(&1 =~ "sm:hidden"))
      assert Enum.all?(attr(wide, "class"), &(&1 =~ "hidden sm:inline"))
    end

    test "options are 52px tappable rows below sm, per the canvas", %{html: html} do
      classes = attr(q(html, "[data-role=meeting-invite-option]"), "class")

      assert Enum.count(classes) == 2
      assert Enum.all?(classes, &(&1 =~ "min-h-[52px]"))
    end

    test "the icons are hero icons and carry no emoji", %{html: html} do
      assert count(html, "[data-role=meeting-invite-option][data-option=guest] span.hero-link") ==
               1

      assert count(
               html,
               "[data-role=meeting-invite-option][data-option=external] span.hero-sparkles"
             ) == 1
    end
  end

  # ── mode-derived event names (stage 4) ─────────────────────────────────
  #
  # Both surfaces live in one LiveView, so the event name is the only
  # thing that distinguishes a create-sheet click from a detail-panel
  # click before it reaches a handler.

  describe "event/2" do
    test "draft and live never share an event name" do
      draft = Enum.map([:search, :stage], &InviteControl.event(:draft, &1))
      live = Enum.map([:search, :stage], &InviteControl.event(:live, &1))

      assert draft == ["meeting_create_invite_search", "meeting_create_invite_stage"]
      assert live == ["meeting_invite_search", "meeting_invite_stage"]
      assert MapSet.disjoint?(MapSet.new(draft), MapSet.new(live))
    end

    test "asking a mode for a control it does not own raises" do
      assert_raise ArgumentError, ~r/no :add_people event exists in invite mode :draft/, fn ->
        InviteControl.event(:draft, :add_people)
      end

      assert_raise ArgumentError, ~r/no :unstage event exists in invite mode :live/, fn ->
        InviteControl.event(:live, :unstage)
      end
    end
  end

  # ── Enter commits (task 01a192d6 stage 3) ──────────────────────────────

  describe "invite_control/1 — Enter in the search box" do
    test "the search input carries the InviteSearchEnter hook" do
      input = one(control(candidates: []), "[data-role=meeting-invite-search]")

      assert attr(input, "phx-hook") == ["InviteSearchEnter"]
    end

    test "data-commit-event names the mode's commit event" do
      draft = one(control(mode: :draft, candidates: []), "[data-role=meeting-invite-search]")
      live = one(control(mode: :live, candidates: []), "[data-role=meeting-invite-search]")

      assert attr(draft, "data-commit-event") == ["meeting_create_invite_commit"]
      assert attr(live, "data-commit-event") == ["meeting_invite_commit"]
      assert InviteControl.event(:draft, :commit) == "meeting_create_invite_commit"
      assert InviteControl.event(:live, :commit) == "meeting_invite_commit"
    end

    # Task 01a19ea6: a guest row's expiry and New link exist only in :live;
    # a draft row has no link yet.
    test "expiry and renew are live-only events" do
      assert InviteControl.event(:live, :expiry) == "meeting_invite_expiry"
      assert InviteControl.event(:live, :renew) == "meeting_invite_renew"

      assert_raise ArgumentError, fn -> InviteControl.event(:draft, :expiry) end
      assert_raise ArgumentError, fn -> InviteControl.event(:draft, :renew) end
    end

    test "the input has a name only when one is given" do
      unnamed = one(control(candidates: []), "[data-role=meeting-invite-search]")

      named =
        one(
          control(candidates: [], name: "start_meeting[invite_query]"),
          "[data-role=meeting-invite-search]"
        )

      assert attr(unnamed, "name") in [[], [nil]]
      assert attr(named, "name") == ["start_meeting[invite_query]"]
    end
  end

  describe "invite_control/1 — one stage event per mode, kinded" do
    test "all three draft options emit the draft stage event" do
      html =
        control(mode: :draft, candidates: [], email_option: "sam@example.test") <>
          control(
            mode: :draft,
            candidates: [user("11111111-0000-4000-8000-000000000001", "Dalton", "d@example.test")]
          )

      clicked =
        q(html, "[data-role=meeting-invite-option], [data-role=meeting-invite-candidate]")

      assert Enum.count(clicked) == 3
      assert attr(clicked, "phx-click") |> Enum.uniq() == ["meeting_create_invite_stage"]
      assert attr(clicked, "phx-value-kind") == ["guest", "external", "user"]
    end

    test "the live control emits the live stage event instead" do
      html = control(mode: :live, candidates: [], email_option: "sam@example.test")

      assert attr(q(html, "[data-role=meeting-invite-option]"), "phx-click") |> Enum.uniq() ==
               ["meeting_invite_stage"]

      assert attr(one(html, "[data-role=meeting-invite-search]"), "phx-keyup") ==
               ["meeting_invite_search"]
    end
  end

  # ── tag derivation ─────────────────────────────────────────────────────

  describe "tag/1 — the four derivations" do
    test "user_id set plus an external org membership is external" do
      assert InviteControl.tag(external_account_entry()) == :external
    end

    test "user_id set otherwise is internal" do
      assert InviteControl.tag(internal_entry()) == :internal
    end

    test "no user_id with an expiry is a guest" do
      assert InviteControl.tag(guest_entry()) == :guest
    end

    test "no user_id, an address and no expiry is an external pending a grant" do
      # This is the row Invite.kind/1 gets wrong: it has a NULL user_id,
      # so kind/1 says :guest. Stage 2 writes exactly this shape from
      # invite_external_user/3.
      assert InviteControl.tag(pending_external_entry()) == :external
    end

    test "the agent row is tagged agent regardless of the other columns" do
      assert InviteControl.tag(agent_entry()) == :agent
    end

    test "an uncovered row shape RAISES rather than defaulting to guest" do
      # No user_id, no expiry, no email — nothing identifies this row.
      # A fallback would render it `guest`, which is a lie about whether
      # the person needs an org grant.
      assert_raise ArgumentError, ~r/no tag derivation covers/, fn ->
        InviteControl.tag(entry([]))
      end
    end

    test "a missing derivation input RAISES naming the key" do
      assert_raise ArgumentError, ~r/missing tag derivation key\(s\) \[:external\]/, fn ->
        InviteControl.tag(entry([]) |> Map.delete(:external))
      end
    end

    test "every tag has a distinct tone — colour never collapses two tags" do
      tones = Enum.map(InviteControl.tags(), &InviteControl.tag_tone/1)
      assert length(Enum.uniq(tones)) == length(tones)
    end

    test "an unknown tag has no tone rather than a neutral fallback" do
      assert_raise FunctionClauseError, fn -> InviteControl.tag_tone(:nonesuch) end
    end
  end

  describe "invite_row/1 — the tag reaches the DOM" do
    test "each derivation renders its own tag element and label" do
      for {entry, tag} <- [
            {internal_entry(), "internal"},
            {external_account_entry(), "external"},
            {guest_entry(), "guest"},
            {pending_external_entry(), "external"},
            {agent_entry(), "agent"}
          ] do
        html = row(entry, mode: :live)

        assert attr(one(html, "[data-role=meeting-invite-row]"), "data-tag") == [tag]
        assert text_at(html, "[data-role=meeting-invite-tag]") == tag
      end
    end

    test "the tag is monospace and carries no raw hex" do
      html = row(guest_entry(), mode: :live)
      class = class_of(one(html, "[data-role=meeting-invite-tag]"))

      assert class =~ "font-mono"
      assert class =~ "chip-soft"
      refute class =~ ~r/#[0-9a-fA-F]{3,6}/
    end
  end

  # ── mode semantics ─────────────────────────────────────────────────────

  describe "invite_row/1 — draft mode" do
    test "a removable draft row has an unstage control and NO copy control" do
      html = row(guest_entry(removable: true), mode: :draft, removable: true)

      unstage = one(html, "[data-role=meeting-invite-unstage]")
      assert attr(unstage, "phx-click") == ["meeting_create_invite_unstage"]
      assert attr(unstage, "phx-value-id") == ["entry-1"]

      # Nothing has been minted at create time, so there is no link.
      assert count(html, "[data-role=meeting-invite-copy]") == 0
    end

    test "a copy_url passed into a draft row renders no control" do
      # A caller mistake must not produce a button that copies a token
      # nobody minted.
      html = row(guest_entry(), mode: :draft, removable: true, copy_url: "https://example.test/g")

      assert count(html, "[data-role=meeting-invite-copy]") == 0
    end

    test "a non-removable draft row (host, agent) has no unstage control" do
      html = row(agent_entry(), mode: :draft, removable: false)

      assert count(html, "[data-role=meeting-invite-unstage]") == 0
    end

    test "the unstage control is a 44px tap target" do
      html = row(guest_entry(), mode: :draft, removable: true)
      class = class_of(one(html, "[data-role=meeting-invite-unstage]"))

      assert class =~ "min-h-11"
      assert class =~ "min-w-11"
    end
  end

  describe "invite_row/1 — live mode" do
    test "a live guest row has a copy control and NO unstage control" do
      html =
        row(guest_entry(), mode: :live, removable: true, copy_url: "https://example.test/g/abc")

      copy = one(html, "[data-role=meeting-invite-copy]")
      assert attr(copy, "data-clipboard-text") == ["https://example.test/g/abc"]
      assert attr(copy, "phx-hook") == ["CopyToClipboard"]

      # The canvas draws no remove/revoke control on any live invitee
      # row. revoke_invite/1 gets no UI caller in this task — revoking
      # the last invitee currently WIDENS the notified audience.
      assert count(html, "[data-role=meeting-invite-unstage]") == 0
    end

    test "a live row with no minted link has no copy control" do
      html = row(internal_entry(), mode: :live, copy_url: nil)

      assert count(html, "[data-role=meeting-invite-copy]") == 0
      assert count(html, "[data-role=meeting-invite-unstage]") == 0
    end
  end

  describe "invite_row/1 — the subtitle carries state" do
    test "renders the state line verbatim when present" do
      html = row(guest_entry(subtitle: "expires in 24h"), mode: :live)

      assert text_at(html, "[data-role=meeting-invite-row-subtitle]") == "expires in 24h"
    end

    test "renders no subtitle element at all when there is no state to show" do
      html = row(internal_entry(subtitle: nil), mode: :live)

      assert count(html, "[data-role=meeting-invite-row-subtitle]") == 0
    end

    test "the name is the element's own text, not a match anywhere on the row" do
      html = row(internal_entry(name: "Alex Rivera", subtitle: "host"), mode: :live)

      assert text_at(html, "[data-role=meeting-invite-row-name]") == "Alex Rivera"
    end
  end

  # ── invite_list/1 ──────────────────────────────────────────────────────

  describe "invite_list/1" do
    defp list(entries, mode) do
      render_component(&InviteControl.invite_list/1, %{
        entries: entries,
        mode: mode,
        target: nil
      })
    end

    test "the header counts the entries" do
      html = list([internal_entry(id: "a"), guest_entry(id: "b")], :live)

      assert text_at(html, "[data-role=meeting-invite-list-header]") == "Invited · 2"
      assert count(html, "[data-role=meeting-invite-row]") == 2
    end

    test "live mode renders the inline Add people row" do
      html = list([internal_entry()], :live)

      add = one(html, "[data-role=meeting-invite-add-people]")
      assert text_of(add) == "Add people"
      assert count(html, "[data-role=meeting-invite-add-people] span.hero-plus") == 1

      class = class_of(add)
      assert class =~ "min-h-11"
      assert class =~ "border-dashed"
      # Rung 18: the label is base-content; the primary hue is on the icon.
      assert class =~ "text-base-content"
      refute class =~ "text-primary"
      assert count(html, "[data-role=meeting-invite-add-people] span.hero-plus.text-primary") == 1
    end

    test "draft mode has no Add people row — the search box is already open above" do
      html = list([internal_entry()], :draft)

      assert count(html, "[data-role=meeting-invite-add-people]") == 0
    end

    test "each entry supplies its own controls" do
      html =
        list(
          [
            internal_entry(id: "a", removable: false),
            guest_entry(id: "b", removable: true)
          ],
          :draft
        )

      assert attr(q(html, "[data-role=meeting-invite-unstage]"), "data-entry-id") == ["b"]
    end

    test "an entry built without :removable RAISES rather than losing its control" do
      bare = internal_entry() |> Map.delete(:removable)

      assert_raise KeyError, fn -> list([bare], :draft) end
    end
  end

  # ── task 01a19ea6 stage 2: guest rows in :live ─────────────────────────

  describe "invite_row/1 — a live guest row (task 01a19ea6 stage 2)" do
    # Wed 4 Nov 2026, 21:00 UTC: the canvas's own example time.
    @ends_at ~U[2026-11-04 21:00:00Z]

    defp expiry(overrides \\ []) do
      Map.merge(
        %{
          expires_at: DateTime.add(DateTime.utc_now(), 2 * 86_400, :second),
          expired?: false,
          meeting_end?: true
        },
        Map.new(overrides)
      )
    end

    defp live_guest(overrides \\ []) do
      guest_entry(
        Keyword.merge(
          [
            id: "guest-1",
            name: "Guest Alpha",
            expiry: expiry(),
            copy_url: "https://meet.test/g/abc"
          ],
          overrides
        )
      )
    end

    defp live_row(entry, opts \\ []),
      do: row(entry, Keyword.merge([mode: :live, copy_url: entry.copy_url], opts))

    test "Copy link is the primary action and copies the row's own link" do
      html = live_row(live_guest())

      copy = one(html, "[data-role=meeting-invite-copy]")
      assert text_of(copy) == "Copy link"
      assert attr(copy, "data-clipboard-text") == ["https://meet.test/g/abc"]
      assert attr(copy, "phx-hook") == ["CopyToClipboard"]
      assert attr(copy, "phx-update") == ["ignore"]
      assert attr(copy, "data-copied-label") == ["Copied"]
      assert attr(copy, "aria-label") == ["Copy link for Guest Alpha"]
      assert count(html, "[data-role=meeting-invite-renew]") == 0
    end

    test "the copy button names a polite aria-live region the hook writes" do
      html = live_row(live_guest(), id_prefix: "panel")

      copy = one(html, "[data-role=meeting-invite-copy]")
      status = one(html, "[data-role=meeting-invite-copy-status]")
      assert attr(copy, "data-copy-status-target") == attr(status, "id")
      assert attr(status, "id") == ["panel-copy-status-guest-1"]
      assert attr(status, "aria-live") == ["polite"]
      assert attr(status, "phx-update") == ["ignore"]
    end

    test "the expiry line states the time in the viewer's zone" do
      # Asia/Tokyo: UTC+9 with no DST rules, so the expectation cannot move
      # with a tz database update (America/Edmonton gave 14:00 on one run and
      # 15:00 on the next, as the suite's tzdata changed Alberta's rules).
      html = live_row(live_guest(expiry: expiry(expires_at: @ends_at)), time_zone: "Asia/Tokyo")

      # 21:00 UTC on Wed 4 Nov is 06:00 on Thu 5 Nov in Tokyo.
      assert text_at(html, "[data-role=meeting-invite-expiry-text]") ==
               "Link works until Thu 5 Nov, 06:00"
    end

    test "with no zone the line is UTC and says so" do
      html = live_row(live_guest(expiry: expiry(expires_at: @ends_at)))

      assert text_at(html, "[data-role=meeting-invite-expiry-text]") ==
               "Link works until Wed 4 Nov, 21:00 UTC"
    end

    test "the select offers the three choices behind a disabled prompt" do
      html = live_row(live_guest(), id_prefix: "panel")

      select = one(html, "[data-role=meeting-invite-expiry-select]")
      assert attr(select, "aria-label") == ["Change link expiry for Guest Alpha"]
      assert attr(select, "name") == ["choice"]
      assert [id] = attr(select, "id")
      assert String.starts_with?(id, "panel-expiry-form-guest-1-")

      values = html |> q("[data-role=meeting-invite-expiry-select] option") |> attr("value")
      assert values == ["", "meeting_end", "hours_24", "days_7"]

      prompt = html |> q("[data-role=meeting-invite-expiry-select] option[value='']")
      assert attr(prompt, "disabled") == [""]
      assert attr(prompt, "selected") == [""]

      assert text_at(html, "[data-role=meeting-invite-expiry-select] option[value=meeting_end]") ==
               "Until the meeting ends"

      form = one(html, "[data-role=meeting-invite-expiry-form]")
      assert attr(form, "phx-change") == ["meeting_invite_expiry"]

      assert html
             |> q("[data-role=meeting-invite-expiry-form] input[name=invite_id]")
             |> attr("value") == ["guest-1"]
    end

    test "without a future scheduled end: two choices and the fallback named" do
      soon = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)
      html = live_row(live_guest(expiry: expiry(expires_at: soon, meeting_end?: false)))

      values = html |> q("[data-role=meeting-invite-expiry-select] option") |> attr("value")
      assert values == ["", "hours_24", "days_7"]

      assert text_at(html, "[data-role=meeting-invite-expiry-text]") =~
               ~r/^Link works until \w{3} \d{1,2} \w{3}, \d{2}:\d{2} UTC · no scheduled end, 24 hours$/
    end

    test "seven days on a meeting with no end drops the fallback note" do
      week = DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
      html = live_row(live_guest(expiry: expiry(expires_at: week, meeting_end?: false)))

      refute text_at(html, "[data-role=meeting-invite-expiry-text]") =~ "no scheduled end"
    end

    test "an expired row reads Link expired, offers New link and no copy or select" do
      gone = DateTime.add(DateTime.utc_now(), -3600, :second)

      html =
        live_row(live_guest(expiry: expiry(expires_at: gone, expired?: true), copy_url: nil))

      assert text_at(html, "[data-role=meeting-invite-expiry-text]") == "Link expired"
      assert count(html, "[data-role=meeting-invite-copy]") == 0
      assert count(html, "[data-role=meeting-invite-copy-status]") == 0
      assert count(html, "[data-role=meeting-invite-expiry-select]") == 0
      assert count(html, "[data-clipboard-text]") == 0

      renew = one(html, "[data-role=meeting-invite-renew]")
      assert text_of(renew) == "New link"
      assert attr(renew, "phx-click") == ["meeting_invite_renew"]
      assert attr(renew, "phx-value-id") == ["guest-1"]
      assert attr(renew, "phx-value-choice") == ["meeting_end"]
    end

    test "member, external and draft rows get no expiry line" do
      for html <- [
            live_row(internal_entry(copy_url: nil)),
            live_row(external_account_entry(copy_url: nil)),
            row(live_guest(), mode: :draft, removable: true)
          ] do
        assert count(html, "[data-role=meeting-invite-expiry]") == 0
        assert count(html, "[data-role=meeting-invite-renew]") == 0
      end
    end

    test "no meeting-wide link, share or QR control anywhere on the row" do
      html = live_row(live_guest())

      for pattern <- [~r/share/i, ~r/qr/i, ~r/meeting link/i] do
        refute html =~ pattern
      end
    end
  end

  # ── task 01a18d0a-ec37 stage 2 ─────────────────────────────────────────

  describe "invite_control/1 — a typed name that matches nobody" do
    test "offers ONE guest option carrying the name, and no external option" do
      html = control(candidates: [], email_option: nil, query: "  Dana Whitfield ")

      assert count(html, "[data-role=meeting-invite-option]") == 1
      option = one(html, "[data-role=meeting-invite-option]")
      assert attr(option, "data-option") == ["guest-name"]
      assert attr(option, "phx-value-kind") == ["guest"]
      assert attr(option, "phx-value-name") == ["Dana Whitfield"]
      assert attr(option, "phx-value-email") == []

      # Canvas 01a19ea7 r1 copy (task 01a19ea6 stage 2), curly quotes.
      assert text_at(html, "[data-role=meeting-invite-option-title]") ==
               "Add guest “Dana Whitfield”"

      assert text_at(html, "[data-role=meeting-invite-option-detail]") ==
               "you'll share the link"

      assert count(html, "[data-option=external]") == 0
    end

    test "a whitespace-only query still renders no dropdown" do
      html = control(candidates: [], email_option: nil, query: "   ")
      assert count(html, "[data-role=meeting-invite-dropdown]") == 0
    end
  end

  @human_users [
    %User{
      id: "3f1a0b6e-0000-4000-8000-0000000000a1",
      name: "Dana Whitfield",
      email: "dana.whitfield.has.a.very.long.address@example.test"
    },
    %User{id: "3f1a0b6e-0000-4000-8000-0000000000a2", name: "Dana Cole", email: "dc@example.test"}
  ]

  defp human_state(overrides) do
    Map.merge(
      %{
        id: "rail",
        query: "",
        users: [],
        guest_host?: true,
        result: nil,
        error: nil
      },
      Map.new(overrides)
    )
  end

  defp human(overrides),
    do: render_component(&InviteControl.human_invite/1, %{state: human_state(overrides)})

  defp guest_result(overrides) do
    Map.merge(
      %{
        invite: %Platform.Meetings.Invite{id: "inv-1", email: nil},
        name: "Dana Whitfield",
        url: "https://meet.example.test/g/AbCdEfGhIjKlMnOpQrStUv",
        email_open?: false,
        email_error: nil
      },
      Map.new(overrides)
    )
  end

  describe "human_invite/1 — the field" do
    test "is the inline 'Invite' field with 'Type a name…' and no dropdown while empty" do
      html = human([])

      input = one(html, "[data-role=meeting-human-invite-search]")
      assert attr(input, "placeholder") == ["Type a name…"]
      assert attr(input, "name") == ["query"]
      assert html |> one("form") |> attr("phx-change") == ["meeting_human_invite_search"]
      assert text_at(html, "[data-role=meeting-human-invite] label") == "Invite"
      assert count(html, "[data-role=meeting-human-invite-dropdown]") == 0
    end

    test "whitespace opens nothing" do
      assert count(human(query: "   "), "[data-role=meeting-human-invite-dropdown]") == 0
    end
  end

  describe "human_invite/1 — the dropdown" do
    setup do
      %{html: human(query: "Dana Whitfield", users: @human_users)}
    end

    test "lists the user rows from the resolver and the guest row LAST", %{html: html} do
      buttons =
        html
        |> q("[data-role=meeting-human-invite-dropdown] > button")
        |> Enum.map(&(attr(&1, "data-role") |> List.first()))

      assert buttons == [
               "meeting-human-invite-user",
               "meeting-human-invite-user",
               "meeting-human-invite-guest"
             ]

      assert text_at(html, "[data-role=meeting-human-invite-guest-label]") ==
               ~s(Invite "Dana Whitfield" as guest)

      assert text_at(html, "[data-role=meeting-human-invite-guest-badge]") == "Guest"
    end

    test "user rows carry the rendered id; name is kept whole and the email truncates", %{
      html: html
    } do
      [first | _] = html |> q("[data-role=meeting-human-invite-user]") |> Enum.to_list()
      assert attr(first, "phx-value-id") == [hd(@human_users).id]
      assert attr(first, "phx-click") == ["meeting_human_invite_user"]

      name = html |> q("[data-role=meeting-human-invite-user-name]") |> Enum.at(0)
      assert class_of(name) =~ "shrink-0"
      assert class_of(name) =~ "whitespace-nowrap"
      email = html |> q("[data-role=meeting-human-invite-user-email]") |> Enum.at(0)
      assert class_of(email) =~ "min-w-0"
      assert class_of(email) =~ "truncate"
    end

    test "the guest row is set off by a divider and uses the info badge", %{html: html} do
      guest = one(html, "[data-role=meeting-human-invite-guest]")
      assert class_of(guest) =~ "border-t border-edge"
      assert attr(guest, "phx-click") == ["meeting_human_invite_guest"]

      badge = one(html, "[data-role=meeting-human-invite-guest-badge]")
      assert class_of(badge) =~ "chip-info"
    end

    test "a name matching nobody still gets the guest row, with no divider above it" do
      html = human(query: "Nobody Atall", users: [])

      assert count(html, "[data-role=meeting-human-invite-user]") == 0
      guest = one(html, "[data-role=meeting-human-invite-guest]")
      refute class_of(guest) =~ "border-t"
    end

    test "with no guest host the guest row is ABSENT" do
      html = human(query: "Dana Whitfield", users: @human_users, guest_host?: false)

      assert count(html, "[data-role=meeting-human-invite-user]") == 2
      assert count(html, "[data-role=meeting-human-invite-guest]") == 0
    end

    test "no guest host and no match: no dropdown at all" do
      html = human(query: "Nobody", users: [], guest_host?: false)
      assert count(html, "[data-role=meeting-human-invite-dropdown]") == 0
    end
  end

  describe "human_invite/1 — the persistent guest result" do
    test "shows name, Guest badge, invited, the FULL link in mono, primary Copy link and + Add email" do
      html = human(result: guest_result([]))

      assert text_at(html, "[data-role=meeting-human-invite-result-name]") == "Dana Whitfield"
      assert text_at(html, "[data-role=meeting-human-invite-result-badge]") == "Guest"

      link = one(html, "[data-role=meeting-human-invite-link]")
      assert text_of(link) == "https://meet.example.test/g/AbCdEfGhIjKlMnOpQrStUv"
      assert class_of(link) =~ "font-mono"
      refute class_of(link) =~ "truncate"

      copy = one(html, "[data-role=meeting-human-invite-copy]")
      assert text_of(copy) == "Copy link"
      assert attr(copy, "phx-hook") == ["CopyToClipboard"]

      assert attr(copy, "data-clipboard-text") == [
               "https://meet.example.test/g/AbCdEfGhIjKlMnOpQrStUv"
             ]

      assert attr(copy, "data-copied-label") == ["Copied"]
      assert class_of(copy) =~ "bg-primary"
      assert class_of(copy) =~ "text-primary-content"
      assert class_of(copy) =~ "[&.copy-copied]:bg-success"
      assert attr(copy, "phx-update") == ["ignore"]

      assert text_at(html, "[data-role=meeting-human-invite-add-email]") ==
               "+ Add email (optional)"

      assert count(html, "[data-role=meeting-human-invite-email-form]") == 0
    end

    test "Add email opens a form; its error renders without losing the link" do
      html =
        human(
          result: guest_result(email_open?: true, email_error: "Email must be an email address.")
        )

      assert count(html, "[data-role=meeting-human-invite-email-form]") == 1
      assert count(html, "[data-role=meeting-human-invite-add-email]") == 0

      assert text_at(html, "[data-role=meeting-human-invite-email-error]") ==
               "Email must be an email address."

      assert count(html, "[data-role=meeting-human-invite-link]") == 1
    end

    test "a saved email is shown and the Add email affordance goes" do
      invite = %Platform.Meetings.Invite{id: "inv-1", email: "dana@example.test"}
      html = human(result: guest_result(invite: invite))

      assert text_at(html, "[data-role=meeting-human-invite-email-saved]") == "dana@example.test"
      assert count(html, "[data-role=meeting-human-invite-add-email]") == 0
    end

    test "carries no raw colour and no emoji" do
      html = human(query: "Dana Whitfield", users: @human_users, result: guest_result([]))

      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute html =~ ~r/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u
    end
  end
end
