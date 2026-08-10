defmodule Platform.Experiments.PromptTemplateHistory do
  @moduledoc """
  An append-only record of what a prompt template said at a moment in time.
  Task 019fe6b9, ADR-0048.

  ## Append-only, by contract

  Rows here are INSERTED and never updated or deleted. There is no
  `update_*` and no `delete_*` changeset in this module, and none may be
  added: a history that can be edited is not a history.

  This table is what gives "snapshot before promote, demote is one revert"
  somewhere to write. Promoting a winning variant overwrites
  `prompt_templates.content`, which is destructive; capturing the outgoing
  content here first makes the promotion reversible by re-writing a stored
  blob rather than by reconstructing what the template used to say from
  memory.

  `promotion_experiment_id` records the promotion that caused the capture,
  and is nullable because a capture can be taken outside any promotion.

  No promotion logic lives in this task — this is the table and its
  changeset only.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Platform.Orchestration.PromptTemplate

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "prompt_template_history" do
    field(:content, :string)
    field(:captured_at, :utc_datetime_usec)
    field(:captured_by, :string)
    field(:promotion_experiment_id, Ecto.UUID)

    belongs_to(:template, PromptTemplate)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an insert changeset. There is deliberately no update or delete
  counterpart — see the moduledoc.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(history, attrs) do
    history
    |> cast(attrs, [
      :template_id,
      :content,
      :captured_at,
      :captured_by,
      :promotion_experiment_id
    ])
    |> validate_required([:template_id, :content, :captured_at])
    |> foreign_key_constraint(:template_id)
  end
end
