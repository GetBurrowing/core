defmodule Platform.Social.IdeaSelectionAgentApiTest do
  @moduledoc """
  What agents see of "Select for research": a read-only `selected` fact and
  filter on `social_idea_list`, full and narrow, with the legacy vote-derived
  shortlist untouched and independent of selection. Agents have no write.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Social.{Idea, IdeaSelectionEvent, IdeaVote, Ideas}

  @narrow_keys ~w(id profile_id title brief source_kind source_url inserted_at board_stage vote_count voted is_mine notes selected)a

  setup do
    ctx = approval_fixture() |> with_ideas_runtime()
    narrow = runtime_ctx(ctx.g, ctx.h1, %{"social.ideas" => "all"})
    Map.merge(ctx, %{narrow_ctx: narrow, full_ctx: ctx.agent_ctx})
  end

  defp runtime_ctx(agent, owner, restrictions) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        runtime_id: "selection-api-#{System.unique_integer([:positive])}",
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active"
      })

    {:ok, _} =
      Platform.Access.RuntimeProfiles.create_for_runtime(runtime, ["social"], restrictions)

    %{agent_id: agent.id, runtime_id: runtime.runtime_id}
  end

  defp list(ctx, who, extra \\ %{}) do
    args = Map.merge(%{"profile_id" => ctx.profile.id}, extra)
    ToolArguments.dispatch("social_idea_list", args, Map.fetch!(ctx, who))
  end

  defp ids!(ctx, who, extra \\ %{}) do
    {:ok, %{ideas: ideas}} = list(ctx, who, extra)
    Enum.map(ideas, & &1.id)
  end

  defp idea!(ctx, title) do
    {:ok, idea} = Ideas.create(ctx.org_id, ctx.profile.id, %{title: title}, {:agent, ctx.g.id})
    idea
  end

  defp vote!(ctx, idea, n) do
    for _ <- 1..n do
      voter = pinned_agent!(ctx.org_id)

      Repo.insert!(%IdeaVote{
        idea_id: idea.id,
        org_id: ctx.org_id,
        profile_id: ctx.profile.id,
        voter_agent_id: voter.id
      })
    end
  end

  defp select!(ctx, idea, user \\ nil) do
    {:ok, _, :changed} =
      Ideas.select_for_research(ctx.org_id, idea.id, {:user, (user || ctx.n).id})
  end

  defp world do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' AND table_name NOT IN ('schema_migrations', 'federation_tool_calls') ORDER BY 1"
      )

    counts =
      for [t] <- tables, into: %{} do
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{t}\"")
        {t, n}
      end

    {counts,
     Repo.all(
       from(i in Idea,
         order_by: i.id,
         select: {i.id, i.updated_at, i.selected_at, i.selected_by_user_id}
       )
     )}
  end

  describe "the selected fact" do
    test "full: selected and selected_at; narrow: selected only, no time and no selector", ctx do
      idea = idea!(ctx, "Plain")
      {:ok, %{ideas: [full]}} = list(ctx, :full_ctx)
      assert %{selected: false, selected_at: nil} = full
      {:ok, %{ideas: [narrow]}} = list(ctx, :narrow_ctx)
      assert %{selected: false} = narrow
      assert MapSet.new(Map.keys(narrow)) == MapSet.new(@narrow_keys)

      select!(ctx, idea, ctx.h2)
      {:ok, %{ideas: [full]}} = list(ctx, :full_ctx)
      assert full.selected == true
      assert %DateTime{} = full.selected_at
      refute Map.has_key?(full, :selected_by_user_id)

      {:ok, %{ideas: [narrow]}} = list(ctx, :narrow_ctx)
      assert narrow.selected == true
      assert MapSet.new(Map.keys(narrow)) == MapSet.new(@narrow_keys)
      refute inspect(narrow) =~ ctx.h2.id
      refute inspect(narrow) =~ "Hugo"
    end

    test "a selected 0-vote idea is inbox; a 3-vote idea is shortlisted and not selected", ctx do
      zero = idea!(ctx, "Zero votes, selected")
      three = idea!(ctx, "Three votes, not selected")
      vote!(ctx, three, 3)
      select!(ctx, zero)

      for who <- [:full_ctx, :narrow_ctx] do
        {:ok, %{ideas: ideas}} = list(ctx, who)
        by = Map.new(ideas, &{&1.id, &1})
        stage = if who == :full_ctx, do: :stage, else: :board_stage
        assert %{selected: true, vote_count: 0} = by[zero.id]
        assert by[zero.id][stage] == "inbox"
        assert %{selected: false, vote_count: 3} = by[three.id]
        assert by[three.id][stage] == "shortlisted"
      end
    end

    test "unselecting returns the fact to false and votes never set it", ctx do
      idea = idea!(ctx, "Toggle")
      vote!(ctx, idea, 4)
      assert [%{selected: false}] = elem(list(ctx, :full_ctx), 1).ideas
      select!(ctx, idea)
      assert [%{selected: true}] = elem(list(ctx, :full_ctx), 1).ideas
      {:ok, _, :changed} = Ideas.unselect_for_research(ctx.org_id, idea.id, {:user, ctx.h1.id})
      assert [%{selected: false, selected_at: nil}] = elem(list(ctx, :full_ctx), 1).ideas
    end
  end

  describe "the selected filter" do
    setup ctx do
      a = idea!(ctx, "A oldest")
      b = idea!(ctx, "B")
      c = idea!(ctx, "C newest")
      select!(ctx, a)
      select!(ctx, c)
      Map.merge(ctx, %{a: a, b: b, c: c})
    end

    test "true, false and absent on both projections", ctx do
      for who <- [:full_ctx, :narrow_ctx] do
        assert Enum.sort(ids!(ctx, who, %{"selected" => true})) == Enum.sort([ctx.a.id, ctx.c.id])
        assert ids!(ctx, who, %{"selected" => false}) == [ctx.b.id]
        assert length(ids!(ctx, who)) == 3
        assert length(ids!(ctx, who, %{"selected" => nil})) == 3
      end
    end

    test "a non-boolean is invalid_argument, on both projections", ctx do
      for who <- [:full_ctx, :narrow_ctx], bad <- ["true", "yes", 1, 0, [], %{}] do
        assert {:error, %{code: :invalid_argument}} = list(ctx, who, %{"selected" => bad})
      end
    end

    test "the boolean is validated only after authority: an unauthorized caller learns nothing",
         ctx do
      Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^ctx.profile.id),
        set: [project_id: nil]
      )

      for who <- [:full_ctx, :narrow_ctx] do
        assert {:error, %{code: code}} = list(ctx, who, %{"selected" => "garbage"})
        assert code == :not_found
      end

      assert {:error, %{code: :not_found}} =
               ToolArguments.dispatch(
                 "social_idea_list",
                 %{"profile_id" => Ecto.UUID.generate(), "selected" => "garbage"},
                 ctx.narrow_ctx
               )
    end

    test "narrow ordering is the vote order and never moves with selection", ctx do
      vote!(ctx, ctx.b, 2)
      before = ids!(ctx, :narrow_ctx)
      assert before == [ctx.b.id, ctx.a.id, ctx.c.id]

      # select and unselect in the opposite order of time and id: nothing moves
      select!(ctx, ctx.b, ctx.h2)
      {:ok, _, :changed} = Ideas.unselect_for_research(ctx.org_id, ctx.a.id, {:user, ctx.h2.id})
      select!(ctx, ctx.a, ctx.h1)
      assert ids!(ctx, :narrow_ctx) == before
      assert ids!(ctx, :narrow_ctx, %{"selected" => true}) == [ctx.b.id, ctx.a.id, ctx.c.id]
      assert ids!(ctx, :full_ctx) == before
    end

    test "the narrow stage filter keeps its meaning beside selected", ctx do
      vote!(ctx, ctx.b, 3)
      assert ids!(ctx, :narrow_ctx, %{"stage" => "shortlisted"}) == [ctx.b.id]
      assert ids!(ctx, :narrow_ctx, %{"stage" => "shortlisted", "selected" => true}) == []

      assert Enum.sort(ids!(ctx, :narrow_ctx, %{"stage" => "inbox", "selected" => true})) ==
               Enum.sort([ctx.a.id, ctx.c.id])
    end
  end

  describe "agents read, never write" do
    test "listing with selected true and false, full and narrow, changes nothing", ctx do
      a = idea!(ctx, "A")
      idea!(ctx, "B")
      select!(ctx, a)
      Phoenix.PubSub.subscribe(Platform.PubSub, Ideas.posts_topic(ctx.profile.id))
      before = {world(), Repo.aggregate(IdeaSelectionEvent, :count)}

      for who <- [:full_ctx, :narrow_ctx], sel <- [true, false, nil] do
        assert {:ok, %{ideas: _}} =
                 list(ctx, who, if(is_nil(sel), do: %{}, else: %{"selected" => sel}))
      end

      assert before == {world(), Repo.aggregate(IdeaSelectionEvent, :count)}
      refute_received {:social_ideas_changed, _}
    end

    test "idea_create carrying selected fields neither sets them nor errors", ctx do
      stolen = DateTime.utc_now()

      args = %{
        "profile_id" => ctx.profile.id,
        "title" => "Sneaky",
        "selected" => true,
        "selected_at" => DateTime.to_iso8601(stolen),
        "selected_by_user_id" => ctx.h1.id
      }

      for who <- [:full_ctx, :narrow_ctx] do
        assert {:ok, %{idea: row}} =
                 ToolArguments.dispatch("social_idea_create", args, Map.fetch!(ctx, who))

        assert row.selected == false
        stored = Repo.get!(Idea, row.id)
        assert {stored.selected_at, stored.selected_by_user_id} == {nil, nil}
      end

      assert Repo.aggregate(IdeaSelectionEvent, :count) == 0
    end

    test "there is no agent tool to select or unselect", ctx do
      idea = idea!(ctx, "Nope")

      for name <- ~w(social_idea_select social_idea_unselect social_idea_select_for_research) do
        result = ToolArguments.dispatch(name, %{"idea_id" => idea.id}, ctx.full_ctx)
        assert match?({:error, _}, result)
      end

      assert is_nil(Repo.get!(Idea, idea.id).selected_at)
    end
  end

  describe "tool text and schema" do
    test "social_idea_list declares a boolean selected filter and says what shortlisted means" do
      def =
        Enum.find(Platform.Social.ToolDefinitions.definitions(), &(&1.name == "social_idea_list"))

      assert %{type: "boolean", required: false} = def.parameters.selected
      assert def.parameters.selected.description =~ "research"
      text = def.description <> def.parameters.stage.description <> def.returns <> def.limitations
      assert text =~ "vote interest"
      assert text =~ ~r/never a human research selection/i
      assert text =~ "selected_at"
      refute text =~ ~r/auto(matic)?(ally)? select/i
    end
  end
end
