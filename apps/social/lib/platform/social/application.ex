defmodule Platform.Social.Application do
  @moduledoc """
  Social's own OTP application (ADR 0055). `:social` depends on `:platform`,
  so OTP starts it after core's Endpoint and stops it before it
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).

  Children are Social's own, never core's: Social 2/7 adds the Fake
  publisher's ETS table owner and the publish rate limit; Social 5/7 the
  clip render queue and its task supervisor.

  ## Runtime settings

  `Platform.Social.RuntimeConfig.apply/1` reads Social's OS environment
  (`SOCIAL_PUBLISHER`, `SOCIAL_ZERNIO_BASE_URL`) here, first, in every
  build: a release's runtime config is core's `config/runtime.exs`, which
  never names Social (ADR 0055 section 8).
  """

  use Application

  @impl true
  def start(_type, _args) do
    Platform.Social.RuntimeConfig.apply(System.get_env())

    children = [
      # Owns the Fake publisher's call log. Idle unless the Fake is selected.
      Platform.Social.Publisher.Fake,
      # Per-account publish limit's ETS counters.
      Platform.Social.RateLimit,
      # Social 5/7: the clip render queue. The task supervisor starts first;
      # a restarted queue stops the tasks its predecessor left there and
      # re-queues their clips from the DB (Platform.Social.RenderQueue).
      {Task.Supervisor, name: Platform.Social.RenderTaskSupervisor},
      Platform.Social.RenderQueue
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
