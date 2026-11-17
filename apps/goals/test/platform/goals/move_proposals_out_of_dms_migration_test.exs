defmodule Platform.Goals.MoveProposalsOutOfDmsMigrationTest do
  @moduledoc """
  `20261117220000_move_goal_proposals_out_of_dms` and
  `Platform.Goals.Proposals.resend_start_signal/1` (task 01a1eab6 stage 4).

  Migrations run to `:up` before ExUnit boots, so `up/0` cannot be driven
  through `Ecto.Migrator` inside the sandbox transaction. The migration's
  `up/0` is exactly `move_all(repo())`, so these tests drive `move_all/1`
  with `Platform.Repo` (the pattern of
  `Platform.DataMigrations.AgentRuntimeMeetingsBundleTest`).

  The proposals on the DM are inserted directly, the way the code before
  stage 2 left them: `space_id` the person's direct DM, `first_message_id`
  a message in it. The DM holds A and B, then the opening message G, then
  the unrelated C ("you there?") and D. A confirmed proposal from an
  earlier goal opened at A.

  The DM is snapshotted as `row_to_json` text of every row (space,
  participants, messages, message versions) before `up` and compared after,
  so any write to a DM row, of any column, fails the comparison.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.{Proposal, Proposals}
  alias Platform.Repo.Migrations.MoveGoalProposalsOutOfDms

  @now ~U[2026-11-16 09:00:00.000000Z]
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261117220000_move_goal_proposals_out_of_dms.exs",
                    __DIR__
                  )

  setup_all do
    unless Code.ensure_loaded?(MoveGoalProposalsOutOfDms), do: Code.require_file(@migration_path)
    :ok
  end

  setup do
    enable_goals!()

    old = Map.new([:clock_now, :wake_up_dispatcher], &{&1, Application.fetch_env(:goals, &1)})
    parent = self()
    Application.put_env(:goals, :clock_now, fn -> @now end)

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    person = member!(org)
    lead = person |> external_agent!() |> grant_goals_tools!()
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), lead.id)

    {:ok, dm} = Chat.find_or_create_dm(person.id, "agent", lead.id)
    me = participant!(dm.id, "user", person.id)
    agent_p = participant!(dm.id, "agent", lead.id)

    a = post!(dm.id, me, "DM A: an older goal, let's run a 10k")
    b = post!(dm.id, agent_p, "DM B: sounds good")
    g = post!(dm.id, me, "GOAL G: I want to see a theater play this month")
    c_msg = post!(dm.id, agent_p, "DM C: you there?")
    d = post!(dm.id, me, "DM D: unrelated DM chatter")

    open = dm_proposal!(person, lead, org, dm, g, "open")
    confirmed = dm_proposal!(person, lead, org, dm, a, "confirmed")

    # A proposal already in its own surface space, started the stage-2 way.
    other = member!(org)
    {:ok, moved} = Goals.start_goal_conversation(other, "ALREADY-MOVED: read a book a week")
    assert_received {:signal, _}

    # A proposal on a DM with an agent whose runtime lacks the Goals tools.
    third = member!(org)
    toolless = external_agent!(third)
    {:ok, dm3} = Chat.find_or_create_dm(third.id, "agent", toolless.id)
    g3 = post!(dm3.id, participant!(dm3.id, "user", third.id), "GOAL G3: learn to juggle")
    toolless_open = dm_proposal!(third, toolless, org, dm3, g3, "open")

    %{
      org: org,
      person: person,
      lead: lead,
      dm: dm,
      dm3: dm3,
      messages: %{a: a, b: b, g: g, c: c_msg, d: d},
      open: open,
      confirmed: confirmed,
      moved: moved,
      toolless_open: toolless_open
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp external_agent!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-move-#{unique()}",
        display_name: "Goals move test",
        status: "active"
      })

    agent!()
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()
  end

  defp participant!(space_id, type, id),
    do:
      Repo.get_by!(Chat.Participant,
        space_id: space_id,
        participant_type: type,
        participant_id: id
      )

  defp post!(space_id, participant, text) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "text",
        content: text
      })

    msg
  end

  # The pre-stage-2 shape: the proposal's space IS the person's direct DM.
  defp dm_proposal!(user, agent, org, dm, first, status) do
    %Proposal{user_id: user.id, agent_id: agent.id, org_id: org, space_id: dm.id}
    |> Proposal.changeset(%{
      first_message_id: first.id,
      expires_at: DateTime.add(@now, 7 * 86_400, :second)
    })
    |> Ecto.Changeset.change(
      status: status,
      confirmed_at: if(status == "confirmed", do: @now, else: nil)
    )
    |> Repo.insert!()
  end

  defp up!, do: MoveGoalProposalsOutOfDms.move_all(Repo)

  defp row(%Proposal{id: id}), do: Repo.one!(from(p in Proposal, where: p.id == ^id))
  defp space(id), do: Repo.one!(from(s in Chat.Space, where: s.id == ^id))

  defp json_rows(sql, id) do
    %{rows: rows} = Repo.query!(sql, [Ecto.UUID.dump!(id)])
    List.flatten(rows)
  end

  # Every column of every row the DM owns, as text.
  defp dm_snapshot(dm_id) do
    %{
      space: json_rows("SELECT row_to_json(s)::text FROM chat_spaces s WHERE s.id = $1", dm_id),
      participants:
        json_rows(
          "SELECT row_to_json(p)::text FROM chat_participants p WHERE p.space_id = $1 ORDER BY p.id",
          dm_id
        ),
      messages:
        json_rows(
          "SELECT row_to_json(m)::text FROM chat_messages m WHERE m.space_id = $1 ORDER BY m.id",
          dm_id
        ),
      versions:
        json_rows(
          "SELECT row_to_json(v)::text FROM chat_message_versions v " <>
            "JOIN chat_messages m ON m.id = v.message_id WHERE m.space_id = $1 ORDER BY v.id",
          dm_id
        )
    }
  end

  # Every row of every table the migration writes.
  defp world_snapshot do
    for table <-
          ~w(chat_spaces chat_participants chat_messages chat_message_versions goal_proposals),
        into: %{} do
      %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t ORDER BY t.id")
      {table, List.flatten(rows)}
    end
  end

  # ── the move ──────────────────────────────────────────────────────────────

  test "each DM proposal gets its own surface space with the person and the agent", c do
    assert up!() == 3

    for proposal <- [c.open, c.confirmed] do
      moved = row(proposal)
      assert moved.space_id != c.dm.id
      new_space = space(moved.space_id)

      assert new_space.kind == "dm"
      assert new_space.is_direct == false
      assert new_space.name == "New goal"
      assert new_space.created_by == c.person.id
      assert new_space.org_id == c.dm.org_id

      assert new_space.metadata == %{
               "surface" => "goals",
               "migrated_from_space_id" => c.dm.id
             }

      members =
        Repo.all(
          from(p in Chat.Participant,
            where: p.space_id == ^moved.space_id,
            select: {p.participant_type, p.participant_id}
          )
        )

      assert Enum.sort(members) == Enum.sort([{"user", c.person.id}, {"agent", c.lead.id}])

      dm_me = participant!(c.dm.id, "user", c.person.id)
      new_me = participant!(moved.space_id, "user", c.person.id)
      assert new_me.display_name == dm_me.display_name
      assert new_me.attention_mode == dm_me.attention_mode
      assert new_me.joined_at == dm_me.joined_at
    end

    assert row(c.open).space_id != row(c.confirmed).space_id
  end

  test "the goal conversation holds only the copied opening message", c do
    up!()

    assert {:ok, [only]} = Goals.conversation(c.person, c.open.id)
    assert only.content == c.messages.g.content
    assert only.from == :person
    assert only.id == row(c.open).first_message_id
    refute only.id == c.messages.g.id

    copy = Chat.get_message(only.id)
    assert copy.space_id == row(c.open).space_id
    assert copy.metadata["copied_from_message_id"] == c.messages.g.id
    refute Map.has_key?(copy.metadata, "attention")
    assert copy.inserted_at == c.messages.g.inserted_at
    assert copy.author_user_id == c.person.id
    assert copy.participant_id == participant!(copy.space_id, "user", c.person.id).id

    assert [%{version_number: 1, content: content}] =
             Repo.all(from(v in Chat.MessageVersion, where: v.message_id == ^copy.id))

    assert content == c.messages.g.content

    assert {:ok, [earlier]} = Goals.conversation(c.person, c.confirmed.id)
    assert earlier.content == c.messages.a.content
  end

  test "the DM's space, participants, messages and versions are byte-identical", c do
    before = dm_snapshot(c.dm.id)
    assert length(before.messages) == 5
    assert length(before.participants) == 2

    up!()

    assert dm_snapshot(c.dm.id) == before

    assert {:ok, %{id: dm_id}} = Chat.find_or_create_dm(c.person.id, "agent", c.lead.id)
    assert dm_id == c.dm.id
  end

  test "the new space is off the chat rail and the DM is on it", c do
    up!()

    refute Chat.rail_visible?(space(row(c.open).space_id))
    refute Chat.rail_visible?(space(row(c.confirmed).space_id))
    assert Chat.rail_visible?(space(c.dm.id))
  end

  test "a proposal already in its own space is untouched", c do
    before =
      json_rows("SELECT row_to_json(p)::text FROM goal_proposals p WHERE p.id = $1", c.moved.id)

    space_before = dm_snapshot(c.moved.space_id)

    up!()

    assert json_rows(
             "SELECT row_to_json(p)::text FROM goal_proposals p WHERE p.id = $1",
             c.moved.id
           ) ==
             before

    assert dm_snapshot(c.moved.space_id) == space_before
  end

  test "a second up changes nothing" do
    assert up!() == 3
    before = world_snapshot()

    assert up!() == 0
    assert world_snapshot() == before
  end

  test "up broadcasts nothing and fires no chat telemetry", c do
    :ok = Chat.PubSub.subscribe(c.dm.id)
    :ok = Chat.PubSub.subscribe_spaces()

    test_pid = self()
    handler_id = "goals-move-#{unique()}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :chat, :message_posted],
          [:platform, :chat, :space_created],
          [:platform, :chat, :attention_routed],
          [:platform, :chat, :attention_skipped]
        ],
        fn event, _measurements, _meta, _ -> send(test_pid, {:telemetry, event}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Positive control: the probes see an ordinary post.
    post!(c.dm.id, participant!(c.dm.id, "user", c.person.id), "probe")
    assert_receive {:new_message, _}
    assert_receive {:telemetry, [:platform, :chat, :message_posted]}
    flush()

    up!()

    refute_receive {:new_message, _}, 200
    refute_received {:telemetry, _}
    refute_received {:space_created, _}
    refute_received {:signal, _}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  # ── redelivery ────────────────────────────────────────────────────────────

  test "resend_start_signal delivers one new_goal signal with the new space id", c do
    up!()
    new_space_id = row(c.open).space_id

    assert {:ok, %Proposal{id: id, delivery: "sent"}} = Goals.resend_start_signal(c.open.id)
    assert id == c.open.id

    assert_received {:signal, signal}
    assert signal.metadata.responsibility_key == "goals.new_goal"
    assert signal.metadata.space_id == new_space_id
    refute Map.has_key?(signal, :space_id)
    assert signal.metadata.prompt =~ new_space_id
    refute_received {:signal, _}

    assert row(c.open).delivery == "sent"
  end

  test "resend_start_signal refuses a confirmed proposal and sends nothing", c do
    up!()

    assert Proposals.resend_start_signal(c.confirmed.id) == {:error, :proposal_closed}
    refute_received {:signal, _}
  end

  test "resend_start_signal refuses a lead without the Goals tools and sends nothing", c do
    up!()

    assert Proposals.resend_start_signal(c.toolless_open.id) ==
             {:error, :lead_missing_goals_tools}

    refute_received {:signal, _}
    assert row(c.toolless_open).delivery == "pending"
  end

  test "resend_start_signal answers not_found for an unknown or malformed id" do
    assert Proposals.resend_start_signal(Ecto.UUID.generate()) == {:error, :not_found}
    assert Proposals.resend_start_signal("nope") == {:error, :not_found}
    refute_received {:signal, _}
  end

  # ── the file ──────────────────────────────────────────────────────────────

  test "the migration carries the waiver, a no-op down, and is not listed as irreversible" do
    source = File.read!(@migration_path)
    assert source =~ ~r/^[ \t]*# old-code-compatible: \S/m
    assert MoveGoalProposalsOutOfDms.down() == :ok

    listed =
      Path.expand("../../../../../deployment/release/irreversible-migrations.txt", __DIR__)
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    refute "20261117220000" in listed
  end
end
