defmodule Platform.Experiments.Subject do
  @moduledoc """
  The thing an experiment assigns a variant to. Task 019fe6b9, ADR-0048.

  A plain struct, deliberately NOT an Ecto schema: a subject is never
  persisted in this shape. `experiment_assignments` stores `subject_type` and
  `subject_id` and nothing else, because the attributes below are inputs to a
  policy decision, not a record of one.

  ## The engine stays ignorant of tasks

  This struct exists so that no policy ever sees a task struct.
  A policy receives a type, an id, and a bag of attributes; it cannot reach
  into the task table, cannot pattern-match a task struct, and therefore
  cannot grow a dependency on the shape of the thing being experimented on.

  That is not tidiness. `subject_type` is `"task"` today and must become
  `"dispatch"` — or anything else — with no migration and no rewrite of the
  policy library. A policy that pattern-matched a task struct would have to be
  rewritten for every new subject kind, and the pressure would be to widen
  `subject_type` into a union the engine switches on, which is the coupling
  this struct was introduced to prevent. `subject_type` therefore stays a
  free string; nothing here validates it against a known set.

  A source-level test asserts the absence of any tasks-context reference from the policy
  layer, because the compiler cannot enforce a constraint about what code is
  *not* written.

  ## `attributes` carries only what the caller already knows

  `:project_id`, `:epic_id`, `:inserted_at`, and (task 01a114a8 stage 4)
  `:agent_id`, the dispatched phase's assignee — plain map keys, supplied by
  the caller from data it already has in hand. Policies read scoping information
  from here and from nowhere else. A policy that needs a fact not present in
  `attributes` returns `:no_opinion` rather than going and fetching it.
  """

  @type t :: %__MODULE__{
          type: String.t(),
          id: Ecto.UUID.t(),
          attributes: map()
        }

  @enforce_keys [:type, :id]
  defstruct type: nil, id: nil, attributes: %{}

  @doc """
  Builds a subject.

  `attributes` defaults to an empty map: a subject with no scoping
  information is legitimate, and every policy that needs one of those keys
  already handles its absence by deferring.
  """
  @spec new(String.t(), Ecto.UUID.t(), map()) :: t()
  def new(type, id, attributes \\ %{})
      when is_binary(type) and is_binary(id) and is_map(attributes) do
    %__MODULE__{type: type, id: id, attributes: attributes}
  end
end
