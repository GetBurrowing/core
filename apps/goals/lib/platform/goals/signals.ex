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

  Options: `:trigger_kind` (default "cron") and `:space_id`, the space the
  agent should answer in. `:space_id` goes in the signal's `metadata` ONLY,
  never at its top level: core's dispatcher reads the named space from
  `metadata.space_id` (`Platform.Chat.AgentResponder`'s `dispatch_space_id`),
  and a runtime pins a pending permission prompt's answer space from a
  TOP-LEVEL `space_id`, which a signal must not claim (task 01a1eab6
  stage 2).
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

    signal =
      case Keyword.get(opts, :space_id) do
        id when is_binary(id) -> put_in(signal, [:metadata, :space_id], id)
        _ -> signal
      end

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
