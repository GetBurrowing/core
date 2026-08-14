defmodule PlatformWeb.ShellLiveExternalBadgeTest do
  @moduledoc """
  Unread-badge delivery on the EXTERNAL chat surface (task 01a00161 stage 2).

  `PlatformWeb.ShellLive` runs as the `on_mount` for the `chat.`-host
  `:external_chat` live_session (`router.ex:324-334`), so it has always pushed
  the `app_badge` event to external users. Until stage 1 the `:external` layout
  carried no `<div id="app-badge" phx-hook="AppBadge">`, so every one of those
  pushes was discarded by the client. These tests pin the DELIVERY (the pushed
  count) on the external surface; `layouts_external_test.exs` pins the MOUNT
  POINT that receives it.

  ## Verification limit — read this before "checking" the badge in a browser

  `navigator.setAppBadge` is a **NO-OP in a plain browser tab**. That is a W3C
  Badging API limit, not a bug: the API only paints when the document is
  running as an INSTALLED application (PWA / standalone window), and the hook
  documents exactly this at `apps/platform/assets/js/hooks/app_badge.js:20-25`
  (which is why it also paints a `(3) ` document-title prefix — the only
  tab-observable fallback). Opening the external chat host in Chrome and seeing
  no OS badge proves NOTHING about the shipped behavior, in either direction.
  The real end-to-end check runs against an installed PWA and lives in this
  task's `e2e_behavior` cases. Nothing in ExUnit can observe the paint; these
  tests observe the push, which is the part that actually broke.

  ## Why both halves run in one module

  A scoping bug that pushes `0` to everybody satisfies the negative assertion
  ("a non-participant's count does not move") all by itself, so the negative is
  worthless without a positive control beside it in the SAME run. Hence:

    * POSITIVE — external user IS a participant of space A, someone @mentions
      them there, and the pushed count rises by exactly 1.
    * NEGATIVE — space B that the external user does NOT participate in, an
      @mention of them by name, and the pushed count is UNCHANGED.

  Producer evidence for the negative: `Platform.Chat.emit_inbox_for_mentions/1`
  (`lib/platform/chat.ex:3572-3577`) resolves recipients from
  `list_participants(space_id)`, so a non-participant never gets an inbox row
  and therefore never gets a count bump.

  `async: false` — mirrors `chat_live_external_host_mount_test.exs`; keeps the
  host-swapped conn cases off the shared async pool.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @external_display_name "Badgey External"

  # A `chat.`-prefixed host makes the `:external_chat` scope win the match.
  # Mirrors `with_chat_host/1` in `chat_live_external_host_mount_test.exs`.
  defp with_chat_host(conn, host \\ "chat.localhost") do
    %{conn | host: host}
  end

  defp create_user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ext-badge-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-ext-badge-#{n}",
      avatar_url: nil
    })
  end

  defp authenticated_conn(conn, %User{} = user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel! do
    slug = "ext-badge-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{
        name: String.capitalize(slug),
        slug: slug,
        kind: "channel"
      })

    space
  end

  defp add_user!(space_id, %User{} = user, display_name) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  # See `chat_live_external_host_mount_test.exs` — `GET /chat` push_navigates
  # to the first space when one exists; the landing target is in the SAME
  # live_session, so the layout/session under test is unchanged.
  defp live_settled(conn, path) do
    case live(conn, path) do
      {:error, {kind, %{to: to}}} when kind in [:live_redirect, :redirect] -> live(conn, to)
      ok -> ok
    end
  end

  defp badge_count(view) do
    :sys.get_state(view.pid).socket.assigns[:inbox_unread_count]
  end

  describe "app_badge delivery on the chat. host" do
    test "POSITIVE: a mention in a space the external user participates in raises the pushed count by exactly 1, and NEGATIVE: a mention in a space they do not participate in leaves it unchanged",
         %{conn: conn} do
      external = create_user!(@external_display_name)
      author = create_user!("Mention Author")

      # Space A — the external user IS a participant.
      space_a = create_channel!()
      author_a = add_user!(space_a.id, author, "Mention Author")
      _ = add_user!(space_a.id, external, @external_display_name)

      # Space B — the external user is NOT a participant. The author is.
      space_b = create_channel!()
      author_b = add_user!(space_b.id, author, "Mention Author")

      {:ok, view, _html} =
        conn
        |> authenticated_conn(external)
        |> with_chat_host()
        |> live_settled("/chat/#{space_a.slug}")

      # Baseline: mount always seeds the hook, even at zero.
      assert_push_event(view, "app_badge", %{count: 0})
      assert badge_count(view) == 0

      # ── POSITIVE ────────────────────────────────────────────────────────
      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space_a.id,
          participant_id: author_a.id,
          content_type: "text",
          content: "@[#{@external_display_name}] please look at this"
        })

      _ = render(view)

      # Rose by exactly 1 — pushed to the client AND reflected in the assign.
      assert_push_event(view, "app_badge", %{count: 1, label: "1"})
      assert badge_count(view) == 1

      # ── NEGATIVE ────────────────────────────────────────────────────────
      # Same user, mentioned by the same name, in a space they do not
      # participate in. `emit_inbox_for_mentions/1` resolves recipients from
      # `list_participants(space_b.id)` — they are not in it, so no row, so
      # no re-push and no movement in the count.
      {:ok, _msg_b} =
        Chat.post_message(%{
          space_id: space_b.id,
          participant_id: author_b.id,
          content_type: "text",
          content: "@[#{@external_display_name}] you should not see this"
        })

      _ = render(view)

      refute_push_event(view, "app_badge", %{count: 2})
      assert badge_count(view) == 1
    end
  end
end
