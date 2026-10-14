defmodule PlatformWeb.ShellLivePushRegistrationTest do
  @moduledoc """
  Device registration from a NON-chat route (task 019ffe52, fix A).

  `Platform.Push.subscribe/2` keys a subscription to a `chat_participants.id`.
  `:current_participant` is assigned by `ChatLive` and `MeetingLive` and by
  nothing else, so on `/inbox`, `/tasks` and every other route in the
  `:authenticated` live_session the `push_subscribed` clause of the
  `:push_events` attach_hook had nothing to key to and dropped the endpoint on
  the floor. The user was told notifications were on; no row existed.

  Nothing about the schema forces that. `Platform.Push` resolves a user's
  devices through

      join: p in Participant,
      on: p.id == s.participant_id,
      where: p.participant_type == "user" and p.participant_id == ^user_id,
      distinct: s.endpoint

  which joins `chat_participants.id` to `push_subscriptions.participant_id` and
  filters on `chat_participants.participant_id` (the USER id). A subscription
  filed against ANY of the user's user-typed participant rows therefore
  resolves for delivery from every conversation. So the fix is a lookup:
  register against a row the user already has.

  Resolution runs through a private query, and the router short-circuits push
  under the test env, so the resolved device set is observed the way
  `platform/push_test.exs` already observes it in the
  `send_to_user/2 endpoint dedup` block: with VAPID unconfigured (the test
  default) each attempted delivery logs exactly one
  "VAPID keys not configured" line, so counting that string counts resolved
  endpoints.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Push
  alias Platform.Push.Subscription
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @device "https://push.example.com/device/registered-off-chat"
  @keys %{"p256dh" => "p256dh-off-chat", "auth" => "auth-off-chat"}

  defp member_user! do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "push-reg-#{n}@example.com",
        name: "Push Reg #{n}",
        oidc_sub: "oidc-push-reg-#{n}"
      })

    acme = Tenancy.get_org_by_slug!("acme")
    Repo.insert!(%OrgMembership{user_id: user.id, org_id: acme.id, role: "member"})

    user
  end

  defp channel_with!(user) do
    acme = Tenancy.get_org_by_slug!("acme")

    {:ok, space} =
      Chat.create_space(%{
        name: "Push Reg Chan",
        slug: "push-reg-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: acme.id
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {space, participant}
  end

  # See the moduledoc: one log line per attempted delivery, one attempted
  # delivery per resolved distinct endpoint.
  defp resolved_endpoints(user_id) do
    log =
      capture_log(fn ->
        assert Push.send_to_user(user_id, %{title: "t", body: "b", url: "/x"}) == :ok
      end)

    log |> String.split("VAPID keys not configured") |> length() |> Kernel.-(1)
  end

  describe "push_subscribed outside chat" do
    test "files the device against a participant row the user already has", %{conn: conn} do
      user = member_user!()
      {_space, participant} = channel_with!(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The premise of the whole task. If this ever starts being assigned on
      # `/tasks`, the case below stops exercising the defect and this line is
      # the thing that says so.
      refute :sys.get_state(view.pid).socket.assigns[:current_participant],
             "/tasks must not assign :current_participant, or this test is not " <>
               "reaching the off-chat path"

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      # At the database, not at the assign. "Reports success" was never the
      # bug; registering nothing was.
      assert %Subscription{} = sub = Repo.get_by(Subscription, endpoint: @device),
             "turning notifications on outside chat must write a push_subscriptions row"

      assert sub.participant_id == participant.id
      assert sub.p256dh == @keys["p256dh"]
      assert sub.auth == @keys["auth"]

      # And it must be a row the delivery path can find, which is the only
      # thing that makes the registration worth anything.
      assert resolved_endpoints(user.id) == 1,
             "the registered device must resolve for the user through send_to_user/2"
    end

    test "a user with no participant row anywhere writes nothing and does not crash",
         %{conn: conn} do
      user = member_user!()

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      # There is genuinely nothing to key to. The clause must degrade, not
      # raise: `push_subscriptions.participant_id` has no matching row to point
      # at. What the UI then tells the user is asserted below.
      assert Repo.aggregate(Subscription, :count) == 0
      assert render(view)
    end

    test "the same device registered twice stays one row", %{conn: conn} do
      user = member_user!()
      {_space, _participant} = channel_with!(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})
      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert Repo.aggregate(Subscription, :count) == 1
      assert resolved_endpoints(user.id) == 1
    end

    # The row chosen must be the same one on every registration, otherwise a
    # user in several channels accumulates one subscription row per channel for
    # a single physical device. Endpoint dedup hides that at delivery time; it
    # still fills the table with rows nothing prunes.
    test "a user in several channels still gets exactly one row per device", %{conn: conn} do
      user = member_user!()
      {_s1, _p1} = channel_with!(user)
      {_s2, _p2} = channel_with!(user)
      {_s3, _p3} = channel_with!(user)

      conn = init_test_session(conn, current_user_id: user.id)

      for _ <- 1..3 do
        {:ok, view, _html} = live(conn, ~p"/tasks")
        render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})
      end

      assert Repo.aggregate(Subscription, :count) == 1,
             "the participant row must be picked deterministically, not per-mount"

      assert resolved_endpoints(user.id) == 1
    end
  end

  # Task 019ffe52 fix B. Stage 1 narrowed who reaches the no-participant path;
  # it did not remove it. A brand-new account that has never been added to any
  # space still has nothing to key a subscription to, and on that path the
  # clause used to report a grant it had not achieved.
  #
  # The negative below is the assertion with teeth, and it is worth saying why
  # plainly: a happy-path-only test passes identically for code that always
  # reports granted, which IS the bug. "Enabling worked" and "we told the user
  # enabling worked" are only the same statement when the write lands.
  describe "reporting the registration honestly" do
    # The assign carries WHY, not whether. It was a boolean until Marlowe
    # rejected the copy it produced: one flag set by two failures with opposite
    # answers forced the wording vague. Asserting the exact reason is the point,
    # since truthiness alone would let the two collapse back together unnoticed.
    defp registration_failure(view),
      do: :sys.get_state(view.pid).socket.assigns[:push_registration_failed]

    test "a failed write does not report granted, and says it failed", %{conn: conn} do
      user = member_user!()

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      # The write is forced to fail honestly, by giving the user no participant
      # row anywhere, rather than by stubbing `Platform.Push`. A stub would
      # also pass if the real failure mode were something else entirely.
      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      refute has_element?(view, "#push-subscribe[data-permission='granted']"),
             "push_subscribed must not report granted when nothing was written"

      assert registration_failure(view) == :no_participant,
             "a failed registration must be recorded with its reason, not swallowed"

      assert Repo.aggregate(Subscription, :count) == 0
    end

    # The permission is NOT the place to record this. The browser truthfully
    # granted, and `assets/js/hooks/push_subscribe.js` pushes
    # `push_permission_state {state: "granted"}` from `requestPermission/0`
    # independently of `push_subscribed`. So the honest state is "granted
    # permission, failed registration", which needs two facts and cannot be
    # squeezed into one. `auto_denied` is the same shape.
    test "a real browser grant still sets granted; the flag carries the failure",
         %{conn: conn} do
      user = member_user!()

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_permission_state", %{"state" => "granted"})
      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert has_element?(view, "#push-subscribe[data-permission='granted']"),
             "the permission is whatever the browser truthfully reported"

      assert registration_failure(view) == :no_participant,
             "and the registration failure is carried beside it, not folded into it"

      assert Repo.aggregate(Subscription, :count) == 0
    end

    # Positive control, non-chat route. Without this, both assertions above
    # would still pass for code that had simply stopped reporting granted at
    # all and set the flag unconditionally.
    test "a successful write off chat reports granted and leaves the reason nil",
         %{conn: conn} do
      user = member_user!()
      {_space, _participant} = channel_with!(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert has_element?(view, "#push-subscribe[data-permission='granted']")
      assert registration_failure(view) == nil
      assert Repo.aggregate(Subscription, :count) == 1
    end

    # `push_subscribe_failed` is the client-side twin: `pushManager.subscribe`
    # rejecting after the browser already granted. It sets the SAME assign with
    # a DIFFERENT reason.
    #
    # This first shipped setting the same boolean as the server-side branch, on
    # the argument that one user-visible outcome reached two ways should be one
    # state. Marlowe's review killed that: the outcomes differ in who can act.
    # Here a reload can genuinely change the result, so the user has a step to
    # take; on the other branch they have none. Asserting the exact reason is
    # what stops the two collapsing back together.
    test "the client-side subscribe failure records its own reason", %{conn: conn} do
      user = member_user!()
      {_space, _participant} = channel_with!(user)

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_permission_state", %{"state" => "granted"})

      render_hook(view, "push_subscribe_failed", %{
        "name" => "AbortError",
        "message" => "push service error"
      })

      assert registration_failure(view) == :subscribe_failed,
             "a browser-side subscribe failure is not the no-conversations case"

      # And it still does not move the permission: a failed subscribe under a
      # granted permission is not a denial.
      assert has_element?(view, "#push-subscribe[data-permission='granted']")
    end

    # A retry that works has to clear the reason, otherwise the first failure is
    # permanent for the life of the socket and the user is told it is broken
    # while it works.
    test "a later successful registration clears the reason", %{conn: conn} do
      user = member_user!()

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})
      assert registration_failure(view) == :no_participant

      # The user is added to a space, then the client retries.
      {_space, _participant} = channel_with!(user)
      render_hook(view, "push_subscribed", %{"endpoint" => @device, "keys" => @keys})

      assert registration_failure(view) == nil
      assert has_element?(view, "#push-subscribe[data-permission='granted']")
      assert Repo.aggregate(Subscription, :count) == 1
    end
  end
end
