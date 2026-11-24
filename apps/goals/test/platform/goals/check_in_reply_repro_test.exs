defmodule Platform.Goals.CheckInReplyReproTest do
  @moduledoc """
  Task 01a20de3 stage 4: the reported defect, end to end through the
  production path. A check-in fires from `Clock.tick`, the coach closes it
  with `goal_ask` through `Tools.execute/3`, the owner answers in words (once
  linked to the ask, once not) and the coach follows up in the goal's
  conversation. The clock then runs past the next wake and the ask's expiry,
  the daily brief runs, and the coach reads the new wake-up with
  `goal_wake_up_get`. The coach must see the conversation, quoted, and the
  ask as answered, not open, expired or ignored.

  Message times are set on the stored rows (the fake clock runs in the past)
  so they fall between the two check-ins. Fixtures are synthetic tokens.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Goals
  alias Platform.Goals.{AskAnswer, Brief, Clock, Goal, GoalClock, Tools, WakeUp}
  alias Platform.Security.ExternalContent

  @start ~U[2026-02-04 07:00:00.000000Z]
  @question "QUESTION-TOKEN which days suit you?"
  @tokens ["REPLY-TOKEN-DAYS", "FOLLOWUP-TOKEN", "REPLY-TOKEN-ZIP"]

  setup do
    enable_goals!()

    old =
      Map.new(
        [:clock_now, :wake_up_dispatcher, :default_time_zone],
        &{&1, Application.fetch_env(:goals, &1)}
      )

    Application.put_env(:goals, :default_time_zone, "Etc/UTC")
    Application.put_env(:goals, :wake_up_dispatcher, fn _signal -> :ok end)
    set_now(@start)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    owner = member!(org)
    coach = coach_agent!(owner)
    goal = goal!(owner, org, %{coach_agent_id: coach.id, rhythm: "daily", outreach: "pushy"})
    %{owner: owner, coach: coach, goal: goal}
  end

  defp set_now(now), do: Application.put_env(:goals, :clock_now, fn -> now end)

  defp digest_date,
    do:
      Clock.now()
      |> DateTime.shift_zone!(Platform.Memory.Insights.Disseminator.timezone())
      |> DateTime.to_date()

  defp call(tool, args, coach), do: Tools.execute(tool, args, %{agent_id: coach.id})

  defp open_wake(goal),
    do: Repo.one!(from(w in WakeUp, where: w.goal_id == ^goal.id and w.status == "open"))

  defp at!(msg, time) do
    Repo.update_all(from(m in Message, where: m.id == ^msg.id), set: [inserted_at: time])
    msg
  end

  # a: the first check-in fires and the coach asks. Returns {wake, ask}.
  defp ask!(c) do
    :ok = Clock.tick(@start)
    slot = Repo.one!(from(g in GoalClock, where: g.goal_id == ^c.goal.id)).next_wake_at
    set_now(slot)
    :ok = Clock.tick(slot)
    wake = open_wake(c.goal)

    args = %{
      "wake_up_id" => wake.id,
      "kind" => "question",
      "title" => @question,
      "prediction" => "This will help",
      "predicted_by" => Date.to_iso8601(Date.add(DateTime.to_date(slot), 3))
    }

    assert {:ok, %{ask: %{id: ask_id}}} = call("goal_ask", args, c.coach)
    ask = Repo.get!(Goals.Ask, ask_id)
    assert {:ok, _} = Brief.prepare(c.owner, digest_date())
    {wake, ask}
  end

  # c + d: past the next wake and the ask's expiry, tick, run the brief, read.
  defp next_briefing!(c, ask) do
    clock = Repo.one!(from(g in GoalClock, where: g.goal_id == ^c.goal.id))
    later = Enum.max([clock.next_wake_at, ask.expires_at], DateTime)
    now = DateTime.add(later, 60)
    set_now(now)
    :ok = Clock.tick(now)
    assert Repo.get!(Goals.Ask, ask.id).status == "expired"
    assert {:ok, _} = Brief.prepare(c.owner, digest_date())

    next = open_wake(c.goal)
    assert {:ok, read} = call("goal_wake_up_get", %{"wake_up_id" => next.id}, c.coach)
    read
  end

  defp span(text) do
    assert [[{start, len}, {id_at, id_len}]] =
             Regex.scan(~r/<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>/, text,
               return: :index
             )

    id = binary_part(text, id_at, id_len)
    assert [{stop, _}] = :binary.matches(text, ExternalContent.end_marker(id))
    {start + len, stop}
  end

  defp listed?(rows, key, id), do: Enum.any?(rows || [], &(&1[key] == id))

  test "a worded answer reaches the next check-in as conversation and as an answered ask", c do
    {wake, ask} = ask!(c)

    # b: words linked to the ask, the coach's follow-up, words with no ask_id.
    {:ok, %{message: days}} =
      Goals.say_in_goal(c.owner, c.goal.id, "REPLY-TOKEN-DAYS Tuesdays", ask_id: ask.id)

    space_id = Repo.get!(Goal, c.goal.id).conversation_space_id
    row = Chat.get_agent_participant(space_id, c.coach.id)

    {:ok, followup} =
      Chat.post_message(
        %{
          space_id: space_id,
          participant_id: row.id,
          content_type: "text",
          content: "FOLLOWUP-TOKEN which postcode?"
        },
        route: :none
      )

    {:ok, %{message: zip}} = Goals.say_in_goal(c.owner, c.goal.id, "REPLY-TOKEN-ZIP 00000")

    for {msg, n} <- Enum.with_index([days, followup, zip], 1),
        do: at!(msg, DateTime.add(wake.fired_at, n * 3600))

    read = next_briefing!(c, ask)
    briefing = read.briefing
    since_last = briefing["since_last"]

    assert Enum.map(briefing["conversation"]["messages"], & &1["id"]) ==
             [days.id, followup.id, zip.id]

    {from, to} = span(read.text)

    for token <- @tokens do
      hits = :binary.matches(read.text, token)
      assert hits != [], token
      assert Enum.all?(hits, fn {at, n} -> at >= from and at + n <= to end), token
      refute inspect(since_last, limit: :infinity, printable_limit: :infinity) =~ token
    end

    assert [%{"ask_id" => replied_id, "reply_message_ids" => [reply_id]}] =
             since_last["replied_asks"]

    assert {replied_id, reply_id} == {ask.id, days.id}
    refute listed?(since_last["open_asks"], "id", ask.id)
    refute listed?(since_last["expired_asks"], "id", ask.id)

    refute Repo.exists?(
             from(a in AskAnswer, where: a.ask_id == ^ask.id and a.answer == "ignored")
           )

    refute read.text =~ "has not answered"
    assert read.text =~ "Answered in the conversation: #{@question} (ask #{ask.id})"
  end

  test "positive control: with no reply the ask is reported expired and nothing is replied", c do
    {_wake, ask} = ask!(c)
    read = next_briefing!(c, ask)
    since_last = read.briefing["since_last"]

    assert listed?(since_last["expired_asks"], "id", ask.id)
    assert since_last["replied_asks"] == []
    assert read.briefing["conversation"]["messages"] == []
    refute read.text =~ "Answered in the conversation"
  end
end
