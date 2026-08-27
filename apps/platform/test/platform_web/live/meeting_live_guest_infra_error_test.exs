defmodule PlatformWeb.MeetingLiveGuestInfraErrorTest do
  @moduledoc """
  Task 019f9cb7-d43d-7e3d-b2e6-57cc679917f9.

  Stage 1 committed the first two tests below RED. `enter_meeting_as_guest/3`
  ended in

      {:error, _reason} ->
        ... assign(:state, :invalid)
        ... assign(:page_title, "Invite link is not valid")
        ... assign(:meeting, nil)

  discarding the reason and rendering every failure as "your invite link is
  bad". `Meetings.mint_guest_join_bundle/2` — the only call that clause
  guards — can return exactly `:livekit_not_configured` and
  `:missing_display_name`. Neither means the invite is invalid; the genuine
  invalid-invite decision is made earlier by `Meetings.resolve_guest_invite/2`
  on the mount clause above.

  Stage 2 split the outcomes by what the guest can DO next, and this file
  pins one test per outcome. They are deliberately NOT written against a
  shared "is not :invalid" assertion — each asserts the state, the page
  title and the on-page copy that belongs to ITS case, so no single edit can
  turn them all green together:

    * infra fault  → `:unavailable`, our fault, logged, meeting KEPT
    * bad name     → `:name_entry`, recoverable, inline message
    * bad token    → `:invalid`, unchanged, and still the only case that says so

  Every test asserts reachability before mounting — the resolver admits the
  invite, and the mint returns the specific error — so a green can never come
  from the invite having quietly gone bad.

  `async: false`: these mutate `Application.put_env(:platform, :livekit, …)`,
  which is global.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Repo
  alias Platform.Tasks

  @invalid_invite_copy "Invite link is not valid"
  @unavailable_copy "Meetings are temporarily unavailable"
  @unavailable_body "Your invite link is fine"
  @name_recovery_copy "We couldn&#39;t read the name on your invite."

  defp put_livekit_env(value) do
    original = Application.get_env(:platform, :livekit, [])
    Application.put_env(:platform, :livekit, value)
    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  defp configure_livekit do
    put_livekit_env(
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )
  end

  # `[]` is what `livekit_config/0` treats as "not configured": it is a
  # list but empty, so the helper falls through to the LIVEKIT_* env vars,
  # which the test environment does not set.
  defp unconfigure_livekit, do: put_livekit_env([])

  defp create_meeting do
    org_id = Platform.TenancyFixtures.fabrikam_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Guest Infra Error Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Guest Infra Error Kickoff #{System.unique_integer([:positive])}"
      })

    Repo.preload(meeting, :chat_space)
  end

  # `meet.` host prefix so the `:guest_meeting` scope wins the route match.
  defp with_meet_host(conn), do: %{conn | host: "meet.localhost"}

  defp sign_invite(meeting, display_name) do
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
    GuestInvite.sign(meeting.slug, expires_at, display_name, meeting_id: meeting.id)
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns

  describe "outcome 2 — an unconfigured media server is an OPERATIONAL fault" do
    test "a valid guest invite lands :unavailable, not :invalid, when LiveKit is unset",
         %{conn: conn} do
      configure_livekit()
      meeting = create_meeting()
      token = sign_invite(meeting, "Jane Doe")

      # REACHABILITY, part 1. The invite itself is good: the resolver
      # admits it straight to `:in_meeting`. Asserted while LiveKit is
      # still configured so this precondition cannot be confused with
      # the thing under test.
      assert {:ok, %{state: :in_meeting, display_name: "Jane Doe"}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      unconfigure_livekit()

      # REACHABILITY, part 2. With LiveKit unset the mint — and ONLY the
      # mint — now fails, with the reason the old clause threw away.
      # Nothing about the guest's link has changed.
      assert {:error, :livekit_not_configured} =
               Meetings.mint_guest_join_bundle(meeting, "Jane Doe")

      {{:ok, view, html}, log} =
        with_log(fn ->
          conn
          |> with_meet_host()
          |> live("/#{meeting.slug}/#{token}")
        end)

      assigns = assigns_of(view)

      # THIS case's own outcome. Not merely "not :invalid".
      assert assigns.state == :unavailable
      assert assigns.page_title == @unavailable_copy
      assert html =~ @unavailable_copy
      assert html =~ @unavailable_body

      # The guest is told our media plane is down, never that their link
      # is bad. That was the defect.
      refute assigns.state == :invalid
      refute html =~ @invalid_invite_copy

      # `assign(:meeting, nil)` is gone on this path: the card names the
      # meeting the guest was legitimately invited to, which is the whole
      # difference between "we can't get you in" and "your link is junk".
      assert assigns.meeting
      assert assigns.meeting.id == meeting.id
      assert html =~ meeting.name

      # Previously silent to operators while the visitor got blamed.
      assert log =~ "[warning]"
      assert log =~ "LiveKit media server is not configured"
      assert log =~ meeting.id

      # GUEST SURFACE. The diagnosis goes to the log; the page carries no
      # error atom, no service name and no internal identifier.
      refute html =~ "livekit"
      refute html =~ "LiveKit"
      refute html =~ "missing_display_name"
      refute html =~ meeting.id

      # ...and the log names the fault, never the guest.
      refute log =~ "Jane Doe"
    end

    test "the same fault reached through the name-entry form gets the same card",
         %{conn: conn} do
      # The second entry point. Stage 2 deleted this site's own pre-flight
      # mint and its separately-worded copy, so this asserts the two paths
      # now produce ONE answer rather than two that can drift.
      configure_livekit()
      meeting = create_meeting()
      # A nil display name routes to `:name_entry`, which mints nothing.
      token = sign_invite(meeting, nil)

      assert {:ok, %{state: :name_entry}} = Meetings.resolve_guest_invite(meeting.slug, token)

      unconfigure_livekit()

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      # REACHABILITY: mount really did stop at the form. If it had already
      # failed, the submit below would prove nothing.
      assert assigns_of(view).state == :name_entry
      assert html =~ "phx-submit=\"submit_name\""

      {submitted, log} =
        with_log(fn ->
          render_hook(view, "submit_name", %{"guest" => %{"name" => "Jane Doe"}})
        end)

      assigns = assigns_of(view)

      assert assigns.state == :unavailable
      assert submitted =~ @unavailable_copy
      refute submitted =~ @invalid_invite_copy
      assert log =~ "[warning]"
      assert log =~ "LiveKit media server is not configured"
      refute log =~ "Jane Doe"
    end
  end

  describe "outcome 3 — an unusable display name is RECOVERABLE input" do
    test "a whitespace-only invite name returns the guest to name entry, not a dead end",
         %{conn: conn} do
      configure_livekit()
      meeting = create_meeting()

      # A whitespace-only name is a binary, so `resolve_guest_invite/2`
      # routes it to `:in_meeting` rather than to the name-entry form, and
      # the mint is what rejects it. This is the second — and last —
      # failure `mint_guest_join_bundle/2` can produce.
      token = sign_invite(meeting, "   ")

      assert {:ok, %{state: :in_meeting, display_name: "   "}} =
               Meetings.resolve_guest_invite(meeting.slug, token)

      assert {:error, :missing_display_name} =
               Meetings.mint_guest_join_bundle(meeting, "   ")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")

      assigns = assigns_of(view)

      # THIS case's own outcome, and it is NOT the operational card. The
      # guest can fix this one, so they get the form and a reason.
      assert assigns.state == :name_entry
      assert assigns.page_title == "Join #{meeting.name}"
      assert assigns.name_error =~ "Please enter the name others in the meeting will see."
      assert html =~ @name_recovery_copy

      # The exit exists: a working form, not a terminal card.
      assert html =~ "phx-submit=\"submit_name\""

      refute assigns.state == :invalid
      refute assigns.state == :unavailable
      refute html =~ @invalid_invite_copy
      refute html =~ @unavailable_copy

      # ANTI-VACUITY for the recovery itself. The form the guest lands on
      # actually works — configure nothing further, just submit a real
      # name and the join goes through. If this were a decorated dead end
      # the state would not move.
      render_hook(view, "submit_name", %{"guest" => %{"name" => "Jane Doe"}})
      assert assigns_of(view).state == :in_meeting
    end
  end

  describe "outcome 1 — a genuinely bad token is still, and only, :invalid" do
    test "an unverifiable token keeps the invalid-invite card", %{conn: conn} do
      configure_livekit()
      meeting = create_meeting()

      # REACHABILITY, inverted: this one fails at the RESOLVER, before the
      # mint is ever reached. It is the one case where "this link doesn't
      # work" is a true statement.
      assert {:error, :invalid} =
               Meetings.resolve_guest_invite(meeting.slug, "not-a-real-token")

      {:ok, view, html} =
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/not-a-real-token")

      assigns = assigns_of(view)

      assert assigns.state == :invalid
      assert assigns.page_title == @invalid_invite_copy
      assert html =~ @invalid_invite_copy

      # The narrowing must not have leaked in the other direction: an
      # actually-bad link must NOT be excused as our fault.
      refute assigns.state == :unavailable
      refute html =~ @unavailable_copy

      # And a link we cannot verify must not name the meeting it points at.
      refute html =~ meeting.name
    end
  end
end
