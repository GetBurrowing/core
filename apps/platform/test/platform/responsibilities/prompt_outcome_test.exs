defmodule Platform.Responsibilities.PromptOutcomeTest do
  @moduledoc """
  The prompt-outcome taxonomy: `Router.classify_prompt_outcome/1` and its
  two consumers (task 019fb8ed stage 1).

  ## What was wrong

  `Router.rendered_prompt_text/1` mapped FOUR distinct provider results
  onto `nil` — `:legacy`, `{:error, reason}`, a `{:messages, _}` whose
  contents join to `""`, and any unexpected shape — and `maybe_put/3` then
  dropped the key. Every one of them therefore left the server as a
  byte-identical bare envelope. A federated runtime could not tell
  "`Handlers.MeetingActionItems` deliberately refused to spend a model
  round-trip on a blank transcript" (legitimate) apart from "`Providers.Tasks`
  exports no `build_prompt/1` at all, so `tasks.triage` has never once
  rendered" (a real gap). Both look like silence.

  ## What this file proves, and what it does not

  It proves the CAUSES are now named and pairwise distinct, and that the
  classifier is actually the thing the dispatch path runs.

  It deliberately does NOT prove that any empty prompt has been fixed, nor
  that the wire carries a status. The wire shape is unchanged in this
  stage on purpose — `prompt` for `{:rendered, text}`, key omitted for
  every `{:absent, _}` — so a bisect can separate "we named the causes"
  from "we changed what ships". Stage 2 renders the missing bodies; stage
  3 puts the status on the envelope. Assertions here that a bare signal is
  still bare are pinning that deliberate no-op, not claiming a fix.

  ## Why two assertion shapes, and why neither is redundant

  The distinctness test (`uniq == 5`) refuses the failure this stage
  exists to prevent: a future edit that re-collapses two causes onto one
  value. Five independent `assert classify(x) == expected` lines would
  ALSO go red for that, but they would print two unrelated diffs rather
  than the colliding pair, and — the real reason — this repo has already
  shipped "two distinct refusal paths returning the same atom so the test
  cannot tell which fired". A pairwise-distinctness assertion is the shape
  that names that class directly.

  But `uniq == 5` is on its own satisfiable by a WRONG classifier: a
  one-line `def classify(x), do: {:absent, {:unexpected_shape, x}}`
  returns five distinct values and passes it. So the exact-value test
  carries the contract, and the distinctness test carries the
  anti-collapse property. Delete either and a real defect ships. That is
  the standard being applied here rather than assumed — see the
  end-to-end describe below for the third leg, which is what stops the
  whole taxonomy from being a pure function nobody calls.

  ## What the enumeration does NOT mean

  A fourth describe pins which of the five outcomes the provider layer can
  actually produce. Only three can: `build_prompt_via_provider/2` maps
  `{:error, :no_build_prompt}`, an unexpected return, and a raise onto
  `:legacy` before the classifier sees them. The other two are classified
  but unreachable from live traffic, so a reader who takes the five-way
  enumeration as a description of what arrives will be wrong — and a later
  stage that maps `{:absent, {:refused, :no_build_prompt}}` to its own wire
  status will find it never fires. Un-collapsing that is wire-visible on
  the external path and out of scope here; the tests pin the pre-collapse
  so the change that does it has a red line to flip.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.ExternalAgents.Dispatcher, as: ExternalDispatcher
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.TaskTriage
  alias Platform.Responsibilities.Responsibility
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role

  setup do
    # config/test.exs pins the repo logger at :warning; the fidelity lines
    # asserted below are emitted by the Router module, so raise it there.
    Logger.put_module_level(Router, :info)
    on_exit(fn -> Logger.delete_module_level(Router) end)
    :ok
  end

  # ── the classifier as a pure function ─────────────────────────────────────

  describe "classify_prompt_outcome/1" do
    # Content-pinned, not property-pinned. `is_binary(text)` or `text != ""`
    # would be satisfied by a classifier that returned the wrong half of the
    # messages list, or that dropped the "\n\n" join the federated clients
    # split on.
    test "a non-blank messages list renders, carrying the joined body" do
      messages = [
        %{role: "system", content: "SYSTEM_HALF"},
        %{role: "user", content: "USER_HALF"}
      ]

      assert Router.classify_prompt_outcome({:messages, messages}) ==
               {:rendered, "SYSTEM_HALF\n\nUSER_HALF"}
    end

    test "blank and non-binary contents are an empty render, not a rendered empty string" do
      # The distinction matters downstream: `{:rendered, ""}` would put an
      # empty `prompt` key on the wire, which reads to a client as "the
      # server had something to say and it was nothing".
      assert Router.classify_prompt_outcome({:messages, [%{role: "user", content: ""}]}) ==
               {:absent, :empty_render}

      assert Router.classify_prompt_outcome({:messages, [%{role: "user", content: nil}]}) ==
               {:absent, :empty_render}

      assert Router.classify_prompt_outcome({:messages, []}) == {:absent, :empty_render}
    end

    test "each remaining shape maps to its own named cause" do
      assert Router.classify_prompt_outcome(:legacy) == {:absent, :legacy}

      assert Router.classify_prompt_outcome({:error, :no_transcript_text}) ==
               {:absent, {:refused, :no_transcript_text}}

      assert Router.classify_prompt_outcome(:a_shape_no_clause_matches) ==
               {:absent, {:unexpected_shape, :a_shape_no_clause_matches}}
    end

    # THE ASSERTION THIS STAGE EXISTS FOR.
    #
    # WHAT FAILURE LOOKS LIKE: re-collapse `:legacy` and
    # `{:error, :no_build_prompt}` onto one value — the exact regression the
    # taxonomy is defending against, and the shape the original defect took —
    # and the uniq count drops to 4 while the message prints the colliding
    # pair by name. A suite of per-input equality assertions would go red too,
    # but would report it as two unrelated diffs rather than as a collision.
    test "the five provider shapes classify to five pairwise-distinct outcomes" do
      inputs = [
        {:messages, [%{role: "user", content: "a body"}]},
        {:messages, [%{role: "user", content: ""}]},
        {:error, :no_transcript_text},
        :legacy,
        :a_shape_no_clause_matches
      ]

      outcomes = Enum.map(inputs, &Router.classify_prompt_outcome/1)

      collisions =
        outcomes
        |> Enum.frequencies()
        |> Enum.filter(fn {_outcome, count} -> count > 1 end)

      assert collisions == [],
             "distinct provider results collapsed onto a shared outcome: " <>
               inspect(collisions) <>
               " — that is the defect this taxonomy exists to prevent"

      assert length(Enum.uniq(outcomes)) == 5
    end

    # The refusal reason has to SURVIVE the classification, not just the
    # fact of refusal. Stage 3 maps `:no_transcript_text` (a legitimate
    # no-work decision) and `:no_build_prompt` (a wiring gap) to different
    # wire statuses; flattening both to a bare `{:absent, :refused}` here
    # would recreate the collapse one layer up, and would still pass the
    # five-shape distinctness test above.
    test "two different refusal reasons stay distinguishable from each other" do
      no_transcript = Router.classify_prompt_outcome({:error, :no_transcript_text})
      no_builder = Router.classify_prompt_outcome({:error, :no_build_prompt})

      assert no_transcript != no_builder
      assert no_transcript == {:absent, {:refused, :no_transcript_text}}
      assert no_builder == {:absent, {:refused, :no_build_prompt}}
    end

    # The catch-all must RECORD the shape it could not read. It stays a
    # catch-all rather than a FunctionClauseError because these fire sites
    # sit inside a plan-submit transaction — but discarding the value is
    # what made "a new provider return shape" indistinguishable from "no
    # provider" for as long as it did.
    test "the catch-all preserves the unreadable value rather than discarding it" do
      strange = %{some: "future shape"}

      assert {:absent, {:unexpected_shape, ^strange}} = Router.classify_prompt_outcome(strange)
    end
  end

  # ── the classifier as the thing dispatch actually runs ────────────────────
  #
  # WITHOUT THIS DESCRIBE the whole file is vacuous: `classify_prompt_outcome/1`
  # is a public function, so every test above would stay green if
  # `dispatch_native/6` never called it and kept its own private copy of the
  # old collapse. These drive real responsibility rows through
  # `Router.fire_trigger/3` with real (throwaway) providers registered through
  # the supported override seam, and assert on the signal the native
  # dispatcher receives plus the log line the classification selects.
  #
  # The empty-render case is the strongest of the four as a wiring proof: its
  # log line did not exist before this stage (the old
  # `log_native_prompt_fidelity(_, _, {:messages, _})` clause matched a blank
  # render and returned `:ok` silently), so it cannot be satisfied by the
  # pre-stage tree at all.
  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :prompt_outcome_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  describe "the dispatch path routes through the classification" do
    setup :capture_native_dispatch

    test "a rendered prompt reaches the signal as the joined body" do
      row = responsibility_with_provider(build_prompt: {:ok, %{system: "SYS", user: "USR"}})
      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      assert signal.metadata.prompt == "SYS\n\nUSR"

      # No absence line for a body that rendered.
      refute log =~ "no prompt key=#{row.key}"
      refute log =~ "render to an empty body"
    end

    test "a refusal is logged as a refusal, carrying the provider's own reason" do
      row = responsibility_with_provider(build_prompt: {:error, :no_transcript_text})
      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}

      # POSITIVE CONTROL before the refute: `refute Map.has_key?/2` also
      # passes on a signal that never arrived or arrived hollow.
      assert signal.metadata.responsibility_key == row.key
      assert signal.metadata.trigger_kind == :cron
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "provider build_prompt refused but native dispatch proceeds"
      assert log =~ "no_transcript_text"
      refute log =~ "render to an empty body"
    end

    # THE WIRING PROOF. This log line is new in this stage — the pre-stage
    # tree matched a blank `{:messages, _}` in the fidelity logger's first
    # clause and said nothing. If `dispatch_native/6` stops routing through
    # `classify_prompt_outcome/1`, this is the assertion that goes red while
    # every pure-function test above stays green.
    test "a provider that answers with nothing is logged as an empty render, not silence" do
      row = responsibility_with_provider(build_prompt: {:ok, %{system: "", user: ""}})
      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "returned messages that render to an empty body"
      assert log =~ "key=#{row.key}"

      # An empty render is NOT a refusal — that conflation is the thing being
      # taken apart. Asserting the other line is absent is what makes this a
      # distinguishability assertion rather than a "some warning was logged"
      # one.
      refute log =~ "provider build_prompt refused"
    end

    test "a feature with no provider at all is logged differently from both" do
      # No override registered for this feature, so
      # `Providers.feature_provider/1` returns `:error` and
      # `build_prompt_via_provider/2` falls to `:legacy` — the real production
      # shape for `tasks.triage` today.
      key = "promptoutcome.noprov_#{System.unique_integer([:positive])}"

      {:ok, row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "promptoutcome_noprovider_#{System.unique_integer([:positive])}",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "*/5 * * * *"},
          scope: "global",
          cost_profile: "low_freq_capable"
        })

      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "native signal carries no prompt key=#{row.key}"
      assert log =~ "has no provider registered"
      refute log =~ "provider build_prompt refused"
      refute log =~ "render to an empty body"
    end
  end

  # ── the responsibility's own prompt template ──────────────────────────────
  #
  # STAGE 2. `{:absent, :legacy}` is not a verdict, it is a question: no
  # provider spoke for this key, so what does the KEY say it wants? The
  # answer has been sitting in `responsibilities.default_prompt_template`
  # all along — `"tasks.triage.v1"` and friends, whose rows were seeded by
  # `20260703120300_seed_prompt_templates_triage_officer.exs` — and nothing
  # on the native path ever looked one up. Three responsibility keys
  # therefore shipped an empty envelope on every single fire since they
  # were registered.
  #
  # WHY THE ASSERTIONS ARE CONTENT-PINNED. `is_binary(prompt)` or
  # `prompt != ""` is satisfied by the defect: the slug string
  # `"tasks.triage.v1"` is a non-empty binary, and that is precisely what
  # the external path ships today. So the positive test names a phrase
  # from the seeded body and separately refutes the slug.
  describe "a :legacy classification resolves the responsibility's default_prompt_template" do
    setup :capture_native_dispatch

    # THE REAL ROW, THE REAL HANDLER, THE REAL MIGRATION. Nothing about the
    # slug or the body is restated here: the descriptor comes from
    # `TaskTriage.register/0` and the content from the migrated
    # `prompt_templates` table, so a change to either side is caught rather
    # than shadowed by a hand-copied constant.
    test "tasks.triage renders the seeded template body instead of shipping empty" do
      slug = TaskTriage.template_slug()

      # FIXTURE POSITIVE CONTROL, before anything is asserted about the
      # wire. If the migration has not run in this environment the phrase
      # assertion below would fail for a reason that has nothing to do with
      # the Router, and the failure message would send the reader to the
      # wrong file.
      template = PromptTemplates.get_template_by_slug(slug)

      assert template,
             "no prompt_templates row for #{slug} — the seed migration has not run in " <>
               "this test database, so this test cannot say anything about the Router"

      assert template.content =~ "propose a priority pass",
             "the seeded body no longer contains the phrase this test pins; update both " <>
               "the migration and this assertion deliberately, do not loosen the assertion"

      row =
        TaskTriage.register()
        |> hd()
        |> create_responsibility!()

      # The wiring premise, stated rather than assumed: this key's provider
      # exports no `build_prompt/1`, which is what makes the fire classify
      # `:legacy` and reach the new code path at all.
      assert {:ok, Platform.Responsibilities.Providers.Tasks} =
               Platform.Responsibilities.Providers.feature_provider(row.feature)

      refute function_exported?(Platform.Responsibilities.Providers.Tasks, :build_prompt, 1)
      assert row.default_prompt_template == slug

      _agent = wire_native_assignee(row.key)

      assert_dispatched(row)
      assert_receive {:captured_signal, signal}

      assert signal.metadata.responsibility_key == "tasks.triage"
      assert signal.metadata.prompt =~ "propose a priority pass"

      # WHAT FAILURE LOOKS LIKE. If the lookup is skipped and the slug is
      # passed through the way `ExternalAgents.Dispatcher` does, ExUnit
      # prints `"tasks.triage.v1"` as the received value.
      refute signal.metadata.prompt == slug
      refute signal.metadata.prompt =~ "tasks.triage.v1"
    end

    # THE NEGATIVE CONTROL, and it is what makes the test above mean
    # something. A `render_template/2` that returned `{:ok, slug}` for every
    # input would keep the positive test green; this one goes red on it,
    # because a slug with no row must NOT produce a prompt.
    test "a slug with no row is named as a missing template, not silently absent" do
      slug = "promptoutcome.nonexistent_#{System.unique_integer([:positive])}.v1"
      refute PromptTemplates.get_template_by_slug(slug)

      row = responsibility_without_provider(default_prompt_template: slug)
      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}

      # Positive control first: `refute Map.has_key?/2` also passes on a
      # signal that never arrived.
      assert signal.metadata.responsibility_key == row.key
      assert signal.metadata.trigger_kind == :cron
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "names a slug with no prompt_templates row"
      assert log =~ "slug=#{inspect(slug)}"

      # DISTINGUISHABILITY. "this key never claimed a prompt" and "this key
      # claims a prompt that isn't there" need different fixes, so they must
      # not share a line.
      refute log =~ "native signal carries no prompt key=#{row.key}"
      refute log =~ "resolved to a blank body"
    end

    # A third outcome, separate from the two above for the same reason they
    # are separate from each other: the remedy differs. A missing row wants
    # a seed migration; a blank row wants someone to put the content back,
    # since templates are editable live.
    test "a row that exists but renders blank is named separately from a missing row" do
      slug = "promptoutcome.blank_#{System.unique_integer([:positive])}.v1"

      Repo.insert!(%PromptTemplate{
        slug: slug,
        name: "Blank on purpose",
        description: "fixture",
        content: "   \n  ",
        variables: []
      })

      row = responsibility_without_provider(default_prompt_template: slug)
      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "resolved to a blank body"
      assert log =~ "slug=#{inspect(slug)}"
      refute log =~ "names a slug with no prompt_templates row"
    end

    # THE SCOPE FENCE, asserted rather than described. A key that never
    # named a template is still `{:absent, :legacy}` — the lookup must not
    # invent one, and must not start reporting these as broken templates.
    test "a responsibility with no default_prompt_template stays a legacy absence" do
      row = responsibility_without_provider(default_prompt_template: nil)
      assert row.default_prompt_template == nil

      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "native signal carries no prompt key=#{row.key}"
      refute log =~ "names a slug with no prompt_templates row"
      refute log =~ "resolved to a blank body"
    end

    # A provider that DID speak keeps the last word. The template lookup
    # answers `:legacy` only — it is not a fallback for a refusal, and
    # turning it into one would put a generic template body on the wire for
    # `Handlers.MeetingActionItems`' deliberate "there is no transcript,
    # spending a model round-trip here buys nothing" refusal.
    test "a provider refusal is not overridden by the responsibility's template" do
      slug = TaskTriage.template_slug()
      assert PromptTemplates.get_template_by_slug(slug)

      row =
        responsibility_with_provider(
          build_prompt: {:error, :no_transcript_text},
          default_prompt_template: slug
        )

      _agent = wire_native_assignee(row.key)

      log = capture_log([level: :info], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      assert log =~ "provider build_prompt refused but native dispatch proceeds"
      refute log =~ "names a slug with no prompt_templates row"
    end
  end

  # ── which refusals are legitimate, and which only look it ─────────────────
  #
  # WRITTEN IN RESPONSE TO A SURVIVING MUTATION (stage 3). Deleting the
  # `when reason in @no_work_refusals` guard — so that EVERY provider refusal
  # is reported as `:no_work` — left the entire suite green. The whitelist
  # had a test, but it only asserted the list's CONTENTS; every end-to-end
  # case exercised the one reason that is on it, so nothing observed what
  # happens to a reason that is not. A wiring gap wearing a refusal's
  # clothes would have shipped labelled "deliberate silence", which is the
  # exact failure mode this task exists to remove, reintroduced one layer
  # up.
  #
  # `:no_build_prompt` is the reason that matters here and it cannot be used
  # as the fixture: `build_prompt_via_provider/2` folds it into `:legacy`
  # before the classifier sees it (pinned below). So the fixture is an
  # arbitrary reason no provider returns today, standing in for the next one
  # someone adds — which is the case the whitelist has to get right.
  describe "an unrecognised refusal is a gap, not deliberate silence" do
    setup :capture_native_dispatch

    test "a whitelisted reason is :no_work and an unlisted one is :render_gap" do
      chosen = responsibility_with_provider(build_prompt: {:error, :no_transcript_text})
      agent = wire_native_assignee(chosen.key)
      assert agent.id
      assert_dispatched(chosen)
      assert_receive {:captured_signal, chosen_signal}

      unlisted = responsibility_with_provider(build_prompt: {:error, :some_unlisted_refusal})

      # The SAME agent takes the second key — `role_assignments` is unique per
      # role, so a second `wire_native_assignee/1` would fail on the
      # constraint rather than on the thing under test. One assignee also
      # keeps the two envelopes comparable.
      wire_extra_responsibility(unlisted.key)
      assert_dispatched(unlisted)
      assert_receive {:captured_signal, unlisted_signal}

      # POSITIVE CONTROLS on both signals before anything is compared.
      assert chosen_signal.metadata.responsibility_key == chosen.key
      assert unlisted_signal.metadata.responsibility_key == unlisted.key
      refute Map.has_key?(chosen_signal.metadata, :prompt)
      refute Map.has_key?(unlisted_signal.metadata, :prompt)

      # THE ASSERTION THE MUTATION SURVIVED. Drop the guard and both sides
      # become `:no_work`, and this inequality prints the shared value.
      assert chosen_signal.metadata.prompt_status != unlisted_signal.metadata.prompt_status

      assert chosen_signal.metadata.prompt_status == :no_work
      assert chosen_signal.metadata.prompt_absence_reason == "no_transcript_text"

      assert unlisted_signal.metadata.prompt_status == :render_gap
      assert unlisted_signal.metadata.prompt_absence_reason == "some_unlisted_refusal"

      # The whitelist is what decides, so pin that it is the thing consulted
      # rather than a coincidence of these two fixtures.
      assert :no_transcript_text in Router.no_work_refusals()
      refute :some_unlisted_refusal in Router.no_work_refusals()
    end
  end

  # ── the external path, pinned UNCHANGED ───────────────────────────────────
  #
  # THE SCOPE FENCE, MADE FALSIFIABLE.
  #
  # `ExternalAgents.Dispatcher.legacy_messages/2` passes
  # `responsibility.default_prompt_template` — the slug STRING — straight
  # into `EEx.eval_string/2` and falls back to the literal on failure. That
  # module contains no reference to `PromptTemplates` at all, so an external
  # agent whose provider asks for the legacy render receives the message
  # `[%{role: "user", content: "tasks.triage.v1"}]`: the name of its prompt
  # instead of its prompt. This is the already-captured defect quoted in
  # `Providers.Meetings`' moduledoc, and it is GENERAL, not
  # meetings-specific.
  #
  # It is deliberately NOT fixed in this stage. Switching the external path
  # to a DB lookup changes the prompt every external agent receives, which
  # is a much larger blast radius than a native-path render gap, and it
  # needs its own e2e coverage. So the current behaviour is pinned here
  # instead: this test asserts the slug still comes back as a literal even
  # though a real seeded row for it now exists and the native path now
  # finds it.
  #
  # WHAT FAILURE LOOKS LIKE, AND WHY THAT IS THE POINT. The task that fixes
  # the external path deletes this test and replaces it with its inverse.
  # A green test here means "the asymmetry is still there on purpose"; a
  # red one means someone changed the external path without noticing they
  # had.
  describe "the external dispatch path still ships the slug, not the row" do
    setup do
      {:ok, _} = Application.ensure_all_started(:req)

      Application.put_env(
        :platform,
        :external_agents_dispatcher_req_client,
        Req.new(plug: {Req.Test, :prompt_outcome_external_test})
      )

      on_exit(fn ->
        Application.delete_env(:platform, :external_agents_dispatcher_req_client)
      end)

      test_pid = self()

      Req.Test.stub(:prompt_outcome_external_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:external_body, body})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
        })
      end)

      :ok
    end

    test "a default_prompt_template slug with a real row reaches the model as the slug" do
      slug = TaskTriage.template_slug()

      # The premise: the row EXISTS. Without this the test would pass on an
      # unseeded database for the wrong reason, and would stop being a
      # statement about the external path at all.
      template = PromptTemplates.get_template_by_slug(slug)
      assert template
      assert template.content =~ "propose a priority pass"

      agent = %{
        id: Ecto.UUID.generate(),
        slug: "promptoutcome-ext-#{System.unique_integer([:positive])}",
        kind: "external",
        endpoint_kind: "openai_compat",
        base_url: "https://api.example.test",
        model: "test-model",
        vault_key: nil,
        metadata: %{}
      }

      :ok = EphemeralCredentials.put(agent.id, "sk-test")
      on_exit(fn -> EphemeralCredentials.delete(agent.id) end)

      responsibility = %Responsibility{
        key: "tasks.triage",
        feature: "tasks",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 9 * * 1-5"},
        scope: "per_project",
        context_provided: [],
        output_contract: nil,
        default_prompt_template: slug,
        cost_profile: "high_freq_low_cost",
        enabled: true,
        metadata: %{}
      }

      assert {:ok, "ok"} = ExternalDispatcher.dispatch(responsibility, agent, %{})

      assert_receive {:external_body, raw_body}
      decoded = Jason.decode!(raw_body)

      assert decoded["messages"] == [%{"role" => "user", "content" => slug}]

      refute Enum.any?(decoded["messages"], &(&1["content"] =~ "propose a priority pass"))
    end
  end

  # ── which outcomes the provider layer can actually produce ────────────────
  #
  # MEASURED, NOT ASSUMED, and it contradicts the stage brief.
  #
  # The brief lists `{:error, :no_build_prompt}` as one of the shapes that
  # reaches the classifier. It does not. `build_prompt_via_provider/2` maps
  # it to `:legacy` BEFORE the classifier is called — deliberately, because
  # that error means "this key does not own its own prompt, use the legacy
  # template render", not "fail" — and it maps an unexpected return and a
  # raise to `:legacy` too.
  #
  # So of the five named outcomes, only THREE are reachable through the
  # dispatch path today: `{:rendered, _}`, `{:absent, :empty_render}`,
  # `{:absent, {:refused, reason}}` for reasons other than
  # `:no_build_prompt`, and `{:absent, :legacy}`. `{:absent, {:refused,
  # :no_build_prompt}}` and `{:absent, {:unexpected_shape, _}}` are
  # reachable only by a direct call. They are still classified, and still
  # pinned above, because a later stage needs somewhere to put them — but a
  # reader who assumes the enumeration describes live traffic would be
  # wrong, and stage 3's mapping table is written against exactly that
  # assumption.
  #
  # Un-collapsing the provider layer is NOT this stage's to do: it is
  # wire-visible on the OTHER path. `dispatch_external/5` aborts on
  # `{:error, _}` with failed telemetry, so letting `:no_build_prompt`
  # through as an error would stop every external agent whose provider asks
  # for the legacy render from dispatching at all.
  #
  # These two tests therefore pin the pre-collapse as it stands, so that the
  # stage which does un-collapse it gets a RED LINE TO FLIP and a pointer to
  # `dispatch_external/5`, rather than a silent behaviour change on a path
  # nobody was looking at.
  describe "the provider layer pre-collapses two of the five outcomes" do
    setup :capture_native_dispatch

    # WHAT FAILURE LOOKS LIKE: un-collapse `build_prompt_via_provider/2` and
    # the refusal warning appears while the `:legacy` debug line disappears,
    # so both the assert and the refute below go red naming
    # `:no_build_prompt` — which is the cue to check `dispatch_external/5`
    # in the same change.
    test "{:error, :no_build_prompt} arrives as :legacy, never as a refusal" do
      row = responsibility_with_provider(build_prompt: {:error, :no_build_prompt})
      _agent = wire_native_assignee(row.key)

      # :debug, not :info — the `:legacy` line for a feature that DOES have a
      # registered provider is a debug: a provider without `build_prompt/1`
      # is a known state, not a misconfiguration.
      Logger.put_module_level(Router, :debug)
      log = capture_log([level: :debug], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      # The `:legacy` line, and specifically the arm for a provider that IS
      # registered — the tell that the provider layer swallowed the reason
      # before the classifier could name it.
      assert log =~ "native signal carries no prompt key=#{row.key}"
      assert log =~ "ships no build_prompt/1"

      refute log =~ "provider build_prompt refused"
      refute log =~ "reason=:no_build_prompt"
    end

    test "an unreadable return arrives as :legacy, never as an unexpected shape" do
      row = responsibility_with_provider(build_prompt: "a bare string, not a result tuple")
      _agent = wire_native_assignee(row.key)

      Logger.put_module_level(Router, :debug)
      log = capture_log([level: :debug], fn -> assert_dispatched(row) end)

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == row.key
      refute Map.has_key?(signal.metadata, :prompt)

      # `build_prompt_via_provider/2` logs the unreadable shape itself and
      # then returns `:legacy`, so the classifier's own catch-all line is the
      # one that must NOT appear.
      assert log =~ "provider build_prompt returned unexpected shape"
      assert log =~ "native signal carries no prompt key=#{row.key}"
      refute log =~ "prompt outcome has an unrecognised shape"
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  # Shared by every describe that drives a real fire. Extracted rather than
  # copy-pasted per describe so a later change to the override seam cannot
  # leave one block behind still stubbing the old way — which would silently
  # dispatch into the real AgentResponder and time out on `assert_receive`
  # rather than fail on the thing under test.
  defp capture_native_dispatch(_context) do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    Application.put_env(:platform, :prompt_outcome_capture_pid, self())

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end

      Application.delete_env(:platform, :prompt_outcome_capture_pid)
    end)

    :ok
  end

  defp assert_dispatched(row) do
    assert {:ok, :dispatched} =
             Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()}, %{})
  end

  # A throwaway provider whose `build_prompt/1` returns exactly what the case
  # needs, bound through the supported override seam
  # (`:responsibility_provider_overrides`) rather than by name convention —
  # `Platform.Responsibilities.Providers` deliberately refuses to derive a
  # module from a feature string.
  defp responsibility_with_provider(opts) do
    build_prompt_result = Keyword.fetch!(opts, :build_prompt)
    template_slug = Keyword.get(opts, :default_prompt_template)
    feature = "promptoutcome_#{System.unique_integer([:positive])}"

    module =
      Module.concat([
        Platform.Responsibilities.Providers,
        "PromptOutcomeAdHoc#{System.unique_integer([:positive])}"
      ])

    Module.create(
      module,
      quote do
        @behaviour Platform.Responsibilities.Provider

        @impl true
        def register, do: []

        @impl true
        def gather_context(_r, _m), do: {:ok, %{}}

        @impl true
        def build_prompt(_ctx), do: unquote(Macro.escape(build_prompt_result))

        @impl true
        def handle_output(_r, _o), do: :ok

        @impl true
        def handle_output(_r, _o, _m), do: :ok
      end,
      Macro.Env.location(__ENV__)
    )

    put_provider_override(feature, module)

    create_responsibility!(%{
      key: "#{feature}.fire_#{System.unique_integer([:positive])}",
      feature: feature,
      trigger_kind: "cron",
      trigger_config: %{"expression" => "*/5 * * * *"},
      scope: "global",
      cost_profile: "low_freq_capable",
      default_prompt_template: template_slug
    })
  end

  # The production shape of the three keys this stage fixes: a real
  # responsibility row carrying a `default_prompt_template` slug, whose
  # feature has no provider registered, so `build_prompt_via_provider/2`
  # falls to `:legacy` and the template lookup is the only thing that can
  # produce a body.
  defp responsibility_without_provider(opts) do
    feature = "promptoutcome_notmpl_#{System.unique_integer([:positive])}"

    create_responsibility!(%{
      key: "#{feature}.fire_#{System.unique_integer([:positive])}",
      feature: feature,
      trigger_kind: "cron",
      trigger_config: %{"expression" => "*/5 * * * *"},
      scope: "global",
      cost_profile: "low_freq_capable",
      default_prompt_template: Keyword.get(opts, :default_prompt_template)
    })
  end

  defp create_responsibility!(attrs) do
    {:ok, row} = Responsibilities.create_responsibility(attrs)
    row
  end

  defp put_provider_override(feature, module) do
    current = Application.get_env(:platform, :responsibility_provider_overrides, %{})

    Application.put_env(
      :platform,
      :responsibility_provider_overrides,
      Map.put(current, feature, module)
    )

    on_exit(fn ->
      remaining = Application.get_env(:platform, :responsibility_provider_overrides, %{})

      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        Map.delete(remaining, feature)
      )
    end)
  end

  # `kind: "native"` with no runtime_type takes `dispatch_native/6`, which is
  # the path under test; the CaptureDispatcher stands in for AgentResponder so
  # no chat space or runtime presence is needed.
  defp wire_native_assignee(responsibility_key) do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: role_key,
      responsibility_key: responsibility_key
    })
    |> Repo.insert!()

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "prompt-outcome-fed-#{System.unique_integer([:positive])}",
        name: "Prompt Outcome Assignee",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  # Give the role an ADDITIONAL responsibility without creating a second
  # agent: `role_assignments` is unique on `role_key`, so a test that needs
  # two keys dispatched has to route them both to the one assignee.
  defp wire_extra_responsibility(responsibility_key) do
    %Platform.Roles.RoleResponsibility{}
    |> Platform.Roles.RoleResponsibility.changeset(%{
      role_key: "historian",
      responsibility_key: responsibility_key
    })
    |> Repo.insert!()
  end
end
