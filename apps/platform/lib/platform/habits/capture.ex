defmodule Platform.Habits.Capture do
  @moduledoc """
  Broad capture for learned defaults (`0061-learned-defaults.md` § 2, task
  01a1b6a1 stage 3): host operations record what a person chose so a later
  consumer starts with history.

  Every function here is a side effect of an operation that has already
  succeeded, and none may fail it. `Platform.Habits.record/1` results are
  matched (`{:ok, _} | {:error, _}`), an error is logged and dropped, and a
  raise or exit is rescued and logged.

  Inside an open `Repo.transaction/1` nothing is recorded: a refused nested
  write would mark the caller's transaction for rollback, which is exactly
  the host failure this module must never cause. The skip is logged at debug.
  """

  require Logger

  alias Platform.Habits
  alias Platform.Repo

  @doc """
  Records one `chosen` signal at rung `none` (no consumer was shown). `attrs`
  are the `Platform.Habits.record/1` keys minus `outcome` and `rung`.
  Always returns `:ok`.
  """
  @spec chosen(map()) :: :ok
  def chosen(attrs) when is_map(attrs),
    do: record(Map.merge(attrs, %{outcome: "chosen", rung: "none"}))

  @doc """
  `Platform.Habits.record/1` that never fails its caller. Always `:ok`.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    safely(attrs[:action], fn ->
      case Habits.record(attrs) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Habits] capture refused action=#{inspect(attrs[:action])} " <>
              "errors=#{inspect(errors(reason))}"
          )
      end
    end)
  end

  @doc """
  Runs `fun` as a capture side effect: skipped inside a transaction, every
  raise, throw and exit rescued and logged. Always `:ok`.
  """
  @spec safely(term(), (-> term())) :: :ok
  def safely(label, fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      Logger.debug("[Habits] capture skipped inside a transaction action=#{inspect(label)}")
    else
      fun.()
    end

    :ok
  rescue
    error ->
      Logger.error(
        "[Habits] capture crashed action=#{inspect(label)} " <>
          "category=#{inspect(error.__struct__)}"
      )

      :ok
  catch
    kind, _reason ->
      Logger.error("[Habits] capture crashed action=#{inspect(label)} kind=#{kind}")
      :ok
  end

  defp errors(%Ecto.Changeset{errors: errors}), do: errors
  defp errors(other), do: other
end
