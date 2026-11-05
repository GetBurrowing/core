defmodule Platform.Responsibilities.Handlers.Hr do
  @moduledoc """
  The HR responsibility: tracks people on a cadence and maintains the two
  tiered people profiles (task 01a1aa47 stage 4). Two rows, feature `"hr"`,
  both in the HISTORIAN bundle (`Platform.Roles.Seeds`): no new role.

    * `hr.daily_sweep` — cron, `per_org`, the people roster over the last
      `staleness_days`;
    * `hr.meeting_completed` — `meeting:finished`, `per_meeting`, the people
      who sat in one meeting and what each of them said in it.

  ## Cadence design

  HR daily sweep is cron `"0 4 * * *"` America/Chicago; dreaming stays at
  `"0 5 * * *"` and its row is untouched. HR is an INPUT to dreaming, never a
  gate on it. This module defines NO predicate about dreaming having run,
  keeps NO `dreaming_ran_at`, schedules NO dreaming fires and never fires the
  Router itself. `Platform.Memory.DreamingPasses` (task 01a1a2db) is the sole
  authority on dreaming's run state. The only HR-owned question is "is the HR
  daily sweep in flight right now", answered by `Platform.People.SweepState`
  from PERSISTED journal rows:

    * `gather_context/2` for `hr.daily_sweep` appends ONE org journal entry
      `HR daily sweep started <ISO8601>` with metadata
      `%{"source" => "responsibility:hr.daily_sweep", "phase" => "started",
      "started_at" => iso}`;
    * `handle_output/3` and `handle_refusal/3` (the external path, the only
      one that calls back) append `HR daily sweep finished <ISO8601>: updated
      <card paths>` with `"phase" => "finished"`.

  Only the daily sweep writes these rows: a `hr.meeting_completed` fire
  landing mid-sweep must not read as the sweep finishing.

  ## What the model gets and what the server keeps

  `gather_context/2` builds, deterministically: the roster
  (`Platform.People.Pages.roster/1`), the appearances in the window
  (`Platform.People.Appearances.collect/3`, or the transcript's participants
  through `Platform.Meetings.participants_for_transcript/1`), the staleness
  report (`Platform.People.Staleness.compute/4`), each resolved subject's own
  words and nothing anyone else said (`Platform.People.OwnWords.for_subject/4`),
  the contract (`Platform.People.Privacy.subject_reads_it_note/0`), the page
  grammar and the resolved `hr.profile` experiment payload.

  `handle_output/3` resolves every profile's name with
  `Platform.People.Identity.resolve/3`: an ambiguous profile is written
  NOWHERE and its candidates go to today's journal as a review line; two
  spellings of one person in one output land on one slug. Every page goes
  through `Platform.People.OutputGuard.render/1` (which drops any perspective
  not said by the subject) and then `Pages.write_card/4`, `write_private/4`
  and `regenerate_index/2`, with `updated_by` the assignee agent id.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.HrProfile
  alias Platform.Meetings
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Org.Context, as: OrgContext
  alias Platform.People.{Appearances, Identity, OutputGuard, OwnWords, Pages, Privacy}
  alias Platform.People.{Staleness, Visibility}
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @daily_key "hr.daily_sweep"
  @meeting_key "hr.meeting_completed"
  @feature "hr"
  @prompt_slug "hr.profile.v1"
  @nil_uuid "00000000-0000-0000-0000-000000000000"
  @context_provided [
    "people_roster",
    "people_appearances",
    "people_staleness",
    "people_own_words",
    "org_identity"
  ]
  @max_appearance_lines 200

  @page_grammar """
  ---
  tier: card | private
  name: ...
  aliases: ...
  user_id: ...
  relation: team | client | prospect | investor | collaborator | former | unknown
  organisation: ...
  role: ...
  last_seen: YYYY-MM-DD
  readers: [subject, admins]      # private only, inserted by the server
  subject_user_id: ...            # private only, inserted by the server
  ---

  ## Role
  ## Current projects
  ## Interactions                 # private only
  - <YYYY-MM-DD> <kind>: <title> [cite: <ref>]
  ## Perspectives                 # private only
  - <statement> — own words [cite: <ref>]
  ## Agents
  """

  @doc "Canonical key of the daily sweep row."
  @spec key() :: String.t()
  def key, do: @daily_key

  @doc "Canonical key of the meeting row."
  @spec meeting_key() :: String.t()
  def meeting_key, do: @meeting_key

  @doc "Both keys this handler owns."
  @spec keys() :: [String.t()]
  def keys, do: [@daily_key, @meeting_key]

  @doc "The prompt slug both rows render."
  @spec prompt_slug() :: String.t()
  def prompt_slug, do: @prompt_slug

  @doc "The page grammar handed to the model; mirrors `Platform.People.PageGuard`."
  @spec page_grammar() :: String.t()
  def page_grammar, do: @page_grammar

  # ── register ─────────────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @daily_key,
        feature: @feature,
        trigger_kind: "cron",
        # 04:00 America/Chicago, one hour before memory.dreaming's 05:00, so
        # the sweep's started/finished rows are what dreaming consults.
        trigger_config: %{"expression" => "0 4 * * *", "timezone" => "America/Chicago"},
        scope: "per_org",
        context_provided: @context_provided,
        output_contract: %{"people" => "list[object]", "review" => "list[string]?"},
        default_prompt_template: @prompt_slug,
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.people", "feeds" => "memory.dreaming"}
      },
      %{
        key: @meeting_key,
        feature: @feature,
        trigger_kind: "event_topic",
        # Same topic and event tuple as meetings.summarize; the payload is
        # `%{transcript_id, room_id, space_id}` (Platform.Meetings.PubSub).
        trigger_config: %{
          "topic" => "meeting:finished",
          "topic_pattern" => "meeting:finished:*",
          "event_match" => "meeting_finished"
        },
        scope: "per_meeting",
        context_provided: @context_provided,
        output_contract: %{"people" => "list[object]", "review" => "list[string]?"},
        default_prompt_template: @prompt_slug,
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.people", "feeds" => "memory.dreaming"}
      }
    ]
  end

  # ── gather_context ───────────────────────────────────────────────────────

  @impl true
  def gather_context(%Responsibility{key: key} = responsibility, ctx)
      when key in [@daily_key, @meeting_key] and is_map(ctx) do
    workspace_id = workspace_id(ctx)
    experiment = experiment_payload(workspace_id)
    now = fired_at(ctx)

    with {:ok, window, appearances} <- window_and_appearances(key, ctx, now, experiment) do
      if key == @daily_key, do: journal_started(responsibility, workspace_id, now)

      roster = Pages.roster(workspace_id)
      index_names = Pages.index_names(workspace_id)

      report =
        Staleness.compute(appearances, roster, index_names,
          staleness_days: experiment["staleness_days"],
          now: now,
          threshold: experiment["fuzzy_threshold"]
        )

      if appearances == [] and report.stale == [] and report.no_profile == [] do
        if key == @daily_key,
          do: journal_finished(responsibility, workspace_id, now, [], "nothing to curate")

        {:error, :nothing_to_curate}
      else
        subjects = subjects(report, roster, appearances)
        {window_start, window_end} = window
        own_words = Enum.map(subjects, &{&1, OwnWords.for_subject(&1, window_start, window_end)})

        {:ok,
         %{
           date: Date.to_iso8601(DateTime.to_date(now)),
           workspace_id: workspace_id || "(none — this is an org-wide fire)",
           org_identity: org_identity(workspace_id),
           people_roster: render_roster(roster),
           people_appearances: render_appearances(appearances),
           people_staleness: render_staleness(report),
           people_own_words: render_own_words(own_words),
           contract: Privacy.subject_reads_it_note(),
           page_grammar: @page_grammar,
           experiment_directive: HrProfile.render_directive(experiment) || ""
         }}
      end
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  defp window_and_appearances(@daily_key, _ctx, now, experiment) do
    window_start = DateTime.add(now, -experiment["staleness_days"] * 86_400, :second)
    {:ok, {window_start, now}, Appearances.collect(window_start, now)}
  end

  defp window_and_appearances(@meeting_key, ctx, now, _experiment) do
    payload = Map.get(ctx, :payload) || Map.get(ctx, "payload") || %{}
    transcript_id = Map.get(payload, :transcript_id) || Map.get(payload, "transcript_id")

    case transcript_id && Meetings.get_transcript(transcript_id) do
      %{} = transcript ->
        completed_at = transcript.completed_at || now
        started_at = transcript.started_at || transcript.inserted_at || completed_at
        # `completed_transcript_ids_between/3` is half-open on completed_at.
        window_end = DateTime.add(completed_at, 1, :second)

        appearances =
          transcript.id
          |> Meetings.participants_for_transcript()
          |> Enum.flat_map(&participant_appearance(&1, transcript))

        {:ok, {started_at, window_end}, appearances}

      _ ->
        {:error, :transcript_not_found}
    end
  end

  defp participant_appearance(%{display_name: name} = row, transcript)
       when is_binary(name) and name != "" do
    [
      %{
        raw_name: name,
        kind: if(row.agent_id, do: :agent, else: :human),
        user_id: row.user_id,
        agent_id: row.agent_id,
        source: :meeting_participant,
        space_id: row.space_id,
        meeting_id: row.meeting_id,
        project_id: row.project_id,
        task_id: nil,
        at: row.joined_at || transcript.completed_at,
        citation:
          if(row.meeting_id,
            do: "meeting:#{row.meeting_id}",
            else: "meeting:transcript:#{transcript.id}"
          )
      }
    ]
  end

  defp participant_appearance(_row, _transcript), do: []

  # One subject per resolved card plus one per name that matched nobody.
  # Ambiguous names are not subjects: nobody's words are attributed to them.
  defp subjects(report, roster, appearances) do
    by_slug = Map.new(roster, &{&1.slug, &1})

    resolved =
      Enum.map(report.resolved, fn %{slug: slug, name: name, appearances: apps} ->
        card = Map.get(by_slug, slug, %{})

        %{
          slug: slug,
          names: Enum.uniq([name | Map.get(card, :aliases, [])]),
          user_id: Map.get(card, :user_id) || first_user_id(apps)
        }
      end)

    new_people =
      Enum.map(report.no_profile, fn raw_name ->
        apps = Enum.filter(appearances, &(&1.raw_name == raw_name))
        %{slug: nil, names: [raw_name], user_id: first_user_id(apps)}
      end)

    resolved ++ new_people
  end

  defp first_user_id(apps),
    do: apps |> Enum.map(&Map.get(&1, :user_id)) |> Enum.find(&is_binary/1)

  # ── build_prompt ─────────────────────────────────────────────────────────

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns =
      context
      |> Map.delete(:__responsibility__)
      |> Map.new(fn
        {k, v} when is_binary(v) -> {k, v}
        {k, v} when is_number(v) or is_atom(v) -> {k, to_string(v)}
        {k, v} -> {k, inspect(v)}
      end)

    rendered =
      case PromptTemplates.render_template(@prompt_slug, assigns) do
        {:ok, body} -> {:ok, body}
        {:error, _} -> PromptTemplates.render_default(@prompt_slug, assigns)
      end

    case rendered do
      {:ok, body} ->
        {:ok,
         %{
           system:
             "You are HR for this organisation. You catalogue people; you never judge them. " <>
               "Follow the user turn exactly.",
           user: body
         }}

      {:error, reason} ->
        {:error, {:prompt_render_failed, reason}}
    end
  end

  # ── handle_output ────────────────────────────────────────────────────────

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    workspace_id = workspace_id(trigger_meta)
    updated_by = updated_by(trigger_meta)
    now = DateTime.utc_now()

    case parse_output(parsed) do
      {:ok, profiles, review} ->
        {written, ambiguous, dropped} = write_profiles(profiles, workspace_id, updated_by)

        if written != [] do
          case Pages.regenerate_index(workspace_id, updated_by) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("[hr] index regeneration failed: #{inspect(reason)}")
          end
        end

        review_lines = Enum.map(review, &to_string/1) ++ Enum.map(ambiguous, &ambiguous_line/1)
        if review_lines != [], do: journal_review(responsibility, workspace_id, now, review_lines)

        if responsibility.key == @daily_key,
          do: journal_finished(responsibility, workspace_id, now, written, nil)

        :telemetry.execute(
          [:platform, :people, :curated],
          %{
            written: length(written),
            ambiguous: length(ambiguous),
            review: length(review_lines),
            dropped_others_said: dropped
          },
          %{responsibility_key: responsibility.key, workspace_id: workspace_id}
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[hr] handler rejected output key=#{responsibility.key} reason=#{inspect(reason)}"
        )

        if responsibility.key == @daily_key,
          do: journal_finished(responsibility, workspace_id, now, [], "invalid output")

        {:error, reason}
    end
  end

  @impl true
  def handle_refusal(%Responsibility{key: @daily_key} = responsibility, refusal, trigger_meta)
      when is_map(trigger_meta) do
    journal_finished(
      responsibility,
      workspace_id(trigger_meta),
      DateTime.utc_now(),
      [],
      "refused: #{inspect(refusal)}"
    )

    :ok
  end

  def handle_refusal(%Responsibility{}, _refusal, _trigger_meta), do: :ok

  defp parse_output(parsed) when is_binary(parsed) do
    case Jason.decode(parsed) do
      {:ok, decoded} -> parse_output(decoded)
      {:error, _} -> {:error, :invalid_output_shape}
    end
  end

  defp parse_output(%{} = parsed) do
    people = Map.get(parsed, "people") || Map.get(parsed, :people)
    review = Map.get(parsed, "review") || Map.get(parsed, :review) || []

    if is_list(people) and Enum.all?(people, &is_map/1) do
      {:ok, Enum.map(people, &stringify_keys/1), List.wrap(review)}
    else
      {:error, :invalid_output_shape}
    end
  end

  defp parse_output(_), do: {:error, :invalid_output_shape}

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Resolve every profile against the roster (growing it as new slugs are
  # minted so a second spelling in the same output lands on the first slug),
  # merge profiles that resolve to one slug, write each once.
  defp write_profiles(profiles, workspace_id, updated_by) do
    roster = Pages.roster(workspace_id)

    {resolved, ambiguous, _roster} =
      Enum.reduce(profiles, {[], [], roster}, fn profile, {acc, amb, roster} ->
        name = profile_name(profile)

        case resolve_slug(profile, roster) do
          {:match, slug} ->
            {[{slug, profile} | acc], amb, roster}

          {:ambiguous, candidates} ->
            {acc, [%{name: name, candidates: candidates} | amb], roster}

          :unknown when name != "" ->
            slug = Identity.slug_for(name, Enum.map(roster, & &1.slug))
            entry = %{slug: slug, name: name, aliases: profile_aliases(profile), user_id: nil}
            {[{slug, profile} | acc], amb, [entry | roster]}

          :unknown ->
            {acc, amb, roster}
        end
      end)

    {written, dropped} =
      resolved
      |> Enum.reverse()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.reduce({[], 0}, fn {slug, group}, {paths, dropped} ->
        profile = group |> merge_profiles() |> Map.put("slug", slug)
        rendered = OutputGuard.render(profile)

        with {:ok, _card, _} <- Pages.write_card(workspace_id, slug, rendered.card, updated_by),
             {:ok, _private, _} <-
               Pages.write_private(workspace_id, slug, rendered.private, updated_by) do
          {paths ++ [Visibility.card_path(slug), Visibility.private_path(slug)],
           dropped + rendered.counts.dropped_others_said}
        else
          {:error, reason} ->
            Logger.warning("[hr] page write failed slug=#{slug} reason=#{inspect(reason)}")
            {paths, dropped + rendered.counts.dropped_others_said}
        end
      end)

    {written, Enum.reverse(ambiguous), dropped}
  end

  defp resolve_slug(profile, roster) do
    name = profile_name(profile)
    slug_hint = profile |> Map.get("slug") |> to_string_or_nil()

    case Identity.resolve(name, roster) do
      :unknown when is_binary(slug_hint) ->
        case Identity.resolve(String.replace(slug_hint, "-", " "), roster) do
          :unknown -> :unknown
          other -> other
        end

      other ->
        other
    end
  end

  defp merge_profiles([profile]), do: profile

  defp merge_profiles([first | rest]) do
    Enum.reduce(rest, first, fn profile, acc ->
      acc
      |> merge_list(profile, "aliases")
      |> merge_list(profile, "current_projects")
      |> merge_list(profile, "interactions")
      |> merge_list(profile, "perspectives")
      |> merge_list(profile, "agents")
    end)
  end

  defp merge_list(acc, profile, key) do
    merged = Enum.uniq(list(acc, key) ++ list(profile, key))
    if merged == [], do: acc, else: Map.put(acc, key, merged)
  end

  defp list(map, key) do
    case Map.get(map, key) do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp profile_name(profile) do
    (Map.get(profile, "name") || Map.get(profile, "slug") || "") |> to_string() |> String.trim()
  end

  defp profile_aliases(profile), do: profile |> list("aliases") |> Enum.map(&to_string/1)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp ambiguous_line(%{name: name, candidates: candidates}),
    do: "ambiguous: \"#{name}\" could be #{Enum.join(candidates, " or ")} — written nowhere"

  # ── journal rows ─────────────────────────────────────────────────────────

  defp journal_started(responsibility, workspace_id, now) do
    iso = DateTime.to_iso8601(now)

    append_journal(
      responsibility,
      workspace_id,
      now,
      "HR daily sweep started #{iso}",
      %{"phase" => "started", "started_at" => iso}
    )
  end

  defp journal_finished(responsibility, workspace_id, now, paths, note) do
    iso = DateTime.to_iso8601(now)
    updated = if paths == [], do: "none", else: Enum.join(paths, ", ")
    suffix = if note, do: " (#{note})", else: ""

    append_journal(
      responsibility,
      workspace_id,
      now,
      "HR daily sweep finished #{iso}: updated #{updated}#{suffix}",
      %{"phase" => "finished", "finished_at" => iso, "updated" => paths}
    )
  end

  defp journal_review(responsibility, workspace_id, now, lines) do
    append_journal(
      responsibility,
      workspace_id,
      now,
      "HR review #{DateTime.to_iso8601(now)}:\n" <> Enum.map_join(lines, "\n", &"- #{&1}"),
      %{"phase" => "review", "lines" => lines}
    )
  end

  defp append_journal(%Responsibility{key: key}, workspace_id, now, content, metadata) do
    attrs = %{
      content: content,
      date: DateTime.to_date(now),
      workspace_id: workspace_id,
      metadata:
        Map.merge(
          %{"source" => "responsibility:#{key}", "responsibility_key" => key},
          metadata
        )
    }

    case OrgContext.append_memory_entry(attrs) do
      {:ok, _entry} ->
        :ok

      {:error, changeset} ->
        Logger.warning("[hr] journal append failed: #{inspect(changeset.errors)}")
        :error
    end
  end

  # ── context pieces ───────────────────────────────────────────────────────

  defp experiment_payload(workspace_id) do
    subject = Subject.new(HrProfile.subject_type(), workspace_id || @nil_uuid)

    payload =
      case Surfaces.resolve(HrProfile.key(), HrProfile.target(), subject) do
        {:variant, _experiment, _slug, %{} = payload} -> payload
        {:default, %{} = payload} -> payload
        _ -> HrProfile.control()
      end

    Map.merge(HrProfile.control(), payload)
  rescue
    _ -> HrProfile.control()
  end

  defp org_identity(workspace_id) do
    opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    case ContextProviders.gather_context(:org_identity, opts) do
      {:ok, %{org_identity: %{content: content}}} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp render_roster([]), do: "(no person cards yet)"

  defp render_roster(roster) do
    Enum.map_join(roster, "\n", fn card ->
      aliases = if card.aliases == [], do: "", else: " aka #{Enum.join(card.aliases, ", ")}"
      role_org = [card.role, card.organisation] |> Enum.reject(&is_nil/1) |> Enum.join(" / ")
      legacy = if card.legacy, do: " [legacy card]", else: ""

      "- #{card.name}#{aliases} — slug #{card.slug}, #{card.relation}" <>
        if(role_org == "", do: "", else: ", #{role_org}") <>
        if(card.last_seen, do: ", last seen #{card.last_seen}", else: "") <> legacy
    end)
  end

  defp render_appearances([]), do: "(nobody appeared in the window)"

  defp render_appearances(appearances) do
    shown = Enum.take(appearances, @max_appearance_lines)

    lines =
      Enum.map(shown, fn a ->
        "- #{a.raw_name} [#{a.kind}] via #{a.source}#{at(a.at)} [cite: #{a.citation}]"
      end)

    rest = length(appearances) - length(shown)
    suffix = if rest > 0, do: ["- (#{rest} more appearances not shown)"], else: []
    Enum.join(lines ++ suffix, "\n")
  end

  defp render_staleness(report) do
    [
      section(
        "Resolved to a card",
        Enum.map(
          report.resolved,
          &"#{&1.name} (#{&1.slug}), #{length(&1.appearances)} appearance(s)"
        )
      ),
      section(
        "Stale cards",
        Enum.map(
          report.stale,
          &"#{&1.slug}: page updated #{iso(&1.page_updated_at)}, last seen #{iso(&1.last_seen_at)}"
        )
      ),
      section("No profile yet", report.no_profile),
      section(
        "Ambiguous — do not write, list under review",
        Enum.map(report.review, &"#{&1.raw_name}: #{Enum.join(&1.candidates, " or ")}")
      ),
      section("In the index but no card", report.index_only)
    ]
    |> Enum.join("\n")
  end

  defp render_own_words([]), do: "(no subjects)"

  defp render_own_words(pairs) do
    Enum.map_join(pairs, "\n\n", fn {subject, items} ->
      heading =
        "### #{hd(subject.names)}" <> if(subject.slug, do: " (#{subject.slug})", else: " (new)")

      body =
        case items do
          [] -> "- (nothing in their own words this window)"
          items -> Enum.map_join(items, "\n", &"- #{&1.text}#{at(&1.at)} [cite: #{&1.citation}]")
        end

      heading <> "\n" <> body
    end)
  end

  defp section(title, []), do: "#{title}: none"
  defp section(title, items), do: "#{title}:\n" <> Enum.map_join(items, "\n", &"- #{&1}")

  defp at(%DateTime{} = dt), do: " at #{DateTime.to_iso8601(dt)}"
  defp at(_), do: ""

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: "unknown"

  defp workspace_id(map) do
    case Map.get(map, :workspace_id) || Map.get(map, "workspace_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp fired_at(ctx) do
    case Map.get(ctx, :fired_at) || Map.get(ctx, "fired_at") do
      %DateTime{} = at -> at
      _ -> DateTime.utc_now()
    end
  end

  defp updated_by(meta) do
    [
      Map.get(meta, :agent_id),
      Map.get(meta, "agent_id"),
      Map.get(meta, :updated_by),
      Map.get(meta, "updated_by"),
      Map.get(meta, :assignee_id),
      Map.get(meta, "assignee_id")
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end
end
