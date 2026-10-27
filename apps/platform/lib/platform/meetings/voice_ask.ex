defmodule Platform.Meetings.VoiceAsk do
  @moduledoc """
  Behaviour of the `voice_ask` bundle (task 01a17b10 stage 4). Definitions,
  and why the tools are a bundle of their own, are in
  `Platform.Federation.VoiceAskTools`.

  ## Asking: the ordinary attention path, nothing new

  `voice_ask_agent` posts ONE chat message in the meeting's space with
  `Platform.Chat.post_message/2`, authored by the CALLING agent's own
  participant (the voice persona), whose content starts with a bracketed
  mention of the target (`@[Burrow]`). `Platform.Chat.AttentionRouter` routes
  it like any other message: an agent-authored message that @-mentions an
  agent on the space roster (role `principal` or `member`) is a `:mention`
  decision, and `AgentResponder` dispatches it. The router's agent-to-agent
  rule only stops UN-mentioned agent-authored messages from fanning out, so
  this needs no flag and no second dispatch path.

  One existing rule does apply: `AgentResponder`'s agent-to-agent loop
  breaker (`check_agent_loop/3`) lets an agent-authored message wake a given
  agent in a given space at most once per 30 seconds. A second ask to the same
  agent in the same space inside that window can be dropped there; it then
  reads as `timeout`. This module does not bypass that rule.

  What this does NOT do: summon. An agent-authored mention never adds an
  agent to a space (`Chat.reinvite_and_pin_mentioned/1` only lets an admin
  user do that), so a target that is not already on the space's roster is
  refused with `agent_not_in_space` rather than posting a message that would
  route nowhere. The question is never authored on a human's behalf.

  The message's metadata carries
  `"voice_ask" => %{"ask_id", "routed_to", "variant", "asked_by", "meeting_id"}`,
  so the chat shows who asked whom, and the reply that follows is authored by
  the answering agent under its own name.

  ## Reading the answer: one accumulator per ask

  Before posting, `ask/2` starts a `Platform.Meetings.VoiceAsk.Accumulator`
  under `Platform.Meetings.VoiceAsk.Supervisor`. It subscribes to the space's
  chat topic and keeps only the target participant's `:agent_reply_chunk`
  text (cumulative, latest wins) and the target's next posted message in that
  space (final text, done). See its moduledoc for timeouts.

  `voice_ask_poll` is answered by that process. `answered_by` is the TARGET
  agent's id, fixed when the ask is made; it is never the caller's.

  The accumulator is node-local (a local `Registry`), so a poll must reach the
  node that took the ask. Core serves MCP from one node per install.
  """

  alias Platform.Agents.{Agent, Burrow}
  alias Platform.Chat
  alias Platform.Meetings.VoiceAsk.Accumulator
  alias Platform.Repo

  @max_question 2000
  @default_wait_ms 1500
  @max_wait_ms 5000
  @roster_roles ~w(principal member)

  @instruction "(Asked by voice in a live meeting: answer in 1 to 3 short spoken-style sentences, plain text, no markdown. Stream it with suite_reply_chunk.)"

  @type result :: {:ok, map()} | {:error, map()}

  @doc "The line appended to every voice question."
  def instruction, do: @instruction

  @spec execute(String.t(), map(), map()) :: result()
  def execute("voice_ask_agent", args, context), do: ask(args, context)
  def execute("voice_ask_poll", args, context), do: poll(args, context)

  def execute(tool, _args, _context),
    do: {:error, error("unknown_tool", "no voice_ask tool named #{inspect(tool)}")}

  # ── voice_ask_agent ─────────────────────────────────────────────────────

  @spec ask(map(), map()) :: result()
  def ask(args, context) do
    space_id = Map.get(args, "space_id")
    caller_id = Map.get(context, :agent_id)

    with {:ok, question} <- question(Map.get(args, "question")),
         :ok <- caller(caller_id),
         {:ok, caller_p} <- caller_participant(space_id, context),
         {:ok, target} <- target(Map.get(args, "agent_id"), caller_id),
         {:ok, target_p} <- target_participant(space_id, target) do
      ask_id = Ecto.UUID.generate()
      variant = if Burrow.burrow?(target), do: "burrow", else: "agent"

      {:ok, pid} =
        Accumulator.start(%{
          ask_id: ask_id,
          space_id: space_id,
          asked_by: caller_id,
          answered_by: target.id,
          answer_participant_id: target_p.id,
          variant: variant
        })

      meta =
        %{
          "ask_id" => ask_id,
          "routed_to" => target.id,
          "variant" => variant,
          "asked_by" => caller_id
        }
        |> maybe_put("meeting_id", Map.get(args, "meeting_id"))

      attrs = %{
        space_id: space_id,
        participant_id: caller_p.id,
        content_type: "text",
        content: content(target_p, target, question),
        metadata: %{"source" => "voice_ask", "voice_ask" => meta}
      }

      case Chat.post_message(attrs) do
        {:ok, message} ->
          Accumulator.question_posted(pid, message)

          {:ok, %{ask_id: ask_id, agent_id: target.id, status: "pending", message_id: message.id}}

        {:error, reason} ->
          Accumulator.stop(pid)

          {:error, error("post_failed", "could not post the question: #{inspect_reason(reason)}")}
      end
    end
  end

  defp question(q) when is_binary(q) do
    q = String.trim(q)

    cond do
      q == "" ->
        {:error, error("empty_question", "question is blank")}

      String.length(q) > @max_question ->
        {:error, error("question_too_long", "question exceeds #{@max_question} characters")}

      true ->
        {:ok, q}
    end
  end

  defp question(_), do: {:error, error("empty_question", "question is required")}

  defp caller(id) when is_binary(id), do: :ok
  defp caller(_), do: {:error, error("forbidden", "no calling agent in context")}

  defp caller_participant(space_id, context) do
    participant =
      if is_binary(space_id) and Platform.UUID.valid?(space_id) do
        case Map.get(context, :agent_participant_id) do
          nil ->
            Chat.get_agent_participant(space_id, context.agent_id)

          # Honoured only if it belongs to this space; a mismatch is a refusal.
          pid ->
            case Chat.get_space_participant(space_id, pid) do
              %Chat.Participant{participant_type: "agent", participant_id: aid} = p
              when aid == context.agent_id ->
                p

              _ ->
                nil
            end
        end
      end

    case participant do
      %Chat.Participant{} = p ->
        {:ok, p}

      nil ->
        {:error,
         error(
           "space_write_denied",
           "you are not a participant in space #{inspect(space_id)}"
         )}
    end
  end

  defp target(nil, caller_id), do: target_agent(Burrow.get(), caller_id)

  defp target(agent_id, caller_id) when is_binary(agent_id) do
    agent = if Platform.UUID.valid?(agent_id), do: Repo.get(Agent, agent_id)
    target_agent(agent, caller_id)
  end

  defp target(_, _), do: {:error, error("agent_not_found", "agent_id must be a string")}

  defp target_agent(nil, _caller_id),
    do: {:error, error("agent_not_found", "no such agent (and no Burrow agent on this install)")}

  defp target_agent(%Agent{id: id}, id),
    do: {:error, error("cannot_ask_self", "you cannot ask yourself")}

  defp target_agent(%Agent{} = agent, _caller_id), do: {:ok, agent}

  defp target_participant(space_id, %Agent{} = agent) do
    case Chat.get_agent_participant(space_id, agent.id) do
      %Chat.Participant{role: role} = p when role in @roster_roles ->
        {:ok, p}

      _ ->
        {:error,
         error(
           "agent_not_in_space",
           "#{agent.name} is not on this space's agent roster; a person in the meeting must add it first"
         )}
    end
  end

  # The bracketed mention names the target's participant display name (what
  # the router and the chat UI match), falling back to the agent's name.
  defp content(%Chat.Participant{display_name: name}, %Agent{name: agent_name}, question) do
    name = if is_binary(name) and name != "", do: name, else: agent_name
    "@[#{name}] #{question}\n\n#{@instruction}"
  end

  # ── voice_ask_poll ──────────────────────────────────────────────────────

  @spec poll(map(), map()) :: result()
  def poll(args, context) do
    ask_id = Map.get(args, "ask_id")
    since = non_neg(Map.get(args, "since"), 0)
    wait_ms = args |> Map.get("wait_ms") |> non_neg(@default_wait_ms) |> min(@max_wait_ms)

    cond do
      not is_binary(ask_id) ->
        {:error, error("invalid_ask_id", "ask_id is required")}

      not is_binary(Map.get(context, :agent_id)) ->
        {:error, error("forbidden", "no calling agent in context")}

      true ->
        case Accumulator.poll(ask_id, context.agent_id, since, wait_ms) do
          {:ok, snapshot} ->
            {:ok, snapshot}

          :unknown ->
            {:ok,
             %{
               ask_id: ask_id,
               text: "",
               done: true,
               status: "unknown",
               answered_by: nil,
               variant: nil
             }}

          {:error, :forbidden} ->
            {:error, error("forbidden", "ask #{ask_id} belongs to another agent")}
        end
    end
  end

  defp non_neg(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_neg(_, default), do: default

  # ── helpers ─────────────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _value), do: map

  defp inspect_reason(%Ecto.Changeset{errors: errors}), do: inspect(Keyword.keys(errors))
  defp inspect_reason(reason), do: inspect(reason)

  defp error(code, message), do: %{error: message, code: code, recoverable: false}
end
