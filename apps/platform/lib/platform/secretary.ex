defmodule Platform.Secretary do
  @moduledoc """
  The per-person triage agent that replaces the inbox (task 01a1b721).

  This module is the ONE place the product name lives. Every surface that
  shows the name reads `name/0`, so a rename is a one-line change here; a
  test scans `lib/` for the quoted literal anywhere else.

  Stage 1 is the data substrate only: settings
  (`Platform.Secretary.Settings`), the evaluation, feedback, batch and
  reach-out store (`Platform.Secretary.Store`), the person's own list
  (`Platform.Secretary.Todos`), the readable-input gatherer
  (`Platform.Secretary.Inputs`), the person's context
  (`Platform.Secretary.Context`) and the experiment surface
  (`Platform.Experiments.Surfaces.SecretaryPolicy`). No model call, UI or
  push happens here.
  """

  @name "Secretary"

  @doc "The product name, as the UI shows it."
  @spec name() :: String.t()
  def name, do: @name
end
