defmodule Platform.Ux.FrictionWatchTest do
  @moduledoc """
  `ux.friction_watch` (task 01a1af00 stage 2): `Handlers.UxFrictionWatch` and
  `Platform.Ux.FrictionWatch`.

  The model is a Mox mock of `Platform.Agents.Providers.Provider` bound
  through `:ux_friction_watch_provider`. The mock answers from the signals it
  was actually sent, so a signal outside the privacy scope can only appear in
  a finding if the server sent it.

  Covers: the no-assignee no-op, the privacy scope (a non-member space and a
  mixed internal+external space contribute nothing, with a readable-channel
  positive control), idempotency (a re-run, and a re-run after the decision
  was answered, file no second decision), the child-task dedupe, the
  threshold and minimum occurrences read from the surface payload, and the
  Router outcome.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Experiments.SurfaceDefault
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.UxFrictionWatch
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Tenancy
  alias Platform.TenancyFixtures
  alias Platform.Ux.Finding
  alias Platform.Ux.FrictionWatch

  Mox.defmock(Platform.Ux.FrictionWatchProviderMock, for: Platform.Agents.Providers.Provider)

  @mock Platform.Ux.FrictionWatchProviderMock

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:platform, :ux_friction_watch_provider)
    Application.put_env(:platform, :ux_friction_watch_provider, @mock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :ux_friction_watch_provider, previous),
        else: Application.delete_env(:platform, :ux_friction_watch_provider)
    end)

    :ok = Seeds.seed_defaults(only_keys: ["designer"])
    [spec] = UxFrictionWatch.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    owner = TenancyFixtures.root_admin!()

    %{row: row, owner: owner}
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "ux-watch-#{System.unique_integer([:positive])}",
      name: "Friction Watch Agent",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp assign_designer! do
    agent = agent!()
    {:ok, _} = Roles.assign_role("designer", agent.id)
    agent
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "ux-#{n}@example.com", name: "Member #{n}", oidc_sub: "ux-#{n}"})
    |> Repo.insert!()
  end

  defp external_user! do
    user = user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: TenancyFixtures.tenant_org_id("globex")
      })

    user
  end

  defp space!(name) do
    {:ok, space} =
      Chat.create_space(%{
        name: name,
        slug: "ux-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp join!(space, type, id) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: content,
      author_display_name: "Member"
    })
    |> Repo.insert!()
  end

  # One internal channel the agent is in, with `n` friction posts and one
  # non-friction post the pre-filter must drop.
  defp readable_channel!(agent, n, text \\ "I can't find my direct messages anywhere") do
    space = space!("general")
    join!(space, "agent", agent.id)
    member = join!(space, "user", user!().id)
    msgs = for i <- 1..n, do: post!(space, member, "#{text} (#{i})")
    post!(space, member, "lunch at noon works for me")
    {space, msgs}
  end

  # The mock groups EVERY signal it was sent into one group, so the
  # findings' citations are exactly the signals the server chose to send.
  defp expect_one_group(opts \\ []) do
    test_pid = self()
    kind = Keyword.get(opts, :kind, "decision")
    similarity = Keyword.get(opts, :similarity, 0.92)
    key = Keyword.get(opts, :group_key, "dm-findability")
    times = Keyword.get(opts, :times, 1)
    extra_ids = Keyword.get(opts, :extra_ids, [])

    expect(@mock, :chat, times, fn _credentials, messages, provider_opts ->
      refute Keyword.has_key?(provider_opts, :tools)
      user = Enum.find(messages, &(&1.role == "user")).content
      signals = Jason.decode!(user)
      send(test_pid, {:model_saw, user, signals})

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "groups" => [
               %{
                 "group_key" => key,
                 "kind" => kind,
                 "question" => "Should direct messages get their own tab?",
                 "similarity" => similarity,
                 "signal_ids" => Enum.map(signals, & &1["id"]) ++ extra_ids,
                 "options" => [
                   %{"label" => "Add a DMs tab", "recommended" => true, "detail" => "Both sizes"},
                   %{"label" => "Pin DMs at the top of the rail", "recommended" => false}
                 ]
               }
             ]
           })
       }}
    end)
  end

  defp findings, do: Repo.all(from(f in Finding, order_by: [asc: f.inserted_at]))

  defp promote!(payload) do
    %SurfaceDefault{}
    |> SurfaceDefault.changeset(%{
      surface_key: "ux.friction_detection",
      surface_target: "ux.friction_detection",
      seq: System.unique_integer([:positive]),
      kind: "promote",
      payload: payload
    })
    |> Repo.insert!()
  end

  # ── registration ─────────────────────────────────────────────────────────

  describe "registration" do
    test "one weekly cron row, per_org, key equal to the designer bundle key", %{row: row} do
      assert row.key == "ux.friction_watch"
      assert row.trigger_kind == "cron"
      assert row.trigger_config["expression"] == "0 8 * * 1"
      assert row.trigger_config["timezone"] == "America/Chicago"
      assert row.scope == "per_org"
      assert row.default_prompt_template == "ux.friction_watch.v1"
      assert "ux.friction_watch" in Roles.bundle_for("designer")

      assert Platform.Responsibilities.Handlers.UxFrictionWatch in Platform.Responsibilities.BuiltIns.providers()
    end

    test "build_prompt and handle_output refuse: there is no agent dispatch" do
      assert {:error, :ux_friction_watch_server_side} = UxFrictionWatch.build_prompt(%{})
      assert {:error, :ux_friction_watch_server_side} = UxFrictionWatch.handle_output(%{}, %{})
    end
  end

  # ── no assignee ──────────────────────────────────────────────────────────

  describe "no assignee" do
    test "a fire with nobody holding the key is a no-op: no read, no model call, no row" do
      agent = agent!()
      readable_channel!(agent, 4)

      # No `expect`: any model call fails the test via Mox.
      assert Router.fire("ux.friction_watch", %{}) == {:ok, :unfilled}
      assert {:ok, %{status: :unassigned, scope_space_ids: []}} = FrictionWatch.run(nil)

      assert {:handled, %{status: :unassigned}} =
               UxFrictionWatch.gather_context(
                 %Responsibilities.Responsibility{key: "ux.friction_watch"},
                 %{}
               )

      assert findings() == []
    end
  end

  # ── privacy scope ────────────────────────────────────────────────────────

  describe "privacy scope" do
    test "a non-member channel and a mixed internal+external space contribute nothing" do
      agent = assign_designer!()

      # Positive control: an internal channel the agent is in.
      {readable, readable_msgs} = readable_channel!(agent, 3)

      # A channel the agent is NOT in.
      outside = space!("elsewhere")
      outsider = join!(outside, "user", user!().id)

      outside_msgs =
        for i <- 1..3, do: post!(outside, outsider, "where is the settings page #{i}")

      # A mixed space the agent IS in: an internal member and an external one.
      mixed = space!("shared-with-partner")
      join!(mixed, "agent", agent.id)
      internal = join!(mixed, "user", user!().id)
      join!(mixed, "user", external_user!().id)
      mixed_msgs = for i <- 1..3, do: post!(mixed, internal, "how do I export this thread #{i}")

      expect_one_group()

      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}

      assert_received {:model_saw, user_turn, signals}
      assert length(signals) == 3
      refute user_turn =~ "settings page"
      refute user_turn =~ "export this thread"
      refute user_turn =~ "lunch at noon"

      # The model never sees an id.
      for id <- [readable.id, outside.id, mixed.id] ++ Enum.map(readable_msgs, & &1.id),
          do: refute(user_turn =~ id)

      [finding] = findings()
      cited = finding.evidence["citations"]
      assert cited == Enum.map(readable_msgs, &Finding.citation(readable.id, &1.id))

      for m <- outside_msgs ++ mixed_msgs do
        refute Enum.any?(cited, &String.contains?(&1, m.id))
      end

      refute Enum.any?(cited, &String.contains?(&1, outside.id))
      refute Enum.any?(cited, &String.contains?(&1, mixed.id))
      assert finding.evidence["count"] == 3
      assert finding.evidence["spaces"] == 1
    end

    test "with no readable friction there is no model call" do
      agent = assign_designer!()

      # The agent IS in a channel (so its roster is not empty and the reader
      # really queries), but nothing there reads as friction.
      calm = space!("calm")
      join!(calm, "agent", agent.id)
      post!(calm, join!(calm, "user", user!().id), "shipped the release, thanks all")

      outside = space!("elsewhere")
      outsider = join!(outside, "user", user!().id)
      for i <- 1..4, do: post!(outside, outsider, "I can't find the inbox #{i}")

      # No `expect`: the pre-filter found nothing readable, so no model call.
      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}
      assert {:ok, %{status: :no_signals, signals: 0}} = FrictionWatch.run(agent)
      assert findings() == []
    end

    test "a signal id the model invents is dropped from the evidence" do
      agent = assign_designer!()
      {space, msgs} = readable_channel!(agent, 3)
      expect_one_group(extra_ids: [999])

      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}
      [finding] = findings()
      assert finding.evidence["count"] == 3
      assert finding.evidence["citations"] == Enum.map(msgs, &Finding.citation(space.id, &1.id))
    end
  end

  # ── the Inbox row (stage 3) ─────────────────────────────────────────────

  defp ux_rows,
    do: Repo.all(from(i in Platform.Inbox.Item, where: i.kind == "ux_decision"))

  describe "the ux_decision Inbox row (stage 3)" do
    test "a decision files ONE row, to its recipient only; a re-run files no second" do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      expect_one_group(times: 2)

      assert {:ok, %{created: ["dm-findability"]}} = FrictionWatch.run(agent)
      [finding] = findings()

      assert [row] = ux_rows()
      assert row.user_id == finding.recipient_user_id
      assert row.user_id == Accounts.install_owner().id
      assert row.source_type == "ux_finding"
      assert row.source_id == finding.id
      assert row.title == finding.question
      assert row.url == "/inbox/ux/" <> finding.id

      assert {:ok, %{created: [], deduped: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert [_] = ux_rows()
    end

    # Stage 4 follow-up: the test above has recipient == install owner, so a
    # mutant emitting to `Accounts.install_owner/0` instead of the finding's
    # recipient survived it. Here the two differ.
    test "with a recipient other than the install owner, the row goes ONLY to the recipient",
         %{owner: owner} do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      expect_one_group()
      recipient = user!()

      assert Accounts.install_owner().id == owner.id
      refute recipient.id == owner.id

      assert {:ok, %{created: ["dm-findability"]}} =
               FrictionWatch.run(agent, recipient_user_id: recipient.id)

      [finding] = findings()
      assert finding.recipient_user_id == recipient.id

      assert [row] = ux_rows()
      assert row.user_id == recipient.id
      assert row.source_id == finding.id
      assert Repo.all(from(i in Platform.Inbox.Item, where: i.user_id == ^owner.id)) == []
    end

    test "an fyi is never an Inbox row" do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      expect_one_group(kind: "fyi", group_key: "rail-density")

      assert {:ok, %{created: ["rail-density"]}} = FrictionWatch.run(agent)
      assert [%{kind: "fyi"}] = findings()
      assert ux_rows() == []
    end
  end

  # ── idempotency and dedupe ───────────────────────────────────────────────

  describe "idempotency" do
    test "re-running files no second decision, open or after it was answered", %{owner: owner} do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      expect_one_group(times: 3)

      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}
      [first] = findings()
      assert first.kind == "decision"
      assert first.recipient_user_id == Accounts.install_owner().id
      assert is_binary(owner.id)
      assert [%{"recommended" => true}, %{"recommended" => false}] = first.options

      assert {:ok, %{created: [], deduped: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert length(findings()) == 1

      # Answered: still ONE decision per recipient per group_key, ever. The
      # partial unique index covers open rows only, so only the dedupe holds
      # this line.
      first |> Finding.resolve_changeset("answered", "Add a DMs tab") |> Repo.update!()
      assert {:ok, %{created: [], deduped: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert [%{id: id}] = findings()
      assert id == first.id
    end

    test "an fyi is held as one open row; a re-run does not add a second", %{owner: _owner} do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      expect_one_group(kind: "fyi", group_key: "rail-density", times: 2)

      assert {:ok, %{created: ["rail-density"]}} = FrictionWatch.run(agent)
      assert {:ok, %{created: [], deduped: ["rail-density"]}} = FrictionWatch.run(agent)
      assert [%{kind: "fyi", status: "open"}] = findings()
    end

    test "a group_key owned by a child task's finding is skipped for every recipient" do
      agent = assign_designer!()
      readable_channel!(agent, 3)
      other = user!()

      {:ok, project} = Platform.Tasks.create_project(%{name: "UX #{System.unique_integer()}"})
      {:ok, task} = Platform.Tasks.create_task(%{project_id: project.id, title: "Findable DMs"})

      %Finding{}
      |> Finding.changeset(%{
        recipient_user_id: other.id,
        question: "Should direct messages get their own tab?",
        kind: "decision",
        group_key: "dm-findability",
        task_id: task.id,
        status: "dismissed",
        evidence: %{"count" => 1, "quotes" => [], "citations" => []},
        options: [%{"label" => "Add a DMs tab", "recommended" => true}]
      })
      |> Repo.insert!()

      expect_one_group()

      assert {:ok, %{created: [], deduped: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert length(findings()) == 1
    end
  end

  # ── threshold from the surface ───────────────────────────────────────────

  describe "grouping threshold and min occurrences come from the surface payload" do
    test "the control (0.80, 3) drops a two-signal group at 0.70 similarity" do
      agent = assign_designer!()
      readable_channel!(agent, 2)
      expect_one_group(similarity: 0.7)

      assert {:ok, %{created: [], below_threshold: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert findings() == []
    end

    test "a promoted payload (0.60, 2) keeps the same group" do
      promote!(%{"grouping_threshold" => 0.6, "min_occurrences" => 2})
      agent = assign_designer!()
      readable_channel!(agent, 2)
      expect_one_group(similarity: 0.7)

      assert {:ok, %{created: ["dm-findability"]}} = FrictionWatch.run(agent)
      assert [%{evidence: %{"count" => 2}}] = findings()
    end

    test "a stricter payload (0.95, 5) drops a group the control would keep" do
      promote!(%{"grouping_threshold" => 0.95, "min_occurrences" => 5})
      agent = assign_designer!()
      readable_channel!(agent, 4)
      expect_one_group(similarity: 0.9)

      assert {:ok, %{created: [], below_threshold: ["dm-findability"]}} = FrictionWatch.run(agent)
    end

    test "the payload's numbers are rendered into the system turn" do
      promote!(%{
        "grouping_threshold" => 0.66,
        "min_occurrences" => 4,
        "directive" => "Be terse."
      })

      {payload, nil} = FrictionWatch.experiment(nil)
      [system, _user] = FrictionWatch.build_messages([], payload)
      assert system.content =~ "0.66"
      assert system.content =~ "at least 4 signals"
      assert system.content =~ "Be terse."
    end
  end

  # ── pre-filter and parsing ───────────────────────────────────────────────

  describe "pre-filter and parse" do
    test "friction phrases pass, ordinary chat does not" do
      for text <- [
            "how do I get to direct messages",
            "I can't find the channel list",
            "where is the settings page?",
            "this is so confusing",
            "the sidebar keeps jumping around"
          ],
          do: assert(FrictionWatch.friction?(text), text)

      for text <- ["lunch at noon works for me", "shipped the release", "thanks!"],
          do: refute(FrictionWatch.friction?(text), text)
    end

    test "parse rejects non-JSON and drops malformed groups" do
      assert FrictionWatch.parse("not json") == :rejected

      assert {:ok, [%{group_key: "dm-findability"}]} =
               FrictionWatch.parse(
                 "```json\n" <>
                   Jason.encode!(%{
                     "groups" => [
                       %{
                         "group_key" => "DM Findability!",
                         "kind" => "decision",
                         "question" => "Add a DMs tab?",
                         "similarity" => 0.9,
                         "signal_ids" => [1]
                       },
                       %{
                         "group_key" => "x",
                         "kind" => "other",
                         "question" => "?",
                         "similarity" => 1
                       },
                       %{
                         "group_key" => "y",
                         "kind" => "fyi",
                         "question" => "no mark",
                         "similarity" => 1
                       }
                     ]
                   }) <> "\n```"
               )
    end
  end

  # ── stage 4: the weekly digest ───────────────────────────────────────────

  describe "weekly digest (stage 4)" do
    # The mock files the DM signals as one decision and the timestamp signals
    # as one fyi, from the signals it was actually sent.
    defp expect_decision_and_fyi(times \\ 1) do
      expect(@mock, :chat, times, fn _credentials, messages, _opts ->
        signals = Jason.decode!(Enum.find(messages, &(&1.role == "user")).content)
        ids = fn word -> for s <- signals, s["text"] =~ word, do: s["id"] end

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "groups" => [
                 %{
                   "group_key" => "dm-findability",
                   "kind" => "decision",
                   "question" => "Should direct messages get their own tab?",
                   "similarity" => 0.92,
                   "signal_ids" => ids.("direct messages"),
                   "options" => [
                     %{"label" => "Add a DMs tab", "recommended" => true},
                     %{"label" => "Pin DMs at the top of the rail", "recommended" => false}
                   ]
                 },
                 %{
                   "group_key" => "timestamp-size",
                   "kind" => "fyi",
                   "question" => "Are message timestamps too small to read?",
                   "similarity" => 0.9,
                   "signal_ids" => ids.("timestamps")
                 }
               ]
             })
         }}
      end)
    end

    defp digest_rig! do
      agent = assign_designer!()
      {channel, _} = readable_channel!(agent, 3)
      member = join!(channel, "user", user!().id)
      for i <- 1..3, do: post!(channel, member, "the timestamps are too small to read (#{i})")

      digest = space!("design-digest")
      join!(digest, "agent", agent.id)
      join!(digest, "user", user!().id)
      agent = set_digest_space!(agent, digest.id)
      {agent, channel, digest}
    end

    defp set_digest_space!(agent, space_id) do
      agent
      |> Ecto.Changeset.change(
        metadata: Map.put(agent.metadata || %{}, "ux_digest_space_id", space_id)
      )
      |> Repo.update!()
    end

    defp digest_messages(space) do
      Repo.all(
        from(m in Message,
          where: m.space_id == ^space.id and fragment("?->>'source' = 'ux_digest'", m.metadata),
          order_by: [asc: m.inserted_at]
        )
      )
    end

    test "the cron fire posts the fyi to the digest space, never the Inbox; the decision is an Inbox row" do
      {_agent, channel, digest} = digest_rig!()
      expect_decision_and_fyi()

      assert Router.fire("ux.friction_watch", %{kind: :cron}) == {:ok, :handled}

      fyi = Repo.one!(from(f in Finding, where: f.kind == "fyi"))
      decision = Repo.one!(from(f in Finding, where: f.kind == "decision"))

      assert [message] = digest_messages(digest)
      assert message.content =~ "UX weekly digest"
      assert message.content =~ "Are message timestamps too small to read?"
      assert message.content =~ "Seen 3× this week across 1 channel"
      assert message.content =~ "1 decision sent to an inbox this week."
      # The decision's question is not in the digest, and no quote, id or link is.
      refute message.content =~ "direct messages get their own tab"
      refute message.content =~ "too small to read ("
      refute message.content =~ channel.id
      assert message.metadata["skip_mention_scan"] == true

      # The fyi is in chat only; the positive control decision IS one Inbox row.
      refute Repo.exists?(from(i in Platform.Inbox.Item, where: i.source_id == ^fyi.id))
      assert [row] = ux_rows()
      assert row.source_id == decision.id
      assert Repo.reload!(fyi).status == "posted"
    end

    test "a second cron fire does not repeat a posted fyi" do
      {_agent, _channel, digest} = digest_rig!()
      expect_decision_and_fyi(2)

      assert Router.fire("ux.friction_watch", %{kind: :cron}) == {:ok, :handled}
      assert Router.fire("ux.friction_watch", %{kind: :cron}) == {:ok, :handled}

      # The same friction is still in chat, so the second fire files a new
      # fyi for next week and posts it; the first fyi is never repeated.
      [first, second] = digest_messages(digest)

      [old_fyi, new_fyi] =
        Repo.all(from(f in Finding, where: f.kind == "fyi", order_by: f.inserted_at))

      assert first.metadata["finding_ids"] == [old_fyi.id]
      assert second.metadata["finding_ids"] == [new_fyi.id]
      assert [_] = ux_rows()
    end

    test "an on-demand fire runs the watch only and posts no digest" do
      {_agent, _channel, digest} = digest_rig!()
      expect_decision_and_fyi()

      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}
      assert digest_messages(digest) == []
      assert Repo.one!(from(f in Finding, where: f.kind == "fyi")).status == "open"
    end

    test "no digest space, a space the agent is not in, or a mixed space posts nothing" do
      {agent, _channel, _digest} = digest_rig!()
      not_member = space!("not-mine")
      mixed = space!("with-partner")
      join!(mixed, "agent", agent.id)
      join!(mixed, "user", external_user!().id)
      expect_decision_and_fyi()

      assert Router.fire("ux.friction_watch", %{}) == {:ok, :handled}

      for {space_id, reason} <- [
            {nil, :no_digest_space},
            {not_member.id, :space_not_allowed},
            {mixed.id, :space_not_allowed}
          ] do
        agent = set_digest_space!(agent, space_id)
        assert Platform.Ux.Digest.post(agent) == {:skipped, reason}
      end

      assert Repo.all(
               from(m in Message, where: fragment("?->>'source' = 'ux_digest'", m.metadata))
             ) ==
               []

      assert Repo.one!(from(f in Finding, where: f.kind == "fyi")).status == "open"
    end

    test "with no fyi and no decision there is nothing to post" do
      agent = assign_designer!()
      digest = space!("design-digest")
      join!(digest, "agent", agent.id)
      agent = set_digest_space!(agent, digest.id)

      assert Platform.Ux.Digest.post(agent) == {:skipped, :nothing_to_post}
      assert digest_messages(digest) == []
    end
  end
end
