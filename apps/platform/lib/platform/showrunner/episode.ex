defmodule Platform.Showrunner.Episode do
  @moduledoc """
  The state model of one How to Computer episode. Task 01a1eaf6 stage 1.

  A plain struct, NOT a table. The episode's live state is the weekly episode
  canvas document: `to_document/1` writes it as a canvas tree and
  `from_document/1` reads it back. A human may hand-edit that canvas, so
  `from_document/1` is TOTAL: anything it cannot read comes back as
  `{:error, reason}`, never as a raise.

  ## Stages

  Seven, in order: `:pitch, :research, :run_sheet, :logistics, :record, :post, :retro`.
  Each carries a state, `:ready | :in_progress | :needs_you | :not_started`.
  `advance/2` moves to the NEXT stage only; the stage left behind becomes
  `:ready`. A stage with an open `needs_you` item cannot be left.

  ## needs_you

  Human decisions only: `%{id, question, options}`. Adding one puts the
  current stage in `:needs_you`; resolving the last one puts it back to
  `:in_progress`.

  ## Run sheet

  A list of segments, `%{id, starts_at_s, ends_at_s, name, talking_points,
  callback_episode, stat_cards}`. `put_run_sheet/2` requires the segments to
  run contiguously from 00:00, the total to be at most 45:00, and every stat
  card to carry a non-blank `source_url`: a stat without a source is refused.

  ## Document shape

  A canonical canvas document (`Platform.Chat.CanvasDocument`): `version`,
  `revision`, a `stack` root whose children are one node each of type
  `production_rail`, `needs_you` and `run_sheet` (stage 2 renders those
  kinds), and the fields no node renders (`brief`, `guests`, `retro`) under
  `meta["showrunner"]`. Nodes are found by TYPE, so a renamed type reads as a
  missing node.
  """

  @stages [:pitch, :research, :run_sheet, :logistics, :record, :post, :retro]
  @stage_states [:ready, :in_progress, :needs_you, :not_started]
  @max_run_s 45 * 60
  @schema 1

  @stage_by_name Map.new(@stages, &{Atom.to_string(&1), &1})
  @state_by_name Map.new(@stage_states, &{Atom.to_string(&1), &1})

  @type stage :: :pitch | :research | :run_sheet | :logistics | :record | :post | :retro
  @type stage_state :: :ready | :in_progress | :needs_you | :not_started
  @type needs_you_item :: %{id: String.t(), question: String.t(), options: [String.t()]}
  @type stat_card :: %{text: String.t(), source_url: String.t()}
  @type segment :: %{
          id: String.t(),
          starts_at_s: non_neg_integer(),
          ends_at_s: pos_integer(),
          name: String.t(),
          talking_points: %{String.t() => String.t()},
          callback_episode: pos_integer() | nil,
          stat_cards: [stat_card()]
        }
  @type retro :: %{
          kept_segment_ids: [String.t()],
          cut_segment_ids: [String.t()],
          clip_results: [map()]
        }

  @type t :: %__MODULE__{
          number: pos_integer(),
          title: String.t(),
          records_at: DateTime.t() | nil,
          room_status: String.t() | nil,
          stage: stage(),
          stages: %{stage() => stage_state()},
          needs_you: [needs_you_item()],
          run_sheet: [segment()],
          brief: String.t() | nil,
          guests: [map()],
          retro: retro()
        }

  defstruct number: nil,
            title: nil,
            records_at: nil,
            room_status: nil,
            stage: :pitch,
            stages: %{},
            needs_you: [],
            run_sheet: [],
            brief: nil,
            guests: [],
            retro: %{kept_segment_ids: [], cut_segment_ids: [], clip_results: []}

  @doc "The seven stages, in order."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "The four per-stage states."
  @spec stage_states() :: [stage_state()]
  def stage_states, do: @stage_states

  @doc "The longest a run sheet may run, in seconds (45:00)."
  @spec max_run_s() :: pos_integer()
  def max_run_s, do: @max_run_s

  @doc """
  A new episode at `:pitch` (in progress; every later stage not started).

  Attrs (map or keyword, atom or string keys): `number` (positive integer,
  required), `title` (non-blank string, required), `records_at` (`DateTime`,
  shifted to UTC and truncated to the second), `room_status`, `brief`,
  `guests` (a list of maps).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with {:ok, number} <- number(get(attrs, :number)),
         {:ok, title} <- non_blank(get(attrs, :title), :title),
         {:ok, records_at} <- records_at(get(attrs, :records_at)),
         {:ok, room_status} <- optional_string(get(attrs, :room_status), :room_status),
         {:ok, brief} <- optional_string(get(attrs, :brief), :brief),
         {:ok, guests} <- map_list(get(attrs, :guests) || [], :guests) do
      {:ok,
       %__MODULE__{
         number: number,
         title: title,
         records_at: records_at,
         room_status: room_status,
         brief: brief,
         guests: guests,
         stage: :pitch,
         stages: initial_stages()
       }}
    end
  end

  def new(_attrs), do: {:error, :attrs_must_be_a_map}

  @doc """
  Moves the episode to `to`, which must be the stage right after the current
  one. The stage left behind becomes `:ready` and `to` becomes
  `:in_progress`. Refused while any needs_you item is open.
  """
  @spec advance(t(), stage()) :: {:ok, t()} | {:error, term()}
  def advance(%__MODULE__{needs_you: [_ | _]}, _to), do: {:error, :needs_you_open}

  def advance(%__MODULE__{stage: from} = episode, to) do
    if next_stage(from) == to and to != nil do
      stages = episode.stages |> Map.put(from, :ready) |> Map.put(to, :in_progress)
      {:ok, %{episode | stage: to, stages: stages}}
    else
      {:error, {:invalid_transition, from, to}}
    end
  end

  @doc "The stage after `stage`, or nil after `:retro`."
  @spec next_stage(stage()) :: stage() | nil
  def next_stage(stage) do
    case Enum.drop_while(@stages, &(&1 != stage)) do
      [_current, next | _] -> next
      _ -> nil
    end
  end

  @doc """
  Replaces the run sheet. Refuses an empty list, a segment that does not
  start where the previous one ended (the first starts at 0), a total over
  45:00, and any stat card without a non-blank `source_url`.
  """
  @spec put_run_sheet(t(), [map()]) :: {:ok, t()} | {:error, term()}
  def put_run_sheet(%__MODULE__{}, []), do: {:error, :empty_run_sheet}

  def put_run_sheet(%__MODULE__{} = episode, segments) do
    with {:ok, segments} <- run_sheet(segments) do
      {:ok, %{episode | run_sheet: segments}}
    end
  end

  @doc """
  Adds a human decision, `%{id, question, options}`, and puts the current
  stage in `:needs_you`. `options` is a non-empty list of strings.
  """
  @spec add_needs_you(t(), map()) :: {:ok, t()} | {:error, term()}
  def add_needs_you(%__MODULE__{} = episode, item) do
    with {:ok, item} <- needs_you_item(item),
         :ok <- unique_needs_you(episode.needs_you, item.id) do
      {:ok,
       %{
         episode
         | needs_you: episode.needs_you ++ [item],
           stages: Map.put(episode.stages, episode.stage, :needs_you)
       }}
    end
  end

  @doc """
  Resolves needs_you item `id` with `choice`, which must be one of its
  options. When none remain, a `:needs_you` current stage goes back to
  `:in_progress`.
  """
  @spec resolve_needs_you(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def resolve_needs_you(%__MODULE__{} = episode, id, choice) do
    case Enum.find(episode.needs_you, &(&1.id == id)) do
      nil ->
        {:error, {:unknown_needs_you, id}}

      item ->
        if choice in item.options do
          remaining = Enum.reject(episode.needs_you, &(&1.id == id))

          stages =
            if remaining == [] and Map.get(episode.stages, episode.stage) == :needs_you,
              do: Map.put(episode.stages, episode.stage, :in_progress),
              else: episode.stages

          {:ok, %{episode | needs_you: remaining, stages: stages}}
        else
          {:error, {:invalid_choice, id, choice}}
        end
    end
  end

  @doc """
  Records the retro: `kept_segment_ids` and `cut_segment_ids` (disjoint, each
  an id on the run sheet) and `clip_results` (a list of maps).
  """
  @spec put_retro(t(), map()) :: {:ok, t()} | {:error, term()}
  def put_retro(%__MODULE__{} = episode, attrs) do
    with {:ok, retro} <- retro(attrs, episode.run_sheet) do
      {:ok, %{episode | retro: retro}}
    end
  end

  @doc """
  The experiment metric: kept segments / total run-sheet segments, as a
  float in 0.0..1.0. Nil when there is no run sheet to take a share of.
  """
  @spec kept_share(t()) :: float() | nil
  def kept_share(%__MODULE__{run_sheet: []}), do: nil

  def kept_share(%__MODULE__{run_sheet: segments, retro: retro}) do
    kept = MapSet.new(retro.kept_segment_ids)
    Enum.count(segments, &MapSet.member?(kept, &1.id)) / length(segments)
  end

  # ── Document ──

  @doc "The episode as a canonical canvas document (string keys, JSON-safe)."
  @spec to_document(t()) :: map()
  def to_document(%__MODULE__{} = episode) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          node("production_rail", %{
            "number" => episode.number,
            "title" => episode.title,
            "records_at" => episode.records_at && DateTime.to_iso8601(episode.records_at),
            "room_status" => episode.room_status,
            "stage" => Atom.to_string(episode.stage),
            "stages" =>
              Enum.map(@stages, fn stage ->
                %{
                  "stage" => Atom.to_string(stage),
                  "state" => Atom.to_string(Map.fetch!(episode.stages, stage))
                }
              end)
          }),
          node("needs_you", %{
            "items" =>
              Enum.map(episode.needs_you, fn item ->
                %{"id" => item.id, "question" => item.question, "options" => item.options}
              end)
          }),
          node("run_sheet", %{
            "segments" => Enum.map(episode.run_sheet, &segment_to_doc/1),
            "total_s" => total_s(episode.run_sheet)
          })
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{
        "showrunner" => %{
          "schema" => @schema,
          "brief" => episode.brief,
          "guests" => episode.guests,
          "retro" => %{
            "kept_segment_ids" => episode.retro.kept_segment_ids,
            "cut_segment_ids" => episode.retro.cut_segment_ids,
            "clip_results" => episode.retro.clip_results
          }
        }
      }
    }
  end

  @doc """
  Reads an episode back from a canvas document. TOTAL: a hand-edited,
  partial or invalid document (a missing node, a renamed type, a bad prop, a
  non-map) returns `{:error, reason}` and never raises.
  """
  @spec from_document(term()) :: {:ok, t()} | {:error, term()}
  def from_document(%{"root" => root, "meta" => meta}) when is_map(root) do
    with {:ok, rail} <- find_props(root, "production_rail"),
         {:ok, needs_you_props} <- find_props(root, "needs_you"),
         {:ok, run_sheet_props} <- find_props(root, "run_sheet"),
         {:ok, show} <- showrunner_meta(meta),
         {:ok, number} <- number(Map.get(rail, "number")),
         {:ok, title} <- non_blank(Map.get(rail, "title"), :title),
         {:ok, records_at} <- records_at(Map.get(rail, "records_at")),
         {:ok, room_status} <- optional_string(Map.get(rail, "room_status"), :room_status),
         {:ok, stage} <- lookup(@stage_by_name, Map.get(rail, "stage"), :stage),
         {:ok, stages} <- stages_from_doc(Map.get(rail, "stages")),
         {:ok, needs_you} <- needs_you_from_doc(Map.get(needs_you_props, "items")),
         {:ok, segments} <- segments_from_doc(Map.get(run_sheet_props, "segments")),
         {:ok, brief} <- optional_string(Map.get(show, "brief"), :brief),
         {:ok, guests} <- map_list(Map.get(show, "guests", []), :guests),
         {:ok, retro} <- retro(Map.get(show, "retro"), segments) do
      {:ok,
       %__MODULE__{
         number: number,
         title: title,
         records_at: records_at,
         room_status: room_status,
         stage: stage,
         stages: stages,
         needs_you: needs_you,
         run_sheet: segments,
         brief: brief,
         guests: guests,
         retro: retro
       }}
    end
  end

  def from_document(%{"root" => _root, "meta" => _meta}), do: {:error, :root_must_be_a_node}
  def from_document(%{"root" => _root}), do: {:error, {:missing, "meta"}}
  def from_document(doc) when is_map(doc), do: {:error, {:missing, "root"}}
  def from_document(_doc), do: {:error, :document_must_be_a_map}

  defp node(type, props), do: %{"id" => type, "type" => type, "props" => props, "children" => []}

  defp segment_to_doc(segment) do
    %{
      "id" => segment.id,
      "starts_at_s" => segment.starts_at_s,
      "ends_at_s" => segment.ends_at_s,
      "name" => segment.name,
      "talking_points" => segment.talking_points,
      "callback_episode" => segment.callback_episode,
      "stat_cards" =>
        Enum.map(segment.stat_cards, &%{"text" => &1.text, "source_url" => &1.source_url})
    }
  end

  defp total_s([]), do: 0
  defp total_s(segments), do: List.last(segments).ends_at_s

  # Depth-first, first match wins. Every non-node shape is skipped, never
  # matched on blindly, so a malformed subtree cannot raise.
  defp find_props(root, type) do
    case find_node(root, type) do
      %{"props" => props} when is_map(props) -> {:ok, props}
      nil -> {:error, {:missing_node, type}}
      _node -> {:error, {:bad_props, type}}
    end
  end

  defp find_node(%{"type" => type} = node, type), do: node

  defp find_node(%{"children" => children}, type) when is_list(children),
    do: Enum.find_value(children, &find_node(&1, type))

  defp find_node(_node, _type), do: nil

  defp showrunner_meta(%{"showrunner" => %{} = show}), do: {:ok, show}
  defp showrunner_meta(%{"showrunner" => _}), do: {:error, {:bad_prop, "meta.showrunner"}}
  defp showrunner_meta(_meta), do: {:error, {:missing, "meta.showrunner"}}

  defp stages_from_doc(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, %{}}, fn
      %{"stage" => name, "state" => state_name}, {:ok, acc} ->
        with {:ok, stage} <- lookup(@stage_by_name, name, :stage),
             {:ok, state} <- lookup(@state_by_name, state_name, :stage_state),
             false <- Map.has_key?(acc, stage) do
          {:cont, {:ok, Map.put(acc, stage, state)}}
        else
          true -> {:halt, {:error, {:duplicate_stage, name}}}
          error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, {:bad_prop, :stages}}}
    end)
    |> case do
      {:ok, stages} when map_size(stages) == length(@stages) -> {:ok, stages}
      {:ok, _partial} -> {:error, {:bad_prop, :stages}}
      error -> error
    end
  end

  defp stages_from_doc(_other), do: {:error, {:bad_prop, :stages}}

  defp needs_you_from_doc(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      with {:ok, item} <- needs_you_item(item),
           :ok <- unique_needs_you(acc, item.id) do
        {:cont, {:ok, acc ++ [item]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp needs_you_from_doc(_other), do: {:error, {:bad_prop, :needs_you}}

  # A document may carry an empty run sheet (an episode before the run_sheet
  # stage); put_run_sheet/2 may not.
  defp segments_from_doc([]), do: {:ok, []}
  defp segments_from_doc(segments), do: run_sheet(segments)

  # ── Validation ──

  defp initial_stages do
    Map.new(@stages, fn
      :pitch -> {:pitch, :in_progress}
      stage -> {stage, :not_started}
    end)
  end

  defp run_sheet(segments) when is_list(segments) do
    segments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0, MapSet.new()}, fn {raw, index}, {:ok, acc, cursor, ids} ->
      with {:ok, segment} <- segment(raw, index),
           :ok <- check(not MapSet.member?(ids, segment.id), {:duplicate_segment, segment.id}),
           :ok <- check(segment.starts_at_s == cursor, {:not_contiguous, segment.id, cursor}) do
        {:cont, {:ok, acc ++ [segment], segment.ends_at_s, MapSet.put(ids, segment.id)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _segments, total, _ids} when total > @max_run_s ->
        {:error, {:run_too_long, total, @max_run_s}}

      {:ok, segments, _total, _ids} ->
        {:ok, segments}

      error ->
        error
    end
  end

  defp run_sheet(_other), do: {:error, {:bad_prop, :run_sheet}}

  defp segment(raw, index) when is_map(raw) do
    with {:ok, id} <- non_blank(get(raw, :id), {:segment, index, :id}),
         {:ok, name} <- non_blank(get(raw, :name), {:segment, id, :name}),
         {:ok, starts} <- seconds(get(raw, :starts_at_s), {:segment, id, :starts_at_s}),
         {:ok, ends} <- seconds(get(raw, :ends_at_s), {:segment, id, :ends_at_s}),
         :ok <- check(ends > starts, {:empty_segment, id}),
         {:ok, points} <- talking_points(get(raw, :talking_points) || %{}, id),
         {:ok, callback} <- callback_episode(get(raw, :callback_episode), id),
         {:ok, cards} <- stat_cards(get(raw, :stat_cards) || [], id) do
      {:ok,
       %{
         id: id,
         starts_at_s: starts,
         ends_at_s: ends,
         name: name,
         talking_points: points,
         callback_episode: callback,
         stat_cards: cards
       }}
    end
  end

  defp segment(_raw, index), do: {:error, {:bad_prop, {:segment, index}}}

  defp talking_points(points, id) when is_map(points) do
    Enum.reduce_while(points, {:ok, %{}}, fn
      {host, text}, {:ok, acc} when (is_binary(host) or is_atom(host)) and is_binary(text) ->
        case host |> to_string() |> String.trim() do
          "" -> {:halt, {:error, {:bad_prop, {:segment, id, :talking_points}}}}
          key -> {:cont, {:ok, Map.put(acc, key, text)}}
        end

      _pair, _acc ->
        {:halt, {:error, {:bad_prop, {:segment, id, :talking_points}}}}
    end)
  end

  defp talking_points(_points, id), do: {:error, {:bad_prop, {:segment, id, :talking_points}}}

  defp callback_episode(nil, _id), do: {:ok, nil}
  defp callback_episode(n, _id) when is_integer(n) and n > 0, do: {:ok, n}
  defp callback_episode(_n, id), do: {:error, {:bad_prop, {:segment, id, :callback_episode}}}

  defp stat_cards(cards, id) when is_list(cards) do
    Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, acc} ->
      case stat_card(card, id) do
        {:ok, card} -> {:cont, {:ok, acc ++ [card]}}
        error -> {:halt, error}
      end
    end)
  end

  defp stat_cards(_cards, id), do: {:error, {:bad_prop, {:segment, id, :stat_cards}}}

  defp stat_card(card, id) when is_map(card) do
    with {:ok, text} <- non_blank(get(card, :text), {:segment, id, :stat_text}),
         {:ok, url} <- source_url(get(card, :source_url), id) do
      {:ok, %{text: text, source_url: url}}
    end
  end

  defp stat_card(_card, id), do: {:error, {:bad_prop, {:segment, id, :stat_cards}}}

  # A stat without a source is refused: the show never airs an unsourced number.
  defp source_url(url, id) do
    case non_blank(url, :source_url) do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, {:unsourced_stat, id}}
    end
  end

  defp needs_you_item(item) when is_map(item) do
    with {:ok, id} <- non_blank(get(item, :id), {:needs_you, :id}),
         {:ok, question} <- non_blank(get(item, :question), {:needs_you, id, :question}),
         {:ok, options} <- options(get(item, :options), id) do
      {:ok, %{id: id, question: question, options: options}}
    end
  end

  defp needs_you_item(_item), do: {:error, {:bad_prop, :needs_you}}

  defp options([_ | _] = options, id) do
    if Enum.all?(options, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, options},
      else: {:error, {:bad_prop, {:needs_you, id, :options}}}
  end

  defp options(_options, id), do: {:error, {:bad_prop, {:needs_you, id, :options}}}

  defp unique_needs_you(items, id) do
    check(not Enum.any?(items, &(&1.id == id)), {:duplicate_needs_you, id})
  end

  defp retro(attrs, segments) when is_map(attrs) do
    on_sheet = MapSet.new(segments, & &1.id)

    with {:ok, kept} <- id_list(get(attrs, :kept_segment_ids) || [], :kept_segment_ids),
         {:ok, cut} <- id_list(get(attrs, :cut_segment_ids) || [], :cut_segment_ids),
         {:ok, clips} <- map_list(get(attrs, :clip_results) || [], :clip_results),
         :ok <- check(MapSet.disjoint?(MapSet.new(kept), MapSet.new(cut)), :kept_and_cut_overlap),
         :ok <- check(Enum.all?(kept ++ cut, &MapSet.member?(on_sheet, &1)), :retro_off_sheet) do
      {:ok, %{kept_segment_ids: kept, cut_segment_ids: cut, clip_results: clips}}
    end
  end

  defp retro(_attrs, _segments), do: {:error, {:bad_prop, :retro}}

  defp id_list(ids, field) when is_list(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, {:bad_prop, field}}
  end

  defp id_list(_ids, field), do: {:error, {:bad_prop, field}}

  # Shallow-stringified keys, so the list survives a JSON round-trip as given.
  defp map_list(list, field) when is_list(list) do
    if Enum.all?(list, &plain_map?/1),
      do: {:ok, Enum.map(list, &stringify_keys/1)},
      else: {:error, {:bad_prop, field}}
  end

  defp map_list(_list, field), do: {:error, {:bad_prop, field}}

  defp plain_map?(map) when is_map(map) and not is_struct(map),
    do: Enum.all?(Map.keys(map), &(is_binary(&1) or is_atom(&1)))

  defp plain_map?(_other), do: false

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp number(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp number(_n), do: {:error, {:bad_prop, :number}}

  defp seconds(s, _field) when is_integer(s) and s >= 0, do: {:ok, s}
  defp seconds(_s, field), do: {:error, {:bad_prop, field}}

  defp records_at(nil), do: {:ok, nil}

  defp records_at(%DateTime{} = at) do
    case DateTime.shift_zone(at, "Etc/UTC") do
      {:ok, utc} -> {:ok, DateTime.truncate(utc, :second)}
      _ -> {:error, {:bad_prop, :records_at}}
    end
  end

  defp records_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> records_at(at)
      _ -> {:error, {:bad_prop, :records_at}}
    end
  end

  defp records_at(_other), do: {:error, {:bad_prop, :records_at}}

  defp non_blank(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:bad_prop, field}}
      _ -> {:ok, value}
    end
  end

  defp non_blank(_value, field), do: {:error, {:bad_prop, field}}

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, _field) when is_binary(value), do: {:ok, value}
  defp optional_string(_value, field), do: {:error, {:bad_prop, field}}

  defp lookup(table, name, field) when is_binary(name) do
    case Map.fetch(table, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:bad_prop, field}}
    end
  end

  defp lookup(_table, _name, field), do: {:error, {:bad_prop, field}}

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  # Atom key first, then its string form: callers pass either.
  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
