defmodule Platform.Agents.ModelRouteTest do
  @moduledoc """
  `Platform.Agents.ModelRoute.endpoint/1` (task 01a1e670 stage 1): the one
  endpoint rule, shared by the meeting intent classifier and the feedback
  intake classifier.

  async: false — reads and writes OLLAMA_BASE_URL.
  """

  use ExUnit.Case, async: false

  alias Platform.Agents.ModelRoute

  setup do
    saved = System.get_env("OLLAMA_BASE_URL")
    System.delete_env("OLLAMA_BASE_URL")

    on_exit(fn ->
      if saved,
        do: System.put_env("OLLAMA_BASE_URL", saved),
        else: System.delete_env("OLLAMA_BASE_URL")
    end)

    :ok
  end

  test "model plus base_url" do
    assert ModelRoute.endpoint(%{model: "qwen", base_url: "http://m.local/v1"}) ==
             {:ok, %{base_url: "http://m.local/v1", model: "qwen"}}
  end

  test "model plus env" do
    System.put_env("OLLAMA_BASE_URL", "http://ollama.local:11434/v1")

    assert ModelRoute.endpoint(%{model: "qwen", base_url: nil}) ==
             {:ok, %{base_url: nil, model: "qwen"}}
  end

  test "a blank base_url is passed on as nil when the env var is set" do
    System.put_env("OLLAMA_BASE_URL", "http://ollama.local:11434/v1")

    for blank <- ["", "   "] do
      assert ModelRoute.endpoint(%{model: "qwen", base_url: blank}) ==
               {:ok, %{base_url: nil, model: "qwen"}}
    end
  end

  test "a blank base_url with no env var is no_endpoint" do
    assert ModelRoute.endpoint(%{model: "qwen", base_url: "  "}) == {:error, :no_endpoint}
    System.put_env("OLLAMA_BASE_URL", "   ")
    assert ModelRoute.endpoint(%{model: "qwen", base_url: nil}) == {:error, :no_endpoint}
  end

  test "a blank model is no_endpoint, even with a base_url and the env var" do
    System.put_env("OLLAMA_BASE_URL", "http://ollama.local:11434/v1")

    for blank <- [nil, "", "  "] do
      assert ModelRoute.endpoint(%{model: blank, base_url: "http://m.local/v1"}) ==
               {:error, :no_endpoint}
    end
  end

  test "a nil agent and a map with neither field are no_endpoint" do
    assert ModelRoute.endpoint(nil) == {:error, :no_endpoint}
    assert ModelRoute.endpoint(%{}) == {:error, :no_endpoint}
  end
end
