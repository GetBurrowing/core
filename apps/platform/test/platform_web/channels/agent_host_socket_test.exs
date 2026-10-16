defmodule PlatformWeb.AgentHostSocketTest do
  @moduledoc """
  The agent host's socket (task 01a10322 stage 2): a wrong or absent token is
  refused, and so is EVERY connection when no `AGENT_HOST_TOKEN` is set. The
  positive control is that the right token connects and joins, so the refusals
  are not a socket that refuses everything.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.AgentHost
  alias PlatformWeb.AgentHostSocket

  @token "agent-host-token-01a10322-0123456789abcdef"

  setup do
    previous = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :agent_host_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :agent_host_token, previous),
        else: Application.delete_env(:platform, :agent_host_token)
    end)

    :ok
  end

  defp connect_with(headers) do
    connect(AgentHostSocket, %{}, connect_info: %{x_headers: headers})
  end

  test "the right token connects and joins the control channel (positive control)" do
    assert {:ok, socket} = connect_with([{"x-agent-host-token", @token}])
    assert {:ok, _reply, _channel} = subscribe_and_join(socket, "agent_host:control", %{})
    assert AgentHost.connected?()
  end

  test "a wrong token is refused" do
    assert :error = connect_with([{"x-agent-host-token", @token <> "x"}])

    assert :error =
             connect_with([{"x-agent-host-token", "agent-host-token-01a10322-0123456789abcdeX"}])
  end

  test "an absent token is refused" do
    assert :error = connect_with([])
    assert :error = connect_with([{"x-agent-host-token", ""}])
    assert :error = connect(AgentHostSocket, %{"token" => @token}, connect_info: %{x_headers: []})
  end

  test "with no AGENT_HOST_TOKEN configured, every connection is refused" do
    Application.delete_env(:platform, :agent_host_token)

    refute AgentHost.configured?()
    assert AgentHost.describe() == "No agent host configured"
    assert :error = connect_with([{"x-agent-host-token", @token}])
    assert :error = connect_with([{"x-agent-host-token", ""}])
  end

  test "a second host is refused while one is connected" do
    {:ok, socket} = connect_with([{"x-agent-host-token", @token}])
    {:ok, _reply, _channel} = subscribe_and_join(socket, "agent_host:control", %{})

    {:ok, socket2} = connect_with([{"x-agent-host-token", @token}])

    assert {:error, %{reason: "already_connected"}} =
             subscribe_and_join(socket2, "agent_host:control", %{})
  end
end
