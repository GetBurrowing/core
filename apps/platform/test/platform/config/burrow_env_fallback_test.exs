defmodule Platform.Config.BurrowEnvFallbackTest do
  @moduledoc """
  Burrow rename (task 01a18dab stage 2): `config/runtime.exs` reads
  BURROW_RUNNERD_BASE_URL / BURROW_RUNNERD_TOKEN only. The old SUITE_ names
  are ignored: no fallback and no deprecation line. An empty string counts as
  unset.

  This evaluates the real runtime.exs under a controlled environment rather
  than unit-testing a copy of the reader, so a regression in the file itself
  is what fails here.

  The legacy names are BUILT here ("SUITE" <> "_...") so this file does not
  itself carry a SUITE_ token for the repo guard
  (test/platform/regression/burrow_env_fallback_guard_test.exs) to flag.
  """

  # Mutates process-global OS env vars.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)

  @legacy_base_url "SUITE" <> "_RUNNERD_BASE_URL"
  @legacy_token "SUITE" <> "_RUNNERD_TOKEN"

  @names [
    "BURROW_RUNNERD_BASE_URL",
    "BURROW_RUNNERD_TOKEN",
    @legacy_base_url,
    @legacy_token
  ]

  @default_base_url "http://127.0.0.1:4101"

  setup do
    saved = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp read_runnerd(env) do
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

    stderr =
      capture_io(:stderr, fn ->
        config = Config.Reader.read!(@runtime_exs, env: :test)
        send(self(), {:runnerd, get_in(config, [:platform, :execution, :suite_runnerd])})
      end)

    assert_received {:runnerd, runnerd}
    {runnerd, stderr}
  end

  defp deprecation_lines(stderr) do
    stderr |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "deprecated: "))
  end

  test "only the legacy base URL set: it is ignored, default used, no deprecation line" do
    {runnerd, stderr} = read_runnerd(%{@legacy_base_url => "http://suite.example:1"})

    assert runnerd[:base_url] == @default_base_url
    assert runnerd[:token] == nil
    assert deprecation_lines(stderr) == []
  end

  test "only the legacy token set: it is ignored, token stays nil" do
    {runnerd, stderr} = read_runnerd(%{@legacy_token => "suite-token"})

    assert runnerd[:token] == nil
    assert deprecation_lines(stderr) == []
  end

  test "BURROW_ set: values used, no deprecation line" do
    {runnerd, stderr} =
      read_runnerd(%{
        "BURROW_RUNNERD_BASE_URL" => "http://burrow.example:2",
        "BURROW_RUNNERD_TOKEN" => "burrow-token"
      })

    assert runnerd[:base_url] == "http://burrow.example:2"
    assert runnerd[:token] == "burrow-token"
    assert deprecation_lines(stderr) == []
  end

  test "BURROW_ empty with the legacy names set: defaults, the legacy values are not used" do
    {runnerd, stderr} =
      read_runnerd(%{
        "BURROW_RUNNERD_BASE_URL" => "",
        @legacy_base_url => "http://suite.example:4",
        "BURROW_RUNNERD_TOKEN" => "",
        @legacy_token => "suite-token-4"
      })

    assert runnerd[:base_url] == @default_base_url
    assert runnerd[:token] == nil
    assert deprecation_lines(stderr) == []
  end

  test "neither set: base_url keeps its default and token is nil" do
    {runnerd, stderr} = read_runnerd(%{})

    assert runnerd[:base_url] == @default_base_url
    assert runnerd[:token] == nil
    assert deprecation_lines(stderr) == []
  end
end
