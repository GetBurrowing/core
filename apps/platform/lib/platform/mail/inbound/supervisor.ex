defmodule Platform.Mail.Inbound.Supervisor do
  @moduledoc """
  Owns the IMAP pollers (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3):
  a `Registry` keyed by account id, a `DynamicSupervisor` of
  `Platform.Mail.Inbound.Poller`s, and a one-shot boot task that starts a
  poller for every eligible account.

  Started by `Platform.Application` ONLY when `Platform.Mail.Config.enabled?/0`
  (see `maybe_add_mail_inbound/1`). With `MAIL_ENABLED` unset this process,
  and therefore every poller and every IMAP connection, does not exist.

  `start_link(boot: false)` skips the boot task; tests use it so the
  supervisor's startup does not query accounts outside their sandbox.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    boot =
      if Keyword.get(opts, :boot, true) do
        [
          Supervisor.child_spec({Task, &boot/0}, id: :mail_inbound_boot, restart: :temporary)
        ]
      else
        []
      end

    children =
      [
        {Registry, keys: :unique, name: Platform.Mail.Inbound.Registry},
        {DynamicSupervisor, name: Platform.Mail.Inbound.PollerSupervisor, strategy: :one_for_one}
      ] ++ boot

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # A boot failure (e.g. the DB not ready) must not take the tree down; the
  # next account save re-syncs its poller.
  defp boot do
    Platform.Mail.Inbound.start_all_pollers()
  rescue
    error ->
      require Logger
      Logger.warning("[Mail.Inbound] boot could not start pollers: #{Exception.message(error)}")
      :ok
  end
end
