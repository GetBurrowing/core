defmodule PlatformWeb.ChatLivePinControlTest do
  @moduledoc """
  The pin / unpin control on sidebar rows (task 019fd80f stage 3).

  Stage 2 shipped the Pinned block but left pinning reachable only from a
  database call. This is the control that puts it on the row, on CHANNEL
  rows and DM rows alike, in normal mode with no edit mode active.

  Three properties carry the whole feature and each has its own anti-vacuity
  guard:

    * The control exists on BOTH kinds of row. A test that only covers
      channels passes for an implementation that never touched the Direct
      Messages section, which is where this control is entirely new.
    * The accessible name carries the CONVERSATION NAME. Asserting the word
      "Pin" passes for twenty identical controls in one list, which is the
      exact failure the design rules out.
    * The control is VISIBLE AT REST. Asserting that it renders passes for a
      `group-hover`-only implementation, and Tailwind compiles `hover:` and
      `group-hover:` inside `@media (hover: hover)`, so on a touch device
      such a control is unreachable rather than merely quiet. The class is
      asserted by exact equality, which is what catches a reveal variant
      being added back.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "pin-control-#{suffix}@example.com",
      name: "Pin Control #{suffix}",
      oidc_sub: "oidc-pin-control-#{suffix}",
      avatar_url: nil
    })
  end

  defp authed(conn) do
    user = insert_user(System.unique_integer([:positive]))
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp fabrikam_org, do: Tenancy.get_org_by_slug!("fabrikam")

  defp fabrikam_section do
    Enum.find(Sidebar.list_active_default_sections(), &(&1.org_id == fabrikam_org().id))
  end

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: fabrikam_org().id
      })

    ch
  end

  # A DM only reaches the rail through `Chat.list_user_conversations/2`, which
  # joins participants, so the viewer must actually be in it. The other
  # participant's `display_name` is what `sidebar_display_name/2` renders and
  # therefore what the control's accessible name must carry.
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
  #
  # Every assertion below is scoped to one element's own markup. A whole-file
  # or whole-page grep is not a presence check: it passes on a comment, on an
  # unrelated section, and on the mobile drawer.

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

  defp section_by(sidebar, attr) do
    case Regex.run(~r/<section[^>]*#{Regex.escape(attr)}.*?<\/section>/s, sidebar) do
      [match] -> match
      _ -> nil
    end
  end

  defp pinned_block(sidebar), do: section_by(sidebar, ~s(data-section-key="pinned"))
  defp dm_section(sidebar), do: section_by(sidebar, ~s(data-section-key="dms"))

  defp client_section(sidebar) do
    section_by(sidebar, ~s(data-section-id="#{fabrikam_section().id}"))
  end

  # Every pin control in a slice, raw. Buttons never nest, so the non-greedy
  # match to the first closing tag is exact.
  defp pin_controls(nil), do: []

  defp pin_controls(slice) do
    ~r/<button[^>]*data-role="pin-control".*?<\/button>/s
    |> Regex.scan(slice)
    |> Enum.map(&hd/1)
  end

  defp pin_control_for(slice, space_id) do
    slice |> pin_controls() |> Enum.find(&String.contains?(&1, space_id))
  end

  # "" rather than nil for a missing element, so a failing assertion reports
  # the mismatch instead of raising out of `=~`.
  defp attr(nil, _name), do: ""

  defp attr(html, name) do
    case Regex.run(~r/#{Regex.escape(name)}="([^"]*)"/, html) do
      [_, value] -> value
      _ -> nil
    end
  end

  # The row wrapper for one space: the element that pairs the navigate-link
  # and the control as siblings. Matched by its own `data-space-id` so a row
  # in another section can never satisfy the assertion. The wrapper holds an
  # `<a>` and a `<button>` and no nested `<div>`, so the non-greedy match to
  # the first closing tag is exact.
  defp row_wrap(nil, _space_id), do: nil

  defp row_wrap(slice, space_id) do
    case Regex.run(
           ~r/<div[^>]*data-space-id="#{Regex.escape(space_id)}"[^>]*>.*?<\/div>/s,
           slice
         ) do
      [match] -> match
      _ -> nil
    end
  end

  # A slice's visible text, tags stripped and whitespace collapsed. Asserting
  # the whole visible text of a row catches a stray glyph AND an empty label
  # in one line, which a `=~ "name"` presence check does not.
  defp visible_text(nil), do: nil

  defp visible_text(html) do
    html
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Same, with every space removed. Inter-tag whitespace in a HEEx template is
  # a formatting artifact, not a rendered-content property, so a row-identity
  # assertion should not depend on it. Removing spaces still catches a stray
  # glyph and an empty label, which is what the assertion is for.
  defp squashed_text(html), do: html |> visible_text() |> String.replace(" ", "")

  # ── 1. The control renders on a CHANNEL row in normal mode ──────────────

  describe "the control on a channel row" do
    test "renders in normal mode with no edit mode active", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      sidebar = rail(conn)
      client = client_section(sidebar)

      assert pin_control_for(client, channel.id),
             "no pin control on the channel row in normal mode"

      # Normal mode, proven rather than assumed: the edit-mode affordances
      # that gate other row controls are absent from this render.
      refute sidebar =~ "channel-row-wrap--editing"
      refute sidebar =~ "channel-row-grab"
      refute sidebar =~ "channel-row-move-button"
    end

    test "the accessible name carries the channel's name, not a bare verb", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      label =
        rail(conn)
        |> client_section()
        |> pin_control_for(channel.id)
        |> attr("aria-label")

      assert label == "Pin Gen-migration",
             "accessible name #{inspect(label)} does not name the conversation"
    end

    test "the control adds no visible text to the row", %{conn: conn} do
      # The name is the protected fragment. A control that renders a text
      # label competes with it and truncates it.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      wrap =
        rail(conn)
        |> client_section()
        |> row_wrap(channel.id)

      assert squashed_text(wrap) == "#Gen-migration",
             "row wrap text #{inspect(visible_text(wrap))} carries more than the row identity"
    end
  end

  # ── 2. The control renders on a DM row in normal mode ───────────────────
  #
  # The DM rows had no hover affordance of any kind before this stage, so
  # this is a new control there rather than an adjustment to an existing one.

  describe "the control on a DM row" do
    test "renders in normal mode", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      dms = rail(conn) |> dm_section()

      assert pin_control_for(dms, dm.id),
             "no pin control on the Direct Messages row: the control shipped for channels only"
    end

    test "the accessible name carries the person's display name", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      label =
        rail(conn)
        |> dm_section()
        |> pin_control_for(dm.id)
        |> attr("aria-label")

      assert label == "Pin Rowan Ellis",
             "accessible name #{inspect(label)} does not name the person"
    end

    test "the control adds no visible text and no glyph to the DM row", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      wrap = rail(conn) |> dm_section() |> row_wrap(dm.id)

      assert visible_text(wrap) == "Rowan Ellis",
             "DM row wrap text #{inspect(visible_text(wrap))} is not a bare name"
    end
  end

  # ── 3. The control is visible at rest, on touch as much as on a mouse ───
  #
  # Marlowe, 2026-08-11: "when developing pinned channels, use similar
  # interactions as what's used for pinned tasks (hover doesn't work on
  # mobile)." Rowan had already chosen visible-at-rest for the task row's
  # unpin control, so both directions land on the same answer.
  #
  # The control used to carry
  # `opacity-0 focus-within:opacity-100 group-hover/row:opacity-100`. Tailwind
  # compiles the two hover variants inside `@media (hover: hover)`, so on a
  # touch device NEITHER rule matches and the only thing left is `opacity-0`.

  @resting_class "channel-row-pin-button"

  describe "resting visibility" do
    test "an unpinned channel control renders with no reveal gate on it", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      control = rail(conn) |> client_section() |> pin_control_for(channel.id)

      assert control, "no pin control on the channel row"

      class = attr(control, "class")

      # Exact equality, not a pair of refutes. A refute list has to enumerate
      # every reveal variant someone might add back; equality catches any of
      # them, including one spelled differently.
      assert class == @resting_class,
             "the control carries more than its resting class: #{inspect(class)}"
    end

    test "an unpinned DM control renders with no reveal gate on it", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      control = rail(conn) |> dm_section() |> pin_control_for(dm.id)

      assert control, "no pin control on the Direct Messages row"
      assert attr(control, "class") == @resting_class

      # The DM half of the accessible name asserted alongside the resting
      # class, in one test: a DM's label comes from `sidebar_row_label/2` and
      # a participants query, not from `space.name`, so a control that is
      # visible-at-rest with an empty target is a distinct failure and one
      # this surface is specifically prone to.
      assert attr(control, "aria-label") == "Pin Rowan Ellis"
    end

    test "no row control anywhere in the rail is gated behind hover alone", %{conn: conn} do
      # Scoped to the CONTROLS, not to the rail: a whole-rail grep for
      # "opacity-0" hits the sub-org hide button, which is a different
      # control with its own reveal and is out of scope here.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      _dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      controls = rail(conn) |> pin_controls()

      assert length(controls) == 2,
             "expected one control on the pinned channel and one on the DM, got #{length(controls)}"

      for control <- controls do
        refute attr(control, "class") =~ "opacity-0",
               "a pin control is still transparent at rest: #{inspect(attr(control, "class"))}"

        refute attr(control, "class") =~ "hover:opacity",
               "a pin control still reveals on hover: #{inspect(attr(control, "class"))}"
      end
    end
  end

  # ── 4. A pinned row wears the x ─────────────────────────────────────────
  #
  # Two of Marlowe's reviews land here, on DIFFERENT objects. Keeping them
  # apart is the whole reason these tests are worded the way they are.
  #
  # 2026-08-11, on a permanent FILLED pin: "No need to append a pin icon to
  # pinned items. The section header is sufficient." That was a STATE marker,
  # the same glyph in two weights, on rows already grouped under a heading
  # that says they are pinned. It stays removed, and a `refute` below holds
  # that line.
  #
  # 2026-08-12, on the block that resulted: "remember to add a way for user to
  # unpin just like how pinned tasks have an \'x\' to unpin". The way out was
  # already there and already announced "Unpin <name>", so this is not an
  # absent control. It is one she could not read: a map-pin on an
  # already-pinned row points the wrong way, and the pinned-TASK rows nearby
  # use a plain x for the same operation.
  #
  # So the glyph forks on state and nothing else does. Same component, same
  # class, same 24px box, same event contract.

  describe "the control on a pinned row" do
    test "renders at rest, like any other row", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      control = rail(conn) |> pinned_block() |> pin_control_for(channel.id)

      assert control, "no unpin control inside the Pinned block"

      assert attr(control, "class") == @resting_class,
             "the pinned row's control carries a reveal gate the other rows do not: #{inspect(attr(control, "class"))}"
    end

    test "wears the x, the same glyph the pinned-task rows use", %{conn: conn} do
      # The 2026-08-12 fix. A map-pin here reads as "pin" on a row that is
      # already pinned, which is how the way out came to look like an absence.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      control = rail(conn) |> pinned_block() |> pin_control_for(channel.id)

      assert control =~ "hero-x-mark",
             "the pinned row still shows a pin glyph rather than the x: #{inspect(control)}"

      refute control =~ "hero-map-pin",
             "both glyphs render on the pinned row: #{inspect(control)}"
    end

    test "an UNPINNED row keeps the map-pin, so the fork is real", %{conn: conn} do
      # Anti-vacuity for the test above. Swapping the glyph everywhere would
      # pass it while making every unpinned row offer an x, which reads as
      # "remove this channel".
      {conn, _user} = authed(conn)
      channel = create_channel("stays-put")

      control = rail(conn) |> client_section() |> pin_control_for(channel.id)

      assert control =~ "hero-map-pin",
             "an unpinned row lost its pin glyph: #{inspect(control)}"

      refute control =~ "hero-x-mark",
             "an unpinned row offers an x, which reads as remove: #{inspect(control)}"
    end

    test "carries the same classes as the control on an unpinned row", %{conn: conn} do
      # The anti-vacuity guard for "one code path". Asserting only that the
      # resting class is present passes for an implementation that kept a
      # conditional and merely flipped which branch is the visible one.
      {conn, user} = authed(conn)
      pinned = create_channel("gen-migration")
      unpinned = create_channel("stays-put")
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      sidebar = rail(conn)
      pinned_class = sidebar |> pinned_block() |> pin_control_for(pinned.id) |> attr("class")

      unpinned_class =
        sidebar |> client_section() |> pin_control_for(unpinned.id) |> attr("class")

      assert pinned_class == unpinned_class,
             "pinned control classes #{inspect(pinned_class)} differ from an unpinned row's #{inspect(unpinned_class)}"
    end

    test "the removed pinned-STATE marker stays removed", %{conn: conn} do
      # Marlowe's EARLIER review, still binding. What she removed was a FILLED
      # variant used to mark the row as pinned. The x is an action glyph, not
      # a state one, so no fill may come back with it.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      block = rail(conn) |> pinned_block()

      refute block =~ "hero-map-pin-solid",
             "a filled pin variant is back in the Pinned block"

      refute block =~ "hero-x-mark-solid", "a filled x variant crept in"
    end

    test "the accessible name still says Unpin and names the channel", %{conn: conn} do
      # The verb distinction survives the simplification. It is the only
      # thing left that varies with pinned-ness, so it is the thing most at
      # risk of being collapsed away along with the icon.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      control = rail(conn) |> pinned_block() |> pin_control_for(channel.id)

      assert attr(control, "aria-label") == "Unpin Gen-migration"
    end

    test "a pinned DM reads Unpin, names the person, and wears the x", %{conn: conn} do
      # Asserted for a DM SPECIFICALLY: a DM has no `name` field and its label
      # resolves through `sidebar_display_name/2`, a different helper from the
      # one channel rows use. Reaching for `space.name` renders empty, which
      # has shipped on this surface once, and a channel-only test passes for
      # exactly that bug.
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      control = rail(conn) |> pinned_block() |> pin_control_for(dm.id)

      assert control, "no unpin control on the pinned DM row"
      assert attr(control, "class") == @resting_class
      assert attr(control, "aria-label") == "Unpin Rowan Ellis"
      assert attr(control, "title") == "Unpin"
      assert control =~ "hero-x-mark"
      refute attr(control, "class") =~ "opacity-0"
    end
  end

  # ── 5. Clicking pins, and the row moves ─────────────────────────────────

  describe "clicking the control" do
    test "pins a channel: the row lifts into the Pinned block", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")
      create_channel("stays-put")

      {:ok, view, _html} = live_rail(conn)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
        |> render_click()

      sidebar = desktop_sidebar(html)

      assert pinned_block(sidebar) =~ "Gen-migration"

      refute client_section(sidebar) =~ "Gen-migration",
             "the row was copied into the Pinned block instead of lifted out of its section"

      assert client_section(sidebar) =~ "Stays-put"
    end

    test "pins a DM: the row lifts out of Direct Messages", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")
      _other = create_dm(user, "Marlowe Quill")

      {:ok, view, _html} = live_rail(conn)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{dm.id}"]))
        |> render_click()

      sidebar = desktop_sidebar(html)

      assert pinned_block(sidebar) =~ "Rowan Ellis"
      refute dm_section(sidebar) =~ "Rowan Ellis"
      assert dm_section(sidebar) =~ "Marlowe Quill"
    end

    test "the x unpins a channel: it persists, and the row returns to its client section",
         %{conn: conn} do
      # ANTI-VACUITY. Three checks, escalating: the re-rendered page, then the
      # PREFERENCE, then a FRESH mount. A handler that accepts the click and
      # writes nothing still re-renders a page, and a socket that patched only
      # its own assigns still shows the row move. Only the last two can tell
      # the difference.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _html} = live_rail(conn)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
        |> render_click()

      sidebar = desktop_sidebar(html)
      refute pinned_block(sidebar), "the Pinned block should render nothing once empty"
      assert client_section(sidebar) =~ "Gen-migration"

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the click re-rendered the rail but never wrote the unpin to preferences"

      fresh = rail(conn)
      refute pinned_block(fresh), "the pin came back on a fresh mount"
      assert client_section(fresh) =~ "Gen-migration"
    end

    test "the x unpins a DM: it persists, and the row returns to Direct Messages",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, _html} = live_rail(conn)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{dm.id}"]))
        |> render_click()

      sidebar = desktop_sidebar(html)
      refute pinned_block(sidebar)
      assert dm_section(sidebar) =~ "Rowan Ellis"

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the click re-rendered the rail but never wrote the unpin to preferences"

      fresh = rail(conn)
      refute pinned_block(fresh)
      assert dm_section(fresh) =~ "Rowan Ellis"
    end

    test "the event posts the DESIRED next state, so a double-fire is idempotent",
         %{conn: conn} do
      # A toggle that flips whatever it finds turns a duplicated event from a
      # render race into a silent unpin.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      view
      |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
      |> render_click()

      # Re-send the same payload the just-rendered control would send again.
      render_click(view, "toggle_pinned", %{"space_id" => channel.id, "pinned" => "true"})

      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id]
    end

    test "persists the pin so it survives a fresh mount", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      view
      |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
      |> render_click()

      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id]
      assert rail(conn) |> pinned_block() =~ "Gen-migration"
    end
  end

  # ── 6. Availability: no edit mode gate ──────────────────────────────────

  describe "availability" do
    test "the control is not gated behind Edit my layout", %{conn: conn} do
      # The rail renders in normal mode on mount. If the control only appeared
      # under `@sidebar_edit` it would be absent from this render entirely,
      # which is what every assertion above already exercises. This test
      # pins the inverse: turning edit mode ON must not remove it either.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      assert desktop_sidebar(render(view))
             |> client_section()
             |> pin_control_for(channel.id)

      html = render_click(view, "toggle_sidebar_edit", %{})

      assert desktop_sidebar(html) |> client_section() |> pin_control_for(channel.id),
             "the control disappeared in edit mode"
    end
  end
end
