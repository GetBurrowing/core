defmodule Platform.Repo.Migrations.BackfillChannelCreatorAdminTest do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1. This file gives
  behavioural coverage of
  `20261002170000_backfill_channel_creator_admin`.

  The suite migrates an EMPTY database, where both UPDATEs match zero rows, so
  a deleted clause and a correct one would look the same. This file seeds each
  clause's positive and negative cases with explicit `joined_at` offsets from
  the space's `inserted_at`. It then runs the SHIPPED `up/0` through
  `Ecto.Migration.Runner` on the test process's sandboxed connection, the same
  way as `EnforceAgentSlugUniquenessAcrossNullWorkspaceTest`, and reads every
  role back. Each test asserts which rows flipped AND which did not, because a
  clause that promoted every member would pass a positive-only check.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Repo

  @migration Platform.Repo.Migrations.BackfillChannelCreatorAdmin

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/" <>
                      "20261002170000_backfill_channel_creator_admin.exs",
                    __DIR__
                  )

  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)
    :ok
  end

  defp run_migration!(operation) when operation in [:up, :down] do
    {:ok, runner} =
      Ecto.Migration.Runner.start_link(
        {self(), Repo, Repo.config(), @migration, :forward, operation,
         %{level: false, sql: false}}
      )

    Ecto.Migration.Runner.metadata(runner, [])
    apply(@migration, operation, [])
    Ecto.Migration.Runner.flush()
    Ecto.Migration.Runner.stop()
    :ok
  end

  @base ~U[2026-09-01 12:00:00.000000Z]

  # Inserted with Repo directly (not `Chat.create_space/1`), so no creator is
  # seated and the rows are exactly the pre-fix shape the migration repairs.
  defp space!(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Space{
      name: "Backfill #{n}",
      slug: "backfill-#{n}",
      kind: Keyword.get(opts, :kind, "channel"),
      created_by: Keyword.get(opts, :created_by),
      inserted_at: @base,
      updated_at: @base
    })
  end

  defp row!(space, type, offset_seconds, opts \\ []) do
    Repo.insert!(%Participant{
      space_id: space.id,
      participant_type: type,
      participant_id: Keyword.get(opts, :participant_id, Ecto.UUID.generate()),
      role: Keyword.get(opts, :role, "member"),
      attention_mode: Keyword.get(opts, :attention_mode, "mention"),
      display_name: "row",
      joined_at: DateTime.add(@base, round(offset_seconds * 1000), :millisecond)
    })
  end

  defp role(%Participant{id: id}), do: Repo.get!(Participant, id).role

  # `chat_spaces.created_by` references `users`, so a recorded creator must be
  # a real user row.
  defp user_id! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Backfill Creator #{n}",
      email: "backfill-creator-#{n}@example.com",
      oidc_sub: "sub-backfill-creator-#{n}"
    }).id
  end

  describe "clause A: created_by IS NOT NULL" do
    test "promotes the creator's member row and only that row" do
      creator_id = user_id!()
      space = space!(created_by: creator_id)
      other = row!(space, "user", 1)
      creator = row!(space, "user", 300, participant_id: creator_id)

      run_migration!(:up)

      assert role(creator) == "admin"
      assert role(other) == "member"
    end

    test "leaves a creator whose row is an observer alone" do
      creator_id = user_id!()
      space = space!(created_by: creator_id)
      creator = row!(space, "user", 1, participant_id: creator_id, role: "observer")

      run_migration!(:up)

      assert role(creator) == "observer"
    end

    test "does not touch a group space with created_by" do
      creator_id = user_id!()
      space = space!(kind: "group", created_by: creator_id)
      creator = row!(space, "user", 0.5, participant_id: creator_id)

      run_migration!(:up)

      assert role(creator) == "member"
    end
  end

  describe "clause B: created_by IS NULL" do
    test "promotes a lone first-in-window user, ignoring a heartbeat historian ahead of it" do
      space = space!()
      historian = row!(space, "agent", 0.01, attention_mode: "heartbeat")
      creator = row!(space, "user", 0.8)
      # Outside the window: a later joiner does not make the creator ambiguous.
      late = row!(space, "user", 90)

      run_migration!(:up)

      assert role(creator) == "admin"
      assert role(historian) == "member"
      assert role(late) == "member"
    end

    test "a second user inside the window leaves both as members" do
      space = space!()
      first = row!(space, "user", 1)
      second = row!(space, "user", 30)

      run_migration!(:up)

      assert role(first) == "member"
      assert role(second) == "member"
    end

    test "a non-heartbeat agent first (an agent-created channel) promotes no one" do
      space = space!()
      agent = row!(space, "agent", 0.1, attention_mode: "mention")
      user = row!(space, "user", 2)

      run_migration!(:up)

      assert role(user) == "member"
      assert role(agent) == "member"
    end

    test "a first join at 61 seconds is outside the window" do
      space = space!()
      user = row!(space, "user", 61)

      run_migration!(:up)

      assert role(user) == "member"
    end

    test "boundary control: a first join at 59 seconds is inside the window" do
      space = space!()
      user = row!(space, "user", 59)

      run_migration!(:up)

      assert role(user) == "admin"
    end

    test "a space that already has an admin is left alone" do
      space = space!()
      first = row!(space, "user", 1)
      admin = row!(space, "user", 200, role: "admin")

      run_migration!(:up)

      assert role(first) == "member"
      assert role(admin) == "admin"
    end

    test "an observer-role first user is not promoted" do
      space = space!()
      observer = row!(space, "user", 1, role: "observer")

      run_migration!(:up)

      assert role(observer) == "observer"
    end

    test "does not touch a DM space" do
      space = space!(kind: "dm")
      user = row!(space, "user", 0.5)

      run_migration!(:up)

      assert role(user) == "member"
    end
  end

  test "down/0 is a no-op and demotes nothing" do
    space = space!()
    creator = row!(space, "user", 1)

    run_migration!(:up)
    assert role(creator) == "admin"

    run_migration!(:down)
    assert role(creator) == "admin"
  end
end
