defmodule Platform.Repo.Migrations.MergeMeetingProducerIntoScribeTest do
  @moduledoc """
  Coverage for `20261118200000_merge_meeting_producer_into_scribe.exs`.

  The test DB is already migrated, so each case stages the PRE-merge state
  inside the sandbox (the old CHECK, the producer role, its bundle row and
  assignment) and runs the migration's data step, `carry_over!/1`, against
  it. The sandbox rolls the DDL and rows back afterwards.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias Platform.Roles

  @migration_module Platform.Repo.Migrations.MergeMeetingProducerIntoScribe

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261118200000_merge_meeting_producer_into_scribe.exs"
                  ])

  @key "meetings.intent_classify"

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = Roles.Seeds.seed_defaults()
    stage_pre_merge!()
    :ok
  end

  defp stage_pre_merge! do
    Repo.query!("ALTER TABLE roles DROP CONSTRAINT roles_key_check", [])

    Repo.query!(
      """
      INSERT INTO roles (key, name, description, icon, inserted_at, updated_at)
      VALUES ('meeting_producer', 'Meeting Producer', 'pre-merge', 'hero-signal', now(), now())
      """,
      []
    )

    Repo.query!(
      "DELETE FROM role_responsibilities WHERE role_key = 'meeting_scribe' AND responsibility_key = $1",
      [@key]
    )

    Repo.query!(
      """
      INSERT INTO role_responsibilities (id, role_key, responsibility_key, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'meeting_producer', $1, now(), now())
      """,
      [@key]
    )
  end

  defp insert_agent! do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "merge-#{n}",
      name: "Merge #{n}",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  # Raw insert: the producer key is no longer admitted by the changeset.
  defp assign_raw!(role_key, agent_id) do
    Repo.query!(
      """
      INSERT INTO role_assignments (id, role_key, agent_id, inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, $2, now(), now())
      """,
      [role_key, Ecto.UUID.dump!(agent_id)]
    )
  end

  defp override_agent_id do
    case Repo.query!(
           "SELECT agent_id FROM responsibility_overrides WHERE responsibility_key = $1",
           [@key]
         ) do
      %{rows: [[id]]} -> Ecto.UUID.load!(id)
      %{rows: []} -> nil
    end
  end

  test "a producer held by a different agent becomes a per-key override on that agent" do
    producer = insert_agent!()
    scribe = insert_agent!()
    assign_raw!("meeting_producer", producer.id)
    assign_raw!("meeting_scribe", scribe.id)

    assert :ok = @migration_module.carry_over!(Repo)

    assert override_agent_id() == producer.id
    assert %Agent{id: id} = Roles.assignee_for(@key)
    assert id == producer.id

    # The scribe keeps its role; the producer role and its rows are gone.
    assert Roles.agent_id_for_role("meeting_scribe") == scribe.id
    assert @key in Roles.bundle_for("meeting_scribe")
    refute Enum.any?(Roles.list_roles(), &(&1.key == "meeting_producer"))
  end

  test "a producer held by the scribe's own agent needs no override" do
    agent = insert_agent!()
    assign_raw!("meeting_producer", agent.id)
    assign_raw!("meeting_scribe", agent.id)

    assert :ok = @migration_module.carry_over!(Repo)

    assert override_agent_id() == nil
    assert %Agent{id: id} = Roles.assignee_for(@key)
    assert id == agent.id
  end

  test "a producer with no scribe keeps classifying through the override, nothing else starts" do
    producer = insert_agent!()
    assign_raw!("meeting_producer", producer.id)

    assert :ok = @migration_module.carry_over!(Repo)

    assert override_agent_id() == producer.id
    assert Roles.agent_id_for_role("meeting_scribe") == nil
    assert Roles.assignee_for("meetings.summarize") == nil
  end

  test "an existing override on the key is left alone" do
    producer = insert_agent!()
    pinned = insert_agent!()
    assign_raw!("meeting_producer", producer.id)
    {:ok, _} = Roles.set_override(@key, pinned.id)

    assert :ok = @migration_module.carry_over!(Repo)

    assert override_agent_id() == pinned.id
  end

  test "an unassigned producer just moves the bundle row" do
    assert :ok = @migration_module.carry_over!(Repo)

    assert override_agent_id() == nil
    assert @key in Roles.bundle_for("meeting_scribe")
    assert Roles.get_role("meeting_scribe").description =~ "classify live meeting intent"
  end
end
