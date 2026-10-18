defmodule Platform.Config.BurrowEnvFallbackTest do
  @moduledoc """
  Burrow rename (task 01a14b9e stage 1): `config/runtime.exs` reads
  BURROW_RUNNERD_BASE_URL / BURROW_RUNNERD_TOKEN first and falls back to the
  old SUITE_ names, printing one deprecation line per name on fallback. An
  empty string counts as unset.

  This evaluates the real runtime.exs under a controlled environment rather
  than unit-testing a copy of the reader, so a regression in the file itself
  is what fails here.
  """

  # Mutates process-global OS env vars.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)

  @names ~w(
    BURROW_RUNNERD_BASE_URL
    SUITE_RUNNERD_BASE_URL
    BURROW_RUNNERD_TOKEN
    SUITE_RUNNERD_TOKEN
  )

  @default_base_url "http://127.0.0.1:4101"

  @base_url_line "deprecated: SUITE_RUNNERD_BASE_URL is set; rename it to BURROW_RUNNERD_BASE_URL"
  @token_line "deprecated: SUITE_RUNNERD_TOKEN is set; rename it to BURROW_RUNNERD_TOKEN"

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

  defp count(haystack, needle) do
    haystack |> String.split("\n") |> Enum.count(&(&1 == needle))
  end

  defp deprecation_lines(stderr) do
    stderr |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "deprecated: "))
  end

  test "(a) only SUITE_ set: values reach :suite_runnerd with one line per name" do
    {runnerd, stderr} =
      read_runnerd(%{
        "SUITE_RUNNERD_BASE_URL" => "http://suite.example:1",
        "SUITE_RUNNERD_TOKEN" => "suite-token"
      })

    assert runnerd[:base_url] == "http://suite.example:1"
    assert runnerd[:token] == "suite-token"
    assert count(stderr, @base_url_line) == 1
    assert count(stderr, @token_line) == 1
  end

  test "(b) only BURROW_ set: values used, no deprecation line" do
    {runnerd, stderr} =
      read_runnerd(%{
        "BURROW_RUNNERD_BASE_URL" => "http://burrow.example:2",
        "BURROW_RUNNERD_TOKEN" => "burrow-token"
      })

    assert runnerd[:base_url] == "http://burrow.example:2"
    assert runnerd[:token] == "burrow-token"
    assert deprecation_lines(stderr) == []
  end

  test "(c) both set to different values: BURROW_ wins, no deprecation line" do
    {runnerd, stderr} =
      read_runnerd(%{
        "BURROW_RUNNERD_BASE_URL" => "http://burrow.example:3",
        "SUITE_RUNNERD_BASE_URL" => "http://suite.example:3",
        "BURROW_RUNNERD_TOKEN" => "burrow-token-3",
        "SUITE_RUNNERD_TOKEN" => "suite-token-3"
      })

    assert runnerd[:base_url] == "http://burrow.example:3"
    assert runnerd[:token] == "burrow-token-3"
    assert deprecation_lines(stderr) == []
  end

  test "(d) BURROW_ empty with SUITE_ set: the SUITE_ value is used, one line per name" do
    {runnerd, stderr} =
      read_runnerd(%{
        "BURROW_RUNNERD_BASE_URL" => "",
        "SUITE_RUNNERD_BASE_URL" => "http://suite.example:4",
        "BURROW_RUNNERD_TOKEN" => "",
        "SUITE_RUNNERD_TOKEN" => "suite-token-4"
      })

    assert runnerd[:base_url] == "http://suite.example:4"
    assert runnerd[:token] == "suite-token-4"
    assert count(stderr, @base_url_line) == 1
    assert count(stderr, @token_line) == 1
  end

  test "(e) neither set: base_url keeps its default and token is nil" do
    {runnerd, stderr} = read_runnerd(%{})

    assert runnerd[:base_url] == @default_base_url
    assert runnerd[:token] == nil
    assert deprecation_lines(stderr) == []
  end
end
