defmodule Platform.Social.IdeaSelectionTest do
  @moduledoc """
  "Select for research": the human-only writers `Ideas.select_for_research/3`
  and `Ideas.unselect_for_research/3`, their storage, and the rule that
  selection never touches posts, votes or anything else.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Social.{Idea, IdeaSelectionEvent, IdeaVote, Ideas}

  setup do
    ctx = approval_fixture() |> with_ideas_runtime()

    {:ok, idea} =
      Ideas.create(ctx.org_id, ctx.profile.id, %{title: "Research me"}, {:agent, ctx.g.id})

    Phoenix.PubSub.subscribe(Platform.PubSub, Ideas.posts_topic(ctx.profile.id))
    Map.put(ctx, :idea, idea)
  end

  defp events(idea),
    do:
      Repo.all(
        from(e in IdeaSelectionEvent,
          where: e.idea_id == ^idea.id,
          order_by: [asc: e.inserted_at, asc: e.id]
        )
      )

  defp fresh(idea), do: Repo.get!(Idea, idea.id)

  # Every table's row count except the two this feature may write.
  defp world do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE' ORDER BY 1"
      )

    for [t] <- tables,
        t not in ["social_ideas", "social_idea_selection_events", "schema_migrations"],
        into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{t}\"")
      {t, n}
    end
  end

  describe "select_for_research/3" do
    test "records who and when, one event, and broadcasts once", ctx do
      assert {:ok, %Idea{} = idea, :changed} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert idea.selected_by_user_id == ctx.n.id
      assert %DateTime{} = idea.selected_at
      assert fresh(ctx.idea).selected_at == idea.selected_at

      assert [%IdeaSelectionEvent{action: "selected", actor_kind: "human", actor_id: actor}] =
               events(ctx.idea)

      assert actor == ctx.n.id
      profile_id = ctx.profile.id
      assert_received {:social_ideas_changed, ^profile_id}
      refute_received {:social_ideas_changed, _}
    end

    test "a repeat is :unchanged: no write, no event, no broadcast", ctx do
      {:ok, first, :changed} =
        Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert_received {:social_ideas_changed, _}
      before = {world(), fresh(ctx.idea)}

      assert {:ok, again, :unchanged} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert again.selected_by_user_id == ctx.h1.id
      assert again.selected_at == first.selected_at
      assert before == {world(), fresh(ctx.idea)}
      assert length(events(ctx.idea)) == 1
      refute_received {:social_ideas_changed, _}
    end

    test "unselect clears the marker, appends its own event; anyone authorized may", ctx do
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert {:ok, idea, :changed} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert {idea.selected_at, idea.selected_by_user_id} == {nil, nil}

      assert [{"selected", h1}, {"unselected", n}] =
               Enum.map(events(ctx.idea), &{&1.action, &1.actor_id})

      assert {h1, n} == {ctx.h1.id, ctx.n.id}
    end

    test "unselecting an idea that is not selected is :unchanged with no event", ctx do
      assert {:ok, _, :unchanged} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert events(ctx.idea) == []
    end

    test "select and unselect alternate strictly in the event log", ctx do
      for _ <- 1..3 do
        {:ok, _, :changed} =
          Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

        {:ok, _, :unchanged} =
          Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

        {:ok, _, :changed} =
          Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h2.id})
      end

      assert Enum.map(events(ctx.idea), & &1.action) ==
               Enum.flat_map(1..3, fn _ -> ~w(selected unselected) end)
    end

    test "touches nothing else: no posts, tasks, messages, jobs, inbox items or post events",
         ctx do
      before = world()
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})
      assert world() == before
      {:ok, _, :changed} = Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})
      assert world() == before
    end

    test "votes and selection are independent in both directions", ctx do
      voter = pinned_agent!(ctx.org_id)

      Repo.insert!(%IdeaVote{
        idea_id: ctx.idea.id,
        org_id: ctx.org_id,
        profile_id: ctx.profile.id,
        voter_agent_id: voter.id
      })

      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})
      assert Repo.aggregate(from(v in IdeaVote, where: v.idea_id == ^ctx.idea.id), :count) == 1
      {:ok, _, :changed} = Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})
      assert Repo.aggregate(from(v in IdeaVote, where: v.idea_id == ^ctx.idea.id), :count) == 1

      three = for _ <- 1..2, do: pinned_agent!(ctx.org_id)

      for a <- three,
          do:
            Repo.insert!(%IdeaVote{
              idea_id: ctx.idea.id,
              org_id: ctx.org_id,
              profile_id: ctx.profile.id,
              voter_agent_id: a.id
            })

      assert is_nil(fresh(ctx.idea).selected_at)
    end
  end

  describe "authority" do
    test "an agent is refused before any state is read", ctx do
      for fun <- [:select_for_research, :unselect_for_research] do
        assert {:error, :not_a_human} =
                 apply(Ideas, fun, [ctx.org_id, ctx.idea.id, {:agent, ctx.g.id}])

        assert {:error, :not_a_human} =
                 apply(Ideas, fun, [ctx.org_id, "not-even-an-id", {:agent, ctx.g.id}])

        assert {:error, :not_a_human} = apply(Ideas, fun, [ctx.org_id, ctx.idea.id, nil])

        assert {:error, :not_a_human} =
                 apply(Ideas, fun, [ctx.org_id, ctx.idea.id, {:system, ctx.h1.id}])
      end

      assert events(ctx.idea) == []
    end

    test "a user id that is not a live user is refused, as is an archived one", ctx do
      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, Ecto.UUID.generate()})

      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, "nope"})

      Repo.update_all(from(u in Platform.Accounts.User, where: u.id == ^ctx.n.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert events(ctx.idea) == []
    end

    test "a user outside the brand's org is refused", ctx do
      stranger = user!()

      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, stranger.id})
    end

    test "a project-level deny of social.use refuses, and authority comes before :unchanged",
         ctx do
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, ctx.n.id},
          permission: "social.use",
          resource: {:project, ctx.profile.project_id}
        })

      before = {world(), fresh(ctx.idea), events(ctx.idea)}

      # The idea IS selected, so a repeat select would be :unchanged for an authorized caller.
      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert {:error, :not_authorized} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.n.id})

      assert before == {world(), fresh(ctx.idea), events(ctx.idea)}
    end

    test "unselecting something not selected also refuses an unauthorized caller", ctx do
      stranger = user!()

      assert {:error, :not_authorized} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, stranger.id})
    end

    test "a profile with no live project refuses", ctx do
      Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^ctx.profile.id),
        set: [project_id: nil]
      )

      assert {:error, :not_authorized} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})
    end

    test "a missing, malformed or other-org idea is :not_found", ctx do
      assert {:error, :not_found} =
               Ideas.select_for_research(ctx.org_id, Ecto.UUID.generate(), {:user, ctx.h1.id})

      assert {:error, :not_found} = Ideas.select_for_research(ctx.org_id, "x", {:user, ctx.h1.id})

      assert {:error, :not_found} =
               Ideas.select_for_research(org_id!(), ctx.idea.id, {:user, ctx.h1.id})
    end

    test "the writers are not agent tools", _ctx do
      names = Platform.Social.ToolDefinitions.definitions() |> Enum.map(& &1.name)
      refute Enum.any?(names, &(&1 =~ "select"))
    end
  end

  describe "archive" do
    test "an archived idea refuses select and unselect with :idea_archived", ctx do
      {:ok, _} = Ideas.archive(ctx.org_id, ctx.idea.id)

      assert {:error, :idea_archived} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert {:error, :idea_archived} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert events(ctx.idea) == []
    end

    test "archiving a selected idea keeps the selection fields and events", ctx do
      {:ok, sel, :changed} =
        Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      {:ok, _} = Ideas.archive(ctx.org_id, ctx.idea.id)
      kept = fresh(ctx.idea)
      assert {kept.selected_at, kept.selected_by_user_id} == {sel.selected_at, ctx.h1.id}
      assert length(events(ctx.idea)) == 1
    end
  end

  describe "selector deletion" do
    test "the idea stays selected, the event keeps the actor id", ctx do
      selector = named_user!("Short Lived")
      member!(selector, ctx.org_id)

      {:ok, sel, :changed} =
        Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, selector.id})

      Repo.query!("DELETE FROM org_memberships WHERE user_id = $1", [Ecto.UUID.dump!(selector.id)])

      Repo.delete!(selector)

      kept = fresh(ctx.idea)
      assert kept.selected_at == sel.selected_at
      assert kept.selected_by_user_id == nil
      assert [%{actor_id: actor}] = events(ctx.idea)
      assert actor == selector.id

      # still a valid row: a later authorized select is :unchanged, unselect works
      assert {:ok, _, :unchanged} =
               Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert {:ok, cleared, :changed} =
               Ideas.unselect_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})

      assert cleared.selected_at == nil
    end
  end

  describe "storage" do
    test "the selection fields are not castable", ctx do
      now = DateTime.utc_now()

      for attrs <- [
            %{"title" => "x", "selected_at" => now, "selected_by_user_id" => ctx.h1.id},
            %{title: "x", selected_at: now, selected_by_user_id: ctx.h1.id}
          ] do
        cs = Idea.changeset(%Idea{}, attrs, {:user, ctx.h1.id})
        refute Map.has_key?(cs.changes, :selected_at)
        refute Map.has_key?(cs.changes, :selected_by_user_id)
        assert Map.has_key?(cs.changes, :title)
      end
    end

    test "the database refuses a selector without a time", ctx do
      assert_raise Postgrex.Error, ~r/social_ideas_selector_needs_time_check/, fn ->
        Repo.update_all(from(i in Idea, where: i.id == ^ctx.idea.id),
          set: [selected_by_user_id: ctx.h1.id]
        )
      end
    end

    test "event checks: action, actor_kind, idea and actor required", ctx do
      insert = fn attrs ->
        Repo.insert!(
          struct(
            IdeaSelectionEvent,
            Map.merge(
              %{
                idea_id: ctx.idea.id,
                action: "selected",
                actor_kind: "human",
                actor_id: ctx.h1.id
              },
              attrs
            )
          )
        )
      end

      assert_raise Ecto.ConstraintError, ~r/idea_selection_events_action_check/, fn ->
        insert.(%{action: "approved"})
      end

      assert_raise Ecto.ConstraintError, ~r/idea_selection_events_actor_kind_check/, fn ->
        insert.(%{actor_kind: "agent"})
      end

      assert_raise Postgrex.Error, ~r/null value/, fn -> insert.(%{idea_id: nil}) end
      assert_raise Postgrex.Error, ~r/null value/, fn -> insert.(%{actor_id: nil}) end
      assert %IdeaSelectionEvent{} = insert.(%{actor_id: Ecto.UUID.generate()})
    end

    test "events follow their idea on delete (CASCADE) and have an (idea_id, inserted_at) index",
         ctx do
      {:ok, _, :changed} = Ideas.select_for_research(ctx.org_id, ctx.idea.id, {:user, ctx.h1.id})
      Repo.delete!(Repo.get!(Idea, ctx.idea.id))
      assert events(ctx.idea) == []

      %{rows: [[def]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'social_idea_selection_events' AND indexdef ILIKE '%(idea_id, inserted_at)%'"
        )

      assert def =~ "idea_id"
    end

    test "events have inserted_at and no updated_at", _ctx do
      assert :inserted_at in IdeaSelectionEvent.__schema__(:fields)
      refute :updated_at in IdeaSelectionEvent.__schema__(:fields)
    end
  end
end
