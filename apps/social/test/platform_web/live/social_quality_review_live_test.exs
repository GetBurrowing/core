defmodule PlatformWeb.SocialQualityReviewLiveTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Post, QueueFeed}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    project = Platform.SocialFixtures.project!(ctx.org_id)

    profile =
      Repo.update!(
        Ecto.Changeset.change(ctx.profile,
          project_id: project.id,
          quality_reviewer_user_ids: [ctx.n.id]
        )
      )

    a = Repo.update!(Ecto.Changeset.change(ctx.a, status: "connected"))
    Map.merge(ctx, %{profile: profile, a: a})
  end

  defp post!(ctx, status \\ "quality_review") do
    {:ok, post} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Ready caption",
        scheduled_at: ~U[2031-01-15 09:00:00Z]
      })

    Repo.update!(Ecto.Changeset.change(post, status: status))
  end

  defp open(conn, ctx, user, suffix \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _} = live(conn, "/m/social?profile=#{ctx.profile.id}&tab=queue#{suffix}")
    find_live_child(view, "ext-page-social")
  end

  defp card(post), do: "#queue-draft-card-#{post.id}"
  defp form(post), do: "#queue-draft-form-#{post.id}"

  test "quality review is a separate feed and count, outside awaiting approval",
       %{conn: conn} = ctx do
    p = post!(ctx)
    assert Enum.map(QueueFeed.quality_review(ctx.n, {:profile, ctx.profile}), & &1.id) == [p.id]
    assert QueueFeed.needs_you(ctx.n, {:profile, ctx.profile}) == []
    view = open(conn, ctx, ctx.n)
    assert has_element?(view, "#queue-quality-review h2", "Quality review")
    assert has_element?(view, "#queue-quality-review [data-role='quality-review-count']", "1")
    assert has_element?(view, "#queue-quality-review #{card(p)}")
    refute has_element?(view, "#queue-needs-you [data-post-id='#{p.id}']")
  end

  test "reviewer can pass stored content without approving or changing its time",
       %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.n)
    assert has_element?(view, form(p))
    refute has_element?(view, "[data-role='social-card-approve']")
    view |> element("#{card(p)} [data-role='quality-pass']") |> render_click()
    saved = Repo.get!(Post, p.id)
    assert saved.status == "needs_approval"
    assert saved.scheduled_at == p.scheduled_at
    assert saved.approved_by_user_id == nil
    assert saved.approved_at == nil
    assert saved.quality_passed_by_user_id == ctx.n.id
    assert %ApprovalCard{} = Social.Approvals.live_card(p.id)
    assert Fake.calls() == []
    refute has_element?(view, "#queue-quality-review #{card(p)}")
  end

  test "dirty review edits must be saved before passing", %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.n)
    view |> element(form(p)) |> render_change(%{"body" => "Edited caption"})
    assert has_element?(view, "#{card(p)} [data-role='quality-pass'][disabled]")

    assert has_element?(
             view,
             "#{card(p)} [data-role='quality-save-first']",
             "Save changes before passing"
           )

    assert Repo.get!(Post, p.id).body == p.body
    view |> element(form(p)) |> render_submit(%{"body" => "Edited caption", "intent" => "save"})
    assert Repo.get!(Post, p.id).body == "Edited caption"
    assert Repo.get!(Post, p.id).status == "quality_review"
    refute has_element?(view, "#{card(p)} [data-role='quality-pass'][disabled]")
    view |> element("#{card(p)} [data-role='quality-pass']") |> render_click()
    assert Repo.get!(Post, p.id).status == "needs_approval"
  end

  test "send back requires a note and returns the post to drafts", %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.n)

    view
    |> element("#{card(p)} [data-role='quality-send-back-form']")
    |> render_submit(%{"note" => " "})

    assert has_element?(
             view,
             "#{card(p)} [data-role='draft-line']",
             "To send this back, write a note first."
           )

    assert Repo.get!(Post, p.id).status == "quality_review"
    assert Social.Approvals.live_card(p.id) == nil
    assert Fake.calls() == []

    view
    |> element("#{card(p)} [data-role='quality-send-back-form']")
    |> render_submit(%{"note" => "Please tighten the edit"})

    assert Repo.get!(Post, p.id).status == "draft"
    assert has_element?(view, "#queue-drafts #{card(p)}")

    assert has_element?(
             view,
             "#{card(p)} [data-role='quality-return-note']",
             "Please tighten the edit"
           )
  end

  test "retained send-back note is historical after resubmission, pass and another content edit",
       %{conn: conn} = ctx do
    p = post!(ctx)

    {:ok, returned} =
      Social.send_back_quality_review(ctx.org_id, p.id, ctx.n.id, "Tighten the original edit")

    {:ok, resubmitted} =
      Social.edit_draft(ctx.org_id, returned.id, ctx.n.id, %{body: "Revised caption"},
        submit: true
      )

    {:ok, passed} = Social.pass_quality_review(ctx.org_id, resubmitted.id, ctx.n.id)

    {:ok, edited} =
      Social.update_post(ctx.org_id, passed.id, %{body: "Another content change after pass"})

    assert edited.status == "quality_review"
    assert edited.rejection_reason == "Tighten the original edit"
    view = open(conn, ctx, ctx.n)

    assert has_element?(
             view,
             "#{card(p)} [data-role='quality-return-note']",
             "Last send-back note: Tighten the original edit"
           )

    assert Repo.get!(Post, p.id).rejection_reason == "Tighten the original edit"
    assert Fake.calls() == []
  end

  test "approver without reviewer role gets note-required send back without editing or passing",
       %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.h1)

    assert has_element?(
             view,
             "#{card(p)} [data-role='draft-read-only']",
             "Waiting for quality review by Nina Viewer"
           )

    refute has_element?(view, form(p))
    refute has_element?(view, "#{card(p)} [data-role='quality-pass']")
    assert has_element?(view, "#{card(p)} [data-role='quality-send-back-form']")
    before = Repo.get!(Post, p.id)

    view
    |> element("#{card(p)} [data-role='quality-send-back-form']")
    |> render_submit(%{"note" => " "})

    assert has_element?(
             view,
             "#{card(p)} [data-role='draft-line']",
             "To send this back, write a note first."
           )

    assert Repo.get!(Post, p.id) == before
    assert Fake.calls() == []

    view
    |> element("#{card(p)} [data-role='quality-send-back-form']")
    |> render_submit(%{"note" => "Please recut the opening"})

    assert Repo.get!(Post, p.id).status == "draft"

    assert has_element?(
             view,
             "#{card(p)} [data-role='quality-return-note']",
             "Please recut the opening"
           )

    assert has_element?(
             view,
             "#queue-drafts [data-role='drafts-guidance']",
             "Drafts and posts sent back"
           )

    refute has_element?(view, "#queue-drafts p", "Not sent for review yet.")
  end

  test "a reader on neither role sees the explanation with no controls", %{conn: conn} = ctx do
    Repo.update!(Ecto.Changeset.change(ctx.profile, approver_user_ids: [ctx.h1.id]))
    p = post!(ctx)
    view = open(conn, ctx, ctx.h2)

    assert has_element?(
             view,
             "#{card(p)} [data-role='draft-read-only']",
             "Waiting for quality review by Nina Viewer"
           )

    refute has_element?(view, "#{card(p)} form")
    refute has_element?(view, "#{card(p)} button")
  end

  test "quality-stage send back respects the account's final owner and fresh authority",
       %{conn: conn} = ctx do
    {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, ctx.h2.id)
    p = post!(ctx)
    other_approver = open(conn, ctx, ctx.h1)
    refute has_element?(other_approver, "#{card(p)} [data-role='quality-send-back-form']")
    owner = open(conn, ctx, ctx.h2)
    assert has_element?(owner, "#{card(p)} [data-role='quality-send-back-form']")
    refute has_element?(owner, form(p))
    refute has_element?(owner, "#{card(p)} [data-role='quality-pass']")
    {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, ctx.h1.id)
    owner |> with_target(card(p)) |> render_hook("quality_send_back", %{"note" => "stale owner"})
    assert Repo.get!(Post, p.id).status == "quality_review"
    assert Repo.get!(Post, p.id).rejection_reason == nil
    assert Fake.calls() == []
    refute has_element?(owner, "#{card(p)} [data-role='quality-send-back-form']")
  end

  test "final Queue card Save text submits the edit and returns the post to quality review",
       %{conn: conn} = ctx do
    p = post!(ctx)

    assert {:ok, _} =
             Social.pass_quality_review(ctx.org_id, p.id, ctx.n.id,
               expected_fingerprint: Social.Approvals.content_fingerprint(p)
             )

    final_card = Social.Approvals.live_card(p.id)
    shown_fingerprint = Social.Approvals.fingerprint(Repo.get!(Post, p.id))
    view = open(conn, ctx, ctx.h1)
    view |> element("#queue-#{p.id} [data-role='queue-edit']") |> render_click()

    assert has_element?(
             view,
             "#queue-form-#{p.id}[phx-submit='q_edit_save'] [data-role='queue-form-submit']",
             "Save text"
           )

    view |> element("#queue-form-#{p.id}") |> render_submit(%{"text" => "Final approver's edit"})
    assert Repo.get!(Post, p.id).body == "Final approver's edit"
    assert Repo.get!(Post, p.id).status == "quality_review"
    assert has_element?(view, "#queue-quality-review #{card(p)}")

    assert {:error, _} =
             Social.Approvals.decide_approve(final_card.canvas_id, ctx.h1, shown_fingerprint)

    assert Repo.get!(Post, p.id).approved_at == nil
    assert Fake.calls() == []
  end

  test "exact-post notification opens the actionable quality card", %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.n, "&post=#{p.id}")
    assert has_element?(view, "#queue-quality-review #{card(p)} [data-role='quality-pass']")
    refute has_element?(view, "[data-role='queue-target-details']")
    refute has_element?(view, "#queue-target-notice")
  end

  test "reviewer removal while open drops controls and refuses the next pass",
       %{conn: conn} = ctx do
    p = post!(ctx)
    view = open(conn, ctx, ctx.n)
    assert has_element?(view, "#{card(p)} [data-role='quality-pass']")
    Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: []))
    view |> with_target(card(p)) |> render_hook("quality_pass", %{})
    assert Repo.get!(Post, p.id).status == "quality_review"
    assert Repo.get!(Post, p.id).quality_passed_at == nil
    assert Social.Approvals.live_card(p.id) == nil
    assert Fake.calls() == []
    refute has_element?(view, "#{card(p)} [data-role='quality-pass']")
  end

  test "quality reviewer may prepare a draft and sends it for quality review",
       %{conn: conn} = ctx do
    p = post!(ctx, "draft")
    view = open(conn, ctx, ctx.n)
    assert has_element?(view, "#{form(p)} [data-role='draft-send']", "Send for quality review")
    view |> element(form(p)) |> render_submit(%{"body" => p.body, "intent" => "submit"})
    assert Repo.get!(Post, p.id).status == "quality_review"
    assert has_element?(view, "#queue-quality-review #{card(p)}")
    assert Social.Approvals.live_card(p.id) == nil
  end

  test "settings stores quality reviewers separately under existing settings authority",
       %{conn: conn} = ctx do
    view = open(conn, ctx, ctx.h1)
    view |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()

    assert has_element?(
             view,
             "#social-settings-form select[name='profile[quality_reviewer_user_ids][]']"
           )

    view
    |> element("#social-settings-form")
    |> render_submit(%{
      "profile" => %{
        "quality_reviewer_user_ids" => [ctx.h2.id],
        "approver_user_ids" => [ctx.h1.id],
        "space_id" => ctx.space.id
      }
    })

    saved = Social.get_profile(ctx.org_id, ctx.profile.id)
    assert saved.quality_reviewer_user_ids == [ctx.h2.id]
    assert saved.approver_user_ids == [ctx.h1.id]
  end

  test "quality reviewer role alone does not permit settings writes", %{conn: conn} = ctx do
    view = open(conn, ctx, ctx.n)
    view |> element("[data-role='social-tab-button'][data-tab='settings']") |> render_click()
    refute has_element?(view, "#social-settings-form")

    render_hook(view, "save_settings", %{
      "profile" => %{
        "quality_reviewer_user_ids" => [ctx.h1.id],
        "approver_user_ids" => [ctx.n.id]
      }
    })

    saved = Social.get_profile(ctx.org_id, ctx.profile.id)
    assert saved.quality_reviewer_user_ids == [ctx.n.id]
    assert saved.approver_user_ids == ctx.profile.approver_user_ids
  end

  test "unpassed final card offers return to quality review and no approval",
       %{conn: conn} = ctx do
    # Make the legacy pending card before enabling the gate, as an existing row would be.
    Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: []))
    {p, _card} = pending_post!(ctx, ctx.a)
    current_profile = Social.get_profile(ctx.org_id, ctx.profile.id)
    Repo.update!(Ecto.Changeset.change(current_profile, quality_reviewer_user_ids: [ctx.n.id]))
    assert Social.get_profile(ctx.org_id, ctx.profile.id).quality_reviewer_user_ids == [ctx.n.id]
    view = open(conn, ctx, ctx.h1)

    assert has_element?(
             view,
             "[data-role='quality-required']",
             "This needs a quality review before it can be approved."
           )

    refute has_element?(view, "[data-role='queue-approve']")
    refute has_element?(view, "[data-role='queue-approve-all']")

    view
    |> element("[data-role='queue-return-quality'][data-post-id='#{p.id}']")
    |> render_click()

    assert Repo.get!(Post, p.id).status == "quality_review"
    assert has_element?(view, "#queue-quality-review #{card(p)}")
  end

  test "passed final card shows who passed it and when", %{conn: conn} = ctx do
    p = post!(ctx)

    assert {:ok, _} =
             Social.pass_quality_review(ctx.org_id, p.id, ctx.n.id,
               expected_fingerprint: Social.Approvals.content_fingerprint(p)
             )

    view = open(conn, ctx, ctx.h1)
    assert has_element?(view, "[data-role='quality-pass-badge']", "Nina Viewer")
    assert has_element?(view, "[data-role='quality-pass-badge'] time[datetime]")
  end

  test "unfinished drafts, quality send-backs and final rejections keep distinct groups and one note",
       %{conn: conn} = ctx do
    {:ok, unfinished} = Social.create_post(ctx.org_id, ctx.a, %{body: "Still preparing"})

    submission = fn body ->
      {:ok, post} =
        Social.create_post(ctx.org_id, ctx.a, %{
          body: body,
          status: "needs_approval",
          scheduled_at: ~U[2031-01-15 09:00:00Z]
        })

      assert post.status == "quality_review"
      post
    end

    final_candidate = submission.("Final decision candidate")

    {:ok, passed} =
      Social.pass_quality_review(ctx.org_id, final_candidate.id, ctx.n.id,
        expected_fingerprint: Social.Approvals.content_fingerprint(final_candidate)
      )

    final_card = Social.Approvals.live_card(passed.id)

    {:ok, %{post: final}} =
      Social.Approvals.decide_reject(
        final_card.canvas_id,
        ctx.h1,
        "Final rejection note",
        Social.Approvals.fingerprint(passed)
      )

    quality_candidate = submission.("Quality revision candidate")

    {:ok, returned} =
      Social.send_back_quality_review(
        ctx.org_id,
        quality_candidate.id,
        ctx.n.id,
        "Quality revision note"
      )

    waiting = submission.("Waiting for the quality reviewer")
    assert final.rejected_at != nil
    assert returned.rejected_at == nil
    scope = {:profile, ctx.profile}

    assert Enum.sort(Enum.map(QueueFeed.drafts(ctx.h1, scope), & &1.id)) ==
             Enum.sort([unfinished.id, returned.id])

    assert Enum.map(QueueFeed.rejected(ctx.h1, scope), & &1.id) == [final.id]
    assert Enum.map(QueueFeed.quality_review(ctx.h1, scope), & &1.id) == [waiting.id]

    view = open(conn, ctx, ctx.h1)
    assert has_element?(view, "#queue-drafts #{card(unfinished)}")

    assert has_element?(
             view,
             "#queue-drafts #{card(returned)} [data-role='quality-return-note']",
             "Last send-back note: Quality revision note"
           )

    refute has_element?(view, "#queue-rejected #{card(returned)}")
    refute has_element?(view, "#queue-drafts #{card(final)}")
    assert has_element?(view, "#queue-quality-review #{card(waiting)}")

    assert has_element?(
             view,
             "[data-role='social-queue-pane'] > section:last-of-type#queue-rejected"
           )

    assert has_element?(
             view,
             "#queue-rejected [data-role='rejected-note']",
             "Final rejection note"
           )

    refute render(view |> element("#queue-rejected")) =~ "Last send-back note:"

    positions =
      Enum.map(
        ["queue-drafts", "queue-quality-review", "queue-needs-you", "queue-rejected"],
        fn id ->
          {position, _} = :binary.match(render(view), ~s(id="#{id}"))
          position
        end
      )

    assert positions == Enum.sort(positions)

    notes =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#queue-rejected-#{final.id} [data-role='rejected-note'], #queue-rejected-#{final.id} [data-role='quality-return-note']"
      )

    assert Enum.count(notes) == 1

    view
    |> element(form(final))
    |> render_submit(%{"body" => "Revised after final rejection", "intent" => "submit"})

    assert Repo.get!(Post, final.id).status == "quality_review"
    refute has_element?(view, "#queue-rejected #{card(final)}")

    assert has_element?(
             view,
             "#queue-quality-review #{card(final)} [data-role='quality-return-note']",
             "Final rejection note"
           )

    assert has_element?(
             view,
             "#queue-quality-review #{card(final)} [data-role='quality-return-note']",
             "Last rejection note: Final rejection note"
           )

    refute render(view |> element(card(final))) =~ "Last send-back note:"

    moved_notes =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{card(final)} [data-role='quality-return-note']")

    assert Enum.count(moved_notes) == 1

    view
    |> element("#{card(final)} [data-role='quality-send-back-form']")
    |> render_submit(%{"note" => "New quality send-back after final rejection"})

    returned_again = Repo.get!(Post, final.id)
    assert returned_again.status == "draft"
    assert returned_again.rejected_at == nil

    assert has_element?(
             view,
             "#queue-drafts #{card(final)} [data-role='quality-return-note']",
             "Last send-back note: New quality send-back after final rejection"
           )

    refute render(view |> element(card(final))) =~ "Last rejection note:"
    assert Fake.calls() == []
  end

  test "a final rejection note stays hidden from an edit-authorized but read-denied approver",
       %{conn: conn} = ctx do
    {:ok, candidate} =
      Social.create_post(ctx.org_id, ctx.a, %{
        body: "Final rejection read boundary",
        status: "needs_approval",
        scheduled_at: ~U[2031-01-15 09:00:00Z]
      })

    {:ok, passed} = Social.pass_quality_review(ctx.org_id, candidate.id, ctx.n.id)
    approval = Social.Approvals.live_card(passed.id)

    {:ok, %{post: rejected}} =
      Social.Approvals.decide_reject(
        approval.canvas_id,
        ctx.h1,
        "Private final rejection note"
      )

    assert :ok == Social.post_preparer_check(ctx.org_id, ctx.profile, ctx.a, ctx.h1.id)
    view = open(conn, ctx, ctx.h1)

    assert has_element?(
             view,
             "#queue-rejected [data-role='rejected-note']",
             "Private final rejection note"
           )

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "social.use",
        resource: {:project, ctx.profile.project_id}
      })

    assert :ok == Social.post_preparer_check(ctx.org_id, ctx.profile, ctx.a, ctx.h1.id)
    assert Social.PostPresentation.read(rejected, {:user, ctx.h1.id}) == nil

    view = open(conn, ctx, ctx.h1)
    assert has_element?(view, form(rejected))
    refute has_element?(view, "#queue-rejected [data-role='rejected-note']")
    refute has_element?(view, "#{card(rejected)} [data-role='quality-return-note']")
    refute render(view) =~ "Private final rejection note"
    assert Fake.calls() == []
  end
end
