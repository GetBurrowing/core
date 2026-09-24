defmodule Platform.Mail.Inbound.Poller do
  @moduledoc """
  Polls one mail account's IMAP mailbox on an interval (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3). Polling is v1; IMAP IDLE is
  deferred.

  Each tick reloads the account row. An account that is no longer eligible
  (`Platform.Mail.Inbound.eligible?/1`: reading off, archived, no host) stops
  its poller with `:normal`; `:transient` restart means it is not restarted.
  The poll itself is `Platform.Mail.Inbound.poll/2`.

  Exits are trapped and a raise or exit inside a poll is caught, so a failed
  connection becomes a logged failed poll, not a crashed poller. (Since stage
  7 the production client, `Platform.Mail.Imap.WireClient`, is a passive
  socket in this process, not a linked connection process.)

  Config: `config :platform, Platform.Mail.Inbound, poll_ms: 60_000,
  initial_delay_ms: 1_000`.
  """
  use GenServer, restart: :transient

  require Logger

  alias Platform.Mail.Account
  alias Platform.Mail.Inbound
  alias Platform.Repo

  def start_link(account_id) do
    GenServer.start_link(__MODULE__, account_id,
      name: {:via, Registry, {Platform.Mail.Inbound.Registry, account_id}}
    )
  end

  @impl true
  def init(account_id) do
    Process.flag(:trap_exit, true)
    schedule(config(:initial_delay_ms, 1_000))
    {:ok, %{account_id: account_id}}
  end

  @impl true
  def handle_info(:poll, %{account_id: account_id} = state) do
    case Repo.get(Account, account_id) do
      %Account{} = account ->
        if Inbound.eligible?(account) do
          run_poll(account)
          schedule(config(:poll_ms, 60_000))
          {:noreply, state}
        else
          {:stop, :normal, state}
        end

      nil ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp run_poll(account) do
    case Inbound.poll(account) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Mail.Inbound] poll failed account_id=#{account.id} reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "[Mail.Inbound] poll raised account_id=#{account.id} error=#{Exception.message(error)}"
      )
  catch
    :exit, reason ->
      Logger.warning("[Mail.Inbound] poll exited account_id=#{account.id} #{inspect(reason)}")
  end

  defp schedule(ms), do: Process.send_after(self(), :poll, ms)

  defp config(key, default) do
    :platform |> Application.get_env(Inbound, []) |> Keyword.get(key, default)
  end
end
