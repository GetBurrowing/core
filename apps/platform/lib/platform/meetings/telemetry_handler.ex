defmodule Platform.Meetings.TelemetryHandler do
  @moduledoc """
  Bridges Meetings `:telemetry` events to the audit event store.

  Attach once in `Application.start/2` (after `Platform.Chat.TelemetryHandler.attach/0`):

      Platform.Meetings.TelemetryHandler.attach()

  ## Handled events

    | Telemetry event                                       | Audit event type              |
    |-------------------------------------------------------|-------------------------------|
    | `[:platform, :meetings, :triage_dispatch]`            | `"meetings.triage.dispatch"`  |
    | `[:platform, :meetings, :tasks_created_from_meeting]` | `"meetings.tasks_created"`    |
    | `[:platform, :meetings, :triage_cap_hit]`             | `"meetings.triage.cap_hit"`   |

  Plus the three intent-classifier FAILURE events, each pinned to an
  explicit slug (see "Why the intent-classifier failures are overridden
  too" below):

    | `[:platform, :meetings, :intent_classifier, :truncated_output]` | `"meetings.intent_classifier.truncated_output"` |
    | `[:platform, :meetings, :intent_classifier, :model_error]`      | `"meetings.intent_classifier.model_error"`      |
    | `[:platform, :meetings, :intent_classifier, :parse_error]`      | `"meetings.intent_classifier.parse_error"`      |

  ## Why a dedicated Meetings handler vs extending Chat's

  Audit type namespace + handler_id per subsystem is the existing pattern
  (Vault, Memory, Audit each own their own handler). Cheaper than a
  shared handler with a type-tag map, and it keeps the audit-event-type
  slug stable per subsystem for reporting.

  ## Naming exception — `tasks_created_from_meeting`

  Every other telemetry event in this module maps 1:1 to its audit_type
  by splitting the last-atom's underscores (`triage_dispatch` →
  `triage.dispatch`). `tasks_created_from_meeting` intentionally does
  NOT — it flattens to `tasks_created` (dropping the `_from_meeting`
  discriminator) because the audit consumers key off the domain-scoped
  slug and the "from meeting" context is already implied by the
  `meetings.` prefix. The handler recognizes both event names.

  ## Why the intent-classifier failures are overridden too

  The three `intent_classifier` failure events are FOUR-segment names,
  and the default derivation splits every atom on its first underscore —
  so `[:platform, :meetings, :intent_classifier, :model_error]` would
  derive `"meetings.intent.classifier.model.error"`, a five-level
  hierarchy that does not exist, and it buries the outcome name the
  classifier deliberately keeps separate. Each is therefore pinned to an
  explicit slug that keeps `intent_classifier` whole and keeps the three
  outcomes DISTINCT — telling `truncated_output` from `model_error` from
  `parse_error` is the entire reason they are separate events.

  Only the FAILURE events are bridged. The success event
  `[:platform, :meetings, :intent_classified]` fires on every transcript
  chunk of every meeting and would flood `audit_events`; it is
  deliberately NOT attached.
  """

  require Logger

  @handler_id "platform-meetings-telemetry"

  @meetings_events [
    [:platform, :meetings, :triage_dispatch],
    [:platform, :meetings, :tasks_created_from_meeting],
    [:platform, :meetings, :triage_cap_hit],
    [:platform, :meetings, :intent_classifier, :truncated_output],
    [:platform, :meetings, :intent_classifier, :model_error],
    [:platform, :meetings, :intent_classifier, :parse_error]
  ]

  # Overrides for the default `event_name_to_string/1` derivation when
  # the desired audit type does not match the telemetry event's atom
  # segments 1:1 (see moduledoc "Naming exception" section).
  @audit_type_overrides %{
    [:platform, :meetings, :tasks_created_from_meeting] => "meetings.tasks_created",
    [:platform, :meetings, :intent_classifier, :truncated_output] =>
      "meetings.intent_classifier.truncated_output",
    [:platform, :meetings, :intent_classifier, :model_error] =>
      "meetings.intent_classifier.model_error",
    [:platform, :meetings, :intent_classifier, :parse_error] =>
      "meetings.intent_classifier.parse_error"
  }

  @doc """
  Attach the handler to all registered meetings telemetry events.

  Idempotent — a duplicate attach is a no-op (see
  `Platform.Audit.TelemetryHandler.attach/0` for the reasoning).
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @meetings_events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler (useful in tests)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler is attached to."
  def events, do: @meetings_events

  @doc false
  def handle_event(event_name, measurements, metadata, _config) do
    attrs = build_attrs(event_name, measurements, metadata)

    case Platform.Audit.record(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Meetings audit persist failed: #{inspect(changeset.errors)}",
          event: inspect(event_name)
        )
    end
  rescue
    error ->
      # Telemetry detaches handlers that raise — never let that happen.
      Logger.error(
        "Meetings audit handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}",
        event: inspect(event_name)
      )
  end

  # -- Internals --

  defp build_attrs(event_name, measurements, metadata) do
    event_type = event_name_to_string(event_name)

    %{
      event_type: event_type,
      actor_id: Map.get(metadata, :actor_id),
      actor_type: Map.get(metadata, :actor_type, "system"),
      resource_type: Map.get(metadata, :resource_type, "meetings"),
      resource_id: resource_id_from(metadata),
      action: Map.get(metadata, :action, "execute") |> to_string(),
      metadata: build_metadata(measurements, metadata),
      session_id: Map.get(metadata, :session_id),
      ip_address: Map.get(metadata, :ip_address)
    }
  end

  # Try to extract a meaningful resource_id from the metadata map.
  # Order matters — the first match wins. `canvas_id` before
  # `meeting_id` because triage events are canvas-scoped (the source
  # meeting canvas is the natural anchor); `task_id` last as a fallback
  # for the per-task events.
  defp resource_id_from(%{canvas_id: id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from(%{meeting_id: id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from(%{transcript_id: id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from(%{task_id: id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from(%{resource_id: id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from(_), do: nil

  # Maps [:platform, :meetings, :triage_dispatch] → "meetings.triage.dispatch"
  # Overrides win for events whose audit-type intentionally differs from
  # the underscore-split default (see @audit_type_overrides).
  defp event_name_to_string(event_name) do
    case Map.get(@audit_type_overrides, event_name) do
      nil -> default_event_name_to_string(event_name)
      override -> override
    end
  end

  defp default_event_name_to_string([:platform | rest]) do
    rest
    |> Enum.flat_map(&atom_to_segments/1)
    |> Enum.join(".")
  end

  defp default_event_name_to_string(event_name) do
    event_name
    |> Enum.flat_map(&atom_to_segments/1)
    |> Enum.join(".")
  end

  # Converts an atom to one or two string segments by splitting on the first "_".
  # :meetings → ["meetings"]
  # :triage_dispatch → ["triage", "dispatch"]
  # :triage_cap_hit → ["triage", "cap_hit"]  (only the first "_" splits)
  defp atom_to_segments(atom) do
    str = Atom.to_string(atom)

    case String.split(str, "_", parts: 2) do
      [only] -> [only]
      [head, tail] -> [head, tail]
    end
  end

  @top_level_keys ~w(actor_id actor_type resource_type resource_id action session_id ip_address)a

  defp build_metadata(measurements, metadata) do
    metadata
    |> Map.drop(@top_level_keys)
    |> Map.merge(measurements)
    |> ensure_json_safe()
  end

  # Structs need custom handling — `Map.new/2` over a struct tries to
  # enumerate it (fails for DateTime/NaiveDateTime/etc which don't
  # implement the Enumerable protocol). We ISO-8601 the temporal ones
  # and stringify anything else via `inspect/1`, which is the safe
  # fallback the Chat handler dodges by never emitting structs.
  defp ensure_json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp ensure_json_safe(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp ensure_json_safe(%Date{} = d), do: Date.to_iso8601(d)
  defp ensure_json_safe(%Time{} = t), do: Time.to_iso8601(t)

  defp ensure_json_safe(%_struct{} = struct_value) do
    struct_value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> ensure_json_safe()
  end

  defp ensure_json_safe(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), ensure_json_safe(v)}
      {k, v} -> {to_string(k), ensure_json_safe(v)}
    end)
  end

  defp ensure_json_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp ensure_json_safe(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&ensure_json_safe/1)
  defp ensure_json_safe(v) when is_list(v), do: Enum.map(v, &ensure_json_safe/1)
  defp ensure_json_safe(v) when is_pid(v), do: inspect(v)
  defp ensure_json_safe(v) when is_reference(v), do: inspect(v)
  defp ensure_json_safe(v) when is_function(v), do: inspect(v)
  defp ensure_json_safe(v), do: v
end
