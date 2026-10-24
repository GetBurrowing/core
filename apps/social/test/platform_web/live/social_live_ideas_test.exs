defmodule PlatformWeb.SocialLiveIdeasTest do
  @moduledoc """
  The Ideas tab (Social authoring 7/11, task 01a16c50-ea67): the board's
  five derived lanes, quick add, Draft it, and the idea detail (versions,
  notes thread, change log, platform options). One describe per Done-means
  item, then the rest of the ticket's What.

  Agents act through `ToolArguments.dispatch/3`, the door both federation
  transports use. `async: false`: the Fake's call log is global, and
  `:ideas_refresh_ms` is set to 0 so a broadcast re-reads the board at once.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{IdeaNote, Post, Publishing, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    previous = Application.get_env(:social, :ideas_refresh_ms)
    Application.put_env(:social, :ideas_refresh_ms, 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:social, :ideas_refresh_ms, previous),
        else: Application.delete_env(:social, :ideas_refresh_ms)
    end)

    ctx = approval_fixture()
    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@show_x"})
    Map.merge(ctx, %{x: x, agent_ctx: %{agent_id: ctx.g.id}})
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp call(tool, args, agent_ctx), do: ToolArguments.dispatch(tool, args, agent_ctx)

  defp idea!(ctx, title) do
    {:ok, %{idea: idea}} =
      call(
        "social_idea_create",
        %{"profile_id" => ctx.profile.id, "title" => title, "brief" => "Announce it"},
        ctx.agent_ctx
      )

    idea
  end

  defp drafts!(ctx, idea, accounts, attrs) do
    {:ok, %{posts: posts}} =
      call(
        "social_draft_create",
        Map.merge(
          %{
            "profile_id" => ctx.profile.id,
            "idea_id" => idea.id,
            "account_ids" => Enum.map(accounts, & &1.id),
            "body" => "Episode 12 is out"
          },
          attrs
        ),
        ctx.agent_ctx
      )

    Enum.map(posts, &Repo.get!(Post, &1.id))
  end

  defp open(conn, user, path \\ "/m/social?tab=ideas") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, path)
    find_live_child(view, "ext-page-social")
  end

  defp card_in(lane, idea_id),
    do: "[data-role='ideas-lane'][data-lane='#{lane}'] #idea-card-#{idea_id}"

  defp open_detail(child, idea_id) do
    child |> element("#idea-card-#{idea_id} [data-role='idea-card-open']") |> render_click()
    assert has_element?(child, "[data-role='idea-detail'][data-idea-id='#{idea_id}']")
    child
  end

  defp lane_of(child, idea_id) do
    child
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='ideas-lane']:has(#idea-card-#{idea_id})")
    |> LazyHTML.attribute("data-lane")
  end

  # ── Done means 1: lanes follow the posts, live ───────────────────────

  describe "an agent-created idea" do
    test "appears in Inbox, then moves Drafting → In review → Scheduled → Live with no reload",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='ideas']")

      idea = idea!(ctx, "Episode 12 launch")
      assert has_element?(child, card_in("inbox", idea.id))

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-source']",
               "Agent idea"
             )

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-agent']",
               ctx.g.name
             )

      [li, x] = drafts!(ctx, idea, [ctx.a, ctx.x], %{"status" => "draft"})
      assert lane_of(child, idea.id) == ["drafting"]

      for {post, platform} <- [{li, "linkedin"}, {x, "x"}] do
        assert has_element?(
                 child,
                 "#idea-card-#{idea.id} [data-role='idea-card-platform'][data-platform='#{platform}']"
               )

        assert post.status == "draft"
      end

      # One draft submitted: In review, waiting on this approver.
      {:ok, _} =
        call(
          "social_draft_update",
          %{"post_id" => li.id, "status" => "needs_approval"},
          ctx.agent_ctx
        )

      assert lane_of(child, idea.id) == ["in_review"]

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-waiting']",
               "1 waiting on you"
             )

      {:ok, _} =
        call(
          "social_draft_update",
          %{"post_id" => x.id, "status" => "needs_approval"},
          ctx.agent_ctx
        )

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-waiting']",
               "2 waiting on you"
             )

      # Approve all, from the detail's versions (the shared Needs-you card).
      open_detail(child, idea.id)
      detail_card = "#idea-detail-card-#{idea.id}"
      assert has_element?(child, "#{detail_card} #idea-detail-#{li.id}")
      child |> element("#{detail_card} [data-role='queue-approve-all']") |> render_click()
      child |> element("#{detail_card} [data-role='queue-approve-all-go']") |> render_click()

      assert length(Fake.calls(:publish)) == 2
      assert lane_of(child, idea.id) == ["scheduled"]

      # The Fake's publish outcome arrives: Live.
      for post <- [li, x] do
        {:ok, _} =
          Publishing.apply_outcome(Repo.get!(Post, post.id), %{
            kind: :published,
            external_url: "https://example.com/p/#{post.id}"
          })
      end

      assert lane_of(child, idea.id) == ["live"]
      assert has_element?(child, "[data-role='idea-detail-stage']", "Live")
    end

    test "a failed post puts a muted Failed marker on the card", %{conn: conn} = ctx do
      idea = idea!(ctx, "Failing idea")
      [li] = drafts!(ctx, idea, [ctx.a], %{})

      {:ok, _} =
        Social.Approvals.decide_approve(Social.Approvals.live_card(li.id).canvas_id, ctx.h1)

      {:ok, _} = Publishing.apply_outcome(Repo.get!(Post, li.id), %{kind: :failed, error: "nope"})

      child = open(conn, ctx.h1)
      assert has_element?(child, card_in("drafting", idea.id))
      assert has_element?(child, "#idea-card-#{idea.id} [data-role='idea-card-failed']", "Failed")
    end
  end

  # ── Done means 2: quick add, then Draft it ───────────────────────────

  describe "quick add" do
    test "creates a human Inbox idea; Ask <agent> to draft mentions the drafting agent",
         %{conn: conn} = ctx do
      {:ok, _} =
        ctx.profile |> Ecto.Changeset.change(drafting_agent_id: ctx.g.id) |> Repo.update()

      child = open(conn, ctx.h1)

      child |> element("[data-role='ideas-quick-open']") |> render_click()

      child
      |> form("#ideas-quick-form",
        idea: %{title: "Guest spotlight", brief: "Lead with the guest"}
      )
      |> render_submit()

      [idea] = Social.Ideas.list(ctx.org_id, ctx.profile.id)
      assert idea.title == "Guest spotlight"
      assert idea.brief == "Lead with the guest"
      assert idea.source_kind == "human"
      assert idea.created_by_user_id == ctx.h1.id
      assert has_element?(child, card_in("inbox", idea.id))

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-source']",
               "Your idea"
             )

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-draft-it'][data-mode='agent']",
               "Ask #{ctx.g.name} to draft"
             )

      child
      |> element("#idea-card-#{idea.id} [data-role='idea-draft-it'][data-mode='agent']")
      |> render_click()

      [message] =
        Repo.all(
          from(m in Platform.Chat.Message,
            where: m.space_id == ^ctx.space.id and like(m.content, "%Please draft%")
          )
        )

      assert message.content =~ "@[#{ctx.g.name}]"
      assert message.content =~ "Guest spotlight"
      assert message.content =~ "social_draft_create idea_id=#{idea.id}"
      assert message.metadata["social_draft_request"]["idea_id"] == idea.id
      assert has_element?(child, "[data-role='ideas-notice']", "Asked #{ctx.g.name} to draft it.")
    end

    test "a blank title is refused on the form and writes nothing", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      child |> element("[data-role='ideas-quick-open']") |> render_click()
      child |> form("#ideas-quick-form", idea: %{title: "  "}) |> render_submit()

      assert Social.Ideas.list(ctx.org_id, ctx.profile.id) == []
      assert has_element?(child, "#ideas-quick-form")
    end

    test "with no drafting agent, Draft it says so instead of a button", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      child |> element("[data-role='ideas-quick-open']") |> render_click()
      child |> form("#ideas-quick-form", idea: %{title: "Orphan idea"}) |> render_submit()
      [idea] = Social.Ideas.list(ctx.org_id, ctx.profile.id)

      refute has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-draft-it'][data-mode='agent']"
             )
    end

    test "Draft it opens the composer on the idea, prefilled", %{conn: conn} = ctx do
      assert PlatformWeb.SocialComposer.enabled?()
      idea = idea!(ctx, "Composer idea")
      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)

      child
      |> element("[data-role='idea-detail'] [data-role='idea-draft-it'][data-mode='composer']")
      |> render_click()

      refute has_element?(child, "[data-role='idea-detail']")
      assert has_element?(child, "[data-role='social-composer'][data-open='true']")
      assert render(child) =~ "Composer idea"
    end
  end

  # ── Done means 3: notes both ways ────────────────────────────────────

  describe "the notes thread" do
    test "a human note reaches social_idea_list, and an agent note appears in the thread",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Episode 12 launch")
      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)
      assert has_element?(child, "[data-role='idea-notes-empty']")

      child
      |> form("#idea-note-form", note: %{body: "Keep it under 200 characters."})
      |> render_submit()

      assert has_element?(
               child,
               "[data-role='idea-note'][data-author-kind='human'] [data-role='idea-note-body']",
               "Keep it under 200 characters."
             )

      {:ok, %{ideas: [listed]}} =
        call("social_idea_list", %{"profile_id" => ctx.profile.id}, ctx.agent_ctx)

      assert [%{author_kind: "human", author_id: author, body: "Keep it under 200 characters."}] =
               listed.notes

      assert author == ctx.h1.id

      {:ok, %{note: note}} =
        call(
          "social_idea_note_add",
          %{"idea_id" => idea.id, "body" => "Will do: a short version for X."},
          ctx.agent_ctx
        )

      assert note.author_kind == "agent"
      assert note.author_id == ctx.g.id

      assert has_element?(
               child,
               "#idea-note-#{note.id}[data-author-kind='agent'] [data-role='idea-note-author']",
               ctx.g.name
             )

      assert has_element?(child, "#idea-note-#{note.id}", "Will do: a short version for X.")
    end

    test "social_idea_note_add refuses an over-long body and another org's idea", ctx do
      idea = idea!(ctx, "Episode 12 launch")

      assert {:error, %{code: :invalid_argument}} =
               call(
                 "social_idea_note_add",
                 %{"idea_id" => idea.id, "body" => String.duplicate("a", 4_001)},
                 ctx.agent_ctx
               )

      other = approval_fixture()
      pinned = pinned_agent!(other.org_id)

      assert {:error, %{code: :not_found}} =
               call("social_idea_note_add", %{"idea_id" => idea.id, "body" => "hi"}, %{
                 agent_id: pinned.id
               })

      assert Repo.aggregate(IdeaNote, :count) == 0
    end
  end

  # ── Done means 4: the change log names the actor kind ────────────────

  describe "the change log" do
    test "every row names who did it and whether that was an agent, a human or the system",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Episode 12 launch")
      [li] = drafts!(ctx, idea, [ctx.a], %{"status" => "draft"})

      {:ok, _} =
        call(
          "social_draft_update",
          %{"post_id" => li.id, "body" => "Episode 12 is live", "status" => "needs_approval"},
          ctx.agent_ctx
        )

      {:ok, _} =
        Social.Approvals.decide_approve(Social.Approvals.live_card(li.id).canvas_id, ctx.h1)

      {:ok, _} =
        Publishing.apply_outcome(Repo.get!(Post, li.id), %{kind: :published, external_url: nil})

      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)

      rows =
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='idea-log-row']")
        |> Enum.to_list()

      assert length(rows) >= 5

      for row <- rows do
        [kind] = LazyHTML.attribute(row, "data-actor-kind")
        assert kind in ~w(agent human system)
        assert LazyHTML.text(LazyHTML.query(row, "[data-role='idea-log-kind']")) == "(#{kind})"
      end

      kinds = rows |> Enum.flat_map(&LazyHTML.attribute(&1, "data-actor-kind")) |> Enum.uniq()
      assert Enum.sort(kinds) == ~w(agent human system)

      assert has_element?(
               child,
               "[data-role='idea-log-row'][data-action='edited'][data-actor-kind='agent']",
               "#{ctx.g.name} (agent) edited LinkedIn"
             )

      assert has_element?(
               child,
               "[data-role='idea-log-row'][data-action='approved'][data-actor-kind='human']",
               "Hana One (human) approved LinkedIn"
             )

      assert has_element?(
               child,
               "[data-role='idea-log-row'][data-action='published'][data-actor-kind='system']",
               "Burrow (system) published LinkedIn"
             )

      assert has_element?(child, "[data-role='idea-log-before']", "Episode 12 is out")
      assert has_element?(child, "[data-role='idea-log-after']", "Episode 12 is live")
    end
  end

  # ── Done means 5: a non-approver reads only ──────────────────────────

  describe "a non-approver" do
    test "sees the board and the detail with no write controls", %{conn: conn} = ctx do
      idea = idea!(ctx, "Episode 12 launch")
      [li, _x] = drafts!(ctx, idea, [ctx.a, ctx.x], %{})

      {:ok, %{note: _}} =
        call(
          "social_idea_note_add",
          %{"idea_id" => idea.id, "body" => "Draft ready"},
          ctx.agent_ctx
        )

      child = open(conn, ctx.n)
      assert has_element?(child, card_in("in_review", idea.id))
      refute has_element?(child, "[data-role='ideas-quick-open']")
      refute has_element?(child, "#idea-card-#{idea.id} [data-role='idea-card-waiting']")

      open_detail(child, idea.id)
      assert has_element?(child, "[data-role='idea-detail'][data-can-write='false']")
      assert has_element?(child, "[data-role='idea-detail-read-only']")
      assert has_element?(child, "#idea-detail-#{li.id}")
      assert has_element?(child, "[data-role='idea-note']", "Draft ready")
      assert has_element?(child, "[data-role='idea-options-read']")

      for role <-
            ~w(idea-note-form idea-archive idea-draft-it idea-options-form queue-approve queue-approve-all queue-edit queue-reject) do
        refute has_element?(child, "[data-role='idea-detail'] [data-role='#{role}']"), role
      end

      # A forged write from the read-only viewer is refused server-side.
      render_submit(child, "ideas_note_save", %{"note" => %{"body" => "sneaky"}})
      render_click(child, "ideas_archive", %{"id" => idea.id})

      render_submit(child, "ideas_options_save", %{
        "post_id" => li.id,
        "options" => %{"first_comment" => "x"}
      })

      assert Repo.aggregate(from(n in IdeaNote, where: n.body == "sneaky"), :count) == 0
      assert Repo.get!(Social.Idea, idea.id).archived_at == nil
      assert Repo.get!(Post, li.id).platform_options == %{}
    end
  end

  # ── Done means 6: zero data ──────────────────────────────────────────

  describe "a new profile" do
    test "shows five empty lanes, each with its own copy, and quick add works", %{conn: conn} do
      org_id = org_id!()
      space = channel!(org_id)
      owner = named_user!("Zed Owner")
      member!(owner, org_id)
      join!(space.id, :user, owner.id)

      {:ok, profile} =
        Social.create_profile(org_id, %{
          name: "Fresh #{unique()}",
          space_id: space.id,
          approver_user_ids: [owner.id]
        })

      child = open(conn, owner)

      copies =
        for lane <- ~w(inbox drafting in_review scheduled live) do
          assert has_element?(child, "[data-role='ideas-lane'][data-lane='#{lane}']")

          [copy] =
            child
            |> render()
            |> LazyHTML.from_fragment()
            |> LazyHTML.query(
              "[data-role='ideas-lane'][data-lane='#{lane}'] [data-role='ideas-lane-empty']"
            )
            |> Enum.map(&LazyHTML.text/1)

          String.trim(copy)
        end

      assert length(Enum.uniq(copies)) == 5
      assert Enum.at(copies, 2) =~ "when a draft is submitted"

      child |> element("[data-role='ideas-quick-open']") |> render_click()
      child |> form("#ideas-quick-form", idea: %{title: "First idea"}) |> render_submit()

      [idea] = Social.Ideas.list(org_id, profile.id)
      assert has_element?(child, card_in("inbox", idea.id))
      refute has_element?(child, "[data-lane='inbox'] [data-role='ideas-lane-empty']")
      assert has_element?(child, "[data-lane='drafting'] [data-role='ideas-lane-empty']")
    end
  end

  # ── The rest of the What ─────────────────────────────────────────────

  describe "the detail" do
    test "opens from ?tab=ideas&idea=<id> and closes", %{conn: conn} = ctx do
      idea = idea!(ctx, "Deep linked")
      child = open(conn, ctx.h1, "/m/social?tab=ideas&idea=#{idea.id}")

      assert has_element?(child, "[data-role='idea-detail-title']", "Deep linked")
      assert has_element?(child, "[data-role='idea-versions-empty']")

      child |> element("[data-role='idea-detail-close']") |> render_click()
      refute has_element?(child, "[data-role='idea-detail']")
    end

    test "an idea of another org is not opened by a deep link", %{conn: conn} = ctx do
      other = approval_fixture()

      {:ok, foreign} =
        Social.Ideas.create(
          other.org_id,
          other.profile.id,
          %{"title" => "Foreign"},
          {:user, other.h1.id}
        )

      child = open(conn, ctx.h1, "/m/social?tab=ideas&idea=#{foreign.id}")
      refute has_element?(child, "[data-role='idea-detail']")
      refute render(child) =~ "Foreign"
    end

    test "links the source the idea came from", %{conn: conn} = ctx do
      {:ok, %{idea: idea}} =
        call(
          "social_idea_create",
          %{
            "profile_id" => ctx.profile.id,
            "title" => "From a link",
            "source_kind" => "url",
            "source_url" => "https://example.com/episode-12"
          },
          ctx.agent_ctx
        )

      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)

      assert has_element?(
               child,
               "a[data-role='idea-detail-source-link'][data-kind='url'][href='https://example.com/episode-12']"
             )
    end

    test "platform options: only Zernio's fields per platform, saved, logged and sent to the publisher",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Options idea")
      [li, x] = drafts!(ctx, idea, [ctx.a, ctx.x], %{})
      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)

      keys = fn post ->
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#idea-options-#{post.id} [data-role='idea-option-input']")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-key"))
      end

      assert keys.(li) == ~w(first_comment alt_text)
      assert keys.(x) == ~w(alt_text)

      child
      |> form("#idea-options-#{li.id}",
        options: %{first_comment: "Full episode in the comments", alt_text: "Host at the mic"}
      )
      |> render_submit()

      assert Repo.get!(Post, li.id).platform_options == %{
               "first_comment" => "Full episode in the comments",
               "alt_text" => "Host at the mic"
             }

      assert has_element?(
               child,
               "[data-role='idea-log-row'][data-action='edited'][data-actor-kind='human']",
               "Platform options: First comment, Image alt text"
             )

      # A key X does not take is never stored.
      render_submit(child, "ideas_options_save", %{
        "post_id" => x.id,
        "options" => %{"first_comment" => "no", "alt_text" => "A chart"}
      })

      assert Repo.get!(Post, x.id).platform_options == %{"alt_text" => "A chart"}

      # Over the limit: refused on the form.
      child
      |> form("#idea-options-#{li.id}", options: %{first_comment: String.duplicate("a", 1_251)})
      |> render_submit()

      assert has_element?(child, "[data-role='idea-option-error'][data-key='first_comment']")

      assert Repo.get!(Post, li.id).platform_options["first_comment"] ==
               "Full episode in the comments"

      {:ok, _} =
        Social.Approvals.decide_approve(Social.Approvals.live_card(li.id).canvas_id, ctx.h1)

      [{:publish, [_account, request], _}] = Fake.calls(:publish)
      assert request.options["first_comment"] == "Full episode in the comments"
      assert request.options["alt_text"] == "Host at the mic"
    end

    test "archive is offered with no published post and removes the idea from the board",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "To archive")
      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)

      child |> element("[data-role='idea-archive']") |> render_click()

      assert Repo.get!(Social.Idea, idea.id).archived_at
      refute has_element?(child, "#idea-card-#{idea.id}")
      refute has_element?(child, "[data-role='idea-detail']")
    end

    test "archive is not offered, and refused, once a post is published", %{conn: conn} = ctx do
      idea = idea!(ctx, "Shipped")
      [li] = drafts!(ctx, idea, [ctx.a], %{})

      {:ok, _} =
        Social.Approvals.decide_approve(Social.Approvals.live_card(li.id).canvas_id, ctx.h1)

      {:ok, _} =
        Publishing.apply_outcome(Repo.get!(Post, li.id), %{kind: :published, external_url: nil})

      child = ctx |> then(&open(conn, &1.h1)) |> open_detail(idea.id)
      refute has_element?(child, "[data-role='idea-archive']")

      render_click(child, "ideas_archive", %{"id" => idea.id})
      assert Repo.get!(Social.Idea, idea.id).archived_at == nil
    end
  end

  describe "All brands" do
    test "shows every visible brand's ideas with a brand chip, and nothing of another org",
         %{conn: conn} = ctx do
      idea = idea!(ctx, "Brand one idea")

      {:ok, second} =
        Social.create_profile(ctx.org_id, %{
          name: "Second #{unique()}",
          space_id: ctx.space.id,
          approver_user_ids: [ctx.h1.id]
        })

      {:ok, idea2} =
        Social.Ideas.create(
          ctx.org_id,
          second.id,
          %{"title" => "Brand two idea"},
          {:user, ctx.h1.id}
        )

      other = approval_fixture()

      {:ok, foreign} =
        Social.Ideas.create(
          other.org_id,
          other.profile.id,
          %{"title" => "Foreign"},
          {:user, other.h1.id}
        )

      child = open(conn, ctx.h1)
      render_change(child, "switch_profile", %{"profile_id" => "all"})

      assert has_element?(
               child,
               "#idea-card-#{idea.id} [data-role='idea-card-brand']",
               ctx.profile.name
             )

      assert has_element?(
               child,
               "#idea-card-#{idea2.id} [data-role='idea-card-brand']",
               second.name
             )

      refute has_element?(child, "#idea-card-#{foreign.id}")
      assert has_element?(child, "[data-role='ideas-quick-pick-brand']")
    end
  end

  describe "phone" do
    test "the lanes are a segmented control, one lane on screen at a time", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               "[data-role='ideas-lane-tab'][data-lane='inbox'][aria-selected='true']"
             )

      refute has_element?(child, "[data-role='ideas-lane'][data-lane='inbox'].max-sm\\:hidden")
      assert has_element?(child, "[data-role='ideas-lane'][data-lane='live'].max-sm\\:hidden")

      child |> element("[data-role='ideas-lane-tab'][data-lane='live']") |> render_click()

      assert has_element?(
               child,
               "[data-role='ideas-lane-tab'][data-lane='live'][aria-selected='true']"
             )

      refute has_element?(child, "[data-role='ideas-lane'][data-lane='live'].max-sm\\:hidden")
      assert has_element?(child, "[data-role='ideas-lane'][data-lane='inbox'].max-sm\\:hidden")
    end
  end

  describe "the Calendar" do
    test "a click on an idea's post opens the idea", %{conn: conn} = ctx do
      idea = idea!(ctx, "Calendar idea")
      at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      [li] = drafts!(ctx, idea, [ctx.a], %{"scheduled_at" => DateTime.to_iso8601(at)})

      child = open(conn, ctx.h1, "/m/social?tab=calendar")
      render_click(child, "open_post", %{"id" => li.id})

      assert has_element?(child, "[data-role='social-tab-body'][data-tab='ideas']")
      assert has_element?(child, "[data-role='idea-detail'][data-idea-id='#{idea.id}']")
    end
  end
end
