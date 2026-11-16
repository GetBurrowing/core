# Development only: GOALS_ENABLED=true mix run dev/retro_seed.exs <user email>
# Task 01a1dfc2-0d97. Private moon dev database only; all goal writes use the context.
defmodule Platform.Goals.DevRetroSeed do
  alias Platform.Goals
  alias Platform.Goals.Clock
  alias Platform.Memory.Insights.Disseminator

  def run(email) do
    user = Enum.find(Platform.Accounts.list_users(query: email), &(&1.email == email)) || raise("log in through /dev/login first")
    root = Platform.Tenancy.get_root_org() || raise("seed the root org first")
    membership = Enum.find(Platform.Tenancy.list_user_memberships(user), &(not &1.external)) || ok!(Platform.Tenancy.set_membership_role(user, root.slug, :member))
    org = membership.org_id
    space = ok!(Platform.Chat.create_space(%{name: "Retro preview", slug: "retro-preview-#{System.unique_integer([:positive])}", kind: "channel", org_id: org}))
    ok!(Platform.Access.Grants.grant(%{principal: user, permission: "goals.use", resource: {:space, space.id}}))
    runtime = ok!(Platform.Federation.register_runtime(user.id, %{runtime_id: "retro-preview-#{System.unique_integer([:positive])}", display_name: "Dalton preview", transport: "websocket"}))
    coach = ok!(Platform.Federation.link_agent(runtime, %{slug: "retro-preview-#{System.unique_integer([:positive])}", name: "Dalton", status: "active"}))
    actual = DateTime.utc_now()
    day = actual |> DateTime.shift_zone!(Disseminator.timezone()) |> DateTime.to_date()
    previous = for key <- [:clock_now, :wake_up_dispatcher], do: {key, Application.fetch_env(:goals, key)}
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> {:error, :runtime_offline} end)
    try do
      video = review(user, org, coach, day, "How to Computer", "do", -5, false)
      spanish = review(user, org, coach, day, "Get by in Spanish by June", "coach", -5, false)
      flat = review(user, org, coach, day, "Build a steady writing habit", "do", -7, true)
      slowdown(user, org, coach, day)
      for {title, value, due} <- [{"A little behind", 699, true}, {"On the hoped-for pace", 700, true}, {"No pace yet", 700, false}] do
        now(at(day, -40))
        g = goal(user, org, coach, %{title: title, retro_every: 60})
        ok!(Goals.log_reading(user, g.id, %{value: 500, measured_at: Clock.now()}))
        ok!(Goals.put_stops(user, g.id, [%{label: "First 1,000", target_value: 1000, due_on: if(due, do: Date.add(day, 60), else: nil)}]))
        now(actual)
        ok!(Goals.log_reading(user, g.id, %{value: value, measured_at: DateTime.add(Clock.now(), -60)}))
        ok!(Goals.add_entry(coach, g.id, %{kind: "action", title: "Prepared the next draft", occurred_at: Clock.now()}))
      end
      now(actual)
      Disseminator.run(now: actual, notifications_module: __MODULE__)
      IO.inspect(%{date: day, video: video.id, spanish: spanish.id, flat: flat.id}, label: "Retro preview")
    after
      for {key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end
  end

  def fan_out_to_user(_, _), do: :ok

  defp review(user, org, coach, day, title, mode, offset, flat?) do
    now(at(day, offset))
    g = goal(user, org, coach, %{title: title, agent_mode: mode, retro_every: 2})
    stops = ok!(Goals.put_stops(user, g.id, [%{label: "First 500", target_value: 500, reached_on: Date.add(day, offset)}, %{label: "First 1,000", target_value: 1000, due_on: Date.add(day, 60)}]))
    ok!(Goals.log_reading(user, g.id, %{value: 500, measured_at: Clock.now()}))
    for cycle <- 1..if(flat?, do: 3, else: 1) do
      check = fire(coach, g)
      ok!(Goals.close_wake_up(coach, check.id, "do", %{title: "Prepared a small experiment", prediction: "A shorter format will help", predicted_change: 40, predicted_by: Date.add(DateTime.to_date(Clock.now()), 1)}))
      unless flat? do
        ok!(Goals.add_entry(coach, g.id, %{kind: "action", title: "Try a longer format", prediction: "The longer format will grow faster", predicted_change: 100, predicted_by: Date.add(DateTime.to_date(Clock.now()), 1), reading_id: check.reading_id, occurred_at: Clock.now()}))
      end
      unless flat?, do: ok!(Goals.log_reading(user, g.id, %{value: 555, measured_at: DateTime.add(Clock.now(), 60)}))
      wake = fire(coach, g)
      attrs = %{title: "What we learned this week", summary: "A smaller, regular effort was easier to keep going.", stop_id: hd(stops).id, worked: [%{"label" => "Short, focused sessions", "percent" => 75}], didnt_work: [%{"text" => "Long sessions were hard to fit in"}], learned: ["Start small and make the next step clear"], next_push: %{"title" => "Keep the useful parts", "suggestions" => [%{"tag" => "keep", "title" => "Short sessions"}]}}
      attrs = cond do
        flat? && cycle == 3 -> Map.put(attrs, :goal_change, %{"summary" => "Choose a smaller target we can sustain", "kind" => "target", "set" => %{"target_value" => 600}})
        flat? -> attrs
        true -> Map.put(attrs, :check_in_change, %{"summary" => "Let us use weekdays for the next stretch", "set" => %{"rhythm" => "weekdays"}})
      end
      ok!(Goals.close_retro(coach, wake.id, attrs))
    end
    ok!(Goals.update_goal(user, g.id, %{status: "paused"}))
    g
  end

  defp slowdown(user, org, coach, day) do
    now(at(day, -4))
    g = goal(user, org, coach, %{title: "Make room for reading", retro_every: 60, outreach: "gentle"})
    for _ <- 1..3 do
      wake = fire(coach, g)
      ok!(Goals.close_wake_up(coach, wake.id, "ask", %{kind: "question", title: "Which small step fits today?", prediction: "One step will help", predicted_by: Date.add(DateTime.to_date(Clock.now()), 1)}))
      d = Clock.now() |> DateTime.shift_zone!(Disseminator.timezone()) |> DateTime.to_date()
      ok!(Goals.prepare_brief(user, d))
      next = DateTime.add(Clock.now(), 1, :day)
      real = DateTime.utc_now()
      now(if DateTime.compare(next, real) == :gt, do: real, else: next)
      ok!(Goals.prepare_brief(user, Date.add(d, 1)))
    end
    g
  end

  defp fire(coach, g) do
    {:ok, clock} = Goals.clock_status(coach, g.id)
    now(clock.next_wake_at)
    :ok = Clock.tick(Clock.now())
    {:ok, rows} = Goals.list_wake_ups(coach, g.id)
    Enum.find(rows, &(&1.status == "open")) || raise("no open wake-up")
  end
  defp goal(user, org, coach, attrs), do: ok!(Goals.create_goal(user, Map.merge(%{org_id: org, coach_agent_id: coach.id, source_key: "self_reported", unit: "words", target_value: 1000, outreach: "pushy", rhythm: "daily"}, attrs)))
  defp at(day, offset), do: day |> Date.add(offset) |> DateTime.new!(~T[12:00:00], Disseminator.timezone()) |> DateTime.shift_zone!("Etc/UTC")
  defp now(t), do: Application.put_env(:goals, :clock_now, fn -> t end)
  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("retro seed context call failed: #{inspect(reason)}")
end

case System.argv() do
  [email | _] -> Platform.Goals.DevRetroSeed.run(email)
  [] -> raise "usage: mix run dev/retro_seed.exs <user email>"
end
