defmodule Platform.Social.Application do
  @moduledoc """
  Social's own OTP application (ADR 0055). `:social` depends on `:platform`,
  so OTP starts it after core's Endpoint and stops it before it
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).

  Children are Social's own, never core's: Social 2/7 adds the Fake
  publisher's ETS table owner and the publish rate limit; Social 5/7 the
  clip render queue and its task supervisor; task 01a165f1 the publish retry
  sweep; Clip Studio 2/9 (task 01a16662) the clip publish window.

  ## Runtime settings

  `Platform.Social.RuntimeConfig.apply/1` reads Social's OS environment
  (`SOCIAL_PUBLISHER`, `SOCIAL_ZERNIO_BASE_URL`) here, first, in every
  build: a release's runtime config is core's `config/runtime.exs`, which
  never names Social (ADR 0055 section 8).
  """

  use Application

  # Web-role classification (task 01a155a6), by child id, under the rule in
  # `Platform.Role`'s moduledoc. The Fake's call log and the rate limit's
  # counters are ETS owners whose only timer prunes their own table. The
  # render queue re-queues clips from the DB when it starts and renders on
  # its own, so it and its task supervisor are background. The publish retry
  # sweep (task 01a165f1) writes posts and calls the vendor, so it is
  # background too, and so is the clip publish window (Clip Studio 2/9),
  # which publishes approved clip posts once their undo window closes.
  @web [Platform.Social.Publisher.Fake, Platform.Social.RateLimit]
  @background [
    Platform.Social.RenderTaskSupervisor,
    Platform.Social.RenderQueue,
    Platform.Social.PublishRetry,
    Platform.Social.ClipPublish,
    Platform.Social.EpisodeDiscovery,
    Platform.Social.AnalyticsSync,
    Platform.Social.WeeklyNoteSweep
  ]

  @impl true
  def start(_type, _args) do
    Platform.Social.RuntimeConfig.apply(System.get_env())

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
  Social's children for `role`: all of them under `:full`, the `@web` ones
  under `:web` (`Platform.Role.select/3`).
  """
  @spec children(Platform.Role.t()) :: list()
  def children(role) do
    [
      # Owns the Fake publisher's call log. Idle unless the Fake is selected.
      Platform.Social.Publisher.Fake,
      # Per-account publish limit's ETS counters.
      Platform.Social.RateLimit,
      # Social 5/7: the clip render queue. The task supervisor starts first;
      # a restarted queue stops the tasks its predecessor left there and
      # re-queues their clips from the DB (Platform.Social.RenderQueue).
      {Task.Supervisor, name: Platform.Social.RenderTaskSupervisor},
      Platform.Social.RenderQueue,
      # Task 01a165f1: re-publishes rate-limited posts once their window ends.
      # State is in the DB (refused_reason / retry_after), so a restart loses
      # nothing.
      Platform.Social.PublishRetry,
      # Clip Studio 2/9: publishes approved clip posts when their 8s undo
      # window closes. State is in the DB (publish_after), and a boot sweep
      # picks up anything a restart left due.
      Platform.Social.ClipPublish,
      # Task 01a17e37: durable source-level episode discovery.
      Platform.Social.EpisodeDiscovery,
      Platform.Social.AnalyticsSync,
      Platform.Social.WeeklyNoteSweep
    ]
    |> Platform.Role.select(role, @web)
  end
end
