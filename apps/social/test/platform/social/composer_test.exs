defmodule Platform.Social.ComposerTest do
  @moduledoc """
  The composer's engine (task 01a14aca's stage 1, carried onto main and
  extended by Social authoring 6/11, task 01a16c50): per-platform
  adaptation in the brand voice, the banned-phrase regeneration, the
  reasoning facts, and the send into the approval path.

  No real model or Zernio traffic: `Platform.SocialComposerFixtures`
  points the Anthropic client at a `Req.Test` stub, and Zernio is selected
  as the publisher with a `Req.Test` stub that reports every request.
  async: false because both seams are application env.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  import Platform.SocialComposerFixtures

  alias Platform.Experiments
  alias Platform.Experiments.{Assignment, Experiment, Variant}
  alias Platform.Social
  alias Platform.Social.{ApprovalCard, Approvals, Composer, Idea, Ideas, Post, PostEvent}
  alias Platform.Social.Composer.{AdaptationSurface, Output, Prompts}
  alias Platform.Social.Publisher.Zernio

  setup do
    restore_llm = use_llm_stub!()
    previous_publisher = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Zernio)

    on_exit(fn ->
      restore_llm.()

      if previous_publisher,
        do: Application.put_env(:social, :publisher, previous_publisher),
        else: Application.delete_env(:social, :publisher)
    end)

    test = self()

    Req.Test.stub(Zernio, fn conn ->
      send(test, {:zernio, conn.method, conn.request_path})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"post" => %{"_id" => "zp_1"}})
    end)

    ctx = approval_fixture()
    {:ok, x} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@htc"})

    {:ok, ig} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "instagram", handle: "@htc.ig"})

    Map.merge(ctx, %{x: x, ig: ig})
  end

  defp ok_columns(%{columns: columns}),
    do: for({p, {:ok, draft}} <- columns, into: %{}, do: {p, draft})

  defp idea_attrs, do: %{title: "The launch", brief: "What we shipped and why."}

  defp drafts_for(result, accounts) do
    drafts = ok_columns(result)

    for account <- accounts do
      d = Map.fetch!(drafts, account.platform)

      %{
        account_id: account.id,
        text: d.text,
        title: d.title,
        original_text: d.text,
        prompt_slug: d.prompt_slug,
        composition_id: result.composition_id
      }
    end
  end

  describe "adapt/3" do
    test "one idea becomes distinct per-platform drafts, one model call per platform", ctx do
      drafting_agent!()
      stub_llm!()

      result =
        Composer.adapt(ctx.profile, ["linkedin", "x", "instagram", "youtube", "tiktok"], %{
          idea: "We launched the thing",
          source: "Transcript excerpt",
          tone: "warm"
        })

      assert Platform.UUID.valid?(result.composition_id)
      drafts = ok_columns(result)
      assert map_size(drafts) == 5

      assert drafts["linkedin"].text == "LinkedIn long-form on the launch."
      assert drafts["instagram"].text == "Launch day caption #htc"
      assert drafts["tiktok"].text == "Launch, fast. #htc"
      assert drafts["youtube"].title == "How the launch came together"
      assert drafts["youtube"].text == "The whole story of the launch."
      assert drafts["linkedin"].prompt_slug == "social.composer.adapt.linkedin.v1"
      assert drafts["x"].prompt_slug == "social.composer.adapt.x.v1"

      # A short X version is one post with no number (PlatformLimits.thread/1).
      assert drafts["x"].text == "The launch, in brief.\n\nWhy it matters."
      assert [%{index: 1, total: 1}] = drafts["x"].posts

      calls =
        for _ <- 1..5 do
          assert_receive {:llm, kind, _model, _prompt}
          kind
        end

      assert Enum.sort(calls) == ~w(instagram linkedin tiktok x youtube)
      refute_received {:llm, _, _, _}
    end

    test "a 600-character X version is three numbered posts", ctx do
      drafting_agent!()
      stub_llm!(replies: %{"x" => long_x_reply()})

      assert {:ok, draft} = Composer.adapt_one(ctx.profile, "x", %{idea: "Launch"})
      assert String.length(draft.text) in 590..600
      assert [p1, p2, p3] = draft.posts
      assert {p1.index, p2.index, p3.index} == {1, 2, 3}
      assert p1.text =~ ~r{ 1/3\z}
      assert p3.text =~ ~r{ 3/3\z}
      assert Enum.all?(draft.posts, &(&1.count <= 280))
    end

    test "the prompt carries the brand voice: notes, samples, banned phrases, learnings", ctx do
      drafting_agent!()
      stub_llm!()

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{
          voice_notes: "Plain, warm, no jargon.",
          voice: %{samples: ["We built it for the people who asked."], banned: ["game changer"]}
        })

      # Learnings are written only by the weekly-note flow (11/11), never
      # cast: set one on the struct the composer is handed.
      learning = %Platform.Social.VoiceLearning{text: "Questions get replies."}
      profile = %{profile | voice: %{profile.voice | learnings: [learning]}}
      assert {:ok, _} = Composer.adapt_one(profile, "linkedin", %{idea: "Launch"})
      assert_receive {:llm, "linkedin", _, prompt}

      assert prompt =~ "Plain, warm, no jargon."
      assert prompt =~ "- We built it for the people who asked."
      assert prompt =~ "NEVER uses (do not write any of them, in any form): game changer"
      assert prompt =~ "- Questions get replies."
    end

    test "the profile's drafting agent is the model, over the fallback", ctx do
      drafting_agent!()
      own = composer_agent!(%{model: "brand-model"})
      stub_llm!()

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{drafting_agent_id: own.id})

      assert {:ok, _} = Composer.adapt_one(profile, "linkedin", %{idea: "Launch"})
      assert_receive {:llm, "linkedin", "brand-model", _}
    end

    test "the X column failing leaves LinkedIn and Instagram ok", ctx do
      drafting_agent!()
      stub_llm!(fail: ["x"])

      result = Composer.adapt(ctx.profile, ["linkedin", "x", "instagram"], %{idea: "Launch"})

      assert [
               {"linkedin", {:ok, %{text: "LinkedIn long-form on the launch."}}},
               {"x", {:error, :provider_failed}},
               {"instagram", {:ok, %{text: "Launch day caption #htc"}}}
             ] = result.columns
    end

    test "output outside the closed shape is that column's error only", ctx do
      drafting_agent!()
      stub_llm!(replies: %{"linkedin" => %{"text" => "ok", "why_shape" => "w", "tool" => "x"}})

      result = Composer.adapt(ctx.profile, ["linkedin", "instagram"], %{idea: "Launch"})

      assert [{"linkedin", {:error, :invalid_output}}, {"instagram", {:ok, _}}] = result.columns
    end

    test "no drafting agent: every column is :no_drafting_agent and no model call", ctx do
      stub_llm!()

      result = Composer.adapt(ctx.profile, ["linkedin", "x"], %{idea: "Launch"})

      assert result.columns == [
               {"linkedin", {:error, :no_drafting_agent}},
               {"x", {:error, :no_drafting_agent}}
             ]

      refute_received {:llm, _, _, _}
    end

    test "an unsupported platform and a blank idea are column errors", ctx do
      drafting_agent!()
      stub_llm!()

      assert %{columns: [{"myspace", {:error, :unsupported_platform}}]} =
               Composer.adapt(ctx.profile, ["myspace"], %{idea: "Launch"})

      assert %{columns: [{"linkedin", {:error, :idea_required}}]} =
               Composer.adapt(ctx.profile, ["linkedin"], %{idea: "  "})
    end

    test "an edited template row is what the model receives (prompts are data)", ctx do
      drafting_agent!()
      stub_llm!()

      template =
        Platform.Orchestration.PromptTemplates.get_template_by_slug(
          Prompts.adapt_slug("linkedin")
        )

      assert template, "the seed migration must have inserted the linkedin row"

      {:ok, _} =
        Platform.Orchestration.PromptTemplates.update_template(template, %{
          content: template.content <> "\nEDITED-IN-ADMIN {{profile_name}}"
        })

      Composer.adapt(ctx.profile, ["linkedin"], %{idea: "Launch"})
      assert_receive {:llm, "linkedin", _, prompt}
      assert prompt =~ "EDITED-IN-ADMIN #{ctx.profile.name}"
    end

    test "the seed inserted one row per platform" do
      for platform <- Prompts.platforms() do
        assert Platform.Orchestration.PromptTemplates.get_template_by_slug(
                 Prompts.adapt_slug(platform)
               ),
               "missing the #{platform} template"
      end
    end
  end

  describe "banned phrases" do
    setup ctx do
      drafting_agent!()

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{voice: %{banned: ["game changer"]}})

      Map.put(ctx, :profile, profile)
    end

    test "a banned phrase triggers ONE regeneration; a clean second version is kept", ctx do
      stub_llm!(
        replies: %{"linkedin" => %{"text" => "A real game changer.", "why_shape" => "w"}},
        retry_replies: %{"linkedin" => %{"text" => "A real step forward.", "why_shape" => "w"}}
      )

      assert {:ok, draft} = Composer.adapt_one(ctx.profile, "linkedin", %{idea: "Launch"})
      assert draft.text == "A real step forward."
      assert draft.regenerated?
      assert is_nil(draft.banned_phrase)

      assert_receive {:llm, "linkedin", _, first}
      assert_receive {:llm, "linkedin", _, second}
      refute first =~ "Your previous version used the phrase"
      assert second =~ ~s(Your previous version used the phrase "game changer")
      refute_received {:llm, _, _, _}
    end

    test "still there after the regeneration: kept, flagged, never stripped", ctx do
      reply = %{"text" => "Truly a Game Changer for us.", "why_shape" => "w"}
      stub_llm!(replies: %{"linkedin" => reply}, retry_replies: %{"linkedin" => reply})

      assert {:ok, draft} = Composer.adapt_one(ctx.profile, "linkedin", %{idea: "Launch"})
      assert draft.text == "Truly a Game Changer for us."
      assert draft.banned_phrase == "game changer"
      assert draft.regenerated?

      assert_receive {:llm, "linkedin", _, _}
      assert_receive {:llm, "linkedin", _, _}
      refute_received {:llm, _, _, _}

      rationale = Composer.rationale(ctx.profile, ctx.a, draft)
      assert rationale.banned == "game changer"
      assert rationale.voice_check =~ "never says"
    end
  end

  describe "rationale/4" do
    test "format from the model, time from the next free slot, a repeat from the last 30 posts",
         ctx do
      {:ok, account} =
        Social.update_account_schedule(ctx.org_id, ctx.a, %{
          posting_slots: [%{weekday: 2, time: "09:00"}]
        })

      {_post, _card} =
        pending_post!(ctx, ctx.a, %{body: "Our team ships every single week without fail."})

      draft = %{
        text: "We said it before: ships every single week without fail.",
        why_shape: "Room."
      }

      r = Composer.rationale(ctx.profile, account, draft)

      assert r.why_format == "Room."
      assert %DateTime{} = r.slot
      assert r.why_time =~ "Next open posting slot: Tue"
      assert r.repeat == "ships every single week without"
      assert r.voice_check =~ "already appears in one of the brand's last 30 posts"
    end

    test "no slots and nothing repeated", ctx do
      r = Composer.rationale(ctx.profile, ctx.a, %{text: "Fresh words here.", why_shape: "w"})
      assert is_nil(r.slot)
      assert r.why_time =~ "No posting slots"
      assert is_nil(r.repeat)
      assert r.voice_check =~ "No banned phrases"
    end
  end

  describe "Output" do
    test "YouTube needs a title and a description; X refuses an empty thread" do
      assert {:error, :invalid_output} =
               Output.parse_adaptation(
                 "youtube",
                 Jason.encode!(%{"text" => "t", "why_shape" => "w"})
               )

      assert {:error, :invalid_output} =
               Output.parse_adaptation("x", Jason.encode!(%{"posts" => [], "why_shape" => "w"}))

      assert {:ok, %{text: "t"}} =
               Output.parse_adaptation(
                 "tiktok",
                 "```json\n" <> Jason.encode!(%{"text" => "t", "why_shape" => "w"}) <> "\n```"
               )
    end
  end

  describe "send/4" do
    setup ctx do
      drafting_agent!()
      stub_llm!()
      result = Composer.adapt(ctx.profile, ["linkedin", "x", "instagram"], %{idea: "Launch"})
      Map.put(ctx, :result, result)
    end

    test "Send for approval: one idea, one needs_approval post per account, a card each, ZERO Zernio",
         ctx do
      drafts = drafts_for(ctx.result, [ctx.a, ctx.x, ctx.ig])

      assert {:ok, %{idea: %Idea{} = idea, posts: posts, approved: []}} =
               Composer.send(ctx.profile, ctx.n.id, %{idea: idea_attrs(), drafts: drafts})

      assert idea.source_kind == "human"
      assert idea.title == "The launch"
      assert length(posts) == 3

      for post <- posts do
        row = Repo.get!(Post, post.id)
        assert row.status == "needs_approval"
        assert row.idea_id == idea.id
        assert is_nil(row.approved_by_user_id)
        assert %ApprovalCard{state: "pending"} = Approvals.live_card(post.id)

        assert [{"created", "human"}, {"submitted", "human"}] =
                 Repo.all(
                   from(e in PostEvent,
                     where: e.post_id == ^post.id,
                     order_by: [asc: e.inserted_at, asc: e.id],
                     select: {e.action, e.actor_kind}
                   )
                 )
      end

      assert Ideas.stage(idea) == "in_review"
      refute_received {:zernio, _, _}
    end

    test "the composer never names the publisher (approval publishes, not send)" do
      source = File.read!(Path.expand("../../../lib/platform/social/composer.ex", __DIR__))

      code =
        ~r/@(moduledoc|doc) """.*?"""/s
        |> Regex.replace(source, "")
        |> then(&Regex.replace(~r/^\s*#.*$/m, &1, ""))

      assert code =~ "Social.create_post"
      assert code =~ "Approvals.decide_approve"

      refute code =~ "Publishing"
      refute code =~ "publish_post"
      refute code =~ ~s("approved")
      refute code =~ ~s("scheduled")
    end

    test "Send and approve: approves as the user through the decision path, then publishes",
         ctx do
      ready_for_zernio!(ctx)
      [li] = drafts_for(ctx.result, [ctx.a])

      assert {:ok, %{approved: [approved], posts: [post]}} =
               Composer.send(ctx.profile, ctx.h1.id, %{idea: idea_attrs(), drafts: [li]},
                 approve: true
               )

      assert approved.id == post.id
      row = Repo.get!(Post, post.id)
      assert row.status in Post.approved_statuses()
      assert row.approved_by_user_id == ctx.h1.id

      assert Repo.exists?(
               from(e in PostEvent,
                 where:
                   e.post_id == ^post.id and e.action == "approved" and e.actor_kind == "human" and
                     e.actor_id == ^ctx.h1.id
               )
             )

      assert_receive {:zernio, "POST", "/api/v1/posts"}
    end

    test "Send and approve: an owned account waits for its owner; draft-only waits to be copied",
         ctx do
      {:ok, owned} = Social.set_account_owner(ctx.org_id, ctx.x, ctx.h2.id)
      drafts = drafts_for(ctx.result, [ctx.a, ctx.d]) ++ drafts_for(ctx.result, [owned])

      assert {:ok, result} =
               Composer.send(ctx.profile, ctx.h1.id, %{idea: idea_attrs(), drafts: drafts},
                 approve: true
               )

      assert [%{account_id: a_id}] = result.approved
      assert a_id == ctx.a.id
      assert [{%{account_id: x_id}, owner}] = result.waiting_owner
      assert x_id == ctx.x.id and owner.id == ctx.h2.id
      assert [%{account_id: d_id}] = result.by_hand
      assert d_id == ctx.d.id

      assert Repo.get!(Post, elem(hd(result.waiting_owner), 0).id).status == "needs_approval"
      assert Repo.get!(Post, hd(result.by_hand).id).status == "needs_approval"
    end

    test "Send and approve by a non-approver writes nothing (a forged event)", ctx do
      drafts = drafts_for(ctx.result, [ctx.a, ctx.x])

      assert {:error, :not_an_approver} =
               Composer.send(ctx.profile, ctx.n.id, %{idea: idea_attrs(), drafts: drafts},
                 approve: true
               )

      assert post_count(ctx) == 0
      assert Repo.aggregate(Idea, :count) == 0
    end

    test "an agent id or an archived user writes nothing", ctx do
      compose = %{idea: idea_attrs(), drafts: drafts_for(ctx.result, [ctx.a])}

      assert {:error, :not_a_human} = Composer.send(ctx.profile, ctx.g.id, compose)

      ctx.h2 |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
      assert {:error, :approver_archived} = Composer.send(ctx.profile, ctx.h2.id, compose)

      assert post_count(ctx) == 0
      assert Repo.aggregate(ApprovalCard, :count) == 0
      refute_received {:zernio, _, _}
    end

    test "a scheduled draft keeps needs_approval with its time and reason", ctx do
      at = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)
      [x] = drafts_for(ctx.result, [ctx.x])
      x = Map.merge(x, %{scheduled_at: at, schedule_reason: "Next open posting slot."})

      assert {:ok, %{posts: [post]}} =
               Composer.send(ctx.profile, ctx.h1.id, %{idea: idea_attrs(), drafts: [x]})

      row = Repo.get!(Post, post.id)
      assert row.status == "needs_approval"
      assert DateTime.compare(row.scheduled_at, at) == :eq
      assert row.schedule_reason == "Next open posting slot."
    end

    test "a past time, an empty version or a foreign account writes nothing", ctx do
      [x] = drafts_for(ctx.result, [ctx.x])
      past = Map.put(x, :scheduled_at, DateTime.add(DateTime.utc_now(), -60))

      assert {:error, :schedule_in_past} =
               Composer.send(ctx.profile, ctx.h1.id, %{idea: idea_attrs(), drafts: [past]})

      assert {:error, {:invalid_draft, _}} =
               Composer.send(ctx.profile, ctx.h1.id, %{
                 idea: idea_attrs(),
                 drafts: [%{x | text: "  "}]
               })

      other = approval_fixture()

      assert {:error, {:no_account, _}} =
               Composer.send(ctx.profile, ctx.h1.id, %{
                 idea: idea_attrs(),
                 drafts: [%{x | account_id: other.a.id}]
               })

      assert post_count(ctx) == 0
      assert Repo.aggregate(Idea, :count) == 0
    end

    test "a profile with no approval channel is refused with nothing written", ctx do
      {:ok, profile} = Social.update_profile(ctx.org_id, ctx.profile, %{space_id: nil})

      assert {:error, :profile_has_no_channel} =
               Composer.send(profile, ctx.h1.id, %{
                 idea: idea_attrs(),
                 drafts: drafts_for(ctx.result, [ctx.x])
               })

      assert post_count(ctx) == 0
    end

    test "opened from an existing idea: the posts join it, no new idea", ctx do
      {:ok, idea} =
        Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Saved"}, {:user, ctx.h1.id})

      assert {:ok, %{idea: ^idea, posts: [post]}} =
               Composer.send(ctx.profile, ctx.h1.id, %{
                 idea: idea,
                 drafts: drafts_for(ctx.result, [ctx.x])
               })

      assert Repo.get!(Post, post.id).idea_id == idea.id
      assert Repo.aggregate(Idea, :count) == 1
    end

    test "save_idea: the idea alone, stage inbox", ctx do
      assert {:ok, idea} = Composer.save_idea(ctx.profile, ctx.n.id, idea_attrs())
      assert idea.source_kind == "human"
      assert Ideas.stage(idea) == "inbox"
      assert post_count(ctx) == 0
    end

    test "each post records post-side provenance, and no experiment arm", ctx do
      [li, x] = drafts_for(ctx.result, [ctx.a, ctx.x])
      li = %{li | text: li.text <> " (edited)"}

      assert {:ok, %{posts: posts}} =
               Composer.send(ctx.profile, ctx.h1.id, %{idea: idea_attrs(), drafts: [li, x]})

      by_account = Map.new(posts, &{&1.account_id, Repo.get!(Post, &1.id).composer_provenance})

      assert by_account[ctx.a.id] == %{
               "source" => "composer",
               "platform" => "linkedin",
               "prompt_slug" => "social.composer.adapt.linkedin.v1",
               "composition_id" => ctx.result.composition_id,
               "edited" => true,
               "edit_count" => 1
             }

      assert %{"platform" => "x", "edited" => false, "edit_count" => 0} = by_account[ctx.x.id]

      for {_, prov} <- by_account, key <- Map.keys(prov) do
        refute key =~ "variant"
        refute key =~ "experiment"
        refute key =~ "arm"
      end
    end
  end

  describe "create_post/4" do
    test "an idea on another profile is refused", ctx do
      other = approval_fixture()

      {:ok, idea} =
        Ideas.create(other.org_id, other.profile.id, %{title: "Theirs"}, {:user, other.h1.id})

      assert {:error, :not_found} =
               Social.create_post(ctx.org_id, ctx.a, %{body: "b", status: "draft"},
                 idea_id: idea.id
               )

      {:ok, mine} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Mine"}, {:user, ctx.h1.id})
      second = Social.get_profile(ctx.org_id, ctx.profile.id)

      {:ok, another} =
        Social.create_profile(ctx.org_id, %{name: "Second #{unique()}", space_id: second.space_id})

      {:ok, acct} = Social.create_account(ctx.org_id, another, %{platform: "x", handle: "@two"})

      assert {:error, :idea_profile_mismatch} =
               Social.create_post(ctx.org_id, acct, %{body: "b", status: "draft"},
                 idea_id: mine.id
               )
    end
  end

  describe "experiment surface" do
    test "Surfaces.get resolves the key to AdaptationSurface (registered by the extension)" do
      assert Platform.Experiments.Surfaces.get("social.composer.adaptation") == AdaptationSurface
      assert AdaptationSurface in Platform.Social.Extension.experiment_surfaces()
      refute AdaptationSurface in Platform.Experiments.Surfaces.core_surfaces()
    end

    test "payload validation and the control come from config" do
      assert {:ok, %{"prompt_slug" => "social.composer.adapt.x.v1"} = control} =
               AdaptationSurface.control_payload("x")

      refute Map.has_key?(control, "model")
      assert {:ok, ^control} = AdaptationSurface.validate_payload(control)

      assert {:ok, %{"prompt_slug" => "social.composer.adapt.x.v2", "model" => "m"}} =
               AdaptationSurface.validate_payload(%{
                 "prompt_slug" => " social.composer.adapt.x.v2 ",
                 "model" => "m"
               })

      assert {:error, _} = AdaptationSurface.validate_payload(%{"prompt_slug" => "dispatch.x"})
      assert {:error, _} = AdaptationSurface.validate_payload(%{"model" => "m"})

      assert {:error, _} =
               AdaptationSurface.validate_payload(%{
                 "prompt_slug" => "social.composer.a",
                 "x" => 1
               })

      assert {:ok, _} = AdaptationSurface.control_payload("tiktok")
      assert {:error, :unknown_target} = AdaptationSurface.control_payload("myspace")
    end

    test "a running experiment's arm drives the column; the assignment row records it", ctx do
      drafting_agent!()
      stub_llm!()
      experiment = running_experiment!("linkedin", %{"model" => "treatment-model"})

      result = Composer.adapt(ctx.profile, ["linkedin", "x"], %{idea: "Launch"})

      models =
        for _ <- 1..2, into: %{} do
          assert_receive {:llm, kind, model, _}
          {kind, model}
        end

      assert models == %{"linkedin" => "treatment-model", "x" => "agent-model"}

      assert [%Assignment{subject_type: "social_composition", variant_slug: "treatment"} = a] =
               Repo.all(from(a in Assignment, where: a.experiment_id == ^experiment.id))

      assert a.subject_id == result.composition_id

      {:ok, %{posts: posts}} =
        Composer.send(ctx.profile, ctx.h1.id, %{
          idea: idea_attrs(),
          drafts: drafts_for(result, [ctx.a])
        })

      for post <- posts do
        prov = Repo.get!(Post, post.id).composer_provenance
        refute Map.has_key?(prov, "variant")
        assert prov["composition_id"] == a.subject_id
      end
    end
  end

  defp running_experiment!(target, payload) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "composer-#{unique()}",
        name: "Composer adaptation",
        surface_key: "social.composer.adaptation",
        surface_target: target
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: Map.merge(%{"prompt_slug" => Prompts.adapt_slug(target)}, payload),
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = running} =
      Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

    Repo.update_all(
      from(v in Variant,
        where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
      ),
      set: [weight: 0]
    )

    running
  end

  defp post_count(ctx) do
    account_ids = [ctx.a.id, ctx.d.id, ctx.x.id, ctx.ig.id]
    Repo.aggregate(from(p in Post, where: p.account_id in ^account_ids), :count)
  end

  # Zernio needs the install key and both vendor refs before it sends.
  defp ready_for_zernio!(ctx) do
    {:ok, _} =
      Platform.Vault.put("social:zernio:api_key", :api_key, "zernio-test-key-not-real",
        scope: {:integration, nil},
        provider: "social"
      )

    {:ok, _} = Social.update_profile(ctx.org_id, ctx.profile, %{provider_profile_ref: "zprof_1"})
    {:ok, _} = Social.update_account(ctx.org_id, ctx.a, %{provider_account_ref: "zacct_1"})
  end
end
