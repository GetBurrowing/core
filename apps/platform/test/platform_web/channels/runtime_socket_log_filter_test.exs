defmodule PlatformWeb.RuntimeSocketLogFilterTest do
  @moduledoc """
  Task 01a0d8ba — `Phoenix.Logger.phoenix_socket_connected/4` prints the
  socket connect params at the socket's `:log` level (`:info` by default,
  which prod prints). Without `config :phoenix, :filter_parameters` covering
  `"token"`, a refused `PlatformWeb.RuntimeSocket` connect logged the
  runtime's bearer token in cleartext.

  The connect line is emitted by Phoenix, not by `RuntimeSocket.connect/3`,
  so these tests drive the real `Phoenix.Socket.__connect__/3` path via
  `Phoenix.ChannelTest.connect/2` and read the captured log.

  `"vsn"` is deliberately omitted from the params: `Phoenix.ChannelTest`
  negotiates against `NoopSerializer "~> 1.0.0"`, so a `"2.0.0"` vsn fails
  serializer negotiation BEFORE telemetry fires and no connect line is
  logged at all — which would make every refute below vacuous.
  """

  use PlatformWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Repo

  @sentinel "tok-SENTINEL-01a0d8ba"

  setup do
    # test.exs sets the Logger level to :warning, which drops the :info
    # connect line at source. Lower it for this file and restore afterwards.
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "a refused connect logs the Parameters line with the token filtered" do
    log =
      capture_log([level: :info], fn ->
        assert :error =
                 connect(PlatformWeb.RuntimeSocket, %{
                   "runtime_id" => "rt-01a0d8ba-absent",
                   "token" => @sentinel
                 })
      end)

    assert log =~ "REFUSED CONNECTION TO PlatformWeb.RuntimeSocket"
    # Positive control: the Parameters line is in the capture.
    assert log =~ "rt-01a0d8ba-absent"
    # The property itself; checked first so a filter regression fails HERE.
    refute log =~ @sentinel
    assert log =~ ~s("token" => "[FILTERED]")
  end

  test "an accepted connect logs the Parameters line without the raw token" do
    {runtime, raw_token} = runtime_fixture()

    log =
      capture_log([level: :info], fn ->
        assert {:ok, _socket} =
                 connect(PlatformWeb.RuntimeSocket, %{
                   "runtime_id" => runtime.runtime_id,
                   "token" => raw_token
                 })
      end)

    assert log =~ "CONNECTED TO PlatformWeb.RuntimeSocket"
    assert log =~ runtime.runtime_id
    refute log =~ raw_token
    assert log =~ ~s("token" => "[FILTERED]")
  end

  # Mirrors `runtime_for/3` in test/security/runtime_channel_capability_test.exs.
  defp runtime_fixture do
    owner = World.create_user!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "rt-01a0d8ba-agent-#{unique()}",
        name: "RuntimeSocket Log Filter Agent",
        status: "active"
      })
      |> Repo.insert()

    raw_token = AgentRuntime.generate_token()

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "rt-01a0d8ba-valid-#{unique()}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw_token),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        ["federation"],
        Platform.Access.RuntimeProfiles.translated_permissions(["federation"])
      )

    {runtime, raw_token}
  end

  defp unique, do: System.unique_integer([:positive])
end
