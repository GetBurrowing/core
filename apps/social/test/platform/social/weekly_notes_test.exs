defmodule Platform.Social.WeeklyNotesTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures
  import Platform.SocialComposerFixtures
  alias Platform.Social
  alias Platform.Social.{WeeklyNotes, Tools, Voice, Slots, Idea, Ideas}
  @week ~D[2026-10-26]
  @now ~U[2026-10-28 12:00:00.000000Z]

  setup do
    c = approval_fixture()
    agent = pinned_agent!(c.org_id)
    profile = c.profile |> Ecto.Changeset.change(drafting_agent_id: agent.id) |> Repo.update!()

    approved_post!(c.org_id, c.a)
    |> Ecto.Changeset.change(status: "published", published_at: ~U[2026-10-21 12:00:00.000000Z])
    |> Repo.update!()

    Map.merge(c, %{agent: agent, profile: profile})
  end

  defp voice,
    do: %{
      kind: "voice",
      text: "Questions worked",
      payload: %{text: "Ask a concrete question before the announcement."}
    }

  defp timing(c),
    do: %{
      kind: "timing",
      text: "Try Tuesday",
      payload: %{account_id: c.a.id, weekday: 2, time: "14:00"}
    }

  defp submit(c, items) do
    {:ok, note} =
      WeeklyNotes.submit(
        c.org_id,
        c.profile.id,
        @week,
        "Audience learning",
        items,
        {:agent, c.agent.id}
      )

    note
  end

  defp use_item(c, note, opts \\ []),
    do:
      WeeklyNotes.decide(
        c.org_id,
        note.id,
        hd(note.items).id,
        "use",
        c.h1.id,
        [now: @now] ++ opts
      )

  defp undo(c, note, opts \\ []),
    do: WeeklyNotes.undo(c.org_id, note.id, hd(note.items).id, c.h1.id, [now: @now] ++ opts)

  test "voice use reaches profile tool and actual stubbed composer prompt once, undo preserves other learnings",
       c do
    note = submit(c, [voice()])
    assert Voice.of(Repo.reload!(c.profile)).learnings == []
    assert {:ok, used} = use_item(c, note)
    assert {:ok, _} = use_item(c, note)
    [learning] = Voice.of(Repo.reload!(c.profile)).learnings
    assert learning.text == "Ask a concrete question before the announcement."
    assert learning.source_note_id == note.id
    assert hd(used.items).decided_by_user_id == c.h1.id

    assert {:ok, json} =
             Tools.execute("social_profile_get", %{"profile_id" => c.profile.id}, %{
               agent_id: c.agent.id
             })

    assert inspect(json) =~ "Ask a concrete question before the announcement."
    restore = use_llm_stub!()
    on_exit(restore)
    drafter = composer_agent!()
    profile = c.profile |> Ecto.Changeset.change(drafting_agent_id: drafter.id) |> Repo.update!()
    stub_llm!()

    assert {:ok, _} =
             Social.Composer.adapt_one(Repo.reload!(profile), "linkedin", %{idea: "Launch"})

    assert_receive {:llm, "linkedin", _, prompt}
    assert prompt =~ "Ask a concrete question before the announcement."
    other = %Social.VoiceLearning{id: Ecto.UUID.generate(), text: "Keep this unrelated learning"}
    profile = Repo.reload!(profile)

    voice = %{learnings: [learning, other]}

    profile
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:voice, voice)
    |> Repo.update!()

    assert {:ok, _} = undo(c, note)

    assert Enum.map(Voice.of(Repo.reload!(profile)).learnings, & &1.text) == [
             "Keep this unrelated learning"
           ]
  end

  test "timing requires confirmation, adds validated slot, next_free reads it, undo preserves preexisting",
       c do
    {:ok, _} =
      Social.update_account_schedule(c.org_id, c.a, %{
        posting_slots: [%{weekday: 4, time: "10:00"}]
      })

    note = submit(c, [timing(c)])
    assert {:error, :confirmation_required} = use_item(c, note)
    assert {:ok, _} = use_item(c, note, confirmed: true)

    assert Slots.next_free(Repo.reload!(c.a), ~U[2026-10-26 00:00:00Z]) ==
             ~U[2026-10-27 14:00:00Z]

    assert {:ok, _} = undo(c, note)
    assert [%{weekday: 4, time: "10:00"}] = Repo.reload!(c.a).posting_slots
  end

  test "a preexisting suggested slot survives undo", c do
    {:ok, _} =
      Social.update_account_schedule(c.org_id, c.a, %{
        posting_slots: [%{weekday: 2, time: "14:00"}]
      })

    note = submit(c, [timing(c)])
    assert {:ok, _} = use_item(c, note, confirmed: true)
    assert {:ok, _} = undo(c, note)
    assert [%{weekday: 2, time: "14:00"}] = Repo.reload!(c.a).posting_slots
  end

  test "downstream slot edits refuse undo atomically without deleting unrelated schedule", c do
    note = submit(c, [timing(c)])
    assert {:ok, _} = use_item(c, note, confirmed: true)

    {:ok, account} =
      Social.update_account_schedule(c.org_id, c.a, %{
        posting_slots: [%{weekday: 2, time: "15:00"}, %{weekday: 5, time: "12:00"}]
      })

    assert {:error, :effect_changed} = undo(c, note)
    assert Repo.reload!(c.a).posting_slots == account.posting_slots
    assert hd(Repo.reload!(note).items).decision == "use"
  end

  test "ignore affects decision only and same-week undo clears it; next local week is expired",
       c do
    note = submit(c, [voice(), timing(c)])
    before_profile = Repo.reload!(c.profile)
    before_account = Repo.reload!(c.a)

    assert {:ok, ignored} =
             WeeklyNotes.decide(c.org_id, note.id, hd(note.items).id, "ignore", c.h1.id,
               now: @now
             )

    assert hd(ignored.items).decision == "ignore"
    assert Repo.reload!(c.profile) == before_profile
    assert Repo.reload!(c.a) == before_account

    assert {:error, :undo_expired} =
             WeeklyNotes.undo(c.org_id, note.id, hd(note.items).id, c.h1.id,
               now: ~U[2026-11-02 00:00:00Z]
             )

    assert {:ok, undone} = undo(c, note)
    assert hd(undone.items).decision == nil
  end

  test "forged requests reauthorize fresh approver membership and scoped profile", c do
    note = submit(c, [voice()])

    assert {:error, :not_an_approver} =
             WeeklyNotes.decide(c.org_id, note.id, hd(note.items).id, "use", c.n.id)

    assert {:error, _} = WeeklyNotes.decide(org_id!(), note.id, hd(note.items).id, "use", c.h1.id)
    c.profile |> Ecto.Changeset.change(approver_user_ids: []) |> Repo.update!()
    assert {:error, :not_an_approver} = use_item(c, note)
    assert hd(Repo.reload!(note).items).decision == nil
    assert Voice.of(Repo.reload!(c.profile)).learnings == []
  end

  test "tools require assigned agent and reject foreign items and forged decisions; list exposes trusted state",
       c do
    other = pinned_agent!(c.org_id)
    ctx = %{agent_id: c.agent.id}

    args = %{
      "profile_id" => c.profile.id,
      "week_start" => "2026-10-26",
      "summary" => "Learning",
      "items" => [voice()]
    }

    assert {:error, _} = Tools.execute("social_weekly_note_submit", args, %{agent_id: other.id})

    assert {:error, _} =
             Tools.execute("social_weekly_note_submit", args, %{
               agent_id: pinned_agent!(org_id!()).id
             })

    assert {:error, _} =
             Tools.execute(
               "social_weekly_note_submit",
               Map.put(args, "items", [Map.put(voice(), :decision, "use")]),
               ctx
             )

    {foreign, account} = social_account!(c.org_id, "x")
    {:ok, idea} = Ideas.create(c.org_id, foreign.id, %{title: "Foreign"}, {:user, c.h1.id})

    for item <- [
          %{
            kind: "timing",
            text: "Bad",
            payload: %{account_id: account.id, weekday: 2, time: "14:00"}
          },
          %{kind: "recycle", text: "Bad", payload: %{idea_id: idea.id}}
        ] do
      assert {:error, _} =
               Tools.execute("social_weekly_note_submit", Map.put(args, "items", [item]), ctx)
    end

    assert {:ok, json} = Tools.execute("social_weekly_note_submit", args, ctx)
    assert json.author_id == c.agent.id
    assert {:ok, _} = WeeklyNotes.decide(c.org_id, json.id, hd(json.items).id, "ignore", c.h1.id)

    assert {:ok, %{notes: [listed]}} =
             Tools.execute("social_weekly_note_list", %{"profile_id" => c.profile.id}, ctx)

    assert hd(listed.items).decision == "ignore"
    refute Map.has_key?(hd(listed.items), :effect)
  end

  test "recycle delegates existing eligibility, creates only one child, refuses edited child undo",
       c do
    source =
      Repo.insert!(%Idea{
        org_id: c.org_id,
        profile_id: c.profile.id,
        title: "Old winner",
        source_kind: "human",
        created_by_user_id: c.h1.id
      })

    approved_post!(c.org_id, c.a)
    |> Ecto.Changeset.change(
      status: "published",
      idea_id: source.id,
      published_at: DateTime.add(DateTime.utc_now(), -40, :day),
      metrics: %{"likes" => 20},
      metrics_synced_at: DateTime.utc_now()
    )
    |> Repo.update!()

    note = submit(c, [%{kind: "recycle", text: "Recycle winner", payload: %{idea_id: source.id}}])
    assert {:ok, used} = use_item(c, note)
    assert {:ok, _} = use_item(c, note)
    child = Repo.get!(Idea, hd(used.items).effect["id"])
    assert child.recycled_from_idea_id == source.id
    assert Ideas.posts(child) == []
    child |> Ecto.Changeset.change(title: "Human edit") |> Repo.update!()
    assert {:error, :effect_changed} = undo(c, note)
    assert Repo.get!(Idea, child.id).title == "Human edit"
  end

  test "unedited recycled child undo removes only the new child and its reference notes", c do
    source =
      Repo.insert!(%Idea{
        org_id: c.org_id,
        profile_id: c.profile.id,
        title: "Old winner",
        source_kind: "human",
        created_by_user_id: c.h1.id
      })

    approved_post!(c.org_id, c.a)
    |> Ecto.Changeset.change(
      status: "published",
      idea_id: source.id,
      published_at: DateTime.add(DateTime.utc_now(), -40, :day),
      metrics: %{"likes" => 20},
      metrics_synced_at: DateTime.utc_now()
    )
    |> Repo.update!()

    note = submit(c, [%{kind: "recycle", text: "Recycle", payload: %{idea_id: source.id}}])
    assert {:ok, used} = use_item(c, note)
    child_id = hd(used.items).effect["id"]
    assert {:ok, _} = undo(c, note)
    assert Repo.get(Idea, child_id) == nil
    assert Repo.get(Idea, source.id)
  end

  test "archived approver cannot use or undo and informational use has no side effect", c do
    note = submit(c, [%{kind: "other", text: "Read the replies", payload: %{}}])
    before_profile = Repo.reload!(c.profile)
    assert {:ok, used} = use_item(c, note)
    assert hd(used.items).effect == %{}
    assert Repo.reload!(c.profile) == before_profile
    c.h1 |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
    assert {:error, :approver_archived} = undo(c, note)
    assert hd(Repo.reload!(note).items).decision == "use"
  end

  defp unboxed(fun),
    do:
      Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)

  test "independent concurrent use requests serialize and persist one learning" do
    c =
      unboxed(fn ->
        c = approval_fixture()
        agent = pinned_agent!(c.org_id)

        profile =
          c.profile |> Ecto.Changeset.change(drafting_agent_id: agent.id) |> Repo.update!()

        approved_post!(c.org_id, c.a)
        |> Ecto.Changeset.change(
          status: "published",
          published_at: ~U[2026-10-21 12:00:00.000000Z]
        )
        |> Repo.update!()

        c = Map.merge(c, %{agent: agent, profile: profile})
        Map.put(c, :note, submit(c, [voice()]))
      end)

    on_exit(fn ->
      unboxed(fn ->
        import Ecto.Query
        Repo.delete_all(from(p in Social.Profile, where: p.id == ^c.profile.id))
        Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^c.space.id))
        Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id in ^[c.agent.id, c.g.id]))

        Repo.delete_all(
          from(u in Platform.Accounts.User, where: u.id in ^[c.h1.id, c.h2.id, c.n.id])
        )

        Repo.delete_all(from(o in Platform.Tenancy.Org, where: o.id == ^c.org_id))
      end)
    end)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> use_item(c, c.note)
            after
              5000 -> raise "concurrency barrier timeout"
            end
          end)
        end)
      end

    for _ <- 1..2 do
      assert_receive {:ready, pid}, 5000
      send(pid, :go)
    end

    for task <- tasks, do: assert({:ok, _} = Task.await(task, 10000))

    unboxed(fn ->
      assert length(Voice.of(Repo.reload!(c.profile)).learnings) == 1
      assert hd(Repo.reload!(c.note).items).decision == "use"
    end)
  end
end
