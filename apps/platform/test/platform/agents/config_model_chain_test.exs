defmodule Platform.Agents.ConfigModelChainTest do
  @moduledoc """
  `Config.model_chain/2`, moved from the deleted agents router module
  (task 01a10322 stage 1) together with the cases that pinned it there.
  """
  use Platform.DataCase, async: true

  alias Platform.Agents.{Agent, Config}
  alias Platform.Repo

  defp create_agent(attrs) do
    default = %{
      slug: "chain-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Chain Agent",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    default
    |> Map.merge(attrs)
    |> then(&Agent.changeset(%Agent{}, &1))
    |> Repo.insert!()
  end

  describe "model_chain/2" do
    test "returns the resolved primary-plus-fallback chain" do
      agent =
        create_agent(%{
          model_config: %{
            "primary" => "anthropic/claude-sonnet-4-6",
            "fallbacks" => ["openai-codex/gpt-5.4", "anthropic/claude-opus-4-6"]
          }
        })

      assert {:ok, chain} = Config.model_chain(agent.id)

      assert chain == [
               "anthropic/claude-sonnet-4-6",
               "openai-codex/gpt-5.4",
               "anthropic/claude-opus-4-6"
             ]
    end

    test "drops blanks and duplicates, and honours a :model override" do
      agent =
        create_agent(%{
          model_config: %{
            "primary" => "anthropic/a",
            "fallbacks" => ["", "anthropic/a", "openai/b"]
          }
        })

      assert {:ok, ["anthropic/a", "openai/b"]} = Config.model_chain(agent)

      assert {:ok, ["openai/x", "openai/y"]} =
               Config.model_chain(agent, model: "openai/x", fallbacks: ["openai/y"])
    end

    test "an empty chain and a malformed key are errors" do
      assert {:error, :no_models_configured} =
               Config.model_chain(create_agent(%{model_config: %{}}))

      assert {:error, {:invalid_model, "no-slash"}} =
               Config.model_chain(create_agent(%{model_config: %{"primary" => "no-slash"}}))
    end
  end

  # UUID boundary (task 019fa129 stage 4): a 16-character slug is a 16-byte
  # binary that a bare Ecto.UUID.cast/1 accepts, which once sent it down the
  # id branch where the strict UUIDv7 key raised. Assert the RESOLUTION, not
  # merely the absence of a raise.
  describe "UUID boundary: a 16-character slug" do
    test "resolves an agent whose slug is exactly 16 characters" do
      slug = "higginshigginsxx"
      assert byte_size(slug) == 16
      # The precondition that makes this test non-vacuous:
      assert {:ok, _} = Ecto.UUID.cast(slug)

      create_agent(%{slug: slug})

      assert {:ok, [_ | _]} = Config.model_chain(slug)
    end

    test "an unknown 16-character slug is :not_found, not a raise" do
      assert {:error, :not_found} = Config.model_chain("nosuchagentxxxxx")
    end

    test "an agent id still resolves" do
      agent = create_agent(%{})
      assert {:ok, [_ | _]} = Config.model_chain(agent.id)
    end
  end
end
