defmodule Platform.GameStream.ApplicationTest do
  @moduledoc """
  Play's own OTP application (ADR 0055, task 01a0ee08 stage 3): it, not
  core, starts Play's process tree, after core, and reads Play's runtime
  settings from the OS environment at boot.

  NOT async: the `apply/1` cases write `:game_stream, :enabled` and
  `:game_stream, :turn` (global app env), restored on exit.
  """

  use ExUnit.Case, async: false

  alias Platform.GameStream.RuntimeConfig

  setup do
    saved = Map.new([:enabled, :turn], &{&1, Application.fetch_env(:game_stream, &1)})

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:game_stream, key, v)
          :error -> Application.delete_env(:game_stream, key)
        end
      end
    end)
  end

  test "Play's tree is started by Play's application, not by core's" do
    assert {:ok, _} = Application.ensure_all_started(:game_stream)
    app_sup = Platform.GameStream.Application.Supervisor

    assert [{Platform.GameStream.Supervisor, pid, :supervisor, _}] =
             Supervisor.which_children(app_sup)

    assert is_pid(pid)

    refute Enum.any?(
             Supervisor.which_children(Platform.Supervisor),
             &(elem(&1, 0) == Platform.GameStream.Supervisor)
           )

    # OTP order: core first, then the module that depends on it.
    started = Enum.map(Application.started_applications(), &elem(&1, 0))

    assert Enum.find_index(started, &(&1 == :game_stream)) <
             Enum.find_index(started, &(&1 == :platform)),
           "started_applications/0 lists newest first: :game_stream must be newer than :platform"
  end

  test "GAME_STREAM_ENABLED: only \"true\" and \"1\" turn Play on" do
    for {value, expected} <- [
          {"true", true},
          {"1", true},
          {"false", false},
          {"yes", false},
          {"", false},
          {nil, false}
        ] do
      env = if value, do: %{"GAME_STREAM_ENABLED" => value}, else: %{}
      assert RuntimeConfig.read(env)[:enabled] == expected, "#{inspect(value)}"
    end
  end

  test "apply/1 puts the settings in Play's app env, and core's app env gains none" do
    platform_env_before = Application.get_all_env(:platform) |> Keyword.keys() |> MapSet.new()

    :ok =
      RuntimeConfig.apply(%{
        "GAME_STREAM_ENABLED" => "1",
        "GAME_STREAM_TURN_URLS" => "turn:a.example:3479",
        "GAME_STREAM_TURN_USERNAME" => " gs "
      })

    assert Application.get_env(:game_stream, :enabled) == true

    assert Application.get_env(:game_stream, :turn) ==
             [urls: ["turn:a.example:3479"], username: "gs", credential: nil]

    assert Platform.GameStream.enabled?()

    platform_env_after = Application.get_all_env(:platform) |> Keyword.keys() |> MapSet.new()
    assert platform_env_after == platform_env_before

    :ok = RuntimeConfig.apply(%{})
    refute Platform.GameStream.enabled?()
  end

  describe "web role (task 01a155a6)" do
    alias Platform.GameStream.Application, as: App

    test "every child is classified exactly once" do
      ids = Enum.map(App.children(:full), &Platform.Role.child_id/1)
      unclassified = ids -- (App.web_ids() ++ App.background_ids())
      assert unclassified == [], "unclassified Play children: #{inspect(unclassified)}"
      assert MapSet.disjoint?(MapSet.new(App.web_ids()), MapSet.new(App.background_ids()))
    end

    test "the web role starts Play's inert supervisor, and :full keeps today's list" do
      assert App.children(:web) == [Platform.GameStream.Supervisor]
      assert App.children(:full) == [Platform.GameStream.Supervisor]
    end
  end
end
