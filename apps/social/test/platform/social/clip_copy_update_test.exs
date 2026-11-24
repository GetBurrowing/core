defmodule Platform.Social.ClipCopyUpdateTest do
  @moduledoc """
  `social_clip_update_copy`: an agent edits ONLY `title` and `caption` of an
  existing clip that is still waiting in review. Through
  `ToolArguments.dispatch/3` (the door both transports use) unless a test
  names `AgentDrafts` directly. The editor's own rules apply (the details
  rail's `ClipReviewFeed.save_details/5`): title trimmed, never blank, at
  most 200; caption kept as given, null clears it, at most 2200.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    AgentDrafts,
    Clip,
    ClipDecisions,
    ClipRemoval,
    ClipReviewFeed,
    ClipRender,
    ClipVersions,
    Post
  }

  setup do
    w = render_world!()
    other = render_world!()
    file = stored_file!(w.project, "clip bytes #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => "Original title",
          "caption" => "Original caption",
          "duration_s" => 30.0,
          "width" => 1080,
          "height" => 1920
        },
        w.agent.id
      )

    # Authority: only the profile's configured drafting agent may edit copy.
    w = %{
      w
      | profile:
          w.profile |> Ecto.Changeset.change(drafting_agent_id: w.agent.id) |> Repo.update!()
    }

    %{w: w, other: other, clip: clip, ctx: %{agent_id: w.agent.id}}
  end

  # The caller's read token is what a real agent sends: the clip's CURRENT
  # copy_rev, unless the test names its own (or `:none`, to omit it).
  defp edit(ctx, clip_id, args) do
    args =
      case Map.fetch(args, "expected_copy_rev") do
        {:ok, :none} -> Map.delete(args, "expected_copy_rev")
        {:ok, _} -> args
        :error -> Map.put(args, "expected_copy_rev", current_rev(clip_id))
      end

    ToolArguments.dispatch("social_clip_update_copy", Map.put(args, "clip_id", clip_id), ctx)
  end

  defp current_rev(clip_id) do
    with {:ok, id} <- Ecto.UUID.cast(clip_id),
         %Clip{} = clip <- Repo.get(Clip, id) do
      ClipReviewFeed.copy_rev(clip)
    else
      _ -> "missing"
    end
  end

  defp reload(clip), do: Repo.get!(Clip, clip.id)

  # Everything the tool must never touch, as one comparable value.
  defp frozen(clip_id) do
    clip = Repo.get!(Clip, clip_id)

    clip
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :title,
      :caption,
      :updated_at,
      :profile,
      :render_file,
      :source_file,
      :transcript_file,
      :reviewed_by_user,
      :reviewed_render,
      :submitted_by_agent,
      :renders,
      :removed_by_user
    ])
    |> Map.put(
      :renders,
      Repo.all(from(r in ClipRender, where: r.clip_id == ^clip_id, order_by: r.rev))
    )
    |> Map.put(:posts, Repo.all(from(p in Post, where: p.clip_id == ^clip_id, order_by: p.id)))
  end

  describe "the copy it may change" do
    test "title only: caption kept, read-back carries id, title, caption, updated_at", %{
      ctx: ctx,
      clip: clip
    } do
      assert {:ok, %{clip: out}} = edit(ctx, clip.id, %{"title" => "  New title  "})
      assert Map.keys(out) |> Enum.sort() == [:caption, :copy_rev, :id, :title, :updated_at]
      assert out.copy_rev == ClipReviewFeed.copy_rev(reload(clip))
      assert %{id: id, title: "New title", caption: "Original caption"} = out
      assert id == clip.id
      assert is_binary(out.updated_at)
      assert {:ok, at, _} = DateTime.from_iso8601(out.updated_at)
      assert DateTime.compare(at, clip.updated_at) in [:gt, :eq]
      assert %{title: "New title", caption: "Original caption"} = reload(clip)
    end

    test "caption only: title kept", %{ctx: ctx, clip: clip} do
      assert {:ok, %{clip: %{title: "Original title", caption: "New caption"}}} =
               edit(ctx, clip.id, %{"caption" => "New caption"})

      assert %{title: "Original title", caption: "New caption"} = reload(clip)
    end

    test "both at once", %{ctx: ctx, clip: clip} do
      assert {:ok, %{clip: %{title: "T2", caption: "C2"}}} =
               edit(ctx, clip.id, %{"title" => "T2", "caption" => "C2"})

      assert %{title: "T2", caption: "C2"} = reload(clip)
    end

    test "an explicit null caption clears it, as the editor allows", %{ctx: ctx, clip: clip} do
      assert {:ok, %{clip: %{caption: nil, title: "Original title"}}} =
               edit(ctx, clip.id, %{"caption" => nil})

      assert %{caption: nil} = reload(clip)
    end

    test "an empty-string caption is kept as given (the editor does not trim it)", %{
      ctx: ctx,
      clip: clip
    } do
      assert {:ok, %{clip: %{caption: ""}}} = edit(ctx, clip.id, %{"caption" => ""})
    end

    test "limits are the editor's: 200-char title and 2200-char caption pass", %{
      ctx: ctx,
      clip: clip
    } do
      assert {:ok, _} =
               edit(ctx, clip.id, %{
                 "title" => String.duplicate("t", 200),
                 "caption" => String.duplicate("c", 2200)
               })
    end
  end

  describe "refusals write nothing" do
    setup %{clip: clip}, do: %{before: frozen(clip.id), copy: reload(clip)}

    defp assert_unchanged(ctx_map) do
      assert frozen(ctx_map.clip.id) == ctx_map.before
      assert %{title: t, caption: c, updated_at: u} = reload(ctx_map.clip)
      assert {t, c, u} == {ctx_map.copy.title, ctx_map.copy.caption, ctx_map.copy.updated_at}
    end

    test "an explicit null or blank title is refused (a clip needs a title)", c do
      for bad <- [nil, "", "   "] do
        assert {:error, %{code: :invalid_argument}} = edit(c.ctx, c.clip.id, %{"title" => bad})
      end

      assert_unchanged(c)
    end

    test "a non-string title or caption is refused", c do
      assert {:error, %{code: :invalid_argument}} = edit(c.ctx, c.clip.id, %{"title" => 5})
      assert {:error, %{code: :invalid_argument}} = edit(c.ctx, c.clip.id, %{"caption" => 5})
      assert_unchanged(c)
    end

    test "a too-long title or caption is refused, and a valid sibling is not applied", c do
      assert {:error, %{code: :invalid_argument}} =
               edit(c.ctx, c.clip.id, %{"title" => String.duplicate("t", 201)})

      assert {:error, %{code: :invalid_argument}} =
               edit(c.ctx, c.clip.id, %{"caption" => String.duplicate("c", 2201)})

      assert {:error, %{code: :invalid_argument}} =
               edit(c.ctx, c.clip.id, %{
                 "title" => "ok",
                 "caption" => String.duplicate("c", 2201)
               })

      assert_unchanged(c)
    end

    test "naming neither field is refused", c do
      assert {:error, %{code: :invalid_argument}} = edit(c.ctx, c.clip.id, %{})
      assert_unchanged(c)
    end

    test "no other field is ever written: the tool ignores them, the context refuses them", c do
      # Alone, an unknown key leaves nothing to update.
      for key <- ~w(review_status render_file_id rev status platforms speaker flow) do
        assert {:error, %{code: :invalid_argument}} = edit(c.ctx, c.clip.id, %{key => "x"})
      end

      assert_unchanged(c)

      # Beside a title, the title lands and the rest is dropped, as for social_clip_submit.
      assert {:ok, _} =
               edit(c.ctx, c.clip.id, %{
                 "title" => "Only this",
                 "review_status" => "approved",
                 "rev" => 9,
                 "render_file_id" => Ecto.UUID.generate()
               })

      after_ = frozen(c.clip.id)
      assert after_ == c.before
      assert %{title: "Only this"} = reload(c.clip)

      # The context function itself refuses, never drops.
      assert {:error, :field_not_allowed, ["review_status"]} =
               AgentDrafts.update_clip_copy(
                 c.w.scope,
                 c.clip.id,
                 %{"title" => "x", "review_status" => "approved"},
                 agent_id: c.w.agent.id,
                 expected_copy_rev: current_rev(c.clip.id)
               )

      assert %{title: "Only this"} = reload(c.clip)
    end

    test "another org's clip reads exactly like a missing id", c do
      assert {:error, %{code: :not_found} = missing} =
               edit(c.ctx, Ecto.UUID.generate(), %{"title" => "x"})

      outsider = %{agent_id: c.other.agent.id}
      assert edit(outsider, c.clip.id, %{"title" => "x"}) == {:error, missing}
      assert edit(outsider, "not-a-uuid", %{"title" => "x"}) == {:error, missing}
      assert_unchanged(c)
    end

    test "a removed clip reads as not found", c do
      Repo.update_all(from(x in Clip, where: x.id == ^c.clip.id),
        set: [removed_at: DateTime.utc_now()]
      )

      before = Repo.get!(Clip, c.clip.id)
      assert {:error, %{code: :not_found}} = edit(c.ctx, c.clip.id, %{"title" => "x"})
      assert Repo.get!(Clip, c.clip.id) == before
    end

    test "approved, rejected, candidate, rendering and failed clips are refused", c do
      for {changes, label} <- [
            {[
               review_status: "approved",
               reviewed_by_user_id: c.w.approver.id,
               reviewed_at: DateTime.utc_now()
             ], "approved"},
            {[
               review_status: "rejected",
               review_note: "no",
               reviewed_by_user_id: c.w.approver.id,
               reviewed_at: DateTime.utc_now()
             ], "rejected"},
            {[review_status: nil, status: "candidate"], "candidate"},
            {[status: "rendering"], "rendering"},
            {[status: "failed"], "failed"}
          ] do
        Repo.update_all(from(x in Clip, where: x.id == ^c.clip.id), set: changes)
        snapshot = Repo.get!(Clip, c.clip.id)

        assert {:error, %{code: :clip_not_editable}} =
                 edit(c.ctx, c.clip.id, %{"title" => "x"}),
               "#{label} must be refused"

        assert Repo.get!(Clip, c.clip.id) == snapshot

        Repo.update_all(from(x in Clip, where: x.id == ^c.clip.id),
          set: [
            review_status: "pending",
            status: "rendered",
            review_note: nil,
            reviewed_by_user_id: nil,
            reviewed_at: nil
          ]
        )
      end
    end

    test "a Studio-flow clip is refused", c do
      Repo.update_all(from(x in Clip, where: x.id == ^c.clip.id), set: [flow: "studio"])
      assert {:error, %{code: :clip_not_editable}} = edit(c.ctx, c.clip.id, %{"title" => "x"})
      assert %{title: "Original title"} = reload(c.clip)
    end
  end

  describe "nothing but title and caption changes" do
    test "review, render, media, versions and every post with this clip_id stay byte-identical",
         %{w: w, ctx: ctx, clip: clip} do
      # A drafted clip that went back to review (a new render resets it to
      # pending) still has its old posts.
      {:ok, %{posts: [_ | _]}} =
        ClipDecisions.draft_clip(w.org_id, clip.id, w.approver.id, %{
          "copy_rev" => clip_copy_rev!(clip),
          "render_id" => render_id!(clip),
          "account_ids" => [w.tiktok.id, w.x.id]
        })

      {:ok, _} =
        Repo.get!(Clip, clip.id)
        |> Clip.review_changeset(:reset_pending)
        |> Repo.update()

      before = frozen(clip.id)
      assert [_, _] = before.posts
      posts_before = Enum.map(before.posts, &Map.from_struct/1)

      assert {:ok, _} = edit(ctx, clip.id, %{"title" => "Changed", "caption" => "Changed too"})

      after_ = frozen(clip.id)
      assert after_ == before
      assert Enum.map(after_.posts, &Map.from_struct/1) == posts_before
      # Bodies were copied at draft time, not read live from the clip.
      assert Enum.all?(after_.posts, &(&1.body == "Original caption"))
      assert [%{headline: "Original title", caption: "Original caption"}] = after_.renders
    end

    test "approval fingerprints of the clip's posts do not move", %{w: w, ctx: ctx, clip: clip} do
      {:ok, %{posts: posts}} =
        ClipDecisions.draft_clip(w.org_id, clip.id, w.approver.id, %{
          "copy_rev" => clip_copy_rev!(clip),
          "render_id" => render_id!(clip),
          "account_ids" => [w.tiktok.id]
        })

      fps = fn ->
        Enum.map(posts, fn p ->
          post = Repo.get!(Post, p.id)
          {Social.Approvals.fingerprint(post), Social.Approvals.content_fingerprint(post)}
        end)
      end

      before = fps.()
      Repo.get!(Clip, clip.id) |> Clip.review_changeset(:reset_pending) |> Repo.update!()
      assert {:ok, _} = edit(ctx, clip.id, %{"caption" => "Different"})
      assert fps.() == before
    end
  end

  describe "events" do
    test "it broadcasts the clip once, as the editor does, and publishes nothing", %{
      w: w,
      ctx: ctx,
      clip: clip
    } do
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(w.profile.id))
      Social.Publisher.Fake.reset()

      assert {:ok, _} = edit(ctx, clip.id, %{"title" => "Broadcast me"})

      assert_receive {:social_clip, %Clip{id: id, title: "Broadcast me"}}
      assert id == clip.id
      refute_receive {:social_clip, _}, 50
      assert Social.Publisher.Fake.calls(:publish) == []
    end

    test "a refusal broadcasts nothing", %{w: w, ctx: ctx, clip: clip} do
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(w.profile.id))
      assert {:error, _} = edit(ctx, clip.id, %{"title" => ""})
      refute_receive {:social_clip, _}, 50
    end
  end

  describe "authority: only the profile's configured drafting agent" do
    setup %{clip: clip}, do: %{before: frozen(clip.id), copy: reload(clip)}

    test "another active agent of the same org is refused, writes nothing, broadcasts nothing",
         c do
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(c.w.profile.id))
      intruder = pinned_agent!(c.w.org_id)

      assert {:error, %{code: :not_drafting_agent, recoverable: false}} =
               edit(%{agent_id: intruder.id}, c.clip.id, %{"title" => "Hijack"})

      assert_unchanged(c)
      refute_receive {:social_clip, _}, 50
    end

    test "a profile with no drafting agent refuses everyone", c do
      c.w.profile |> Ecto.Changeset.change(drafting_agent_id: nil) |> Repo.update!()

      assert {:error, %{code: :not_drafting_agent}} =
               edit(c.ctx, c.clip.id, %{"title" => "x"})

      assert_unchanged(c)
    end

    test "naming no caller at the context is refused, never org-wide", c do
      assert {:error, :not_drafting_agent} =
               AgentDrafts.update_clip_copy(c.w.scope, c.clip.id, %{"title" => "x"},
                 expected_copy_rev: current_rev(c.clip.id)
               )

      assert {:error, :not_drafting_agent} =
               AgentDrafts.update_clip_copy(c.w.scope, c.clip.id, %{"title" => "x"},
                 agent_id: nil,
                 expected_copy_rev: current_rev(c.clip.id)
               )

      assert_unchanged(c)
    end

    test "reassigning the drafting agent moves the authority with it", c do
      new_agent = pinned_agent!(c.w.org_id)
      c.w.profile |> Ecto.Changeset.change(drafting_agent_id: new_agent.id) |> Repo.update!()

      assert {:error, %{code: :not_drafting_agent}} = edit(c.ctx, c.clip.id, %{"title" => "old"})
      assert {:ok, _} = edit(%{agent_id: new_agent.id}, c.clip.id, %{"title" => "new"})
      assert %{title: "new"} = reload(c.clip)
    end

    test "the configured agent being inactive is refused", c do
      Repo.update_all(from(a in Platform.Agents.Agent, where: a.id == ^c.w.agent.id),
        set: [status: "archived"]
      )

      assert {:error, _} = edit(c.ctx, c.clip.id, %{"title" => "x"})
      assert_unchanged(c)
    end

    test "authority is decided before the clip is looked at: no clip state leaks", c do
      intruder = pinned_agent!(c.w.org_id)

      Repo.update_all(from(x in Clip, where: x.id == ^c.clip.id),
        set: [status: "rendering"]
      )

      assert {:error, %{code: :not_drafting_agent}} =
               edit(%{agent_id: intruder.id}, c.clip.id, %{"title" => "x"})
    end
  end

  describe "authority: an agent's explicit org that cannot be resolved fails closed" do
    setup %{clip: clip}, do: %{before: frozen(clip.id), copy: reload(clip)}

    defp make_drafting!(c, agent) do
      c.w.profile |> Ecto.Changeset.change(drafting_agent_id: agent.id) |> Repo.update!()
    end

    defp repoint!(agent, metadata) do
      Repo.update_all(from(a in Platform.Agents.Agent, where: a.id == ^agent.id),
        set: [metadata: metadata]
      )
    end

    test "metadata org_id naming no org: refused through the tool door, nothing written", c do
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(c.w.profile.id))
      repoint!(c.w.agent, %{"org_id" => Ecto.UUID.generate()})

      assert {:error, %{code: :not_drafting_agent, recoverable: false}} =
               edit(c.ctx, c.clip.id, %{"title" => "Root takeover"})

      assert_unchanged(c)
      refute_receive {:social_clip, _}, 50
    end

    test "metadata org_id that is not even a uuid is refused too", c do
      repoint!(c.w.agent, %{"org_id" => "not-a-uuid"})

      assert {:error, %{code: :not_drafting_agent}} =
               edit(c.ctx, c.clip.id, %{"title" => "x"})

      assert_unchanged(c)
    end

    test "a tenant agent in its own org still edits", c do
      assert {:ok, %{clip: %{title: "Tenant edit"}}} =
               edit(c.ctx, c.clip.id, %{"title" => "Tenant edit"})
    end

    test "a root-homed drafting agent (no org_id) still edits", c do
      root = agent!()
      make_drafting!(c, root)

      assert {:ok, %{clip: %{title: "Root edit"}}} =
               edit(%{agent_id: root.id}, c.clip.id, %{"title" => "Root edit"})
    end

    test "a drafting agent pinned to the root org itself still edits", c do
      repoint!(c.w.agent, %{"org_id" => Platform.TenancyFixtures.acme_org_id()})

      assert {:ok, %{clip: %{title: "Pinned root edit"}}} =
               edit(c.ctx, c.clip.id, %{"title" => "Pinned root edit"})
    end

    test "an agent repointed to a real OTHER tenant org is still not_found", c do
      repoint!(c.w.agent, %{"org_id" => c.w.other_org_id})

      assert {:error, %{code: :not_found}} = edit(c.ctx, c.clip.id, %{"title" => "x"})
      assert_unchanged(c)
    end
  end

  describe "audit: the edit is attributed to the calling agent" do
    defp audit_rows(clip_id) do
      Repo.all(
        from(e in Platform.Audit.Event,
          where:
            e.event_type == "platform.social.clip_copy_updated" and e.resource_id == ^clip_id,
          order_by: e.inserted_at
        )
      )
    end

    test "one audit event per applied edit: agent, clip, fields changed, no copy text", c do
      assert {:ok, _} = edit(c.ctx, c.clip.id, %{"title" => "Secret new title"})
      assert {:ok, _} = edit(c.ctx, c.clip.id, %{"caption" => "Another"})

      assert [one, two] = audit_rows(c.clip.id)
      assert one.actor_id == c.w.agent.id
      assert one.actor_type == "agent"
      assert one.resource_type == "social_clip"
      assert one.action == "copy_updated"
      assert one.metadata["fields"] == ["title"]
      assert one.metadata["profile_id"] == c.w.profile.id
      assert one.metadata["org_id"] == c.w.org_id
      assert two.metadata["fields"] == ["caption"]
      refute inspect(one.metadata) =~ "Secret new title"
    end

    test "an edit that changes nothing records no audit row", c do
      clip = reload(c.clip)
      assert {:ok, _} = edit(c.ctx, c.clip.id, %{"title" => clip.title})

      assert {:ok, _} =
               edit(c.ctx, c.clip.id, %{"caption" => clip.caption, "title" => clip.title})

      assert audit_rows(c.clip.id) == []
    end

    test "refusals record nothing", c do
      intruder = pinned_agent!(c.w.org_id)
      assert {:error, _} = edit(%{agent_id: intruder.id}, c.clip.id, %{"title" => "x"})
      assert {:error, _} = edit(c.ctx, c.clip.id, %{"title" => ""})
      assert {:error, _} = edit(c.ctx, c.clip.id, %{"title" => "x", "expected_copy_rev" => "old"})
      assert audit_rows(c.clip.id) == []
    end
  end

  describe "freshness: the caller's read token" do
    setup %{clip: clip}, do: %{before: frozen(clip.id), copy: reload(clip)}

    test "copy_rev is a function of the copy only", %{clip: clip} do
      rev = ClipReviewFeed.copy_rev(clip)
      assert rev != ""
      assert rev == ClipReviewFeed.copy_rev(%{clip | updated_at: DateTime.utc_now(), rev: 99})
      refute rev == ClipReviewFeed.copy_rev(%{clip | title: "Other"})
      refute rev == ClipReviewFeed.copy_rev(%{clip | caption: "Other"})
      # nil and "" are different copies; so are shifts between the two fields.
      refute ClipReviewFeed.copy_rev(%{clip | caption: nil}) ==
               ClipReviewFeed.copy_rev(%{clip | caption: ""})

      refute ClipReviewFeed.copy_rev(%{clip | title: "ab", caption: "c"}) ==
               ClipReviewFeed.copy_rev(%{clip | title: "a", caption: "bc"})
    end

    test "a missing token is refused: the tool needs the caller's read", c do
      # The transport enforces the schema's required key first.
      assert {:error, %{code: :missing_expected_copy_rev}} =
               edit(c.ctx, c.clip.id, %{"title" => "x", "expected_copy_rev" => :none})

      assert {:error, %{code: code}} =
               edit(c.ctx, c.clip.id, %{"title" => "x", "expected_copy_rev" => ""})

      assert code in [:invalid_argument, :missing_expected_copy_rev]

      assert {:error, %{code: code5}} =
               edit(c.ctx, c.clip.id, %{"title" => "x", "expected_copy_rev" => 5})

      assert code5 in [:invalid_argument, :invalid_type]

      assert_unchanged(c)
    end

    test "the context refuses a nil, blank or non-text token itself, writing nothing", c do
      for bad <- [nil, "", 5] do
        assert {:error, :copy_rev_required} =
                 AgentDrafts.update_clip_copy(c.w.scope, c.clip.id, %{"title" => "x"},
                   agent_id: c.w.agent.id,
                   expected_copy_rev: bad
                 )
      end

      assert {:error, :copy_rev_required} =
               AgentDrafts.update_clip_copy(c.w.scope, c.clip.id, %{"title" => "x"},
                 agent_id: c.w.agent.id
               )

      assert_unchanged(c)
    end

    test "a token from before a human save is refused with stale_copy; nothing is written", c do
      Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(c.w.profile.id))
      old = current_rev(c.clip.id)

      {:ok, _} =
        ClipReviewFeed.save_details(c.w.org_id, c.w.profile.id, c.clip.id, c.w.approver.id, %{
          "caption" => "Human wrote this"
        })

      assert_receive {:social_clip, _}
      after_human = reload(c.clip)

      assert {:error, %{code: :stale_copy, recoverable: true} = err} =
               edit(c.ctx, c.clip.id, %{"title" => "Agent", "expected_copy_rev" => old})

      assert err.suggestion =~ "social_clip_list"
      assert reload(c.clip) == after_human
      assert after_human.caption == "Human wrote this"
      assert audit_rows(c.clip.id) == []
      refute_receive {:social_clip, _}, 50
    end

    test "a token from before another agent edit is refused too", c do
      old = current_rev(c.clip.id)
      assert {:ok, _} = edit(c.ctx, c.clip.id, %{"title" => "First"})

      assert {:error, %{code: :stale_copy}} =
               edit(c.ctx, c.clip.id, %{"title" => "Second", "expected_copy_rev" => old})

      assert %{title: "First"} = reload(c.clip)
    end

    test "the token the last write returned is accepted, and a no-op edit keeps it", c do
      assert {:ok, %{clip: %{copy_rev: r1}}} = edit(c.ctx, c.clip.id, %{"title" => "T1"})

      assert {:ok, %{clip: %{copy_rev: r2}}} =
               edit(c.ctx, c.clip.id, %{"title" => "T2", "expected_copy_rev" => r1})

      refute r1 == r2

      assert {:ok, %{clip: %{copy_rev: ^r2}}} =
               edit(c.ctx, c.clip.id, %{"title" => "T2", "expected_copy_rev" => r2})
    end

    test "social_clip_list carries the token to send", c do
      assert {:ok, %{clips: clips}} =
               ToolArguments.dispatch(
                 "social_clip_list",
                 %{"profile_id" => c.w.profile.id},
                 c.ctx
               )

      assert %{copy_rev: rev} = Enum.find(clips, &(&1.id == c.clip.id))
      assert rev == ClipReviewFeed.copy_rev(reload(c.clip))
    end

    test "every writer of title or caption moves the token; unrelated writes do not", c do
      rev0 = current_rev(c.clip.id)

      # not a copy write: platforms through the details rail
      {:ok, _} =
        ClipReviewFeed.save_details(c.w.org_id, c.w.profile.id, c.clip.id, c.w.approver.id, %{
          "platforms" => ["tiktok"]
        })

      assert current_rev(c.clip.id) == rev0

      # 1. the details rail
      {:ok, _} =
        ClipReviewFeed.save_details(c.w.org_id, c.w.profile.id, c.clip.id, c.w.approver.id, %{
          "title" => "Rail"
        })

      rev1 = current_rev(c.clip.id)
      refute rev1 == rev0

      # 2. the tool
      {:ok, _} = edit(c.ctx, c.clip.id, %{"caption" => "Tool"})
      rev2 = current_rev(c.clip.id)
      refute rev2 in [rev0, rev1]

      # 3. a new version (render job / intake): ClipVersions.append!
      file2 = stored_file!(c.w.project, "v2 #{unique()}", "v2.mp4", "video/mp4")

      {:ok, _} =
        Repo.transaction(fn ->
          ClipVersions.append!(c.clip.id, file2, %{title: "Version", caption: "Version cap"}, %{
            headline: "Version",
            caption: "Version cap",
            source: %{"origin" => "external"},
            provenance: %{"kind" => "test"},
            completion_key: "test:" <> Ecto.UUID.generate()
          })
        end)

      rev3 = current_rev(c.clip.id)
      refute rev3 in [rev0, rev1, rev2]
      assert %{title: "Version", caption: "Version cap"} = reload(c.clip)

      # 4. Create drafts with an explicit human edit
      assert {:ok, _} =
               ClipDecisions.draft_clip(c.w.org_id, c.clip.id, c.w.approver.id, %{
                 "copy_rev" => clip_copy_rev!(c.clip),
                 "render_id" => render_id!(reload(c.clip)),
                 "account_ids" => [c.w.tiktok.id],
                 "title" => "Drafted title"
               })

      rev4 = current_rev(c.clip.id)
      refute rev4 in [rev0, rev1, rev2, rev3]
    end

    test "removing the current version restores the previous copy and moves the token", c do
      file2 = stored_file!(c.w.project, "v2 #{unique()}", "v2.mp4", "video/mp4")

      {:ok, _} =
        Repo.transaction(fn ->
          ClipVersions.append!(c.clip.id, file2, %{title: "V2", caption: "V2 cap"}, %{
            headline: "V2",
            caption: "V2 cap",
            source: %{"origin" => "external"},
            provenance: %{"kind" => "test"},
            completion_key: "test:" <> Ecto.UUID.generate()
          })
        end)

      rev_v2 = current_rev(c.clip.id)
      v2 = Repo.get_by!(ClipRender, clip_id: c.clip.id, rev: 2)

      assert {:ok, _} =
               ClipRemoval.remove_clip_render(
                 c.w.scope,
                 c.w.profile.id,
                 c.clip.id,
                 v2.id,
                 c.w.approver.id
               )

      assert %{title: "Original title"} = reload(c.clip)
      refute current_rev(c.clip.id) == rev_v2
    end
  end

  describe "the tool definition" do
    test "is in the bundle with a narrow schema and the human-approves sentence" do
      tool =
        Enum.find(
          Platform.Social.ToolDefinitions.definitions(),
          &(&1.name == "social_clip_update_copy")
        )

      assert tool
      assert "social_clip_update_copy" in Platform.Social.ToolDefinitions.names()

      assert Enum.sort(Map.keys(tool.parameters)) ==
               [:caption, :clip_id, :expected_copy_rev, :title]

      assert tool.parameters.clip_id.required
      assert tool.parameters.expected_copy_rev.required
      assert tool.limitations =~ "stale_copy"
      assert tool.limitations =~ "not_drafting_agent"
      assert tool.description =~ "drafting agent"
      refute tool.parameters.title.required
      refute tool.parameters.caption.required
      assert tool.description =~ Platform.Social.ToolDefinitions.human_approves()
      assert tool.limitations =~ "clip_not_editable"
    end
  end
end
