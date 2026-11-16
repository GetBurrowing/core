defmodule Platform.Goals.Signals do
  @moduledoc """
  The one sender of content-free signals from Goals to an agent's runtime
  (lifted from Goals 3/8's clock by task 01a1dfc1-7625, Goals 5/8). The clock
  and the New goal conversation both send through `deliver/4`.

  A signal carries identifiers only: core stores an undelivered signal's
  payload in its dead-letter ledger, which admins can read, so a prompt must
  never hold a person's words, a title or a setting.

  The dispatcher is injectable: `Application.get_env(:goals,
  :wake_up_dispatcher, {Platform.Chat.AgentResponder, :respond})`, either a
  `{module, function}` or a one-argument function.
  """

  @type delivery :: String.t()

  @doc """
  Sends `prompt` to `agent`'s runtime under `responsibility_key` and returns
  the delivery value: "sent", "offline", "failed" or "no_runtime".
  """
  @spec deliver(term(), String.t(), String.t(), keyword()) :: delivery()
  def deliver(agent, responsibility_key, prompt, opts \\ [])

  def deliver(%{runtime_type: "external", runtime_id: id} = agent, key, prompt, opts)
      when is_binary(id) do
    signal = %{
      reason: :system_event,
      metadata: %{
        agent_id: agent.id,
        agent_slug: agent.slug,
        responsibility_key: key,
        feature: "goals",
        trigger_kind: Keyword.get(opts, :trigger_kind, "cron"),
        prompt: prompt,
        prompt_status: :rendered
      }
    }

    dispatcher =
      Application.get_env(:goals, :wake_up_dispatcher, {Platform.Chat.AgentResponder, :respond})

    result =
      case dispatcher do
        {module, function} -> apply(module, function, [signal])
        function when is_function(function, 1) -> function.(signal)
      end

    case result do
      :ok -> "sent"
      {:error, :runtime_offline} -> "offline"
      _ -> "failed"
    end
  rescue
    _ -> "failed"
  end

  def deliver(_agent, _key, _prompt, _opts), do: "no_runtime"
end
