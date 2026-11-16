defmodule Platform.Goals.ScriptedAgent do
  @moduledoc """
  A scripted lead agent for the New goal conversation (task 01a1dfc1-7625,
  Goals 5/8 stage 3). Test support and the dev script
  (`apps/goals/dev/scripted_agent.exs`) only; never under lib.

  It plays the two example conversations of canvas 01a15ef6 node `p`
  (screen `create`): `:yt` (How to Computer) and `:es` (Spanish). It can do
  nothing a real agent could not: it records the proposal through
  `Platform.Goals.Tools.execute("goal_propose", ...)` with the agent's id in
  the context, reads the DM with `Platform.Chat.list_messages/2`, and posts
  as the agent's participant with `Platform.Chat.post_message/1`. It calls
  no other `Platform.Goals` function.

  `next_turn/3` plays the agent's next turn: it counts the agent's messages
  after the opening one, records what the person's last answer settled
  (the first label in each list is the default; an answer that matches no
  label is the default) plus the next quick replies, then posts the
  agent's sentence. Returns `{:ok, turn}` or `:done` once the goal is
  ready.
  """

  alias Platform.Chat
  alias Platform.Goals.Tools

  @nudges_q "If things slip, how much should I nudge you? Gentle is one line in your briefing. Pushy is a message to you when something is overdue. Off means I only report."
  @nudges ["Gentle (suggested)", "Pushy", "Off"]
  @nudge_values %{"Gentle (suggested)" => "gentle", "Pushy" => "pushy", "Off" => "off"}
  @summary "Here's your goal. Have a look before I set it up."

  @doc "The example's turns: `{settle(answer), sentence, replies}` each."
  def script(:yt) do
    [
      {fn _ -> %{} end,
       "Good one. “Big” is easiest to steer by with one number, and for a YouTube channel that's subscribers. How big is big?",
       ["1 million", "100,000", "Not sure, you pick"]},
      {fn answer ->
         target = if answer == "100,000", do: "100000", else: "1000000"

         %{
           "unit" => "subscribers",
           "target_value" => target,
           "stops" => [
             %{
               "label" => "First 1,000",
               "target_value" => "1000",
               "due_on" => "2026-12-01",
               "theme" => "learn"
             },
             %{"label" => "30,000", "target_value" => "30000", "due_on" => "2027-06-30"},
             %{"label" => "1 million", "target_value" => target, "caption" => "the big one"}
           ]
         }
       end,
       "1 million is a long road, so let's break it into stops. Most channels learn what works on the way to their first 1,000, so that stop is about learning, not numbers.",
       ["Sounds good", "Change the stops"]},
      {fn _ -> %{} end,
       "Where should the number come from? There is nothing to connect for a channel yet, so the subscriber count comes from you.",
       ["I'll enter it by hand"]},
      {fn _ -> %{"source_key" => "self_reported"} end,
       "For a channel I can do a lot of the work myself: pick topics from your comments, draft scripts, edit and schedule. I'll ask before anything goes public, and you film. Should I work that way, or just advise?",
       ["Yes, do the work", "Just advise me"]},
      {fn answer ->
         %{"agent_mode" => if(answer == "Just advise me", do: "advise", else: "do")}
       end, "I'll check in once a week, on Mondays, in your briefing. Does that suit you?",
       ["Mondays is good", "Every day", "Every 2 weeks"]},
      {fn
         "Every day" -> %{"rhythm" => "daily"}
         "Every 2 weeks" -> %{"rhythm" => "biweekly", "rhythm_weekday" => 1}
         _ -> %{"rhythm" => "weekly", "rhythm_weekday" => 1}
       end, @nudges_q, @nudges},
      {fn answer ->
         %{
           "outreach" => Map.get(@nudge_values, answer, "gentle"),
           "title" => "Grow How to Computer to 1M subscribers",
           "ready" => true
         }
       end, @summary, []}
    ]
  end

  def script(:es) do
    [
      {fn _ -> %{} end, "Lovely. What would “learned” look like for you?",
       ["Get by in a conversation on holiday", "Pass an exam", "Read a novel"]},
      {fn _ ->
         %{
           "unit" => "words",
           "target_value" => "1000",
           "stops" => [
             %{
               "label" => "300 words",
               "target_value" => "300",
               "due_on" => "2026-12-25",
               "theme" => "habit"
             },
             %{"label" => "1,000 words", "target_value" => "1000", "due_on" => "2027-04-30"},
             %{"label" => "10-minute chat", "caption" => "June, in Spain"}
           ]
         }
       end,
       "Then let's count the words you know, with stops on the way. The first stop is about finding a habit that sticks.",
       ["Sounds good", "Change the stops"]},
      {fn _ -> %{} end,
       "There's nothing to connect for this one, so the number comes from you. The flash cards in your briefing count words as you go, and you can fix the count any time.",
       ["That works"]},
      {fn _ -> %{"source_key" => "self_reported"} end,
       "Practice is the part only you can do. I'll plan, make your cards and find things to listen to, but I won't pretend to do the practice for you.",
       ["Right"]},
      {fn _ -> %{"agent_mode" => "coach"} end,
       "Little and often works best for languages. A few flash cards in your briefing every day?",
       ["Every day", "Weekdays only", "Once a week"]},
      {fn
         "Weekdays only" -> %{"rhythm" => "weekdays"}
         "Once a week" -> %{"rhythm" => "weekly", "rhythm_weekday" => 1}
         _ -> %{"rhythm" => "daily"}
       end, @nudges_q, @nudges},
      {fn answer ->
         %{
           "outreach" => Map.get(@nudge_values, answer, "gentle"),
           "title" => "Get by in Spanish by June",
           "ready" => true
         }
       end, @summary, []}
    ]
  end

  @doc "Plays the agent's next turn in `proposal`'s conversation."
  def next_turn(agent, proposal, example) when example in [:yt, :es] do
    messages =
      Chat.list_messages(proposal.space_id,
        after_id: proposal.first_message_id,
        order: :asc,
        top_level_only: true,
        limit: 200
      )

    turn = Enum.count(messages, &(&1.author_participant_type == "agent"))

    case Enum.at(script(example), turn) do
      nil ->
        :done

      {settle, sentence, replies} ->
        answer = last_answer(messages)

        args =
          answer
          |> settle.()
          |> Map.merge(%{"proposal_id" => proposal.id, "replies" => replies})

        {:ok, _} = Tools.execute("goal_propose", args, %{agent_id: agent.id})
        {:ok, _message} = say(agent, proposal, sentence)
        {:ok, turn}
    end
  end

  @doc "Posts `text` in the proposal's DM as the agent's participant."
  def say(agent, proposal, text) do
    participant = Chat.get_agent_participant(proposal.space_id, agent.id)

    Chat.post_message(%{
      space_id: proposal.space_id,
      participant_id: participant.id,
      content_type: "text",
      content: text
    })
  end

  defp last_answer(messages) do
    messages
    |> Enum.filter(&(&1.author_participant_type == "user"))
    |> List.last()
    |> case do
      %{content: content} when is_binary(content) -> String.trim(content)
      _ -> nil
    end
  end
end
