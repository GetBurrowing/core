defmodule Platform.Goals.OpsTest do
  @moduledoc """
  `Platform.Goals.Ops`, the operator-only home of `resend_start_signal/1`
  (task 01a1eb3f stage 2). The setup mirrors
  `Platform.Goals.MoveProposalsOutOfDmsMigrationTest`: an open proposal on the
  person's DM, moved into its own space by
  `20261117220000_move_goal_proposals_out_of_dms` (`move_all/1`).

  The boundary assertions pin the move: the function is gone from
  `Platform.Goals` (so the revoked and disabled sweeps cannot reach it), only
  `ops.ex` calls `Proposals.resend_start_signal`, and no web or tools module
  names `Goals.Ops`.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals.{Ops, Proposal}
  alias Platform.Repo.Migrations.MoveGoalProposalsOutOfDms

  @now ~U[2026-11-16 09:00:00.000000Z]
  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261117220000_move_goal_proposals_out_of_dms.exs",
                    __DIR__
                  )
  @apps_root Path.expand("../../../..", __DIR__)

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
    g = post!(dm.id, me, "GOAL G: I want to see a theater play this month")
    open = dm_proposal!(person, lead, org, dm, g)

    assert MoveGoalProposalsOutOfDms.move_all(Repo) == 1
    moved = row(open)
    refute moved.space_id == dm.id

    %{open: moved}
  end

  # ── the command ───────────────────────────────────────────────────────────

  test "an open migrated proposal gets exactly one new_goal signal with its space id", c do
    assert {:ok, %Proposal{id: id, delivery: "sent"}} = Ops.resend_start_signal(c.open.id)
    assert id == c.open.id

    assert_received {:signal, signal}
    assert signal.metadata.responsibility_key == "goals.new_goal"
    assert signal.metadata.space_id == c.open.space_id
    refute_received {:signal, _}

    assert row(c.open).delivery == "sent"
  end

  test "the resent new_goal prompt points at opening_message and carries no opening text", c do
    assert {:ok, %Proposal{delivery: "sent"}} = Ops.resend_start_signal(c.open.id)

    assert_received {:signal, signal}
    assert signal.metadata.prompt =~ "goal_proposal_get's opening_message"
    assert signal.metadata.prompt =~ "answer what they already wrote"
    refute inspect(signal) =~ "GOAL G"
    refute inspect(signal) =~ "theater play"
  end

  test "with Goals disabled it answers goals_disabled, sends nothing and changes no row", c do
    before = proposal_json(c.open.id)
    Application.put_env(:goals, :enabled, false)

    assert Ops.resend_start_signal(c.open.id) == {:error, :goals_disabled}
    assert Ops.resend_start_signal("nope") == {:error, :goals_disabled}

    refute_received {:signal, _}
    assert proposal_json(c.open.id) == before
  end

  test "an unknown or malformed id answers not_found and sends nothing" do
    assert Ops.resend_start_signal(Ecto.UUID.generate()) == {:error, :not_found}
    assert Ops.resend_start_signal("nope") == {:error, :not_found}
    refute_received {:signal, _}
  end

  # ── the boundary ──────────────────────────────────────────────────────────

  test "Platform.Goals no longer exports resend_start_signal" do
    assert Code.ensure_loaded?(Platform.Goals)
    refute function_exported?(Platform.Goals, :resend_start_signal, 1)
    assert function_exported?(Ops, :resend_start_signal, 1)
  end

  test "only ops.ex calls Proposals.resend_start_signal, and no web or tools module names Goals.Ops" do
    files = lib_files()
    # Positive control: the scan reads both apps' lib trees and ops.ex itself.
    assert Enum.any?(files, &String.ends_with?(&1, "apps/goals/lib/platform/goals/ops.ex"))
    assert Enum.any?(files, &String.contains?(&1, "apps/platform/lib/platform_web/"))

    callers = for f <- files, File.read!(f) =~ "Proposals.resend_start_signal", do: rel(f)
    assert callers == ["goals/lib/platform/goals/ops.ex"]

    ops_refs = for f <- files, File.read!(f) =~ "Goals.Ops", do: rel(f)
    assert "goals/lib/platform/goals/ops.ex" in ops_refs

    assert Enum.filter(ops_refs, &web_or_tools?/1) == []
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp lib_files do
    for app <- ["goals", "platform"],
        file <- Path.wildcard(Path.join([@apps_root, app, "lib", "**", "*.{ex,exs,heex}"])),
        do: file
  end

  defp rel(file), do: Path.relative_to(file, @apps_root)

  defp web_or_tools?(rel) do
    String.contains?(rel, "_web/") or Path.basename(rel) =~ ~r/tool/ or
      String.contains?(rel, "/tools/")
  end

  defp external_agent!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-ops-#{unique()}",
        display_name: "Goals ops test",
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
  defp dm_proposal!(user, agent, org, dm, first) do
    %Proposal{user_id: user.id, agent_id: agent.id, org_id: org, space_id: dm.id}
    |> Proposal.changeset(%{
      first_message_id: first.id,
      expires_at: DateTime.add(@now, 7 * 86_400, :second)
    })
    |> Ecto.Changeset.change(status: "open")
    |> Repo.insert!()
  end

  defp row(%Proposal{id: id}), do: Repo.one!(from(p in Proposal, where: p.id == ^id))

  defp proposal_json(id) do
    %{rows: rows} =
      Repo.query!("SELECT row_to_json(p)::text FROM goal_proposals p WHERE p.id = $1", [
        Ecto.UUID.dump!(id)
      ])

    List.flatten(rows)
  end
end
