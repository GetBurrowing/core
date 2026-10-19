defmodule PlatformWeb.ChatLiveMobileNoSpacesTest do
  @moduledoc """
  A brand-new user on a phone must have SOMEWHERE to tap (task 01a0312e
  stage 8).

  Measured at 390x844 on `/chat` with a DB where `Chat.list_spaces/0`,
  `Chat.list_archived_spaces/0` and `Chat.list_user_conversations/1` are all
  empty: `document.querySelector("main").innerText.trim().length == 0`. The
  §5.1 "no spaces yet" state WAS in the DOM — inside `#chat-sidebar`, which
  computes `display: none` below `lg`. Its mobile counterpart in
  `Partials.MobileBrowser` was dead code for this user: the overlay opens on
  `toggle_mobile_browser`, and the only trigger for that event lives in
  `Partials.Conversation.channel_pills/1`, a `<nav>` gated on `@active_space`.
  Zero spaces, no active space, no trigger — the empty state was behind a door
  with no handle.

  ## Why this file asserts on BOTH populations

  An assertion that `#chat-mobile-no-spaces` renders for the zero-space user
  says nothing on its own: a selector that matched nothing would fail the
  same way whether the fix worked or the selector was a typo, and a `refute`
  over a never-matching selector passes forever. So each test pairs the pane
  with the affordance the OTHER population must keep — a user with a channel
  gets `toggle_mobile_browser` and NOT this pane. The two are mutually
  exclusive by construction, which is exactly what makes the pair
  discriminating.

  Selectors, not `=~` on the copy: the §5.1 strings also render inside
  `#chat-sidebar` and (for a searchless drawer) inside the mobile browser, so
  a substring match cannot tell "reachable on a phone" from "present but
  `display: none`". Everything here goes through `LazyHTML.query/2` over a
  parsed document. Note `LazyHTML.query/2` returns a STRUCT, never a list, so
  emptiness is measured with `Enum.count/1`.

  ## What this file does NOT prove

  It is a server-render test. It proves the node exists in the mobile branch
  of the markup and that its create chip carries a real event; it does not
  execute the `lg:hidden` media query. The defect it guards turns on an
  element being ABSENT FROM THE DOM ENTIRELY for one population, which is a
  server-render property.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @pane "#chat-mobile-no-spaces"
  @mobile_browser_trigger "[phx-click='toggle_mobile_browser']"

  defp admin_conn(conn) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mobile-no-spaces-#{n}@example.com",
        name: "Mobile No Spaces #{n}",
        oidc_sub: "oidc-mobile-no-spaces-#{n}"
      })

    acme = Tenancy.get_org_by_slug!("acme")

    case Repo.get_by(OrgMembership, user_id: user.id, org_id: acme.id) do
      nil ->
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: acme.id, role: "admin"})
        |> Repo.insert!()

      existing ->
        existing |> Ecto.Changeset.change(%{role: "admin"}) |> Repo.update!()
    end

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp channel!(org_slug) do
    n = System.unique_integer([:positive, :monotonic])
    org = Tenancy.get_org_by_slug!(org_slug)

    {:ok, space} =
      Chat.create_space(%{
        name: "Chan #{n}",
        slug: "mobile-no-spaces-chan-#{n}",
        kind: "channel",
        org_id: org.id
      })

    space
  end

  # `/chat` live-redirects to the first ACTIVE channel when one exists, so the
  # populated control has to follow the redirect to reach a rendered surface.
  defp mount_chat(conn) do
    case live(conn, ~p"/chat") do
      {:ok, _view, html} -> html
      {:error, {:live_redirect, %{to: path}}} -> live(conn, path) |> elem(2)
    end
  end

  defp count(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  describe "the mobile content pane for a user with no spaces at all" do
    test "renders the pane, and it is NOT inside the display:none desktop rail",
         %{conn: conn} do
      {conn, _user} = admin_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/chat")

      assert count(html, @pane) == 1,
             "a user with zero spaces must get a create/join affordance in the mobile " <>
               "content region — without it `main` renders zero characters at 390px"

      # The rail's copy is the one that was already there and already hidden.
      # If the new pane were nested inside `#chat-sidebar` it would inherit
      # that `display: none` and fix nothing, so pin where it lives.
      assert count(html, "#chat-sidebar #{@pane}") == 0

      assert count(html, "#{@pane}.lg\\:hidden") == 1,
             "the pane must carry lg:hidden — desktop already has the rail's copy"
    end

    test "the pane's create chip carries a real event, not inert markup", %{conn: conn} do
      {conn, _user} = admin_conn(conn)

      {:ok, view, html} = live(conn, ~p"/chat")

      chips =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#{@pane} button.empty-chip")

      assert Enum.count(chips) == 2,
             "§5.1 pins two CTAs: create a space, connect an agent"

      events = LazyHTML.attribute(chips, "phx-click")

      assert "new_channel_open" in events,
             "expected a literal new_channel_open push among #{inspect(events)}"

      # The event has to be handled, not merely present: an unhandled push
      # crashes the LiveView, which `render/1` would surface here.
      assert view
             |> element("#{@pane} button[phx-click='new_channel_open']")
             |> render_click() =~ "chat-new-channel"
    end

    test "the pane is the ONLY mobile entry point — the pills trigger is genuinely absent",
         %{conn: conn} do
      {conn, _user} = admin_conn(conn)

      {:ok, _view, html} = live(conn, ~p"/chat")

      # This refute is the reason the pane has to exist. It is not vacuous:
      # the positive control below renders the same selector once.
      assert count(html, @mobile_browser_trigger) == 0
      assert count(html, @pane) == 1
    end
  end

  describe "positive control — a user WITH a channel is untouched" do
    test "keeps the normal mobile browser trigger and does not get the pane",
         %{conn: conn} do
      {conn, _user} = admin_conn(conn)
      _space = channel!("hooli")

      html = mount_chat(conn)

      assert count(html, @mobile_browser_trigger) >= 1,
             "the pills-strip search button must still open the mobile browser"

      refute count(html, @pane) == 1
      assert count(html, @pane) == 0
    end

    test "an ARCHIVED-only user gets neither — an archive proves you are not new",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      space = channel!("hooli")
      {:ok, _} = Chat.archive_space(admin, space)

      html = mount_chat(conn)

      assert count(html, @pane) == 0,
             "same `@archived_channels == []` test the rail applies (task 019f4eaa)"
    end
  end
end
