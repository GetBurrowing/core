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

  ## What task 019ff8ba stage 1 moved

  Marlowe, 2026-08-13, taking Option C off the design canvas: the pin leaves
  the row in EVERY mode. An ordinary row now carries one three-dot trigger
  and nothing else, and the pin is the first item in the menu that trigger
  opens.

  The three properties above still hold, but two of them now describe two
  different elements. Resting visibility is the TRIGGER's property, since the
  trigger is what sits on the row. Reaching the pin costs a menu-open step,
  and the pin keeps `data-role="pin-control"`, its `data-space-id` and its
  desired-next-state payload wherever it renders, so `pin_control_for/2`
  finds it in the menu unchanged.

  Stage 1 shipped one exception: a Pinned-block row kept its `hero-x-mark` on
  the row beside the trigger, because Marlowe had asked for a visible way out of
  the block on 2026-08-12. She reversed that on 2026-08-13 with a reason: "for
  pinned items, it's a little weird to see an 'x' with 3-dots menu, so we
  should keep the interaction more consistent and just have a 3-dot menu where
  one of the actions for a pinned item is to unpin it." Every row in the rail
  carries a three-dot menu and nothing else, pinned rows included, and the
  unpin is the menu's first item. The pinned-row tests below moved with it.

  Pinned TASK rows are in the same rule ("task - unpin since it gets pinned
  from a diff page"). They had no trigger at all in stage 1, on the reasoning
  that their menu would be empty; the unpin IS the item, and it is the only
  one. Their tests are section 5 below.

  The menu renders at the TEMPLATE ROOT, outside `<aside id="chat-sidebar">`,
  so it is never inside a `rail/1` slice. A rail-scoped assertion about a row
  therefore still means what it says — and it is why every absence assertion
  here is paired, in the same test, with a positive control. "The x is gone
  from the pinned row" is equally true of a rail that stopped rendering pinned
  rows at all, so each one names the row it is talking about and then reaches
  the action through that row's menu.
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
  alias Platform.Tenancy.OrgMembership

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

  # An Acme admin, which is the viewer the arrange-mode section below uses.
  # Marlowe reported this bug as an admin, and an admin's menu is the LONGEST
  # one — it is the only viewer whose row menu holds "Move to organisation…" —
  # so a menu-parity assertion made as an admin covers the shorter menus too.
  defp admin_authed(conn) do
    user = insert_user(System.unique_integer([:positive]))

    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: acme_org().id,
        role: "admin"
      })
    )

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  defp acme_section do
    Enum.find(Sidebar.list_active_default_sections(), &(&1.org_id == acme_org().id))
  end

  defp create_channel(slug) do
    {:ok, ch} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel",
        org_id: acme_org().id
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

  # A pinned TASK row. Its pin lives in `task_chat_pins`, not in the viewer's
  # preferences, so it cannot be seeded through `Sidebar.set_space_pinned/3`
  # like the conversation rows above — `ChatPins.pin/3` is what materialises
  # the task-exec space AND the pin row together.
  defp seed_pinned_task_for(user, title) do
    {:ok, project} =
      Tasks.create_project(%{name: "Pin Control Project #{System.unique_integer([:positive])}"})

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
    section_by(sidebar, ~s(data-section-id="#{acme_section().id}"))
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

  # ── The row's overflow trigger and the menu it opens (019ff8ba stage 1) ──

  defp row_actions_triggers(nil), do: []

  defp row_actions_triggers(slice) do
    ~r/<button[^>]*data-role="row-actions-trigger".*?<\/button>/s
    |> Regex.scan(slice)
    |> Enum.map(&hd/1)
  end

  defp trigger_for(slice, space_id) do
    slice |> row_actions_triggers() |> Enum.find(&String.contains?(&1, space_id))
  end

  # The pinned-TASK unpin. A different contract from `pin-control` — a task
  # comes off through `unpin_task_from_chat` and `task_chat_pins`, not through
  # `toggle_pinned` and the viewer's preferences — so it keeps its own role,
  # the one the row's own button carried before the menu took it over.
  defp task_unpins(nil), do: []

  defp task_unpins(slice) do
    ~r/<button[^>]*data-role="pinned-task-rail-unpin".*?<\/button>/s
    |> Regex.scan(slice)
    |> Enum.map(&hd/1)
  end

  defp task_unpin_for(slice, space_id) do
    slice |> task_unpins() |> Enum.find(&String.contains?(&1, space_id))
  end

  # The open menu's own markup. Sliced with LazyHTML rather than a regex: the
  # dialog nests divs, so a non-greedy match to the first `</div>` would cut
  # it off before the items. The menu renders at the template root, outside
  # `<aside id="chat-sidebar">`, so `rail/1` never contains it.
  # `query/2`, not `filter/2`: filter keeps ROOT nodes that match the
  # selector, and the roots of a rendered page are `<html>` and friends.
  defp menu(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="row-actions-dialog"]))
    |> LazyHTML.to_html()
  end

  # Click one row's trigger and return the menu that opened. The two-step is
  # the cost Marlowe accepted with Option C: pinning is two clicks now.
  defp open_menu(view, space_id) do
    view
    |> element(~s(button[data-role="row-actions-trigger"][data-space-id="#{space_id}"]))
    |> render_click()
    |> menu()
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

  # ── The row's control set, in document order (019ff8ba stage 2) ─────────
  #
  # Every control a rail row can carry, each keyed on the attribute that
  # IDENTIFIES it rather than on a class, so a restyle does not silently
  # rename a control out of this list. The three that stage 1 took off the
  # row are still listed: their job here is to fail the equality below if one
  # of them comes back.
  @row_control_markers [
    {~s(class="channel-row-grab"), :grab},
    {~s(phx-value-direction="up"), :move_up},
    {~s(phx-value-direction="down"), :move_down},
    {~s(data-role="pin-control"), :pin},
    {~s(data-role="rail-row-actions-hide"), :hide},
    {~s(data-role="move-to-org-trigger"), :move_to_org},
    {~s(data-role="row-actions-trigger"), :trigger}
  ]

  # An ORDERED, EXACT list of the controls one row carries. Deliberately not a
  # presence check plus a pile of refutes: one equality is the positive
  # control and the absence assertion at once. A row that stopped rendering
  # yields `[]` and fails, which is the property the refutes on their own
  # cannot have.
  defp row_controls(slice, space_id) do
    wrap = row_wrap(slice, space_id) || ""

    @row_control_markers
    |> Enum.flat_map(fn {marker, name} ->
      case :binary.match(wrap, marker) do
        {position, _length} -> [{position, name}]
        :nomatch -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # One row's move buttons, keyed on the event contract (`move_channel` plus
  # the channel id) rather than on a `data-role` invented for the test. The
  # event and its two values are what the keyboard reorder path actually is.
  defp move_button(slice, space_id, direction) do
    slice
    |> row_wrap(space_id)
    |> Kernel.||("")
    |> then(
      &Regex.run(
        ~r/<button[^>]*phx-value-direction="#{direction}".*?<\/button>/s,
        &1
      )
    )
    |> case do
      [match] -> match
      _ -> nil
    end
  end

  # The open menu's items, in order, by role. Includes the Close action: it is
  # one of the menu's buttons and a mode that dropped it would be a real
  # difference between the two menus.
  defp menu_item_roles(menu) do
    ~r/<button[^>]*data-role="([^"]+)"/s
    |> Regex.scan(menu)
    |> Enum.map(fn [_full, role] -> role end)
  end

  # Personal-edit mode, pushed directly. The entry point (the header's
  # overflow menu) is `chat_live_edit_layout_test.exs`'s subject; what is
  # under test here is what a ROW renders once the mode is on.
  defp enter_arrange_mode(view), do: render_click(view, "toggle_sidebar_edit", %{})

  # ── 1. The control renders on a CHANNEL row in normal mode ──────────────

  describe "the control on a channel row" do
    test "the row carries the trigger, and the pin is one menu-open away", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, html} = live_rail(conn)
      sidebar = desktop_sidebar(html)
      client = client_section(sidebar)

      assert trigger_for(client, channel.id),
             "no row-actions trigger on the channel row in normal mode"

      # The half that would otherwise pass for a no-op. Option C takes the pin
      # off the row in EVERY mode, so a build that merely ADDED the trigger
      # beside it has not done the thing Marlowe asked for.
      refute pin_control_for(client, channel.id),
             "the pin still renders on the row beside the trigger"

      # Normal mode, proven rather than assumed: the edit-mode affordances
      # that gate other row controls are absent from this render.
      refute sidebar =~ "channel-row-wrap--editing"
      refute sidebar =~ "channel-row-grab"
      refute sidebar =~ "channel-row-move-button"

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pin is off the row and not in the menu either: it is unreachable"
    end

    test "the accessible name carries the channel's name, not a bare verb", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      label =
        view
        |> open_menu(channel.id)
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
    test "the row carries the trigger, and the pin is one menu-open away", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, html} = live_rail(conn)
      dms = desktop_sidebar(html) |> dm_section()

      assert trigger_for(dms, dm.id),
             "no row-actions trigger on the Direct Messages row: the control shipped for channels only"

      refute pin_control_for(dms, dm.id),
             "the pin still renders on the DM row beside the trigger"

      assert pin_control_for(open_menu(view, dm.id), dm.id),
             "the pin is off the DM row and not in its menu either"
    end

    test "the accessible name carries the person's display name", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, _html} = live_rail(conn)

      label =
        view
        |> open_menu(dm.id)
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

  @trigger_resting_class "channel-row-actions-button"

  describe "resting visibility" do
    test "an unpinned channel row's trigger has no reveal gate, and holds the pin",
         %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, html} = live_rail(conn)
      trigger = desktop_sidebar(html) |> client_section() |> trigger_for(channel.id)

      assert trigger, "no row-actions trigger on the channel row"

      class = attr(trigger, "class")

      # Exact equality, not a pair of refutes. A refute list has to enumerate
      # every reveal variant someone might add back; equality catches any of
      # them, including one spelled differently. This is the assertion that
      # moved: resting visibility is now the TRIGGER's property, because the
      # trigger is what sits on the row.
      assert class == @trigger_resting_class,
             "the trigger carries more than its resting class: #{inspect(class)}"

      # The pin's class is legitimately not `channel-row-pin-button` here — a
      # labelled menu item is not a 24px icon box — so what is asserted is
      # that the ACTION is reachable rather than what it looks like.
      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pin action is not reachable through the row's menu"
    end

    test "an unpinned DM row's trigger has no reveal gate, and holds the pin", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")

      {:ok, view, html} = live_rail(conn)
      trigger = desktop_sidebar(html) |> dm_section() |> trigger_for(dm.id)

      assert trigger, "no row-actions trigger on the Direct Messages row"
      assert attr(trigger, "class") == @trigger_resting_class

      # The DM half of the accessible name asserted alongside the resting
      # class, in one test: a DM's label comes from `sidebar_row_label/2` and
      # a participants query, not from `space.name`, so a control with an
      # empty target is a distinct failure and one this surface is
      # specifically prone to. It is asserted on the trigger AND on the pin,
      # since both now carry the name and they resolve it separately.
      assert attr(trigger, "aria-label") == "More actions for Rowan Ellis"

      pin = view |> open_menu(dm.id) |> pin_control_for(dm.id)
      assert attr(pin, "aria-label") == "Pin Rowan Ellis"
    end

    test "no row control anywhere in the rail is gated behind hover alone", %{conn: conn} do
      # Scoped to the CONTROLS, not to the rail: a whole-rail grep for
      # "opacity-0" hits nothing today, and would hit any future control with
      # its own reveal, which is out of scope here.
      #
      # Counts asserted first, and they are the anti-vacuity guard: an empty
      # list satisfies every `refute` in the loop below, so a control that
      # vanished from the rail entirely — the worse bug — would pass.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      _dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Hovering Task")

      sidebar = rail(conn)
      triggers = row_actions_triggers(sidebar)

      # Three rows, three triggers, and one control on each of them. THE
      # POSITIVE CONTROL for the two refutations under it: without a count the
      # pair passes for a rail that renders no rows at all.
      assert length(triggers) == 3,
             "expected a trigger on the pinned channel, the pinned task and the DM row, got #{length(triggers)}"

      # Both of the row-level unpin controls are off the rows now (Marlowe,
      # 2026-08-13). Refuted for BOTH contracts, since the two pinned rows
      # carried a different one each.
      assert pin_controls(sidebar) == [],
             "a conversation pin control is still on a rail row"

      assert task_unpins(sidebar) == [],
             "the pinned task row still carries its own x beside the trigger"

      # And the actions survived the move, which is the other half of a
      # refutation about a control that was supposed to RELOCATE.
      {:ok, view, _html} = live_rail(conn)

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pinned channel's unpin did not land in its menu"

      render_click(view, "close_row_actions", %{})

      assert task_unpin_for(open_menu(view, task_space.id), task_space.id),
             "the pinned task's unpin did not land in its menu"

      for control <- triggers do
        refute attr(control, "class") =~ "opacity-0",
               "a row control is still transparent at rest: #{inspect(attr(control, "class"))}"

        refute attr(control, "class") =~ "hover:opacity",
               "a row control still reveals on hover: #{inspect(attr(control, "class"))}"

        refute attr(control, "class") =~ "group-hover",
               "a row control reveals on a group-hover variant: #{inspect(attr(control, "class"))}"
      end
    end
  end

  # ── 4. A pinned row carries the trigger, and its menu carries the x ─────
  #
  # Three of Marlowe's reviews land here, on DIFFERENT objects. Keeping them
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
  # already there and already announced "Unpin <name>", so this was not an
  # absent control. It was one she could not read: a map-pin on an
  # already-pinned row points the wrong way.
  #
  # 2026-08-13, on the row that resulted: "for pinned items, it's a little
  # weird to see an 'x' with 3-dots menu, so we should keep the interaction
  # more consistent and just have a 3-dot menu where one of the actions for a
  # pinned item is to unpin it." So the x is OFF the row and is the menu's
  # first item. The glyph still forks on state, one step further in.
  #
  # Every test in this section that refutes something on the row names that
  # row first and then opens its menu, because "the x is gone from the pinned
  # row" is equally true of a rail with no pinned rows in it.

  describe "the control on a pinned row" do
    test "the row carries the trigger at rest, and the unpin is one menu-open away",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, html} = live_rail(conn)
      block = desktop_sidebar(html) |> pinned_block()
      trigger = trigger_for(block, channel.id)

      assert trigger, "no row-actions trigger on the pinned row"

      # Exact equality, as on every other row: it is the assertion that
      # catches a reveal variant being added back, including one spelled
      # differently from the two the refutes below would enumerate.
      assert attr(trigger, "class") == @trigger_resting_class,
             "the pinned row's trigger carries more than its resting class: #{inspect(attr(trigger, "class"))}"

      refute pin_control_for(block, channel.id),
             "the pinned row still wears its own x beside the trigger"

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the unpin is off the pinned row and not in its menu either: it is unreachable"
    end

    test "the menu's item wears the x, the same glyph the pinned-task rows use", %{conn: conn} do
      # The 2026-08-12 fix, one step further in. A map-pin here reads as "pin"
      # on a row that is already pinned, which is how the way out came to look
      # like an absence in the first place.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _html} = live_rail(conn)
      control = view |> open_menu(channel.id) |> pin_control_for(channel.id)

      assert control, "no unpin item in the pinned row's menu"

      assert control =~ "hero-x-mark",
             "the pinned row's menu still shows a pin glyph rather than the x: #{inspect(control)}"

      refute control =~ "hero-map-pin",
             "both glyphs render in the pinned row's menu: #{inspect(control)}"
    end

    test "the glyph fork is real: the x for a pinned row, the map-pin for an unpinned one",
         %{conn: conn} do
      # Anti-vacuity for the test above. Swapping the glyph everywhere would
      # pass it while making every unpinned row offer an x, which reads as
      # "remove this channel". Both ends of the fork now render in the same
      # PLACE and differ only by the row the menu was opened from, so both are
      # asserted from a menu.
      {conn, user} = authed(conn)
      pinned = create_channel("gen-migration")
      unpinned = create_channel("stays-put")
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_rail(conn)

      pinned_item = view |> open_menu(pinned.id) |> pin_control_for(pinned.id)

      assert pinned_item =~ "hero-x-mark",
             "a pinned row's menu shows a pin glyph rather than the x: #{inspect(pinned_item)}"

      refute pinned_item =~ "hero-map-pin",
             "both glyphs render in the pinned row's menu: #{inspect(pinned_item)}"

      render_click(view, "close_row_actions", %{})

      unpinned_item = view |> open_menu(unpinned.id) |> pin_control_for(unpinned.id)

      assert unpinned_item =~ "hero-map-pin",
             "an unpinned row's menu item lost its pin glyph: #{inspect(unpinned_item)}"

      refute unpinned_item =~ "hero-x-mark",
             "an unpinned row offers an x, which reads as remove: #{inspect(unpinned_item)}"
    end

    test "one event contract, whichever row's menu it is opened from", %{conn: conn} do
      # The anti-vacuity guard for "one code path". Classes cannot be compared
      # — a labelled menu item is not a 24px icon box — so the assertion is on
      # the thing every caller actually depends on: the role, the target id,
      # the event name, and the DESIRED next state rather than a flip.
      {conn, user} = authed(conn)
      pinned = create_channel("gen-migration")
      unpinned = create_channel("stays-put")
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_rail(conn)

      from_pinned = view |> open_menu(pinned.id) |> pin_control_for(pinned.id)
      render_click(view, "close_row_actions", %{})
      from_unpinned = view |> open_menu(unpinned.id) |> pin_control_for(unpinned.id)

      for {control, space_id, desired, where} <- [
            {from_pinned, pinned.id, "false", "a Pinned-block row's menu"},
            {from_unpinned, unpinned.id, "true", "an unpinned row's menu"}
          ] do
        assert control, "no pin control in #{where}"

        assert attr(control, "phx-click") == "toggle_pinned",
               "#{where} posts #{inspect(attr(control, "phx-click"))}"

        assert attr(control, "data-space-id") == space_id
        assert attr(control, "phx-value-space_id") == space_id

        assert attr(control, "phx-value-pinned") == desired,
               "#{where} posts #{inspect(attr(control, "phx-value-pinned"))} rather than the desired next state"
      end
    end

    test "the removed pinned-STATE marker stays removed, and no glyph replaced it",
         %{conn: conn} do
      # Marlowe's EARLIER review, still binding. What she removed was a FILLED
      # variant used to mark the row as pinned. No fill may come back, and
      # since 2026-08-13 no OUTLINE pin marks the row either — the block's
      # rows carry a trigger and a name.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      block = rail(conn) |> pinned_block()

      # The positive control. Every refutation below is satisfied by a block
      # that rendered nothing at all, so the row is named first.
      assert block =~ ~s(data-space-id="#{channel.id}"),
             "the pinned row is not in the block, so the refutations below prove nothing"

      assert trigger_for(block, channel.id), "the pinned row lost its trigger"

      refute block =~ "hero-map-pin-solid",
             "a filled pin variant is back in the Pinned block"

      refute block =~ "hero-x-mark-solid", "a filled x variant crept in"

      refute block =~ "hero-map-pin",
             "a pin glyph is back on a pinned row: the block's heading already says they are pinned"
    end

    test "the menu item still says Unpin and names the channel", %{conn: conn} do
      # The verb distinction survives the move. It is the only thing left that
      # varies with pinned-ness, so it is the thing most at risk of being
      # collapsed away along with the row control.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _html} = live_rail(conn)
      control = view |> open_menu(channel.id) |> pin_control_for(channel.id)

      assert attr(control, "aria-label") == "Unpin Gen-migration"
    end

    test "a pinned DM's row carries the trigger and its menu reads Unpin with the person's name",
         %{conn: conn} do
      # Asserted for a DM SPECIFICALLY: a DM has no `name` field and its label
      # resolves through `sidebar_display_name/2`, a different helper from the
      # one channel rows use. Reaching for `space.name` renders empty, which
      # has shipped on this surface once, and a channel-only test passes for
      # exactly that bug. Both ends carry the name and resolve it separately,
      # so both are asserted.
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, html} = live_rail(conn)
      block = desktop_sidebar(html) |> pinned_block()
      trigger = trigger_for(block, dm.id)

      assert trigger, "no row-actions trigger on the pinned DM row"
      assert attr(trigger, "class") == @trigger_resting_class
      assert attr(trigger, "aria-label") == "More actions for Rowan Ellis"

      refute pin_control_for(block, dm.id),
             "the pinned DM row still wears its own x beside the trigger"

      control = view |> open_menu(dm.id) |> pin_control_for(dm.id)

      assert control, "no unpin item in the pinned DM's menu"
      assert attr(control, "aria-label") == "Unpin Rowan Ellis"
      assert control =~ "hero-x-mark"
      refute attr(control, "class") =~ "opacity-0"
    end
  end

  # ── 5. A pinned TASK row ────────────────────────────────────────────────
  #
  # Stage 1 gave these rows no trigger, on the reasoning that their menu would
  # be empty: a task pin lives in `task_chat_pins` and comes off through
  # `unpin_task_from_chat`, so `toggle_pinned` is the wrong verb for it, and
  # hide and org filing are meaningless on a task-exec space.
  #
  # Marlowe overrode that on 2026-08-13 and stated the reason the menu holds one
  # item: "task - unpin since it gets pinned from a diff page." So the row's
  # own x moved into the menu exactly as the conversation rows' did, and the
  # rail is one interaction rather than two.

  describe "the control on a pinned task row" do
    test "the row carries the trigger, the x is off the row, and the unpin is in the menu",
         %{conn: conn} do
      {conn, user} = authed(conn)
      %{space: space} = seed_pinned_task_for(user, "Ship The Rail")

      {:ok, view, html} = live_rail(conn)
      block = desktop_sidebar(html) |> pinned_block()

      assert block =~ ~s(data-space-id="#{space.id}"),
             "the pinned task row is not in the block, so the refutation below proves nothing"

      trigger = trigger_for(block, space.id)

      assert trigger,
             "the pinned task row has no trigger: stage 1's exception was not lifted"

      assert attr(trigger, "class") == @trigger_resting_class
      assert attr(trigger, "aria-label") == "More actions for Ship The Rail"

      refute task_unpin_for(block, space.id),
             "the task row still wears its own x beside the trigger"

      assert task_unpin_for(open_menu(view, space.id), space.id),
             "the task's unpin is off the row and not in its menu either: it is unreachable"
    end

    test "the menu holds Unpin and nothing else", %{conn: conn} do
      # The item list forks on the row's kind. A task menu carrying
      # `toggle_pinned` would write the viewer's conversation preferences for a
      # space that is not a conversation, and hide has no way back for it.
      {conn, user} = authed(conn)
      %{space: space} = seed_pinned_task_for(user, "One Item Only")

      {:ok, view, _html} = live_rail(conn)
      menu = open_menu(view, space.id)

      assert task_unpin_for(menu, space.id),
             "the task menu did not open, so the refutations below are vacuous"

      refute menu =~ ~s(phx-click="toggle_pinned"),
             "a task's menu offers the conversation pin, which writes the wrong table"

      refute menu =~ ~s(phx-click="hide_channel"),
             "a task's menu offers hide, which the Hidden drawer cannot reverse for it"

      refute menu =~ ~s(data-role="move-to-org-trigger"),
             "a task's menu offers org filing, which a task-exec space has no use for"
    end

    test "the menu's unpin carries the task id and the row's accessible name", %{conn: conn} do
      {conn, user} = authed(conn)
      %{task: task, space: space} = seed_pinned_task_for(user, "Named Task")

      {:ok, view, _html} = live_rail(conn)
      control = view |> open_menu(space.id) |> task_unpin_for(space.id)

      assert attr(control, "phx-click") == "unpin_task_from_chat",
             "the task item posts #{inspect(attr(control, "phx-click"))}, not the task unpin"

      # The payload key is hyphenated, which is the handler's pattern
      # (`%{"task-id" => task_id}`), and it is the TASK id rather than the
      # space id: `task_chat_pins` is keyed by task.
      assert attr(control, "phx-value-task-id") == task.id,
             "the task item is wired to #{inspect(attr(control, "phx-value-task-id"))} rather than the task id"

      assert attr(control, "aria-label") == "Unpin Named Task from Chat"
    end

    test "clicking it unpins: the row goes, and the pin row goes with it", %{conn: conn} do
      # ANTI-VACUITY. The rendered row disappearing is not enough — a socket
      # that patched only its own assigns shows the same thing — so the
      # `task_chat_pins` row is checked directly.
      {conn, user} = authed(conn)
      %{task: task, space: space} = seed_pinned_task_for(user, "Will Be Unpinned")

      {:ok, view, _html} = live_rail(conn)
      _ = open_menu(view, space.id)

      view
      |> element(~s(button[data-role="pinned-task-rail-unpin"][data-space-id="#{space.id}"]))
      |> render_click()

      refute ChatPins.pinned?(task.id, %{kind: "user", id: user.email}),
             "the click re-rendered the rail but never removed the pin row"

      refute rail(conn) =~ ~s(data-space-id="#{space.id}"),
             "the task row survives a fresh mount"
    end
  end

  # ── 6. Clicking pins, and the row moves ─────────────────────────────────

  describe "clicking the control" do
    test "pins a channel: the row lifts into the Pinned block", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")
      create_channel("stays-put")

      {:ok, view, _html} = live_rail(conn)

      _ = open_menu(view, channel.id)

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

      _ = open_menu(view, dm.id)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{dm.id}"]))
        |> render_click()

      sidebar = desktop_sidebar(html)

      assert pinned_block(sidebar) =~ "Rowan Ellis"
      refute dm_section(sidebar) =~ "Rowan Ellis"
      assert dm_section(sidebar) =~ "Marlowe Quill"
    end

    test "the menu's x unpins a channel: it persists, and the row returns to its client section",
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

      # The unpin is in the menu now, on a pinned row as on every other one
      # (Marlowe, 2026-08-13), so the click needs the row's trigger first.
      _ = open_menu(view, channel.id)

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

    test "the menu's x unpins a DM: it persists, and the row returns to Direct Messages",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Rowan Ellis")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, _html} = live_rail(conn)

      _ = open_menu(view, dm.id)

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

      _ = open_menu(view, channel.id)

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

      _ = open_menu(view, channel.id)

      view
      |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
      |> render_click()

      assert Sidebar.list_pinned_space_ids(user.id) == [channel.id]
      assert rail(conn) |> pinned_block() =~ "Gen-migration"
    end
  end

  # ── 7. Availability: no edit mode gate ──────────────────────────────────

  describe "availability" do
    test "the pin action is reachable in normal mode AND in edit mode", %{conn: conn} do
      # The point survives Option C, and the reason it has to be asserted in
      # both modes has not changed: pinning is how you USE the rail, not an
      # act of rearranging it, so putting it behind "Edit my layout" would
      # add a two-step preamble to it — and dropping it FROM edit mode would
      # strand anyone who is already in there.
      #
      # What moved is where the action lives. It used to be on the row in both
      # modes; it is now in the row's menu in both modes, which is exactly the
      # half of the earlier version that Marlowe's 2026-08-13 change broke.
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pin action is not reachable through the row's menu in normal mode"

      render_click(view, "close_row_actions", %{})
      html = render_click(view, "toggle_sidebar_edit", %{})

      assert desktop_sidebar(html) |> client_section() |> trigger_for(channel.id),
             "the trigger disappeared in edit mode"

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pin action is not reachable through the row's menu in edit mode"
    end
  end

  # ── 8. Arrange mode: the row's control set (019ff8ba stage 2) ───────────
  #
  # Marlowe's report was about arrange mode: for an Acme admin the sub-org channel
  # names read "f...", "e...", "p...". Six controls held a slot on that row —
  # drag, up, down, pin, hide and "Move to organisation…" — and the name got
  # 25px at the rail's 224px width. Stage 1 took the last three off the row in
  # EVERY mode, so arrange mode is four slots now and normal mode is one.
  #
  # Read the section title literally: these are LABELLED PROXIES for one
  # property, WHICH controls the template emits on a row in each mode. A
  # LiveView test renders markup with no CSS, no layout and no focus model, so
  # nothing here can tell a control a person can see from one a stylesheet has
  # hidden, and nothing here measures a pixel. The measured name width and the
  # keyboard behaviour were taken in a real browser and are attached to this
  # stage's manual_approval.
  #
  # What these CAN do is fail when a control appears on, or disappears from, a
  # row where the design says otherwise — which is the whole of what this
  # stage changed and the common way it will regress.

  describe "arrange mode (markup proxy, labelled)" do
    test "PROXY: every sub-org row carries the trigger alone at rest, and drag plus the two move buttons once arranging",
         %{conn: conn} do
      {conn, _user} = admin_authed(conn)
      # Three channels, and the assertion runs on ALL of them rather than on a
      # lucky one: with a single row both move buttons are boundary-disabled,
      # so a one-row test would pass for an implementation that rendered the
      # buttons only when they are disabled.
      channels = Enum.map(~w(gen-migration eng-platform product-design), &create_channel/1)

      {:ok, view, html} = live_rail(conn)
      sidebar = desktop_sidebar(html)

      for channel <- channels do
        assert row_controls(sidebar, channel.id) == [:trigger],
               "#{channel.name} at rest carries more than the trigger: " <>
                 inspect(row_controls(sidebar, channel.id))
      end

      arranging = view |> enter_arrange_mode() |> desktop_sidebar()

      for channel <- channels do
        assert row_controls(arranging, channel.id) == [:grab, :move_up, :move_down, :trigger],
               "#{channel.name} in arrange mode: " <>
                 inspect(row_controls(arranging, channel.id))
      end
    end

    test "PROXY: arrange mode takes nothing away — the trigger survives it and the pin is still in the menu",
         %{conn: conn} do
      # The half that a "four controls render" assertion does not cover.
      # Adding the move controls back could equally have been implemented by
      # swapping the trigger out for them, and the row would still have four
      # controls in arrange mode.
      {conn, _user} = admin_authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      arranging = view |> enter_arrange_mode() |> desktop_sidebar()

      assert row_controls(arranging, channel.id) == [:grab, :move_up, :move_down, :trigger],
             "the row's controls in arrange mode: " <>
               inspect(row_controls(arranging, channel.id))

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pin action is not reachable through the row's menu while arranging"
    end

    test "PROXY: the move buttons are real buttons with no reveal gate, and the boundary ones are disabled rather than dropped",
         %{conn: conn} do
      # WCAG 2.1.1: these are the keyboard alternative to the drag handle, so
      # a hover-gated one is not a quieter control, it is an absent one —
      # Tailwind compiles `hover:` and `group-hover:` inside
      # `@media (hover: hover)`, which never matches on touch. The class is
      # asserted by exact equality for the same reason the trigger's is: a
      # refute list has to enumerate every variant someone might add back.
      {conn, _user} = admin_authed(conn)

      [first, _second, _third] =
        channels = Enum.map(~w(aaa-first bbb-mid ccc-last), &create_channel/1)

      {:ok, view, _html} = live_rail(conn)
      arranging = view |> enter_arrange_mode() |> desktop_sidebar()

      # THE POSITIVE CONTROL for everything below: without it the loop passes
      # for a rail rendering no rows, since `move_button/3` would return nil
      # and `attr/2` answers "" for nil.
      for channel <- channels do
        assert row_controls(arranging, channel.id) == [:grab, :move_up, :move_down, :trigger]
      end

      for channel <- channels, direction <- ~w(up down) do
        button = move_button(arranging, channel.id, direction)

        assert button, "no #{direction} button on #{channel.name}"
        assert button =~ ~s(type="button")

        assert attr(button, "class") == "channel-row-move-button",
               "the #{direction} button carries more than its resting class: " <>
                 inspect(attr(button, "class"))

        assert attr(button, "aria-label") == "Move ##{channel.name} #{direction}",
               "the #{direction} button's accessible name does not carry the verb and the target"
      end

      # Focus order has to stay stable as a row travels to the top, so the
      # boundary button is disabled in place rather than removed. `first` is
      # the top row of the section, and its up button is in the control list
      # asserted above.
      assert move_button(arranging, first.id, "up") =~ "disabled"
    end

    test "the menu holds the same items in the same order in both modes, pin first",
         %{conn: conn} do
      {conn, _user} = admin_authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      resting = view |> open_menu(channel.id) |> menu_item_roles()

      # Pin FIRST, and the whole list asserted rather than just its head: a
      # menu that lost its hide or its org filing on the way into arrange mode
      # is the regression this pins, and only an equality catches it.
      assert resting == [
               "pin-control",
               "rail-row-actions-hide",
               "move-to-org-trigger",
               "row-actions-close"
             ]

      render_click(view, "close_row_actions", %{})
      enter_arrange_mode(view)

      assert view |> open_menu(channel.id) |> menu_item_roles() == resting,
             "the row's menu is not the same menu in arrange mode"
    end
  end

  # ── 9. The menu's chrome, as a MARKUP PROXY and not as proof ────────────
  #
  # Read the name of the test below literally. A LiveView test renders markup;
  # it runs no CSS, no focus model and no key handling, so it cannot tell a
  # working dialog from a broken one. What it CAN do is fail loudly when an
  # attribute the keyboard path depends on is dropped, which is the common way
  # this regresses. The behaviour itself was verified in a real browser and
  # the capture is attached to the stage's manual_approval.

  describe "the menu's chrome (markup proxy, not proof)" do
    test "PROXY ONLY: the trigger and the dialog carry the attributes the keyboard path needs",
         %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, html} = live_rail(conn)

      trigger = desktop_sidebar(html) |> client_section() |> trigger_for(channel.id)

      assert attr(trigger, "data-role") == "row-actions-trigger"
      assert attr(trigger, "aria-haspopup") == "dialog"

      assert attr(trigger, "aria-label") == "More actions for Gen-migration",
             "the trigger's accessible name does not name the conversation"

      full =
        view
        |> element(~s(button[data-role="row-actions-trigger"][data-space-id="#{channel.id}"]))
        |> render_click()

      # The breakpoint split. `lg:contents` rather than `lg:block`, because
      # daisyUI's `.modal` is `display: grid` and a block override breaks its
      # centring — and `.modal-box` has to stay a child of `.modal` to be
      # revealed at all.
      assert full =~ ~s(class="hidden lg:contents"),
             "the desktop menu is not gated to lg and up, so both chromes are live at once"

      menu = menu(full)

      assert menu =~ ~s(data-role="row-actions-dialog")
      assert menu =~ ~s(role="dialog")
      assert menu =~ ~s(aria-modal="true")
      assert menu =~ ~s(aria-labelledby="chat-row-actions-title")

      # Focus in on open, focus back out on Escape and on click-away. The
      # dialog is server-rendered, so closing it removes the focused element
      # and focus would otherwise fall to <body>.
      assert menu =~ "phx-mounted"
      assert menu =~ ~s(phx-key="escape")
      assert menu =~ "pop_focus"
      assert menu =~ "phx-click-away"

      # daisyUI ships `.modal` as `visibility: hidden` and reveals it only
      # under `.modal-open`. All three classes, or none of them.
      assert menu =~ "modal modal-open"
      assert menu =~ "modal-box"
    end
  end
end
