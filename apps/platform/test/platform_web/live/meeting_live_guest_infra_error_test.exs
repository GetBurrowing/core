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

  ## Task 01a04353 — the card's promise now matches the fault

  The `:unavailable` card used to be one string ending "Please try again in
  a few minutes". Every fault that reaches it is reached through
  `MeetingLive.classify_guest_mint_failure/2`, and BOTH faults it can
  classify today are permanent: `:livekit_not_configured` is a synchronous
  config read, and a nil `chat_space_id` is a data defect written (or not)
  inside `create_meeting/1`'s single transaction. Neither self-heals while
  a guest waits, so obeying the retry instruction produced the identical
  card forever.

  The card now splits on `@unavailable_kind`, and this file pins BOTH
  directions, because a one-directional test would pass equally well if the
  fix had simply replaced the retry sentence everywhere:

    * `:permanent` → no timeframe, no retry sentence, points at the invite
      sender. Asserted end-to-end through a real guest mount.
    * `:unknown` (the catch-all, for a mint atom we do not yet know) →
      KEEPS the retry sentence. Asserted at the classifier, which is the
      only reachable seam — `mint_guest_join_bundle/2`'s error set is
      closed — and at the render, so both the decision and the copy it
      selects are covered.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.MeetingLive

  @invalid_invite_copy "Invite link is not valid"
  @unavailable_copy "Meetings are temporarily unavailable"
  @unavailable_body "Your invite link is fine"
  @name_recovery_copy "We couldn&#39;t read the name on your invite."

  # The permanent variant's title and its load-bearing clause — the one that
  # replaced the promise the state could not keep.
  @permanent_title "We can&#39;t connect you to this meeting"
  @permanent_title_raw "We can't connect you to this meeting"
  @permanent_body "it is not something that will clear on its own"

  # The retry sentence. Asserted ABSENT on the permanent card and PRESENT on
  # the unknown one; that pairing is the whole point of the change.
  @retry_promise "Please try again in a few minutes"

  # Stable selector, owned by `meeting_live.html.heex` (not by this file).
  @card_selector "#guest-unavailable-card"

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
      assert assigns.unavailable_kind == :permanent
      assert assigns.page_title == @permanent_title_raw
      assert html =~ @permanent_title
      assert html =~ @unavailable_body

      # PERMANENCE (task 01a04353). An unconfigured media plane cannot come
      # good while the guest waits, so the card must not tell them to wait,
      # and must not call itself "temporarily" anything. Both the promise
      # and the old title are asserted GONE — dropping either assertion
      # would let the lie back in through the other.
      assert has_element?(view, @card_selector <> "[data-unavailable-kind=permanent]")
      assert html =~ @permanent_body
      refute html =~ @retry_promise
      refute html =~ @unavailable_copy

      # ...but the sentence that was 019f9cb7's entire fix is untouched.
      # `@unavailable_body` above is that sentence's opening; this pins that
      # the guest is still not being blamed for their link.
      refute html =~ @invalid_invite_copy

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

      # ...and greppable by the ATOM, not only by the prose (task
      # 01a04353). That is the search term an operator actually has: it is
      # what the `@spec` says, what `meetings.ex` returns and what every
      # ticket about this failure calls it. Asserted as the atom STRING
      # rather than "a warning was emitted", because the pre-01a04353
      # implementation already emitted a warning and would have passed the
      # looser assertion unchanged.
      assert log =~ "livekit_not_configured"
      assert log =~ "reason=livekit_not_configured"

      # The prose is NOT replaced by the atom — a human reading the log
      # still gets the sentence saying the invite verified and what the
      # guest was shown. Both, which is why both are asserted.
      assert log =~ "The invite itself verified"

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
      assert assigns.unavailable_kind == :permanent
      assert submitted =~ @permanent_title
      assert submitted =~ @unavailable_body
      refute submitted =~ @invalid_invite_copy

      # The two entry points must agree about permanence too, not just
      # about which card. A retry promise reintroduced on only one of them
      # is exactly the drift stage 2 collapsed.
      refute submitted =~ @retry_promise
      refute submitted =~ @unavailable_copy

      assert log =~ "[warning]"
      assert log =~ "LiveKit media server is not configured"
      assert log =~ "reason=livekit_not_configured"
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
      refute html =~ @permanent_title

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
      refute html =~ @permanent_title

      # And a link we cannot verify must not name the meeting it points at.
      refute html =~ meeting.name
    end
  end

  describe "outcome 4 — permanence, in BOTH directions (task 01a04353)" do
    # The card's wording is chosen by `classify_guest_mint_failure/2`, so
    # that is where the decision is pinned. It is `@doc false` public for
    # exactly this: the `:unknown` clause cannot be reached through
    # `mint_guest_join_bundle/2`, whose error set is closed, so a
    # mount-only test could only ever exercise the permanent half — and a
    # fix that made EVERY fault permanent would pass it.

    test "an unconfigured media server is classified :permanent" do
      meeting = create_meeting()

      assert {:fault, :permanent, detail} =
               MeetingLive.classify_guest_mint_failure(meeting, :livekit_not_configured)

      assert detail =~ "not configured"
    end

    test "a meeting with no chat space is classified :permanent" do
      # The other fault that reaches the card. `create_meeting/1` writes the
      # space and the meeting in ONE transaction, so this shape is a data
      # defect rather than a window a guest can wait out — which is why it
      # is permanent and not merely slow.
      assert {:fault, :permanent, detail} =
               MeetingLive.classify_guest_mint_failure(
                 %Meeting{chat_space_id: nil},
                 :missing_display_name
               )

      assert detail =~ "no backing chat space"
    end

    test "an unrecognised mint failure is classified :unknown, NOT :permanent" do
      # THE OTHER DIRECTION. A future atom might well be a transient
      # upstream failure, so it keeps the retry wording. Asserting
      # `:unknown` rather than `!= :permanent` means a later edit that
      # invents a third permanence cannot slip through here silently.
      meeting = create_meeting()

      assert {:fault, :unknown, detail} =
               MeetingLive.classify_guest_mint_failure(meeting, :some_future_livekit_failure)

      assert detail =~ "unrecognised mint failure"
    end

    test "a recoverable name is not a fault at all" do
      # Control: the classifier still has a non-fault outcome, so the two
      # `:fault` assertions above are discriminating rather than describing
      # the only tuple the function can return.
      meeting = create_meeting()

      assert {:recoverable_name, _message} =
               MeetingLive.classify_guest_mint_failure(meeting, :missing_display_name)
    end

    test ":permanent drops the retry sentence and :unknown keeps it" do
      # Both cards, rendered from the same template, differing only in
      # `@unavailable_kind`. Rendered directly because the `:unknown` kind
      # has no reachable mount path (see the describe comment); the
      # end-to-end permanent case is covered by outcome 2 above.
      meeting = create_meeting()

      permanent = render_unavailable_card(meeting, :permanent)
      unknown = render_unavailable_card(meeting, :unknown)

      # The retry promise exists on exactly one of the two. Asserted as a
      # pair: either assertion alone would pass a change that made every
      # card say the same thing.
      refute permanent =~ @retry_promise
      assert unknown =~ @retry_promise

      # ...and so does the "temporarily" framing in the heading.
      refute permanent =~ @unavailable_copy
      assert unknown =~ @unavailable_copy
      # `@permanent_title_raw`, not the escaped form: `live/2` returns HTML
      # that has been through a parse/serialize round-trip (which turns the
      # apostrophe into `&#39;`), whereas `rendered_to_string/1` hands back
      # the template's own bytes. Same sentence, two encodings.
      assert permanent =~ @permanent_title_raw
      refute unknown =~ @permanent_title_raw

      # The opening sentence — the whole of 019f9cb7's fix — survives on
      # BOTH. The guest is never told their link is the problem.
      assert permanent =~ @unavailable_body
      assert unknown =~ @unavailable_body

      # The stable selector carries the kind, and it is the template that
      # owns it: both variants render the same node id.
      assert card_kind(permanent) == ["permanent"]
      assert card_kind(unknown) == ["unknown"]

      # LEAK SCAN, re-run against the NEW copy. The permanent card explains
      # less, not more: no service name, no error atom, no internal id.
      for html <- [permanent, unknown] do
        refute html =~ "livekit"
        refute html =~ "LiveKit"
        refute html =~ "livekit_not_configured"
        refute html =~ "missing_display_name"
        refute html =~ meeting.id
      end
    end
  end

  # Renders MeetingLive's template at the `:unavailable` branch. The
  # top-level cond short-circuits there, so these are every assign the
  # branch reads.
  defp render_unavailable_card(meeting, kind) do
    rendered_to_string(
      MeetingLive.render(%{
        chrome_mode: :none,
        state: :unavailable,
        unavailable_kind: kind,
        meeting: meeting,
        public_site_url: nil,
        public_site_host: nil
      })
    )
  end

  # `query/2`, not `filter/2`: filter matches only the fragment's ROOT
  # nodes, and the card sits two divs deep, so filter returns `[]` here —
  # an empty list that looks exactly like "the attribute is missing".
  defp card_kind(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(@card_selector)
    |> LazyHTML.attribute("data-unavailable-kind")
  end
end
