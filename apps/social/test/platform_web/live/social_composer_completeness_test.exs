defmodule PlatformWeb.SocialComposerCompletenessTest do
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Platform.SocialApprovalFixtures
  import Platform.SocialComposerFixtures
  import Platform.SocialFixtures, only: [project!: 1, unique: 0]

  alias Platform.{Repo, Social}
  alias Platform.Social.Post

  setup do
    restore = use_llm_stub!()
    on_exit(restore)
    ctx = approval_fixture()
    project = project!(ctx.org_id)
    {:ok, profile} = Social.update_profile(ctx.org_id, ctx.profile, %{project_id: project.id})
    {:ok, account} = Social.update_account(ctx.org_id, ctx.a, %{status: "connected"})
    drafting_agent!()
    stub_llm!()
    Map.merge(ctx, %{profile: profile, a: account, project: project})
  end

  defp open_draft(ctx, accounts \\ nil, user \\ nil) do
    conn = Plug.Test.init_test_session(ctx.conn, current_user_id: (user || ctx.h1).id)
    {:ok, view, _} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    Req.Test.allow(llm_stub(), self(), child.pid)
    child |> element("[data-role='social-new-idea']") |> render_click()

    child
    |> form("#composer-idea-form",
      idea: %{title: "A scheduled idea", account_ids: accounts || [ctx.a.id]}
    )
    |> render_submit()

    render_async(child)
    child
  end

  test "a gated brand requests quality review without a combined approval control", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: [ctx.n.id]))
    child = open_draft(ctx)
    refute has_element?(child, "[data-role='composer-send-approve']")
    assert has_element?(child, "[data-role='composer-send']", "Send for quality review")

    child
    |> form("#composer-edit-#{ctx.a.id}", version: %{scheduled_at: "2099-01-02T13:45"})
    |> render_change()

    child |> element("[data-role='composer-send']") |> render_click()
    assert [%Post{status: "quality_review", approved_by_user_id: nil}] = Repo.all(Post)
    assert has_element?(child, "[data-role='composer-sent-heading']", "Quality review requested")
    assert has_element?(child, "[data-role='composer-sent-lines']", "In quality review")
    refute Repo.exists?(Platform.Social.ApprovalCard)
  end

  defp media!(project) do
    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: project.id,
        name: "launch.png",
        original_filename: "launch.png",
        content_type: "image/png",
        byte_size: 1024,
        storage_key: "files/#{project.id}/#{unique()}/launch.png",
        content_hash: String.duplicate("b", 64)
      })

    file
  end

  test "missing publish time leaves an editable control and blocks scheduled approval", ctx do
    child = open_draft(ctx)
    assert has_element?(child, "[data-role='composer-publish-time']")
    assert has_element?(child, "[data-role='composer-publish-time'].min-h-11")
    assert has_element?(child, "[data-role='composer-send'].min-h-11")
    assert has_element?(child, "[data-role='composer-send-approve'].min-h-11")

    assert has_element?(
             child,
             "[data-role='composer-schedule-required']",
             "Choose a publish time for each post first."
           )

    assert has_element?(
             child,
             "[data-role='composer-send-approve'][disabled]",
             "Approve scheduled posts"
           )

    assert has_element?(child, "[data-role='composer-send'][disabled]")

    child
    |> form("#composer-edit-#{ctx.a.id}", version: %{scheduled_at: "2099-01-02T13:45"})
    |> render_change()

    refute has_element?(child, "[data-role='composer-send-approve'][disabled]")
    refute has_element?(child, "[data-role='composer-send'][disabled]")

    child
    |> form("#composer-edit-#{ctx.a.id}", version: %{scheduled_at: "2001-01-02T13:45"})
    |> render_change()

    assert has_element?(child, "[data-role='composer-send'][disabled]")
  end

  test "explicit save keeps an incomplete version as a draft without review or publishing", ctx do
    Platform.Social.Publisher.Fake.reset()
    child = open_draft(ctx)
    child |> element("[data-role='composer-save-drafts']") |> render_click()

    assert [post] = Repo.all(Post)
    assert post.status == "draft"
    assert is_nil(post.scheduled_at)
    refute Repo.exists?(Platform.Social.ApprovalCard)
    assert Platform.Social.Publisher.Fake.calls() == []

    assert has_element?(
             child,
             "a[href='/m/social?profile=#{ctx.profile.id}&tab=queue#queue-drafts']",
             "Open Drafts"
           )

    refute render(child) =~ "An approver for this account can finish"
  end

  test "a non-approver is told who can finish a saved draft", ctx do
    child = open_draft(ctx, [ctx.a.id], ctx.n)
    child |> element("[data-role='composer-save-drafts']") |> render_click()

    assert render(child) =~
             "Saved as a draft. An approver for this account can finish and send it from the Queue."

    assert [%Post{status: "draft"}] = Repo.all(Post)
  end

  test "mixed-account confirmation identifies only the account the saver cannot edit", ctx do
    {:ok, _} = Social.set_account_owner(ctx.org_id, ctx.a, ctx.h2.id)
    child = open_draft(ctx, [ctx.a.id, ctx.d.id])
    child |> element("[data-role='composer-save-drafts']") |> render_click()

    assert has_element?(
             child,
             "[data-role='composer-sent-lines']",
             "LinkedIn @htc_official: Saved as a draft."
           )

    refute has_element?(
             child,
             "[data-role='composer-sent-lines']",
             "LinkedIn @htc_drafts: Saved as a draft."
           )

    assert length(Repo.all(Post)) == 2
  end

  test "saving keeps entered title, time and selected media", ctx do
    file = media!(ctx.project)

    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "youtube",
        handle: "@show",
        status: "connected"
      })

    child = open_draft(ctx, [youtube.id])

    child
    |> form("#composer-edit-#{youtube.id}",
      version: %{
        title: "My title",
        text: "Caption",
        scheduled_at: "2099-01-02T13:45",
        media_file_ids: [file.id]
      }
    )
    |> render_change()

    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert [post] = Repo.all(Post)
    assert post.status == "draft"
    assert post.platform_options["title"] == "My title"
    assert post.body == "Caption"
    assert post.media_file_ids == [file.id]
    assert DateTime.compare(post.scheduled_at, ~U[2099-01-02 13:45:00Z]) == :eq
  end

  test "a refused save keeps the typed version on screen", ctx do
    child = open_draft(ctx)

    child
    |> form("#composer-edit-#{ctx.a.id}", version: %{text: "Keep my words"})
    |> render_change()

    Repo.update_all(from(a in Social.Account, where: a.id == ^ctx.a.id),
      set: [archived_at: DateTime.utc_now()]
    )

    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert has_element?(child, "[data-role='composer-edit']", "Keep my words")
    assert has_element?(child, "[data-role='composer-send-error']")
    assert Repo.all(Post) == []
  end

  test "an empty edited version can be kept as an incomplete draft", ctx do
    child = open_draft(ctx)
    child |> form("#composer-edit-#{ctx.a.id}", version: %{text: ""}) |> render_change()
    refute has_element?(child, "[data-role='composer-save-drafts'][disabled]")
    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert [%Post{status: "draft", body: body}] = Repo.all(Post)
    assert body in [nil, ""]
    refute Repo.exists?(Platform.Social.ApprovalCard)
  end

  test "by-hand accounts can still enter review without a publishing time", ctx do
    child = open_draft(ctx, [ctx.d.id])
    refute has_element?(child, "[data-role='composer-schedule-required']")
    refute has_element?(child, "[data-role='composer-send'][disabled]")
    child |> element("[data-role='composer-send']") |> render_click()
    assert [post] = Repo.all(Post)
    assert post.account_id == ctx.d.id
    assert post.status == "needs_approval"
    assert is_nil(post.scheduled_at)
  end

  test "selected project media and edited schedule are preserved in submitted draft", ctx do
    file = media!(ctx.project)
    other = media!(project!(ctx.org_id))
    child = open_draft(ctx)
    assert has_element?(child, "[data-role='composer-media-choice'][value='#{file.id}']")
    refute has_element?(child, "[data-role='composer-media-choice'][value='#{other.id}']")

    child
    |> form("#composer-edit-#{ctx.a.id}",
      version: %{media_file_ids: [file.id], scheduled_at: "2099-01-02T13:45"}
    )
    |> render_change()

    assert has_element?(child, "[data-role='composer-selected-media']", "launch.png")
    child |> element("[data-role='composer-send']") |> render_click()
    assert [post] = Repo.all(Post)
    assert post.media_file_ids == [file.id]
    assert DateTime.compare(post.scheduled_at, ~U[2099-01-02 13:45:00Z]) == :eq
  end

  test "missing video media gives the actionable publishing error", ctx do
    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "youtube",
        handle: "@show",
        status: "connected"
      })

    child = open_draft(ctx, [youtube.id])

    child
    |> form("#composer-edit-#{youtube.id}", version: %{scheduled_at: "2099-01-02T13:45"})
    |> render_change()

    child |> element("[data-role='composer-send']") |> render_click()
    assert has_element?(child, "[data-role='composer-send-error']", "Add a video.")
    assert Repo.all(Post) == []

    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert [%Post{status: "draft", media_file_ids: []}] = Repo.all(Post)
    refute Repo.exists?(Platform.Social.ApprovalCard)
  end

  defp three_versions(ctx, with_video?) do
    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "youtube",
        handle: "@third",
        status: "connected"
      })

    file = media!(ctx.project)
    file = Repo.update!(Ecto.Changeset.change(file, content_type: "video/mp4"))
    child = open_draft(ctx, [ctx.a.id, ctx.d.id, youtube.id])

    for account <- [ctx.a, youtube] do
      child
      |> form("#composer-edit-#{account.id}", version: %{scheduled_at: "2099-01-02T13:45"})
      |> render_change()
    end

    if with_video? do
      child
      |> form("#composer-edit-#{youtube.id}", version: %{media_file_ids: [file.id]})
      |> render_change()
    end

    {child, youtube, file}
  end

  test "three versions with one incomplete write nothing and show its column's lines", ctx do
    {child, youtube, file} = three_versions(ctx, false)
    child |> element("[data-role='composer-send']") |> render_click()
    assert Repo.all(Post) == []
    refute Repo.exists?(Social.ApprovalCard)

    assert has_element?(
             child,
             "#composer-column-#{youtube.id} [data-role='composer-review-error']",
             "Add a video."
           )

    refute has_element?(child, "#composer-column-#{ctx.a.id} [data-role='composer-review-error']")
    assert has_element?(child, "[data-role='composer-send']", "Send 3 for approval")

    child
    |> form("#composer-edit-#{youtube.id}", version: %{media_file_ids: [file.id]})
    |> render_change()

    child |> element("[data-role='composer-send']") |> render_click()

    assert Enum.sort(Enum.map(Repo.all(Post), & &1.account_id)) ==
             Enum.sort([ctx.a.id, ctx.d.id, youtube.id])

    refute render(child) =~ "went out"
  end

  test "every incomplete selected version gets its own complete error list", ctx do
    {child, youtube, _file} = three_versions(ctx, false)
    child |> form("#composer-edit-#{ctx.a.id}", version: %{text: ""}) |> render_change()
    child |> form("#composer-edit-#{youtube.id}", version: %{title: ""}) |> render_change()
    child |> element("[data-role='composer-send']") |> render_click()
    assert Repo.all(Post) == []

    assert has_element?(
             child,
             "#composer-column-#{ctx.a.id} [data-role='composer-review-error']",
             "Add the post text."
           )

    assert has_element?(
             child,
             "#composer-column-#{youtube.id} [data-role='composer-review-error']",
             "Add a video title"
           )

    assert has_element?(
             child,
             "#composer-column-#{youtube.id} [data-role='composer-review-error']",
             "Add a video."
           )

    assert has_element?(child, "[data-role='composer-send']", "Send 3 for approval")
  end

  test "a rolled-back multi-draft save shows the failing column and retries all unsaved versions",
       ctx do
    {child, youtube, _file} = three_versions(ctx, false)

    child
    |> form("#composer-edit-#{youtube.id}", version: %{title: String.duplicate("x", 101)})
    |> render_change()

    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert Repo.all(Post) == []

    assert has_element?(
             child,
             "#composer-column-#{youtube.id} [data-role='composer-review-error']",
             "100"
           )

    refute has_element?(child, "[data-role='composer-result']")

    child
    |> form("#composer-edit-#{youtube.id}", version: %{title: "Corrected"})
    |> render_change()

    child |> element("[data-role='composer-save-drafts']") |> render_click()
    assert length(Repo.all(Post)) == 3
    assert Enum.all?(Repo.all(Post), &(&1.status == "draft"))
    refute Repo.exists?(Social.ApprovalCard)
  end

  for recovery <- [:review, :draft] do
    test "late media refusal preserves successes and retries only the remaining version via #{recovery}",
         ctx do
      {child, youtube, file} = three_versions(ctx, true)
      table = :ets.new(:composer_late_refusal, [:set, :public])
      handler = {__MODULE__, make_ref()}
      # Labelled injection: remove the selected file after the second real
      # post INSERT, after the pre-validation pass, before the third writer.
      :telemetry.attach(
        handler,
        [:platform, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "INSERT INTO \"social_posts\"") and
               :ets.update_counter(table, :inserts, {2, 1}, {:inserts, 0}) == 2 do
            Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
              set: [deleted_at: DateTime.utc_now()]
            )
          end
        end,
        nil
      )

      try do
        child |> element("[data-role='composer-send']") |> render_click()
      after
        :telemetry.detach(handler)
      end

      assert [{:inserts, 2}] = :ets.lookup(table, :inserts)
      :ets.delete(table)
      assert length(Repo.all(Post)) == 2

      assert has_element?(
               child,
               "#composer-column-#{youtube.id} [data-role='composer-review-error']",
               "media"
             )

      for account <- [ctx.a, ctx.d] do
        assert has_element?(
                 child,
                 "#composer-column-#{account.id} [data-role='composer-result']",
                 "Sent for review"
               )

        assert has_element?(
                 child,
                 "#composer-column-#{account.id} [data-role='composer-edit'][disabled]"
               )
      end

      assert has_element?(child, "[data-role='composer-send']", "Send 1 for approval")

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [deleted_at: nil]
      )

      case unquote(recovery) do
        :review -> child |> element("[data-role='composer-send']") |> render_click()
        :draft -> child |> element("[data-role='composer-save-drafts']") |> render_click()
      end

      posts = Repo.all(Post)

      assert Enum.sort(Enum.map(posts, & &1.account_id)) ==
               Enum.sort([ctx.a.id, ctx.d.id, youtube.id])

      assert Enum.uniq(Enum.map(posts, & &1.idea_id)) |> length() == 1
      yt = Enum.find(posts, &(&1.account_id == youtube.id))
      assert yt.status == if(unquote(recovery) == :review, do: "needs_approval", else: "draft")
      refute render(child) =~ "went out"
    end
  end
end
