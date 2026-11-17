defmodule Platform.Agents.ModelRoute do
  @moduledoc """
  The one rule for "can this agent's own model be called?" (task 01a1e670
  stage 1).

  Moved verbatim out of `Platform.Meetings.IntentModel.route/1`, so the
  meeting intent classifier and the feedback intake classifier ask the same
  question the same way, and no caller re-derives it.

  `endpoint/1` returns `{:ok, %{base_url: b, model: m}}` when the agent has a
  non-blank `model` AND either a non-blank `base_url` or a non-blank
  `OLLAMA_BASE_URL`. In the env-var case `b` is nil, because the Ollama
  adapter falls back to `OLLAMA_BASE_URL` only when `:base_url` is nil.
  Every other agent, including a nil agent, is `{:error, :no_endpoint}`.

  "Blank" means `nil`, `""` or whitespace only.
  """

  @type endpoint :: %{base_url: String.t() | nil, model: String.t()}

  @doc "The agent's own model endpoint, or `{:error, :no_endpoint}`."
  @spec endpoint(map() | nil) :: {:ok, endpoint()} | {:error, :no_endpoint}
  def endpoint(agent) do
    model = agent_field(agent, :model)
    base_url = agent_field(agent, :base_url)

    cond do
      present?(model) and present?(base_url) ->
        {:ok, %{base_url: base_url, model: model}}

      # The Ollama adapter falls back to OLLAMA_BASE_URL only when :base_url
      # is nil, so a blank agent base_url is passed on as nil.
      present?(model) and present?(System.get_env("OLLAMA_BASE_URL")) ->
        {:ok, %{base_url: nil, model: model}}

      true ->
        {:error, :no_endpoint}
    end
  end

  @doc "True for a binary with at least one non-whitespace character."
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_), do: false

  defp agent_field(%{} = agent, key), do: Map.get(agent, key)
  defp agent_field(_, _), do: nil
end
