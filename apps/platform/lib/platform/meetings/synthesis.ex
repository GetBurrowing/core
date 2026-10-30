defmodule Platform.Meetings.Synthesis do
  @moduledoc "Native, tool-free synthesis for a filed completion snapshot (task 01a16974)."
  import Ecto.Query
  require Logger
  alias Platform.{Repo, Meetings}
  alias Platform.Meetings.{Completion, CompletionRun, Meeting, SynthesisFindings}
  alias Platform.Meetings.Synthesis.{Context, Parser}
  alias Platform.Experiments.{Subject, Surfaces}
  alias Platform.Experiments.Surfaces.MeetingBriefSynthesis, as: Surface
  alias Platform.Orchestration.PromptTemplates
  @key "meetings.brief_synthesis"
  # Provider calls per meeting run (stage 6). Audiences beyond this share
  # one call over the sources all of them can read.
  @max_provider_calls 4

  def maybe_start(meeting_id) do
    case Repo.one(from(r in CompletionRun, where: r.meeting_id == ^meeting_id)) do
      %CompletionRun{status: "filed"} = run ->
        if run.synthesis["snapshot_hash"] == run.snapshot_hash and
             run.synthesis["status"] == "pending" do
          if Meetings.Config.summary().provider == :none do
            run(meeting_id, run.id, run.snapshot_hash)
          else
            case Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
                   try do
                     run(meeting_id, run.id, run.snapshot_hash)
                   rescue
                     # An async test can end its sandbox owner while this
                     # supervised child is starting or releasing the gate.
                     DBConnection.OwnershipError -> :ok
                   end
                 end) do
              {:ok, _pid} ->
                :ok

              {:error, _reason} ->
                Completion.synthesis_changed(meeting_id, run.id, run.snapshot_hash, "complete")
            end
          end
        end

      _ ->
        :ok
    end
  end

  def run(meeting_id, run_id, snapshot_hash) do
    if claim(meeting_id, run_id, snapshot_hash) do
      try do
        execute(meeting_id, run_id, snapshot_hash)
      rescue
        _error ->
          Logger.warning("Meeting synthesis failed; releasing briefing prerequisite")
          {:error, :synthesis_failed}
      catch
        _kind, _reason -> {:error, :synthesis_failed}
      after
        Completion.synthesis_changed(meeting_id, run_id, snapshot_hash, "complete")
      end
    else
      {:error, :stale_or_claimed}
    end
  end

  defp claim(meeting_id, run_id, hash) do
    Repo.transaction(fn ->
      case Repo.one(
             from(r in CompletionRun, where: r.meeting_id == ^meeting_id, lock: "FOR UPDATE")
           ) do
        %CompletionRun{id: ^run_id, status: "filed", snapshot_hash: ^hash} = r ->
          if r.synthesis["status"] == "pending" and r.synthesis["snapshot_hash"] == hash and
               r.synthesis["claimed"] != true do
            r
            |> Ecto.Changeset.change(synthesis: Map.put(r.synthesis, "claimed", true))
            |> Repo.update!()

            true
          else
            false
          end

        _ ->
          false
      end
    end) == {:ok, true}
  end

  defp execute(meeting_id, run_id, hash) do
    cfg = Meetings.Config.summary()

    with true <- cfg.provider != :none,
         {:ok, control} <- Surface.control_payload(@key, []),
         %Meeting{} = meeting <- Repo.one(from(m in Meeting, where: m.id == ^meeting_id)),
         project <-
           Repo.one!(from(p in Platform.Tasks.Project, where: p.id == ^meeting.project_id)),
         payload <- arm(meeting, project, control),
         {:ok, _, _} <- Platform.Meetings.MeetingBriefings.build(meeting),
         context <- Context.gather(meeting, lookback_days: payload["lookback_days"]),
         {:ok, calls} <- safe_audiences(meeting, context, payload["max_sources"]),
         true <- calls != [],
         {:ok, system} <- PromptTemplates.render_template("meetings.brief_synthesis.v1", %{}),
         {:ok, findings} <- call_audiences(cfg, payload, system, meeting, calls) do
      with {:ok, written} <- persist(meeting, run_id, hash, findings) do
        place_findings(written)
        {:ok, written}
      end
    else
      false -> {:ok, :skipped}
      {:error, _} = error -> error
      _ -> {:error, :invalid_context}
    end
  end

  # One provider call per audience. A finding's recipients are that call's
  # members (bounded again in persist/4), so every source in the prompt
  # that produced a finding is readable by every recipient. A call that
  # errors contributes nothing; only when every call errors is the run an
  # error.
  defp call_audiences(cfg, payload, system, meeting, calls) do
    results =
      Enum.map(calls, fn call ->
        case call_provider(cfg, payload, system, meeting.id, call.sources) do
          {:ok, text} ->
            {:ok,
             Parser.parse(text, call.sources, payload["min_confidence"])
             |> Enum.filter(&(meeting.id in &1.meeting_ids))
             |> Enum.map(&Map.merge(&1, %{members: call.members, prompt_refs: call.prompt_refs}))}

          {:error, _} = error ->
            error
        end
      end)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {[], [error | _]} -> error
      {ok, _} -> {:ok, Enum.flat_map(ok, fn {:ok, findings} -> findings end)}
    end
  end

  # Fail closed: if the audiences cannot be computed, no provider call is
  # made and the run completes with zero findings (run/3's `after`).
  defp safe_audiences(meeting, context, max_sources) do
    {:ok, audiences(meeting, context, max_sources)}
  rescue
    _error ->
      Logger.warning("Meeting synthesis could not group recipients; making no provider call")
      {:error, :audiences_unavailable}
  end

  @doc """
  The provider calls for one synthesis run (task 01a16974 stage 6), as
  `[%{members, sources, prompt_refs}]`.

  Invariant: every source in a call's prompt is readable by every member
  of that call, and a finding from a call is only ever delivered to (a
  subset of) its members.

  Candidate recipients are grouped by the EXACT set of gathered sources
  each can read (`reader_ids`, materialised by `Context.filter_sources/2`);
  candidates who can read nothing are dropped. One call per group, given
  only that group's set (origin-meeting sources first, then the rest,
  truncated to `max_sources`). Groups holding an attendee of `meeting` come
  first, then larger groups, then by source set, so the order is
  deterministic.

  At most `#{@max_provider_calls}` calls are made. When there are more
  groups than that, the first `#{@max_provider_calls - 1}` get their own call
  and every remaining candidate shares ONE call over the sources ALL of
  them can read (the intersection of their sets). It never widens: an
  empty intersection makes no call for them.

  `prompt_refs` are the sorted, unique `"kind:id"` refs of every prompt
  source plus each one's required refs; persist stores them on the finding.
  """
  @spec audiences(Meeting.t(), map(), pos_integer()) :: [
          %{members: [binary()], sources: [map()], prompt_refs: [String.t()]}
        ]
  def audiences(%Meeting{} = meeting, %{sources: sources} = context, max_sources)
      when is_integer(max_sources) and max_sources > 0 do
    indexed = Enum.with_index(sources)
    attendees = Meetings.human_attendee_ids(meeting)

    groups =
      context.candidate_recipient_ids
      |> Enum.uniq()
      |> Enum.group_by(fn user_id ->
        for {s, i} <- indexed, user_id in s.reader_ids, do: i
      end)
      |> Enum.reject(fn {set, _members} -> set == [] end)
      |> Enum.map(fn {set, members} -> {set, Enum.sort(members)} end)
      |> Enum.sort_by(fn {set, members} ->
        {not Enum.any?(members, &(&1 in attendees)), -length(members), set}
      end)

    {direct, overflow} =
      if length(groups) > @max_provider_calls,
        do: Enum.split(groups, @max_provider_calls - 1),
        else: {groups, []}

    common =
      case overflow do
        [] ->
          []

        [{first, _} | _] ->
          set =
            Enum.reduce(overflow, MapSet.new(first), fn {s, _}, acc ->
              MapSet.intersection(acc, MapSet.new(s))
            end)
            |> Enum.sort()

          [{set, overflow |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort()}]
      end

    (direct ++ common)
    |> Enum.reject(fn {set, _} -> set == [] end)
    |> Enum.flat_map(fn {set, members} ->
      by_index = MapSet.new(set)
      chosen = for {s, i} <- indexed, MapSet.member?(by_index, i), do: s
      {current, related} = Enum.split_with(chosen, &(meeting.id in &1.meeting_ids))

      case Enum.take(current ++ related, max_sources) do
        [] -> []
        prompt -> [%{members: members, sources: prompt, prompt_refs: prompt_refs(prompt)}]
      end
    end)
  end

  @doc "The maximum number of provider calls one synthesis run makes."
  @spec max_provider_calls() :: pos_integer()
  def max_provider_calls, do: @max_provider_calls

  defp prompt_refs(sources) do
    sources
    |> Enum.flat_map(fn s ->
      [Parser.ref(s) | Enum.map(Map.get(s, :required_refs, []), fn {k, id} -> "#{k}:#{id}" end)]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp arm(meeting, project, control) do
    subject =
      Subject.new("meeting", meeting.id, %{org_id: project.org_id, project_id: project.id})

    case Surfaces.resolve(@key, @key, subject, org_id: project.org_id) do
      {:variant, _experiment, _slug, payload} -> Map.merge(control, payload)
      {:default, payload} -> Map.merge(control, payload)
      :none -> control
    end
  end

  defp persist(meeting, run_id, hash, findings) do
    project = Repo.one!(from(p in Platform.Tasks.Project, where: p.id == ^meeting.project_id))
    # The completion fence and writes share a transaction. Reopened meetings
    # and changed snapshots cannot receive a late model response.
    Repo.transaction(fn ->
      run = Repo.one!(from(r in CompletionRun, where: r.id == ^run_id, lock: "FOR UPDATE"))
      current = Repo.one!(from(m in Meeting, where: m.id == ^meeting.id, lock: "FOR UPDATE"))

      with true <-
             current.status == "ended" and run.snapshot_hash == hash and run.status == "filed",
           {:ok, snap, _} <- Completion.snapshot(current),
           true <- Completion.snapshot_hash(run, snap) == hash do
        Enum.flat_map(findings, fn finding ->
          named = Repo.all(from(m in Meeting, where: m.id in ^finding.meeting_ids))

          # The call's members bound the recipients: they are exactly the
          # people who can read every source in the prompt behind the body.
          recipients =
            Context.recipients_for(finding.citations, named)
            |> Enum.filter(&(&1 in finding.members))

          if recipients == [] do
            []
          else
            # Sources sharing a ref may carry different dependency checks;
            # the stored citation keeps the union, so the render-time
            # re-check (MeetingBriefings.view/2) is as strict as gathering.
            citations =
              finding.citations
              |> Enum.group_by(&Parser.ref/1)
              |> Enum.map(fn {ref, [s | _] = group} ->
                {kind, _id} = s.ref

                requires =
                  group
                  |> Enum.flat_map(&Map.get(&1, :required_refs, []))
                  |> Enum.map(fn {k, id} -> "#{k}:#{id}" end)
                  |> Enum.uniq()

                %{
                  "source_kind" => to_string(kind),
                  "ref" => ref,
                  "title" => String.slice(s.text, 0, 200),
                  "requires" => requires
                }
              end)
              |> Enum.sort_by(fn c ->
                Enum.find_index(finding.citations, &(Parser.ref(&1) == c["ref"]))
              end)

            attrs = %{
              org_id: project.org_id,
              origin_meeting_id: meeting.id,
              meeting_ids: finding.meeting_ids,
              kind: finding.kind,
              confidence: finding.confidence,
              body: finding.body,
              citations: citations,
              recipient_user_ids: recipients,
              prompt_refs: finding.prompt_refs,
              run_id: run_id,
              snapshot_hash: hash
            }

            case SynthesisFindings.upsert(attrs) do
              {:ok, f, _} -> [f]
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        end)
        # Two audiences can produce the same finding (one dedupe key); the
        # second upsert merged into the first row. Keep its latest version.
        |> Enum.reverse()
        |> Enum.uniq_by(& &1.id)
        |> Enum.reverse()
      else
        _ -> Repo.rollback(:stale_snapshot)
      end
    end)
  end

  @doc """
  Stage 4 placement: every finding becomes a `"finding"` item in the
  briefing of EVERY meeting in its `meeting_ids`
  (`MeetingBriefings.add_finding/2`). Synthesis files nothing; this only
  adds briefing items. Each touched meeting is then re-delivered through
  `MeetingBriefings.deliver/2`'s Inbox upsert with the new keys, so only a
  person who can SEE a new item has their row relisted, and the row count
  is their own. `deliver/2` pushes only on a CREATED Inbox row, so anyone
  who already had a meeting's brief gets no second push (the
  `Triage.refresh_meeting_briefing/1` rule). The origin meeting is still
  gated on synthesis when this runs, so its deliver waits for
  `Completion.synthesis_changed/4`, unless its deadline already passed.
  Must run outside a transaction (deliver answers `:pending` inside one).
  """
  @spec place_findings([Platform.Meetings.SynthesisFinding.t()]) :: :ok
  def place_findings(findings) when is_list(findings) do
    findings
    |> Enum.flat_map(fn finding ->
      Enum.flat_map(finding.meeting_ids || [], fn meeting_id ->
        case Platform.Meetings.MeetingBriefings.add_finding(meeting_id, finding) do
          {:ok, _briefing, %{new_keys: keys}} -> [{meeting_id, keys}]
          {:error, _} -> []
        end
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {meeting_id, keys} ->
      Platform.Meetings.MeetingBriefings.deliver(%Meeting{id: meeting_id},
        new_keys: List.flatten(keys)
      )
    end)
  end

  defp call_provider(cfg, payload, system, meeting_id, sources) do
    provider = Platform.Chat.ContextSummary.Config.parse_provider(payload["provider"])
    adapter = Application.get_env(:platform, :meeting_synthesis_provider) || adapter(provider)
    same? = provider == cfg.provider
    env = if same?, do: cfg.api_key_env

    credentials =
      if env && System.get_env(env),
        do: %{api_key: System.get_env(env)},
        else: if(provider == :ollama, do: %{}, else: %{credential_slug: to_string(provider)})

    opts =
      [
        system: Enum.join([system, payload["system_prompt"] || ""], "\n"),
        model: payload["model"],
        max_tokens: cfg.max_tokens,
        temperature: cfg.temperature,
        base_url: if(same?, do: cfg.base_url)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    data =
      Enum.map(sources, fn s ->
        %{ref: Parser.ref(s), meeting_ids: s.meeting_ids, text: s.text}
      end)

    case adapter.chat(
           credentials,
           [%{role: "user", content: Jason.encode!(%{meeting_id: meeting_id, sources: data})}],
           opts
         ) do
      {:ok, %{content: text}} when is_binary(text) -> {:ok, text}
      {:ok, %{content: [%{"text" => text} | _]}} -> {:ok, text}
      {:ok, %{"content" => [%{"text" => text} | _]}} -> {:ok, text}
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp adapter(:anthropic), do: Platform.Agents.Providers.Anthropic
  defp adapter(:openai), do: Platform.Agents.Providers.OpenAI
  defp adapter(:ollama), do: Platform.Agents.Providers.Ollama
end
