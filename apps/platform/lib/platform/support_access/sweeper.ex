defmodule Platform.SupportAccess.Sweeper do
  @moduledoc """
  The support access tick (task 01a1b362 stage 1, ADR 0059): every
  `Config.sweep_interval_ms/0` (60 s) it runs `Platform.SupportAccess.sweep/1`,
  which ends expired sessions, rewrites the host state file, ingests shell
  events and prunes nonces and codes. `Process.send_after/3` ticks, the
  `Platform.Federation.Peers.NonceCache` style; core has no Oban.

  A failing tick is logged and the next one runs on schedule, so a database
  blip cannot leave a session running past its `not_after` for longer than
  one interval after the database is back. Disabled in `config/test.exs`
  (`:start_support_access_sweeper`); tests call `SupportAccess.sweep/1`.
  """
  use GenServer

  require Logger

  alias Platform.SupportAccess
  alias Platform.SupportAccess.Config

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      SupportAccess.sweep()
    rescue
      e -> Logger.warning("[support_access] sweep failed: #{Exception.message(e)}")
    catch
      kind, reason -> Logger.warning("[support_access] sweep failed: #{inspect({kind, reason})}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :tick, Config.sweep_interval_ms())
end
