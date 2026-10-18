defmodule Platform.Federation.ToolCallRecord do
  @moduledoc """
  One row per federated tool call (`dispatch_tool_calls`, task 01a114a8
  stage 1). Written only by `Platform.Federation.ToolCallLedger`.

  The row records WHICH tool ran, how it ended and who it is attributed to.
  It has no column for arguments, results or script text, and none may be
  added: the ledger's privacy property is that there is nowhere to put them.
  A `burrow_run` row (stage 2) carries `script_sha256` and `script_bytes`: a
  fingerprint and a size, from which the script cannot be recovered. Its
  `id` is the run's `run_id`, which its inner calls carry as `parent_run_id`.

  `error_kind` (task 01a115b5 stage 1) is set only on a `burrow_run` row whose
  run failed (`status: "error"`). It is one of
  `Platform.CodeMode.Run.error_kinds/0`, an enumerated kind, never the
  error message: the changeset refuses any other value.

  `attribution` names the rung of the ladder that produced
  `task_id` / `stage_id` (see `ToolCallLedger.attribute/3`):

    * `explicit_arg` — `task_id`, `stage_id` or `plan_id` in the call's args
    * `execution_space` — a `space_id` that is a task's execution space
    * `sole_acked_stage` — the runtime has exactly one acked stage whose
      stage row is still `running`
    * `sole_lease` — the runtime holds exactly one active execution_lease
      (OpenClaw runtimes; Claude Code runtimes never write lease rows)
    * `unattributed` — none of the above
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @statuses ~w(ok error denied)
  @attributions ~w(explicit_arg execution_space sole_acked_stage sole_lease unattributed)

  @fields ~w(id runtime_id agent_id tool status duration_ms result_bytes task_id stage_id
             lease_id attribution parent_run_id script_sha256 script_bytes error_kind)a

  schema "dispatch_tool_calls" do
    field(:runtime_id, :string)
    field(:agent_id, :binary_id)
    field(:tool, :string)
    field(:status, :string)
    field(:duration_ms, :integer)
    field(:result_bytes, :integer)
    field(:task_id, :binary_id)
    field(:stage_id, :binary_id)
    field(:lease_id, :binary_id)
    field(:attribution, :string)
    field(:parent_run_id, :binary_id)
    field(:script_sha256, :string)
    field(:script_bytes, :integer)
    field(:error_kind, :string)
    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
  end

  def statuses, do: @statuses
  def attributions, do: @attributions

  def changeset(record \\ %__MODULE__{}, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:runtime_id, :tool, :status, :attribution])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:attribution, @attributions)
    |> validate_format(:script_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_inclusion(:error_kind, Platform.CodeMode.Run.error_kinds())
  end
end
