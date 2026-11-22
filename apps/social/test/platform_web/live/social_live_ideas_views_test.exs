defmodule PlatformWeb.SocialLiveIdeasViewsTest do
  @moduledoc """
  The Ideas tab as one list in three views (All ideas, With votes, Selected for
  research), and the human "Select for research" action: who sees the button,
  what a click writes, what it never writes, and how the page binds a client
  idea id to the viewer and the current brand.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Idea, IdeaNotes, IdeaSelectionEvent, IdeaVote, Ideas}

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

  # ── Helpers ──────────────────────────────────────────────────────────

  defp open(conn, user, ctx, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _} = live(conn, "/m/social?tab=ideas&profile=#{ctx.profile.id}" <> query)
    find_live_child(view, "ext-page-social")
  end

  defp idea!(ctx, title, creator \\ nil) do
    creator = creator || {:agent, ctx.g.id}
    {:ok, idea} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: title}, creator)
    idea
  end

  defp vote!(ctx, idea, n) do
    for _ <- 1..n do
      voter = pinned_agent!(ctx.org_id)

      Repo.insert!(%IdeaVote{
        idea_id: idea.id,
        org_id: idea.org_id,
        profile_id: idea.profile_id,
        voter_agent_id: voter.id
      })
    end
  end

  defp select!(ctx, idea, user),
    do: {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, idea.id, {:user, user.id})

  defp view_tab(view), do: "[data-role='ideas-view-tab'][data-view='#{view}']"

  defp row_ids(child) do
    child
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#ideas-list [data-role='idea-card']")
    |> LazyHTML.attribute("data-idea-id")
  end

  defp count_text(child, view),
    do:
      child
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{view_tab(view)} [data-role='ideas-view-count']")
      |> LazyHTML.text()
      |> String.trim()

  defp world do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' AND table_name NOT IN ('schema_migrations', 'social_ideas', 'social_idea_selection_events') ORDER BY 1"
      )

    for [t] <- tables, into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{t}\"")
      {t, n}
    end
  end

  # ── The three views ──────────────────────────────────────────────────

  describe "one list, three views" do
    test "three buttons with counts, and no lane, stage or shortlist anywhere",
         %{conn: conn} = ctx do
      a = idea!(ctx, "First idea")
      b = idea!(ctx, "Second idea")
      c = idea!(ctx, "Third idea")
      vote!(ctx, b, 3)
      vote!(ctx, c, 1)
      select!(ctx, c, ctx.h1)

      child = open(conn, ctx.h1, ctx)

      assert {count_text(child, "all"), count_text(child, "voted"), count_text(child, "selected")} ==
               {"3", "2", "1"}

      assert has_element?(child, "#{view_tab("all")}[aria-current='page']")
      refute has_element?(child, "#{view_tab("voted")}[aria-current]")

      # short labels on a phone, the full names as accessible names
      for {view, short, full} <- [
            {"all", "All", "All ideas"},
            {"voted", "Votes", "With votes"},
            {"selected", "Selected", "Selected for research"}
          ] do
        assert has_element?(child, "#{view_tab(view)}[aria-label^='#{full}']")
        assert has_element?(child, "#{view_tab(view)} .sm\\:hidden", short)
      end

      html = html_of(child, "[data-role='social-ideas']")

      for gone <-
            ~w(Shortlisted Drafting) ++
              ["In review", "Scheduled", "Three agent votes", "Inbox", "ideas-lane"] do
        refute html =~ gone, "the page still says #{gone}"
      end

      refute has_element?(child, "[data-role='ideas-lane']")
      refute has_element?(child, "[data-role='idea-card'][data-stage]")
      assert row_ids(child) == [c.id, b.id, a.id]
    end

    test "all ideas is newest first and every active idea; archived ones are in none",
         %{conn: conn} = ctx do
      old = idea!(ctx, "Old")
      mid = idea!(ctx, "Mid")
      new = idea!(ctx, "New")
      archived = idea!(ctx, "Archived selected")
      select!(ctx, archived, ctx.h1)
      vote!(ctx, archived, 2)
      {:ok, _} = Ideas.archive(ctx.org_id, archived.id)

      child = open(conn, ctx.h1, ctx)
      assert row_ids(child) == [new.id, mid.id, old.id]
      child = open(conn, ctx.h1, ctx, "&view=voted")
      assert row_ids(child) == []
      child = open(conn, ctx.h1, ctx, "&view=selected")
      assert row_ids(child) == []

      assert {count_text(child, "all"), count_text(child, "voted"), count_text(child, "selected")} ==
               {"3", "0", "0"}
    end

    test "with votes: most votes first, then oldest; a mismatched vote row never counts",
         %{conn: conn} = ctx do
      a = idea!(ctx, "A two votes, older")
      b = idea!(ctx, "B two votes, newer")
      c = idea!(ctx, "C three votes")
      d = idea!(ctx, "D one real vote plus a cross-profile row")
      e = idea!(ctx, "E only cross-profile rows")
      for {i, n} <- [{a, 2}, {b, 2}, {c, 3}, {d, 1}], do: vote!(ctx, i, n)

      {:ok, other} =
        Social.create_profile(ctx.org_id, %{
          name: "Elsewhere",
          space_id: ctx.space.id,
          approver_user_ids: [ctx.h1.id]
        })

      for idea <- [d, e] do
        stray = pinned_agent!(ctx.org_id)

        Repo.insert!(%IdeaVote{
          idea_id: idea.id,
          org_id: idea.org_id,
          profile_id: other.id,
          voter_agent_id: stray.id
        })
      end

      # a human's historical vote never counts either
      Repo.insert!(%IdeaVote{
        idea_id: e.id,
        org_id: e.org_id,
        profile_id: e.profile_id,
        voter_user_id: ctx.n.id
      })

      child = open(conn, ctx.h1, ctx)
      assert count_text(child, "voted") == "4"
      child = open(conn, ctx.h1, ctx, "&view=voted")
      assert row_ids(child) == [c.id, a.id, b.id, d.id]

      assert has_element?(
               child,
               "#idea-card-#{d.id} [data-role='idea-vote-count']",
               "1 agent vote"
             )

      refute has_element?(
               child,
               "#idea-card-#{d.id} [data-role='idea-vote-count']",
               "2 agent votes"
             )

      refute e.id in row_ids(child)

      child = open(conn, ctx.h1, ctx, "&view=all")

      assert has_element?(
               child,
               "#idea-card-#{e.id} [data-role='idea-vote-count']",
               "0 agent votes"
             )
    end

    test "selected: most recently selected first, naming who and how many notes",
         %{conn: conn} = ctx do
      first = idea!(ctx, "Selected first")
      second = idea!(ctx, "Selected second")
      idea!(ctx, "Never selected")
      select!(ctx, first, ctx.h1)
      Process.sleep(5)
      select!(ctx, second, ctx.n)
      {:ok, _} = IdeaNotes.add(ctx.org_id, first.id, {:agent, ctx.g.id}, "Found a source")
      {:ok, _} = IdeaNotes.add(ctx.org_id, first.id, {:human, ctx.h1.id}, "Thanks")

      _child = open(conn, ctx.h1, ctx)
      child = open(conn, ctx.h1, ctx, "&view=selected")
      assert row_ids(child) == [second.id, first.id]

      assert has_element?(
               child,
               "#idea-card-#{first.id} [data-role='idea-selected-by']",
               "Selected for research by #{ctx.h1.name}"
             )

      assert has_element?(
               child,
               "#idea-card-#{second.id} [data-role='idea-selected-by']",
               "Selected for research by #{ctx.n.name}"
             )

      assert has_element?(
               child,
               "#idea-card-#{first.id} [data-role='idea-notes-count']",
               "2 notes"
             )

      assert has_element?(
               child,
               "#idea-card-#{second.id} [data-role='idea-notes-count']",
               "0 notes"
             )

      refute html_of(child, "#idea-card-#{first.id}") =~ "research notes"
    end

    test "an idea with votes and a selection is in all three views", %{conn: conn} = ctx do
      idea = idea!(ctx, "In all three")
      vote!(ctx, idea, 2)
      select!(ctx, idea, ctx.h1)
      _child = open(conn, ctx.h1, ctx)

      for view <- ~w(all voted selected) do
        child = open(conn, ctx.h1, ctx, "&view=#{view}")
        assert row_ids(child) == [idea.id], view
      end
    end

    test "three votes never select, and a selected idea needs no votes", %{conn: conn} = ctx do
      voted = idea!(ctx, "Popular")
      chosen = idea!(ctx, "Chosen")
      vote!(ctx, voted, 5)
      select!(ctx, chosen, ctx.h1)
      _child = open(conn, ctx.h1, ctx)
      child = open(conn, ctx.h1, ctx, "&view=selected")
      assert row_ids(child) == [chosen.id]
      assert Repo.get!(Idea, voted.id).selected_at == nil
      child = open(conn, ctx.h1, ctx, "&view=voted")
      assert row_ids(child) == [voted.id]
    end

    test "the view is read from the address", %{conn: conn} = ctx do
      idea = idea!(ctx, "Deep linked")
      select!(ctx, idea, ctx.h1)
      other = idea!(ctx, "Not selected")
      child = open(conn, ctx.h1, ctx, "&view=selected")
      assert has_element?(child, "#{view_tab("selected")}[aria-current='page']")
      assert row_ids(child) == [idea.id]
      refute other.id in row_ids(child)

      child = open(conn, ctx.h1, ctx, "&view=nonsense")
      assert has_element?(child, "#{view_tab("all")}[aria-current='page']")
    end

    test "empty states keep the three buttons and say what to do", %{conn: conn} = ctx do
      child = open(conn, ctx.h1, ctx)

      assert has_element?(
               child,
               "[data-role='ideas-empty'][data-view='all']",
               "No ideas yet. Add one, or ask an agent for theirs."
             )

      child = open(conn, ctx.h1, ctx, "&view=voted")

      assert has_element?(
               child,
               "[data-role='ideas-empty'][data-view='voted']",
               "No idea has a vote yet. Agents vote on each other's ideas; counts appear here."
             )

      child = open(conn, ctx.h1, ctx, "&view=selected")

      assert has_element?(
               child,
               "[data-role='ideas-empty'][data-view='selected']",
               "Nothing selected yet. Open All ideas and choose Select for research on one worth exploring."
             )

      for view <- ~w(all voted selected), do: assert(has_element?(child, view_tab(view)))
      # Open All ideas is a link that names the shown brand
      assert has_element?(
               child,
               "a[data-role='ideas-empty-all'][href='?tab=ideas&view=all&profile=#{ctx.profile.id}']"
             )

      child = open(conn, ctx.h1, ctx, "&view=all")
      assert has_element?(child, "#{view_tab("all")}[aria-current='page']")
    end
  end

  defp html_of(child, selector),
    do:
      child |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()

  # ── Select for research ──────────────────────────────────────────────

  describe "Select for research" do
    test "a person without approver rights selects with one click; the row shows who",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Worth exploring")
      before = world()
      child = open(conn, ctx.n, ctx)
      refute Social.approver_check(ctx.org_id, ctx.profile, ctx.n.id) == :ok

      child |> element("#idea-card-#{idea.id} [data-role='idea-select']") |> render_click()

      row = Repo.get!(Idea, idea.id)
      assert row.selected_by_user_id == ctx.n.id
      assert %DateTime{} = row.selected_at
      assert [%{action: "selected", actor_id: actor}] = Repo.all(IdeaSelectionEvent)
      assert actor == ctx.n.id

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-selected-by']",
               "Selected for research by #{ctx.n.name}"
             )

      assert has_element?(child, "#idea-card-#{idea.id} [data-role='idea-unselect']", "Unselect")
      refute has_element?(child, "#idea-card-#{idea.id} [data-role='idea-select']")
      assert count_text(child, "selected") == "1"
      # nothing but the marker and its event was written
      assert world() == before
    end

    test "anyone authorized may unselect another's selection; the event records who",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Switch")
      select!(ctx, idea, ctx.n)
      child = open(conn, ctx.h1, ctx)
      child |> element("#idea-card-#{idea.id} [data-role='idea-unselect']") |> render_click()

      assert is_nil(Repo.get!(Idea, idea.id).selected_at)

      assert [{"selected", selector}, {"unselected", unselector}] =
               Repo.all(
                 from(e in IdeaSelectionEvent,
                   order_by: [asc: e.inserted_at, asc: e.id],
                   select: {e.action, e.actor_id}
                 )
               )

      assert {selector, unselector} == {ctx.n.id, ctx.h1.id}
      assert count_text(child, "selected") == "0"
    end

    test "Select is hidden from a viewer who fails the selection authority, and a forged click is refused",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Guarded")

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, ctx.n.id},
          permission: "social.use",
          resource: {:project, ctx.profile.project_id}
        })

      child = open(conn, ctx.n, ctx)
      assert has_element?(child, "#idea-card-#{idea.id}")
      refute has_element?(child, "[data-role='idea-select']")
      refute has_element?(child, "[data-role='idea-unselect']")

      render_click(child, "ideas_select", %{"id" => idea.id})
      assert is_nil(Repo.get!(Idea, idea.id).selected_at)
      assert Repo.all(IdeaSelectionEvent) == []
      assert has_element?(child, "[data-role='ideas-notice'][data-tone='warning']")
    end

    test "the acting user is the session's, never a parameter", %{conn: conn} = ctx do
      idea = idea!(ctx, "Spoof")
      child = open(conn, ctx.n, ctx)

      render_click(child, "ideas_select", %{
        "id" => idea.id,
        "user_id" => ctx.h1.id,
        "actor_id" => ctx.h1.id
      })

      assert Repo.get!(Idea, idea.id).selected_by_user_id == ctx.n.id
    end

    test "a forged id of another brand's idea, or another org's, is refused",
         %{conn: conn} = ctx do
      {:ok, other} =
        Social.create_profile(ctx.org_id, %{
          name: "Other brand",
          space_id: ctx.space.id,
          approver_user_ids: [ctx.h1.id]
        })

      other = Repo.update!(Ecto.Changeset.change(other, project_id: ctx.profile.project_id))

      {:ok, foreign} =
        Ideas.create(ctx.org_id, other.id, %{title: "Other brand idea"}, {:agent, ctx.g.id})

      alien_org = org_id!()
      alien_profile = Repo.insert!(%Social.Profile{org_id: alien_org, name: "Alien"})

      {:ok, alien} =
        Ideas.create(alien_org, alien_profile.id, %{title: "Alien idea"}, {:agent, ctx.g.id})

      child = open(conn, ctx.h1, ctx)
      refute has_element?(child, "#idea-card-#{foreign.id}")

      for forged <- [foreign, alien] do
        render_click(child, "ideas_select", %{"id" => forged.id})
        assert is_nil(Repo.get!(Idea, forged.id).selected_at)
        render_click(child, "ideas_unselect", %{"id" => forged.id})
      end

      assert Repo.all(IdeaSelectionEvent) == []
      assert render_click(child, "ideas_select", %{"id" => "not-a-uuid"}) =~ "no longer here"
    end

    test "an archived idea cannot be selected from a stale page", %{conn: conn} = ctx do
      idea = idea!(ctx, "Stale")
      child = open(conn, ctx.h1, ctx)
      {:ok, _} = Ideas.archive(ctx.org_id, idea.id)
      render_click(child, "ideas_select", %{"id" => idea.id})
      assert is_nil(Repo.get!(Idea, idea.id).selected_at)
    end

    test "a selection by someone else appears without a reload", %{conn: conn} = ctx do
      idea = idea!(ctx, "Live")
      child = open(conn, ctx.h1, ctx)
      refute has_element?(child, "#idea-card-#{idea.id} [data-role='idea-selected-by']")
      select!(ctx, idea, ctx.n)

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-selected-by']",
               ctx.n.name
             )

      assert count_text(child, "selected") == "1"
    end

    test "a deleted selector reads as a former user and the idea stays selected",
         %{conn: conn} = ctx do
      gone = named_user!("Short Lived")
      member!(gone, ctx.org_id)
      idea = idea!(ctx, "Orphaned selection")
      select!(ctx, idea, gone)
      Repo.query!("DELETE FROM org_memberships WHERE user_id = $1", [Ecto.UUID.dump!(gone.id)])
      Repo.delete!(gone)

      child = open(conn, ctx.h1, ctx, "&view=selected")
      assert row_ids(child) == [idea.id]

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-selected-by']",
               "Selected for research by a former user"
             )
    end
  end

  # ── The next step: a note, for those who can add one ─────────────────

  describe "the research prompt" do
    test "only a viewer who can add notes sees it, even if they selected the idea",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Prompted")
      select!(ctx, idea, ctx.n)

      nina = open(conn, ctx.n, ctx, "&view=selected")
      assert has_element?(nina, "#idea-card-#{idea.id} [data-role='idea-selected-by']")
      refute has_element?(nina, "[data-role='idea-research-prompt']")

      hana = open(conn, ctx.h1, ctx, "&view=selected")

      assert has_element?(
               hana,
               "#idea-card-#{idea.id} [data-role='idea-research-prompt']",
               "Add what you find as a note"
             )
    end

    test "the detail has a Research section: who selected it, the prompt for approvers, the toggle",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Detailed")
      select!(ctx, idea, ctx.n)

      hana = open(conn, ctx.h1, ctx)
      hana |> element("#idea-card-#{idea.id} [data-role='idea-card-open']") |> render_click()

      assert has_element?(
               hana,
               "[data-role='idea-detail'] [data-role='idea-research']",
               "Selected for research by #{ctx.n.name}"
             )

      assert has_element?(
               hana,
               "[data-role='idea-detail'] [data-role='idea-research']",
               "Add what you find as a note"
             )

      assert has_element?(hana, "[data-role='idea-detail'] [data-role='idea-unselect']")

      refute has_element?(
               hana,
               "[data-role='idea-detail'] [data-role='idea-detail-stage']",
               "Shortlisted"
             )

      nina = open(conn, ctx.n, ctx)
      nina |> element("#idea-card-#{idea.id} [data-role='idea-card-open']") |> render_click()

      assert has_element?(
               nina,
               "[data-role='idea-detail'] [data-role='idea-research']",
               "Selected for research by #{ctx.n.name}"
             )

      refute has_element?(
               nina,
               "[data-role='idea-detail'] [data-role='idea-research']",
               "Add what you find as a note"
             )

      assert has_element?(nina, "[data-role='idea-detail'] [data-role='idea-unselect']")
    end

    test "Draft it stays in the detail and is not on the row", %{conn: conn} = ctx do
      idea = idea!(ctx, "Draftable")
      child = open(conn, ctx.h1, ctx)
      refute has_element?(child, "#idea-card-#{idea.id} [data-role='idea-draft-it']")
      child |> element("#idea-card-#{idea.id} [data-role='idea-card-open']") |> render_click()
      assert has_element?(child, "[data-role='idea-detail'] [data-role='idea-draft-it']")
    end
  end

  describe "All brands" do
    test "the brand is added after the date", %{conn: conn} = ctx do
      idea!(ctx, "Branded")
      child = open(conn, ctx.h1, ctx)
      render_change(child, "switch_profile", %{"profile_id" => "all"})
      assert has_element?(child, "[data-role='idea-card-brand']", ctx.profile.name)
    end
  end
end
