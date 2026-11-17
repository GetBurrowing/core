defmodule Platform.Sharing.UsageEvents do
  @moduledoc """
  Anonymous usage counts (task 01a1b678 stage 2): the PINNED list of what is
  counted, the collector that counts it, and the scrubber every batch passes
  before it leaves the install.

  ## Exactly what is sent

  One JSON body per batch window, to `<broker base>/usage`
  (`Platform.Feedback.GithubPublisher.Broker.post_usage/1`):

      %{"sharing_install_id" => uuid, "window" => %{"start" => unix_s, "seconds" => n},
        "counts" => %{event_name => non_negative_integer}}

  `sharing_install_id` is the random id on the `install_sharing` row
  (`Platform.Sharing`), not the federation install id and linked to no
  account. `counts` keys are a subset of `events/0`. Nothing else: no message
  content, names, emails, space or agent names, ids of people, spaces or
  agents, and no free text. Telemetry METADATA is never read; the collector
  counts the event name and nothing more.

  `events/0` is this table's first column, pinned by
  `Platform.Sharing.UsageEventsTest`:

    | Sent as                        | Counted from (`:telemetry`)                     |
    |--------------------------------|-------------------------------------------------|
    | `message.posted`               | `[:platform, :chat, :message_posted]` (people and agents) |
    | `message.edited`               | `[:platform, :chat, :message_edited]`           |
    | `message.deleted`              | `[:platform, :chat, :message_deleted]`          |
    | `thread.created`               | `[:platform, :chat, :thread_created]`           |
    | `reaction.added`               | `[:platform, :chat, :reaction_added]`           |
    | `pin.added`                    | `[:platform, :chat, :pin_added]`                |
    | `canvas.created`               | `[:platform, :chat, :canvas_created]`           |
    | `space.created`                | `[:platform, :chat, :space_created]`            |
    | `meeting.started`              | `[:burrow, :interaction, :meeting_started]`     |
    | `meeting.transcription_failed` | `[:platform, :meetings, :transcription_failed]` |
    | `access.blocked`               | `[:platform, :auth, :access_blocked]`           |

  The last two are drop-off points: a meeting whose transcript failed, and a
  person who hit a wall they were not allowed past.

  ## One emission family for user-choice interactions

  Every `:telemetry` event above except `meeting.started` already existed. A
  NEW emit for a user-choice interaction goes under
  `[:burrow, :interaction, ...]`, the one family both these counts and the
  learned-defaults work (task 01a1b6a1) consume, so there is never a second
  emission framework. `Platform.Meetings.start_meeting/2` emits
  `[:burrow, :interaction, :meeting_started]`. Adding an event here means
  one row in `@events`, one literal in the pin test, and one line in the
  decision note's "Exactly what is sent".

  ## The collector never raises

  `:telemetry` detaches a handler that raises or exits, VM-wide and for the
  rest of the run. `handle_event/4` therefore does all its work inside
  `try/rescue/catch` and returns `:ok`. It touches only the ETS table, never
  the database: whether counting is on is a flag in that table, refreshed
  from `Platform.Sharing.enabled?(:usage_counts)` by
  `Platform.Sharing.UsageBatcher` on every flush and by `Platform.Sharing.set/3`
  on every change. No table, or the flag off, means the event is dropped.

  ## The scrubber

  `scrub_counts/1` keeps only pinned names whose value is a non-negative
  integer. `refusal/1` then checks the ENCODED body: it must survive
  `Platform.Feedback.Redaction.redact/1` unchanged, contain no email-shaped
  text, and contain no string other than the install id, the pinned names and
  the body's own keys (the name sentinel: a person's name can only appear as
  a string the allowlist does not know). Any hit refuses the whole batch.
  """

  alias Platform.Feedback.Redaction

  @table __MODULE__
  @handler_id "platform-sharing-usage-events"

  @events [
    {"message.posted", [:platform, :chat, :message_posted]},
    {"message.edited", [:platform, :chat, :message_edited]},
    {"message.deleted", [:platform, :chat, :message_deleted]},
    {"thread.created", [:platform, :chat, :thread_created]},
    {"reaction.added", [:platform, :chat, :reaction_added]},
    {"pin.added", [:platform, :chat, :pin_added]},
    {"canvas.created", [:platform, :chat, :canvas_created]},
    {"space.created", [:platform, :chat, :space_created]},
    {"meeting.started", [:burrow, :interaction, :meeting_started]},
    {"meeting.transcription_failed", [:platform, :meetings, :transcription_failed]},
    {"access.blocked", [:platform, :auth, :access_blocked]}
  ]

  @names Enum.map(@events, &elem(&1, 0))
  @by_telemetry Map.new(@events, fn {name, event} -> {event, name} end)

  @body_keys ~w(sharing_install_id window counts start seconds)

  @email ~r/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/

  @doc "The pinned event names, in order. Exactly what can appear in `counts`."
  @spec events() :: [String.t()]
  def events, do: @names

  @doc "The `:telemetry` event each pinned name is counted from."
  @spec telemetry_events() :: [{String.t(), :telemetry.event_name()}]
  def telemetry_events, do: @events

  @doc "The collector's `:telemetry` handler id."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  # ── collector ─────────────────────────────────────────────────────────────

  @doc """
  Create the counts table (if absent) and attach the collector. Called by
  `Platform.Sharing.UsageBatcher.init/1`, which owns the table. Idempotent.
  """
  @spec attach() :: :ok
  def attach do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    end

    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        Enum.map(@events, &elem(&1, 1)),
        &__MODULE__.handle_event/4,
        nil
      )

    :ok
  end

  @doc "Detach the collector. The table goes with its owner."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  @doc """
  The `:telemetry` handler. Counts the event's pinned name when the table
  exists and the flag is on. Never raises, never reads metadata, never
  touches the database.
  """
  def handle_event(event, _measurements, _metadata, _config) do
    with name when is_binary(name) <- Map.get(@by_telemetry, event),
         true <- counting?() do
      :ets.update_counter(@table, {:count, name}, {2, 1}, {{:count, name}, 0})
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Whether the collector is counting right now (table present, flag on)."
  @spec counting?() :: boolean()
  def counting? do
    :ets.whereis(@table) != :undefined and :ets.lookup(@table, :enabled) == [{:enabled, true}]
  rescue
    _ -> false
  end

  @doc """
  Set the counting flag. `false` also drops every pending count, so nothing
  counted before the owner turned this off is ever sent. No-op without the
  table.
  """
  @spec set_counting(boolean()) :: :ok
  def set_counting(on?) when is_boolean(on?) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {:enabled, on?})
      unless on?, do: :ets.match_delete(@table, {{:count, :_}, :_})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "The pending counts, `%{name => n}`, only names with n > 0."
  @spec pending() :: %{String.t() => non_neg_integer()}
  def pending do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      @table
      |> :ets.match_object({{:count, :_}, :_})
      |> Enum.flat_map(fn {{:count, name}, n} -> if n > 0, do: [{name, n}], else: [] end)
      |> Map.new()
    end
  end

  @doc """
  Subtract `counts` (what a successful send carried) from the table, so an
  event counted while the request was in flight is kept for the next batch.
  """
  @spec subtract(%{String.t() => non_neg_integer()}) :: :ok
  def subtract(counts) when is_map(counts) do
    if :ets.whereis(@table) != :undefined do
      for {name, n} <- counts, is_integer(n) do
        :ets.update_counter(@table, {:count, name}, {2, -n}, {{:count, name}, 0})
      end
    end

    :ok
  end

  # ── scrubber ──────────────────────────────────────────────────────────────

  @doc """
  Keep only pinned names whose value is a non-negative integer. Everything
  else is dropped.
  """
  @spec scrub_counts(map()) :: %{String.t() => non_neg_integer()}
  def scrub_counts(counts) when is_map(counts) do
    counts
    |> Enum.filter(fn {name, n} -> name in @names and is_integer(n) and n >= 0 end)
    |> Map.new()
  end

  def scrub_counts(_counts), do: %{}

  @doc """
  The body for one batch. Only these three top-level keys exist; the counts
  are scrubbed here.
  """
  @spec build_body(String.t(), DateTime.t(), non_neg_integer(), map()) :: map()
  def build_body(sharing_install_id, %DateTime{} = window_start, seconds, counts)
      when is_binary(sharing_install_id) and is_integer(seconds) and seconds >= 0 do
    %{
      "sharing_install_id" => sharing_install_id,
      "window" => %{"start" => DateTime.to_unix(window_start), "seconds" => seconds},
      "counts" => scrub_counts(counts)
    }
  end

  @doc """
  Why `body` must not be sent, or `nil` when it is safe. Checks the encoded
  JSON: redaction must change nothing, no email-shaped text, and no string
  outside the allowlist (install id, pinned names, body keys). Optional common
  pack/shape extensions must pass their independent typed validators before
  being removed from the legacy count-string check.
  """
  @spec refusal(map()) ::
          nil | :redaction_hit | :email_sentinel | :unknown_string | :not_encodable
  def refusal(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} ->
        cond do
          elem(Redaction.redact(encoded), 1) > 0 ->
            :redaction_hit

          Regex.match?(@email, encoded) ->
            :email_sentinel

          not valid_outcomes?(body) ->
            :unknown_string

          not valid_shapes?(body) ->
            :unknown_string

          not only_known_strings?(
            Map.drop(body, ["instruction_outcomes", "learned_default_shapes"])
          ) ->
            :unknown_string

          true ->
            nil
        end

      {:error, _} ->
        :not_encodable
    end
  end

  defp valid_outcomes?(body) do
    not Map.has_key?(body, "instruction_outcomes") or
      Platform.InstructionPacks.Outcomes.valid?(body["instruction_outcomes"])
  end

  defp valid_shapes?(body) do
    not Map.has_key?(body, "learned_default_shapes") or
      Platform.Sharing.LearnedShapes.valid?(body["learned_default_shapes"])
  end

  defp only_known_strings?(body) do
    allowed = MapSet.new([body["sharing_install_id"] | @names ++ @body_keys])
    body |> strings() |> Enum.all?(&(is_binary(&1) and MapSet.member?(allowed, &1)))
  end

  defp strings(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> [to_string(k) | strings(v)] end)

  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(s) when is_binary(s), do: [s]
  defp strings(n) when is_integer(n), do: []
  defp strings(other), do: [other]
end
