# Development only; outside priv so this never ships in a release image.
# GOALS_ENABLED=true mix run dev/brief_seed.exs reader@example.com
# Each invocation creates a fresh sample set. Run against a private dev database.
defmodule Platform.Goals.DevBriefSeed do
  alias Platform.Goals
  alias Platform.Goals.Clock
  alias Platform.Memory.Insights.Disseminator

  def run(email) do
    unless Goals.enabled?(), do: raise("set GOALS_ENABLED=true")

    user =
      Enum.find(Platform.Accounts.list_users(query: email), &(&1.email == email)) ||
        raise("no active user with that email")

    membership = internal_membership(user)

    now = DateTime.utc_now()
    zone = Disseminator.timezone()
    today = now |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    previous =
      for key <- [:clock_now, :default_time_zone], do: {key, Application.fetch_env(:goals, key)}

    Application.put_env(:goals, :default_time_zone, zone)

    try do
      seed(user, membership.org_id, now, today)
    after
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(:goals, key, original)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end
  end

  defp seed(user, org_id, now, today) do
    suffix = System.unique_integer([:positive])

    space =
      ok!(
        Platform.Chat.create_space(%{
          name: "Goals briefing preview",
          slug: "goals-brief-preview-#{suffix}",
          kind: "channel",
          org_id: org_id
        })
      )

    ok!(
      Platform.Access.Grants.grant(%{
        principal: user,
        permission: "goals.use",
        resource: {:space, space.id}
      })
    )

    # An unactivated runtime keeps this sample coach offline.
    runtime =
      ok!(
        Platform.Federation.register_runtime(user.id, %{
          runtime_id: "goals-brief-preview-#{suffix}",
          display_name: "Dalton preview",
          transport: "websocket"
        })
      )

    coach =
      ok!(
        Platform.Federation.link_agent(runtime, %{
          slug: "goals-brief-preview-#{suffix}",
          name: "Dalton",
          status: "active"
        })
      )

    put_now(DateTime.add(now, -7, :day))

    practice =
      goal(user, org_id, coach, %{
        title: "Get by in Spanish by June",
        agent_mode: "coach",
        unit: "words",
        target_value: 300
      })

    ok!(Goals.log_reading(user, practice.id, %{value: 150, measured_at: Clock.now()}))
    ok!(Goals.put_stops(user, practice.id, [%{label: "300 words", target_value: 300}]))
    :ok = Clock.tick(Clock.now())

    cards = [
      %{"front" => "hello", "back" => "hola"},
      %{"front" => "thank you", "back" => "gracias"},
      %{"front" => "please", "back" => "por favor"},
      %{"front" => "water", "back" => "agua"},
      %{"front" => "tomorrow", "back" => "mañana"}
    ]

    for _day <- 1..6 do
      ask =
        queue(coach, practice, %{
          kind: "practice",
          title: "Five everyday words",
          payload: %{"cards" => cards}
        })

      results = for i <- 0..4, do: %{"index" => i, "result" => "got"}
      ok!(Goals.record_practice(user, ask.id, results))
    end

    put_now(DateTime.add(now, -2, :day))

    report =
      goal(user, org_id, coach, %{
        title: "Grow How to Computer to 1M subscribers",
        agent_mode: "do",
        unit: "subscribers",
        target_value: 1_000_000
      })

    ok!(Goals.log_reading(user, report.id, %{value: 640, measured_at: Clock.now()}))
    ok!(Goals.put_stops(user, report.id, [%{label: "First 1,000", target_value: 1_000}]))
    :ok = Clock.tick(Clock.now())

    takeaway =
      ok!(
        Goals.add_entry(coach, report.id, %{
          kind: "takeaway",
          title: "Short videos bring in new viewers",
          body: "A short, useful fix gives a new viewer a reason to subscribe.",
          details: %{"doing" => "Try two short fixes each week."}
        })
      )

    queue(coach, report, %{
      kind: "offer",
      title: "Try a weekly question video",
      payload: %{
        "idea" => %{
          "why" => "Viewers already tell us what they need help with.",
          "measure" => "Two subscribers per hundred views within two weeks.",
          "steps" => ["Pick the three most asked questions", "Draft one short answer"],
          "takeaway_id" => takeaway.id
        }
      }
    })

    queue(coach, report, %{
      kind: "question",
      title: "Choose what to change this week",
      payload: %{
        "moved" => [%{"direction" => "up", "text" => "Short fixes brought new subscribers."}],
        "suggestions" => [
          %{"title" => "Try one more short fix", "why" => "Keep learning what viewers need."}
        ]
      }
    })

    put_now(DateTime.add(now, -1, :day))

    shared =
      goal(user, org_id, coach, %{
        title: "Ship the Burrow redesign",
        agent_mode: "advise",
        unit: "pieces live",
        target_value: 24
      })

    ok!(Goals.open_goal(user, shared.id, {:team, org_id}))
    ok!(Goals.log_reading(user, shared.id, %{value: 9, measured_at: Clock.now()}))
    :ok = Clock.tick(Clock.now())

    queue(coach, shared, %{
      kind: "offer",
      title: "Want the outline?",
      body: "I drafted the next release outline. Want it?",
      payload: %{
        "draft" =>
          "Release outline\n\n1. Make the sidebar easier to scan.\n2. Bring the daily brief into focus.\n3. Test the phone layout."
      }
    })

    queue(coach, practice, %{
      kind: "practice",
      title: "Five everyday words",
      payload: %{"cards" => cards}
    })

    put_now(DateTime.utc_now())

    for {title, details, takeaway_id} <- [
          {"Drafted three short video outlines",
           %{"undo_note" => "Delete the three drafts; nothing has been published."}, takeaway.id},
          {"Picked the next three viewer questions", %{}, nil},
          {"Reviewed this week's subscriber numbers", %{}, nil}
        ] do
      ok!(
        Goals.add_entry(coach, report.id, %{
          kind: "action",
          title: title,
          details: details,
          takeaway_id: takeaway_id,
          occurred_at: Clock.now()
        })
      )
    end

    delivery_now = DateTime.utc_now()
    put_now(delivery_now)
    {:ok, result} = Disseminator.run(now: delivery_now)
    {:ok, items} = Goals.brief_items(user, today)
    {:ok, streak} = Goals.practice_streak(user, practice.id, today: today)

    IO.puts(
      "Brief ready: /inbox/briefing/#{today}; #{length(items)} goal items; practice streak #{streak}."
    )

    IO.inspect(result, label: "Delivery")
  end

  defp internal_membership(user) do
    case Enum.find(Platform.Tenancy.list_user_memberships(user), &(not &1.external)) do
      nil ->
        if Platform.Tenancy.external_user?(user),
          do: raise("use an internal development reader")

        root = Platform.Tenancy.get_root_org() || raise("seed the development root org first")
        ok!(Platform.Tenancy.set_membership_role(user, root.slug, :member))

      membership ->
        membership
    end
  end

  defp goal(user, org_id, coach, attrs) do
    ok!(
      Goals.create_goal(
        user,
        Map.merge(
          %{
            org_id: org_id,
            coach_agent_id: coach.id,
            source_key: "self_reported",
            outreach: "pushy",
            rhythm: "daily"
          },
          attrs
        )
      )
    )
  end

  defp queue(coach, goal, attrs) do
    {:ok, clock} = Goals.clock_status(coach, goal.id)
    put_now(clock.next_wake_at)
    {:ok, wake} = Clock.claim(coach, goal, Clock.visible_clock(coach, goal.id), Clock.now())

    {:ok, %{ask: ask}} =
      Goals.close_wake_up(
        coach,
        wake.id,
        "ask",
        Map.merge(
          %{
            prediction: "This gives us a useful next step.",
            predicted_by: Date.add(DateTime.to_date(Clock.now()), 3)
          },
          attrs
        )
      )

    ask
  end

  defp put_now(now), do: Application.put_env(:goals, :clock_now, fn -> now end)
  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("brief seed context call failed: #{inspect(reason)}")
end

case System.argv() do
  [email | _] -> Platform.Goals.DevBriefSeed.run(email)
  [] -> raise "usage: mix run dev/brief_seed.exs <user email>"
end
