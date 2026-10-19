defmodule PlatformWeb.ChatLivePinnedBlockTest do
  @moduledoc """
  Render tests for the sidebar's Pinned block (task 019fd80f stage 2).

  The block holds channels AND direct messages in one flat list at the top
  of the rail. A pinned conversation is LIFTED out of its home section, not
  copied into the block, so every test that asserts presence in the block
  also asserts absence from the home section. Presence alone passes for an
  implementation that renders the row twice, which is the failure the
  design specifically rules out.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins
  alias Platform.Tenancy

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "pinned-block-#{suffix}@example.com",
      name: "Pinned Block #{suffix}",
      oidc_sub: "oidc-pinned-block-#{suffix}",
      avatar_url: nil
    })
  end

  defp authed(conn) do
    user = insert_user(System.unique_integer([:positive]))
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  defp acme_section do
    Enum.find(Sidebar.list_active_default_sections(), &(&1.org_id == acme_org().id))
  end

  # A pinned TASK, which is what fills the second pinned block. Different
  # mechanism from a pinned conversation entirely: a row in `task_chat_pins`
  # rather than an entry in the viewer's preferences.
  defp seed_pinned_task_for(user, title) do
    {:ok, project} =
      Tasks.create_project(%{name: "Pinned Label Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} = ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)
    %{task: task, space: space}
  end

  defp create_channel(slug, attrs \\ %{}) do
    {:ok, ch} =
      Chat.create_space(
        Map.merge(
          %{name: String.capitalize(slug), slug: slug, kind: "channel", org_id: acme_org().id},
          attrs
        )
      )

    ch
  end

  # A DM only reaches the rail through `Chat.list_user_conversations/2`, which
  # joins participants, so the viewer must actually be in it. The other
  # participant's `display_name` is what `sidebar_display_name/2` renders.
  defp create_dm(user, other_name) do
    {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: other_name,
        joined_at: DateTime.utc_now()
      })

    dm
  end

  defp live_rail(conn) do
    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path)
      ok -> ok
    end
  end

  # ── HTML slicing ────────────────────────────────────────────────────────

  defp desktop_sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  defp rail(conn) do
    {:ok, _view, html} = live_rail(conn)
    desktop_sidebar(html)
  end

  # One `<section>` out of the rail, keyed by an attribute on the tag. The
  # rail's sections are siblings, never nested, so a non-greedy match to the
  # first closing tag is exact.
  defp section_by(sidebar, attr) do
    case Regex.run(~r/<section[^>]*#{Regex.escape(attr)}.*?<\/section>/s, sidebar) do
      [match] -> match
      _ -> nil
    end
  end

  # A section's own heading text, whole and whitespace-normalised.
  #
  # Asserting the WHOLE text, not "contains Pinned": both correct labels
  # contain the word "Pinned", so a substring check cannot tell "Pinned Tasks"
  # from the bare "Pinned" it replaced. Whole-text also catches an empty label,
  # which a presence check would not.
  defp label_text(section) do
    case Regex.run(~r/<p[^>]*>\s*([^<]*?)\s*<\/p>/s, section) do
      [_, text] -> text |> String.split() |> Enum.join(" ")
      _ -> nil
    end
  end

  defp pinned_block(sidebar), do: section_by(sidebar, ~s(data-section-key="pinned"))
  defp dm_section(sidebar), do: section_by(sidebar, ~s(data-section-key="dms"))

  defp client_section(sidebar) do
    section_by(sidebar, ~s(data-section-id="#{acme_section().id}"))
  end

  # ── Mobile surfaces ─────────────────────────────────────────────────────
  #
  # The desktop rail is `hidden lg:flex`, so below `lg` the Pinned block does
  # not render at all. Pinned conversations reach mobile through two other
  # surfaces, both of which read the same `@channel_sections.pinned` list.

  # The horizontally-scrollable chip strip above the message list. Requires an
  # active space, so callers must land on a concrete chat route.
  defp mobile_strip(html) do
    case Regex.run(~r/<nav[^>]*data-role="mobile-pinned-strip".*?<\/nav>/s, html) do
      [match] -> match
      _ -> nil
    end
  end

  # The Pinned section inside the mobile "Conversations" drawer. Both this and
  # the desktop block carry `aria-label="Pinned"`; only the desktop one carries
  # `data-section-key`, which is what separates them here.
  #
  # The `<section>` anchor matters: the mobile chip strip above the message
  # list is a `<nav aria-label="Pinned">` and is a different surface.
  defp drawer_pinned_section(html) do
    ~r/<section[^>]*aria-label="Pinned"[^>]*>.*?<\/section>/s
    |> Regex.scan(html)
    |> Enum.map(&hd/1)
    |> Enum.reject(&String.contains?(&1, ~s(data-section-key="pinned")))
    |> List.first()
  end

  # ── Reorder helpers (task 019fe987) ─────────────────────────────────────

  # The rows of a block, top to bottom, by the space id each carries.
  #
  # `data-space-id` appears more than once per row (the wrapper, then the
  # row's own controls), always CONSECUTIVELY, so `dedup` collapses each row
  # to one id while still catching two different rows that render the same
  # conversation twice.
  defp pinned_order(nil), do: []

  defp pinned_order(slice) do
    ~r/data-space-id="([0-9a-fA-F-]{36})"/
    |> Regex.scan(slice)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.dedup()
  end

  # One move button's whole opening tag, found by BOTH its role and the space
  # it moves. Matching on attribute presence rather than on a fixed attribute
  # ORDER: the order HEEx emits them in is not part of the contract.
  defp move_button(nil, _space_id, _role), do: nil

  defp move_button(slice, space_id, role) do
    ~r/<button[^>]*>/
    |> Regex.scan(slice)
    |> Enum.map(&hd/1)
    |> Enum.find(fn tag ->
      String.contains?(tag, ~s(data-role="#{role}")) and
        String.contains?(tag, ~s(phx-value-space_id="#{space_id}"))
    end)
  end

  defp aria_label(nil), do: nil

  defp aria_label(tag) do
    case Regex.run(~r/aria-label="([^"]*)"/, tag) do
      [_, label] -> label
      _ -> nil
    end
  end

  # Occurrences of a literal inside a slice. Used with a PREDICTED number
  # written into the test, so a check that quietly matches nothing (or the
  # whole page) shows up as a disagreement instead of a pass.
  defp count(nil, _needle), do: 0

  defp count(slice, needle), do: slice |> String.split(needle) |> length() |> Kernel.-(1)

  # The drawer, open, in personal-edit mode. Edit mode also clears
  # `@drawer_query`, which is the state the drawer's reorder chrome is gated
  # on, so the order of these two clicks is not interchangeable.
  defp drawer_in_edit_mode(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()

    html = render_click(view, "toggle_sidebar_edit", %{})
    {view, html}
  end

  # How many pinned SECTIONS a slice renders.
  #
  # The count is the only assertion that can tell one block from two, and it
  # is the whole point of this task. No string check can do it: both of the
  # headings this merge replaced ("Pinned Channels" and "Pinned Tasks")
  # contained the word "Pinned", so `=~ "Pinned"` and `refute =~ "Pinned"` are
  # each satisfied by both the before and the after shape.
  #
  # Matched on the OPENING TAG and on the `Pinned` PREFIX of the accessible
  # name, so the count survives a later copy change and still catches a
  # re-split into two differently-named blocks. Anchored to `<section>`, which
  # excludes the `<nav aria-label="Pinned">` chip strip on mobile.
  defp pinned_section_count(html) do
    ~r/<section[^>]*aria-label="Pinned[^"]*"/
    |> Regex.scan(html)
    |> length()
  end

  defp open_mobile_drawer(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

    view
    |> element(~s(button[phx-click="toggle_mobile_browser"]))
    |> render_click()

    render(view)
  end

  # A row or chip that rendered `{space.name}` for a DM produces a lone glyph
  # and an empty label, because a DM row has no `name`. This is the shape the
  # mobile surfaces shipped before the fix, and the thing worth asserting
  # against directly: a person rendered as an unnamed channel.
  defp nameless_hash_rows(slice) do
    slice
    |> rows()
    |> Enum.map(&row_text/1)
    |> Enum.filter(&(&1 == "#" or &1 == ""))
  end

  # Every `<a>` in a slice, raw.
  defp rows(nil), do: []

  defp rows(slice) do
    ~r/<a[^>]*>.*?<\/a>/s
    |> Regex.scan(slice)
    |> Enum.map(&hd/1)
  end

  defp row_containing(slice, text) do
    slice |> rows() |> Enum.find(&String.contains?(&1, text))
  end

  # Every row's visible text, IN RENDER ORDER. Asserting the whole list is
  # what makes an ordering claim non-vacuous: `assert block =~ "Task"` and
  # `assert block =~ "Channel"` both pass in either order, and an index
  # comparison alone passes for a row that rendered its glyph and no label.
  defp row_texts(slice), do: slice |> rows() |> Enum.map(&row_text/1)

  # Where a row sits in its block, by a fragment of its visible text.
  defp row_index(slice, text) do
    slice |> rows() |> Enum.find_index(&String.contains?(&1, text))
  end

  # A row's visible text, tags stripped and whitespace collapsed. Asserting on
  # this catches a stray glyph AND an empty label in one assertion, which the
  # presence-only form does not.
  defp row_text(html) do
    html
    |> strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_tags(html), do: String.replace(html, ~r/<[^>]*>/s, "")

  # The `class` attribute of the row link for one space, within a slice.
  defp row_class(nil, _space_id), do: nil

  defp row_class(slice, space_id) do
    case Regex.run(
           ~r/<a[^>]*href="[^"]*#{Regex.escape(space_id)}[^"]*"[^>]*class="([^"]*)"/s,
           slice
         ) do
      [_, class] -> class
      _ -> row_class_by_slug(slice, space_id)
    end
  end

  # Channels navigate by slug, not id, so fall back to matching the row by
  # its `data-channel-id` wrapper or by scanning every anchor in the slice.
  defp row_class_by_slug(slice, _space_id) do
    case Regex.run(~r/<a[^>]*class="([^"]*channel-row[^"]*)"/s, slice) do
      [_, class] -> class
      _ -> nil
    end
  end

  # ── 1. A pinned CHANNEL lifts out of its client section ─────────────────

  describe "pinning a channel" do
    test "renders in the Pinned block and is ABSENT from its client section", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      other = create_channel("stays-put")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      sidebar = rail(conn)
      block = pinned_block(sidebar)
      client = client_section(sidebar)

      assert block, "expected a Pinned block to render"
      assert block =~ "Gen-migration"

      # The absence half. Presence alone passes for an implementation that
      # COPIES the row into the block instead of lifting it.
      refute client =~ "Gen-migration",
             "pinned channel is still rendered in its client section: copied, not lifted"

      # The section itself is intact. Lifting one channel must not empty it.
      assert client =~ "Stays-put"
      refute block =~ "Stays-put"
    end

    test "survives a channel switch, so every recompute site passes the pin set", %{conn: conn} do
      # Miss one recompute site and the block empties itself on the next
      # navigation, which reads to a user as the pin having failed to save.
      {conn, user} = authed(conn)
      pinned = create_channel("pinned-one")
      elsewhere = create_channel("elsewhere")

      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_rail(conn)

      html = render(live_redirect_to(view, conn, elsewhere))
      sidebar = desktop_sidebar(html)

      assert pinned_block(sidebar) =~ "Pinned-one"
      refute client_section(sidebar) =~ "Pinned-one"
    end
  end

  # Navigate the live view to another channel and return the same view.
  defp live_redirect_to(_view, conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    view
  end

  # ── 2. A pinned DM lifts out of the Direct Messages section ─────────────

  describe "pinning a direct message" do
    test "renders in the Pinned block and is ABSENT from the DM section", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")
      _other_dm = create_dm(user, "Robin Park")

      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      sidebar = rail(conn)
      block = pinned_block(sidebar)
      dms = dm_section(sidebar)

      assert block =~ "Alex Rivera"

      refute dms =~ "Alex Rivera",
             "pinned DM is still rendered in the Direct Messages section: copied, not lifted"

      # The unpinned DM stays where it belongs.
      assert dms =~ "Robin Park"
      refute block =~ "Robin Park"
    end
  end

  # ── 3. Unpinning returns each to its OWN home section ───────────────────

  describe "unpinning" do
    test "a channel returns to its client section, not to the DM section", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("returns-home")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, false)

      sidebar = rail(conn)

      assert client_section(sidebar) =~ "Returns-home"
      refute dm_section(sidebar) =~ "Returns-home"
      refute pinned_block(sidebar)
    end

    test "a DM returns to the DM section, not to a client section", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Saru Designer")

      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, false)

      sidebar = rail(conn)

      assert dm_section(sidebar) =~ "Saru Designer"
      refute client_section(sidebar) =~ "Saru Designer"
      refute pinned_block(sidebar)
    end
  end

  # ── 4. Row identity: a channel is `#` + name, a person is a name ────────

  describe "row identity inside the block" do
    test "a channel row carries the hash and a DM row is a bare name", %{conn: conn} do
      # The rail already renders a DM as a bare name in the Direct Messages
      # section, with no glyph and no avatar. An avatar here made the same
      # conversation look like two different things depending on which section
      # it happened to be sitting in.
      {conn, user} = authed(conn)
      channel = create_channel("build-log")
      dm = create_dm(user, "Alex Rivera")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      block = pinned_block(rail(conn))
      channel_row = row_containing(block, "Build-log")
      dm_row = row_containing(block, "Alex Rivera")

      assert channel_row, "expected a pinned row for the channel"
      assert dm_row, "expected a pinned row for the DM"

      # The channel keeps its marker.
      assert channel_row =~ ~s(data-role="pinned-row-hash")
      assert row_text(channel_row) == "# Build-log"

      # The person does not. Asserting the row's whole visible text, rather
      # than just the absence of the marker, is what makes this non-vacuous:
      # an EMPTY row also has no hash, and an empty row is precisely the bug
      # the mobile surfaces shipped. The name has to be there too.
      refute dm_row =~ ~s(data-role="pinned-row-hash")
      assert row_text(dm_row) == "Alex Rivera"

      # No avatar anywhere in the block. `initials/1` takes the first two
      # whitespace-separated words, so a group DM labelled
      # "Alex Rivera, Alexandra ..." rendered "RM" and was indistinguishable
      # from a private DM with Alex.
      refute block =~ ~s(data-role="pinned-row-avatar")
      refute block =~ "human-avatar"

      # The person's name still starts where the channel's does: the row holds
      # a 20px slot in place of the glyph, so the name column stays straight.
      # A blank slot beside rows that visibly carry a `#` reads as "no hash
      # here"; it is not space held for a marker that never arrives.
      assert dm_row =~ ~s(data-role="pinned-row-indent")

      # One flat list: no sub-grouping into People / Channels, and no type
      # label competing with the conversation name.
      refute block =~ "People"
      refute block =~ ">DM<"
      refute block =~ ">Channel<"

      labels = Regex.scan(~r/class="channel-section-label"/, block)

      assert length(labels) == 1,
             "the block must carry exactly one heading, got #{length(labels)}"
    end
  end

  # ── 5. Empty state renders nothing at all ───────────────────────────────

  describe "empty state" do
    test "a user with no pins renders no Pinned block and no PINNED label", %{conn: conn} do
      # Day one for every rail in the company: channels and DMs both present,
      # nothing pinned. The top of a 260px rail is too expensive to spend on
      # a placeholder for a feature nobody has adopted yet.
      {conn, user} = authed(conn)
      create_channel("general")
      _dm = create_dm(user, "Unrelated Person")

      sidebar = rail(conn)

      refute pinned_block(sidebar)

      # Counted, not string-matched. A `refute sidebar =~ "Pinned"` here could
      # never fail once the merged block's own heading is that word, and the
      # two headings it replaced both contained it too.
      assert pinned_section_count(sidebar) == 0,
             "the Pinned block rendered its heading with nothing to put under it"
    end
  end

  # ── The block's label ───────────────────────────────────────────────────

  describe "block label" do
    test "the desktop block is labelled Pinned", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      sidebar = rail(conn)
      header = section_header(pinned_block(sidebar))

      # Exact equality, not `=~`. A substring check on "Pinned" passes on the
      # bare word AND on both of the two-block headings it replaced.
      assert row_text(header) == "Pinned"

      # The section's accessible name has to move with the visible one, or a
      # screen-reader user and a sighted user are looking at differently
      # named regions.
      assert Regex.run(~r/aria-label="([^"]*)"/, pinned_block(sidebar)) |> Enum.at(1) ==
               "Pinned"
    end

    test "the mobile drawer's section carries the same label", %{conn: conn} do
      # Two surfaces or neither. A rename on one is a rename that a phone user
      # never sees.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      html = open_mobile_drawer(conn, channel)
      section = drawer_pinned_section(html)

      assert section, "expected a Pinned section in the mobile drawer"
      assert label_text(section) == "Pinned"
    end
  end

  # ── 6. No reserved gutter, no client colour (v3) ────────────────────────

  describe "the block holds no client colour and reserves no space for one" do
    test "a pinned channel row carries the same classes as it does in its client section",
         %{conn: conn} do
      # Plan v2 told the implementer to leave room on the row's left edge for
      # a client colour marker. That task was cancelled, and reserved space
      # with nothing in it reads as a rendering bug. The pinned row must be
      # the same row, with the same padding, as it is anywhere else.
      {conn, user} = authed(conn)
      channel = create_channel("same-row")
      # A second channel is the one the view lands on, so `same-row` is never
      # the active row and never picks up `.channel-row--active`.
      create_channel("aaa-landing")

      unpinned_class = rail(conn) |> client_section() |> row_class(channel.id)

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      pinned_class = rail(conn) |> pinned_block() |> row_class(channel.id)

      assert pinned_class == unpinned_class,
             "pinned row classes #{inspect(pinned_class)} differ from the same channel in its client section #{inspect(unpinned_class)}"

      # And explicitly: no reserved gutter, no colour token, no dot.
      block = rail(conn) |> pinned_block()
      refute block =~ "channel-section-color-dot"

      for token <- ["hooli", "initech", "acme", "vandelay-ind", "globex"] do
        refute block =~ "bg-#{token}-dot",
               "client colour token #{token} leaked into the Pinned block"
      end

      refute Regex.match?(~r/class="[^"]*channel-row[^"]*\bp[ls]-\d/, block),
             "a left-padding utility on the pinned row means a gutter is being reserved"
    end

    test "a pinned row that is the active channel keeps the standard active treatment",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("active-pin")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")
      block = html |> desktop_sidebar() |> pinned_block()

      assert block =~ "channel-row--active",
             "selection inside the Pinned block must not be special-cased"
    end
  end

  # ── The block has no chrome ─────────────────────────────────────────────

  describe "block chrome" do
    test "the PINNED label carries no icon, no fill and no collapse control", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("no-chrome")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      # Scoped to the HEADER, not the whole block. The claim is about the
      # label's chrome, and the block's ROWS legitimately carry an icon —
      # stage 3 put the unpin control there. A block-wide refute would fail
      # on a row control, which is not what this test is about.
      header = section_header(pinned_block(rail(conn)))

      assert header =~ "channel-section-label"
      refute header =~ "hero-"
      refute header =~ "channel-section-collapse"

      # The block itself still has no surface treatment and no collapse
      # control anywhere in it.
      block = pinned_block(rail(conn))
      refute block =~ "channel-section-collapse"
      refute block =~ "aria-expanded"
    end
  end

  # The `<div class="channel-section-header">` of a section: the label and
  # whatever chrome sits beside it, and nothing from the rows below.
  defp section_header(nil), do: ""

  defp section_header(section) do
    case Regex.run(~r/<div[^>]*class="[^"]*channel-section-header[^"]*".*?<\/div>/s, section) do
      [match] -> match
      _ -> ""
    end
  end

  # ── Mobile surfaces carry the same row identity ─────────────────────────
  #
  # Wiring the pin set into `channel_sections/4` switched on two mobile
  # surfaces that had been dead since they were written, because every caller
  # passed an empty set. Neither branched on kind, so a pinned DM rendered
  # `{space.name}`, which for a DM is nil: a person appeared as an unnamed
  # CHANNEL. The absence assertions below are the ones that catch that.

  describe "mobile pinned strip" do
    test "a channel chip carries the hash and a DM chip is a bare name", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("mobile-chan")
      dm = create_dm(user, "Alex Rivera")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")
      strip = mobile_strip(html)

      assert strip, "expected the mobile pinned strip to render"

      channel_chip = row_containing(strip, "Mobile-chan")
      dm_chip = row_containing(strip, "Alex Rivera")

      assert channel_chip, "expected a chip for the pinned channel"
      assert dm_chip, "expected a chip for the pinned DM"

      assert channel_chip =~ ~s(data-role="pinned-row-hash")
      assert row_text(channel_chip) == "# Mobile-chan"

      # Same pairing as desktop: no marker AND the name is present. Asserting
      # the whole text is what stops an empty chip passing the "no hash" half.
      refute dm_chip =~ ~s(data-role="pinned-row-hash")
      assert row_text(dm_chip) == "Alex Rivera"

      refute strip =~ ~s(data-role="pinned-row-avatar")
      refute strip =~ "human-avatar"

      assert nameless_hash_rows(strip) == [],
             "the strip renders a pinned conversation with no label: #{inspect(nameless_hash_rows(strip))}"
    end

    test "the strip carries neither the bookmark icon nor an avatar", %{conn: conn} do
      # Every chip in the strip is a pin, so a pin icon on all of them carries
      # no information. The hash is what varies.
      {conn, user} = authed(conn)
      channel = create_channel("mobile-icon")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, _view, html} = live(conn, ~p"/chat/#{channel.slug}")
      strip = mobile_strip(html)

      refute strip =~ "hero-bookmark-solid"
      refute strip =~ "human-avatar"
    end
  end

  describe "mobile conversations drawer" do
    test "a pinned DM renders its display name, not a bare hash", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("drawer-chan")
      dm = create_dm(user, "Alex Rivera")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      section = conn |> open_mobile_drawer(channel) |> drawer_pinned_section()

      assert section, "expected a Pinned section in the mobile drawer"

      channel_row = row_containing(section, "Drawer-chan")
      dm_row = row_containing(section, "Alex Rivera")

      assert channel_row, "expected a drawer row for the pinned channel"
      assert dm_row, "expected a drawer row for the pinned DM"

      assert channel_row =~ ~s(data-role="pinned-row-hash")
      assert row_text(channel_row) == "# Drawer-chan"

      # The worst of the three surfaces before the fix: a person rendering as
      # a `#` with no name read as an unnamed CHANNEL, the wrong object type
      # rather than a missing label. Both halves are asserted together.
      refute dm_row =~ ~s(data-role="pinned-row-hash")
      assert row_text(dm_row) == "Alex Rivera"
      assert dm_row =~ ~s(data-role="pinned-row-indent")

      refute section =~ ~s(data-role="pinned-row-avatar")
      refute section =~ "human-avatar"

      assert nameless_hash_rows(section) == [],
             "the drawer renders a pinned conversation as a bare glyph: #{inspect(nameless_hash_rows(section))}"
    end
  end

  # ── ONE block, three kinds of row (task 019feec6-73d9) ──────────────────
  #
  # The rail carried two adjacent pinned blocks until 2026-08-10: "Pinned
  # Channels" from the viewer's preferences and "Pinned Tasks" from
  # `task_chat_pins`. Robin pinned a task from the Tasks page, went to Chat
  # and found its execution log in her rail — pinning a task is the same act
  # as pinning a channel, so it is one need and one block.
  #
  # Every test below asserts the section COUNT rather than the presence or
  # absence of a heading string. Both of the old headings contained the word
  # "Pinned", so no string check can tell one block from two.

  describe "one Pinned block" do
    test "the desktop rail renders exactly one pinned section", %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("one-block-chan")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "One Block Task")

      sidebar = rail(conn)

      # The fixture holds BOTH kinds of pin, so a rail that still renders them
      # in separate blocks counts 2 here. Expected: 1.
      assert pinned_section_count(sidebar) == 1,
             "expected one pinned section in the rail, got #{pinned_section_count(sidebar)}"

      assert label_text(pinned_block(sidebar)) == "Pinned"
    end

    test "the mobile drawer renders exactly one pinned section", %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("one-block-drawer")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "One Block Drawer Task")

      html = open_mobile_drawer(conn, channel)

      # The desktop rail is in the same DOM (hidden below `lg`), so the page
      # holds exactly two pinned sections: one per surface. Counting the page
      # and the rail separately pins down WHICH surface split, if one does.
      assert pinned_section_count(desktop_sidebar(html)) == 1

      assert pinned_section_count(html) == 2,
             "expected one pinned section per surface, got #{pinned_section_count(html)} on the page"

      assert label_text(drawer_pinned_section(html)) == "Pinned"
    end

    test "the one block holds a channel, a person and a task conversation",
         %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("three-kinds")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      seed_pinned_task_for(user, "Three Kinds Task")

      sidebar = rail(conn)
      block = pinned_block(sidebar)

      assert pinned_section_count(sidebar) == 1
      assert block, "expected the merged Pinned block to render"

      # Each row's WHOLE visible text. A presence check would pass on a row
      # that rendered a glyph and an empty label, which is the exact bug the
      # mobile surfaces shipped when this list first mixed kinds.
      assert row_text(row_containing(block, "Three-kinds")) == "# Three-kinds"
      assert row_text(row_containing(block, "Alex Rivera")) == "Alex Rivera"
      assert row_text(row_containing(block, "Three Kinds Task")) == "Three Kinds Task"

      # The task row keeps its own glyph, and it is the only thing that marks
      # it as a different kind of row.
      task_row = row_containing(block, "Three Kinds Task")
      assert task_row =~ "hero-clipboard-document-list-mini"
      refute task_row =~ ~s(data-role="pinned-row-hash")

      # One heading over all three. No sub-headings, no kind labels.
      assert length(Regex.scan(~r/class="channel-section-label"/, block)) == 1
      refute block =~ ">Task<"
      refute block =~ ">Channel<"
      refute block =~ ">DM<"
    end

    test "a pinned channel is still LIFTED out of its client section", %{conn: conn} do
      # Presence in the merged block alone passes for an implementation that
      # renders the row twice — once in the block, once at home, each with its
      # own unread pill.
      {conn, user} = authed(conn)

      channel = create_channel("lifted-chan")
      create_channel("stays-home")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "Lifted Task")

      sidebar = rail(conn)

      assert pinned_block(sidebar) =~ "Lifted-chan"

      refute client_section(sidebar) =~ "Lifted-chan",
             "pinned channel is still rendered in its client section: copied, not lifted"

      # A task conversation was never in a client section, so it needs no
      # lifting — and the section it was never in is still whole.
      assert client_section(sidebar) =~ "Stays-home"
    end
  end

  # ── Reordering the block (task 019fe987) ────────────────────────────────
  #
  # The assertion that matters in here is the PERSISTED order after a move.
  # A handler that accepts the event and writes nothing re-renders a block
  # still holding every row in some order, so any check that only asks "did
  # the page survive" passes it. Each test below reads
  # `Sidebar.list_pinned_space_ids/1` back out of preferences AND asserts the
  # rendered order, and the two must agree.

  describe "reordering the Pinned block" do
    test "an arrow move persists the new order and the desktop rail renders it",
         %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("alpha-one")
      beta = create_channel("beta-two")
      gamma = create_channel("gamma-three")

      for space <- [alpha, beta, gamma],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})

      # Predicted before running: gamma moves above beta, so the stored list
      # and the rail both read [alpha, gamma, beta].
      html = render_click(view, "move_pinned", %{"space_id" => gamma.id, "direction" => "up"})

      assert Sidebar.list_pinned_space_ids(user.id) == [alpha.id, gamma.id, beta.id]

      assert html |> desktop_sidebar() |> pinned_block() |> pinned_order() ==
               [alpha.id, gamma.id, beta.id]
    end

    test "a drag drop persists the new order and the desktop rail renders it",
         %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("drag-alpha")
      beta = create_channel("drag-beta")
      gamma = create_channel("drag-gamma")

      for space <- [alpha, beta, gamma],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})

      # The payload ChannelMembershipDrag pushes: the dragged id plus the
      # order the client just drew. Gamma dragged to the top.
      html =
        render_hook(view, "pinned_reordered", %{
          "space_id" => gamma.id,
          "ordered_ids" => [gamma.id, alpha.id, beta.id]
        })

      assert Sidebar.list_pinned_space_ids(user.id) == [gamma.id, alpha.id, beta.id]

      assert html |> desktop_sidebar() |> pinned_block() |> pinned_order() ==
               [gamma.id, alpha.id, beta.id]
    end

    test "a move down persists, so the handler is not a one-direction stub", %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("down-alpha")
      beta = create_channel("down-beta")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})
      render_click(view, "move_pinned", %{"space_id" => alpha.id, "direction" => "down"})

      assert Sidebar.list_pinned_space_ids(user.id) == [beta.id, alpha.id]
    end

    test "the mobile drawer renders the new order after a move", %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("drawer-alpha")
      beta = create_channel("drawer-beta")
      gamma = create_channel("drawer-gamma")

      for space <- [alpha, beta, gamma],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {view, _html} = drawer_in_edit_mode(conn, alpha)

      html = render_click(view, "move_pinned", %{"space_id" => gamma.id, "direction" => "up"})

      assert Sidebar.list_pinned_space_ids(user.id) == [alpha.id, gamma.id, beta.id]

      assert html |> drawer_pinned_section() |> pinned_order() ==
               [alpha.id, gamma.id, beta.id]
    end

    test "a move naming a space that is no longer pinned changes nothing", %{conn: conn} do
      # A second tab unpinned it between the render and the drop. The rail
      # ignores the event rather than raising or shuffling the block.
      {conn, user} = authed(conn)
      alpha = create_channel("stale-alpha")
      beta = create_channel("stale-beta")
      stranger = create_channel("stale-stranger")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})

      html =
        render_hook(view, "pinned_reordered", %{
          "space_id" => stranger.id,
          "ordered_ids" => [stranger.id, alpha.id, beta.id]
        })

      assert Sidebar.list_pinned_space_ids(user.id) == [alpha.id, beta.id]

      assert html |> desktop_sidebar() |> pinned_block() |> pinned_order() ==
               [alpha.id, beta.id]
    end
  end

  describe "reorder chrome appears only in edit mode" do
    test "the desktop block carries no handle and no arrows at rest", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("rest-state-chan")
      dm = create_dm(user, "Alex Rivera")

      for space <- [channel, dm],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, html} = live_rail(conn)
      block = html |> desktop_sidebar() |> pinned_block()

      assert block, "expected the desktop Pinned block"
      refute block =~ "channel-row-grab"
      refute block =~ "move_pinned"
      # The glyph itself, not only the class: a handle rendered with the wrong
      # class still squeezes the name it sits beside.
      refute block =~ "⠿"

      # And the row still reads as its name, whole. One assertion that catches
      # a stray glyph AND an emptied label, which marker-absence does not.
      assert block |> row_containing("Alex Rivera") |> row_text() == "Alex Rivera"

      # Same block in edit mode. Predicted: 2 rows × 2 buttons = 4 move
      # controls, and 2 grab handles.
      edit_block =
        view |> render_click("toggle_sidebar_edit", %{}) |> desktop_sidebar() |> pinned_block()

      assert count(edit_block, ~s(phx-click="move_pinned")) == 4
      assert count(edit_block, "channel-row-grab") == 2
    end

    test "the mobile drawer carries no arrows at rest", %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("drawer-rest-alpha")
      beta = create_channel("drawer-rest-beta")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      browse = conn |> open_mobile_drawer(alpha) |> drawer_pinned_section()

      assert browse, "expected the drawer's Pinned section"
      refute browse =~ "move_pinned"

      # Edit mode. Predicted: 2 rows × 2 buttons = 4.
      {_view, edit_html} = drawer_in_edit_mode(conn, alpha)
      edit = drawer_pinned_section(edit_html)

      assert count(edit, ~s(phx-click="move_pinned")) == 4
      assert count(edit, ~s(phx-value-direction="up")) == 2
      assert count(edit, ~s(phx-value-direction="down")) == 2
    end
  end

  describe "move controls name what they move" do
    test "a DM's arrows carry the person's name, not a bare Move up", %{conn: conn} do
      # A bare "Move up" is meaningless in a list of identical controls, and a
      # DM is the case that breaks first: its label comes from
      # `sidebar_display_name/2`, not from `space.name`, which is nil for a DM.
      # An implementation reaching for `space.name` renders "Move  up" and
      # passes any check that only asserts the verb.
      {conn, user} = authed(conn)
      dm = create_dm(user, "Alex Rivera")
      channel = create_channel("named-arrows-chan")

      for space <- [dm, channel],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)

      block =
        view |> render_click("toggle_sidebar_edit", %{}) |> desktop_sidebar() |> pinned_block()

      assert block |> move_button(dm.id, "pinned-move-down") |> aria_label() ==
               "Move Alex Rivera down"

      # The channel beside it, so the DM assertion is not passing on a string
      # every row happens to share.
      assert block |> move_button(channel.id, "pinned-move-up") |> aria_label() ==
               "Move Named-arrows-chan up"
    end

    test "boundary arrows are disabled rather than hidden", %{conn: conn} do
      # Disabled, not hidden, so focus order stays stable as a row travels to
      # an end of the list.
      {conn, user} = authed(conn)
      first = create_channel("boundary-first")
      last = create_channel("boundary-last")

      for space <- [first, last],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      {:ok, view, _html} = live_rail(conn)

      block =
        view |> render_click("toggle_sidebar_edit", %{}) |> desktop_sidebar() |> pinned_block()

      assert move_button(block, first.id, "pinned-move-up") =~ "disabled"
      refute move_button(block, first.id, "pinned-move-down") =~ "disabled"
      refute move_button(block, last.id, "pinned-move-up") =~ "disabled"
      assert move_button(block, last.id, "pinned-move-down") =~ "disabled"
    end
  end

  # ── The task rows are a floor a conversation cannot cross (019fe987) ────
  #
  # Robin, 2026-08-12, choosing between commingling the two pin models and
  # keeping them apart: "I lean towards #2 - it's essentially two separate
  # lists so makes me think to not commingle the interactions too much."
  #
  # Asserted on the PERSISTED list, not on the render. A render can only show
  # what it was handed, so a check there passes for a server that wrote
  # something else and re-rendered from a stale assign. The stored list is
  # what survives a reload, and it is where a cross-table write would show
  # up: `chat_pinned_spaces` holds conversation ids only, because a task pin
  # is a row in `task_chat_pins`.

  describe "a conversation cannot be ordered into or above the task rows" do
    test "a drag payload claiming a slot above a task row lands at the top of the conversations",
         %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("floor-alpha")
      beta = create_channel("floor-beta")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      %{space: task_space} = seed_pinned_task_for(user, "Floor Task")

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})

      # The hostile payload: beta claims the very top of the block, ABOVE the
      # task row. A real client cannot draw this — the hook filters locked
      # rows out of the order it computes — so this is the server being asked
      # to honour it directly, with the client's guard removed.
      render_hook(view, "pinned_reordered", %{
        "space_id" => beta.id,
        "ordered_ids" => [beta.id, task_space.id, alpha.id]
      })

      # Predicted before running: beta lands at index 0 of the CONVERSATIONS,
      # which is as high as it goes, and the task id never enters the pref.
      persisted = Sidebar.list_pinned_space_ids(user.id)

      assert persisted == [beta.id, alpha.id],
             "the clamp did not hold: #{inspect(persisted)}"

      refute task_space.id in persisted,
             "a task id was written into chat_pinned_spaces, which is a cross-table reorder"
    end

    test "an arrow move cannot lift the top conversation past a task row", %{conn: conn} do
      # The keyboard path shares every line of persistence with the drag, but
      # it resolves its own direction, so it gets its own assertion.
      {conn, user} = authed(conn)
      alpha = create_channel("arrow-floor-alpha")
      beta = create_channel("arrow-floor-beta")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      %{space: task_space} = seed_pinned_task_for(user, "Arrow Floor Task")

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})
      render_click(view, "move_pinned", %{"space_id" => alpha.id, "direction" => "up"})

      persisted = Sidebar.list_pinned_space_ids(user.id)

      assert persisted == [alpha.id, beta.id],
             "the top conversation moved on a no-op arrow: #{inspect(persisted)}"

      refute task_space.id in persisted
    end

    test "the top conversation's Move up is disabled even with a task row above it",
         %{conn: conn} do
      # The boundary is `move_index` against `move_count`, the row's place
      # among the CONVERSATIONS. Counting the block's rows instead would leave
      # this button live and point it at a destination it is not allowed to
      # have.
      {conn, user} = authed(conn)
      alpha = create_channel("bound-alpha")
      beta = create_channel("bound-beta")

      for space <- [alpha, beta],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      seed_pinned_task_for(user, "Bound Task")

      {:ok, view, _html} = live_rail(conn)

      block =
        view |> render_click("toggle_sidebar_edit", %{}) |> desktop_sidebar() |> pinned_block()

      assert move_button(block, alpha.id, "pinned-move-up") =~ "disabled",
             "the top conversation can be moved up, so the arrows are counting the task rows"

      assert move_button(block, beta.id, "pinned-move-down") =~ "disabled"
    end

    test "a task row carries no reorder controls at all", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("chrome-chan")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Chrome Task")

      {:ok, view, _html} = live_rail(conn)

      block =
        view |> render_click("toggle_sidebar_edit", %{}) |> desktop_sidebar() |> pinned_block()

      refute move_button(block, task_space.id, "pinned-move-up"),
             "a task row offers a Move up, so it reads as hand-orderable"

      refute move_button(block, task_space.id, "pinned-move-down"),
             "a task row offers a Move down, so it reads as hand-orderable"

      # Anti-vacuity for the two refutes: the conversation row in the same
      # block DOES carry them, so they are not passing because edit mode
      # failed to open or the block failed to render.
      assert move_button(block, channel.id, "pinned-move-up"),
             "no move controls anywhere, so the refutes above prove nothing"
    end
  end

  # ── Rendered order IS stored order (019fe987 regression guard) ──────────
  #
  # The bug this catches, stated so a later reader does not undo it: the
  # block used to render `Enum.reverse/1` of the stored conversation list,
  # because pins are stored append-ordered while the block wanted to read
  # newest-first. A drag resolves a move by finding the dragged id's
  # SUCCESSOR in the order the client drew and inserting before it in the
  # STORED list. If the render reverses and the resolution does not, "after"
  # on screen is "before" in storage: the user drags a row up and it persists
  # a move down.
  #
  # These assert the two lists are the same SEQUENCE after a move, on both
  # surfaces, with a task row present so the conversation filtering is
  # exercised at the same time. Asserting the rendered order alone would not
  # catch it — a reversing render of a reversed write looks correct on screen
  # and is wrong in the database.

  describe "rendered order matches persisted order after a move" do
    test "on the desktop rail", %{conn: conn} do
      {conn, user} = authed(conn)
      alpha = create_channel("mirror-alpha")
      beta = create_channel("mirror-beta")
      gamma = create_channel("mirror-gamma")

      for space <- [alpha, beta, gamma],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      %{space: task_space} = seed_pinned_task_for(user, "Mirror Task")

      {:ok, view, _html} = live_rail(conn)
      render_click(view, "toggle_sidebar_edit", %{})

      html = render_click(view, "move_pinned", %{"space_id" => gamma.id, "direction" => "up"})

      persisted = Sidebar.list_pinned_space_ids(user.id)
      assert persisted == [alpha.id, gamma.id, beta.id]

      rendered = html |> desktop_sidebar() |> pinned_block() |> pinned_order()

      # One assertion carrying both halves: the task row leads, and the
      # conversation rows below it are the stored list in the stored order.
      assert rendered == [task_space.id | persisted],
             "the rail does not render the stored order. rendered #{inspect(rendered)}, stored #{inspect(persisted)}"
    end

    test "in the mobile drawer", %{conn: conn} do
      # Both surfaces or neither. An earlier stage on this stack wired the
      # rail, left the drawer rendering rows that could not do the thing, and
      # reached a human approval gate before anyone noticed.
      {conn, user} = authed(conn)
      alpha = create_channel("mirror-drawer-alpha")
      beta = create_channel("mirror-drawer-beta")
      gamma = create_channel("mirror-drawer-gamma")

      for space <- [alpha, beta, gamma],
          do: {:ok, _} = Sidebar.set_space_pinned(user.id, space.id, true)

      %{space: task_space} = seed_pinned_task_for(user, "Mirror Drawer Task")

      {view, _html} = drawer_in_edit_mode(conn, alpha)

      html = render_click(view, "move_pinned", %{"space_id" => gamma.id, "direction" => "up"})

      persisted = Sidebar.list_pinned_space_ids(user.id)
      assert persisted == [alpha.id, gamma.id, beta.id]

      rendered = html |> drawer_pinned_section() |> pinned_order()

      assert rendered == [task_space.id | persisted],
             "the drawer does not render the stored order. rendered #{inspect(rendered)}, stored #{inspect(persisted)}"
    end
  end

  # ── Task rows lead the block (task 019feec6-73d9) ───────────────────────
  #
  # Robin, 2026-08-11: "if I'm working on a task and I deliberately pin, I
  # would want to have that as easiest to access while I'm on the go / on my
  # phone." Tasks sat at the BOTTOM when the two blocks were first merged.
  # Putting them on top also makes the rail agree with the mobile chip strip,
  # which already iterates `@pinned_task_spaces` before
  # `@channel_sections.pinned`.
  #
  # The cost is accepted: a task row removes itself when its task hits done
  # or cancelled, so every conversation row below it shifts up. No animation,
  # no placeholder, no notice — Robin's call.

  describe "task rows come first" do
    test "the desktop rail renders the pinned task ABOVE the pinned channel", %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("ordering-chan")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "Ordering Task")

      block = pinned_block(rail(conn))

      assert block, "expected the merged Pinned block to render"

      # The WHOLE ordered list of row texts. Presence assertions pass in
      # either order, and an index comparison alone passes for a row that
      # rendered a glyph and an empty label.
      assert row_texts(block) == ["Ordering Task", "# Ordering-chan"],
             "the Pinned block is not task-first: #{inspect(row_texts(block))}"
    end

    test "the mobile drawer renders the same order", %{conn: conn} do
      # Two surfaces or neither. An ordering change on the rail alone is a
      # change the phone user Robin described never sees.
      {conn, user} = authed(conn)

      channel = create_channel("ordering-drawer")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "Ordering Drawer Task")

      section = conn |> open_mobile_drawer(channel) |> drawer_pinned_section()

      assert section, "expected a Pinned section in the mobile drawer"

      assert row_texts(section) == ["Ordering Drawer Task", "# Ordering-drawer"],
             "the drawer's Pinned section is not task-first: #{inspect(row_texts(section))}"
    end

    test "the task still leads when a channel AND a person are pinned too", %{conn: conn} do
      # Asserted by INDEX rather than by exact list: the order of the two
      # conversation rows relative to each other is a separate question (they
      # carry no pin timestamp to sort on), and this test is about the
      # task-versus-conversation boundary only.
      {conn, user} = authed(conn)

      channel = create_channel("lead-chan")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      seed_pinned_task_for(user, "Leading Task")

      block = pinned_block(rail(conn))

      assert length(rows(block)) == 3,
             "expected three pinned rows, got #{inspect(row_texts(block))}"

      assert row_index(block, "Leading Task") == 0,
             "the task row is not first: #{inspect(row_texts(block))}"

      assert row_index(block, "Lead-chan") > 0
      assert row_index(block, "Alex Rivera") > 0
    end
  end

  # ── One glyph for a task conversation (task 019feec6-73d9) ──────────────
  #
  # The chip strip marked a task with `hero-map-pin-mini` while both rail
  # surfaces used `hero-clipboard-document-list-mini`: one concept, two
  # glyphs, decided by which surface the reader happened to be on. The glyph
  # is the ONLY thing distinguishing the three kinds of pinned row, so it is
  # the one thing that cannot vary by surface.

  describe "the task glyph" do
    test "the rail row, the drawer row and the mobile chip all carry the same glyph",
         %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("glyph-chan")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      seed_pinned_task_for(user, "Glyph Task")

      # One render carries all three surfaces: the drawer overlay, the rail
      # (in the DOM, hidden below `lg`) and the chip strip in the main pane.
      html = open_mobile_drawer(conn, channel)

      surfaces = [
        {"rail row", html |> desktop_sidebar() |> pinned_block() |> row_containing("Glyph Task")},
        {"drawer row", html |> drawer_pinned_section() |> row_containing("Glyph Task")},
        {"mobile chip", html |> mobile_strip() |> row_containing("Glyph Task")}
      ]

      for {surface, markup} <- surfaces do
        assert markup, "no #{surface} rendered for the pinned task"

        assert markup =~ "hero-clipboard-document-list-mini",
               "the #{surface} does not carry the task glyph"

        refute markup =~ "hero-map-pin-mini",
               "the #{surface} still carries the old pin glyph"
      end

      # And nowhere else in the strip either — the channel chip never had a
      # glyph of its own, so a surviving `hero-map-pin-mini` anywhere in this
      # element is a task marker that was missed.
      refute mobile_strip(html) =~ "hero-map-pin-mini",
             "hero-map-pin-mini survives somewhere in the mobile pinned strip"
    end
  end

  describe "unread counts inside the merged block" do
    test "a pinned task conversation still resolves its unread count", %{conn: conn} do
      # `@pinned_task_spaces` is merged into `@spaces`, and that merge is what
      # subscribes the LiveView to the task space's PubSub topic. Drop it and
      # unread silently stops working for task conversations while every
      # render-only test stays green.
      {conn, user} = authed(conn)

      %{space: space} = seed_pinned_task_for(user, "Noisy Task")
      seed_unread_for(user, space, 3)

      # Asserted BEFORE the render check, and this order is the point:
      # `unread_counts_for_user/1` drops zero counts entirely, so on a fixture
      # that produced no unread the pill assertion below would be vacuous.
      counts = Chat.unread_counts_for_user(user.id)

      assert Map.get(counts, space.id, 0) == 3,
             "fixture produced #{Map.get(counts, space.id, 0)} unread, expected 3 — the render assertion below would be vacuous"

      block = pinned_block(rail(conn))
      row = row_containing(block, "Noisy Task")

      assert row, "expected the pinned task conversation to render a row"
      assert row_text(row) == "Noisy Task 3"
      assert row =~ "channel-row-unread-pill"
    end
  end

  describe "the vanishing row" do
    test "completing the task removes its row and nothing marks the departure",
         %{conn: conn} do
      # Robin, explicitly: "I want it out of my Chat view so that I don't have
      # to manually close it." No animation, no toast, no tombstone.
      {conn, user} = authed(conn)

      channel = create_channel("outlives-the-task")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{task: task} = seed_pinned_task_for(user, "Finishing Task")

      assert pinned_block(rail(conn)) =~ "Finishing Task"

      {:ok, task} = Tasks.transition_task_status(task, "in_progress")
      {:ok, _task} = Tasks.transition_task_status(task, "done")

      sidebar = rail(conn)
      block = pinned_block(sidebar)

      refute block =~ "Finishing Task",
             "a done task's conversation is still pinned in the rail"

      # The block survives with the rest of its rows, still as ONE section.
      assert block =~ "Outlives-the-task"
      assert pinned_section_count(sidebar) == 1

      # Nothing is left behind to explain the removal.
      refute block =~ "hero-x-circle"
      refute sidebar =~ "task finished"
      refute sidebar =~ "no longer pinned"
    end
  end

  # Real unread for `user` in `space`: the viewer joins with no read cursor,
  # someone else posts. `count_unread/3` excludes the viewer's own messages
  # and `unread_counts_for_user/1` reads off the viewer's participant row, so
  # both participants are required for the count to be non-zero.
  defp seed_unread_for(user, space, count) do
    {:ok, _viewer} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Someone Else",
        joined_at: DateTime.utc_now()
      })

    for n <- 1..count do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "message #{n}"
        })
    end

    :ok
  end
end
