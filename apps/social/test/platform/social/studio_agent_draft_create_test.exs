defmodule Platform.Social.StudioAgentDraftCreateTest do
  @moduledoc """
  `social_studio_draft_create` / `Studio.create_agent_draft/4`: an agent makes a
  Studio post in `draft` and nothing else. Every refusal leaves posts, events,
  receipts and request rows exactly as they were; a repeat of one request is
  the same draft; a reused request id with other content is a conflict.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDraftRequest, AgentDrafts, Ideas, Post, PostEvents, Studio}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    w = studio_world!()
    pic = stored_file!(w.project, "image bytes #{unique()}", "pic.png", "image/png")
    %{w: w, pic: pic}
  end

  defp ctx(w), do: %{agent_id: w.agent.id}

  defp tool(w, account, args, ctx \\ nil) do
    ToolArguments.dispatch(
      "social_studio_draft_create",
      Map.merge(
        %{"account_id" => account.id, "request_id" => "req-#{unique()}", "body" => "Hello"},
        args
      ),
      ctx || ctx(w)
    )
  end

  defp counts, do: {write_counts(), Repo.aggregate(AgentDraftRequest, :count)}

  defp refused(result, code) do
    assert {:error, %{code: ^code} = envelope} = result
    envelope
  end

  describe "what it creates" do
    test "a draft, version 1, by the agent, with no approval, plan, timer or send", %{
      w: w,
      pic: pic
    } do
      assert {:ok, %{post: post, replayed: false}} =
               tool(w, w.x, %{"body" => "Agent copy", "media_file_ids" => [pic.id]})

      row = Repo.get!(Post, post.id)

      assert {row.flow, row.status, row.version, row.body, row.media_file_ids} ==
               {"studio", "draft", 1, "Agent copy", [pic.id]}

      assert {row.scheduled_at, row.approved_by_user_id, row.publish_after, row.external_id} ==
               {nil, nil, nil, nil}

      assert actions(row) == ["created"]
      assert [%{actor_kind: "agent", actor_id: id}] = PostEvents.list_for_post(row.id)
      assert id == w.agent.id
      assert receipts(row) == []
      assert send_calls() == []
      assert PostEvents.created_by_agents([row.id]) == %{row.id => w.agent.id}
    end

    test "status draft is accepted; the post is the one Today lists", %{w: w} do
      assert {:ok, %{post: post}} = tool(w, w.x, %{"status" => "draft"})
      assert {:ok, [listed]} = Studio.list_posts(w.org_id, w.profile.id)
      assert listed.id == post.id
    end
  end

  describe "draft only" do
    test "every other status is refused, never changed", %{w: w} do
      before = counts()

      for status <-
            ~w(needs_approval approved planned scheduled published failed rejected) ++ [""] do
        envelope = refused(tool(w, w.x, %{"status" => status}), :status_not_allowed)
        assert envelope.error =~ "draft and nothing else"
      end

      assert counts() == before
    end

    test "any other field is refused and named, including every approval and plan field", %{w: w} do
      before = counts()

      for key <- ~w(scheduled_at approved_by_user_id approved_at task_id cover_file_id flow
                    version state_rev platform_options generated_by_agent_id is_aigc profile_id) do
        envelope = refused(tool(w, w.x, %{key => "x"}), :field_not_allowed)
        assert envelope.error =~ key
      end

      assert counts() == before
    end

    test "the tool cannot be told to submit, and no approval card or timer exists afterwards", %{
      w: w
    } do
      {:ok, %{post: post}} = tool(w, w.x, %{})
      assert Repo.get!(Post, post.id).status == "draft"
      assert Repo.all(from(e in Platform.Social.PostEvent, where: e.action == "submitted")) == []
      assert Repo.aggregate(Platform.Social.PostApproval, :count) == 0
      assert send_calls() == []
    end
  end

  describe "refusals write nothing" do
    test "request_id is required: blank, not a string, too long, or absent", %{w: w} do
      before = counts()

      for bad <- [5, String.duplicate("a", 201)] do
        args = %{"account_id" => w.x.id, "body" => "Hello", "request_id" => bad}

        refused(
          ToolArguments.dispatch("social_studio_draft_create", args, ctx(w)),
          :request_id_required
        )
      end

      # Absent or blank: the transport refuses a missing required argument
      # first; the context function refuses both too.
      for blank <- ["", "   "] do
        args = %{"account_id" => w.x.id, "body" => "Hello", "request_id" => blank}

        refused(
          ToolArguments.dispatch("social_studio_draft_create", args, ctx(w)),
          :missing_request_id
        )

        assert {:error, :request_id_required} =
                 Studio.create_agent_draft(w.scope, w.x.id, w.agent.id, %{
                   "body" => "Hello",
                   "request_id" => blank
                 })
      end

      args = %{"account_id" => w.x.id, "body" => "Hello"}

      refused(
        ToolArguments.dispatch("social_studio_draft_create", args, ctx(w)),
        :missing_request_id
      )

      assert {:error, :request_id_required} =
               Studio.create_agent_draft(w.scope, w.x.id, w.agent.id, %{"body" => "Hello"})

      assert counts() == before
    end

    test "a missing or blank body is refused", %{w: w} do
      before = counts()
      refused(tool(w, w.x, %{"body" => ""}), :missing_body)

      assert {:error, %Ecto.Changeset{}} =
               Studio.create_agent_draft(w.scope, w.x.id, w.agent.id, %{
                 "body" => "",
                 "request_id" => "r"
               })

      refused(tool(w, w.x, %{"body" => nil}), :missing_body)
      assert counts() == before
    end

    test "Studio switched off", %{w: w} do
      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      before = counts()
      refused(tool(w, w.x, %{}), :studio_disabled)
      assert counts() == before
    end

    test "no access: another org's agent, and an account that is not there", %{w: w} do
      before = counts()
      other = %{agent_id: pinned_agent!(w.other_org_id).id}
      refused(tool(w, w.x, %{}, other), :not_found)
      refused(tool(w, %{id: Ecto.UUID.generate()}, %{}), :not_found)
      refused(tool(w, %{id: "not-a-uuid"}, %{}), :not_found)
      assert counts() == before
    end

    test "the legacy agent path refuses the same other-org agent (parity)", %{w: w} do
      other = pinned_agent!(w.other_org_id)

      assert {:error, :not_found} =
               AgentDrafts.create_agent_drafts(
                 {:tenant, w.other_org_id},
                 w.profile.id,
                 %{
                   "account_ids" => [w.x.id],
                   "body" => "x",
                   "status" => "draft"
                 },
                 agent_id: other.id
               )

      refused(tool(w, w.x, %{}, %{agent_id: other.id}), :not_found)
    end

    test "archived account", %{w: w} do
      {:ok, _} = Social.archive_account(w.org_id, w.x)
      before = counts()
      refused(tool(w, w.x, %{}), :account_archived)
      assert counts() == before
    end

    test "profile project archived or removed", %{w: w} do
      before = counts()
      {:ok, _} = Social.update_profile(w.org_id, w.profile, %{project_id: nil})
      refused(tool(w, w.x, %{}), :studio_needs_project)
      assert counts() == before
    end

    test "a banned phrase refuses the draft and names it", %{w: w} do
      {:ok, _} =
        Social.update_profile(w.org_id, w.profile, %{voice: %{banned: ["Game Changer"]}})

      before = counts()
      envelope = refused(tool(w, w.x, %{"body" => "a real game changer"}), :banned_phrase)
      assert envelope.error =~ "Game Changer"
      assert counts() == before
    end

    test "media: another org's file, another project's file, a missing and a deleted file all alike",
         %{w: w} do
      other_org_file =
        stored_file!(project!(w.other_org_id), "other org #{unique()}", "o.png", "image/png")

      other_project_file =
        stored_file!(project!(w.org_id), "other project #{unique()}", "p.png", "image/png")

      gone = stored_file!(w.project, "gone #{unique()}", "g.png", "image/png")
      {:ok, _} = Platform.Files.delete_file(%{id: w.approver.id}, gone)
      before = counts()

      for id <- [other_org_file.id, other_project_file.id, gone.id, Ecto.UUID.generate(), "nope"] do
        refused(tool(w, w.x, %{"media_file_ids" => [id]}), :file_not_in_project)
      end

      assert counts() == before
    end

    test "media: a file whose upload is not finished is not ready", %{w: w} do
      reserved =
        Repo.insert!(%Platform.Files.File{
          project_id: w.project.id,
          org_id: w.org_id,
          name: "pending.png",
          content_type: "image/png",
          byte_size: 10,
          storage_key: "reserved/#{unique()}",
          ingest_status: "pending"
        })

      refute Platform.Files.finalized_upload?(reserved)
      before = counts()
      refused(tool(w, w.x, %{"media_file_ids" => [reserved.id]}), :file_not_ready)
      assert counts() == before
    end

    test "media: more than twenty references", %{w: w, pic: pic} do
      refused(tool(w, w.x, %{"media_file_ids" => List.duplicate(pic.id, 21)}), :invalid_argument)
    end
  end

  describe "no idea linking in v1" do
    test "idea_id through the tool is refused, whatever it holds, and nothing is created", %{w: w} do
      {:ok, idea} =
        Ideas.create(w.scope, w.profile.id, %{"title" => "Idea"}, {:agent, w.agent.id})

      before = counts()

      for value <- [idea.id, Ecto.UUID.generate(), "nope", nil, ""] do
        envelope = refused(tool(w, w.x, %{"idea_id" => value}), :idea_not_supported)
        assert envelope.error =~ "not supported"
      end

      assert counts() == before
    end

    test "idea_id through the context function is refused too, string or atom key", %{w: w} do
      {:ok, idea} =
        Ideas.create(w.scope, w.profile.id, %{"title" => "Idea"}, {:agent, w.agent.id})

      before = counts()

      for attrs <- [
            %{"request_id" => "i1", "body" => "x", "idea_id" => idea.id},
            %{request_id: "i2", body: "x", idea_id: idea.id},
            %{"request_id" => "i3", "body" => "x", "idea_id" => nil}
          ] do
        assert {:error, :idea_not_supported} =
                 Studio.create_agent_draft(w.scope, w.x.id, w.agent.id, attrs)
      end

      assert counts() == before
    end

    test "no draft ever carries an idea", %{w: w} do
      {:ok, %{post: post}} = tool(w, w.x, %{})
      assert Repo.get!(Post, post.id).idea_id == nil
    end

    test "the idea lock helper is gone" do
      Code.ensure_loaded!(Ideas)
      assert function_exported?(Ideas, :create, 4)
      refute function_exported?(Ideas, :lock_for_link, 2)
    end
  end

  describe "retries" do
    test "the same request twice is one draft", %{w: w} do
      args = %{"request_id" => "once", "body" => "Same"}
      assert {:ok, %{post: first, replayed: false}} = tool(w, w.x, args)
      before = counts()
      assert {:ok, %{post: again, replayed: true}} = tool(w, w.x, args)
      assert again.id == first.id
      assert counts() == before
      assert Repo.aggregate(from(p in Post, where: p.flow == "studio"), :count) == 1
      assert actions(first.id) == ["created"]
    end

    test "a replay returns the draft as it is now, and does not undo a submit", %{w: w} do
      args = %{"request_id" => "submitted-meanwhile", "body" => "Same"}
      {:ok, %{post: first}} = tool(w, w.x, args)

      {:ok, _} =
        Studio.resubmit(w.org_id, first.id, w.approver.id, expect(Repo.get!(Post, first.id)))

      assert {:ok, %{post: again, replayed: true}} = tool(w, w.x, args)
      assert {again.id, again.status} == {first.id, "needs_approval"}
    end

    test "the same request id with different content is a conflict that touches nothing", %{
      w: w,
      pic: pic
    } do
      {:ok, %{post: first}} = tool(w, w.x, %{"request_id" => "r1", "body" => "Original"})
      before = {counts(), Repo.get!(Post, first.id)}

      for change <- [
            %{"body" => "Changed"},
            %{"media_file_ids" => [pic.id]},
            %{"link_url" => "https://example.com/x"}
          ] do
        refused(
          tool(w, w.x, Map.merge(%{"request_id" => "r1", "body" => "Original"}, change)),
          :request_id_conflict
        )
      end

      assert {counts(), Repo.get!(Post, first.id)} == before
    end

    test "the same request id on another authorised account is a separate draft, not a conflict",
         %{w: w} do
      {:ok, %{post: first}} = tool(w, w.x, %{"request_id" => "r1", "body" => "Original"})

      assert {:ok, %{post: second, replayed: false}} =
               tool(w, w.tiktok, %{"request_id" => "r1", "body" => "Original"})

      refute second.id == first.id
      assert Repo.get!(Post, first.id).account_id == w.x.id
      assert Repo.get!(Post, second.id).account_id == w.tiktok.id

      # Each account's own retry still returns its own draft.
      assert {:ok, %{post: again_x, replayed: true}} =
               tool(w, w.x, %{"request_id" => "r1", "body" => "Original"})

      assert {:ok, %{post: again_t, replayed: true}} =
               tool(w, w.tiktok, %{"request_id" => "r1", "body" => "Original"})

      assert {again_x.id, again_t.id} == {first.id, second.id}
    end

    test "the same request id on an account the agent may not use is refused and reveals nothing",
         %{w: w} do
      {:ok, %{post: first}} = tool(w, w.x, %{"request_id" => "r1", "body" => "Secret original"})

      {:ok, foreign_profile} = Social.create_profile(w.other_org_id, %{name: "Foreign show"})

      {:ok, foreign} =
        Social.create_account(w.other_org_id, foreign_profile, %{
          platform: "x",
          handle: "@foreign"
        })

      before = counts()

      for body <- ["Secret original", "Different"] do
        envelope = refused(tool(w, foreign, %{"request_id" => "r1", "body" => body}), :not_found)
        refute inspect(envelope) =~ first.id
        refute inspect(envelope) =~ "Secret original"
      end

      assert counts() == before
      assert Repo.get!(Post, first.id).account_id == w.x.id
    end

    test "another agent's request id is its own: never another agent's draft", %{w: w} do
      {:ok, %{post: mine}} = tool(w, w.x, %{"request_id" => "shared-id", "body" => "Mine"})
      other = %{agent_id: pinned_agent!(w.org_id).id}

      assert {:ok, %{post: theirs, replayed: false}} =
               tool(w, w.tiktok, %{"request_id" => "shared-id", "body" => "Theirs"}, other)

      refute theirs.id == mine.id
    end

    test "a retry is authorised again: access lost after the first call is refused, nothing revealed",
         %{w: w} do
      args = %{"request_id" => "lost-access", "body" => "Same"}
      {:ok, %{post: _}} = tool(w, w.x, args)
      before = counts()

      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      refused(tool(w, w.x, args), :studio_disabled)
      {:ok, _} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, true)

      {:ok, _} = Social.archive_account(w.org_id, w.x)
      refused(tool(w, w.x, args), :account_archived)

      moved = pinned_agent!(w.other_org_id)
      refused(tool(w, w.x, args, %{agent_id: moved.id}), :not_found)

      assert counts() == before
    end
  end
end
