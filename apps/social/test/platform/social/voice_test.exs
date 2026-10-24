defmodule Platform.Social.VoiceTest do
  @moduledoc """
  Social authoring 4/11 (task 01a16c4f-9041): the profile's structured
  voice, timezone, notify list and drafting agent; banned phrases refusing
  an AGENT draft (create and update) and only flagging for a human; and
  `social_profile_get` returning all of it to agents.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, PlatformLimits, Post, Profile, Voice, VoiceLearning}

  setup do
    org_id = org_id!()
    approver = member!(user!(), org_id)

    {:ok, profile} =
      Social.create_profile(org_id, %{
        name: "Voice #{unique()}",
        space_id: channel!(org_id).id,
        approver_user_ids: [approver.id],
        voice: %{samples: ["We ship small things often."], banned: ["game changer", "Synergy"]}
      })

    {:ok, account} = Social.create_account(org_id, profile, %{platform: "x", handle: "voice"})

    %{
      org_id: org_id,
      scope: {:tenant, org_id},
      profile: profile,
      account: account,
      approver: approver,
      agent: pinned_agent!(org_id)
    }
  end

  defp learning!(profile, text) do
    voice = Voice.of(profile)

    learning = %VoiceLearning{
      id: Ecto.UUID.generate(),
      text: text,
      accepted_at: DateTime.utc_now()
    }

    profile
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:voice, %{learnings: voice.learnings ++ [learning]})
    |> Repo.update!()
  end

  describe "profile fields" do
    test "a new profile defaults to Etc/UTC and an empty voice", ctx do
      {:ok, profile} = Social.create_profile(ctx.org_id, %{name: "Plain #{unique()}"})
      profile = Repo.get!(Profile, profile.id)

      assert profile.timezone == "Etc/UTC"
      assert %Voice{samples: [], banned: [], learnings: []} = Voice.of(profile)
      assert profile.notify_user_ids == []
      assert profile.drafting_agent_id == nil
    end

    test "timezone is validated against the time zone database", ctx do
      assert {:ok, %{timezone: "America/Denver"}} =
               Social.update_profile(ctx.org_id, ctx.profile, %{timezone: "America/Denver"})

      assert {:error, changeset} =
               Social.update_profile(ctx.org_id, ctx.profile, %{timezone: "Mars/Olympus"})

      assert "is not a known time zone" in errors_on(changeset).timezone
    end

    test "voice samples and banned phrases are trimmed, capped and deduplicated", ctx do
      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{
          voice: %{samples: ["  one  ", "", "two"], banned: ["Buzz", "buzz ", " ", "hype"]}
        })

      assert {profile.voice.samples, profile.voice.banned} == {["one", "two"], ["Buzz", "hype"]}

      too_many = for i <- 1..11, do: "sample #{i}"
      too_long = String.duplicate("a", 3001)

      for voice <- [
            %{samples: too_many},
            %{samples: [too_long]},
            %{banned: for(i <- 1..51, do: "p#{i}")}
          ] do
        assert {:error, %Ecto.Changeset{}} =
                 Social.update_profile(ctx.org_id, ctx.profile, %{voice: voice})
      end
    end

    test "learnings are never cast from attrs", ctx do
      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{
          voice: %{samples: ["kept"], learnings: [%{text: "forged"}]}
        })

      assert Voice.of(profile).learnings == []
    end

    test "notify must be approvers; removing an approver drops them from notify", ctx do
      other = user!()

      assert {:error, changeset} =
               Social.update_profile(ctx.org_id, ctx.profile, %{notify_user_ids: [other.id]})

      assert errors_on(changeset).notify_user_ids != []

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{
          approver_user_ids: [ctx.approver.id, other.id],
          notify_user_ids: [ctx.approver.id, other.id]
        })

      {:ok, profile} =
        Social.update_profile(ctx.org_id, profile, %{approver_user_ids: [ctx.approver.id]})

      assert profile.notify_user_ids == [ctx.approver.id]
    end

    test "the drafting agent must be an active agent of the org", ctx do
      assert {:ok, %{drafting_agent_id: id}} =
               Social.update_profile(ctx.org_id, ctx.profile, %{drafting_agent_id: ctx.agent.id})

      assert id == ctx.agent.id

      foreign = pinned_agent!(org_id!())

      assert {:error, changeset} =
               Social.update_profile(ctx.org_id, ctx.profile, %{drafting_agent_id: foreign.id})

      assert errors_on(changeset).drafting_agent_id != []
      assert ctx.agent.id in Enum.map(Social.drafting_agent_options(ctx.org_id), & &1.id)
      refute foreign.id in Enum.map(Social.drafting_agent_options(ctx.org_id), & &1.id)
    end

    test "an approver removes a learning; anyone else is refused", ctx do
      profile = learning!(ctx.profile, "Lead with the result")
      [learning] = profile.voice.learnings

      assert {:error, :not_an_approver} =
               Social.remove_voice_learning(ctx.org_id, profile, user!().id, learning.id)

      assert {:error, :not_found} =
               Social.remove_voice_learning(
                 ctx.org_id,
                 profile,
                 ctx.approver.id,
                 Ecto.UUID.generate()
               )

      assert {:ok, profile} =
               Social.remove_voice_learning(ctx.org_id, profile, ctx.approver.id, learning.id)

      assert Voice.of(Repo.get!(Profile, profile.id)).learnings == []
    end
  end

  describe "banned_phrase/2" do
    test "is case-insensitive, whitespace-tolerant and whole-word at word edges" do
      banned = ["game changer", "Synergy", "100%"]

      assert Voice.banned_phrase("This is a GAME   changer.", banned) == "game changer"
      assert Voice.banned_phrase("pure synergy", banned) == "Synergy"
      assert Voice.banned_phrase("We give 100%!", banned) == "100%"
      assert Voice.banned_phrase("synergyx is a word we made up", banned) == nil
      assert Voice.banned_phrase("A plain update.", banned) == nil
      assert Voice.banned_phrase(nil, banned) == nil
    end
  end

  describe "agent drafts with a banned phrase (done means)" do
    test "a create is refused with the phrase named, and nothing is written", ctx do
      before = Repo.aggregate(Post, :count)

      assert {:error, :banned_phrase, "game changer"} =
               AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
                 "account_ids" => [ctx.account.id],
                 "body" => "This release is a Game Changer for teams."
               })

      assert Repo.aggregate(Post, :count) == before
    end

    test "an update is refused with the phrase named, and the post is untouched", ctx do
      {:ok, [post]} =
        AgentDrafts.create_agent_drafts(ctx.scope, ctx.profile.id, %{
          "account_ids" => [ctx.account.id],
          "body" => "A plain update."
        })

      assert {:error, :banned_phrase, "Synergy"} =
               AgentDrafts.update_agent_draft(ctx.scope, post.id, %{"body" => "Real synergy."})

      assert Repo.get!(Post, post.id).body =~ "A plain update."
    end

    test "through the tool, the refusal names the phrase", ctx do
      assert {:error, %{code: :banned_phrase, recoverable: true, error: error}} =
               ToolArguments.dispatch(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.account.id],
                   "body" => "a game changer"
                 },
                 %{agent_id: ctx.agent.id}
               )

      assert error =~ "game changer"
    end

    test "a human writing the same body is not blocked, only flagged", ctx do
      assert {:ok, %Post{}} =
               Social.create_post(ctx.org_id, ctx.account, %{
                 body: "A game changer.",
                 status: "draft"
               })

      flags =
        PlatformLimits.flags("x", %{body: "A game changer.", banned: ctx.profile.voice.banned})

      assert %{key: "banned_phrase", text: text} = Enum.find(flags, &(&1.key == "banned_phrase"))
      assert text =~ "game changer"

      refute Enum.any?(
               PlatformLimits.flags("x", %{body: "A game changer."}),
               &(&1.key == "banned_phrase")
             )
    end
  end

  describe "social_profile_get" do
    test "returns timezone, voice and slots, goal and next free slot per account", ctx do
      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{timezone: "America/Denver"})

      profile = learning!(profile, "Short sentences")

      {:ok, _} =
        Social.update_account_schedule(ctx.org_id, ctx.account, %{
          posting_slots: [%{weekday: 1, time: "09:00"}],
          weekly_goal: 4
        })

      assert {:ok, p} =
               ToolArguments.dispatch(
                 "social_profile_get",
                 %{"profile_id" => profile.id},
                 %{agent_id: ctx.agent.id}
               )

      assert p.timezone == "America/Denver"
      assert p.voice.samples == ["We ship small things often."]
      assert p.voice.banned == ["game changer", "Synergy"]
      assert [%{text: "Short sentences"}] = p.voice.learnings

      assert [account] = p.accounts
      assert account.posting_slots == [%{weekday: 1, time: "09:00"}]
      assert account.weekly_goal == 4
      assert %DateTime{} = account.next_free_slot
      refute Map.has_key?(account, :secret_slug)
    end
  end
end
