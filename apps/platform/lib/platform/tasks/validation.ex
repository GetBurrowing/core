defmodule Platform.Tasks.Validation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(ci_check ci_passed pr_merged lint_pass type_check test_pass code_review manual_approval e2e_behavior)
  # `skipped` (task 01a0665e stage 3) is written by exactly one seam:
  # `PlanEngine` moving a `failed` `e2e_behavior` row whose evidence carries
  # the `could_not_evaluate` marker out of the way once its host stage has at
  # least one genuinely passed sibling. It is NOT accepted by
  # `evaluate_validation` (still `passed | failed` only) — a reviewer cannot
  # skip a case, only report that it could not be run. Evidence is retained.
  # A skipped row is terminal and MET (absent from `@unmet_statuses`), so
  # every "still owed" reader treats it like `passed`.
  @statuses ~w(pending running passed failed skipped)
  @unmet_statuses ~w(pending running failed)
  @e2e_payload_required_keys ~w(setup actions expected)

  schema "validations" do
    belongs_to(:stage, Platform.Tasks.Stage)
    field(:kind, :string)
    field(:status, :string, default: "pending")
    field(:evidence, :map, default: %{})
    field(:evaluation_payload, :map, default: nil)
    field(:evaluated_by, :string)
    field(:evaluated_at, :utc_datetime_usec)

    # Task 01a0acb4 stage 1. Append-only history of in-place corrections to
    # `evaluation_payload` on an approved/executing plan. Written ONLY by
    # `payload_amendment_changeset/3`; it is deliberately absent from
    # `changeset/2`'s cast list, which is what keeps plan_create, plan_update
    # and validation_evaluate from writing (or forging) it. Not stored in
    # `evidence` because an e2e verdict replaces `evidence` wholesale.
    field(:payload_amendments, {:array, :map}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "The statuses under which a gate is still owed — as distinct from which statuses exist."
  def unmet_statuses, do: @unmet_statuses

  def changeset(validation, attrs) do
    validation
    |> cast(attrs, [
      :stage_id,
      :kind,
      :status,
      :evidence,
      :evaluation_payload,
      :evaluated_by,
      :evaluated_at
    ])
    |> validate_required([:stage_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_e2e_behavior_payload()
    |> foreign_key_constraint(:stage_id)
  end

  @doc """
  The ONLY writer of `payload_amendments` (task 01a0acb4 stage 1).

  Replaces `evaluation_payload` with `new_payload` and appends `entry` to
  the existing `payload_amendments` list (never replaces it). The amended
  payload goes through the same e2e_behavior payload check as authoring, so
  it must still carry non-blank `setup`, `actions` and `expected`.
  `status`, `evidence` and the evaluation fields are not touched.
  """
  def payload_amendment_changeset(%__MODULE__{} = validation, new_payload, entry)
      when is_map(entry) do
    existing = validation.payload_amendments || []

    validation
    |> change(%{evaluation_payload: new_payload, payload_amendments: existing ++ [entry]})
    |> validate_e2e_behavior_payload()
  end

  # When kind is "e2e_behavior", evaluation_payload must be a non-empty map
  # containing string-keyed setup, actions, and expected fields. The actual
  # failure observation IS the feedback (the review agent posts what it
  # expected vs what it saw); pre-writing failure_feedback at plan time is
  # not required and was dropped in v2.
  # Soft validator: only enforced when kind is set to "e2e_behavior".
  defp validate_e2e_behavior_payload(changeset) do
    kind = get_field(changeset, :kind)

    if kind == "e2e_behavior" do
      payload = get_field(changeset, :evaluation_payload)

      cond do
        is_nil(payload) or payload == %{} ->
          add_error(
            changeset,
            :evaluation_payload,
            "is required for e2e_behavior validations (must include #{Enum.join(@e2e_payload_required_keys, ", ")})"
          )

        not is_map(payload) ->
          add_error(changeset, :evaluation_payload, "must be a map")

        true ->
          missing =
            Enum.reject(@e2e_payload_required_keys, fn key ->
              has_payload_key?(payload, key)
            end)

          if missing == [] do
            changeset
          else
            add_error(
              changeset,
              :evaluation_payload,
              "missing required keys: #{Enum.join(missing, ", ")}"
            )
          end
      end
    else
      changeset
    end
  end

  defp has_payload_key?(payload, key) when is_map(payload) do
    value = Map.get(payload, key) || Map.get(payload, String.to_atom(key))
    is_binary(value) and String.trim(value) != ""
  rescue
    ArgumentError -> false
  end
end
