defmodule Platform.Goals do
  @moduledoc """
  The Goals module's public context (ADR 0055 build-time module, task
  01a1dfc0). For now it answers only whether the install switched Goals on.
  """

  @doc """
  Whether this install switched Goals on (`GOALS_ENABLED`, read at boot by
  `Platform.Goals.RuntimeConfig`). False until the application has started,
  and false whenever the variable is unset.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:goals, :enabled, false) == true
end
