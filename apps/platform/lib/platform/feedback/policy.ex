defmodule Platform.Feedback.Policy do
  @moduledoc """
  The installation's external-feedback capability (task 01a11ec3 stage 2).

  ONE environment value, `FEEDBACK_POLICY`, normalised to one of three modes:

    * `:disabled` — the capability does not exist. `feedback_submit` is not
      listed by any bundle, a direct call is refused server-side, and no
      dispatch or nudge prompt mentions it.
    * `:quarantined` — the capability exists; an accepted intake stamps the
      task it files `trust: "quarantined"`.
    * `:trusted` — the capability exists; an accepted intake stamps the task
      `trust: "trusted"`.

  `quarantined` and `trusted` differ ONLY in the initial trust stamp written
  at accepted intake (`initial_trust/0`). Neither one is read again after that
  write: a task's persisted `trust`, `origin` and external identity are
  authoritative, so changing this value later never rewrites an existing row.
  Nothing here reads a task.

  ## Unset means on; an explicit typo means off

  Unset or blank (after trimming) means `:quarantined`: a fresh install has
  the capability on, so its agents can report defects without an operator
  setting anything (task 01a1a6a5 stage 1). The opt-out is an explicit
  `FEEDBACK_POLICY=disabled`.

  An EXPLICIT value is still fail-closed: every value other than the three
  names above (compared after trimming and downcasing) means `:disabled`, so a
  typo such as `enabeld` turns the feature off; it never turns it on.

  ## The one predicate

  `enabled?/0` is THE capability predicate. `Platform.Federation.ToolSurface`
  (listing and execution), `Platform.Orchestration.PromptTemplates`
  (guidance text) and `Platform.Orchestration.HeartbeatScheduler` (the assigns
  every task dispatch and nudge render) all ask it and nothing else, so the
  advertised set and the callable set cannot disagree.

  `explicit?/0` is the narrower predicate for `Platform.Feedback.Intake` only:
  true when an operator EXPLICITLY set `quarantined` or `trusted`. Intake
  files tasks and writes dispositions back to the feedback repository, so the
  unset default must not switch it on for every install whose project is
  connected to that repository.

  ## Injection

  `config/runtime.exs` writes `config :platform, :feedback_policy` from
  `FEEDBACK_POLICY` outside the test environment, passing `nil` when the
  variable is unset. `config/config.exs` sets no value; `config/test.exs`
  pins it to `"disabled"`, so the suite is not a function of the host's
  environment. A test that needs another mode (or the unset default, via
  `Application.delete_env/2`) changes it and restores it on exit.
  """

  @modes ~w(disabled quarantined trusted)

  @type mode :: :disabled | :quarantined | :trusted

  @doc "The three accepted policy names, in order."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  The installation's normalised feedback mode. An unset or blank value is
  `:quarantined` (the default-on capability); any explicit value goes through
  `normalize/1`, which is fail-closed.
  """
  @spec mode() :: mode()
  def mode do
    value = configured()
    if unset?(value), do: :quarantined, else: normalize(value)
  end

  @doc """
  True only when an operator explicitly set `quarantined` or `trusted`. The
  unset default is NOT explicit. `Platform.Feedback.Intake` gates on this,
  not on `enabled?/0`.
  """
  @spec explicit?() :: boolean()
  def explicit? do
    value = configured()
    not unset?(value) and normalize(value) != :disabled
  end

  @doc """
  The capability predicate: true exactly when the mode is `:quarantined` or
  `:trusted`.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: mode() != :disabled

  @doc """
  The trust stamp an accepted intake writes onto the task it files, or
  `{:error, :disabled}` when the capability is off.
  """
  @spec initial_trust() :: {:ok, String.t()} | {:error, :disabled}
  def initial_trust do
    case mode() do
      :quarantined -> {:ok, "quarantined"}
      :trusted -> {:ok, "trusted"}
      :disabled -> {:error, :disabled}
    end
  end

  @doc """
  Normalise an explicit raw policy value. Atoms and strings are accepted;
  anything that is not exactly one of the three names (after trim + downcase)
  is `:disabled`. The unset default is applied by `mode/0`, not here.
  """
  @spec normalize(term()) :: mode()
  def normalize(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> normalize()

  def normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "quarantined" -> :quarantined
      "trusted" -> :trusted
      _ -> :disabled
    end
  end

  def normalize(_value), do: :disabled

  defp configured, do: Application.get_env(:platform, :feedback_policy)

  defp unset?(nil), do: true
  defp unset?(value) when is_binary(value), do: String.trim(value) == ""
  defp unset?(_value), do: false
end
