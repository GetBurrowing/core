defmodule PlatformWeb.Dev.FakeSecretarySeeds do
  @moduledoc """
  Dev fixtures for the secretary (task 01a1b721 stage 3), served by
  `PlatformWeb.Dev.FakeSecretary` (`POST /dev/fake-secretary/seed/<name>`)
  and only with `BURROW_FAKE_AGENT_HOST=1`. Every row goes through a real
  context path, so PubSub, the arrival hooks and the Scheduler see it:
  `Platform.Inbox.emit/1`, `Platform.Chat.create_space/1`,
  `add_participant/2`, `update_space/2` (goals) and `post_message/2`,
  `Platform.Calendar.create_event/2`, `Platform.Secretary.Todos`,
  `Platform.Access.Restrictions` / `Grants` (as the system actor, named
  explicitly), and
  `Platform.Inbox.dismiss_all_unread/1`. People are made with
  `Platform.Accounts.find_or_create_from_oidc/1`, as a sign-in would.

  Seeds: `base`, `arrive`, `quiet`, `sponsor`, `plan_review`, `privacy`,
  `clear`. `privacy` makes people A, B and C with the stage-1 readability
  strings (dm-secret-xyz, grp-secret-xyz, open-text, restricted-xyz,
  exec-xyz, denied-xyz, allowed-xyz).

  Meeting action items are not seeded: a real one needs a whole meeting
  run. The heard to-do comes through `Todos.suggest/2` from a goal space.
  """

  alias Platform.Access.{Grants, Restrictions, Scope}
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Secretary
  alias Platform.Secretary.Todos

  @seeds ~w(base arrive quiet sponsor plan_review privacy clear)

  @doc "The seed names."
  def seeds, do: @seeds

  @doc "The dev-login user (`/dev/login` without `?as=`)."
  def dev_user do
    {:ok, user} = person("dev-local-user", "dev@localhost", "Dev User")
    user
  end

  @doc "Runs a seed for `user`: `{:ok, summary}` or `{:error, reason}`."
  def run(name, %User{} = user) when name in @seeds do
    result = seed(name, user)
    Secretary.note_arrival(user.id)
    {:ok, result}
  end

  def run(_name, _user), do: {:error, :unknown_seed}

  # ── seeds ───────────────────────────────────────────────────────────────

  defp seed("base", user) do
    helper = helper!()
    today_5pm = deadline_today(17)

    goals =
      for {name, goal} <- [
            {"Launch", "Ship the spring launch on the 20th"},
            {"Hiring", "Hire two engineers this quarter"},
            {"Customers", "Keep every pilot customer renewing"}
          ] do
        space = channel!(name)
        join!(space, user)
        join!(space, helper)
        {:ok, space} = Chat.update_space(space, %{goal: goal})
        space
      end

    [launch, hiring, _customers] = goals

    emit!(
      user,
      "task_plan_review",
      "task",
      "Approve the launch plan by #{hm(today_5pm)}",
      "The plan for the spring launch needs your yes today."
    )

    emit!(
      user,
      "task_sponsor_assigned",
      "task",
      "You're now sponsoring: Hiring loop revamp",
      "You were made sponsor of the hiring loop work."
    )

    say!(launch, helper, "@[#{user.name}] can you check the launch numbers before the review?")

    emit!(user, "meeting_starting", "meeting", "Launch sync starts in 15 minutes", "Launch sync")
    emit!(user, "briefing", "briefing", "Your morning briefing", "Three things moved overnight.")

    open = channel!("Open-news")
    join!(open, helper)
    say!(open, helper, "The office is closed on Friday for the move.")
    say!(open, helper, "New coffee machine on floor two.")

    {:ok, _} =
      Todos.suggest(user.id, %{
        "title" => "Send the interview rubric",
        "source_space_id" => hiring.id,
        "source_quote" => "Could you send the interview rubric?"
      })

    {:ok, _} = Todos.add_own(user.id, "Book the venue for the offsite")

    now = DateTime.utc_now()

    {:ok, _} =
      Platform.Calendar.create_event(Scope.for_user(user), %{
        title: "School pickup",
        starts_at: DateTime.add(now, 3 * 3600, :second),
        ends_at: DateTime.add(now, 3 * 3600 + 1800, :second),
        time_zone: "Etc/UTC",
        visibility: "busy"
      })

    %{goal_spaces: Enum.map(goals, & &1.id), open_channel: open.id}
  end

  defp seed("arrive", user) do
    emit!(
      user,
      "task_plan_review",
      "task",
      "Urgent: sign off the press release in 30 minutes",
      "The press release goes out at the top of the hour."
    )
  end

  defp seed("quiet", user),
    do:
      emit!(
        user,
        "meeting_invited",
        "meeting",
        "You're invited: quarterly review",
        "Next Tuesday"
      )

  defp seed("sponsor", user) do
    emit!(
      user,
      "task_sponsor_assigned",
      "task",
      "You're now sponsoring: Onboarding docs",
      "You were made sponsor of the onboarding docs."
    )
  end

  defp seed("plan_review", user) do
    emit!(
      user,
      "task_plan_review",
      "task",
      "Review the plan: billing export",
      "The billing export plan is ready for review."
    )
  end

  defp seed("privacy", _user) do
    {:ok, a} = person("dev-secretary-a", "secretary-a@localhost", "Secretary A")
    {:ok, b} = person("dev-secretary-b", "secretary-b@localhost", "Secretary B")
    {:ok, c} = person("dev-secretary-c", "secretary-c@localhost", "Secretary C")
    {:ok, d} = person("dev-secretary-d", "secretary-d@localhost", "Secretary D")

    dm = space!("dm", "secretary-dm")
    join!(dm, a)
    join!(dm, b)
    say!(dm, b, "dm-secret-xyz")

    group = space!("group", "secretary-group")
    join!(group, a)
    join!(group, b)
    say!(group, b, "grp-secret-xyz")

    open = channel!("Secretary-open")
    join!(open, a)
    say!(open, a, "open-text")

    restricted = channel!("Secretary-restricted")
    join!(restricted, a)
    say!(restricted, a, "restricted-xyz")
    {:ok, _} = Restrictions.restrict_space(restricted, ["admin"], a.id)

    exec = space!("execution", "secretary-exec")
    join!(exec, a)
    say!(exec, a, "exec-xyz")

    denied = channel!("Secretary-denied")
    join!(denied, a)
    say!(denied, a, "denied-xyz")

    {:ok, _} =
      Grants.deny(
        %{
          principal: {:user, c.id},
          permission: "chat.read",
          resource: {:space, denied.id}
        },
        actor: Scope.system()
      )

    allowed = space!("dm", "secretary-allowed")
    join!(allowed, a)
    join!(allowed, d)
    say!(allowed, a, "allowed-xyz")

    {:ok, _} =
      Grants.grant(
        %{
          principal: {:user, c.id},
          permission: "chat.read",
          resource: {:space, allowed.id}
        },
        actor: Scope.system()
      )

    %{a: a.email, b: b.email, c: c.email}
  end

  defp seed("clear", user) do
    {:ok, ids} = Inbox.dismiss_all_unread(user.id)
    %{dismissed: length(ids)}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp person(sub, email, name),
    do: Accounts.find_or_create_from_oidc(%{sub: sub, email: email, name: name})

  defp helper! do
    {:ok, helper} = person("dev-secretary-helper", "secretary-helper@localhost", "Robin Helper")
    helper
  end

  defp emit!(user, kind, source_type, title, body) do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: kind,
        source_type: source_type,
        source_id: Ecto.UUID.generate(),
        title: title,
        body: body,
        url: "/brief"
      })

    %{item_id: item.id}
  end

  defp channel!(name), do: space!("channel", name)

  defp space!(kind, name) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "#{name}-#{n}",
        slug: "dev-sec-#{String.downcase(name)}-#{n}",
        kind: kind
      })

    space
  end

  defp join!(space, %User{} = user) do
    case Chat.add_participant(space.id, %{
           participant_type: "user",
           participant_id: user.id,
           display_name: user.name,
           joined_at: DateTime.utc_now()
         }) do
      {:ok, participant} ->
        participant

      {:error, _} ->
        Enum.find(
          Chat.list_participants(space.id),
          &(&1.participant_type == "user" and &1.participant_id == user.id)
        )
    end
  end

  defp say!(space, %User{} = user, text) do
    participant = join!(space, user)

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: text
      })

    message
  end

  defp deadline_today(hour) do
    today = Date.utc_today()
    DateTime.new!(today, Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp hm(%DateTime{} = dt), do: Calendar.strftime(dt, "%-I%P")
end
