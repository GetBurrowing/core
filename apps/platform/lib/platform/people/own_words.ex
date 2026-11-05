defmodule Platform.People.OwnWords do
  @moduledoc """
  What the subject themselves said in a window — the only admissible input
  for a cited perspective on a person's private page.

  Two sources, nothing else:

    * the subject's OWN chat messages: `author_user_id` equal to the
      subject's `user_id`, or (for a subject without an account) an
      `author_display_name` that normalises to one of the subject's names,
      drawn from `Platform.Chat.digest_eligible_messages_query/1`;
    * the subject's OWN spoken segments:
      `Platform.Meetings.segments_spoken_by/2` over the transcripts completed
      in the window (`Platform.Meetings.completed_transcript_ids_between/3`).
      The summary is never read.

  Each item is `%{text, at, citation}` with `Platform.People.Privacy.scrub/1`
  applied to the text. The list is capped at #{40} items and #{8_000} bytes
  of text, oldest first.
  """

  import Ecto.Query

  alias Platform.{Chat, Meetings, Repo}
  alias Platform.People.{Identity, Privacy}

  @max_items 40
  @max_bytes 8_000

  @type subject :: %{optional(:user_id) => String.t() | nil, optional(:names) => [String.t()]}
  @type item :: %{text: String.t(), at: DateTime.t() | nil, citation: String.t()}

  @doc """
  The subject's own words in `[window_start, window_end)`.

  Options: `:scope` (default `:internal`), threaded to both seams.
  """
  @spec for_subject(subject(), DateTime.t(), DateTime.t(), keyword()) :: [item()]
  def for_subject(subject, %DateTime{} = window_start, %DateTime{} = window_end, opts \\ [])
      when is_map(subject) do
    scope = Keyword.get(opts, :scope, :internal)
    user_id = Map.get(subject, :user_id)
    names = subject |> Map.get(:names, []) |> List.wrap() |> Enum.filter(&is_binary/1)

    keys =
      names |> Enum.map(&Identity.normalize_key/1) |> Enum.reject(&(&1 == "")) |> MapSet.new()

    if is_nil(user_id) and MapSet.size(keys) == 0 do
      []
    else
      chat = chat_items(user_id, keys, window_start, window_end, scope)
      spoken = spoken_items(names, window_start, window_end, scope)

      (chat ++ spoken)
      |> Enum.sort_by(& &1.at, {:asc, DateTime})
      |> Enum.map(fn item -> %{item | text: scrub(item.text)} end)
      |> cap()
    end
  end

  # ── chat ─────────────────────────────────────────────────────────────────

  defp chat_items(user_id, keys, window_start, window_end, scope) do
    [scope: scope]
    |> Chat.digest_eligible_messages_query()
    |> where([m], m.inserted_at >= ^window_start and m.inserted_at < ^window_end)
    |> where([m], not is_nil(m.content) and m.content != "")
    |> order_by([m], asc: m.inserted_at)
    |> select([m], %{
      id: m.id,
      space_id: m.space_id,
      content: m.content,
      inserted_at: m.inserted_at,
      author_user_id: m.author_user_id,
      author_display_name: m.author_display_name
    })
    |> Repo.all()
    |> Enum.filter(&own_message?(&1, user_id, keys))
    |> Enum.map(fn m ->
      %{text: m.content, at: m.inserted_at, citation: "chat:#{m.space_id}:#{m.id}"}
    end)
  end

  # By account first; by name only when the message carries no author
  # account at all, so another member's message is never mistaken for the
  # subject's because of a shared display name.
  defp own_message?(%{author_user_id: author_id}, user_id, _keys)
       when is_binary(author_id) and is_binary(user_id),
       do: author_id == user_id

  defp own_message?(%{author_user_id: nil, author_display_name: name}, _user_id, keys)
       when is_binary(name),
       do: MapSet.member?(keys, Identity.normalize_key(name))

  defp own_message?(_, _, _), do: false

  # ── meetings ─────────────────────────────────────────────────────────────

  defp spoken_items([], _ws, _we, _scope), do: []

  defp spoken_items(names, window_start, window_end, scope) do
    window_start
    |> Meetings.completed_transcript_ids_between(window_end, scope: scope)
    |> Enum.flat_map(fn transcript_id ->
      transcript_id
      |> Meetings.segments_spoken_by(names)
      |> Enum.filter(&(is_binary(&1.text) and &1.text != ""))
      |> Enum.map(fn segment ->
        %{
          text: segment.text,
          at: parse_time(segment.spoken_at),
          citation: "meeting:transcript:#{transcript_id}:#{segment.segment_id}"
        }
      end)
    end)
  end

  defp parse_time(%DateTime{} = at), do: at

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # ── shape ────────────────────────────────────────────────────────────────

  defp scrub(text) do
    {scrubbed, _report} = Privacy.scrub(text)
    scrubbed
  end

  defp cap(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.reduce_while({[], 0}, fn item, {kept, bytes} ->
      next = bytes + byte_size(item.text)
      if next > @max_bytes, do: {:halt, {kept, bytes}}, else: {:cont, {[item | kept], next}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
