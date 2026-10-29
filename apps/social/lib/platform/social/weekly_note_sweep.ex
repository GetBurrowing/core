defmodule Platform.Social.WeeklyNoteSweep do
  @moduledoc "Social-owned durable Monday 09:00 delivery. Expiring claims keep generation outside locks; unique outbox rows commit chat messages and sent flags together. Delivery week facts cover the preceding completed local week."
  use GenServer
  import Ecto.Query
  alias Platform.{Chat, Repo}

  alias Platform.Social.{
    Approvals,
    Profile,
    WeeklyNote,
    WeeklyNoteRequest,
    WeeklyNotes,
    WeeklyNotePrompts
  }

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep, :infinity)
  @impl true
  def init(opts) do
    opts =
      [start: Application.get_env(:platform, :env) == :prod]
      |> Keyword.merge(Application.get_env(:social, :weekly_note_sweep, []))
      |> Keyword.merge(opts)

    if opts[:start] && Keyword.get(opts, :boot_sweep, true), do: send(self(), :sweep)
    {:ok, opts}
  end

  @impl true
  def handle_call(:sweep, _, opts), do: {:reply, sweep(opts), opts}
  @impl true
  def handle_info(:sweep, opts) do
    if opts[:start] do
      sweep(opts)
      ms = Keyword.get(opts, :interval_ms, 60_000)
      if ms != :infinity, do: Process.send_after(self(), :sweep, ms)
    end

    {:noreply, opts}
  end

  def due_week(profile, now) do
    local = DateTime.shift_zone!(now, profile.timezone)
    date = DateTime.to_date(local)
    monday = Date.add(date, 1 - Date.day_of_week(date))
    if date != monday or Time.compare(DateTime.to_time(local), ~T[09:00:00]) != :lt, do: monday
  end

  def sweep(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    for p <- Repo.all(Profile),
        w = due_week(p, now),
        w != nil,
        do: {p.id, deliver(p, w, now, opts)}
  end

  def deliver(profile, week, now, opts \\ []) do
    facts = WeeklyNote.facts(profile, week)

    if facts.published_count == 0 do
      {:ok, :empty}
    else
      Repo.insert(%WeeklyNoteRequest{profile_id: profile.id, week_start: week},
        on_conflict: :nothing,
        conflict_target: [:profile_id, :week_start]
      )

      case note(profile.id, week) do
        %WeeklyNote{} = note ->
          send_once(profile, week, :link_sent, "Weekly note: " <> link(profile, week, note.id))

        nil when is_binary(profile.drafting_agent_id) ->
          request(profile, week)

        nil ->
          generate(profile, week, facts, now, opts)
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Best-effort post-commit outbox delivery; a later sweep retries failures."
  def note_submitted(%WeeklyNote{} = note) do
    p = Repo.get!(Profile, note.profile_id)

    Repo.insert(%WeeklyNoteRequest{profile_id: p.id, week_start: note.week_start},
      on_conflict: :nothing,
      conflict_target: [:profile_id, :week_start]
    )

    send_once(
      p,
      note.week_start,
      :link_sent,
      "Weekly note: " <> link(p, note.week_start, note.id)
    )
  rescue
    _ -> {:error, :link_delivery_failed}
  end

  def link(profile, week, target),
    do:
      "/m/social?" <>
        URI.encode_query(%{
          tab: "results",
          profile_id: profile.id,
          weekly_note_week: Date.to_iso8601(week),
          weekly_note_target: target
        })

  defp note(id, week),
    do: Repo.one(from(n in WeeklyNote, where: n.profile_id == ^id and n.week_start == ^week))

  defp locked(p, w),
    do:
      Repo.one!(
        from(r in WeeklyNoteRequest,
          where: r.profile_id == ^p.id and r.week_start == ^w,
          lock: "FOR UPDATE"
        )
      )

  defp request(p, w) do
    case Repo.get(Platform.Agents.Agent, p.drafting_agent_id) do
      %Platform.Agents.Agent{status: "active"} = a ->
        send_once(
          p,
          w,
          :request_sent,
          "@[#{a.name}] Please write this week's note from these measured facts: " <>
            link(p, w, "facts") <>
            ". Submit with social_weekly_note_submit; week_start is delivery Monday, facts cover the prior completed local week."
        )

      _ ->
        {:error, :drafting_agent_not_found}
    end
  end

  defp send_once(p, w, field, content) do
    Repo.transaction(fn ->
      row = locked(p, w)

      if Map.fetch!(row, field) do
        :already_sent
      else
        key = "social-weekly-note:#{p.id}:#{w}:#{field}"

        with %Chat.Space{org_id: org} <- Repo.get(Chat.Space, p.space_id),
             true <- org == p.org_id,
             {:ok, sender} <- Approvals.system_participant(p.space_id),
             :ok <- ensure_drafter(p, field),
             {:ok, _} <-
               Chat.post_message(%{
                 space_id: p.space_id,
                 participant_id: sender.id,
                 content: content,
                 metadata: %{idempotency_key: key}
               }) do
          row |> Ecto.Changeset.change(%{field => true}) |> Repo.update!()
          :sent
        else
          error -> Repo.rollback({:delivery_failed, error})
        end
      end
    end)
  end

  defp ensure_drafter(p, :request_sent) do
    with %Platform.Agents.Agent{status: "active"} = agent <-
           Repo.get(Platform.Agents.Agent, p.drafting_agent_id),
         true <-
           Platform.Social.org_visible?(Platform.Experiments.Tools.home_org(agent), p.org_id),
         {:ok, _} <- Chat.add_agent_participant(p.space_id, agent) do
      :ok
    else
      _ -> {:error, :invalid_drafting_agent}
    end
  end

  defp ensure_drafter(_, _), do: :ok

  defp generate(p, w, facts, now, opts) do
    token = Ecto.UUID.generate()

    claim =
      Repo.transaction(fn ->
        row = locked(p, w)

        if row.claim_until && DateTime.compare(row.claim_until, now) == :gt do
          :busy
        else
          row
          |> Ecto.Changeset.change(claim_token: token, claim_until: DateTime.add(now, 300))
          |> Repo.update!()

          :claimed
        end
      end)

    if claim == {:ok, :claimed} do
      result =
        with {:ok, prompt} <- WeeklyNotePrompts.render(facts),
             {:ok, output} <- completion(prompt, opts),
             {:ok, %{"summary" => summary, "items" => items}} <- Jason.decode(output) do
          Repo.transaction(fn ->
            row = locked(p, w)
            if row.claim_token != token, do: Repo.rollback(:claim_lost)
            fresh = Repo.get!(Profile, p.id)

            case note(p.id, w) do
              %WeeklyNote{} = existing ->
                existing

              nil ->
                case WeeklyNotes.submit(fresh.org_id, fresh.id, w, summary, items, {:system, nil}) do
                  {:ok, note} -> note
                  {:error, error} -> Repo.rollback(error)
                end
            end
          end)
        else
          error -> {:error, {:generation_failed, error}}
        end

      Repo.update_all(
        from(r in WeeklyNoteRequest,
          where: r.profile_id == ^p.id and r.week_start == ^w and r.claim_token == ^token
        ),
        set: [claim_token: nil, claim_until: nil]
      )

      case result do
        {:ok, note} -> send_once(p, w, :link_sent, "Weekly note: " <> link(p, w, note.id))
        error -> error
      end
    else
      {:ok, :busy}
    end
  end

  defp completion(prompt, opts) do
    config = Keyword.merge(Application.get_env(:social, :weekly_note_generation, []), opts)
    agent = Keyword.get(config, :agent) || Platform.Roles.assignee_for("social.composer")

    if is_map(agent) do
      agent =
        case Keyword.get(config, :model) do
          nil -> agent
          model -> Map.put(agent, :model, model)
        end

      Platform.Agents.ToollessChat.call(
        Keyword.get(config, :provider, Platform.Agents.Providers.Anthropic),
        agent,
        [%{role: "user", content: prompt}],
        temperature: Keyword.get(config, :temperature, 0.3),
        max_tokens: Keyword.get(config, :max_tokens, 2000)
      )
    else
      {:error, :system_model_not_configured}
    end
  end
end
