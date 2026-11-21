defmodule Platform.Social.Trends do
  @moduledoc "Shared observations for the Social trends watchlist."

  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Idea, Ideas, Studio}
  alias Platform.Social.Trends.{IdeaLink, Snapshot, SourceState}

  @max_items 100

  def record_snapshot(
        %{
          source: source,
          limit: limit,
          observed_at: %DateTime{} = time,
          items: items,
          complete: true
        } = input
      )
      when is_binary(source) and byte_size(source) in 1..64 and is_integer(limit) and limit > 0 and
             limit <= @max_items and is_list(items) do
    ids = Enum.map(items, fn item -> if is_map(item), do: Map.get(item, :id) end)
    ranks = Enum.map(items, fn item -> if is_map(item), do: Map.get(item, :rank) end)

    reporting_date = Map.get(input, :reporting_date)
    daily? = match?(%Date{}, reporting_date)

    source_valid? =
      source != "wikimedia_pageviews" or
        (daily? and Enum.all?(items, &match?(%{pageviews: _}, &1)))

    if source_valid? and safe_text?(source) and items != [] and length(items) <= limit and
         Enum.all?(items, &valid_item?(&1, if(daily?, do: 1000, else: limit))) and
         Enum.uniq(ids) == ids and (daily? or Enum.uniq(ranks) == ranks) do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "social:trends:" <> source
        ])

        if daily? and
             Repo.exists?(
               from(s in Snapshot,
                 where: s.source == ^source and s.reporting_date == ^reporting_date
               )
             ) do
          Repo.rollback(:unchanged)
        end

        latest_date =
          Repo.one(from(s in Snapshot, where: s.source == ^source, select: max(s.reporting_date)))

        if (daily? and latest_date) && Date.compare(reporting_date, latest_date) != :gt do
          Repo.rollback(:out_of_order)
        end

        latest_time =
          Repo.one(from(s in Snapshot, where: s.source == ^source, select: max(s.observed_at)))

        if latest_time && DateTime.compare(time, latest_time) != :gt do
          Repo.rollback(:out_of_order)
        end

        snapshot =
          Repo.insert!(%Snapshot{
            source: source,
            sample_limit: limit,
            reporting_date: reporting_date,
            observed_at: %{time | microsecond: {elem(time.microsecond, 0), 6}},
            payload: %{
              items:
                Enum.map(
                  items,
                  &Map.take(&1, [:id, :rank, :title, :url, :points, :comments, :pageviews])
                )
            }
          })

        keep =
          Repo.all(
            from(s in Snapshot,
              where: s.source == ^source,
              order_by: [desc: s.observed_at, desc: s.id],
              limit: 2,
              select: s.id
            )
          )

        Repo.delete_all(from(s in Snapshot, where: s.source == ^source and s.id not in ^keep))
        snapshot
      end)
      |> case do
        {:error, :unchanged} -> {:ok, :unchanged}
        other -> other
      end
    else
      {:error, :invalid_snapshot}
    end
  end

  def record_snapshot(_), do: {:error, :invalid_snapshot}

  def latest(source) do
    rows =
      Repo.all(
        from(s in Snapshot,
          where: s.source == ^source,
          order_by: [desc: s.observed_at, desc: s.id],
          limit: 2
        )
      )

    %{current: decode(Enum.at(rows, 0)), previous: decode(Enum.at(rows, 1))}
  end

  @doc "Wikipedia provenance for an already-authorized collection of ideas."
  def wikipedia_idea_ids([]), do: MapSet.new()

  def wikipedia_idea_ids(ideas) do
    ids = Enum.map(ideas, & &1.id)

    Repo.all(
      from(link in IdeaLink,
        join: idea in Idea,
        on: idea.id == link.idea_id and idea.profile_id == link.profile_id,
        where: idea.id in ^ids and link.source == "wikimedia_pageviews",
        select: idea.id
      )
    )
    |> MapSet.new()
  end

  def source_status(source), do: Repo.get(SourceState, source)

  def saved_story_ids(org_id, profile_id, user_id) do
    with %Social.Profile{} = profile <- Social.get_profile(org_id, profile_id),
         true <- Studio.enabled?(profile),
         :ok <- Social.approver_check(org_id, profile, user_id),
         :ok <- Studio.authorize_studio_actor(profile, user_id) do
      Repo.all(
        from(i in IdeaLink,
          where: i.profile_id == ^profile.id and i.source == "wikimedia_pageviews",
          select: i.story_id
        )
      )
      |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end

  def turn_into_idea(org_id, profile_id, source, story_id, user_id, snapshot_id)
      when is_binary(source) and byte_size(source) in 1..64 and is_binary(story_id) and
             byte_size(story_id) in 1..255 and is_binary(snapshot_id) do
    result =
      Repo.transaction(fn ->
        unless safe_text?(source) and safe_text?(story_id) and safe_text?(snapshot_id),
          do: Repo.rollback(:not_found)

        with %Social.Profile{} = profile <- Social.lock_profile(org_id, profile_id, :share),
             true <- Studio.enabled?(profile),
             :ok <- Social.approver_check(org_id, profile, user_id),
             :ok <- Studio.authorize_studio_actor(profile, user_id) do
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "social:trend:idea:#{profile.id}:#{source}:#{story_id}"
          ])

          case Repo.get_by(IdeaLink, profile_id: profile.id, source: source, story_id: story_id) do
            %IdeaLink{idea_id: idea_id} -> {:existing, Repo.get!(Idea, idea_id)}
            nil -> create_idea!(org_id, profile, source, story_id, user_id, snapshot_id)
          end
        else
          nil -> Repo.rollback(:not_found)
          false -> Repo.rollback(:studio_disabled)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {:created, idea}} ->
        Ideas.broadcast_changed(idea.profile_id)
        {:ok, idea}

      {:ok, {:existing, idea}} ->
        {:ok, idea}

      error ->
        error
    end
  end

  def turn_into_idea(_, _, _, _, _, _), do: {:error, :not_found}

  defp create_idea!(org_id, profile, source, story_id, user_id, snapshot_id) do
    Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [
      "social:trends:" <> source
    ])

    current = latest(source).current
    if is_nil(current) or current.id != snapshot_id, do: Repo.rollback(:stale_observation)
    item = current && Enum.find(current.items, &(&1.id == story_id))
    if is_nil(item), do: Repo.rollback(:not_found)

    attrs = %{
      title: String.slice(item.title, 0, Idea.max_title()),
      source_kind: "url",
      source_url: item.url,
      brief: idea_brief(source, current, item)
    }

    idea =
      case Ideas.create(org_id, profile.id, attrs, {:user, user_id}, broadcast: false) do
        {:ok, idea} -> idea
        {:error, reason} -> Repo.rollback(reason)
      end

    Repo.insert!(%IdeaLink{
      profile_id: profile.id,
      idea_id: idea.id,
      source: source,
      story_id: story_id
    })

    {:created, idea}
  end

  defp idea_brief(source, %{reporting_date: %Date{} = date} = current, item) do
    "Source #{source}; article #{item.title}; reporting date #{date}; rank #{item.rank}, #{item.pageviews} pageviews; observed #{DateTime.to_iso8601(current.observed_at)}."
  end

  defp idea_brief(source, current, item) do
    "Source #{source}; rank #{item.rank}, #{item.points} points, #{item.comments} comments; observed #{DateTime.to_iso8601(current.observed_at)}."
  end

  defp decode(nil), do: nil

  defp decode(snapshot) do
    items =
      Enum.map(snapshot.payload["items"], fn item ->
        %{
          id: item["id"],
          rank: item["rank"],
          title: item["title"],
          url: item["url"],
          points: item["points"],
          comments: item["comments"],
          pageviews: item["pageviews"]
        }
      end)

    %{
      id: snapshot.id,
      source: snapshot.source,
      limit: snapshot.sample_limit,
      observed_at: snapshot.observed_at,
      reporting_date: snapshot.reporting_date,
      items: items
    }
  end

  defp valid_item?(%{id: id, rank: rank, title: title, url: url, pageviews: pageviews}, limit) do
    valid_key?(id) and is_integer(rank) and rank > 0 and rank <= limit and
      safe_text?(title) and String.length(title) in 1..255 and safe_url?(url) and
      is_integer(pageviews) and pageviews >= 0
  end

  defp valid_item?(
         %{id: id, rank: rank, title: title, url: url, points: points, comments: comments},
         limit
       ) do
    valid_key?(id) and is_integer(rank) and rank > 0 and rank <= limit and
      safe_text?(title) and String.length(title) in 1..200 and
      safe_url?(url) and
      is_integer(points) and points >= 0 and is_integer(comments) and comments >= 0
  end

  defp valid_item?(_, _), do: false

  defp valid_key?(id) when is_binary(id), do: byte_size(id) in 1..255 and safe_text?(id)
  defp valid_key?(_), do: false

  defp safe_url?(url) when is_binary(url) and byte_size(url) <= 2048 do
    case if(safe_text?(url), do: URI.parse(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp safe_url?(_), do: false

  defp safe_text?(text) when is_binary(text),
    do: String.valid?(text) and not String.contains?(text, <<0>>)

  defp safe_text?(_), do: false
end
