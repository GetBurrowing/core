defmodule PlatformWeb.SocialLiveIdeasPhoneFocusUrlTest do
  @moduledoc """
  The design owner's three fixes to the Ideas page:

    1. the phone layout (Select / Unselect below the row content). There is no
       real browser here: these tests assert the structure and the Tailwind
       classes that stack the row on a phone, not rendered pixels;
    2. focus and announcement after Select / Unselect (the pushed focus target
       id and the polite live region text; the hook moving real focus is
       covered by the node test in `assets/test/social_ideas.node.mjs`);
    3. the view and brand in the address. Social is nested by
       `ExtensionPageLive` with `live_render/3` (no `push_patch`, no
       `handle_params`), and a hook's `pushState` raced LiveView's own history
       handling (Back left the page on another view). The view controls are
       ordinary links that carry `tab`, `view` and the brand SHOWN (`profile=all`
       for All brands); `from_query/2` reads them at mount. The browser owns Back
       and Forward (see `test/browser/ideas_navigation.browser.mjs`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures

  alias Platform.Social.Ideas

  setup do
    previous = Application.get_env(:social, :ideas_refresh_ms)
    Application.put_env(:social, :ideas_refresh_ms, 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:social, :ideas_refresh_ms, previous),
        else: Application.delete_env(:social, :ideas_refresh_ms)
    end)

    approval_fixture() |> with_ideas_runtime()
  end

  defp open(conn, user, ctx, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _} = live(conn, "/m/social?tab=ideas&profile=#{ctx.profile.id}" <> query)
    find_live_child(view, "ext-page-social")
  end

  defp idea!(ctx, title) do
    {:ok, idea} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: title}, {:agent, ctx.g.id})
    idea
  end

  defp select!(ctx, idea, user),
    do: {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, idea.id, {:user, user.id})

  defp view_tab(view), do: "[data-role='ideas-view-tab'][data-view='#{view}']"

  defp href(child, view) do
    [href] = child |> doc() |> LazyHTML.query(view_tab(view)) |> LazyHTML.attribute("href")
    href
  end

  # A second brand in the same org, visible to the same people.
  defp second_brand!(ctx, name \\ nil) do
    {:ok, other} =
      Platform.Social.create_profile(ctx.org_id, %{
        name: name || "ZZ #{System.unique_integer([:positive])} second",
        space_id: ctx.space.id,
        approver_user_ids: [ctx.h1.id]
      })

    other
  end

  defp open_url(conn, user, url) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _} = live(conn, url)
    {view, find_live_child(view, "ext-page-social")}
  end

  defp shown(child), do: child |> render() |> String.replace(~r/\s+/, " ")

  defp doc(child), do: child |> render() |> LazyHTML.from_fragment()

  defp announcement(child),
    do:
      child
      |> doc()
      |> LazyHTML.query("[data-role='ideas-announcement']")
      |> LazyHTML.text()
      |> String.trim()

  defp classes(child, selector) do
    [class] = child |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute("class")
    String.split(class)
  end

  # ── 1. Phone layout ──────────────────────────────────────────────────

  describe "phone layout (structure and classes only; no real browser here)" do
    test "Select sits in its own container after the row content, stacked on a phone",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "A long idea title that must keep the full width of the row on a phone")
      child = open(conn, ctx.n, ctx)
      card = "#idea-card-#{idea.id}"

      # the button lives in the actions container, not in the content
      assert has_element?(child, "#{card} [data-role='idea-actions'] [data-role='idea-select']")

      refute has_element?(
               child,
               "#{card} [data-role='idea-card-content'] [data-role='idea-select']"
             )

      # the actions container follows the content container as its next sibling
      assert has_element?(
               child,
               "#{card} [data-role='idea-card-content'] + [data-role='idea-actions']"
             )

      # the row stacks on a phone and goes back to a row from sm up
      row = classes(child, "#{card} [data-role='idea-card-row']")
      assert "flex-col" in row and "sm:flex-row" in row

      # the title is not squeezed: the content takes the full row on a phone
      assert "w-full" in classes(child, "#{card} [data-role='idea-card-content']")

      # the button fills the row on a phone and keeps a 44px tap target
      button = classes(child, "#{card} [data-role='idea-select']")
      assert "min-h-11" in button and "max-sm:w-full" in button
    end

    test "Unselect has the same stacking and tap target", %{conn: conn} = ctx do
      idea = idea!(ctx, "Chosen")
      select!(ctx, idea, ctx.n)
      child = open(conn, ctx.n, ctx)
      card = "#idea-card-#{idea.id}"

      assert has_element?(
               child,
               "#{card} [data-role='idea-card-content'] + [data-role='idea-actions'] [data-role='idea-unselect']"
             )

      button = classes(child, "#{card} [data-role='idea-unselect']")
      assert "min-h-11" in button and "max-sm:w-full" in button
    end
  end

  # ── 2. Announcement and focus ────────────────────────────────────────

  describe "announcement" do
    test "a polite live region is always present and empty at rest", %{conn: conn} = ctx do
      idea!(ctx, "Quiet")
      child = open(conn, ctx.n, ctx)

      assert has_element?(
               child,
               "[data-role='ideas-announcement'][role='status'][aria-live='polite']"
             )

      assert announcement(child) == ""
    end

    test "Select announces 'Selected for research', Unselect announces 'Unselected'",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Announce me")
      child = open(conn, ctx.n, ctx)

      child |> element("#idea-select-#{idea.id}") |> render_click()
      assert announcement(child) == "Selected for research"

      child |> element("#idea-unselect-#{idea.id}") |> render_click()
      assert announcement(child) == "Unselected"
    end

    test "a repeat of the same text is a new node, so it is announced again",
         %{conn: conn} = ctx do
      a = idea!(ctx, "A")
      b = idea!(ctx, "B")
      child = open(conn, ctx.n, ctx)

      child |> element("#idea-select-#{a.id}") |> render_click()

      [first] =
        child
        |> doc()
        |> LazyHTML.query("[data-role='ideas-announcement'] [id]")
        |> LazyHTML.attribute("id")

      child |> element("#idea-select-#{b.id}") |> render_click()

      [second] =
        child
        |> doc()
        |> LazyHTML.query("[data-role='ideas-announcement'] [id]")
        |> LazyHTML.attribute("id")

      assert announcement(child) == "Selected for research"
      assert first != second
    end
  end

  describe "focus" do
    test "(a) Select in All keeps focus on the same row's control, now Unselect",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Focus a")
      child = open(conn, ctx.n, ctx)

      child |> element("#idea-select-#{idea.id}") |> render_click()
      target = "idea-unselect-#{idea.id}"
      assert_push_event(child, "ideas:focus", %{id: ^target})
      assert has_element?(child, "##{target}")
    end

    test "(b) Unselect in All keeps focus on the same row's control, now Select",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Focus b")
      select!(ctx, idea, ctx.n)
      child = open(conn, ctx.n, ctx)

      child |> element("#idea-unselect-#{idea.id}") |> render_click()
      target = "idea-select-#{idea.id}"
      assert_push_event(child, "ideas:focus", %{id: ^target})
      assert has_element?(child, "##{target}")
    end

    test "(c) Unselect in Selected moves focus to the next row's control",
         %{conn: conn} = ctx do
      a = idea!(ctx, "Sel a")
      b = idea!(ctx, "Sel b")
      c = idea!(ctx, "Sel c")
      for i <- [a, b, c], do: select!(ctx, i, ctx.n)
      child = open(conn, ctx.n, ctx, "&view=selected")

      ids =
        child
        |> doc()
        |> LazyHTML.query("#ideas-list [data-role='idea-card']")
        |> LazyHTML.attribute("data-idea-id")

      [first, second | _] = ids

      child |> element("#idea-unselect-#{first}") |> render_click()
      target = "idea-unselect-#{second}"
      assert_push_event(child, "ideas:focus", %{id: ^target})
      refute has_element?(child, "#idea-card-#{first}")
    end

    test "(c') Unselect of the last of several Selected rows falls back to the row before it",
         %{conn: conn} = ctx do
      a = idea!(ctx, "Sel a")
      b = idea!(ctx, "Sel b")
      for i <- [a, b], do: select!(ctx, i, ctx.n)
      child = open(conn, ctx.n, ctx, "&view=selected")

      ids =
        child
        |> doc()
        |> LazyHTML.query("#ideas-list [data-role='idea-card']")
        |> LazyHTML.attribute("data-idea-id")

      [first, last] = ids

      child |> element("#idea-unselect-#{last}") |> render_click()
      target = "idea-unselect-#{first}"
      assert_push_event(child, "ideas:focus", %{id: ^target})
    end

    test "(d) Unselect of the last Selected row moves focus to the view heading",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Only one")
      select!(ctx, idea, ctx.n)
      child = open(conn, ctx.n, ctx, "&view=selected")

      child |> element("#idea-unselect-#{idea.id}") |> render_click()
      assert_push_event(child, "ideas:focus", %{id: "ideas-view-heading"})
      assert has_element?(child, "#ideas-view-heading[tabindex='-1']", "Selected for research")
      assert has_element?(child, "[data-role='ideas-empty'][data-view='selected']")
    end

    test "a refused click pushes no focus", %{conn: conn} = ctx do
      idea!(ctx, "Refused")
      child = open(conn, ctx.n, ctx)
      render_hook(child, "ideas_select", %{"id" => Ecto.UUID.generate()})
      refute_push_event(child, "ideas:focus", _)
    end
  end

  # ── 3. The view and brand in the address ─────────────────────────────

  describe "the view in the address: ordinary links" do
    test "each view is a plain link naming tab, view and the shown brand; no client history",
         %{conn: conn} = ctx do
      idea!(ctx, "One")
      child = open(conn, ctx.n, ctx)
      pid = ctx.profile.id

      for view <- ~w(all voted selected) do
        assert href(child, view) == "?tab=ideas&view=#{view}&profile=#{pid}"
        assert has_element?(child, "a#{view_tab(view)}")
        refute has_element?(child, "#{view_tab(view)}[phx-click]")
        refute has_element?(child, "#{view_tab(view)}[data-phx-link]")
      end

      # the hook root stays for focus; it is given no address to write
      assert has_element?(child, "#social-ideas[phx-hook='SocialIdeas']")
    end

    test "a click on a view writes nothing: no URL push event exists", %{conn: conn} = ctx do
      idea!(ctx, "One")
      child = open(conn, ctx.n, ctx)
      refute_push_event(child, "ideas:url", _)
      render_hook(child, "ideas_view", %{"view" => "voted"})
      render_hook(child, "ideas_view_url", %{"view" => "voted"})
      refute_push_event(child, "ideas:url", _)
      assert has_element?(child, "#ideas-list[data-view='all']")
    end

    test "Open All ideas from the empty Selected view is a link too", %{conn: conn} = ctx do
      idea!(ctx, "One")
      child = open(conn, ctx.n, ctx, "&view=selected")

      assert has_element?(
               child,
               "a[data-role='ideas-empty-all'][href='?tab=ideas&view=all&profile=#{ctx.profile.id}']"
             )

      refute has_element?(child, "[data-role='ideas-empty-all'][phx-click]")
    end

    test "loading the URL shows that view", %{conn: conn} = ctx do
      a = idea!(ctx, "Plain")
      b = idea!(ctx, "Chosen")
      select!(ctx, b, ctx.n)

      child = open(conn, ctx.n, ctx, "&view=selected")
      assert has_element?(child, "#ideas-list[data-view='selected']")
      assert has_element?(child, "#idea-card-#{b.id}")
      refute has_element?(child, "#idea-card-#{a.id}")
      assert has_element?(child, "#{view_tab("selected")}[aria-current='page']")
    end

    test "an invalid view falls back to All", %{conn: conn} = ctx do
      idea!(ctx, "Plain")
      child = open(conn, ctx.n, ctx, "&view=bogus")
      assert has_element?(child, "#ideas-list[data-view='all']")
      assert has_element?(child, "#{view_tab("all")}[aria-current='page']")
    end

    test "adding an idea from another view tells where it went and keeps the view",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1, ctx, "&view=voted")
      child |> element("[data-role='ideas-quick-open']") |> render_click()
      child |> form("#ideas-quick-form", idea: %{title: "Fresh"}) |> render_submit()

      assert has_element?(child, "#ideas-list[data-view='voted']")
      assert has_element?(child, "[data-role='ideas-notice']", "Idea added to All ideas.")
      assert has_element?(child, "#{view_tab("all")} [data-role='ideas-view-count']", "1")
    end
  end

  describe "All brands in the address (profile=all)" do
    test "a viewer of several brands gets All brands; the links say so", %{conn: conn} = ctx do
      other = second_brand!(ctx)
      mine = idea!(ctx, "Idea of the first brand")

      {:ok, theirs} =
        Ideas.create(
          ctx.org_id,
          other.id,
          %{title: "Idea of the second brand"},
          {:agent, ctx.g.id}
        )

      {view, child} = open_url(conn, ctx.h1, "/m/social?tab=ideas&profile=all&view=all")
      assert has_element?(child, "#idea-card-#{mine.id}")
      assert has_element?(child, "#idea-card-#{theirs.id}")
      assert has_element?(view, "[data-role='social-profile-option-all'][selected]")

      for v <- ~w(all voted selected),
          do: assert(href(child, v) == "?tab=ideas&view=#{v}&profile=all")
    end

    test "a single-brand viewer's profile=all falls back as today", %{conn: conn} = ctx do
      mine = idea!(ctx, "Only brand")
      {view, child} = open_url(conn, ctx.h1, "/m/social?tab=ideas&profile=all")

      assert has_element?(child, "#idea-card-#{mine.id}")
      refute has_element?(view, "[data-role='social-profile-option-all'][selected]")
      assert href(child, "voted") == "?tab=ideas&view=voted&profile=#{ctx.profile.id}"
    end

    test "an unknown brand id selects nothing and the links name the brand shown",
         %{conn: conn} = ctx do
      mine = idea!(ctx, "Shown")

      {_view, child} =
        open_url(conn, ctx.h1, "/m/social?tab=ideas&profile=#{Ecto.UUID.generate()}")

      assert has_element?(child, "#idea-card-#{mine.id}")
      assert href(child, "all") == "?tab=ideas&view=all&profile=#{ctx.profile.id}"
    end

    test "another org's brand is not exposed, even by id", %{conn: conn} = ctx do
      foreign_org = Platform.SocialFixtures.org_id!()
      foreign_space = Platform.SocialFixtures.channel!(foreign_org)

      {:ok, foreign} =
        Platform.Social.create_profile(foreign_org, %{
          name: "Foreign #{System.unique_integer([:positive])}",
          space_id: foreign_space.id,
          approver_user_ids: [ctx.h1.id]
        })

      {:ok, secret} =
        Ideas.create(foreign_org, foreign.id, %{title: "Foreign secret"}, {:agent, ctx.g.id})

      mine = idea!(ctx, "Mine")

      for query <- ["profile=#{foreign.id}", "profile=all"] do
        {_view, child} = open_url(conn, ctx.n, "/m/social?tab=ideas&" <> query)
        assert has_element?(child, "#idea-card-#{mine.id}"), query
        refute has_element?(child, "#idea-card-#{secret.id}"), query
        refute shown(child) =~ "Foreign secret", query
        refute shown(child) =~ foreign.id, query
        assert href(child, "all") == "?tab=ideas&view=all&profile=#{ctx.profile.id}", query
      end
    end

    test "the Queue tab reads profile=all exactly as on main (it is not All brands)",
         %{conn: conn} = ctx do
      _other = second_brand!(ctx)

      {queue_all, _} = open_url(conn, ctx.h1, "/m/social?tab=queue&profile=all")

      {queue_unknown, _} =
        open_url(conn, ctx.h1, "/m/social?tab=queue&profile=#{Ecto.UUID.generate()}")

      for view <- [queue_all, queue_unknown] do
        refute has_element?(view, "[data-role='social-profile-option-all'][selected]")
        assert has_element?(view, "[data-role='social-profile-option'][selected]")
      end

      selected = fn v ->
        v
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#social-profile-select option[selected]")
        |> LazyHTML.attribute("value")
      end

      assert selected.(queue_all) == selected.(queue_unknown)
      assert selected.(queue_all) == [ctx.profile.id]
    end
  end
end
