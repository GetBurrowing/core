defmodule Platform.Repo.Migrations.RenameMeetingAssistantAgentToBurrowTest do
  @moduledoc """
  Coverage for `20260930120000_rename_meeting_assistant_agent_to_burrow`
  (task 01a0f31d stage 1, item 1).

  The seed script's `@agent_name` moving from `"Meeting Assistant"` to
  `"Burrow"` only affects a future run of `mix
  platform.seed_meeting_voice_agent` — it does nothing for the row that
  script already inserted into prod. This migration is the only thing
  that renames that already-persisted row, matched by `name`, not `slug`
  (the slug, `"meeting-assistant"`, is out of scope for this rename and
  must survive untouched).
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Repo

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.RenameMeetingAssistantAgentToBurrow

  # Migration files live under `priv/repo/migrations/` and are not on the
  # compile path — walk up from `test/platform/repo/migrations/<this>.exs`
  # to the `apps/platform/` app root, then descend into
  # `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260930120000_rename_meeting_assistant_agent_to_burrow.exs"
                  ])

  setup do
    # `mix test` runs `ecto.migrate` in the same VM, which compiles every
    # migration file — so the module is normally already loaded. Load it
    # ourselves when it is not, so a syntax error in the migration surfaces
    # here rather than as a full-suite compile break at deploy time.
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp insert_agent!(attrs) do
    Repo.insert!(
      Agent.changeset(
        %Agent{},
        Map.merge(%{slug: "agent-#{unique()}", status: "active"}, attrs)
      )
    )
  end

  describe "up/0" do
    test "renames a row named \"Meeting Assistant\" to \"Burrow\", slug untouched" do
      agent =
        insert_agent!(%{slug: "meeting-assistant", name: "Meeting Assistant"})

      assert :ok = @migration_module.up()

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.name == "Burrow"
      assert reloaded.slug == "meeting-assistant"
    end

    test "is a no-op when no row is named \"Meeting Assistant\" (fresh install)" do
      assert :ok = @migration_module.up()

      assert Repo.aggregate(from(a in Agent, where: a.name == "Meeting Assistant"), :count) == 0
    end

    test "running it twice is safe (idempotent)" do
      agent = insert_agent!(%{slug: "meeting-assistant", name: "Meeting Assistant"})

      assert :ok = @migration_module.up()
      first = Repo.get!(Agent, agent.id)
      assert first.name == "Burrow"

      assert :ok = @migration_module.up()
      second = Repo.get!(Agent, agent.id)

      assert second.name == "Burrow"

      assert second.updated_at == first.updated_at,
             "a rerun must skip an already-renamed row rather than re-writing it"
    end

    test "does not touch an agent with an unrelated name" do
      other = insert_agent!(%{slug: "other-agent-#{unique()}", name: "Other Agent"})

      assert :ok = @migration_module.up()

      reloaded = Repo.get!(Agent, other.id)
      assert reloaded.name == "Other Agent"
    end
  end

  describe "down/0" do
    test "is a no-op" do
      assert :ok = @migration_module.down()
    end
  end
end
