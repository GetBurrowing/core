defmodule Platform.Agents.Providers.ProviderTimeoutsTest do
  @moduledoc """
  A cross-adapter guard: every provider's *default* `Req` client must carry a
  positive-integer `receive_timeout`.

  A bare `Req.new()` inherits Finch's default, which for a stalled model call
  means the caller waits far longer than any of these adapters intends. Ollama
  shipped exactly that omission; this test exists so the next adapter cannot.

  The assertion is made against the runtime `%Req.Request{}` each module builds,
  not against the source text, so setting the option somewhere the request never
  reads does not satisfy it.
  """

  use ExUnit.Case, async: false

  alias Platform.Agents.Providers.Anthropic
  alias Platform.Agents.Providers.Codex
  alias Platform.Agents.Providers.Ollama
  alias Platform.Agents.Providers.OpenAI

  # {module, app-env key that overrides the client wholesale, source basename}.
  # The basename is spelled out rather than derived: `OpenAI` underscores to
  # "open_ai", which would never match the file on disk.
  @providers [
    {OpenAI, :openai_req_client, "openai"},
    {Anthropic, :anthropic_req_client, "anthropic"},
    {Codex, :codex_req_client, "codex"},
    {Ollama, :ollama_req_client, "ollama"}
  ]

  @providers_dir Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "..",
                   "lib",
                   "platform",
                   "agents",
                   "providers"
                 ])

  describe "default Req client" do
    test "covers every provider module that builds one" do
      on_disk =
        @providers_dir
        |> Path.join("*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(&1 |> File.read!() |> String.contains?("def req_client")))
        |> Enum.map(&Path.basename(&1, ".ex"))
        |> MapSet.new()

      covered =
        @providers
        |> Enum.map(fn {_mod, _key, basename} -> basename end)
        |> MapSet.new()

      assert MapSet.size(covered) == 4,
             "expected 4 providers under guard, got #{MapSet.size(covered)}"

      assert MapSet.equal?(on_disk, covered),
             """
             provider modules building a Req client do not match the guarded list.
             Unguarded (add them to @providers): #{inspect(MapSet.to_list(MapSet.difference(on_disk, covered)))}
             Guarded but absent from disk: #{inspect(MapSet.to_list(MapSet.difference(covered, on_disk)))}
             """
    end

    for {module, env_key, _basename} <- @providers do
      test "#{inspect(module)} sets a positive-integer receive_timeout" do
        module = unquote(module)
        env_key = unquote(env_key)

        # The guard is about the *default* client, so drop any injected override.
        previous = Application.fetch_env(:platform, env_key)
        Application.delete_env(:platform, env_key)

        on_exit(fn ->
          case previous do
            {:ok, value} -> Application.put_env(:platform, env_key, value)
            :error -> Application.delete_env(:platform, env_key)
          end
        end)

        client = module.req_client()

        assert %Req.Request{} = client,
               "#{inspect(module)}.req_client/0 did not return a Req.Request"

        timeout = client.options[:receive_timeout]

        assert is_integer(timeout) and timeout > 0,
               """
               #{inspect(module)} builds its default Req client without a usable \
               receive_timeout (got #{inspect(timeout)}).

               A bare `Req.new()` leaves a stalled model call to hang on Finch's \
               default. Pass `receive_timeout:` in #{inspect(module)}.req_client/0.
               """
      end
    end
  end
end
