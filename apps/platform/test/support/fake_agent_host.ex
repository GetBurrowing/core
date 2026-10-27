defmodule Platform.FakeAgentHost do
  @moduledoc """
  A stand-in for the install's agent host (services/agent-host), for tests. It
  registers as the host with `Platform.AgentHost.Reconciler`, serves
  `agent.file_read` from a tmp directory (the agents' work dirs, one
  sub-directory per agent id) and reports `agent.state`.
  """
  use GenServer

  alias Platform.AgentHost.Reconciler

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Report an agent's observed state, with any extra payload keys."
  def report(pid, agent_id, state, extra \\ %{}),
    do: GenServer.call(pid, {:report, agent_id, state, extra})

  @impl true
  def init(opts) do
    :ok = Reconciler.host_joined(self(), %{"profile" => "contained"})
    {:ok, %{root: Keyword.fetch!(opts, :root)}}
  end

  @impl true
  def handle_call({:report, agent_id, state, extra}, _from, s) do
    payload = Map.merge(%{"agent_id" => agent_id, "state" => state}, extra)
    {:reply, Reconciler.agent_state(self(), payload), s}
  end

  @impl true
  def handle_info(
        {:agent_host_push, "agent.file_read", %{"agent_id" => id, "key" => key, "ref" => ref}},
        s
      ) do
    payload =
      case File.read(Path.join([s.root, id, key])) do
        {:ok, bytes} ->
          %{
            "content" => bytes,
            "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
          }

        {:error, _} ->
          %{"error" => "not_found"}
      end

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      Platform.AgentHost.file_topic(ref),
      {:agent_host_file, ref, payload}
    )

    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}
end
