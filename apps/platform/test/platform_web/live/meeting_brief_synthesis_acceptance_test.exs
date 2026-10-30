defmodule PlatformWeb.MeetingBriefSynthesisAcceptanceTest do
  @moduledoc """
  End-to-end acceptance for meeting brief synthesis (task 01a16974),
  adopted from the stage 6 behavioural reviewer's driver as a regression
  test for the case-2 leak (a finding citing only a readable source whose
  body describes an uncited source one recipient cannot read).

  Drives the REAL completion pipeline (transcript -> end_meeting ->
  capture fence -> summary -> scribe_complete -> triage_file -> native
  synthesis handler -> deliver) with only the model provider stubbed via
  `:meeting_synthesis_provider`, then reads the Inbox through the real
  LiveViews and `MeetingBriefings.view/2` / `act/5`.

  Set `E2E_OBS=1` to print every observation with an `E2E|` prefix.

  Case 2's stub provider only writes about the Pricing council note when
  that note is in its prompt: a model cannot describe a source it was
  never shown. Since stage 6 each audience gets its own call, so J's call
  never contains the note.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.{Chat, Federation, Meetings, Repo, Roles, Tasks}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Inbox.Item

  alias Platform.Meetings.{
    Completion,
    CompletionRun,
    Meeting,
    MeetingBriefing,
    MeetingBriefings,
    MeetingCandidate,
    Participant,
    Room,
    SynthesisFinding,
    SynthesisFindings,
    Transcript
  }

  defmodule Pushes do
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, n) do
      send(:persistent_term.get({__MODULE__, :owner}), {:push, user_id, n.url, n.title, n.body})
      :ok
    end
  end

  defmodule StubProvider do
    def chat(_creds, [%{content: content}], _opts) do
      payload = Jason.decode!(content)
      owner = Application.fetch_env!(:platform, :e2e_synth_owner)
      send(owner, {:provider_called, payload["meeting_id"], payload["sources"]})
      fun = Application.fetch_env!(:platform, :e2e_synth_fun)
      {:ok, %{content: fun.(payload)}}
    end
  end

  defp obs(label, value) do
    if System.get_env("E2E_OBS"), do: obs!(label, value)
  end

  defp obs!(label, value),
    do:
      IO.puts(
        "E2E|" <> label <> "|" <> inspect(value, limit: :infinity, printable_limit: :infinity)
      )

  setup do
    keys = [
      :meetings_summary,
      :meeting_synthesis_provider,
      :e2e_synth_owner,
      :e2e_synth_fun,
      :notifications_module
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    on_exit(fn ->
      Enum.each(old, fn
        {k, {:ok, v}} -> Application.put_env(:platform, k, v)
        {k, :error} -> Application.delete_env(:platform, k)
      end)

      :persistent_term.erase({Pushes, :owner})
    end)

    Application.put_env(:platform, :meetings_summary, %{provider: :openai})
    Application.put_env(:platform, :meeting_synthesis_provider, StubProvider)
    Application.put_env(:platform, :e2e_synth_owner, self())
    Application.put_env(:platform, :e2e_synth_fun, fn _ -> "" end)
    Application.put_env(:platform, :notifications_module, Pushes)
    Pushes.install(self())
    Platform.Orchestration.PromptTemplates.seed_defaults()

    n = System.unique_integer([:positive])

    {:ok, project} =
      Tasks.create_project(%{
        name: "E2E synthesis #{n}",
        org_id: acme_org_id(),
        repo_url: "https://github.com/test/e2e-synthesis"
      })

    %{
      project: project,
      scribe: role_agent!("meeting_scribe"),
      triage: role_agent!("triage_officer")
    }
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp role_agent!(role) do
    n = System.unique_integer([:positive])
    agent = Repo.insert!(%Agent{slug: "e2e-#{role}-#{n}", name: role, status: "active"})

    owner =
      Repo.insert!(%User{
        email: "e2e-owner-#{n}@example.com",
        oidc_sub: "e2e-owner-#{n}",
        name: "Owner"
      })

    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "e2e-#{n}"})
    {:ok, _} = Federation.link_agent(runtime, agent)
    :ok = Roles.unassign_role(role)
    {:ok, _} = Roles.assign_role(role, agent.id)
    agent
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "e2e-#{String.downcase(name)}-#{n}@example.com",
        oidc_sub: "e2e-#{name}-#{n}",
        name: "#{name} #{n}"
      })

    Repo.insert!(
      Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
        user_id: user.id,
        org_id: acme_org_id(),
        role: "member"
      })
    )

    user
  end

  defp join!(space_id, user) do
    unless Chat.participant?(space_id, user.id) do
      {:ok, _} =
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    :ok
  end

  # A live meeting started `ago` seconds ago, attended (room participants) by `attendees`.
  defp live_meeting!(project, name, attendees, ago \\ 3600) do
    started = DateTime.add(DateTime.utc_now(), -ago, :second)
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: started}) |> Repo.update()

    room =
      %Room{}
      |> Room.changeset(%{space_id: live.chat_space_id, livekit_room_name: "e2e-#{live.id}"})
      |> Repo.insert!()

    for u <- attendees do
      %Participant{}
      |> Participant.changeset(%{
        room_id: room.id,
        user_id: u.id,
        display_name: u.name,
        joined_at: DateTime.add(started, 60, :second)
      })
      |> Repo.insert!()
    end

    live
  end

  defp canvas!(space_id, agent, ids) do
    {:ok, participant} = Chat.add_agent_participant(space_id, agent.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space_id,
        "created_by" => participant.id,
        "title" => "Final meeting actions"
      })

    document = %{
      "type" => "stack",
      "children" => Enum.map(ids, &%{"type" => "checklist_item", "id" => &1, "label" => &1})
    }

    canvas |> Ecto.Changeset.change(document: document) |> Repo.update!()
  end

  # Runs the real completion pipeline. `actions` are accepted action
  # candidates; each is filed by triage as a task (candidate_ids preserved).
  # Returns timings and ids.
  defp complete!(ctx, live, speech, actions, opts \\ []) do
    seg = %{"id" => Ecto.UUID.generate(), "text" => speech, "start_time" => 1}

    transcript =
      Repo.insert!(%Transcript{
        space_id: live.chat_space_id,
        meeting_id: live.id,
        room_id: live.livekit_room_name,
        started_at: DateTime.add(live.started_at, 120, :second),
        segments: [seg],
        status: "processing"
      })

    candidates =
      for text <- actions do
        Repo.insert!(%MeetingCandidate{
          meeting_id: live.id,
          state: :closed,
          closed_reason: :done,
          disposition: :accepted,
          classified_intent: "action_items",
          evidence_quote: text
        })
      end

    {:ok, ended} = Meetings.end_meeting(live)
    Completion.capture_finished_for_space(live.chat_space_id)
    input = Meetings.get_transcript(transcript.id)

    {:ok, _} =
      Meetings.complete_transcript(
        transcript.id,
        Keyword.get(opts, :summary, speech),
        Transcript.summary_fingerprint(input)
      )

    run = Repo.get_by!(CompletionRun, meeting_id: live.id)
    ids = Enum.with_index(candidates, fn _c, i -> "item-#{i}" end)
    canvas = canvas!(ended.chat_space_id, ctx.scribe, ids)

    args = %{
      "meeting_id" => live.id,
      "run_id" => run.id,
      "transcript_id" => run.transcript_id,
      "canvas_id" => canvas.id,
      "snapshot_hash" => run.snapshot_hash
    }

    {:ok, _} = Completion.scribe_complete(ctx.scribe.id, args)
    after_scribe = Repo.get!(CompletionRun, run.id)
    readiness_after_scribe = MeetingBriefings.readiness(Repo.get!(Meeting, live.id))

    titles = Keyword.get(opts, :titles, actions)

    items =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        %{
          "item_id" => "item-#{i}",
          "candidate_ids" => [c.id],
          "title" => Enum.at(titles, i),
          "description" => c.evidence_quote,
          "source_segment_ids" => [seg["id"]]
        }
      end)

    tasks_before_triage = Repo.aggregate(Platform.Tasks.Task, :count)
    triage_at = DateTime.utc_now()
    {:ok, filed} = Completion.triage_file(ctx.triage.id, Map.put(args, "action_items", items))
    triage_returned_at = DateTime.utc_now()
    tasks_after_triage = Repo.aggregate(Platform.Tasks.Task, :count)

    synth = wait_synthesis!(live.id)
    synthesis_done_at = DateTime.utc_now()

    %{
      meeting: Repo.get!(Meeting, live.id),
      run: Repo.get!(CompletionRun, run.id),
      synthesis_after_scribe: after_scribe.synthesis,
      readiness_after_scribe: readiness_after_scribe,
      filed: filed,
      candidates: candidates,
      triage_at: triage_at,
      triage_returned_at: triage_returned_at,
      synthesis_done_at: synthesis_done_at,
      synth: synth,
      tasks_before_triage: tasks_before_triage,
      tasks_after_triage: tasks_after_triage
    }
  end

  defp wait_synthesis!(meeting_id, tries \\ 200) do
    run = Repo.get_by!(CompletionRun, meeting_id: meeting_id)

    cond do
      run.synthesis["status"] == "complete" and
          run.synthesis["snapshot_hash"] == run.snapshot_hash ->
        # Let the synthesis child finish its trailing refresh_briefing/deliver.
        Process.sleep(400)
        Repo.get_by!(CompletionRun, meeting_id: meeting_id).synthesis

      tries == 0 ->
        flunk("synthesis never completed: #{inspect(run.synthesis)} status=#{run.status}")

      true ->
        Process.sleep(50)
        wait_synthesis!(meeting_id, tries - 1)
    end
  end

  defp briefing(meeting), do: Repo.get_by!(MeetingBriefing, meeting_id: meeting.id)
  defp scope(user), do: Scope.for_user(Repo.get!(User, user.id))
  defp auth(conn, user), do: init_test_session(conn, current_user_id: user.id)
  defp detail(meeting), do: "/inbox/meeting/" <> meeting.id

  defp inbox_row(user, meeting) do
    Repo.one(
      from(i in Item,
        where:
          i.user_id == ^user.id and i.kind == "meeting_briefing" and
            i.url == ^("/inbox/meeting/" <> meeting.id)
      )
    )
  end

  defp finding_items(briefing),
    do: for({k, %{"kind" => "finding"} = v} <- briefing.items || %{}, do: {k, v})

  defp drain(tag, acc \\ []) do
    receive do
      msg when elem(msg, 0) == tag -> drain(tag, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pushes(acc \\ []) do
    receive do
      {:push, uid, url, title, body} ->
        pushes([%{user: uid, url: url, title: title, body: body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_messages(space_id),
    do: Repo.aggregate(from(m in Chat.Message, where: m.space_id == ^space_id), :count)

  defp ref_for(sources, text) do
    case Enum.find(
           sources,
           &(&1["text"] =~ text and not String.starts_with?(&1["ref"], "meeting_briefing:"))
         ) do
      nil -> nil
      s -> s["ref"]
    end
  end

  defp card(key), do: ~s([data-role="meeting-briefing-card"][data-key="#{key}"])
  defp resolved(key), do: ~s([data-role="meeting-briefing-resolved-card"][data-key="#{key}"])

  defp strip(html),
    do: html |> String.replace(~r/<[^>]+>/, "") |> String.replace(~r/\s+/, " ") |> String.trim()

  # ── Case 1 ──────────────────────────────────────────────────────────────

  test "case 1: one alignment item in both briefings, resolved once for everyone",
       %{conn: conn} = ctx do
    [r, j, c, k] = for n <- ~w(R J C K), do: user!(n)

    # The provider emits the conflict only when both sides are in its context.
    Application.put_env(:platform, :e2e_synth_fun, fn payload ->
      a = ref_for(payload["sources"], "Drop Stripe; move billing to Paddle")
      b = ref_for(payload["sources"], "Ship billing on Stripe by Friday")

      if a && b do
        ~s(<meeting-finding kind="conflicts_with" confidence="high">Meeting A drops Stripe for Paddle; meeting B ships billing on Stripe by Friday.<cite ref="#{a}"/><cite ref="#{b}"/></meeting-finding>)
      else
        ""
      end
    end)

    # Meeting B: started two days ago, ends, completes, then its end is set to yesterday.
    b_live = live_meeting!(ctx.project, "Billing sync B", [c, k], 2 * 86_400)
    a_live = live_meeting!(ctx.project, "Billing sync A", [r, j])
    for u <- [r, j, c, k], m <- [a_live, b_live], do: join!(m.chat_space_id, u)

    b =
      complete!(ctx, b_live, "We will ship billing on Stripe by Friday.", [
        "Ship billing on Stripe by Friday"
      ])

    Repo.update!(
      Ecto.Changeset.change(b.meeting,
        ended_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
      )
    )

    b_meeting = Repo.get!(Meeting, b_live.id)
    obs("c1.b.synthesis", b.synth)
    obs("c1.b.findings_after_b", length(SynthesisFindings.list_for_meeting(b_meeting.id)))
    pushes_b = pushes()
    obs("c1.pushes_after_b", Enum.map(pushes_b, &{name_of(&1.user, [r, j, c, k]), &1.url}))

    a =
      complete!(ctx, a_live, "Decision: drop Stripe; move billing to Paddle.", [
        "Drop Stripe; move billing to Paddle"
      ])

    a_meeting = a.meeting
    obs("c1.a.synthesis", a.synth)
    obs("c1.a.filed_task_ids", a.filed)
    pushes_a = pushes()

    obs(
      "c1.pushes_after_a",
      Enum.map(pushes_a, &{name_of(&1.user, [r, j, c, k]), &1.url, &1.body})
    )

    findings =
      Repo.all(
        from(f in SynthesisFinding,
          where:
            f.origin_meeting_id in ^[a_meeting.id, b_meeting.id] or
              fragment(
                "? && ?",
                f.meeting_ids,
                type(^[a_meeting.id, b_meeting.id], {:array, :binary_id})
              )
        )
      )

    obs(
      "c1.finding_rows",
      Enum.map(
        findings,
        &Map.take(&1, [:id, :kind, :meeting_ids, :citations, :recipient_user_ids, :receipt])
      )
    )

    assert [finding] = findings
    {key, _} = SynthesisFindings.item(finding)

    for {label, m} <- [{"A", a_meeting}, {"B", b_meeting}] do
      items = finding_items(briefing(m))
      obs("c1.briefing_#{label}.finding_items", items)
      assert [{^key, %{"ref" => ref}}] = items
      assert ref == "finding:" <> finding.id
    end

    titles = Enum.map(finding.citations, & &1["title"])
    obs("c1.citation_titles", titles)
    assert Enum.any?(titles, &(&1 =~ "Drop Stripe; move billing to Paddle"))
    assert Enum.any?(titles, &(&1 =~ "Ship billing on Stripe by Friday"))

    # Open the Inbox as R (A) and C (B); J's tab is opened before C's click.
    {:ok, r_lv, _} = live(auth(conn, r), detail(a_meeting))
    {:ok, j_lv, _} = live(auth(conn, j), detail(a_meeting))
    {:ok, k_lv, _} = live(auth(conn, k), detail(b_meeting))
    {:ok, c_lv, _} = live(auth(conn, c), detail(b_meeting))

    for {n, lv} <- [{"R", r_lv}, {"J", j_lv}, {"K", k_lv}, {"C", c_lv}] do
      obs(
        "c1.before.#{n}.open_card_present",
        has_element?(lv, card(key) <> ~s( [data-action="align"]))
      )
    end

    assert has_element?(c_lv, card(key) <> ~s( [data-action="align"]))

    msgs_before =
      {count_messages(a_meeting.chat_space_id), count_messages(b_meeting.chat_space_id)}

    c_lv |> element(card(key) <> ~s( [data-action="align"])) |> render_click()

    after_c = Repo.get!(SynthesisFinding, finding.id)

    msgs_after =
      {count_messages(a_meeting.chat_space_id), count_messages(b_meeting.chat_space_id)}

    obs("c1.receipt_after_C", after_c.receipt)
    obs("c1.messages_before_after_C", {msgs_before, msgs_after})
    assert after_c.receipt["verb"] == "aligned"
    assert after_c.receipt["by"] == c.id
    assert msgs_after == {elem(msgs_before, 0) + 1, elem(msgs_before, 1) + 1}
    obs("c1.briefing_receipts_maps", {briefing(a_meeting).receipts, briefing(b_meeting).receipts})

    # J's stale click: the act event a pre-click tab would send.
    j_lv
    |> with_target("#meeting-briefing-#{a_meeting.id}")
    |> render_click("act", %{"key" => key, "verb" => "confirm"})

    j_notice =
      if has_element?(j_lv, ~s([data-role="meeting-briefing-notice"])),
        do: j_lv |> element(~s([data-role="meeting-briefing-notice"])) |> render() |> strip()

    obs("c1.J.stale_notice", j_notice)
    after_j = Repo.get!(SynthesisFinding, finding.id)

    msgs_after_j =
      {count_messages(a_meeting.chat_space_id), count_messages(b_meeting.chat_space_id)}

    obs("c1.receipt_after_J", after_j.receipt)
    obs("c1.messages_after_J", msgs_after_j)
    assert after_j.receipt == after_c.receipt
    assert msgs_after_j == msgs_after
    assert j_notice == "Already handled by " <> c.name

    # Direct act from J too: refused as already resolved.
    direct =
      MeetingBriefings.act(
        MeetingBriefings.get_for_attendee(a_meeting.id, j.id),
        key,
        :confirm,
        scope(j),
        %{}
      )

    obs("c1.J.direct_act", elem(direct, 0) == :error && Tuple.delete_at(direct, 2))
    assert match?({:error, :already_resolved, _}, direct)

    for {n, lv} <- [{"R", r_lv}, {"J", j_lv}, {"K", k_lv}, {"C", c_lv}] do
      Platform.AsyncAssertions.assert_eventually(fn -> has_element?(lv, resolved(key)) end)

      lead =
        lv
        |> element(resolved(key) <> ~s( [data-role="meeting-briefing-receipt-lead"]))
        |> render()
        |> strip()

      obs("c1.after.#{n}.receipt_lead", lead)
      assert lead == "Aligned by " <> c.name
      refute has_element?(lv, card(key))
    end

    # view/2 for each person
    for {n, u, m} <- [
          {"R", r, a_meeting},
          {"J", j, a_meeting},
          {"K", k, b_meeting},
          {"C", c, b_meeting}
        ] do
      v = MeetingBriefings.view(MeetingBriefings.get_for_attendee(m.id, u.id), scope(u))
      entry = Enum.find(v.resolved, &(&1.key == key))
      obs("c1.view.#{n}", entry && {entry.receipt.verb, entry.receipt.by_name})
      assert entry && entry.receipt.verb == "aligned"
    end

    late_pushes = pushes()

    obs(
      "c1.pushes_after_clicks",
      Enum.map(late_pushes, &{name_of(&1.user, [r, j, c, k]), &1.url})
    )

    b_url = "/inbox/meeting/" <> b_meeting.id
    all = pushes_b ++ pushes_a ++ late_pushes

    for u <- [c, k] do
      n = Enum.count(all, &(&1.user == u.id and &1.url == b_url))
      obs("c1.pushes_for_B.#{name_of(u.id, [r, j, c, k])}", n)
      assert n == 1
    end
  end

  defp name_of(id, users),
    do: Enum.find_value(users, id, &(&1.id == id && hd(String.split(&1.name))))

  # ── Case 2 ──────────────────────────────────────────────────────────────

  for variant <- [:no_cite, :cites_only_a_item] do
    # Read from the context, not unquoted, so the type checker does not
    # flag the other variant's branch as unreachable.
    @tag variant: variant
    test "case 2 (#{variant}): a source J cannot read never appears in J's view",
         %{conn: conn} = ctx do
      variant = ctx.variant
      r = user!("R")
      j = user!("J")

      # P: the chat space of another (ended) meeting, which only R reads.
      p_live = live_meeting!(ctx.project, "Pricing council", [], 7200)
      {:ok, p_meeting} = Meetings.end_meeting(p_live)
      join!(p_meeting.chat_space_id, r)
      p_space = Chat.get_space(p_meeting.chat_space_id)
      p_part = Repo.get_by!(Chat.Participant, space_id: p_space.id, participant_id: r.id)
      p_text = "Decision thread: billing stays on Stripe"

      p_msg =
        Repo.insert!(%Chat.Message{
          space_id: p_space.id,
          participant_id: p_part.id,
          content: p_text
        })

      obs("c2.#{variant}.P", %{
        space_name: p_space.name,
        slug: p_space.slug,
        j_participant?: Chat.participant?(p_space.id, j.id)
      })

      Application.put_env(:platform, :e2e_synth_fun, fn payload ->
        a = ref_for(payload["sources"], "move billing to Paddle")

        p =
          Enum.find_value(payload["sources"], &(&1["ref"] == "message:" <> p_msg.id && &1["ref"]))

        send(Application.fetch_env!(:platform, :e2e_synth_owner), {:refs, a, p})

        second =
          case variant do
            _ when is_nil(p) ->
              ""

            :no_cite ->
              ~s(<meeting-finding kind="contradicts" confidence="high">This contradicts the "#{p_text}" in #{p_space.name}.</meeting-finding>)

            :cites_only_a_item ->
              ~s(<meeting-finding kind="contradicts" confidence="high">This contradicts the "#{p_text}" in #{p_space.name}.<cite ref="#{a}"/></meeting-finding>)
          end

        first =
          if p,
            do:
              ~s(<meeting-finding kind="conflicts_with" confidence="high">Paddle move conflicts with the Stripe decision.<cite ref="#{a}"/><cite ref="#{p}"/></meeting-finding>),
            else: ""

        first <> second
      end)

      a_live = live_meeting!(ctx.project, "Billing review", [r, j])
      for u <- [r, j], do: join!(a_live.chat_space_id, u)

      a =
        complete!(ctx, a_live, "We agreed to move billing to Paddle.", ["move billing to Paddle"])

      refs_seen = for {:refs, ar, pr} <- drain(:refs), do: {ar, pr}
      calls_seen = drain(:provider_called)
      # One call per audience: R's (reads P) and J's (does not).
      assert length(calls_seen) == 2
      assert Enum.count(refs_seen, fn {_, pr} -> pr end) == 1
      {a_ref, p_ref} = Enum.find(refs_seen, fn {_, pr} -> pr end)
      obs("c2.#{variant}.refs_in_context", {a_ref, p_ref})

      obs(
        "c2.#{variant}.provider_saw_P",
        Enum.map(calls_seen, fn {:provider_called, _, sources} ->
          Enum.any?(sources, &(&1["text"] =~ "billing stays on Stripe"))
        end)
      )

      rows = SynthesisFindings.list_for_meeting(a.meeting.id)

      obs(
        "c2.#{variant}.finding_rows",
        Enum.map(rows, &Map.take(&1, [:kind, :body, :citations, :recipient_user_ids]))
      )

      obs(
        "c2.#{variant}.recipient_names",
        Enum.map(rows, fn f -> Enum.map(f.recipient_user_ids, &name_of(&1, [r, j])) end)
      )

      b = briefing(a.meeting)
      obs("c2.#{variant}.briefing_finding_items", finding_items(b))

      # R: positive control.
      r_view =
        MeetingBriefings.view(MeetingBriefings.get_for_attendee(a.meeting.id, r.id), scope(r))

      r_findings = Enum.filter(r_view.open ++ r_view.resolved, &(&1.kind == "finding"))

      obs(
        "c2.#{variant}.R.view_findings",
        Enum.map(
          r_findings,
          &{&1.finding.kind, &1.finding.body, Enum.map(&1.finding.citations, fn c -> c.title end)}
        )
      )

      obs("c2.#{variant}.R.counts", r_view.counts)
      {:ok, r_lv, r_html} = live(auth(conn, r), detail(a.meeting))
      r_all = r_html <> render(r_lv)
      {:ok, r_list, r_list_html} = live(auth(conn, r), "/inbox?f=briefing")
      r_all = r_all <> r_list_html <> render(r_list)
      r_row = inbox_row(r, a.meeting)
      obs("c2.#{variant}.R.row_body", r_row && r_row.body)
      obs("c2.#{variant}.R.html_contains_P_text", String.contains?(r_all, p_text))

      obs(
        "c2.#{variant}.R.html_contains_P_slug",
        String.contains?(r_all, "/chat/" <> p_space.slug)
      )

      # J.
      j_briefing = MeetingBriefings.get_for_attendee(a.meeting.id, j.id)
      j_view = MeetingBriefings.view(j_briefing, scope(j))
      j_findings = Enum.filter(j_view.open ++ j_view.resolved, &(&1.kind == "finding"))

      obs(
        "c2.#{variant}.J.view_findings",
        Enum.map(
          j_findings,
          &{&1.finding.kind, &1.finding.body, Enum.map(&1.finding.citations, fn c -> c.title end)}
        )
      )

      obs("c2.#{variant}.J.counts", j_view.counts)
      {:ok, j_lv, j_html} = live(auth(conn, j), detail(a.meeting))
      {:ok, j_list, j_list_html} = live(auth(conn, j), "/inbox?f=briefing")
      j_all = j_html <> render(j_lv) <> j_list_html <> render(j_list)
      j_row = inbox_row(j, a.meeting)
      obs("c2.#{variant}.J.row", j_row && Map.take(j_row, [:title, :body, :url]))
      j_pushes = Enum.filter(pushes(), &(&1.user == j.id))
      obs("c2.#{variant}.J.pushes", j_pushes)

      j_corpus =
        j_all <>
          inspect(Map.from_struct(j_row)) <>
          inspect(j_pushes) <> inspect(j_view, limit: :infinity, printable_limit: :infinity)

      needles =
        [p_text, "billing stays on Stripe", "Stripe", p_space.name, p_space.slug, p_msg.id]
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))

      hits = for n <- needles, String.contains?(j_corpus, n), do: n
      r_corpus = r_all <> inspect(r_view, limit: :infinity, printable_limit: :infinity)
      r_hits = for n <- needles, String.contains?(r_corpus, n), do: n
      obs("c2.#{variant}.J.needle_hits", hits)
      obs("c2.#{variant}.R.needle_hits(positive control)", r_hits)

      # J direct act on every finding key in A's briefing.
      for {fkey, _} <- finding_items(b) do
        res = MeetingBriefings.act(j_briefing, fkey, :confirm, scope(j), %{})
        obs("c2.#{variant}.J.direct_act.#{fkey}", res)

        j_lv
        |> with_target("#meeting-briefing-#{a.meeting.id}")
        |> render_click("act", %{"key" => fkey, "verb" => "dismiss"})
      end

      obs(
        "c2.#{variant}.receipts_after_J_acts",
        Enum.map(SynthesisFindings.list_for_meeting(a.meeting.id), & &1.receipt)
      )

      assert Enum.any?(
               r_findings,
               &Enum.any?(&1.finding.citations, fn c -> c.ref == "message:" <> p_msg.id end)
             )

      assert r_hits != []
      assert j_findings == []
      assert hits == []
      assert j_view.counts.total == 1
      assert j_row.body == "1 item"
      assert Enum.all?(j_pushes, &(&1.body =~ "· 1 item"))

      for {fkey, _} <- finding_items(b) do
        assert {:error, :not_found} =
                 MeetingBriefings.act(j_briefing, fkey, :confirm, scope(j), %{})
      end

      assert Enum.all?(SynthesisFindings.list_for_meeting(a.meeting.id), &is_nil(&1.receipt))
      assert length(rows) == if(variant == :no_cite, do: 1, else: 2)
      assert Enum.all?(rows, &(&1.recipient_user_ids == [r.id]))
    end
  end

  # ── Case 3 ──────────────────────────────────────────────────────────────

  for mode <- [:empty_provider, :provider_none] do
    @tag mode: mode
    test "case 3 (#{mode}): no conflict, no items, not delayed", ctx do
      mode = ctx.mode
      r = user!("R")

      if mode == :provider_none do
        Application.put_env(:platform, :meetings_summary, %{provider: :none})
      else
        Application.put_env(:platform, :e2e_synth_fun, fn _ -> "" end)
      end

      live = live_meeting!(ctx.project, "Garden planning #{mode}", [r])
      join!(live.chat_space_id, r)
      c = complete!(ctx, live, "Water the ferns on Tuesday.", ["Water the ferns on Tuesday"])

      called =
        receive do
          {:provider_called, _, _} -> true
        after
          0 -> false
        end

      b = briefing(c.meeting)
      row = inbox_row(r, c.meeting)
      readiness = MeetingBriefings.readiness(c.meeting)

      obs("c3.#{mode}.provider_called", called)
      obs("c3.#{mode}.synthesis_after_scribe", c.synthesis_after_scribe)
      obs("c3.#{mode}.missing_after_scribe", c.readiness_after_scribe.missing)

      obs("c3.#{mode}.run", %{
        status: c.run.status,
        snapshot_hash: c.run.snapshot_hash,
        synthesis: c.run.synthesis
      })

      obs("c3.#{mode}.finding_items", finding_items(b))
      obs("c3.#{mode}.finding_rows", length(SynthesisFindings.list_for_meeting(c.meeting.id)))
      obs("c3.#{mode}.readiness", readiness)

      obs("c3.#{mode}.timing", %{
        meeting_ended_at: c.meeting.ended_at,
        triage_called_at: c.triage_at,
        triage_returned_at: c.triage_returned_at,
        inbox_row_inserted_at: row && row.inserted_at,
        row_minus_ended_s:
          row && DateTime.diff(row.inserted_at, c.meeting.ended_at, :millisecond) / 1000,
        row_minus_triage_s:
          row && DateTime.diff(row.inserted_at, c.triage_at, :millisecond) / 1000
      })

      assert finding_items(b) == []
      assert SynthesisFindings.list_for_meeting(c.meeting.id) == []
      assert c.run.synthesis == %{"snapshot_hash" => c.run.snapshot_hash, "status" => "complete"}
      refute "synthesis" in readiness.missing
      assert row
      refute readiness.deadline?
      assert DateTime.diff(row.inserted_at, c.meeting.ended_at) < 1200
    end
  end

  # ── Case 4 ──────────────────────────────────────────────────────────────

  test "case 4: synthesis files nothing; duplicate offers Revert; raising provider still delivers",
       %{conn: conn} = ctx do
    r = user!("R")

    {:ok, existing} =
      Tasks.create_task(%{
        project_id: ctx.project.id,
        title: "Migrate billing to Paddle",
        description: "Move all billing to Paddle.",
        status: "backlog"
      })

    obs("c4.existing", Map.take(existing, [:id, :title, :status]))

    Application.put_env(:platform, :e2e_synth_fun, fn payload ->
      filed =
        Enum.find_value(payload["sources"], fn s ->
          (String.starts_with?(s["ref"], "task:") and s["ref"] != "task:" <> existing.id and
             s["text"] =~ "Paddle") && s["ref"]
        end)

      send(Application.fetch_env!(:platform, :e2e_synth_owner), {:dup_refs, filed})

      ~s(<meeting-finding kind="duplicates" confidence="high">The task filed in this meeting duplicates the open billing migration task.<cite ref="task:#{existing.id}"/><cite ref="#{filed}"/></meeting-finding>)
    end)

    live = live_meeting!(ctx.project, "Payments standup", [r])
    join!(live.chat_space_id, r)
    count_before = Repo.aggregate(Platform.Tasks.Task, :count)

    d =
      complete!(ctx, live, "Let's switch our billing provider over to Paddle.", [
        "Switch the billing provider over to Paddle"
      ])

    count_after = Repo.aggregate(Platform.Tasks.Task, :count)
    assert_received {:dup_refs, filed_ref}

    filed_ids = d.filed.task_ids

    obs("c4.counts", %{
      before_meeting: count_before,
      before_triage: d.tasks_before_triage,
      after_triage: d.tasks_after_triage,
      after_synthesis: count_after,
      triage_filed: filed_ids
    })

    obs("c4.filed_ref_cited", filed_ref)
    filed_tasks = Repo.all(from(t in Platform.Tasks.Task, where: t.id in ^filed_ids))

    obs(
      "c4.filed_tasks",
      Enum.map(filed_tasks, &Map.take(&1, [:id, :title, :status, :deleted_at]))
    )

    rows = SynthesisFindings.list_for_meeting(d.meeting.id)

    obs(
      "c4.finding_rows",
      Enum.map(rows, &Map.take(&1, [:kind, :citations, :recipient_user_ids, :receipt]))
    )

    v = MeetingBriefings.view(MeetingBriefings.get_for_attendee(d.meeting.id, r.id), scope(r))
    entry = Enum.find(v.open, &(&1.kind == "finding"))

    obs(
      "c4.view_finding",
      entry &&
        %{
          actions: entry.actions,
          revert_ref: entry.finding.revert_ref,
          revertible?: entry.revertible?
        }
    )

    {:ok, lv, _} = live(auth(conn, r), detail(d.meeting))
    revert_btn = entry && has_element?(lv, card(entry.key) <> ~s( [data-action="revert"]))
    obs("c4.lv_revert_button", revert_btn)

    still = Repo.all(from(t in Platform.Tasks.Task, where: t.id in ^filed_ids))
    obs("c4.filed_tasks_after_view", Enum.map(still, &Map.take(&1, [:id, :status, :deleted_at])))

    assert count_after == d.tasks_after_triage
    assert d.tasks_after_triage - count_before == length(filed_ids)
    assert [_] = rows
    assert entry
    assert :revert in entry.actions
    assert entry.finding.revert_ref == "task:" <> hd(filed_ids)
    assert revert_btn
    assert Enum.all?(still, &(&1.status == "backlog" and is_nil(&1.deleted_at)))

    # Raising provider on a fresh meeting.
    Application.put_env(:platform, :e2e_synth_fun, fn _ -> raise "stub provider failure" end)
    live2 = live_meeting!(ctx.project, "Payments retro", [r])
    join!(live2.chat_space_id, r)
    e = complete!(ctx, live2, "Let's document the refund flow.", ["Document the refund flow"])
    row = inbox_row(r, e.meeting)
    obs("c4.raise.synthesis", e.run.synthesis)
    obs("c4.raise.findings", length(SynthesisFindings.list_for_meeting(e.meeting.id)))
    obs("c4.raise.inbox_row", row && Map.take(row, [:title, :body, :inserted_at]))
    obs("c4.raise.readiness", MeetingBriefings.readiness(e.meeting))
    assert row
    assert e.run.synthesis["status"] == "complete"
    assert SynthesisFindings.list_for_meeting(e.meeting.id) == []
  end
end
