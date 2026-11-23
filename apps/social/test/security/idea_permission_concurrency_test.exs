defmodule Platform.Social.IdeaPermissionConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Repo
  alias Platform.Social.{Idea, Profile}

  setup do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])
    root = Repo.one!(from(o in Platform.Tenancy.Org, where: is_nil(o.parent_org_id), limit: 1))

    org =
      Repo.insert!(%Platform.Tenancy.Org{
        name: "Ideas race #{n}",
        slug: "ideas-race-#{n}",
        parent_org_id: root.id
      })

    owner =
      Repo.insert!(%Platform.Accounts.User{
        name: "Ideas race",
        email: "ideas-race-#{n}@example.com",
        oidc_sub: "ideas-race-#{n}"
      })

    Repo.insert!(%Platform.Tenancy.OrgMembership{
      org_id: org.id,
      user_id: owner.id,
      role: "member"
    })

    {:ok, project} = Platform.Tasks.create_project(%{name: "Ideas race #{n}", org_id: org.id})

    {:ok, profile} =
      Platform.Social.create_profile(org.id, %{
        name: "Ideas race",
        project_id: project.id,
        approver_user_ids: [owner.id]
      })

    {:ok, account} =
      Platform.Social.create_account(org.id, profile, %{platform: "x", handle: "@ideas-race-#{n}"})

    agent =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "ideas-race-#{n}",
        name: "Ideas race",
        metadata: %{"org_id" => org.id}
      })

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "ideas-race-#{n}",
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social"], %{
        "social.ideas" => "all"
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      steps = [
        fn ->
          Repo.delete_all(
            from(c in Platform.Federation.ToolCallRecord,
              where: c.runtime_id == ^runtime.runtime_id
            )
          )
        end,
        fn ->
          Repo.delete_all(from(g in Platform.Access.Grant, where: g.principal_id == ^owner.id))
        end,
        fn ->
          post_ids =
            Repo.all(
              from(p in Platform.Social.Post, where: p.account_id == ^account.id, select: p.id)
            )

          Repo.delete_all(from(e in Platform.Social.PostEvent, where: e.post_id in ^post_ids))
        end,
        fn ->
          Repo.delete_all(from(p in Platform.Social.Post, where: p.account_id == ^account.id))
        end,
        fn -> Repo.delete_all(from(a in Platform.Social.Account, where: a.id == ^account.id)) end,
        fn -> Repo.delete_all(from(i in Idea, where: i.profile_id == ^profile.id)) end,
        fn ->
          Repo.update_all(from(c in Platform.Social.Clip, where: c.profile_id == ^profile.id),
            set: [reviewed_render_id: nil]
          )
        end,
        fn ->
          clip_ids =
            Repo.all(
              from(c in Platform.Social.Clip, where: c.profile_id == ^profile.id, select: c.id)
            )

          Repo.delete_all(from(r in Platform.Social.ClipRender, where: r.clip_id in ^clip_ids))
        end,
        fn ->
          Repo.delete_all(from(c in Platform.Social.Clip, where: c.profile_id == ^profile.id))
        end,
        fn ->
          Repo.delete_all(from(f in Platform.Files.File, where: f.project_id == ^project.id))
        end,
        fn -> Repo.delete_all(from(p in Profile, where: p.id == ^profile.id)) end,
        fn ->
          Repo.delete_all(
            from(p in Platform.Access.RuntimeProfile, where: p.runtime_id == ^runtime.id)
          )
        end,
        fn ->
          Repo.delete_all(from(r in Platform.Agents.AgentRuntime, where: r.id == ^runtime.id))
        end,
        fn -> Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id)) end,
        fn -> Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^project.id)) end,
        fn ->
          Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.org_id == ^org.id))
        end,
        fn -> Repo.delete_all(from(u in Platform.Accounts.User, where: u.id == ^owner.id)) end,
        fn -> Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^org.id)) end
      ]

      errors =
        Enum.flat_map(steps, fn step ->
          try do
            step.()
            []
          rescue
            error -> [error]
          end
        end)

      Sandbox.mode(Repo, :manual)
      if errors != [], do: raise(hd(errors))
    end)

    %{
      org: org,
      owner: owner,
      project: project,
      profile: profile,
      account: account,
      runtime: runtime
    }
  end

  test "a project deny committed while create waits is seen by the inner authorization", ctx do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(p in Profile, where: p.id == ^ctx.profile.id, lock: "FOR UPDATE"))
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})

          Platform.Federation.ToolCall.invoke(
            "social_idea_create",
            %{"profile_id" => ctx.profile.id, "title" => "Must not be written"},
            ctx.runtime
          )
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid), "worker did not wait on this test's profile lock"

    assert {:ok, _} =
             Platform.Access.Grants.deny(%{
               principal: {:user, ctx.owner.id},
               permission: "social.use",
               resource: {:project, ctx.project.id}
             })

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, %{code: :not_found}} = Task.await(worker, 10_000)
    assert Repo.aggregate(from(i in Idea, where: i.profile_id == ^ctx.profile.id), :count) == 0
  end

  for tool <- ~w(social_idea_note_add social_idea_vote social_idea_unvote social_idea_archive) do
    @board_tool tool
    test "a project deny committed while #{@board_tool} waits is seen under the locks", ctx do
      {:ok, idea} =
        Platform.Social.Ideas.create(
          ctx.org.id,
          ctx.profile.id,
          %{title: "Existing idea"},
          {:agent, ctx.runtime.agent_id},
          broadcast: false
        )

      parent = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(p in Profile, where: p.id == ^ctx.profile.id, lock: "FOR UPDATE"))
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:holder, pid})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:holder, holder_pid}, 5_000

      worker =
        Task.async(fn ->
          Repo.checkout(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:worker, pid})

            Platform.Federation.ToolCall.invoke(
              @board_tool,
              %{"idea_id" => idea.id, "body" => "Must not be written"},
              ctx.runtime
            )
          end)
        end)

      assert_receive {:worker, worker_pid}, 5_000

      assert blocked_by?(worker_pid, holder_pid),
             "worker did not wait on this test's profile lock"

      assert {:ok, _} =
               Platform.Access.Grants.deny(%{
                 principal: {:user, ctx.owner.id},
                 permission: "social.use",
                 resource: {:project, ctx.project.id}
               })

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert {:error, %{code: :not_found}} = Task.await(worker, 10_000)
      assert is_nil(Repo.get!(Idea, idea.id).archived_at)

      assert Repo.aggregate(
               from(n in Platform.Social.IdeaNote, where: n.idea_id == ^idea.id),
               :count
             ) == 0

      assert Repo.aggregate(
               from(v in Platform.Social.IdeaVote, where: v.idea_id == ^idea.id),
               :count
             ) == 0
    end
  end

  test "ideas-only archive wins against a concurrent Composer post link", ctx do
    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        ctx.profile.id,
        %{title: "Archive first"},
        {:agent, ctx.runtime.agent_id},
        broadcast: false
      )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %{archived: true}} =
                   Platform.Federation.ToolCall.invoke(
                     "social_idea_archive",
                     %{"idea_id" => idea.id},
                     ctx.runtime
                   )

          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})

          Platform.Social.create_post(ctx.org.id, ctx.account, %{body: "Must not link"},
            idea_id: idea.id
          )
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :idea_archived} = Task.await(worker, 10_000)

    assert Repo.aggregate(from(p in Platform.Social.Post, where: p.idea_id == ^idea.id), :count) ==
             0
  end

  test "a concurrent Composer link makes ideas-only archive refuse", ctx do
    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        ctx.profile.id,
        %{title: "Link first"},
        {:agent, ctx.runtime.agent_id},
        broadcast: false
      )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, post} =
                   Platform.Social.create_post(ctx.org.id, ctx.account, %{body: "Linked"},
                     idea_id: idea.id
                   )

          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid, post.id})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid, post_id}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})

          Platform.Federation.ToolCall.invoke(
            "social_idea_archive",
            %{"idea_id" => idea.id},
            ctx.runtime
          )
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, %{code: :idea_has_posts}} = Task.await(worker, 10_000)
    assert Repo.get!(Platform.Social.Post, post_id).idea_id == idea.id
    assert is_nil(Repo.get!(Idea, idea.id).archived_at)
  end

  test "ideas-only archive wins against concurrent clip approval", ctx do
    {clip, render, idea} = clip_idea!(ctx)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %{archived: true}} =
                   Platform.Federation.ToolCall.invoke(
                     "social_idea_archive",
                     %{"idea_id" => idea.id},
                     ctx.runtime
                   )

          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})
          draft_clip_for(ctx, clip, render, parent)
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :idea_archived} = Task.await(worker, 10_000)

    assert Repo.aggregate(from(p in Platform.Social.Post, where: p.idea_id == ^idea.id), :count) ==
             0

    assert Repo.get!(Platform.Social.Clip, clip.id).review_status == "pending"
  end

  test "ideas-only archive wins against a concurrent agent draft link", ctx do
    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        ctx.profile.id,
        %{title: "Archive before agent draft"},
        {:agent, ctx.runtime.agent_id},
        broadcast: false
      )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %{archived: true}} =
                   Platform.Federation.ToolCall.invoke(
                     "social_idea_archive",
                     %{"idea_id" => idea.id},
                     ctx.runtime
                   )

          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})
          agent_draft(ctx, idea)
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, :idea_archived} = Task.await(worker, 10_000)

    assert Repo.aggregate(from(p in Platform.Social.Post, where: p.idea_id == ^idea.id), :count) ==
             0
  end

  test "a concurrent agent draft link makes ideas-only archive refuse", ctx do
    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        ctx.profile.id,
        %{title: "Agent draft first"},
        {:agent, ctx.runtime.agent_id},
        broadcast: false
      )

    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, _} = agent_draft(ctx, idea)
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})

          Platform.Federation.ToolCall.invoke(
            "social_idea_archive",
            %{"idea_id" => idea.id},
            ctx.runtime
          )
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, %{code: :idea_has_posts}} = Task.await(worker, 10_000)

    assert Repo.aggregate(from(p in Platform.Social.Post, where: p.idea_id == ^idea.id), :count) ==
             1

    assert is_nil(Repo.get!(Idea, idea.id).archived_at)
  end

  defp agent_draft(ctx, idea) do
    Platform.Social.AgentDrafts.create_agent_drafts(
      ctx.org.id,
      ctx.profile.id,
      %{
        "account_ids" => [ctx.account.id],
        "idea_id" => idea.id,
        "status" => "draft",
        "body" => "Agent draft"
      },
      agent_id: ctx.runtime.agent_id
    )
  end

  test "concurrent clip approval makes ideas-only archive refuse", ctx do
    {clip, render, idea} = clip_idea!(ctx)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %{posts: [post]}} = draft_clip_for(ctx, clip, render, parent)
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:holder, pid, post.id})

          receive do
            :release -> :ok
          after
            10_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:holder, holder_pid, post_id}, 5_000

    worker =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:worker, pid})

          Platform.Federation.ToolCall.invoke(
            "social_idea_archive",
            %{"idea_id" => idea.id},
            ctx.runtime
          )
        end)
      end)

    assert_receive {:worker, worker_pid}, 5_000
    assert blocked_by?(worker_pid, holder_pid)
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert {:error, %{code: :idea_has_posts}} = Task.await(worker, 10_000)
    assert Repo.get!(Platform.Social.Post, post_id).idea_id == idea.id
    assert is_nil(Repo.get!(Idea, idea.id).archived_at)
  end

  # A synthetic file row suffices: approval checks its live project and does
  # not read bytes. The schedule cast goes to the test process, never a publisher.
  defp clip_idea!(ctx) do
    n = System.unique_integer([:positive])

    file =
      Repo.insert!(%Platform.Files.File{
        project_id: ctx.project.id,
        org_id: ctx.org.id,
        name: "clip",
        original_filename: "clip.mp4",
        content_type: "video/mp4",
        byte_size: 10,
        storage_key: "idea-race-#{n}",
        content_hash: String.duplicate("a", 63) <> Integer.to_string(rem(n, 10))
      })

    {:ok, clip} =
      Platform.Social.AgentDrafts.submit_clip(
        {:tenant, ctx.org.id},
        ctx.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Clip",
          "caption" => "Caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        ctx.runtime.agent_id
      )

    render = Repo.one!(from(r in Platform.Social.ClipRender, where: r.clip_id == ^clip.id))

    {:ok, idea} =
      Platform.Social.Ideas.create(
        ctx.org.id,
        ctx.profile.id,
        %{title: "Clip idea", source_kind: "clip", clip_id: clip.id},
        {:agent, ctx.runtime.agent_id},
        broadcast: false
      )

    {clip, render, idea}
  end

  defp draft_clip_for(ctx, clip, render, test_process) do
    Platform.Social.draft_clip(
      ctx.org.id,
      clip.id,
      ctx.owner.id,
      %{"render_id" => render.id, "account_ids" => [ctx.account.id]},
      now: DateTime.utc_now(),
      publish_server: test_process
    )
  end

  defp blocked_by?(worker_pid, holder_pid, tries \\ 100) do
    %{rows: [[blocked]]} =
      Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [holder_pid, worker_pid])

    cond do
      blocked -> true
      tries == 0 -> false
      true -> Process.sleep(50) && blocked_by?(worker_pid, holder_pid, tries - 1)
    end
  end
end
