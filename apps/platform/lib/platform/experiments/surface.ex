defmodule Platform.Experiments.Surface do
  @moduledoc """
  A named decision point an experiment can vary. Task 01a0d415, the
  experimentation-layer ADR-0052 (extends ADR-0048).

  A module declares a surface ONCE, in code: its key, what kind of subject it
  decides for, the shape of the payload an arm carries, what the control arm
  is, and where the decision is taken. After that, every experiment on the
  surface is data — rows in `experiments` and `experiment_variants` — and no
  further code change or deploy is needed to run one.

  The registry of surfaces is `Platform.Experiments.Surfaces`.

  ## `path/0` — where the payload is consumed

    * `:dispatch` — resolved at dispatch time, inside the dispatch read
      point (e.g. `dispatch.prompt`, resolved in
      `Platform.Orchestration.PromptTemplates.render_template/2`).
    * `:draft` — resolved when a draft is composed, which a human or a later
      gate sees before anything leaves the system.

  There is deliberately no `:send` value. A surface resolved at the moment
  something is SENT would let an experiment change an outbound message after
  every review point has passed, so no path skips the draft.
  """

  alias Platform.Experiments.Variant

  @typedoc "Where the surface's payload is consumed. There is no `:send`; see the moduledoc."
  @type path :: :draft | :dispatch

  @doc "The surface key, e.g. `\"dispatch.prompt\"`."
  @callback key() :: String.t()

  @doc "The `subject_type` assignments on this surface carry, e.g. `\"task\"`."
  @callback subject_type() :: String.t()

  @doc """
  The payload shape as PLAIN DATA (string keys, no functions), so it can be
  listed over MCP without the caller loading this module.
  """
  @callback payload_schema() :: map()

  @doc "Validates and normalises an arm's payload."
  @callback validate_payload(payload :: map()) :: {:ok, map()} | {:error, [String.t()]}

  @doc """
  The control arm's payload for `target`, captured NOW — the snapshot an
  experiment takes at activation.
  """
  @callback control_payload(target :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Where the payload is consumed."
  @callback path() :: path()

  @doc """
  Reads a variant row's payload. Optional: the default is the row's
  `payload` map. A surface whose arms predate `payload` (the prompt surface's
  `content` blob) overrides it.
  """
  @callback variant_payload(Variant.t()) :: map()

  @doc """
  Attributes of a subject a policy may read (`:project_id`, `:org_id`,
  `:epic_id`, `:inserted_at`). Optional. Called only when an experiment on
  the surface is scoped or carries a policy, so an unscoped experiment costs
  no extra query.
  """
  @callback subject_attributes(subject_id :: String.t()) :: map()

  @doc """
  The surface targets a read point resolves. Optional. When a surface
  declares them, `experiment_create` refuses any other target, because an
  experiment on a target no read point asks about would never assign.
  """
  @callback targets() :: [String.t()]

  @doc """
  The payload as the plain-text body of a dispatch directive block, or nil
  for "no block". Optional; only a surface whose payload is appended to a
  dispatch prompt (see `HeartbeatScheduler.append_experiment_directive/4`)
  implements it. A control payload renders nil, so the control arm's prompt
  is the unexperimented prompt.
  """
  @callback render_directive(payload :: map()) :: String.t() | nil

  @optional_callbacks variant_payload: 1,
                      subject_attributes: 1,
                      targets: 0,
                      render_directive: 1
end
