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

  ## Fail closed

  Unset, blank, and every value other than the three names above (compared
  after trimming and downcasing) mean `:disabled`. A typo turns the feature
  off; it never turns it on.

  ## The one predicate

  `enabled?/0` is THE capability predicate. `Platform.Federation.ToolSurface`
  (listing and execution), `Platform.Orchestration.PromptTemplates`
  (guidance text) and `Platform.Orchestration.HeartbeatScheduler` (the assigns
  every task dispatch and nudge render) all ask it and nothing else, so the
  advertised set and the callable set cannot disagree.

  ## Injection

  `config/runtime.exs` writes `config :platform, :feedback_policy` from
  `FEEDBACK_POLICY` outside the test environment; `config/config.exs`
  defaults it to `"disabled"` and `config/test.exs` pins it there, so the
  suite is not a function of the host's environment. A test that needs the
  capability flips it with `Application.put_env/3` and restores it on exit.
  """

  @modes ~w(disabled quarantined trusted)

  @type mode :: :disabled | :quarantined | :trusted

  @doc "The three accepted policy names, in order."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "The installation's normalised feedback mode."
  @spec mode() :: mode()
  def mode, do: normalize(Application.get_env(:platform, :feedback_policy))

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
  Normalise a raw policy value. Atoms and strings are accepted; anything that
  is not exactly one of the three names (after trim + downcase) is
  `:disabled`.
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
end
