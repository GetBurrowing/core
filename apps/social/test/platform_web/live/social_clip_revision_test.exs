defmodule PlatformWeb.SocialClipRevisionTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, Clip, ClipEditRequest, ClipRender, ClipRevisions}

  setup do
    w = render_world!()
    file = stored_file!(w.project, "first cut #{unique()}", "first.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Working title",
          "caption" => "Working caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    base = Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)
    %{w: w, clip: clip, base: base}
  end

  defp open(conn, ctx, user_id \\ nil) do
    {:ok, view, _} =
      live_isolated(conn, PlatformWeb.SocialClipRevisionHost,
        session: %{
          "scope" => ctx.w.scope,
          "profile_id" => ctx.w.profile.id,
          "clip_id" => ctx.clip.id,
          "user_id" => user_id || ctx.w.approver.id
        }
      )

    view
  end

  defp request!(ctx, attrs \\ %{}) do
    {:ok, %{request: request}} =
      ClipRevisions.request_edit(
        ctx.w.scope,
        ctx.clip.id,
        ctx.w.approver.id,
        Map.merge(
          %{
            request_id: Ecto.UUID.generate(),
            base_render_id: ctx.base.id,
            assignee: :self,
            note: "Tighten the opening"
          },
          attrs
        )
      )

    request
  end

  defp form_id(ctx), do: "#revision-#{ctx.clip.id}-request-form"
  defp upload_form(ctx), do: "#revision-#{ctx.clip.id}-upload-form"

  defp eligible_agent!(w) do
    join!(w.profile.space_id, :agent, w.agent.id)

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "revision-ui-#{unique()}",
        agent_id: w.agent.id,
        owner_user_id: w.approver.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social", "files"], nil)

    runtime
  end

  test "a human requests a self recut with a note and sees Awaiting edit", %{conn: conn} = ctx do
    view = open(conn, ctx)

    assert has_element?(
             view,
             "#{form_id(ctx)} select[name='request[assignee]'] option[value='self']"
           )

    view
    |> form(form_id(ctx), request: %{note: "  Cut the pause  ", assignee: "self"})
    |> render_submit()

    latest = ClipRevisions.latest(ctx.clip.id)
    assert latest.assigned_user_id == ctx.w.approver.id
    assert latest.note == "Cut the pause"
    assert has_element?(view, "[data-role='clip-edit-state']", "Awaiting edit")
    assert has_element?(view, "[data-role='clip-edit-latest-note']", "Cut the pause")
    assert has_element?(view, upload_form(ctx))
    refute has_element?(view, form_id(ctx))
    refute has_element?(view, "a[href*='/files/']")
  end

  test "an editor must be chosen explicitly, including self edit", %{conn: conn} = ctx do
    view = open(conn, ctx)
    assert has_element?(view, "#{form_id(ctx)} option[value='']", "Choose an editor")
    refute has_element?(view, "#{form_id(ctx)} option[value='self'][selected]")
    view |> form(form_id(ctx), request: %{note: "Tighten this"}) |> render_submit()
    assert ClipRevisions.latest(ctx.clip.id) == nil

    assert has_element?(
             view,
             "[data-role='clip-edit-error']",
             "Choose self or an available editing agent"
           )

    assert has_element?(view, "#{form_id(ctx)} label", "Editing instructions")

    view
    |> form(form_id(ctx), request: %{note: "Tighten this", assignee: "self"})
    |> render_submit()

    assert ClipRevisions.latest(ctx.clip.id).assigned_user_id == ctx.w.approver.id
  end

  test "a plain rejection without an edit action has no empty recut heading",
       %{conn: conn} = ctx do
    {:ok, _} =
      Social.ClipDecisions.reject_clip(
        ctx.w.org_id,
        ctx.clip.id,
        ctx.w.approver.id,
        "Not for this audience"
      )

    view = open(conn, ctx)
    refute has_element?(view, "h3", "Request a recut")
    refute has_element?(view, "#revision-#{ctx.clip.id}")
    refute has_element?(view, "[data-role='clip-revision']")
    refute has_element?(view, form_id(ctx))
    refute has_element?(view, upload_form(ctx))
  end

  test "empty notes and forged agent assignments write no editing request", %{conn: conn} = ctx do
    view = open(conn, ctx)
    view |> form(form_id(ctx), request: %{note: " ", assignee: "self"}) |> render_submit()
    assert has_element?(view, "[data-role='clip-edit-error']", "Write an editing note first")
    assert ClipRevisions.latest(ctx.clip.id) == nil

    view
    |> with_target("#revision-#{ctx.clip.id}")
    |> render_hook(
      "revision_request",
      %{"request" => %{"note" => "Secret instruction", "assignee" => "agent:#{ctx.w.agent.id}"}}
    )

    assert ClipRevisions.latest(ctx.clip.id) == nil
    assert Repo.get!(Clip, ctx.clip.id).review_status == "pending"
  end

  test "the picker offers only eligible agents and an explicit choice notifies that agent",
       %{conn: conn} = ctx do
    eligible_agent!(ctx.w)
    view = open(conn, ctx)
    assert has_element?(view, "#{form_id(ctx)} option[value='agent:#{ctx.w.agent.id}']")

    view
    |> form(form_id(ctx),
      request: %{note: "Reframe this cut", assignee: "agent:#{ctx.w.agent.id}"}
    )
    |> render_submit()

    request = ClipRevisions.latest(ctx.clip.id)
    assert request.assigned_agent_id == ctx.w.agent.id
    assert request.notification_status == "sent"

    assert has_element?(
             view,
             "[data-role='clip-edit-notification']",
             "Request posted for #{ctx.w.agent.name}. Receipt is not confirmed."
           )

    refute render(view) =~ "Editing agent notified"
    refute has_element?(view, upload_form(ctx))
  end

  test "a queued old form cannot replace a genuinely failed notification or wake the agent",
       %{conn: conn} = ctx do
    eligible_agent!(ctx.w)
    space = Platform.Chat.get_space(ctx.w.profile.space_id)
    Repo.update!(Ecto.Changeset.change(space, archived_at: DateTime.utc_now()))
    view = open(conn, ctx)
    params = %{note: "Original editing instruction", assignee: "agent:#{ctx.w.agent.id}"}
    view |> form(form_id(ctx), request: params) |> render_submit()
    failed = ClipRevisions.latest(ctx.clip.id)
    assert failed.notification_status == "failed"
    assert failed.notification_attempted_at != nil
    assert failed.notification_message_id == nil
    assert has_element?(view, "#{form_id(ctx)} button", "Replace editing request")
    Repo.update!(Ecto.Changeset.change(Platform.Chat.get_space(space.id), archived_at: nil))

    # The receipt identifies the exact server nonce used by the first rendered form.
    # Reopening Chat makes an accidental replacement's second notification observable.
    duplicate = %{
      "request" => %{
        "request_id" => failed.client_request_id,
        "note" => params.note,
        "assignee" => params.assignee
      }
    }

    view |> with_target("#revision-#{ctx.clip.id}") |> render_hook("revision_request", duplicate)
    assert Repo.aggregate(ClipEditRequest, :count) == 1
    assert ClipRevisions.latest(ctx.clip.id).id == failed.id
    original = Repo.get!(ClipEditRequest, failed.id)
    assert original.notification_status == "failed"
    assert original.notification_attempted_at == failed.notification_attempted_at
    assert original.notification_message_id == nil
    assert has_element?(view, "[data-role='clip-edit-error']", "This editing form has changed")
  end

  for status <- ["failed", "uncertain"] do
    test "a #{status} notification offers an explicit replacement and retains old history",
         %{conn: conn} = ctx do
      old = request!(ctx, %{note: "Earlier instruction"})
      # Persist an ambiguous/failed notification outcome, without claiming a successful wake.
      Repo.update!(Ecto.Changeset.change(old, notification_status: unquote(status)))
      view = open(conn, ctx)

      assert has_element?(
               view,
               "[data-role='clip-edit-replacement-warning']",
               "old notification may already have arrived"
             )

      assert has_element?(view, "#{form_id(ctx)} button", "Replace editing request")

      view
      |> form(form_id(ctx), request: %{note: "Replacement instruction", assignee: "self"})
      |> render_submit()

      newer = ClipRevisions.latest(ctx.clip.id)
      assert newer.id != old.id
      assert Repo.get!(ClipEditRequest, old.id).notification_status == unquote(status)
      assert has_element?(view, "[data-role='clip-edit-history-note']", "Earlier instruction")
      assert has_element?(view, "[data-role='clip-edit-latest-note']", "Replacement instruction")
    end
  end

  for status <- [nil, "attempted"] do
    test "an agent notification stored as #{inspect(status)} offers explicit replacement with a late-message warning",
         %{conn: conn} = ctx do
      eligible_agent!(ctx.w)
      old = request!(ctx, %{assignee: {:agent, ctx.w.agent.id}, note: "Unconfirmed earlier edit"})
      Repo.update!(Ecto.Changeset.change(old, notification_status: unquote(status)))
      view = open(conn, ctx)
      assert has_element?(view, "#{form_id(ctx)} button", "Replace editing request")
      assert has_element?(view, "[data-role='clip-edit-replacement-warning']", "may still arrive")

      view
      |> form(form_id(ctx), request: %{note: "I will edit it", assignee: "self"})
      |> render_submit()

      newer = ClipRevisions.latest(ctx.clip.id)
      assert newer.id != old.id
      assert newer.assigned_user_id == ctx.w.approver.id
      assert newer.notification_status == "not_applicable"
      assert Repo.get!(ClipEditRequest, old.id).notification_status == unquote(status)

      assert has_element?(
               view,
               "[data-role='clip-edit-history-note']",
               "Unconfirmed earlier edit"
             )
    end
  end

  test "revoked files access hides notes and refuses forged requests on the next event",
       %{conn: conn} = ctx do
    request!(ctx, %{note: "Private instruction"})
    view = open(conn, ctx)
    assert has_element?(view, "[data-role='clip-edit-latest-note']", "Private instruction")

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.w.approver.id},
        permission: "files.read",
        resource: {:project, ctx.w.project.id}
      })

    view
    |> with_target("#revision-#{ctx.clip.id}")
    |> render_hook(
      "revision_request",
      %{"request" => %{"note" => "Forged request", "assignee" => "self"}}
    )

    refute has_element?(view, "[data-role='clip-edit-latest-note']")
    refute has_element?(view, "[data-role='clip-edit-history-note']")
    refute has_element?(view, "form")
    assert Repo.aggregate(ClipEditRequest, :count) == 1
  end

  test "a self-assigned upload appends a version and preserves current title and caption",
       %{conn: conn} = ctx do
    request = request!(ctx)
    view = open(conn, ctx)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Clip, ctx.clip.id),
        title: "Newer working title",
        caption: "Newer working caption"
      )
    )

    bytes = File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__))

    upload =
      file_input(view, upload_form(ctx), :recut, [
        %{name: "returned.mp4", content: bytes, type: "video/mp4", last_modified: 1}
      ])

    render_upload(upload, "returned.mp4")
    view |> element(upload_form(ctx)) |> render_submit()

    error_text =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='clip-edit-error']")
      |> LazyHTML.text()

    assert has_element?(view, "[data-role='social-notice']", "New version returned for review."),
           error_text

    current = Repo.get!(Clip, ctx.clip.id)
    assert current.rev == ctx.clip.rev + 1
    assert current.review_status == "pending"
    assert current.title == "Newer working title"
    assert current.caption == "Newer working caption"
    returned = Repo.get!(ClipEditRequest, request.id)
    assert returned.returned_render_id != nil
    render = Repo.get!(ClipRender, returned.returned_render_id)
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    {:ok, submission_id} =
      Social.ClipRevisionContract.submission_id(request.id, ctx.clip.id, ctx.base.id, sha)

    assert render.provenance["submission_facts"]["sha256"] == sha
    assert render.provenance["submission_facts"]["submission_id"] == submission_id
    assert has_element?(view, "[data-role='social-notice']", "New version returned for review.")
    assert has_element?(view, "[data-role='clip-edit-latest-note']", "Tighten the opening")
    assert has_element?(view, "[data-role='clip-edit-state']", "Returned for review")
    assert Repo.all(Social.Post) == []
  end

  test "another current preparer can read the editing note but cannot upload for a self assignee",
       %{conn: conn} = ctx do
    request!(ctx)
    other = member!(user!(), ctx.w.org_id)

    Social.update_profile(ctx.w.org_id, ctx.w.profile, %{
      approver_user_ids: [ctx.w.approver.id, other.id]
    })

    view = open(conn, ctx, other.id)
    assert has_element?(view, "[data-role='clip-edit-latest-note']", "Tighten the opening")
    refute has_element?(view, upload_form(ctx))
  end

  test "a newer unrelated render keeps request history without labelling itself a returned edit",
       %{conn: conn} = ctx do
    request = request!(ctx)

    output =
      stored_file!(
        ctx.w.project,
        File.read!(Path.expand("../../support/fixtures/episode_pipeline/one.mp4", __DIR__)),
        "returned.mp4",
        "video/mp4"
      )

    {:ok, submission_id} =
      Social.ClipRevisionContract.submission_id(
        request.id,
        ctx.clip.id,
        ctx.base.id,
        output.content_hash
      )

    {:ok, %{render: returned}} =
      ClipRevisions.append_version(ctx.w.scope, ctx.clip.id, {:user, ctx.w.approver.id}, %{
        file_id: output.id,
        request_id: request.id,
        base_render_id: ctx.base.id,
        submission_id: submission_id,
        sha256: output.content_hash,
        byte_size: output.byte_size,
        duration_s: 29.0,
        width: 1080,
        height: 1920
      })

    before = open(conn, ctx)
    assert has_element?(before, "[data-role='clip-edit-state']", "Returned for review")
    other = stored_file!(ctx.w.project, "unrelated cut #{unique()}", "other.mp4", "video/mp4")

    {:ok, _} =
      Repo.transaction(fn ->
        Social.ClipVersions.append!(ctx.clip.id, other, %{}, %{
          completion_key: "unrelated-#{unique()}"
        })
      end)

    view = open(conn, ctx)
    refute has_element?(view, "[data-role='clip-edit-state']", "Returned for review")
    assert has_element?(view, "[data-role='clip-edit-history-note']", "Tighten the opening")
    assert Repo.get!(ClipEditRequest, request.id).returned_render_id == returned.id
  end

  test "an assigned agent losing access stays awaiting edit with a blocked-editor explanation",
       %{conn: conn} = ctx do
    runtime = eligible_agent!(ctx.w)
    request = request!(ctx, %{assignee: {:agent, ctx.w.agent.id}})
    assert request.notification_status == "sent"
    Repo.update!(Ecto.Changeset.change(runtime, status: "revoked"))
    view = open(conn, ctx)
    assert has_element?(view, "[data-role='clip-edit-state']", "Awaiting edit")
    assert has_element?(view, "[data-role='clip-edit-editor-blocked']", "no longer has access")
    assert has_element?(view, "[data-role='clip-edit-latest-note']", "Tighten the opening")
    refute has_element?(view, form_id(ctx))
    refute has_element?(view, upload_form(ctx))
    assert Repo.get!(ClipEditRequest, request.id).notification_status == "sent"
  end
end
