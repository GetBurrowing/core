defmodule Platform.Meetings.IntentModelTest do
  @moduledoc """
  Task 01a1e5da stage 1: the install-level model route for the meeting
  intent classifier. `route/1` is the one place that decides whether a
  chunk goes to the assignee's own endpoint, to the install-level hosted
  provider, or nowhere.
  """

  # Mutates OLLAMA_BASE_URL, a test-owned key env var and the :platform app env.
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Agents.Providers.Anthropic
  alias Platform.Meetings.IntentModel

  @key_env "MEETINGS_INTENT_MODEL_TEST_KEY"
  @app_keys [:meetings_intent_model, :meetings_intent_provider]
  @os_keys ["OLLAMA_BASE_URL", @key_env]

  defmodule SeamProvider do
    @moduledoc false
    def chat(_credentials, _messages, _opts), do: {:ok, %{content: "{}"}}
  end

  setup do
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:platform, &1)})
    saved_os = Map.new(@os_keys, &{&1, System.get_env(&1)})

    Enum.each(@app_keys, &Application.delete_env(:platform, &1))
    Enum.each(@os_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved_app, fn
        {key, {:ok, value}} -> Application.put_env(:platform, key, value)
        {key, :error} -> Application.delete_env(:platform, key)
      end)

      Enum.each(saved_os, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp native(attrs \\ %{}),
    do: struct(Agent, Map.merge(%{kind: "native", base_url: nil, model: nil}, attrs))

  defp external(attrs \\ %{}) do
    struct(
      Agent,
      Map.merge(
        %{kind: "external", base_url: "http://intent.example:11434", model: "qwen-intent"},
        attrs
      )
    )
  end

  defp configure(map), do: Application.put_env(:platform, :meetings_intent_model, map)

  describe "config/0" do
    test "defaults to provider :none" do
      assert IntentModel.config() == %{
               provider: :none,
               model: nil,
               base_url: nil,
               api_key_env: nil
             }
    end

    test "an unknown provider string fails closed to :none" do
      configure(%{"provider" => "bogus", "model" => "m"})

      assert IntentModel.config().provider == :none
      assert IntentModel.route(native()) == {:error, :not_configured}
    end

    test "unknown keys are dropped" do
      configure(%{provider: "anthropic", system_prompt: "x", nonsense: 1})

      assert Map.keys(IntentModel.config()) |> Enum.sort() ==
               [:api_key_env, :base_url, :model, :provider]
    end
  end

  describe "route/1" do
    test "external agent with base_url + model routes to the assignee even when a provider is configured" do
      configure(%{provider: :anthropic, model: "claude-x"})

      assert IntentModel.route(external()) ==
               {:assignee, %{base_url: "http://intent.example:11434", model: "qwen-intent"}}
    end

    test "native agent, no OLLAMA_BASE_URL, provider :none => not configured" do
      assert IntentModel.route(native()) == {:error, :not_configured}
    end

    test "native agent with blank base_url is not usable" do
      # The model is set so only the base_url check can decide this.
      assert IntentModel.route(native(%{base_url: "  ", model: "qwen-intent"})) ==
               {:error, :not_configured}

      assert IntentModel.route(native(%{base_url: "", model: "qwen-intent"})) ==
               {:error, :not_configured}
    end

    test "blank model is not usable even with a base_url" do
      assert IntentModel.route(native(%{base_url: "http://x:1", model: " "})) ==
               {:error, :not_configured}
    end

    test "native agent with a model and OLLAMA_BASE_URL set keeps today's assignee route" do
      System.put_env("OLLAMA_BASE_URL", "http://ollama.example:11434")

      assert IntentModel.route(native(%{model: "qwen-intent"})) ==
               {:assignee, %{base_url: nil, model: "qwen-intent"}}
    end

    test "a blank OLLAMA_BASE_URL does not count" do
      System.put_env("OLLAMA_BASE_URL", "   ")

      assert IntentModel.route(native(%{model: "qwen-intent"})) == {:error, :not_configured}
    end

    test "provider anthropic + api_key_env set => hosted Anthropic with the env key" do
      System.put_env(@key_env, "sk-test-value")
      configure(%{provider: "anthropic", model: "claude-x", api_key_env: @key_env})

      assert {:hosted, route} = IntentModel.route(native())
      assert route.provider == :anthropic
      assert route.module == Anthropic
      assert %{api_key: "sk-test-value"} = route.credentials
      assert route.model == "claude-x"
      assert route.base_url == nil
    end

    test "provider anthropic with no env key falls back to the platform Vault slug" do
      configure(%{provider: :anthropic})

      assert {:hosted, %{credentials: %{credential_slug: "anthropic"}, model: nil}} =
               IntentModel.route(native())
    end

    test "provider ollama carries base_url and needs no credentials" do
      configure(%{provider: :ollama, model: "qwen", base_url: "http://ollama.internal:11434"})

      assert {:hosted,
              %{
                provider: :ollama,
                credentials: %{},
                base_url: "http://ollama.internal:11434"
              }} = IntentModel.route(native())
    end

    test "the :meetings_intent_provider seam wins over the built-in adapter" do
      Application.put_env(:platform, :meetings_intent_provider, SeamProvider)
      configure(%{provider: :openai})

      assert {:hosted, %{provider: :openai, module: SeamProvider}} = IntentModel.route(native())
    end

    test "nil agent => not configured when nothing is set" do
      assert IntentModel.route(nil) == {:error, :not_configured}
    end
  end

  describe "status/0" do
    defp assign!(attrs) do
      agent =
        %Agent{}
        |> Agent.changeset(
          Map.merge(
            %{
              slug: "intent-model-#{System.unique_integer([:positive])}",
              name: "Intent Model Agent",
              status: "active"
            },
            attrs
          )
        )
        |> Repo.insert!()

      {:ok, _} = Platform.Roles.set_override("meetings.intent_classify", agent.id)
      agent
    end

    test "no meetings.intent_classify assignee => {:off, :no_assignee}, even with a provider" do
      configure(%{provider: :anthropic})

      assert IntentModel.status() == {:off, :no_assignee}
    end

    test "native assignee and nothing configured => {:off, :not_configured}" do
      assign!(%{})

      assert IntentModel.status() == {:off, :not_configured}
    end

    test "native assignee with a provider configured => :ok" do
      assign!(%{})
      configure(%{provider: "anthropic"})

      assert IntentModel.status() == :ok
    end
  end
end
