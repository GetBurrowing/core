defmodule Platform.Repo.Migrations.AddInstallManagedToAgentRuntimes do
  @moduledoc """
  Task 01a10322 stage 1: a native (install-managed) agent is a ROW SHAPE, not a
  new code path. Three columns mark an `agent_runtimes` row as managed by this
  install rather than federated in from elsewhere:

    * `managed_by`: NULL for a federated runtime, `"install"` for a native one.
    * `harness`: the CLI the install runs for it, `"claude_code"` or `"codex"`.
    * `desired_state`: `"running"` or `"stopped"`, default `"stopped"`.

  Columns, not `metadata` keys: `PlatformWeb.RuntimeChannel` rewrites
  `metadata["client_info"]` on every join, and `Federation.update_metadata/2`
  merges shallowly, so a supervision flag kept there could be clobbered by a
  reconnect.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_runtimes) do
      add(:managed_by, :text)
      add(:harness, :text)
      add(:desired_state, :text, null: false, default: "stopped")
    end
  end
end
