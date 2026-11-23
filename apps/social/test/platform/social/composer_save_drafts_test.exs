defmodule Platform.Social.ComposerSaveDraftsTest do
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialApprovalFixtures
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Composer, Idea, Post, PostEvent}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture() |> with_ideas_runtime()
    Map.put(ctx, :idea, %{title: "A draft idea"})
  end

  test "saves incomplete drafts without cards, submitted events or publishing", ctx do
    messages_before = Repo.aggregate(Platform.Chat.Message, :count)
    inbox_before = Repo.aggregate(Platform.Inbox.Item, :count)

    compose = %{
      idea: ctx.idea,
      drafts: [%{account_id: ctx.a.id, text: ""}, %{account_id: ctx.d.id, text: "Ready later"}]
    }

    assert {:ok, %{idea: idea, posts: [first, second]}} =
             Composer.save_drafts(ctx.profile, ctx.h1.id, compose)

    assert Enum.all?([first, second], &(&1.status == "draft" and &1.idea_id == idea.id))
    assert is_nil(first.scheduled_at)
    refute Repo.exists?(ApprovalCard)
    assert Repo.aggregate(from(e in PostEvent, where: e.action == "submitted"), :count) == 0
    assert Repo.aggregate(from(e in PostEvent, where: e.action == "created"), :count) == 2
    assert Repo.aggregate(Platform.Chat.Message, :count) == messages_before
    assert Repo.aggregate(Platform.Inbox.Item, :count) == inbox_before
    assert Fake.calls() == []
  end

  test "refuses an outsider, an agent and an account from another profile without writes", ctx do
    outsider = user!()
    draft = %{account_id: ctx.a.id, text: "Private"}

    assert {:error, :approver_no_access} =
             Composer.save_drafts(ctx.profile, outsider.id, %{idea: ctx.idea, drafts: [draft]})

    assert {:error, :not_a_human} =
             Composer.save_drafts(ctx.profile, ctx.g.id, %{idea: ctx.idea, drafts: [draft]})

    {:ok, other_profile} = Social.create_profile(ctx.org_id, %{name: "Other"})

    {:ok, other_account} =
      Social.create_account(ctx.org_id, other_profile, %{platform: "x", handle: "@other"})

    assert {:error, {:no_account, _}} =
             Composer.save_drafts(ctx.profile, ctx.h1.id, %{
               idea: ctx.idea,
               drafts: [draft, %{account_id: other_account.id, text: "Foreign"}]
             })

    assert Repo.all(Post) == []
    assert Repo.all(Idea) == []
    assert Fake.calls() == []
  end

  test "a later field validation failure rolls back every draft and the new idea", ctx do
    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "@show"})

    compose = %{
      idea: ctx.idea,
      drafts: [
        %{account_id: ctx.a.id, text: "First"},
        %{account_id: youtube.id, text: "Second", title: String.duplicate("x", 101)}
      ]
    }

    assert {:error, _} = Composer.save_drafts(ctx.profile, ctx.h1.id, compose)
    assert Repo.all(Post) == []
    assert Repo.all(Idea) == []
    assert Repo.all(PostEvent) == []
    assert Fake.calls() == []
  end

  test "invalid or other-project media is refused before any draft is written", ctx do
    other_project = project!(ctx.org_id)

    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: other_project.id,
        name: "foreign.png",
        original_filename: "foreign.png",
        content_type: "image/png",
        byte_size: 1,
        storage_key: "files/#{other_project.id}/foreign.png",
        content_hash: String.duplicate("f", 64)
      })

    for ids <- [[file.id], ["bad-id"], nil, "bad"] do
      compose = %{
        idea: ctx.idea,
        drafts: [%{account_id: ctx.a.id, text: "Keep", media_file_ids: ids}]
      }

      assert {:error, :invalid_media} = Composer.save_drafts(ctx.profile, ctx.h1.id, compose)
    end

    assert Repo.all(Post) == []
    assert Repo.all(Idea) == []
  end

  test "a YouTube draft may omit its title and media", ctx do
    {:ok, youtube} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "@incomplete"})

    compose = %{idea: ctx.idea, drafts: [%{account_id: youtube.id, text: "", title: nil}]}
    assert {:ok, %{posts: [post]}} = Composer.save_drafts(ctx.profile, ctx.h1.id, compose)
    assert post.status == "draft"
    assert post.media_file_ids == []
    assert (post.platform_options || %{})["title"] == nil
  end

  for reason <- [:denied, :other_project] do
    test "direct review refuses #{reason} file access before any writes", ctx do
      project =
        if unquote(reason) == :other_project,
          do: project!(ctx.org_id),
          else: %{id: ctx.profile.project_id}

      {:ok, file} =
        Platform.Files.create_file(%{
          project_id: project.id,
          name: "review.png",
          original_filename: "review.png",
          content_type: "image/png",
          byte_size: 1,
          content_hash: String.duplicate("c", 64),
          storage_key: "files/#{project.id}/#{unique()}/review.png"
        })

      if unquote(reason) == :denied do
        assert :ok ==
                 Platform.Access.check(
                   Platform.Access.Scope.for_user(ctx.h1),
                   "files.read",
                   {:project, project.id}
                 )

        {:ok, _} =
          Platform.Access.Grants.deny(%{
            principal: {:user, ctx.h1.id},
            permission: "files.read",
            resource: {:project, project.id}
          })
      end

      assert {:error, :invalid_media} =
               Composer.send(ctx.profile, ctx.h1.id, %{
                 idea: ctx.idea,
                 drafts: [
                   %{
                     account_id: ctx.a.id,
                     text: "Ready",
                     media_file_ids: [file.id],
                     scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
                   }
                 ]
               })

      assert Repo.all(Post) == []
      assert Repo.all(Idea) == []
      assert Repo.all(PostEvent) == []
      assert Repo.all(ApprovalCard) == []
      assert Fake.calls() == []
    end
  end

  test "unreadable incomplete media yields only access refusal before detailed validation", ctx do
    project_id = ctx.profile.project_id

    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: project_id,
        name: "unfinished.png",
        original_filename: "unfinished.png",
        content_type: "image/png",
        byte_size: 1,
        content_hash: String.duplicate("e", 64),
        storage_key: "files/#{project_id}/#{unique()}/unfinished.png"
      })

    Repo.update!(Ecto.Changeset.change(file, content_hash: nil, ingest_status: "pending"))

    {:ok, _} =
      Platform.Access.Grants.deny(%{
        principal: {:user, ctx.h1.id},
        permission: "files.read",
        resource: {:project, project_id}
      })

    assert {:error, :invalid_media} =
             Composer.send(ctx.profile, ctx.h1.id, %{
               idea: ctx.idea,
               drafts: [
                 %{
                   account_id: ctx.a.id,
                   text: "",
                   media_file_ids: [file.id],
                   scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
                 }
               ]
             })

    assert Repo.all(Post) == []
    assert Repo.all(Idea) == []
    assert Repo.all(PostEvent) == []
    assert Repo.all(ApprovalCard) == []
    assert Fake.calls() == []
  end

  test "direct review accepts a readable brand-project file", ctx do
    project_id = ctx.profile.project_id

    {:ok, file} =
      Platform.Files.create_file(%{
        project_id: project_id,
        name: "readable.png",
        original_filename: "readable.png",
        content_type: "image/png",
        byte_size: 1,
        content_hash: String.duplicate("d", 64),
        storage_key: "files/#{project_id}/#{unique()}/readable.png"
      })

    assert {:ok, %{posts: [post]}} =
             Composer.send(ctx.profile, ctx.h1.id, %{
               idea: ctx.idea,
               drafts: [
                 %{
                   account_id: ctx.a.id,
                   text: "Ready",
                   media_file_ids: [file.id],
                   scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
                 }
               ]
             })

    assert post.media_file_ids == [file.id]
    assert post.status == "needs_approval"
    assert Fake.calls() == []
  end

  test "by-hand review keeps its existing blank-text and past-time refusals", ctx do
    assert {:error, {:invalid_draft, _}} =
             Composer.send(ctx.profile, ctx.h1.id, %{
               idea: ctx.idea,
               drafts: [%{account_id: ctx.d.id, text: ""}]
             })

    assert {:error, :schedule_in_past} =
             Composer.send(ctx.profile, ctx.h1.id, %{
               idea: ctx.idea,
               drafts: [
                 %{
                   account_id: ctx.d.id,
                   text: "Copy",
                   scheduled_at: DateTime.add(DateTime.utc_now(), -60)
                 }
               ]
             })

    assert Repo.all(Post) == []
  end
end
