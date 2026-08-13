defmodule PlatformWeb.ChatLiveMobilePinnedStripTest do
  @moduledoc """
  Tests for the mobile Pinned strip (task 019f923b Stage 1).

  The strip is a `lg:hidden` horizontally-scrollable chip row at the top of
  the chat main pane that surfaces the same pinned spaces the desktop rail
  shows — `@pinned_task_spaces` (task-exec pins,
  `hero-clipboard-document-list-mini`) and `@channel_sections.pinned`
  (pinned conversations). Without it, pinned spaces are unreachable on
  mobile because `<aside id="chat-sidebar">` is `hidden lg:flex`.

  Updated by task 019fd80f stage 2. Conversation pinning is now wired at
  every `channel_sections/4` call site, so `@channel_sections.pinned` is no
  longer always `[]`, and the chips no longer carry `hero-bookmark-solid`:
  a pin marker on every chip in a strip of pins never varied and told the
  reader nothing. Chips now use the desktop row identity, a bare name for
  a person and `#` for a channel. Render coverage for both kinds lives in
  `chat_live_pinned_block_test.exs`, which can seed a pinned conversation;
  the tests here stay on the task-pin path.

  Updated again by task 019feec6-73d9. The task chip carried
  `hero-map-pin-mini` while the rail's task row carried
  `hero-clipboard-document-list-mini` — one concept, two glyphs depending on
  which surface you were looking at. The glyph is the ONLY thing that
  distinguishes the three kinds of pinned row, so the two surfaces now use
  the one Saru's design canvas specifies.

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
    test "task chip renders the rail's task glyph + task title label", %{conn: conn} do
      user = insert_chat_user()
      %{space: space} = seed_pinned_task_for(user, title: "Iconic Task")

      conn = init_test_session(conn, current_user_id: user.id)

      {:ok, view, _html} = live(conn, ~p"/chat/#{nav_target(space)}")

      chip_html =
        view
        |> element("[data-role='mobile-pinned-task-chip'][data-space-id='#{space.id}']")
        |> render()

      # The SAME glyph the desktop rail and the mobile drawer put on a task
      # row. This chip carried `hero-map-pin-mini` until task 019feec6-73d9:
      # a task read as one thing in the rail and another in the strip, and
      # the glyph is the only thing separating a task from a channel or a
      # person.
      assert chip_html =~ "hero-clipboard-document-list-mini"

      refute chip_html =~ "hero-map-pin-mini",
             "the task chip still carries the old pin glyph alongside the new one"

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

    test "conversation-chip branch is present in the template skeleton", %{conn: _conn} do
      # A snapshot assertion locking the conversation-chip branch to the
      # template so removing it fails loudly.
      #
      # This test is SCOPED to the chip's own markup rather than grepping the
      # whole file, and the history is why. It used to assert
      # `hero-bookmark-solid` was present. When task 019fd80f stage 2 removed
      # that icon from the chips, the assertion did NOT fail: the string still
      # appears five times elsewhere in the file for message pinning. A
      # whole-file grep for a string that is not unique to the thing under
      # test cannot fail for the reason it was written.
      #
      # Scoping to the region between the chip's data-role and its closing tag
      # makes every assertion below answer a question about the chip itself.
      template_path =
        Path.join([
          File.cwd!(),
          "lib/platform_web/live/chat_live.html.heex"
        ])

      template = File.read!(template_path)

      assert template =~ "@channel_sections.pinned"
      assert template =~ "data-role=\"mobile-pinned-channel-chip\""

      chip =
        case Regex.run(~r/data-role="mobile-pinned-channel-chip".*?<\/\.link>/s, template) do
          [match] -> match
          _ -> flunk("could not locate the conversation-chip markup in the template")
        end
        # HEEx comments are stripped before asserting. Without this the
        # refutes below match the comment that EXPLAINS why the bookmark and
        # the avatar are absent, so a correct template fails. Scoping the
        # region was not enough on its own; the region has to be markup.
        |> String.replace(~r/<%!--.*?--%>/s, "")

      # A channel chip keeps the hash; a person chip is a bare display name.
      assert chip =~ "data-role=\"pinned-row-hash\""
      assert chip =~ "sidebar_display_name(space, @user_id)"

      # Neither marker belongs on these chips. The bookmark never varied in a
      # strip where every chip is already a pin, and the avatar rendered
      # misleading initials for group DMs.
      refute chip =~ "hero-bookmark-solid"
      refute chip =~ "human_avatar"
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
