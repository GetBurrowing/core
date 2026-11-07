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
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces

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

  @doc """
  What `agent_id` gets on this surface: the arm's payload when a running
  experiment assigns it, else a promoted default, else the control. A nil
  agent id (the built-in chat agent called without one) gets the control.

  Never raises: `Surfaces.resolve/4` falls through to the default on any
  failure, and a default that does not validate is ignored for the control.
  """
  @spec for_agent(String.t() | nil) :: %{String.t() => term()}
  def for_agent(agent_id) when is_binary(agent_id) do
    case Surfaces.resolve(@target, @target, Subject.new("agent", agent_id)) do
      {:variant, _experiment, _slug, %{"block" => _, "banned" => _} = payload} -> payload
      {:default, payload} -> validated_or_control(payload)
      _ -> control()
    end
  end

  def for_agent(_agent_id), do: control()

  @doc "The control payload."
  @spec control() :: %{String.t() => term()}
  def control do
    {:ok, payload} = control_payload(@target)
    payload
  end

  defp validated_or_control(payload) do
    case validate_payload(payload) do
      {:ok, payload} -> payload
      {:error, _} -> control()
    end
  end

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
