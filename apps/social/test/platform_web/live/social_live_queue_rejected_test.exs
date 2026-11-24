defmodule PlatformWeb.SocialLiveQueueRejectedTest do
  @moduledoc """
  A post a human rejected is a `draft` with `rejected_at` set
  (`Post.rejected?/1`). It must not sit in "Drafts" among unfinished work:
  it has its own labelled "Rejected" group after the active groups, with the
  stored note. `async: false`: the Fake publisher's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, Post, PostPresentation, QueueFeed}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture() |> with_ideas_runtime()
    a = Repo.update!(Ecto.Changeset.change(ctx.a, status: "connected"))
    Map.put(ctx, :a, a)
  end

  defp open(conn, ctx, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social?profile=#{ctx.profile.id}&tab=queue")
    find_live_child(view, "ext-page-social")
  end

  defp draft!(ctx, attrs) do
    {:ok, post} = Social.create_post(ctx.org_id, ctx.a, attrs)
    post
  end

  # Through the real writer of the marker: the human's reject decision.
  defp rejected!(ctx, body, reason) do
    {_post, card} = pending_post!(ctx, ctx.a, %{body: body})
    {:ok, %{post: rejected}} = Approvals.decide_reject(card.canvas_id, ctx.h1, reason)
    assert Post.rejected?(rejected)
    rejected
  end

  defp pos(html, id), do: elem(:binary.match(html, ~s(id="#{id}")), 0)

  test "a rejected post is not listed under Drafts; an unfinished draft is",
       %{conn: conn} = ctx do
    unfinished = draft!(ctx, %{body: "Still writing this"})
    rejected = rejected!(ctx, "Too salesy post", "Cut the last line")
    view = open(conn, ctx, ctx.h1)

    assert has_element?(view, "section#queue-drafts #queue-draft-card-#{unfinished.id}")
    refute has_element?(view, "section#queue-drafts #queue-draft-card-#{rejected.id}")
  end

  test "the rejected post is in a labelled Rejected group after active work, with its note",
       %{conn: conn} = ctx do
    draft!(ctx, %{body: "Still writing this"})
    rejected = rejected!(ctx, "Too salesy post", "Cut the last line")
    {_p, _c} = pending_post!(ctx, ctx.a, %{body: "Waiting for approval"})
    view = open(conn, ctx, ctx.h1)

    assert has_element?(view, "section#queue-rejected h2", "Rejected")
    assert has_element?(view, "section#queue-rejected #queue-draft-card-#{rejected.id}")

    assert has_element?(
             view,
             "#queue-rejected-#{rejected.id} [data-role='rejected-note']",
             "Cut the last line"
           )

    assert has_element?(view, "#queue-rejected-#{rejected.id} [data-role='rejected-at']")

    html = render(view)
    assert pos(html, "queue-drafts") < pos(html, "queue-needs-you")
    assert pos(html, "queue-needs-you") < pos(html, "queue-scheduled")
    assert pos(html, "queue-scheduled") < pos(html, "queue-rejected")
  end

  test "an unfinished draft carries no rejected label or note", %{conn: conn} = ctx do
    unfinished = draft!(ctx, %{body: "Still writing this"})
    view = open(conn, ctx, ctx.h1)

    refute has_element?(view, "#queue-rejected")
    refute has_element?(view, "#queue-draft-card-#{unfinished.id} [data-role='rejected-note']")
  end

  test "no rejected posts, no Rejected group", %{conn: conn} = ctx do
    view = open(conn, ctx, ctx.h1)
    refute has_element?(view, "#queue-rejected")
  end

  test "editing and saving a rejected post keeps it rejected; resubmitting moves it to review",
       %{conn: conn} = ctx do
    rejected = rejected!(ctx, "Too salesy post", "Cut the last line")
    view = open(conn, ctx, ctx.h1)
    form = "#queue-draft-form-#{rejected.id}"

    view
    |> element(form)
    |> render_submit(%{"body" => "Better post", "at" => "2031-01-15T09:00", "intent" => "save"})

    saved = Repo.get!(Post, rejected.id)
    assert saved.body == "Better post"
    assert saved.status == "draft"
    assert Post.rejected?(saved)
    assert has_element?(view, "section#queue-rejected #queue-draft-card-#{rejected.id}")

    view
    |> element(form)
    |> render_submit(%{"body" => "Better post", "at" => "2031-01-15T09:00", "intent" => "submit"})

    sent = Repo.get!(Post, rejected.id)
    assert sent.status == "needs_approval"
    refute has_element?(view, "#queue-rejected")
    refute has_element?(view, "#queue-draft-card-#{rejected.id}")
    assert has_element?(view, "#queue-card-idea-#{rejected.id}")
  end

  test "a viewer whose read access was withdrawn is not shown the stored note",
       %{conn: conn} = ctx do
    rejected = rejected!(ctx, "Too salesy post", "Private note text")

    # With read access the note is shown (control, so the refute below can fail).
    assert PostPresentation.read(rejected, {:user, ctx.n.id})
    view = open(conn, ctx, ctx.n)
    assert has_element?(view, "[data-role='rejected-note']", "Private note text")

    # A read-only viewer is not told to edit or resend what they cannot.
    assert has_element?(view, "section#queue-rejected", "Rejected with a note.")
    refute render(view) =~ ~r/edit and send|send it for review again/i

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.n.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    assert PostPresentation.read(rejected, {:user, ctx.n.id}) == nil
    view = open(conn, ctx, ctx.n)
    refute render(view) =~ "Private note text"
  end

  test "the Queue tab count and approval badge ignore rejected posts and drafts",
       %{conn: conn} = ctx do
    {_p, _c} = pending_post!(ctx, ctx.a, %{body: "Waiting for approval"})
    before = Social.needs_approval_counts([ctx.profile.id])
    draft!(ctx, %{body: "Still writing this"})
    rejected!(ctx, "Too salesy post", "Cut the last line")
    # The rejected post left needs_approval; nothing else changed.
    assert Social.needs_approval_counts([ctx.profile.id]) == before
    view = open(conn, ctx, ctx.h1)
    assert has_element?(view, "[data-role='queue-summary']", "1 idea · 1 post")
  end

  test "the feed splits drafts from rejected, and a viewer outside the org reads neither",
       ctx do
    plain = draft!(ctx, %{body: "Plain draft"})
    post = rejected!(ctx, "Will be rejected", "No thanks")

    scope = {:profile, ctx.profile}
    assert [%{id: id}] = QueueFeed.drafts(ctx.h1, scope)
    assert id == plain.id
    assert [%{id: rid}] = QueueFeed.rejected(ctx.h1, scope)
    assert rid == post.id
    assert QueueFeed.final_rejection?(post)
    refute QueueFeed.final_rejection?(plain)

    outsider = named_user!("Outsider")
    assert QueueFeed.rejected(outsider, :all) == []
  end

  # The accepted contract (a quality send-back clears `rejected_at` and keeps
  # its note): only draft + non-nil `rejected_at` is a final rejection. Main
  # has no send-back writer yet, so the cleared state is set directly, starting
  # from a real final rejection.
  test "mixed: unfinished draft, final rejection, and a cleared earlier rejection with a note",
       %{conn: conn} = ctx do
    unfinished = draft!(ctx, %{body: "Still writing this"})
    final = rejected!(ctx, "Final no", "Off brand")
    earlier = rejected!(ctx, "Sent back for revision", "Old rejection")

    revised =
      earlier
      |> Ecto.Changeset.change(rejected_at: nil, rejection_reason: "Tighten the hook")
      |> Repo.update!()

    assert revised.status == "draft" and revised.rejection_reason == "Tighten the hook"
    refute QueueFeed.final_rejection?(revised)
    assert QueueFeed.final_rejection?(final)
    refute QueueFeed.final_rejection?(unfinished)

    scope = {:profile, ctx.profile}

    assert Enum.sort(Enum.map(QueueFeed.drafts(ctx.h1, scope), & &1.id)) ==
             Enum.sort([unfinished.id, revised.id])

    assert Enum.map(QueueFeed.rejected(ctx.h1, scope), & &1.id) == [final.id]

    view = open(conn, ctx, ctx.h1)
    assert has_element?(view, "section#queue-drafts #queue-draft-card-#{revised.id}")
    refute has_element?(view, "section#queue-drafts #queue-draft-card-#{final.id}")

    # The group speaks of rejection, not the quality stage's "sent back".
    html = render(view)
    assert html =~ "Rejected with a note."
    refute html =~ "Sent back with a note"
  end
end
