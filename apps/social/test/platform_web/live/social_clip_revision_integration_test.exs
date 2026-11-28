defmodule PlatformWeb.SocialClipRevisionIntegrationTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, ClipRender, ClipRevisions}

  setup do
    w = render_world!()
    media = stored_file!(w.project, "first #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => media.id,
          "title" => "Test clip",
          "caption" => "Working copy",
          "duration_s" => 20,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)
    %{w: w, clip: clip, base: base}
  end

  defp open(conn, w, view) do
    conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, root, _} = live(conn, "/m/social?tab=clips&view=#{view}&profile=#{w.profile.id}")
    find_live_child(root, "ext-page-social")
  end

  test "rejection and editing instructions are labelled for their own actions",
       %{conn: conn} = ctx do
    first = open(conn, ctx.w, "review")
    assert has_element?(first, "label[for='clip-note']", "Rejection note")
    assert has_element?(first, "#review-revision-#{ctx.clip.id} label", "Editing instructions")
    refute has_element?(first, "[data-role='clip-note'][placeholder*='Use Request edit']")
    assert has_element?(first, "[data-role='clip-note-hint']", "Used when you choose Reject")
  end

  test "Review and Library distinguish Awaiting edit from pending and bare rejection",
       %{conn: conn} = ctx do
    first = open(conn, ctx.w, "review")
    assert has_element?(first, "#review-revision-#{ctx.clip.id} form")

    assert {:ok, %{request: request}} =
             ClipRevisions.request_edit(ctx.w.scope, ctx.clip.id, ctx.w.approver.id, %{
               request_id: Ecto.UUID.generate(),
               base_render_id: ctx.base.id,
               assignee: :self,
               note: "Tighten this"
             })

    review = open(recycle(conn), ctx.w, "review")
    assert has_element?(review, "[data-role='clips-awaiting-edit']", "Awaiting edit")

    assert has_element?(
             review,
             "a[data-role='clips-awaiting-edit-link'][href='#clips-awaiting-edit']",
             "Awaiting edit (1)"
           )

    assert has_element?(review, "#clips-awaiting-edit[data-role='clips-awaiting-edit']")
    assert has_element?(review, "#awaiting-revision-#{ctx.clip.id}", "Tighten this")
    refute has_element?(review, "[data-role='clips-queue-item'][data-clip-id='#{ctx.clip.id}']")

    result =
      Social.ClipLibrary.list(ctx.w.org_id, %{
        "show" => ctx.w.profile.id,
        "status" => "Awaiting edit"
      })

    assert [%{clip: %{id: id}, state: "Awaiting edit"}] = result.items
    assert id == ctx.clip.id
    assert result.total == 1
    assert request.returned_render_id == nil
    library = open(recycle(conn), ctx.w, "library")

    assert has_element?(
             library,
             "#library-clip-#{ctx.clip.id} [data-role='library-state']",
             "Awaiting edit"
           )

    library
    |> element("#library-clip-#{ctx.clip.id} [data-role='library-thumbnail']")
    |> render_click()

    assert has_element?(library, "[data-role='library-decision']", "Sent back by")
    refute has_element?(library, "[data-role='library-rejection']")
    assert has_element?(library, "#library-revision-#{ctx.clip.id}", "Tighten this")
  end

  test "a returned render keeps the instruction visible without crediting the original agent for the recut",
       %{conn: conn} = ctx do
    {:ok, %{request: request}} =
      ClipRevisions.request_edit(ctx.w.scope, ctx.clip.id, ctx.w.approver.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: ctx.base.id,
        assignee: :self,
        note: "Fix the pause"
      })

    file =
      stored_file!(
        ctx.w.project,
        File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__)),
        "recut.mp4",
        "video/mp4"
      )

    {:ok, id} =
      Social.ClipRevisionContract.submission_id(
        request.id,
        ctx.clip.id,
        ctx.base.id,
        file.content_hash
      )

    assert {:ok, _} =
             ClipRevisions.append_version(ctx.w.scope, ctx.clip.id, {:user, ctx.w.approver.id}, %{
               request_id: request.id,
               base_render_id: ctx.base.id,
               submission_id: id,
               file_id: file.id,
               sha256: file.content_hash,
               byte_size: file.byte_size,
               duration_s: 15,
               width: 1080,
               height: 1920
             })

    review = open(conn, ctx.w, "review")

    assert has_element?(
             review,
             "[data-role='clips-details-body'] [data-role='closing-versions'] + #review-revision-#{ctx.clip.id} [data-role='clip-edit-latest-note']",
             "Fix the pause"
           )

    assert has_element?(
             review,
             "[data-role='clips-details-body'] [data-role='clip-edit-state']",
             "Returned for review"
           )

    refute has_element?(review, "[data-role='clips-awaiting-edit']")
    refute has_element?(review, "[data-role='clip-byline']", "rendered by")
    assert has_element?(review, "[data-role='clip-byline']", "originally submitted by")
  end

  test "human return confirmation survives removal of its Awaiting edit upload panel",
       %{conn: conn} = ctx do
    {:ok, %{request: request}} =
      ClipRevisions.request_edit(ctx.w.scope, ctx.clip.id, ctx.w.approver.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: ctx.base.id,
        assignee: :self,
        note: "Fix this pause"
      })

    review = open(conn, ctx.w, "review")
    upload_form = "#awaiting-revision-#{ctx.clip.id}-upload-form"
    bytes = File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__))

    upload =
      file_input(review, upload_form, :recut, [
        %{name: "returned.mp4", content: bytes, type: "video/mp4", last_modified: 1}
      ])

    render_upload(upload, "returned.mp4")
    review |> element(upload_form) |> render_submit()
    _ = render(review)
    assert Repo.get!(Social.ClipEditRequest, request.id).returned_render_id != nil
    refute has_element?(review, "#awaiting-revision-#{ctx.clip.id}")
    assert has_element?(review, "[data-role='social-notice']", "New version returned for review.")

    assert has_element?(
             review,
             "[data-role='clip-return-confirmation'][tabindex='-1'][phx-mounted]"
           )

    html = render(review) |> LazyHTML.from_fragment()

    [mounted] =
      html
      |> LazyHTML.query("[data-role='clip-return-confirmation']")
      |> LazyHTML.attribute("phx-mounted")

    assert [["focus", %{}]] = Jason.decode!(mounted)

    assert has_element?(
             review,
             "[data-role='clip-return-confirmation'][role='region']",
             "New version returned for review."
           )

    assert has_element?(review, "[data-role='clip-return-confirmation'] [role='status']")

    review
    |> element("[data-role='clip-return-confirmation'] button", "Dismiss")
    |> render_click()

    refute has_element?(review, "[data-role='clip-return-confirmation']")
    refute has_element?(review, "[data-role='clip-revision'] [data-role='social-notice']")
    assert Repo.get!(Social.Clip, ctx.clip.id).review_status == "pending"
  end

  test "a plain rejected library detail has no empty revision wrapper", %{conn: conn} = ctx do
    {:ok, _} =
      Social.ClipDecisions.reject_clip(
        ctx.w.org_id,
        ctx.clip.id,
        ctx.w.approver.id,
        "Plain rejection"
      )

    library = open(conn, ctx.w, "library")

    library
    |> element("#library-clip-#{ctx.clip.id} [data-role='library-thumbnail']")
    |> render_click()

    assert has_element?(library, "[data-role='library-rejection']", "Plain rejection")
    refute has_element?(library, "#library-revision-#{ctx.clip.id}")
    refute has_element?(library, "#library-detail [data-role='clip-revision']")
  end

  test "Awaiting edit receives phone scroll clearance only while a decision bar is present",
       %{conn: conn} = ctx do
    {:ok, _} =
      ClipRevisions.request_edit(ctx.w.scope, ctx.clip.id, ctx.w.approver.id, %{
        request_id: Ecto.UUID.generate(),
        base_render_id: ctx.base.id,
        assignee: :self,
        note: "Self edit"
      })

    empty_bay = open(conn, ctx.w, "review")
    refute has_element?(empty_bay, "[data-role='clips-pbar']")
    refute has_element?(empty_bay, "[data-role='clip-edit-action-clearance']")
    file = stored_file!(ctx.w.project, "other pending #{unique()}", "pending.mp4", "video/mp4")

    {:ok, _} =
      AgentDrafts.submit_clip(
        ctx.w.scope,
        ctx.w.profile.id,
        %{file_id: file.id, title: "Still reviewing", duration_s: 20, width: 1080, height: 1920},
        ctx.w.agent.id
      )

    occupied_bay = open(recycle(conn), ctx.w, "review")
    assert has_element?(occupied_bay, "[data-role='clips-pbar']")

    assert has_element?(
             occupied_bay,
             "#clips-awaiting-edit [data-role='clip-edit-action-clearance'][aria-hidden='true']"
           )

    # This checks the overlay-dependent clearance state, not rendered geometry.
    # Ordinary tapping and safe-area clearance need the browser check.
  end
end
