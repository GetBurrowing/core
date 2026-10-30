defmodule Platform.Social.WeeklyNoteSweepTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Social.{
    WeeklyNoteSweep,
    WeeklyNotes,
    WeeklyNote,
    WeeklyNoteRequest,
    WeeklyNotePrompts
  }

  @week ~D[2026-10-26]
  @now ~U[2026-10-26 09:00:00.000000Z]
  defmodule Provider do
    def chat(_, messages, _) do
      send(Process.get(:weekly_test), {:prompt, messages})

      {:ok,
       %{
         content:
           Process.get(
             :weekly_output,
             ~s({"summary":"Measured weekly note","items":[{"kind":"voice","text":"Questions worked","payload":{"text":"Ask a question"}}]})
           )
       }}
    end
  end

  setup do
    c = approval_fixture()

    approved_post!(c.org_id, c.a)
    |> Ecto.Changeset.change(status: "published", published_at: ~U[2026-10-21 12:00:00.000000Z])
    |> Repo.update!()

    Process.put(:weekly_test, self())
    c
  end

  defp messages(c),
    do:
      Platform.Chat.list_messages(c.space.id)
      |> Enum.filter(&Map.has_key?(&1.metadata, "idempotency_key"))

  defp system(c),
    do: WeeklyNoteSweep.deliver(c.profile, @week, @now, agent: %{}, provider: Provider)

  test "one actual agent mention survives restarted workers before submit; final link is once",
       c do
    agent = Platform.SocialFixtures.pinned_agent!(c.org_id)
    p = c.profile |> Ecto.Changeset.change(drafting_agent_id: agent.id) |> Repo.update!()
    assert {:ok, :sent} = WeeklyNoteSweep.deliver(p, @week, @now)
    assert {:ok, :already_sent} = WeeklyNoteSweep.deliver(p, @week, @now)
    [request] = messages(c)
    assert request.content =~ "@[#{agent.name}]"
    assert request.content =~ "weekly_note_target=facts"
    assert request.content =~ "[measured facts]("

    assert Enum.any?(
             Platform.Chat.list_participants(c.space.id),
             &(&1.participant_type == "agent" and &1.participant_id == agent.id)
           )

    assert {:ok, _} =
             WeeklyNotes.submit(
               c.org_id,
               p.id,
               @week,
               "Human-directed note",
               [],
               {:agent, agent.id}
             )

    assert {:ok, :already_sent} = WeeklyNoteSweep.deliver(p, @week, @now)
    assert {:ok, :already_sent} = WeeklyNoteSweep.deliver(p, @week, @now)
    assert length(messages(c)) == 2
    assert Enum.any?(messages(c), &String.starts_with?(&1.content, "[Review weekly note]("))
    refute_received {:prompt, _}
  end

  test "system ToollessChat uses editable row, validates output, retries and labels authorship",
       c do
    template =
      Platform.Orchestration.PromptTemplates.get_template_by_slug(WeeklyNotePrompts.slug())

    template |> Ecto.Changeset.change(content: "Operator prompt {{facts}}") |> Repo.update!()

    Process.put(
      :weekly_output,
      ~s({"summary":"bad","items":[{"kind":"timing","text":"bad","payload":{"account_id":"00000000-0000-0000-0000-000000000000","weekday":2,"time":"14:00"}}]})
    )

    assert {:error, _} = system(c)
    assert Repo.aggregate(WeeklyNote, :count) == 0
    assert messages(c) == []
    Process.delete(:weekly_output)
    assert {:ok, :sent} = system(c)
    [note] = WeeklyNotes.list(c.org_id, c.profile.id)
    assert note.author_kind == "system"
    assert note.author_id == nil
    assert hd(note.items).decision == nil
    assert_receive {:prompt, [%{content: prompt}]}
    assert String.starts_with?(prompt, "Operator prompt")
    assert {:ok, :already_sent} = system(c)
    assert length(messages(c)) == 1
  end

  test "empty reporting week creates no request message or completion", c do
    assert {:ok, :empty} =
             WeeklyNoteSweep.deliver(c.profile, ~D[2026-11-09], @now,
               agent: %{},
               provider: Provider
             )

    assert Repo.aggregate(WeeklyNoteRequest, :count) == 0
    assert messages(c) == []
    refute_received {:prompt, _}
  end

  test "09:00 local boundary, DST and catch-up use local delivery Monday" do
    p = %Platform.Social.Profile{timezone: "America/New_York"}
    assert WeeklyNoteSweep.due_week(p, ~U[2026-11-02 13:59:59Z]) == nil
    assert WeeklyNoteSweep.due_week(p, ~U[2026-11-02 14:00:00Z]) == ~D[2026-11-02]
    assert WeeklyNoteSweep.due_week(p, ~U[2026-11-04 03:00:00Z]) == ~D[2026-11-02]
    p = %{p | timezone: "Asia/Tokyo"}
    assert WeeklyNoteSweep.due_week(p, ~U[2026-11-02 00:00:00Z]) == ~D[2026-11-02]
  end

  test "expired generation claim recovers while live claim prevents duplicate call", c do
    Repo.insert!(%WeeklyNoteRequest{
      profile_id: c.profile.id,
      week_start: @week,
      claim_token: Ecto.UUID.generate(),
      claim_until: DateTime.add(@now, 30)
    })

    assert {:ok, :busy} = system(c)
    refute_received {:prompt, _}

    assert {:ok, :sent} =
             WeeklyNoteSweep.deliver(c.profile, @week, DateTime.add(@now, 31),
               agent: %{},
               provider: Provider
             )
  end

  test "non-production application worker has no timers" do
    assert Application.get_env(:social, :weekly_note_sweep)[:start] == false
    pid = start_supervised!({WeeklyNoteSweep, name: :weekly_disabled, start: false})
    assert :sys.get_state(pid)[:start] == false
    assert Process.info(pid, :messages) == {:messages, []}
  end

  test "independent concurrent sweep deliveries commit exactly one request" do
    unboxed = fn fun ->
      Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)
    end

    c =
      unboxed.(fn ->
        c = approval_fixture()
        a = pinned_agent!(c.org_id)
        p = c.profile |> Ecto.Changeset.change(drafting_agent_id: a.id) |> Repo.update!()

        approved_post!(c.org_id, c.a)
        |> Ecto.Changeset.change(
          status: "published",
          published_at: ~U[2026-10-21 12:00:00.000000Z]
        )
        |> Repo.update!()

        %{c | profile: p}
      end)

    tasks =
      for _ <- 1..3,
          do:
            Task.async(fn ->
              unboxed.(fn -> WeeklyNoteSweep.deliver(c.profile, @week, @now) end)
            end)

    results = Enum.map(tasks, &Task.await(&1, 20_000))
    assert Enum.count(results, &(&1 == {:ok, :sent})) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:ok, :already_sent})) == 2
    assert length(unboxed.(fn -> messages(c) end)) == 1
    # A new process after the concurrent send must read the durable bit.
    task =
      Task.async(fn -> unboxed.(fn -> WeeklyNoteSweep.deliver(c.profile, @week, @now) end) end)

    assert Task.await(task) == {:ok, :already_sent}
    unboxed.(fn -> Repo.delete!(Repo.reload!(c.profile)) end)
  end
end
