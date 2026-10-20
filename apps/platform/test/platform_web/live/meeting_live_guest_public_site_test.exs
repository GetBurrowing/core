defmodule PlatformWeb.MeetingLiveGuestPublicSiteTest do
  @moduledoc """
  Task 01a04352-dae4-729d-955b-1ea967a927c1.

  The three guest FAILURE cards — expired invite, invalid invite, meetings
  temporarily unavailable — each carried one outbound action whose host was a
  literal in `meeting_live.html.heex`. `core` is a public repository, so that
  literal instructed every deployment's external guests to visit one
  particular company's website, with no configuration path around it.

  ## What these tests are built to catch, and how

  A test that asserts "the configured host renders" passes against an
  implementation that also keeps a baked-in default — it never looks at what
  ELSE is on the page. So the assertions here are about the WHOLE set of
  outbound links in the rendered card, not one link:

      outbound_links(html) == ["https://" <> configured_host]

  Set equality is what makes a literal impossible. Any host compiled into the
  template shows up as an extra element (or, before this change, as the only
  element and not the configured one) and the assertion fails. It also lets
  this file state the invariant WITHOUT NAMING the leaked hostname — writing
  `refute html =~ "<the real domain>"` would republish it in the very repo
  the task is scrubbing, and would only ever pin that one string.

  Each case is run against TWO different configured hosts. One host cannot
  distinguish "renders the configured value" from "renders a constant that
  happens to match".

  The unconfigured half is equally load-bearing: with nothing configured the
  action must be ABSENT from the DOM — not an empty label, not a dead `href`,
  and not the word `nil` on a page shown to an outside visitor. The card's
  own copy has to carry the guest on its own, so each case asserts the
  heading and the "ask whoever invited you" sentence survive.

  `async: false`: `:public_site_host` and `:livekit` are global app env.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Repo
  alias Platform.Tasks
  alias PlatformWeb.PublicSite

  # Obviously-fake hosts, in the RFC 2606 reserved `.example` / `.invalid`
  # space. Two of them, so a constant cannot pass as a configured value.
  @host_a "guest-actions.example"
  @host_b "another-deployment.invalid"

  @expired_copy "This invite has expired"
  @invalid_copy "Invite link is not valid"
  # `render_unavailable_card/1` below reaches this card through
  # `:livekit_not_configured`, which task 01a04353 classified as a
  # PERMANENT fault — so the heading it renders is the no-retry variant,
  # not the "temporarily" one the card carried before. This constant only
  # has to identify the card; the wording itself is owned by
  # `meeting_live_guest_infra_error_test.exs`.
  @unavailable_copy "We can&#39;t connect you to this meeting"

  setup do
    # Start every test from the UNSET state regardless of what the host
    # environment exports, and restore whatever was there afterwards.
    original = Application.fetch_env(:platform, :public_site_host)
    Application.delete_env(:platform, :public_site_host)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:platform, :public_site_host, value)
        :error -> Application.delete_env(:platform, :public_site_host)
      end
    end)

    :ok
  end

  defp put_public_site(host), do: Application.put_env(:platform, :public_site_host, host)

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

  # `[]` is "not configured" to `livekit_config/0`: a list, but empty, so it
  # falls through to LIVEKIT_* env vars the test environment does not set.
  defp unconfigure_livekit, do: put_livekit_env([])

  defp create_meeting do
    org_id = Platform.TenancyFixtures.acme_org_id()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Guest Public Site Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Guest Public Site Kickoff #{System.unique_integer([:positive])}"
      })

    Repo.preload(meeting, :chat_space)
  end

  defp with_meet_host(conn), do: %{conn | host: "meet.localhost"}

  defp sign_invite(meeting, display_name, offset_seconds) do
    expires_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(offset_seconds)
    GuestInvite.sign(meeting.slug, expires_at, display_name, meeting_id: meeting.id)
  end

  # EVERY absolute outbound link in the rendered card, by element, never by
  # regex over attribute order. This is the assertion surface: what the page
  # offers a guest is the whole list, not the one link a test went looking
  # for.
  defp outbound_links(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(a[href^="http"]))
    |> LazyHTML.attribute("href")
    |> Enum.sort()
  end

  # What a guest reads: the document's text content, without attribute
  # values (which hold random session and CSRF tokens).
  defp guest_text(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.text()
  end

  defp action_blocks(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".card-actions")
    |> Enum.to_list()
  end

  # ── the three cards, each mounted the way its own state is reached ──────

  defp render_expired_card(conn) do
    meeting = create_meeting()
    token = sign_invite(meeting, "Jane Doe", -3600)

    # Reachability: the resolver really does refuse this as EXPIRED. A green
    # from some other refusal would be a green about a different card.
    assert {:error, :expired} = Meetings.resolve_guest_invite(meeting.slug, token)

    {:ok, view, html} =
      conn
      |> with_meet_host()
      |> live("/#{meeting.slug}/#{token}")

    assert :sys.get_state(view.pid).socket.assigns.state == :expired
    assert html =~ @expired_copy
    html
  end

  defp render_invalid_card(conn) do
    meeting = create_meeting()
    token = sign_invite(meeting, "Jane Doe", 3600) <> "tamper"

    assert {:error, :invalid} = Meetings.resolve_guest_invite(meeting.slug, token)

    {:ok, view, html} =
      conn
      |> with_meet_host()
      |> live("/#{meeting.slug}/#{token}")

    assert :sys.get_state(view.pid).socket.assigns.state == :invalid
    assert html =~ @invalid_copy
    html
  end

  defp render_unavailable_card(conn) do
    configure_livekit()
    meeting = create_meeting()
    token = sign_invite(meeting, "Jane Doe", 3600)

    # Reachability, in two parts: the invite is GOOD, and only the media
    # mint fails. Otherwise this could be the invalid card wearing a
    # different name.
    assert {:ok, %{state: :in_meeting}} = Meetings.resolve_guest_invite(meeting.slug, token)
    unconfigure_livekit()

    assert {:error, :livekit_not_configured} =
             Meetings.mint_guest_join_bundle(meeting, "Jane Doe")

    {{:ok, view, html}, _log} =
      with_log(fn ->
        conn
        |> with_meet_host()
        |> live("/#{meeting.slug}/#{token}")
      end)

    assert :sys.get_state(view.pid).socket.assigns.state == :unavailable
    assert html =~ @unavailable_copy
    html
  end

  @cards ["expired-invite", "invalid-invite", "temporarily-unavailable"]

  describe "the guest cards' outbound action comes from configuration" do
    for name <- @cards do
      @card_name name

      test "#{name}: the ONLY outbound link is the configured host, for two different hosts",
           %{conn: conn} do
        render = card_renderer(@card_name)

        put_public_site(@host_a)
        html_a = render.(conn)

        # Set equality, not `=~`. A literal left in the template would be an
        # extra link here — or, before the fix, the only one.
        assert outbound_links(html_a) == ["https://#{@host_a}"],
               "expected exactly one outbound link, the configured host, got: " <>
                 inspect(outbound_links(html_a))

        assert html_a =~ "Go to #{@host_a}"

        # A SECOND, unrelated host. Together with the first, this is what
        # separates "renders the configured value" from "renders a constant".
        put_public_site(@host_b)
        html_b = render.(conn)

        assert outbound_links(html_b) == ["https://#{@host_b}"],
               "expected exactly one outbound link, the configured host, got: " <>
                 inspect(outbound_links(html_b))

        assert html_b =~ "Go to #{@host_b}"

        # And the two renders genuinely differ — a template that ignored the
        # config entirely would satisfy neither of the above, but this makes
        # the dependence explicit.
        refute html_a == html_b
      end

      test "#{name}: with NOTHING configured the action is absent, and the card still helps",
           %{conn: conn} do
        render = card_renderer(@card_name)

        # `setup` deleted the key. This is the shipped default for every
        # deployment that has not set PUBLIC_SITE_HOST.
        refute PublicSite.configured?()

        html = render.(conn)

        assert outbound_links(html) == [],
               "an unconfigured deployment must offer a guest NO outbound link, got: " <>
                 inspect(outbound_links(html))

        # Absent, not empty: no dead action block, no empty href, and none
        # of the ways a nil leaks into guest copy.
        assert action_blocks(html) == []
        refute html =~ ~s(href="")
        refute html =~ ~s(href="https://")
        refute html =~ "Go to"
        # Over the page's TEXT, not its raw HTML: the raw page carries random
        # signed tokens (data-phx-session, the CSRF meta, phx ids), and one
        # with "nil" in its base64 failed this on CI run 39485975295.
        text = guest_text(html)
        refute text =~ "nil"
        # Positive control: `text` is the card's copy, so the refute is not
        # passing on an empty string.
        assert text =~ "invited you" or text =~ "meeting host"

        # The card still reads sensibly on its own — the heading it exists
        # to show, and the next step that actually helps the guest.
        assert html =~ card_copy(@card_name)
        assert html =~ "invited you" or html =~ "meeting host"
      end

      test "#{name}: a blank configured value is the unconfigured case, not an empty button",
           %{conn: conn} do
        render = card_renderer(@card_name)

        put_public_site("   ")
        refute PublicSite.configured?()

        html = render.(conn)

        assert outbound_links(html) == []
        assert action_blocks(html) == []
        refute html =~ "Go to"
      end
    end
  end

  describe "PublicSite reads the key once, with no default" do
    test "unset, nil, empty and whitespace all mean the same thing" do
      Application.delete_env(:platform, :public_site_host)
      refute PublicSite.configured?()
      assert PublicSite.url() == nil
      assert PublicSite.display_host() == nil

      for blank <- [nil, "", "   ", "\t", "https://"] do
        put_public_site(blank)
        refute PublicSite.configured?(), "expected #{inspect(blank)} to read as unconfigured"
        assert PublicSite.url() == nil
      end
    end

    test "a value configured as a full URL renders as a host, and never doubles the scheme" do
      for configured <- [
            "https://#{@host_a}",
            "http://#{@host_a}",
            "#{@host_a}/",
            "  #{@host_a} "
          ] do
        put_public_site(configured)

        assert PublicSite.display_host() == @host_a,
               "expected #{inspect(configured)} to display as #{@host_a}"

        assert PublicSite.url() == "https://#{@host_a}"
      end
    end
  end

  # Dispatch by name so the generated tests above stay readable; a captured
  # function in a module attribute cannot survive `unquote` into a test body.
  defp card_renderer("expired-invite"), do: &render_expired_card/1
  defp card_renderer("invalid-invite"), do: &render_invalid_card/1
  defp card_renderer("temporarily-unavailable"), do: &render_unavailable_card/1

  defp card_copy("expired-invite"), do: @expired_copy
  defp card_copy("invalid-invite"), do: @invalid_copy
  defp card_copy("temporarily-unavailable"), do: @unavailable_copy
end
