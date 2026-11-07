defmodule Platform.Experiments.Surfaces.AgentVoiceBlock do
  @moduledoc """
  The `agents.voice_block` experiment surface: the voice block a Burrow-run
  agent's prompt carries, and the banned-phrase list its replies are checked
  against. Subject: the agent.

  An arm is one full blob, `%{"block" => text, "banned" => [phrase]}`. The
  control is `Platform.Agents.VoiceBlock.text/0` and
  `Platform.Agents.VoiceCheck.default_banned/0`. It is resolved where the
  prompt is assembled (the native agent's start files and the built-in
  chat agent's frame), so the path is `:dispatch`.

  Whatever list an arm carries, hits are always COUNTED against
  `VoiceCheck.default_banned/0` (a shadow check), so an arm cannot win the
  metric by shrinking its own list.
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Agents.VoiceBlock
  alias Platform.Agents.VoiceCheck

  @target "agents.voice_block"
  @max_block_chars 8000
  @max_banned 200
  @keys ["banned", "block"]

  @impl true
  def key, do: @target

  @impl true
  def subject_type, do: "agent"

  @impl true
  def path, do: :dispatch

  @impl true
  def targets, do: [@target]

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["block", "banned"],
      "additionalProperties" => false,
      "properties" => %{
        "block" => %{
          "type" => "string",
          "maxLength" => @max_block_chars,
          "pattern" => "^" <> VoiceBlock.marker()
        },
        "banned" => %{
          "type" => "array",
          "maxItems" => @max_banned,
          "items" => %{"type" => "string", "minLength" => 1}
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    errors =
      unknown_key_errors(payload) ++
        block_errors(Map.get(payload, "block")) ++ banned_errors(Map.get(payload, "banned"))

    case errors do
      [] -> {:ok, %{"block" => payload["block"], "banned" => payload["banned"]}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_), do: {:error, ["payload must be an object with block and banned"]}

  @impl true
  def control_payload(_target, _opts \\ []),
    do: {:ok, %{"block" => VoiceBlock.text(), "banned" => VoiceCheck.default_banned()}}

  defp unknown_key_errors(payload) do
    case Map.keys(payload) -- @keys do
      [] -> []
      unknown -> ["unknown keys: #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}"]
    end
  end

  defp block_errors(block) when is_binary(block) do
    marker = VoiceBlock.marker()

    cond do
      not String.starts_with?(block, marker) ->
        ["block must start with #{inspect(marker)}"]

      String.length(block) > @max_block_chars ->
        ["block must be at most #{@max_block_chars} characters"]

      true ->
        []
    end
  end

  defp block_errors(_), do: ["block must be a string"]

  defp banned_errors(banned) when is_list(banned) do
    cond do
      length(banned) > @max_banned ->
        ["banned must have at most #{@max_banned} phrases"]

      not Enum.all?(banned, &(is_binary(&1) and String.trim(&1) != "")) ->
        ["banned must contain only non-empty strings"]

      true ->
        []
    end
  end

  defp banned_errors(_), do: ["banned must be a list of strings"]
end
