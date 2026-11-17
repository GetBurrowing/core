defmodule Platform.Config.MeetingsIntentEnvTest do
  @moduledoc """
  Task 01a1e5da stage 1: `config/runtime.exs` reads MEETINGS_INTENT_PROVIDER,
  MEETINGS_INTENT_MODEL, MEETINGS_INTENT_BASE_URL and MEETINGS_INTENT_API_KEY
  into `config :platform, :meetings_intent_model`. Unset or blank provider
  leaves the key unset. The API key's VALUE never enters config: only the
  env var's name does (`api_key_env`).

  Evaluates the real runtime.exs under a controlled environment, like
  `Platform.Config.BurrowEnvFallbackTest`, so a regression in the file
  itself is what fails here.
  """

  # Mutates process-global OS env vars.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_exs Path.expand("../../../config/runtime.exs", __DIR__)

  @names [
    "MEETINGS_INTENT_PROVIDER",
    "MEETINGS_INTENT_MODEL",
    "MEETINGS_INTENT_BASE_URL",
    "MEETINGS_INTENT_API_KEY"
  ]

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

  defp read_platform(env) do
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

    capture_io(:stderr, fn ->
      config = Config.Reader.read!(@runtime_exs, env: :test)
      send(self(), {:platform, Keyword.get(config, :platform, [])})
    end)

    assert_received {:platform, platform}
    platform
  end

  test "nothing set: the key is absent" do
    refute Keyword.has_key?(read_platform(%{}), :meetings_intent_model)
  end

  test "blank provider: the key is absent even when the other vars are set" do
    platform =
      read_platform(%{
        "MEETINGS_INTENT_PROVIDER" => "   ",
        "MEETINGS_INTENT_MODEL" => "claude-x",
        "MEETINGS_INTENT_API_KEY" => "sk-should-not-matter"
      })

    refute Keyword.has_key?(platform, :meetings_intent_model)
  end

  test "provider + key: provider atom and the key's NAME, never its value" do
    secret = "sk-intent-#{System.unique_integer([:positive])}"

    platform =
      read_platform(%{
        "MEETINGS_INTENT_PROVIDER" => " Anthropic ",
        "MEETINGS_INTENT_API_KEY" => secret
      })

    intent = Keyword.fetch!(platform, :meetings_intent_model)

    assert intent == %{
             provider: :anthropic,
             model: nil,
             base_url: nil,
             api_key_env: "MEETINGS_INTENT_API_KEY"
           }

    refute inspect(platform, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  test "model and base_url are read; no key var means no api_key_env" do
    platform =
      read_platform(%{
        "MEETINGS_INTENT_PROVIDER" => "ollama",
        "MEETINGS_INTENT_MODEL" => "qwen3:4b",
        "MEETINGS_INTENT_BASE_URL" => "http://ollama.internal:11434",
        "MEETINGS_INTENT_API_KEY" => ""
      })

    assert Keyword.fetch!(platform, :meetings_intent_model) == %{
             provider: :ollama,
             model: "qwen3:4b",
             base_url: "http://ollama.internal:11434",
             api_key_env: nil
           }
  end

  test "an unknown provider string reads as :none, never a new atom" do
    platform = read_platform(%{"MEETINGS_INTENT_PROVIDER" => "bogus"})

    assert Keyword.fetch!(platform, :meetings_intent_model).provider == :none
  end
end
