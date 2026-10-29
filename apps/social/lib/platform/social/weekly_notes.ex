defmodule Platform.Social.WeeklyNotes do
  @moduledoc """
  Scoped weekly-note reads and submission (task 01a16c52).

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

  defp author(profile, {:agent, id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Platform.Agents.Agent{status: "active"} = agent <- Repo.get(Platform.Agents.Agent, id),
         true <- Social.org_visible?(Platform.Experiments.Tools.home_org(agent), profile.org_id) do
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
