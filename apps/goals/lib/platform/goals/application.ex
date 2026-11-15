defmodule Platform.Goals.Application do
  @moduledoc """
  Goals' own OTP application (ADR 0055, task 01a1dfc0). It reads Goals'
  runtime settings and starts Goals' process tree; core does neither.

  ## Runtime settings

  `Platform.Goals.RuntimeConfig.apply/1` turns the OS environment into Goals'
  app env (`:goals, :enabled`) here, at boot, in every build: a release's
  runtime config is core's `config/runtime.exs`, which never names Goals.

  ## Children

  None yet. The `@web` / `@background` lists and `children/1` follow Play's
  shape (`Platform.Role.select/3`), so a later member adds a child in one
  place.
  """

  use Application

  # Web-role classification (task 01a155a6), by child id, under the rule in
  # `Platform.Role`'s moduledoc. Empty: Goals starts no process yet.
  @web []
  @background []

  @impl true
  def start(_type, _args) do
    Platform.Goals.RuntimeConfig.apply(System.get_env())

    Supervisor.start_link(children(Platform.Role.role()),
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end

  @doc false
  def web_ids, do: @web

  @doc false
  def background_ids, do: @background

  @doc """
  Goals' children for `role`: all of them under `:full`, the `@web` ones
  under `:web` (`Platform.Role.select/3`).
  """
  @spec children(Platform.Role.t()) :: list()
  def children(role) do
    Platform.Role.select(@web ++ @background, role, @web)
  end
end
