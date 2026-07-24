defmodule PlatformWeb.ChatLiveMobilePinnedStripTest do
  @moduledoc """
  Tests for the mobile Pinned strip (task 019f923b Stage 1).

  The strip is a `lg:hidden` horizontally-scrollable chip row at the top of
  the chat main pane that surfaces the same pinned spaces the desktop rail
  shows — `@pinned_task_spaces` (task-exec pins, `hero-map-pin-mini`) and
  `@channel_sections.pinned` (channel pins, `hero-bookmark-solid`). Without
  it, pinned spaces are unreachable on mobile because `<aside id="chat-sidebar">`
  is `hidden lg:flex`.

  Channel-level pinning is not yet wired end-to-end
  (`channel_sections/4` receives `MapSet.new()` for `pinned_channel_ids` at
  every current call site), so `@channel_sections.pinned` is always `[]` in
  production today. These tests exercise the task-pin path (which IS wired)
  and assert the template also carries the channel-chip skeleton so the
  branch is ready when channel-pinning ships.

  Strip render requires an active_space (`:if={@active_space && !@embedded && …}`) —
  each test navigates to a concrete chat route so the LiveView has a chosen
  space to mount into. Tailwind class assertions (`lg:hidden`, etc.) are
  the mobile-only gate; CSS media-query behavior is browser-side and is
  validated by the task-level e2e_behavior gate rather than here.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins

  defp insert_chat_user(attrs \\ %{}) do
    Repo.insert!(%User{
      email:
        Map.get(
          attrs,
          :email,
          "mobile-pinned-strip-#{System.unique_integer([:positive])}@example.com"
        ),
      name: Map.get(attrs, :name, "Mobile Strip Test User"),
      oidc_sub:
        Map.get(
          attrs,
          :oidc_sub,
          "oidc-mobile-pinned-strip-#{System.unique_integer([:positive])}"
        ),
      avatar_url: Map.get(attrs, :avatar_url)
    })
  end

  defp seed_pinned_task_for(user, opts) do
    title = Keyword.get(opts, :title, "Mobile Strip Task")

    {:ok, project} =
      Tasks.create_project(%{name: "Mobile Strip Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} =
      ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)

    %{task: task, space: space}
  end

  defp seed_channel(slug) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Channel #{slug}",
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  # Reuse the production URL helper so tests lock the exact contract the
  # template's `<.link navigate=>` compiles against — otherwise a helper
  # divergence (e.g. org_id-scoped spaces preferring id over slug) surfaces
  # as a test-only false failure.
  defp nav_target(space), do: PlatformWeb.ChatLive.space_nav_target(space)

  describe "mobile Pinned strip auto-hide" do
    test "strip absent when the user has no pins", %{conn: conn} do
      user = insert_chat_user()
      channel = seed_channel("no-pins")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, html} = live(conn, ~p"/chat/#{nav_target(channel)}")

      refute has_element?(view, "[data-role='mobile-pinned-strip']")

      # No empty header slot either — the strip is fully absent, not empty.
      refute html =~ "data-role=\"mobile-pinned-strip\""
      refute html =~ "aria-label=\"Pinned\""
    end

    test "strip renders when the user has at least one pinned task", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Alpha Task")

      conn = init_test_session(conn, current_user_id: user.id)

      # Navigate INTO the pinned exec space so it becomes @active_space and
      # the mobile strip's `:if={@active_space && !@embedded && …}` gate
      # opens. The strip then renders with the current space highlighted
      # (bg-primary) so a mobile user can see the "you are here" state
      # inside the strip.
      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(space)}")

      assert has_element?(view, "[data-role='mobile-pinned-strip']")

      assert has_element?(
               view,
               "[data-role='mobile-pinned-task-chip'][data-space-id='#{space.id}']"
             )
    end
  end

  describe "mobile Pinned strip mobile-only gate" do
    test "strip root nav carries the `lg:hidden` breakpoint class", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Gate Task")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(space)}")

      strip_html =
        view
        |> element("[data-role='mobile-pinned-strip']")
        |> render()

      # The `lg:hidden` gate is what keeps the strip mobile-only. Losing it
      # would double-render pinned spaces at desktop (once in the rail, once
      # in this strip), which is the exact regression the class prevents.
      assert strip_html =~ "lg:hidden"
      assert strip_html =~ "aria-label=\"Pinned\""
    end
  end

  describe "mobile Pinned strip chip rendering" do
    test "task chip renders hero-map-pin-mini icon + task title label", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Iconic Task")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(space)}")

      chip_html =
        view
        |> element("[data-role='mobile-pinned-task-chip'][data-space-id='#{space.id}']")
        |> render()

      # hero-map-pin-mini matches the desktop rail's Pinned-tasks section
      # header icon at chat_live.html.heex:353 — same mental model, same
      # glyph, so a mobile user recognises the pin metaphor immediately.
      assert chip_html =~ "hero-map-pin-mini"

      # Chip label MUST be the real task title, not the cryptic
      # `task-exec-<id>` space slug (regression against the desktop rail
      # bug fixed in the Pin-to-Chat Stage 4 review pass — the mobile strip
      # inherits the same fix by calling `display_name_for_space/1`).
      assert chip_html =~ "Iconic Task"
      refute chip_html =~ "task-exec-"
    end

    test "chip navigates to `/chat/<space_nav_target>` on click", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Nav Task")

      # Land on a different space so the pinned chip's href doesn't collapse
      # to the current URL — we want to see the destination it would
      # navigate to.
      other = seed_channel("nav-elsewhere")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(other)}")

      expected_path = "/chat/#{nav_target(space)}"

      chip_html =
        view
        |> element("[data-role='mobile-pinned-task-chip'][data-space-id='#{space.id}']")
        |> render()

      # `<.link navigate={…}>` compiles to an anchor with href on the LHS —
      # asserting the exact href locks the URL contract to `space_nav_target/1`
      # (prefers slug when org_id nil, falls back to id).
      assert chip_html =~ "href=\"#{expected_path}\""
    end

    test "channel-chip branch is present in the template skeleton", %{conn: _conn} do
      # Channel-level pinning isn't wired at the DB level yet (see moduledoc);
      # we can't seed a pinned channel through the Chat context today. This
      # snapshot-style assertion locks the channel-chip skeleton to the
      # template so removing it would fail loudly instead of silently
      # dropping the branch once channel-pinning lands.
      template_path =
        Path.join([
          File.cwd!(),
          "lib/platform_web/live/chat_live.html.heex"
        ])

      template = File.read!(template_path)

      assert template =~ "data-role=\"mobile-pinned-channel-chip\""
      assert template =~ "hero-bookmark-solid"
      assert template =~ "@channel_sections.pinned"
    end
  end

  describe "mobile Pinned strip unread badge" do
    test "chip renders unread badge via unread_label/1 when count > 0", %{conn: conn} do
      user = insert_chat_user()
      %{space: pinned_space} = seed_pinned_task_for(user, title: "Unread Task")

      # Sit on a DIFFERENT space so the pinned chip's unread count stays
      # non-zero — ChatLive's :active_space mount path clears unread for
      # the space we land in, which would zero out the badge if we mounted
      # directly on the pinned space.
      elsewhere = seed_channel("unread-elsewhere")

      # Add both users as participants; the "other" user posts a message
      # while the pinned user has no last_read_message_id, so
      # `count_unread/3` returns 1 for that space.
      other = insert_chat_user()

      {:ok, _user_participant} =
        Chat.add_participant(pinned_space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name || user.email,
          joined_at: DateTime.utc_now()
        })

      {:ok, other_participant} =
        Chat.add_participant(pinned_space.id, %{
          participant_type: "user",
          participant_id: other.id,
          display_name: other.name || other.email,
          joined_at: DateTime.utc_now()
        })

      {:ok, _message} =
        Chat.post_message(%{
          space_id: pinned_space.id,
          participant_id: other_participant.id,
          content_type: "text",
          content: "unread bump"
        })

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(elsewhere)}")

      chip_html =
        view
        |> element("[data-role='mobile-pinned-task-chip'][data-space-id='#{pinned_space.id}']")
        |> render()

      # unread_label/1 returns "1" for count == 1, so the badge text is "1".
      # The badge span has the same visual language as the channel-pills
      # strip below (min-w-[18px], primary background, bordered).
      assert chip_html =~ "min-w-[18px]"
      assert chip_html =~ ~r/>\s*1\s*</
    end

    test "chip omits unread badge when count == 0", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Read Task")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(space)}")

      chip_html =
        view
        |> element("[data-role='mobile-pinned-task-chip'][data-space-id='#{space.id}']")
        |> render()

      # No badge span → no "min-w-[18px]" class in the chip HTML.
      refute chip_html =~ "min-w-[18px]"
    end
  end
end
