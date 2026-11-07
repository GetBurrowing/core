defmodule Platform.InstructionPacks.Poller do
  @moduledoc """
  Sequential BEAM pull worker on the existing broker. Tries the next immutable
  version, so a manifest never supplies a destination or controls scheduling.
  Missing releases/network errors leave the last good contents active.
  """
  use GenServer
  alias Platform.InstructionPacks.{Check, Download, Installer, State}
  alias Platform.Repo

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    interval = Keyword.get(options, :interval, 900_000)
    send(self(), :poll)
    {:ok, interval}
  end

  @impl true
  def handle_info(:poll, interval) do
    poll()
    Process.send_after(self(), :poll, interval)
    {:noreply, interval}
  end

  def poll(options \\ []) do
    config = Application.get_env(:platform, :instruction_packs, [])
    roots = Keyword.get(config, :trust_roots, %{})

    result =
      with {:ok, snapshot} <- Installer.consent_snapshot() do
        Check.begin_check()

        with {:ok, packs} <- discover(Keyword.get(config, :packs, []), options) do
          results =
            for pack_id <- packs do
              state = Repo.get(State, pack_id)

              if state && state.pinned_version do
                :ok
              else
                next = if state && state.version, do: state.version + 1, else: 1

                Installer.pull(
                  pack_id,
                  next,
                  roots,
                  Keyword.put(options, :consent_snapshot, snapshot)
                )
              end
            end

          Enum.find(results, fn
            {:error, reason} -> reason not in [:release_unavailable, :pinned]
            _ -> false
          end) || :ok
        end
      end

    Check.finish(result)

    :ok
  end

  defp discover([], options), do: Download.catalog(options)
  defp discover(packs, _options), do: {:ok, packs}
end
