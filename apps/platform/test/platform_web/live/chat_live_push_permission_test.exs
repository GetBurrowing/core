defmodule PlatformWeb.ChatLivePushPermissionTest do
  @moduledoc """
  The push-permission wire contract between the PushSubscribe hook and
  ChatLive (task 019ffb7b stage 2).

  Before this stage, `assets/js/hooks/push_subscribe.js` reported
  `{state: "prompt"}` only for iOS Safari. Every desktop browser fell through
  to a silent `pushManager.subscribe()`, so `:push_permission` stayed
  `"unknown"` and `notification_banner/1` (gated on exactly `"prompt"`) could
  never render there. The hook now reports `"prompt"` on every browser and
  waits for the user gesture.

  The hook itself is JS and no ExUnit test reaches it. What IS reachable, and
  what these tests cover, is the server half of the contract:

    * the five wire values (`"granted"`, `"denied"`, `"prompt"`,
      `"unsupported"`, `"unknown"`) each land on `:push_permission`, and only
      `"prompt"` renders the banner;
    * the banner's click pushes `request_push_permission` back to the hook,
      which is the user gesture the whole change exists to route through;
    * `push_subscribe_failed` is handled at all, and does NOT move
      `:push_permission`.

  That last one is the regression this file is really here for. ChatLive has
  no catch-all `handle_event/3`, so a hook event with no matching clause takes
  the LiveView down.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Push.Subscription
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @banner_text "Get notified when someone mentions you."
  @banner "[data-role='chat-notification-banner']"
  @enable_button "button[phx-click='enable_notifications']"
  @dismiss_button "button[phx-click='dismiss_notification_banner']"

  defp member_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "push-perm-#{n}@example.com",
        name: "Push Perm #{n}",
        oidc_sub: "oidc-push-perm-#{n}"
      })

    acme = Tenancy.get_org_by_slug!("acme")

    unless Repo.get_by(OrgMembership, user_id: user.id, org_id: acme.id) do
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: acme.id, role: "member"})
      |> Repo.insert!()
    end

    init_test_session(conn, current_user_id: user.id)
  end

  # `/chat` live-redirects to the first ACTIVE channel when the user has one.
  # Follow it: the banner renders from the same template either way.
  defp mount_chat(conn) do
    case live(conn, ~p"/chat") do
      {:ok, view, _html} ->
        view

      {:error, {:live_redirect, %{to: path}}} ->
        {:ok, view, _html} = live(conn, path)
        view
    end
  end

  # Task 019ffe52 fix A moved the `push_subscribed` clause off
  # `:current_participant` alone and onto a user-level fallback. These are the
  # control that the working path was not broken to fix the broken one: from a
  # chat route, where `:current_participant` IS assigned, the device must still
  # reach `push_subscriptions` and the permission must still read "granted".
  describe "push_subscribed from a chat route (019ffe52 positive control)" do
    @device "https://push.example.com/device/from-chat"
    @keys %{"p256dh" => "p256dh-from-chat", "auth" => "auth-from-chat"}

    defp channel_member_conn(conn) do
      n = System.unique_integer([:positive])
      acme = Tenancy.get_org_by_slug!("acme")

      user =
        Repo.insert!(%User{
          email: "push-chat-#{n}@example.com",
          name: "Push Chat #{n}",
          oidc_sub: "oidc-push-chat-#{n}"
        })

      Repo.insert!(%OrgMembership{user_id: user.id, org_id: acme.id, role: "member"})

      # TWO channels, joined in order. Mounting the SECOND is what makes this a
      # real control rather than a coincidence: the user-level fallback picks
      # the user's EARLIEST membership, so if the `:current_participant` branch
      # were deleted the row would land on `first`'s participant and the
      # assertion below would fail. With one channel both branches agree and
      # the test would pass either way.
      spaces =
        for i <- 1..2 do
          {:ok, space} =
            Chat.create_space(%{
              name: "Push Chat Chan #{i}",
              slug: "push-chat-#{n}-#{i}",
              kind: "channel",
              org_id: acme.id
            })

          {:ok, participant} =
            Chat.add_participant(space.id, %{
              participant_type: "user",
              participant_id: user.id,
              display_name: user.name,
              joined_at: DateTime.add(DateTime.utc_now(), i, :second)
            })

          {space, participant}
        end

      [{first_space, first_participant}, {second_space, second_participant}] = spaces

      %{
        conn: init_test_session(conn, current_user_id: user.id),
        first_space: first_space,
        first_participant: first_participant,
        space: second_space,
        participant: second_participant
      }
    end

    test "writes the row, keyed to THIS space's participant", %{conn: conn} do
      %{conn: conn, space: space, participant: participant, first_participant: first} =
        channel_member_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert %Subscription{} = sub = Repo.get_by(Subscription, endpoint: @device)
      assert sub.p256dh == @keys["p256dh"]
      assert sub.auth == @keys["auth"]

      assert sub.participant_id == participant.id,
             "a chat route must key the device to the participant it is rendering"

      refute sub.participant_id == first.id,
             "the user-level fallback took over on a route that has a participant"
    end

    # Positive control for fix B on the chat path. A successful registration
    # reports granted AND leaves the failure flag false. Both halves matter:
    # the flag assertion alone would pass for code that never sets it, and the
    # granted assertion alone is what the pre-fix bug satisfied.
    test "a successful write reports granted and leaves the failure flag false",
         %{conn: conn} do
      %{conn: conn, space: space} = channel_member_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert has_element?(view, "#push-subscribe[data-permission='granted']")
      refute :sys.get_state(view.pid).socket.assigns[:push_registration_failed]
      assert Repo.aggregate(Subscription, :count) == 1
    end

    test "still reports granted, so the banner comes down", %{conn: conn} do
      %{conn: conn, space: space} = channel_member_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert has_element?(view, @banner)

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      refute has_element?(view, @banner)
      refute render(view) =~ @banner_text
    end
  end

  describe "notification banner gating" do
    test "hidden on mount, before the hook has reported anything", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      # :push_permission starts at "unknown". Nothing to offer yet.
      refute render(view) =~ @banner_text
      refute has_element?(view, @enable_button)
    end

    test "shows when the hook reports \"prompt\"", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert render(view) =~ @banner_text
      assert has_element?(view, @enable_button)
    end

    test "stays hidden for granted, denied and unsupported", %{conn: conn} do
      for state <- ["granted", "denied", "unsupported"] do
        view = mount_chat(member_conn(conn))

        render_hook(view, "push_permission_state", %{"state" => state})

        refute render(view) =~ @banner_text,
               "the opt-in banner must not render while permission is #{state}"
      end
    end

    test "push_unsupported takes the banner back down", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert render(view) =~ @banner_text

      render_hook(view, "push_unsupported", %{})
      refute render(view) =~ @banner_text
    end
  end

  describe "banner treatment (stage 5)" do
    # ONE test walks all five permission states, and it is written this way on
    # purpose. Split into "prompt renders" plus "the others don't", a banner
    # wired to nothing fails only the first and the absence half stays green.
    # Here the positive control and the four absences share a test, so a
    # component that renders nothing detonates inside the same case.
    test "renders in prompt and in no other state", %{conn: conn} do
      for state <- ["prompt", "granted", "denied", "unsupported", "unknown"] do
        view = mount_chat(member_conn(conn))
        render_hook(view, "push_permission_state", %{"state" => state})

        if state == "prompt" do
          assert has_element?(view, @banner),
                 "the opt-in banner must render while permission is prompt"

          assert has_element?(view, @enable_button),
                 "the prompt banner must carry its action"

          assert has_element?(view, @dismiss_button),
                 "the prompt banner must carry its dismiss control"
        else
          refute has_element?(view, @banner),
                 "the opt-in banner must not render while permission is #{state}"

          refute has_element?(view, @enable_button),
                 "no enable action may render while permission is #{state}"

          refute has_element?(view, @dismiss_button),
                 "no dismiss control may render while permission is #{state}"
        end
      end
    end

    # `denied` gets its own case because it is the state most likely to be
    # "helpfully" added back later. The blocked state belongs to the /inbox
    # row, which can say something useful about it; a chat strip could not.
    test "denied renders nothing here — /inbox owns that state", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert has_element?(view, @banner)

      render_hook(view, "push_permission_state", %{"state" => "denied"})
      refute has_element?(view, @banner)
    end

    test "the action is the primary colour, not the banner's own tint", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(view, "#{@enable_button}.btn.btn-primary.btn-sm")

      # The defect this stage fixes: btn-info on bg-info/10 is a button-shaped
      # piece of the banner.
      refute has_element?(view, "#{@enable_button}.btn-info")
    end

    test "the copy truncates and the button holds its size", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(view, "#{@banner} p.min-w-0.truncate")
      assert has_element?(view, "#{@enable_button}.shrink-0")

      # The action and the dismiss x share one shrink-0 wrapper. As three
      # direct children, `justify-between` spread the free space between all
      # of them and left the action floating mid-banner on a wide viewport.
      assert has_element?(view, "#{@banner} > div.shrink-0 #{@enable_button}")
      assert has_element?(view, "#{@banner} > div.shrink-0 #{@dismiss_button}")
    end

    test "says what the notifications are for, and what the button does", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      html = render(view)

      assert html =~ @banner_text
      assert html =~ "Turn on notifications"
    end
  end

  # Robin, 2026-08-13: "this banner needs a way to be dismissed. A user should
  # be able to dismiss this notification if they dont want notifications or
  # they dont want to set it up right now."
  describe "dismissal (stage 5 rework)" do
    test "the x is a real, named button inside the banner", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      # Inside the banner, not floating somewhere else on the page.
      assert has_element?(view, "#{@banner} #{@dismiss_button}")

      # A <button type="button"> is what puts it in the tab order and makes
      # Enter/Space activate it. A clickable <div> or an <a href="#"> would
      # satisfy a "does clicking work" test and fail a keyboard user.
      assert has_element?(
               view,
               "#{@banner} button[type='button'][phx-click='dismiss_notification_banner']"
             )

      # Names what is being dismissed. "Close" alone tells a screen-reader
      # user nothing about which of the page's several controls this is.
      assert has_element?(view, "#{@dismiss_button}[aria-label='Dismiss notification setup']")
    end

    # The control is painted at rest. Tailwind compiles `hover:` and
    # `group-hover:` inside `@media (hover: hover)`, which never matches on a
    # touch device — a visibility rule written that way makes the x absent on
    # a phone rather than merely quiet. Same trap the rail's pin control fell
    # into (Robin: "hover doesn't work on mobile").
    test "no hover variant gates the x's visibility", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      refute has_element?(view, "#{@dismiss_button}[class*='hover:']"),
             "the dismiss control must not carry a Tailwind hover: variant"

      refute has_element?(view, "#{@dismiss_button}[class*='group-hover']"),
             "the dismiss control must not carry a Tailwind group-hover: variant"

      refute has_element?(view, "#{@dismiss_button}[class*='opacity-0']"),
             "the dismiss control must be visible at rest, not revealed"
    end

    test "clicking the x takes the banner down", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert has_element?(view, @banner)

      view |> element(@dismiss_button) |> render_click()

      refute has_element?(view, @banner)
      refute has_element?(view, @enable_button)
      refute render(view) =~ @banner_text
    end

    # THE point of the rework. One of Robin's two reasons ("they dont want
    # notifications") is permanent, so a dismissal that dies with the
    # LiveView process would re-nag that user on every single visit — the
    # exact behaviour the feedback asks to stop. The state is written to
    # `users.preferences` and read back at mount.
    test "the dismissal survives a remount", %{conn: conn} do
      conn = member_conn(conn)

      view = mount_chat(conn)
      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      view |> element(@dismiss_button) |> render_click()
      refute has_element?(view, @banner)

      # A brand-new LiveView process for the SAME user, which is what a page
      # reload gives you. A session-scoped dismissal fails here.
      remounted = mount_chat(conn)
      render_hook(remounted, "push_permission_state", %{"state" => "prompt"})

      refute has_element?(remounted, @banner),
             "a dismissed banner must stay dismissed across a reload"

      refute render(remounted) =~ @banner_text
    end

    # Positive control for the test above: without this, "the banner is absent
    # after a remount" would also pass if the banner had stopped rendering for
    # every user, dismissed or not.
    test "a different user still sees the banner", %{conn: conn} do
      dismisser = member_conn(conn)

      view = mount_chat(dismisser)
      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      view |> element(@dismiss_button) |> render_click()

      other = mount_chat(member_conn(conn))
      render_hook(other, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(other, @banner),
             "one user's dismissal must not silence the banner for everyone"
    end

    test "the dismissal is recorded on the user, not just the socket", %{conn: conn} do
      conn = member_conn(conn)
      user_id = Plug.Conn.get_session(conn, :current_user_id)

      refute Accounts.notification_banner_dismissed?(user_id)

      view = mount_chat(conn)
      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      view |> element(@dismiss_button) |> render_click()

      assert Accounts.notification_banner_dismissed?(user_id)
    end
  end

  describe "the user gesture" do
    test "clicking Enable pushes request_push_permission back to the hook", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      view |> element(@enable_button) |> render_click()

      # This is the gesture-driven Notification.requestPermission() call that
      # replaced the hook's silent auto-subscribe on desktop.
      assert_push_event(view, "request_push_permission", %{})
    end
  end

  describe "push_subscribe_failed" do
    test "is handled, and leaves the banner up rather than reading as a denial",
         %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      render_hook(view, "push_subscribe_failed", %{
        "name" => "NotAllowedError",
        "message" => "Registration failed - permission denied"
      })

      # Alive: no catch-all clause exists, so an unhandled event would have
      # taken the view down here.
      assert render(view) =~ @banner_text
    end

    test "does not downgrade a granted permission", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "granted"})

      render_hook(view, "push_subscribe_failed", %{
        "name" => "AbortError",
        "message" => "push service error"
      })

      # A subscribe failure under a granted permission is not a denial. The
      # assign must not move, so the banner must not appear.
      refute render(view) =~ @banner_text
    end

    test "tolerates a malformed payload from the client", %{conn: conn} do
      view = mount_chat(member_conn(conn))

      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      render_hook(view, "push_subscribe_failed", %{})

      assert render(view) =~ @banner_text
    end
  end
end
