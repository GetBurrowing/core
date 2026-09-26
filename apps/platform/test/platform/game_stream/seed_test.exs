defmodule Platform.GameStream.SeedTest do
  @moduledoc """
  `Platform.GameStream.Seed.run/1` (task 01a0db5f stage 2): the play host's
  agent and runtime, declaring `game_stream_host`, granted no bundles, with
  its token written ONLY to the file named by `:token_path`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation
  alias Platform.GameStream.Seed
  alias Platform.Repo

  setup do
    user =
      Repo.insert!(%User{
        email: "seed-#{System.unique_integer([:positive])}@example.com",
        name: "Seed Owner",
        oidc_sub: "seed-#{System.unique_integer([:positive])}"
      })

    %{user: user, runtime_id: "play-host-seed-#{System.unique_integer([:positive])}"}
  end

  @tag :tmp_dir
  test "creates the host row, writes the token only to the file", ctx do
    path = Path.join(ctx.tmp_dir, "secrets/runtime-token")

    {result, log} =
      with_log(fn ->
        Seed.run(owner_email: ctx.user.email, token_path: path, runtime_id: ctx.runtime_id)
      end)

    assert {:ok, %{runtime: runtime, agent: agent, token_written: true}} = result
    token = File.read!(path)
    assert byte_size(token) > 16
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

    # The token is nowhere but the file: not in the result, not in the log.
    refute inspect(result) =~ token
    refute log =~ token

    assert runtime.runtime_id == ctx.runtime_id
    assert runtime.agent_id == agent.id
    assert runtime.allowed_bundles == []
    assert runtime.status == "active"
    assert Federation.declared_features(runtime.metadata) == ["game_stream_host"]
    assert %AgentRuntime{} = Federation.get_runtime_by_token(token)
  end

  @tag :tmp_dir
  test "a rerun reuses the row and leaves the token file alone; rotate mints anew", ctx do
    path = Path.join(ctx.tmp_dir, "token")
    opts = [owner_email: ctx.user.email, token_path: path, runtime_id: ctx.runtime_id]

    {:ok, %{runtime: first}} = Seed.run(opts)
    token = File.read!(path)

    assert {:ok, %{runtime: again, token_written: false}} = Seed.run(opts)
    assert again.id == first.id
    assert File.read!(path) == token

    assert {:ok, %{token_written: true}} = Seed.run(Keyword.put(opts, :rotate, true))
    refute File.read!(path) == token
    assert Federation.get_runtime_by_token(token) == nil
  end

  test "an unknown owner or a missing option is refused", ctx do
    assert {:error, :unknown_owner} =
             Seed.run(owner_email: "nobody-#{ctx.runtime_id}@example.com", token_path: "/x")

    assert {:error, {:missing_option, :token_path}} = Seed.run(owner_email: ctx.user.email)
  end
end
