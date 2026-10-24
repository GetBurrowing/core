defmodule PlatformWeb.ChatLiveMaskTitleTest do
  @moduledoc """
  The browser tab title and the chat header under screen-share masking
  (task 01a00c66 stage 5).

  ## Why this file exists at all

  Stage 5's job was to walk the running app with masking on and enumerate every
  surface that still spells a real org name. The first one found was the one
  that matters most: `<title>`. `space_page_title/4` builds the tab from the
  open channel's name, so with `#vandelay-ind` open the rail read `Workspace B`
  while the tab read `# vandelay-ind` — and the tab survives WINDOW-share mode,
  where the rail is not even captured. A masked rail beside an unmasked tab is
  worse than no masking, because the presenter believes they are covered.

  The stage-4 absence file could not have caught this: its fixture opens
  `#general`, a channel named after no org, so its whole-document refutes were
  true whatever the title did. The fixture here opens a channel named after a
  seeded org, which is the only configuration in which the leak exists.

  ## Every assertion is a matched pair

  Same fixture, same surface, mask off instead of on. Without the pair, a
  refute against a title that never carried the name proves nothing — which is
  precisely how the leak survived stages 2 through 4.

  ## The named limitation is pinned, not just described

  `#atlas` is a project-code channel: its name is not the org's name or slug,
  so no rule that infers from org names can catch it, and a hardcoded keyword
  list would be stale the day a new client arrives. The test asserting it stays
  VISIBLE is deliberate. It states the limitation in a form that goes red if
  someone later papers over it with a keyword list, at which point the
  enumeration in the PR body is wrong and has to be revised with the change.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @org "Vandelay-Ind"

  defp authenticated_conn(conn, suffix) do
    user =
      Repo.insert!(%User{
        email: "mask_title_#{suffix}@example.com",
        name: "Mask Title #{suffix}",
        oidc_sub: "oidc-mask-title-#{suffix}",
        avatar_url: nil
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_channel(slug, name) do
    org = Platform.Tenancy.get_org_by_slug(slug)

    {:ok, channel} =
      Chat.create_space(%{name: name, slug: slug, kind: "channel", org_id: org && org.id})

    channel
  end

  # The org-named channel this whole file turns on, plus a plain one so the
  # rail is not a single row.
  defp fixture(conn, suffix) do
    create_channel("general", "General")
    channel = create_channel("vandelay-ind", @org)
    {:ok, view, html} = live(authenticated_conn(conn, suffix), ~p"/chat/#{channel.slug}")
    {view, html}
  end

  defp toggle_mask(view) do
    view
    |> element(~s(#chat-sidebar button[phx-click="toggle_mask_names"]))
    |> render_click()
  end

  defp header(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("header")
    |> LazyHTML.to_html()
  end

  describe "browser tab title" do
    test "MATCHED PAIR: unmasked, the tab spells the org-named channel", %{conn: conn} do
      {view, _html} = fixture(conn, "title-pair")

      assert_name_anywhere(page_title(view), @org)
    end

    test "masked, the tab carries the placeholder and no spelling of the name",
         %{conn: conn} do
      {view, _html} = fixture(conn, "title")

      # Pre-condition, asserted rather than assumed: the surface under test
      # carries the real name before the toggle, so the refute below is about
      # masking and not about an empty title.
      assert_name_anywhere(page_title(view), @org)

      toggle_mask(view)
      title = page_title(view)

      refute_name_anywhere(title, @org)

      assert title =~ ~r/^#\s*workspace-[a-z]+$/,
             "expected a `# workspace-<letter>` tab title, got #{inspect(title)}"
    end

    test "the title follows a per-section reveal and the re-mask after it", %{conn: conn} do
      {view, html} = fixture(conn, "title-reveal")

      # Read the org's own section id off the UNMASKED render rather than
      # assuming a rail position — the letter is a position, so hardcoding one
      # would make this test a statement about seed order.
      section_id = section_id_named(html, @org)

      toggle_mask(view)
      refute_name_anywhere(page_title(view), @org)

      view
      |> element(
        ~s(#chat-sidebar button[phx-click="reveal_section"][phx-value-section_id="#{section_id}"])
      )
      |> render_click()

      # Revealing the org's own section must bring the tab back with it.
      # Otherwise the reveal is a half-measure: the rail shows the name while
      # the tab still says `workspace-b`, and the two disagree on screen.
      assert_name_anywhere(page_title(view), @org)

      view |> element(~s(button[phx-click="remask_all"])) |> render_click()
      refute_name_anywhere(page_title(view), @org)
    end
  end

  # Attribute ORDER inside the tag is not asserted — the open tag is found by
  # its key and the id read out of it, so a template reshuffle cannot turn this
  # into a silent nil and a MatchError three lines later.
  defp section_id_named(html, name) do
    tag =
      ~r/<section[^>]*>/
      |> Regex.scan(html)
      |> Enum.map(&hd/1)
      |> Enum.find(&String.contains?(&1, ~s(data-section-key="#{name}")))

    assert tag, "no rail section carries data-section-key=#{inspect(name)}"

    [_, id] = Regex.run(~r/data-section-id="([^"]+)"/, tag)
    id
  end

  describe "chat header" do
    test "MATCHED PAIR: unmasked, the header spells the channel name", %{conn: conn} do
      {_view, html} = fixture(conn, "header-pair")

      assert_name_anywhere(header(html), @org)
    end

    test "masked, neither breakpoint's header node carries the name", %{conn: conn} do
      {view, _html} = fixture(conn, "header")

      masked_header = view |> toggle_mask() |> header()

      assert masked_header != "", "the header must render, or this refute is vacuous"
      refute_name_anywhere(masked_header, @org)

      # Both breakpoints, explicitly: the mobile and desktop titles are
      # separate nodes and a mask applied to only one of them renders
      # correctly at whichever width the author happened to test.
      assert masked_header
             |> String.downcase()
             |> then(&Regex.scan(~r/workspace-[a-z]+/, &1))
             |> length() >= 2,
             "expected the placeholder in BOTH the mobile and desktop header titles"
    end
  end

  # The Members popover renders INSIDE the header and the phone sheet outside
  # it; both titles read "Members · <space name>" (task 01a1557a-8f80 stage
  # 3). The first cut built that from `space.name`, so masking hid the header
  # title and the popover beside it spelled the channel out.
  describe "Members sheet title" do
    defp members(view) do
      view |> element(~s(button[data-role="members-open"])) |> render_click()

      ["#chat-members-popover", "#chat-members"]
      |> Enum.map(fn id -> view |> element(id) |> render() end)
    end

    test "MATCHED PAIR: unmasked, both Members instances spell the channel name",
         %{conn: conn} do
      {view, _html} = fixture(conn, "members-pair")

      for html <- members(view), do: assert_name_anywhere(html, @org)
    end

    test "masked, neither Members instance carries the name", %{conn: conn} do
      {view, _html} = fixture(conn, "members")
      toggle_mask(view)

      for html <- members(view) do
        assert html =~ "Members · ", "the title must render, or this refute is vacuous"
        refute_name_anywhere(html, @org)
      end
    end
  end

  describe "named limitation: project-code channels" do
    test "a channel whose name is not its org's name stays visible, masked or not",
         %{conn: conn} do
      create_channel("general", "General")
      atlas = create_channel("atlas", "Atlas")

      {:ok, view, _html} =
        live(authenticated_conn(conn, "atlas"), ~p"/chat/#{atlas.slug}")

      toggle_mask(view)

      # NOT a bug and NOT an oversight: `atlas` is neither the name nor the
      # slug of any org, so no rule inferring from org names can reach it. The
      # PR body lists this as uncovered. If this assertion ever goes red
      # because a keyword list was added, the enumeration is stale and must be
      # revised in the same change.
      assert String.downcase(page_title(view)) =~ "atlas"
    end
  end
end
