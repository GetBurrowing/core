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

  Robin, 2026-08-13, taking Option C off the design canvas: the pin leaves
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
  the row beside the trigger, because Robin had asked for a visible way out of
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

  ## Burrow redesign 22 stage 2

  The desktop channel rail is deleted, and with it the per-row three-dot
  trigger, its resting class, arrange mode (drag, move up/down) and edit
  mode. Their tests are deleted. What survives is the MENU: right-clicking a
  row in the Chat list (`#chat-list`, beside the conversation at lg) pushes
  `open_row_actions`, which opens the same `row_actions_dialog/1`. The tests
  below open it with `render_hook/3`, the event the `RowContextMenu` hook
  pushes, and read rows off the list's Pinned, Spaces and Direct sections.
  The row-level half of every "relocated, not removed" assertion now says
  the LIST row carries no pin or unpin of its own.
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
  # Robin reported this bug as an admin, and an admin's menu is the LONGEST
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
  # Every assertion below is scoped to one element's own markup. Rows are read
  # inside `#chat-list-scroller`, because the search sheet and popover rows
  # carry the same `chat-list-row` data-role.

  @scroller "#chat-list-scroller"

  defp query(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp to_html_or_nil(nodes) do
    case Enum.to_list(nodes) do
      [] -> nil
      list -> list |> Enum.map(&LazyHTML.to_html/1) |> Enum.join()
    end
  end

  defp list_html(conn) do
    {:ok, _view, html} = live_rail(conn)
    html
  end

  defp section(html, role),
    do: html |> query(~s(#{@scroller} [data-role="#{role}"])) |> to_html_or_nil()

  defp pinned_block(html), do: section(html, "chat-list-pinned")
  defp dm_section(html), do: section(html, "chat-list-direct")
  defp client_section(html), do: section(html, "chat-list-spaces")

  # One space's row link inside a slice, or nil.
  defp row_in(nil, _space_id), do: nil

  defp row_in(slice, space_id) do
    slice
    |> query(~s(a[data-role="chat-list-row"][data-space-id="#{space_id}"]))
    |> to_html_or_nil()
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

  # The pinned-TASK unpin. A different contract from `pin-control` — a task
  # comes off through `unpin_task_from_chat` and `task_chat_pins`, not through
  # `toggle_pinned` and the viewer's preferences — so it keeps its own role.
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
  # it off before the items. `query/2`, not `filter/2`: filter keeps ROOT
  # nodes that match the selector, and the roots of a rendered page are
  # `<html>` and friends.
  defp menu(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="row-actions-dialog"]))
    |> LazyHTML.to_html()
  end

  # Open one row's menu the way the list's `RowContextMenu` hook does (a
  # right-click at lg) and return the menu that opened.
  defp open_menu(view, space_id) do
    view
    |> render_hook("open_row_actions", %{"space_id" => space_id})
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

  # The open menu's items, in order, by role. Includes the dialog's dismiss
  # button: it is one of the menu's buttons.
  defp menu_item_roles(menu) do
    ~r/<button[^>]*data-role="([^"]+)"/s
    |> Regex.scan(menu)
    |> Enum.map(fn [_full, role] -> role end)
  end

  # ── 1. The control on a CHANNEL row ─────────────────────────────────────

  describe "the control on a channel row" do
    test "the list row carries no pin of its own, and the pin is one menu-open away",
         %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, html} = live_rail(conn)
      client = client_section(html)

      # The positive control: the row is there, so the refute means something.
      assert row_in(client, channel.id), "the channel row is not in the list's Spaces section"

      refute pin_control_for(client, channel.id),
             "a pin renders on the list row itself"

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
  end

  # ── 2. The control on a DM row ──────────────────────────────────────────

  describe "the control on a DM row" do
    test "the list row carries no pin of its own, and the pin is one menu-open away",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")

      {:ok, view, html} = live_rail(conn)
      dms = dm_section(html)

      assert row_in(dms, dm.id),
             "the DM row is not in the list's Direct section: the control shipped for channels only"

      refute pin_control_for(dms, dm.id), "a pin renders on the DM list row itself"

      assert pin_control_for(open_menu(view, dm.id), dm.id),
             "the pin is off the DM row and not in its menu either"
    end

    test "the accessible name carries the person's display name", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")

      {:ok, view, _html} = live_rail(conn)

      label =
        view
        |> open_menu(dm.id)
        |> pin_control_for(dm.id)
        |> attr("aria-label")

      assert label == "Pin Alex Rivera",
             "accessible name #{inspect(label)} does not name the person"
    end
  end

  # ── 3. No row in the list carries a pin or unpin; the menus do ──────────
  #
  # The rail's resting-visibility tests (the trigger's exact class) went with
  # the rail's trigger. The relocation half survives.

  describe "relocation" do
    test "no list row carries a pin or an unpin, and every row's menu does", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Hovering Task")

      html = list_html(conn)
      list = html |> query(@scroller) |> to_html_or_nil()

      # THE POSITIVE CONTROL for the two refutations under it: without the
      # rows the pair passes for a list that renders nothing at all.
      for id <- [channel.id, dm.id, task_space.id] do
        assert row_in(list, id), "row #{id} is not in the list"
      end

      assert pin_controls(list) == [], "a conversation pin control is on a list row"
      assert task_unpins(list) == [], "the pinned task row carries its own x"

      {:ok, view, _html} = live_rail(conn)

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the pinned channel's unpin is not in its menu"

      render_click(view, "close_row_actions", %{})

      assert task_unpin_for(open_menu(view, task_space.id), task_space.id),
             "the pinned task's unpin is not in its menu"
    end
  end

  # ── 4. A pinned row's menu carries the x ────────────────────────────────
  #
  # Three of Robin's reviews land here, on DIFFERENT objects.
  #
  # 2026-08-11, on a permanent FILLED pin: "No need to append a pin icon to
  # pinned items. The section header is sufficient." That STATE marker stays
  # removed, and a `refute` below holds that line.
  #
  # 2026-08-12: "remember to add a way for user to unpin just like how pinned
  # tasks have an 'x' to unpin". A map-pin on an already-pinned row points
  # the wrong way.
  #
  # 2026-08-13: "just have a 3-dot menu where one of the actions for a pinned
  # item is to unpin it." So the x is OFF the row and is the menu's first
  # item. The glyph still forks on state, one step further in.

  describe "the control on a pinned row" do
    test "the pinned list row carries no unpin of its own, and the unpin is one menu-open away",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, html} = live_rail(conn)
      block = pinned_block(html)

      assert row_in(block, channel.id), "the pinned row is not in the Pinned section"

      refute pin_control_for(block, channel.id),
             "the pinned row wears its own x"

      assert pin_control_for(open_menu(view, channel.id), channel.id),
             "the unpin is off the pinned row and not in its menu either: it is unreachable"
    end

    test "the menu's item wears the x, the same glyph the pinned-task rows use", %{conn: conn} do
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
      # "remove this channel".
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
      {conn, user} = authed(conn)
      pinned = create_channel("gen-migration")
      unpinned = create_channel("stays-put")
      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _html} = live_rail(conn)

      from_pinned = view |> open_menu(pinned.id) |> pin_control_for(pinned.id)
      render_click(view, "close_row_actions", %{})
      from_unpinned = view |> open_menu(unpinned.id) |> pin_control_for(unpinned.id)

      for {control, space_id, desired, where} <- [
            {from_pinned, pinned.id, "false", "a pinned row's menu"},
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
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      block = conn |> list_html() |> pinned_block()

      # The positive control. Every refutation below is satisfied by a block
      # that rendered nothing at all, so the row is named first.
      assert row_in(block, channel.id),
             "the pinned row is not in the Pinned section, so the refutations below prove nothing"

      refute block =~ "hero-map-pin-solid", "a filled pin variant is back in the Pinned section"
      refute block =~ "hero-x-mark-solid", "a filled x variant crept in"

      refute block =~ "hero-map-pin",
             "a pin glyph is back on a pinned row: the section heading already says they are pinned"
    end

    test "the menu item still says Unpin and names the channel", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _html} = live_rail(conn)
      control = view |> open_menu(channel.id) |> pin_control_for(channel.id)

      assert attr(control, "aria-label") == "Unpin Gen-migration"
    end

    test "a pinned DM's menu reads Unpin with the person's name", %{conn: conn} do
      # Asserted for a DM SPECIFICALLY: a DM has no `name` field and its label
      # resolves through a different helper from the one channel rows use.
      # Reaching for `space.name` renders empty, which has shipped on this
      # surface once, and a channel-only test passes for exactly that bug.
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, html} = live_rail(conn)
      block = pinned_block(html)

      assert row_in(block, dm.id), "the pinned DM is not in the Pinned section"
      refute pin_control_for(block, dm.id), "the pinned DM row wears its own x"

      control = view |> open_menu(dm.id) |> pin_control_for(dm.id)

      assert control, "no unpin item in the pinned DM's menu"
      assert attr(control, "aria-label") == "Unpin Alex Rivera"
      assert control =~ "hero-x-mark"
      refute attr(control, "class") =~ "opacity-0"
    end
  end

  # ── 5. A pinned TASK row ────────────────────────────────────────────────
  #
  # A task pin lives in `task_chat_pins` and comes off through
  # `unpin_task_from_chat`, so `toggle_pinned` is the wrong verb for it, and
  # hide and org filing are meaningless on a task-exec space. Robin, on
  # 2026-08-13: "task - unpin since it gets pinned from a diff page." So the
  # menu holds one item.

  describe "the control on a pinned task row" do
    test "the list row carries no x of its own, and the unpin is in the menu", %{conn: conn} do
      {conn, user} = authed(conn)
      %{space: space} = seed_pinned_task_for(user, "Ship The Rail")

      {:ok, view, html} = live_rail(conn)
      block = pinned_block(html)

      assert row_in(block, space.id),
             "the pinned task row is not in the Pinned section, so the refutation below proves nothing"

      refute task_unpin_for(block, space.id), "the task row wears its own x"

      assert task_unpin_for(open_menu(view, space.id), space.id),
             "the task's unpin is off the row and not in its menu either: it is unreachable"
    end

    test "the menu holds Unpin and nothing else", %{conn: conn} do
      {conn, user} = authed(conn)
      %{space: space} = seed_pinned_task_for(user, "One Item Only")

      {:ok, view, _html} = live_rail(conn)
      menu = open_menu(view, space.id)

      assert task_unpin_for(menu, space.id),
             "the task menu did not open, so the refutations below are vacuous"

      refute menu =~ ~s(phx-click="toggle_pinned"),
             "a task's menu offers the conversation pin, which writes the wrong table"

      refute menu =~ ~s(phx-click="hide_channel"),
             "a task's menu offers hide, which the Hidden list cannot reverse for it"

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
      # `task_chat_pins` row is checked directly, and then a fresh mount.
      {conn, user} = authed(conn)
      %{task: task, space: space} = seed_pinned_task_for(user, "Will Be Unpinned")

      {:ok, view, html} = live_rail(conn)
      assert row_in(pinned_block(html), space.id), "the task row is not in the list to begin with"
      _ = open_menu(view, space.id)

      view
      |> element(~s(button[data-role="pinned-task-rail-unpin"][data-space-id="#{space.id}"]))
      |> render_click()

      refute ChatPins.pinned?(task.id, %{kind: "user", id: user.email}),
             "the click re-rendered the list but never removed the pin row"

      refute conn |> list_html() |> query(@scroller) |> to_html_or_nil() |> row_in(space.id),
             "the task row survives a fresh mount"
    end
  end

  # ── 6. Clicking pins, and the row moves ─────────────────────────────────

  describe "clicking the control" do
    test "pins a channel: the row lifts into the Pinned section", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")
      stays = create_channel("stays-put")

      {:ok, view, _html} = live_rail(conn)

      _ = open_menu(view, channel.id)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
        |> render_click()

      assert row_in(pinned_block(html), channel.id)

      refute row_in(client_section(html), channel.id),
             "the row was copied into Pinned instead of lifted out of Spaces"

      assert row_in(client_section(html), stays.id)
    end

    test "pins a DM: the row lifts out of Direct", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")
      other = create_dm(user, "Robin Park")

      {:ok, view, _html} = live_rail(conn)

      _ = open_menu(view, dm.id)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{dm.id}"]))
        |> render_click()

      assert row_in(pinned_block(html), dm.id)
      refute row_in(dm_section(html), dm.id)
      assert row_in(dm_section(html), other.id)
    end

    test "the menu's x unpins a channel: it persists, and the row returns to Spaces",
         %{conn: conn} do
      # ANTI-VACUITY. Three checks, escalating: the re-rendered page, then the
      # PREFERENCE, then a FRESH mount.
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, html} = live_rail(conn)
      assert row_in(pinned_block(html), channel.id)

      _ = open_menu(view, channel.id)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{channel.id}"]))
        |> render_click()

      refute row_in(pinned_block(html), channel.id)
      assert row_in(client_section(html), channel.id)

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the click re-rendered the list but never wrote the unpin to preferences"

      fresh = list_html(conn)
      refute row_in(pinned_block(fresh), channel.id), "the pin came back on a fresh mount"
      assert row_in(client_section(fresh), channel.id)
    end

    test "the menu's x unpins a DM: it persists, and the row returns to Direct",
         %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, html} = live_rail(conn)
      assert row_in(pinned_block(html), dm.id)

      _ = open_menu(view, dm.id)

      html =
        view
        |> element(~s(button[data-role="pin-control"][data-space-id="#{dm.id}"]))
        |> render_click()

      refute row_in(pinned_block(html), dm.id)
      assert row_in(dm_section(html), dm.id)

      assert Sidebar.list_pinned_space_ids(user.id) == [],
             "the click re-rendered the list but never wrote the unpin to preferences"

      fresh = list_html(conn)
      refute row_in(pinned_block(fresh), dm.id)
      assert row_in(dm_section(fresh), dm.id)
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
      assert conn |> list_html() |> pinned_block() |> row_in(channel.id)
    end
  end

  # ── 7. The menu's items ─────────────────────────────────────────────────
  #
  # The rail's availability-in-edit-mode test and its arrange-mode proxies
  # (row control sets, move buttons) went with the rail's edit and arrange
  # modes. The menu-order half survives.

  describe "the menu's items" do
    test "an admin's channel menu holds pin first, then hide, org filing and dismiss",
         %{conn: conn} do
      # An admin's menu is the LONGEST one — the only viewer whose row menu
      # holds "Move to organisation…" — and only an equality catches a menu
      # that lost an item.
      {conn, _user} = admin_authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      assert view |> open_menu(channel.id) |> menu_item_roles() == [
               "pin-control",
               "rail-row-actions-hide",
               "move-to-org-trigger",
               "row-actions-close"
             ]
    end
  end

  # ── 8. The menu's chrome, as a MARKUP PROXY and not as proof ────────────
  #
  # A LiveView test renders markup; it runs no CSS, no focus model and no key
  # handling, so it cannot tell a working dialog from a broken one. What it
  # CAN do is fail loudly when an attribute the keyboard path depends on is
  # dropped. The rail trigger's own attributes (aria-haspopup, "More actions
  # for …") went with the trigger.

  describe "the menu's chrome (markup proxy, not proof)" do
    test "PROXY ONLY: the dialog carries the attributes the keyboard path needs",
         %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("gen-migration")

      {:ok, view, _html} = live_rail(conn)

      refute has_element?(view, ~s([data-role="row-actions-dialog"])),
             "the dialog is open before any row asked for it"

      full = render_hook(view, "open_row_actions", %{"space_id" => channel.id})

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
