defmodule Platform.Social.WeeklyNotes do
  @moduledoc """
  Scoped weekly-note submission and human decisions (task 01a16c52).

  The caller supplies its authenticated `{:agent, id}` identity or the internal
  `{:system, nil}` identity, never a model's authorship fields. Agent identity is
  checked against a real, active agent and its home org as well as caller scope.
  `week_start` is the delivery Monday; facts cover the preceding completed local
  week. No submission changes voice, posting slots or ideas. Human decisions
  are a separate service operation, never accepted as submission data.
  """
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Ideas, Profile, WeeklyNote}

  @doc "Latest first, through the current scope; an inaccessible profile yields []."
  def list(scope, profile_id) do
    case Social.get_profile(scope, profile_id) do
      %Profile{id: id, org_id: org_id} ->
        Repo.all(
          from(n in WeeklyNote,
            where: n.profile_id == ^id and n.org_id == ^org_id,
            order_by: [desc: n.week_start, desc: n.id]
          )
        )

      nil ->
        []
    end
  end

  @doc "Reads a note through its profile and org scope; malformed or inaccessible ids yield nil."
  def get(scope, note_id) do
    with {:ok, id} <- Ecto.UUID.cast(note_id),
         %WeeklyNote{} = note <- Repo.get(WeeklyNote, id),
         %Profile{org_id: org_id} <- Social.get_profile(scope, note.profile_id),
         true <- org_id == note.org_id do
      note
    else
      _ -> nil
    end
  end

  @doc """
  Submit once per profile and delivery Monday. `items` accepts only id, kind,
  text and payload. Decisions/attribution are rejected even if nil. Voice payload
  is `%{text: <=280 chars}`, timing is `%{account_id, weekday: 1..7, time: HH:MM}`,
  recycle is `%{idea_id}` belonging to this profile. Other payloads must be empty.
  No published posts in the reporting week returns `{:error, :no_published_posts}`.
  """
  def submit(scope, profile_id, week_start, summary, items, author) do
    Repo.transaction(fn ->
      with {:ok, _} <- lock_profile(scope, profile_id),
           {:ok, note} <- do_submit(scope, profile_id, week_start, summary, items, author) do
        note
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp do_submit(scope, profile_id, week_start, summary, items, author) do
    with %Profile{} = profile <- Social.get_profile(scope, profile_id) || {:error, :not_found},
         {:ok, kind, author_id} <- author(profile, author),
         {:ok, week_start} <- delivery_monday(week_start),
         {:ok, items} <- submission_items(scope, profile, items),
         true <-
           WeeklyNote.facts(profile, week_start).published_count > 0 ||
             {:error, :no_published_posts} do
      %WeeklyNote{
        org_id: profile.org_id,
        profile_id: profile.id,
        author_kind: kind,
        author_id: author_id
      }
      |> WeeklyNote.changeset(%{week_start: week_start, summary: summary, items: items})
      |> Repo.insert()
    end
  end

  @doc "Apply a human decision once; timing use requires confirmed: true."
  def decide(scope, note_id, item_id, decision, user_id, opts \\ []) do
    if decision in ["use", "ignore"] do
      change_item(scope, note_id, item_id, user_id, fn note, profile, item ->
        cond do
          item.decision == decision ->
            {:ok, note}

          item.decision != nil ->
            {:error, :already_decided}

          true ->
            now = Keyword.get(opts, :now, DateTime.utc_now())

            with {:ok, effect} <-
                   apply_effect(scope, profile, note, item, decision, user_id, now, opts) do
              save_item(note, %{
                item
                | decision: decision,
                  decided_by_user_id: user_id,
                  decided_at: now,
                  effect: effect
              })
            end
        end
      end)
    else
      {:error, :invalid_decision}
    end
  end

  @doc "Undo within the delivery week; refuse effects changed downstream atomically."
  def undo(scope, note_id, item_id, user_id, opts \\ []) do
    change_item(scope, note_id, item_id, user_id, fn note, profile, item ->
      today =
        Keyword.get(opts, :now, DateTime.utc_now())
        |> DateTime.shift_zone!(profile.timezone)
        |> DateTime.to_date()

      cond do
        Date.compare(today, note.week_start) == :lt or
            Date.compare(today, Date.add(note.week_start, 7)) != :lt ->
          {:error, :undo_expired}

        item.decision == nil ->
          {:ok, note}

        true ->
          with :ok <- reverse_effect(scope, profile, item) do
            save_item(note, %{
              item
              | decision: nil,
                decided_by_user_id: nil,
                decided_at: nil,
                effect: %{}
            })
          end
      end
    end)
  end

  defp lock_profile(scope, profile_id) do
    with %Profile{} <- Social.get_profile(scope, profile_id),
         %Profile{} = profile <-
           Repo.one(from(p in Profile, where: p.id == ^profile_id, lock: "FOR UPDATE")),
         %Profile{} <- Social.get_profile(scope, profile_id) do
      {:ok, profile}
    else
      _ -> {:error, :not_found}
    end
  end

  defp change_item(scope, note_id, item_id, user_id, fun) do
    Repo.transaction(fn ->
      with %WeeklyNote{} = initial <- get(scope, note_id) || {:error, :not_found},
           {:ok, profile} <- lock_profile(scope, initial.profile_id),
           :ok <- Social.approver_check(profile.org_id, profile, user_id),
           %WeeklyNote{} = note <-
             Repo.one(from(n in WeeklyNote, where: n.id == ^initial.id, lock: "FOR UPDATE")),
           %WeeklyNote.Item{} = item <-
             Enum.find(note.items, &(&1.id == item_id)) || {:error, :not_found},
           {:ok, changed} <- fun.(note, profile, item) do
        changed
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  defp save_item(note, changed) do
    note
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(
      :items,
      Enum.map(note.items, fn item ->
        if item.id == changed.id,
          do:
            Ecto.Changeset.change(
              item,
              Map.take(changed, [:decision, :decided_at, :decided_by_user_id, :effect])
            ),
          else: Ecto.Changeset.change(item)
      end)
    )
    |> Repo.update()
  end

  defp apply_effect(_, _, _, _, "ignore", _, _, _), do: {:ok, %{}}
  defp apply_effect(_, _, _, %{kind: "other"}, _, _, _, _), do: {:ok, %{}}

  defp apply_effect(_, profile, note, %{kind: "voice", payload: payload}, _, user_id, now, _) do
    learning =
      Ecto.Changeset.apply_changes(
        Platform.Social.VoiceLearning.changeset(
          %Platform.Social.VoiceLearning{id: Ecto.UUID.generate()},
          %{
            text: payload["text"],
            source_note_id: note.id,
            accepted_by_user_id: user_id,
            accepted_at: now
          }
        )
      )

    voice = Platform.Social.Voice.of(profile)

    voice = %{learnings: voice.learnings ++ [learning]}

    with {:ok, _} <-
           profile
           |> Ecto.Changeset.change()
           |> Ecto.Changeset.put_embed(:voice, voice)
           |> Repo.update() do
      {:ok, %{"kind" => "voice", "id" => learning.id, "snapshot" => snapshot(learning)}}
    end
  end

  defp apply_effect(scope, profile, _, %{kind: "timing", payload: payload}, _, _, _, opts) do
    with true <- Keyword.get(opts, :confirmed, false) == true || {:error, :confirmation_required},
         :ok <- validate_payload(scope, profile, "timing", payload) do
      account =
        Repo.one!(from(a in Account, where: a.id == ^payload["account_id"], lock: "FOR UPDATE"))

      if account.profile_id != profile.id or account.archived_at != nil,
        do: Repo.rollback(:invalid_timing)

      slot = %{"weekday" => payload["weekday"], "time" => payload["time"]}

      slots =
        Enum.map(account.posting_slots, &Map.take(Map.from_struct(&1), [:weekday, :time]))
        |> stringify()

      if slot in slots do
        {:ok, %{}}
      else
        with {:ok, updated} <-
               Social.update_account_schedule(scope, account, %{posting_slots: slots ++ [slot]}) do
          {:ok,
           %{
             "kind" => "timing",
             "account_id" => account.id,
             "slot" => slot,
             "snapshot" => snapshot(updated.posting_slots)
           }}
        end
      end
    end
  end

  defp apply_effect(scope, profile, _, %{kind: "recycle", payload: payload}, _, user_id, _, _) do
    with :ok <- validate_payload(scope, profile, "recycle", payload),
         {:ok, child} <-
           Platform.Social.Results.recycle(scope, payload["idea_id"], user_id,
             profiles: [profile]
           ) do
      {:ok,
       %{
         "kind" => "recycle",
         "id" => child.id,
         "snapshot" => snapshot(child),
         "notes" => notes_snapshot(child.id)
       }}
    end
  end

  defp reverse_effect(_, _, %{effect: effect}) when map_size(effect) == 0, do: :ok

  defp reverse_effect(_, profile, %{effect: %{"kind" => "voice"} = effect}) do
    voice = Platform.Social.Voice.of(profile)

    case Enum.find(voice.learnings, &(&1.id == effect["id"])) do
      nil ->
        :ok

      learning ->
        if snapshot(learning) == effect["snapshot"] do
          voice = %{learnings: Enum.reject(voice.learnings, &(&1.id == learning.id))}

          profile
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_embed(:voice, voice)
          |> Repo.update()
          |> ok()
        else
          {:error, :effect_changed}
        end
    end
  end

  defp reverse_effect(scope, profile, %{effect: %{"kind" => "timing"} = effect}) do
    account =
      Repo.one(
        from(a in Account,
          where: a.id == ^effect["account_id"] and a.profile_id == ^profile.id,
          lock: "FOR UPDATE"
        )
      )

    if account && snapshot(account.posting_slots) == effect["snapshot"] do
      slots =
        account.posting_slots
        |> Enum.map(&Map.take(Map.from_struct(&1), [:weekday, :time]))
        |> stringify()
        |> Enum.reject(&(&1 == effect["slot"]))

      Social.update_account_schedule(scope, account, %{posting_slots: slots}) |> ok()
    else
      {:error, :effect_changed}
    end
  end

  defp reverse_effect(_, profile, %{effect: %{"kind" => "recycle"} = effect}) do
    child =
      Repo.one(
        from(i in Platform.Social.Idea,
          where: i.id == ^effect["id"] and i.profile_id == ^profile.id,
          lock: "FOR UPDATE"
        )
      )

    if child && snapshot(child) == effect["snapshot"] &&
         notes_snapshot(child.id) == effect["notes"] &&
         not Repo.exists?(from(p in Platform.Social.Post, where: p.idea_id == ^child.id)) &&
         not Repo.exists?(
           from(i in Platform.Social.Idea, where: i.recycled_from_idea_id == ^child.id)
         ) do
      Repo.delete(child) |> ok()
    else
      {:error, :effect_changed}
    end
  end

  defp reverse_effect(_, _, _), do: {:error, :effect_changed}
  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error
  defp stringify(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp snapshot(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()

  defp notes_snapshot(id),
    do:
      Repo.all(from(n in Platform.Social.IdeaNote, where: n.idea_id == ^id, order_by: n.id))
      |> snapshot()

  defp author(profile, {:agent, id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Platform.Agents.Agent{status: "active"} = agent <- Repo.get(Platform.Agents.Agent, id),
         true <- Social.org_visible?(Platform.Experiments.Tools.home_org(agent), profile.org_id),
         true <- profile.drafting_agent_id == id do
      {:ok, "agent", id}
    else
      _ -> {:error, :invalid_author}
    end
  end

  defp author(%Profile{drafting_agent_id: nil}, {:system, nil}), do: {:ok, "system", nil}
  defp author(_, _), do: {:error, :invalid_author}

  defp delivery_monday(%Date{} = date) do
    if Date.day_of_week(date) == 1, do: {:ok, date}, else: {:error, :invalid_week_start}
  end

  defp delivery_monday(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> delivery_monday(date)
      _ -> {:error, :invalid_week_start}
    end
  end

  defp delivery_monday(_), do: {:error, :invalid_week_start}

  defp submission_items(scope, profile, items) when is_list(items) do
    with {:ok, items} <- normalize_items(items),
         true <- unique_ids?(items) || {:error, :duplicate_item_ids} do
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, valid} ->
        case validate_item(scope, profile, item) do
          :ok -> {:cont, {:ok, [item | valid]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, valid} -> {:ok, Enum.reverse(valid)}
        error -> error
      end
    end
  end

  defp submission_items(_, _, _), do: {:error, :invalid_items}

  defp normalize_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn
      item, {:ok, acc} when is_map(item) and not is_struct(item) ->
        with {:ok, item} <- string_keys(item),
             true <- Enum.all?(Map.keys(item), &(&1 in ~w(id kind text payload))) do
          {:cont, {:ok, acc ++ [item]}}
        else
          _ -> {:halt, {:error, :invalid_item_fields}}
        end

      _, _ ->
        {:halt, {:error, :invalid_items}}
    end)
  end

  defp string_keys(map) do
    if Enum.all?(Map.keys(map), &(is_atom(&1) or is_binary(&1))) and
         map_size(map) == length(Enum.uniq(Enum.map(Map.keys(map), &to_string/1))),
       do: {:ok, Map.new(map, fn {key, value} -> {to_string(key), value} end)},
       else: {:error, :invalid_item_fields}
  end

  defp unique_ids?(items) do
    ids =
      Enum.flat_map(items, fn item ->
        case Map.fetch(item, "id") do
          :error -> []
          {:ok, id} -> [id]
        end
      end)

    cast_ids = Enum.map(ids, &Ecto.UUID.cast/1)
    Enum.all?(cast_ids, &match?({:ok, _}, &1)) and length(ids) == length(Enum.uniq(cast_ids))
  end

  defp validate_item(scope, profile, %{"kind" => kind, "text" => text, "payload" => payload})
       when is_binary(text) and is_map(payload) and not is_struct(payload) do
    with {:ok, payload} <- string_keys(payload),
         :ok <- validate_payload(scope, profile, kind, payload) do
      :ok
    end
  end

  defp validate_item(_, _, _), do: {:error, :invalid_item}

  defp validate_payload(_, _, "voice", %{"text" => text} = payload)
       when map_size(payload) == 1 and is_binary(text) do
    if String.length(String.trim(text)) in 1..280, do: :ok, else: {:error, :invalid_voice}
  end

  defp validate_payload(
         _,
         profile,
         "timing",
         %{"account_id" => id, "weekday" => day, "time" => time} = payload
       )
       when map_size(payload) == 3 and is_integer(day) and day in 1..7 and is_binary(time) do
    with true <- Regex.match?(~r/\A([01]\d|2[0-3]):[0-5]\d\z/, time),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Account{profile_id: profile_id, archived_at: nil} <- Repo.get(Account, id),
         true <- profile_id == profile.id do
      :ok
    else
      _ -> {:error, :invalid_timing}
    end
  end

  defp validate_payload(scope, profile, "recycle", %{"idea_id" => id} = payload)
       when map_size(payload) == 1 do
    case Ideas.get(scope, id) do
      %Platform.Social.Idea{profile_id: profile_id} when profile_id == profile.id -> :ok
      _ -> {:error, :invalid_recycle}
    end
  end

  defp validate_payload(_, _, "other", payload) when map_size(payload) == 0, do: :ok
  defp validate_payload(_, _, _, _), do: {:error, :invalid_payload}
end
