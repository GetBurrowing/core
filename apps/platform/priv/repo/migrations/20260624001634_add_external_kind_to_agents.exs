defmodule Platform.Repo.Migrations.AddExternalKindToAgents do
  use Ecto.Migration

  @moduledoc """
  Extends the `agents` table with the columns needed to represent External
  Agents (Responsibilities & External Agents stack, M2 stage 1).

  Adds:
    * `kind`          — agent classification ("native" | "external"); backfills
                        existing rows to "native" so the column is NOT NULL.
    * `endpoint_kind` — transport for external agents (e.g. "anthropic",
                        "openai", "openai_compatible"); only meaningful when
                        kind = "external".
    * `base_url`      — provider endpoint URL for external agents.
    * `model`         — provider-specific model identifier for external agents.
    * `vault_key`     — opaque handle into the credential vault (M3 ETS table).
                        Nullable because credentials are ephemeral and may not
                        yet be registered when the agent row is created.

  This migration is intentionally column-only — Ecto changeset validation in
  stage 2 enforces the kind-specific shape (e.g. base_url required when
  kind == "external"). The `runtime_type` column added in
  `20260319140000_create_agent_runtimes.exs` is preserved as a distinct
  concept (runtime ownership) per the stack decision; do not merge.

  Admitted by task 019ef65b, PR #454 — Responsibilities & External Agents
  stack, M2 stage 1.
  """

  def change do
    alter table(:agents) do
      add(:kind, :string, null: false, default: "native")
      add(:endpoint_kind, :string)
      add(:base_url, :string)
      add(:model, :string)
      add(:vault_key, :string)
    end

    create(index(:agents, [:kind]))
  end
end
