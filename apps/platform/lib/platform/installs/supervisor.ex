defmodule Platform.Installs.Supervisor do
  @moduledoc """
  `Platform.Installs`'s boot-time processes (task 01a10315 stage 2): the
  hand-over sweeper, a one-shot `Platform.Installs.resume_all/0` that
  restarts unfinished runs and teardowns, and in dev stub mode the
  `Platform.Installs.Fake` store. Started after Repo, PubSub and
  `Platform.TaskSupervisor`; `config :platform, :start_installs, false` in
  test, where cases drive the runner themselves. The run registry
  (`Platform.Installs.Registry`) is started apart from this, in every env.
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    fake =
      if Keyword.get(Application.get_env(:platform, Platform.Installs, []), :fake, false),
        do: [Platform.Installs.Fake],
        else: []

    children =
      fake ++
        [
          Platform.Installs.Sweeper,
          Supervisor.child_spec(
            {Task, &Platform.Installs.resume_all/0},
            id: :installs_resume,
            restart: :temporary
          )
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
