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
         sources <- Enum.take(context.sources, payload["max_sources"]),
         true <- sources != [],
         {:ok, system} <- PromptTemplates.render_template("meetings.brief_synthesis.v1", %{}),
         {:ok, text} <- call_provider(cfg, payload, system, meeting.id, sources) do
      findings =
        Parser.parse(text, sources, payload["min_confidence"])
        |> Enum.filter(&(meeting.id in &1.meeting_ids))

      persist(meeting, run_id, hash, findings)
    else
      false -> {:ok, :skipped}
      {:error, _} = error -> error
      _ -> {:error, :invalid_context}
    end
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
          recipients = Context.recipients_for(finding.citations, named)

          if recipients == [] do
            []
          else
            citations =
              Enum.uniq_by(finding.citations, &Parser.ref/1)
              |> Enum.map(fn s ->
                {kind, _id} = s.ref

                %{
                  "source_kind" => to_string(kind),
                  "ref" => Parser.ref(s),
                  "title" => String.slice(s.text, 0, 200)
                }
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
              run_id: run_id,
              snapshot_hash: hash
            }

            case SynthesisFindings.upsert(attrs) do
              {:ok, f, _} -> [f]
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        end)
      else
        _ -> Repo.rollback(:stale_snapshot)
      end
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
