defmodule Platform.Feedback.Submission do
  @moduledoc """
  The `feedback_submit` boundary (task 01a11ec3 stage 2): an allowlisted,
  bounded, redacted structure, a duplicate fingerprint and rate limits, all
  checked BEFORE any external call, then one publication through
  `Platform.Feedback.GithubPublisher`.

  ## Order of checks

    1. Capability. `Platform.Feedback.Policy.enabled?/0`; disabled refuses
       before anything is read.
    2. Actor. An identified agent is required; anonymous calls are refused.
    3. Shape. Only the allowlisted keys are read: `category`, `title`,
       `expected_behavior`, `observed_behavior`, `reproduction_steps`,
       `version_environment`, `diagnostics`. Every other key is ignored and
       named (by key only, never value) in `ignored_fields`.
    4. Redaction (`Platform.Feedback.Redaction`), then per-field and
       aggregate length limits on the redacted text, then the category enum.
    5. Fingerprint: sha256 over the normalized allowlisted text, so a retry
       (or the same report with different spacing or case) maps to one key.
    6. Duplicate: an existing `published` row answers with its issue and no
       external call. A `pending` row younger than the in-flight window is
       refused as `:in_flight`; an older one is reconciled through the
       publisher's `find_existing/1` before it may publish again.
    7. Rate limits, per actor and per installation, over the rolling window.
       A duplicate never consumes quota.
    8. Reserve the row (unique fingerprint), publish, record the outcome.

  ## Diagnostics

  Absent by default. A `diagnostics` value is used only when it is a map with
  `include: true`, a `scope` from `diagnostic_scopes/0`, and a non-blank
  `content` string — the caller must both opt in and say what it is. Anything
  else is dropped (and reported as `diagnostics_dropped: true`). Nothing in
  this module gathers diagnostics itself: no logs, no session, no
  environment, no other tool's output is ever read.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Feedback.GithubPublisher
  alias Platform.Feedback.Policy
  alias Platform.Feedback.Redaction
  alias Platform.Feedback.SubmissionRecord
  alias Platform.Repo

  @categories ~w(bug positive_change)
  @diagnostic_scopes ~w(error_message stack_trace tool_call request_shape configuration)

  @text_fields [
    :title,
    :expected_behavior,
    :observed_behavior,
    :reproduction_steps,
    :version_environment
  ]
  @required [:title, :expected_behavior, :observed_behavior]

  @limits %{
    title: 200,
    expected_behavior: 2_000,
    observed_behavior: 4_000,
    reproduction_steps: 4_000,
    version_environment: 1_000,
    diagnostics: 4_000
  }
  @aggregate_limit 12_000

  @allowed_keys ~w(category title expected_behavior observed_behavior reproduction_steps version_environment diagnostics)
  @max_ignored_reported 20

  @default_per_actor 5
  @default_per_installation 30
  @default_window_seconds 3_600
  @in_flight_seconds 600

  @doc "The accepted `category` values."
  def categories, do: @categories

  @doc "The accepted `diagnostics.scope` values."
  def diagnostic_scopes, do: @diagnostic_scopes

  @doc "The allowlisted argument keys."
  def allowed_keys, do: @allowed_keys

  @doc "Per-field length limits (graphemes, measured after redaction)."
  def limits, do: @limits

  @doc "The aggregate length limit across every field (graphemes)."
  def aggregate_limit, do: @aggregate_limit

  @doc """
  Submit feedback. `actor` is `%{agent_id: binary, slug: binary | nil}`.

  Returns `{:ok, result}` where `result.status` is `"created"` or
  `"duplicate"`, or `{:error, %{code: atom, message: binary}}` (plus
  `:field` / `:retry_after_seconds` where they apply).
  """
  @spec submit(map(), map() | nil) :: {:ok, map()} | {:error, map()}
  def submit(args, actor) do
    with :ok <- capability(),
         {:ok, actor} <- actor(actor),
         {:ok, sanitized, report} <- normalize(args) do
      fingerprint = fingerprint(sanitized)
      publish_once(sanitized, report, fingerprint, actor)
    end
  end

  @doc """
  Validate, redact and bound `args`. Pure: no database, no network.

  Returns `{:ok, sanitized, report}` where `report` carries `:redactions`,
  `:ignored_fields`, `:diagnostics_included` and `:diagnostics_dropped`.
  """
  @spec normalize(map()) :: {:ok, map(), map()} | {:error, map()}
  def normalize(args) when is_map(args) do
    args = stringify_keys(args)
    ignored = args |> Map.keys() |> Enum.reject(&(&1 in @allowed_keys)) |> Enum.sort()

    with {:ok, category} <- category(args["category"]),
         {:ok, fields, redactions} <- text_fields(args),
         {:ok, diagnostics, diag_redactions, dropped?} <- diagnostics(args["diagnostics"]),
         :ok <- aggregate(fields, diagnostics) do
      sanitized =
        fields
        |> Map.put(:category, category)
        |> maybe_put(:diagnostics, diagnostics)

      {:ok, sanitized,
       %{
         redactions: redactions + diag_redactions,
         ignored_fields: Enum.take(ignored, @max_ignored_reported),
         diagnostics_included: not is_nil(diagnostics),
         diagnostics_dropped: dropped?
       }}
    end
  end

  def normalize(_args), do: error(:invalid_arguments, "arguments must be an object")

  @doc """
  The duplicate fingerprint: sha256 (lowercase hex) of the category and the
  allowlisted text fields, each trimmed, whitespace-collapsed and downcased.
  Diagnostics are excluded, so a retry that attaches different diagnostics is
  still the same report.
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(sanitized) do
    parts =
      [sanitized.category | Enum.map(@text_fields, &canonical(Map.get(sanitized, &1)))]

    :crypto.hash(:sha256, Enum.join(parts, <<0>>)) |> Base.encode16(case: :lower)
  end

  # ── checks ─────────────────────────────────────────────────────────────

  defp capability do
    if Policy.enabled?(),
      do: :ok,
      else: error(:feedback_disabled, "feedback submission is not enabled on this installation")
  end

  defp actor(%{agent_id: id} = actor) when is_binary(id) and id != "",
    do: {:ok, %{agent_id: id, slug: Map.get(actor, :slug)}}

  defp actor(_), do: error(:unauthorized, "feedback_submit requires an identified agent caller")

  defp category(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized in @categories,
      do: {:ok, normalized},
      else:
        error(:invalid_category, "category must be one of: #{Enum.join(@categories, ", ")}",
          field: "category"
        )
  end

  defp category(_),
    do:
      error(:invalid_category, "category must be one of: #{Enum.join(@categories, ", ")}",
        field: "category"
      )

  defp text_fields(args) do
    Enum.reduce_while(@text_fields, {:ok, %{}, 0}, fn field, {:ok, acc, count} ->
      key = Atom.to_string(field)

      case text_field(field, Map.get(args, key)) do
        {:ok, nil, 0} -> {:cont, {:ok, acc, count}}
        {:ok, text, n} -> {:cont, {:ok, Map.put(acc, field, text), count + n}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp text_field(field, nil) do
    if field in @required,
      do: error(:missing_field, "`#{field}` is required", field: Atom.to_string(field)),
      else: {:ok, nil, 0}
  end

  defp text_field(field, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        text_field(field, nil)

      trimmed ->
        {redacted, n} = Redaction.redact(trimmed)
        limit = Map.fetch!(@limits, field)

        if String.length(redacted) > limit,
          do:
            error(:field_too_long, "`#{field}` is longer than #{limit} characters",
              field: Atom.to_string(field)
            ),
          else: {:ok, redacted, n}
    end
  end

  defp text_field(field, _value),
    do: error(:invalid_field, "`#{field}` must be a string", field: Atom.to_string(field))

  defp diagnostics(nil), do: {:ok, nil, 0, false}

  defp diagnostics(value) when is_map(value) do
    value = stringify_keys(value)

    with true <- value["include"] == true,
         scope when is_binary(scope) <- value["scope"],
         scope = scope |> String.trim() |> String.downcase(),
         true <- scope in @diagnostic_scopes,
         content when is_binary(content) <- value["content"],
         trimmed when trimmed != "" <- String.trim(content) do
      {redacted, n} = Redaction.redact(trimmed)

      if String.length(redacted) > @limits.diagnostics,
        do:
          error(
            :field_too_long,
            "`diagnostics.content` is longer than #{@limits.diagnostics} characters",
            field: "diagnostics"
          ),
        else: {:ok, %{scope: scope, content: redacted}, n, false}
    else
      _ -> {:ok, nil, 0, true}
    end
  end

  defp diagnostics(_other), do: {:ok, nil, 0, true}

  defp aggregate(fields, diagnostics) do
    total =
      fields
      |> Map.values()
      |> Enum.map(&String.length/1)
      |> Enum.sum()
      |> Kernel.+(if diagnostics, do: String.length(diagnostics.content), else: 0)

    if total > @aggregate_limit,
      do:
        error(
          :submission_too_long,
          "the submission is longer than #{@aggregate_limit} characters in total"
        ),
      else: :ok
  end

  # ── publication ────────────────────────────────────────────────────────

  defp publish_once(sanitized, report, fingerprint, actor) do
    case existing(fingerprint) do
      %SubmissionRecord{status: "published"} = record ->
        {:ok, result("duplicate", identity(record), fingerprint, report)}

      %SubmissionRecord{status: "pending"} = record ->
        if fresh?(record),
          do: in_flight(),
          else: reconcile(record, sanitized, report, fingerprint, actor)

      %SubmissionRecord{status: "failed"} = record ->
        with :ok <- rate_limit(actor),
             {:ok, record} <- claim(record, actor) do
          publish(record, sanitized, report, fingerprint, actor)
        end

      nil ->
        with :ok <- rate_limit(actor),
             {:ok, record} <- reserve(fingerprint, sanitized.category, actor) do
          publish(record, sanitized, report, fingerprint, actor)
        end
    end
  end

  # A stale `pending` row means an earlier attempt ended without recording an
  # outcome — possibly AFTER the issue was created. Ask the publisher before
  # publishing again, so that window cannot produce a second issue.
  defp reconcile(record, sanitized, report, fingerprint, actor) do
    with {:ok, record} <- claim(record, actor) do
      case GithubPublisher.find_existing(fingerprint: fingerprint) do
        {:ok, %{} = identity} ->
          {:ok, _} = mark_published(record, identity)
          {:ok, result("duplicate", identity, fingerprint, report)}

        {:ok, nil} ->
          publish(record, sanitized, report, fingerprint, actor)

        {:error, code} ->
          {:ok, _} = mark_failed(record, code)
          publisher_error(code)
      end
    end
  end

  defp publish(record, sanitized, report, fingerprint, actor) do
    issue =
      GithubPublisher.build_issue(sanitized, %{
        fingerprint: fingerprint,
        actor: actor.slug,
        installation: GithubPublisher.config(:installation_label)
      })

    case GithubPublisher.publish(issue, fingerprint: fingerprint) do
      {:ok, identity} ->
        {:ok, _} = mark_published(record, identity)
        {:ok, result("created", identity, fingerprint, report)}

      {:error, code} ->
        {:ok, _} = mark_failed(record, code)
        publisher_error(code)
    end
  end

  defp existing(fingerprint) do
    Repo.one(from(r in SubmissionRecord, where: r.fingerprint == ^fingerprint))
  end

  defp fresh?(%SubmissionRecord{attempted_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at, :second) < @in_flight_seconds

  defp fresh?(_record), do: false

  defp reserve(fingerprint, category, actor) do
    attrs = %{
      fingerprint: fingerprint,
      category: category,
      actor_agent_id: actor.agent_id,
      attempted_at: DateTime.utc_now()
    }

    case attrs |> SubmissionRecord.reserve_changeset() |> Repo.insert() do
      {:ok, record} ->
        {:ok, record}

      # A concurrent identical submission reserved the fingerprint first.
      {:error, %Ecto.Changeset{}} ->
        in_flight()
    end
  end

  # Take over a failed or stale row with a compare-and-set on its status and
  # attempt time, so two retries racing for the same row publish once.
  defp claim(%SubmissionRecord{} = record, actor) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(r in SubmissionRecord,
          where:
            r.id == ^record.id and r.status == ^record.status and
              r.attempted_at == ^record.attempted_at
        ),
        set: [
          status: "pending",
          attempted_at: now,
          error_code: nil,
          actor_agent_id: actor.agent_id,
          updated_at: now
        ]
      )

    if count == 1,
      do: {:ok, %{record | status: "pending", attempted_at: now, error_code: nil}},
      else: in_flight()
  end

  defp mark_published(record, identity) do
    record
    |> SubmissionRecord.status_changeset(%{
      status: "published",
      external_repository: identity.repository,
      external_issue_number: identity.issue_number,
      error_code: nil,
      published_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp mark_failed(record, code) do
    record
    |> SubmissionRecord.status_changeset(%{status: "failed", error_code: Atom.to_string(code)})
    |> Repo.update()
  end

  defp rate_limit(actor) do
    window = rate_config(:window_seconds, @default_window_seconds)
    since = DateTime.add(DateTime.utc_now(), -window, :second)
    per_actor = rate_config(:per_actor, @default_per_actor)
    per_installation = rate_config(:per_installation, @default_per_installation)

    actor_count =
      Repo.aggregate(
        from(r in SubmissionRecord,
          where: r.actor_agent_id == ^actor.agent_id and r.inserted_at > ^since
        ),
        :count
      )

    installation_count =
      Repo.aggregate(from(r in SubmissionRecord, where: r.inserted_at > ^since), :count)

    cond do
      actor_count >= per_actor ->
        rate_limited("this agent has reached its feedback limit", window)

      installation_count >= per_installation ->
        rate_limited("this installation has reached its feedback limit", window)

      true ->
        :ok
    end
  end

  defp rate_config(key, default) do
    case Application.get_env(:platform, :feedback_rate_limits, []) |> Keyword.get(key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  # ── results ────────────────────────────────────────────────────────────

  defp identity(%SubmissionRecord{} = record) do
    %{
      repository: record.external_repository,
      issue_number: record.external_issue_number,
      url:
        "https://github.com/#{record.external_repository}/issues/#{record.external_issue_number}"
    }
  end

  defp result(status, identity, fingerprint, report) do
    %{
      status: status,
      issue: identity,
      fingerprint: fingerprint,
      redactions: report.redactions,
      ignored_fields: report.ignored_fields,
      diagnostics_included: report.diagnostics_included,
      diagnostics_dropped: report.diagnostics_dropped
    }
  end

  defp in_flight,
    do:
      error(
        :in_flight,
        "an identical submission is already being published; retry in a few minutes"
      )

  defp rate_limited(message, window),
    do: {:error, %{code: :rate_limited, message: message, retry_after_seconds: window}}

  defp publisher_error(code),
    do:
      {:error,
       %{code: code, message: "the feedback publisher did not accept the submission (#{code})"}}

  defp error(code, message, extra \\ []),
    do: {:error, Map.merge(%{code: code, message: message}, Map.new(extra))}

  # ── helpers ────────────────────────────────────────────────────────────

  defp canonical(nil), do: ""

  defp canonical(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
