defmodule Platform.Repo.Migrations.RenameMeetingAssistantAgentToBurrow do
  use Ecto.Migration

  @moduledoc """
  Task 01a0f31d stage 1, item 1: the product lead renamed the "Meeting Assistant"
  persona to **Burrow** (an earlier "Borough" spelling was a correction
  miss and is not used anywhere). Data-only migration: `@agent_name` in
  `mix platform.seed_meeting_voice_agent` moving from `"Meeting Assistant"`
  to `"Burrow"` only affects a FUTURE run of that seed task — it does
  nothing for the row it already inserted into prod (agent id
  `01a0db75-037c-7001-...`, task 01a0d4a0 stage 2, confirmed live in org
  journal 2026-09-26). This migration is the only thing that renames that
  already-persisted row.

  ## Why match on name, not slug

  The agent's slug (`"meeting-assistant"`) is an internal identifier, not
  the user-facing persona name, and is explicitly OUT of scope for this
  rename (`Platform.Agents.SlugLookup.resolve/2` and every runtime lookup
  key off it — renaming it would be a second, unrelated migration with its
  own blast radius). Matching on `a.name == "Meeting Assistant"` targets
  exactly the display-name field the seed script's `@agent_name` sets, and
  nothing else keys off it.

  ## Idempotent

  A rerun finds zero rows with `name == "Meeting Assistant"` (they are all
  already `"Burrow"`) and updates nothing — safe to run twice, and a no-op
  on any environment where the old-named row never existed (a fresh
  install seeded straight from the already-renamed `@agent_name`).
  """

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Repo

  # The `agents` columns as they stood at this migration's version. Loading
  # the LIVE `Agent` schema here selects every column the schema knows today,
  # so a fresh `ecto.migrate` crashes with `undefined_column` the moment a
  # later migration adds an agents column (task 01a19776 stage 1 added
  # `dm_policy` and hit exactly that). Selecting this fixed list keeps the
  # historical migration runnable whatever the schema grows.
  @agent_fields ~w(
    id workspace_id slug name status model_config tools_config thinking_default
    heartbeat_config max_concurrent sandbox_mode parent_agent_id metadata
    runtime_type runtime_id color kind endpoint_kind base_url model vault_key
    last_probe_at last_probe_status last_probe_latency_ms last_successful_fire_at
    avatar_url avatar_storage_key voice_config inserted_at updated_at
  )a

  @old_name "Meeting Assistant"
  @new_name "Burrow"

  def up do
    Repo.all(
      from(a in Agent, where: a.name == ^@old_name, select: struct(a, ^@agent_fields))
    )
    |> Enum.each(fn agent ->
      {:ok, _updated} =
        agent
        |> Agent.changeset(%{name: @new_name})
        |> Repo.update()
    end)

    :ok
  end

  def down do
    :ok
  end
end
