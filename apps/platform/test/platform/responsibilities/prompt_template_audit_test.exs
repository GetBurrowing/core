defmodule Platform.Responsibilities.PromptTemplateAuditTest do
  @moduledoc """
  Registration-time prompt-template audit (task `01a0a74d` stage 3).

  ## What is under test, and what is NOT

  `router.ex` ALREADY distinguishes `{:template_missing, slug}` from
  `{:template_blank, slug}` from `:legacy`, already warns naming the slug,
  already stamps `prompt_status: :render_gap` on the native envelope, and
  the external path already aborts before the model call. None of that is
  re-tested here and none of it was re-plumbed. What was missing is that
  every bit of it is per-FIRE: a cron key that fires at 23:00 UTC announces
  its own breakage once a day, after the agent already got an empty prompt.
  The slug is declared in source, so the miss is knowable at REGISTRATION
  with zero fires. That — and only that — is what these tests pin.

  ## PREDICTION, STATED BEFORE THE RUN

  With `AbsentSlugProvider` registered, the orphan list is exactly
  `["definitely.not.a.real.slug.v1"]`, and these tests are green only with
  the `audit_prompt_templates/1` call present in `Registry.do_register/1`.

  ## THE MUTATION THAT PROVES IT

  Delete the `audit_prompt_templates(oks)` call from
  `Registry.do_register/1` (leave everything else) and this file must go
  RED. Recorded in the stage-3 test evidence as a failure SET by NAME, not
  as a count: a count is producible from an expectation, whereas a list of
  test names has to come out of a run.

  ## The not-a-raise assertion is the load-bearing one

  `do_register/1` is documented boot-safe and deliberately carries no
  try/rescue around `register_all/1`. An audit that raised would take the
  application down on every environment whose `prompt_templates` rows are
  not seeded yet — i.e. every fresh test database before `seed_defaults/0`.
  `Process.alive?/1` after registering a provider naming a slug that
  certainly does not exist is the assertion that stops a later reader
  "fixing" the `Logger.error` into a raise.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]

  alias Platform.Responsibilities
  alias Platform.Responsibilities.Registry

  @absent_slug "definitely.not.a.real.slug.v1"

  defmodule AbsentSlugProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "prompttemplateaudittest.absent",
          feature: "prompt_template_audit_test",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 23 * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: "definitely.not.a.real.slug.v1",
          cost_profile: "low_freq_capable"
        }
      ]
    end

    @impl true
    def gather_context(_resp, _ctx), do: {:ok, %{}}

    @impl true
    def handle_output(_resp, _output), do: :ok
  end

  defmodule NoTemplateProvider do
    @moduledoc false
    @behaviour Platform.Responsibilities.Provider

    @impl true
    def register do
      [
        %{
          key: "prompttemplateaudittest.legacy",
          feature: "prompt_template_audit_test",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 23 * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{"summary" => "string"},
          default_prompt_template: nil,
          cost_profile: "low_freq_capable"
        }
      ]
    end

    @impl true
    def gather_context(_resp, _ctx), do: {:ok, %{}}

    @impl true
    def handle_output(_resp, _output), do: :ok
  end

  defp start_registry(opts) do
    name = :"#{__MODULE__}.Reg#{System.unique_integer([:positive])}"
    pid = start_supervised!({Registry, Keyword.put(opts, :name, name)})
    {pid, name}
  end

  defp attach_orphan_handler do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:platform, :responsibilities, :prompt_template_orphan],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {:orphan_event, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  describe "Registry surfaces a declared-but-unbacked slug at registration" do
    test "telemetry fires naming the exact slug, status/0 reports it, and the Registry lives" do
      ref = attach_orphan_handler()

      {{pid, name}, _log} = with_log(fn -> start_registry(providers: [AbsentSlugProvider]) end)

      # (i) the telemetry event carries the exact slug.
      assert_received {:orphan_event, ^ref, %{count: 1}, metadata}
      assert metadata.slug == @absent_slug
      assert metadata.key == "prompttemplateaudittest.absent"
      assert metadata.verdict == "missing"
      assert metadata.trigger_kind == "cron"

      # (ii) status/0's orphan key contains it — and the PREDICTION is that
      # the list is exactly this one slug, not merely that it is a member.
      status = Registry.status(name)
      assert Enum.map(status.prompt_template_orphans, & &1.slug) == [@absent_slug]
      assert [%{status: {:missing, @absent_slug}}] = status.prompt_template_orphans

      # (iii) NOT A RAISE. The audit reports; it does not take the boot path
      # down. Do not "fix" the Logger.error in registry.ex into a raise.
      assert Process.alive?(pid)

      # Positive control on the surrounding machinery: the row really did
      # register. An audit that fired because registration itself failed
      # would satisfy the orphan assertions by being broken.
      assert %{ok: [row], errors: []} = Map.take(status, [:ok, :errors])
      assert row.key == "prompttemplateaudittest.absent"
    end

    test "a responsibility declaring NO template is not an orphan" do
      # `:none` is a legacy-path key, a different and deliberate state.
      # Folding it into the orphan list would make that list permanently
      # non-empty and therefore permanently ignored — which is the failure
      # mode this whole stage exists to avoid.
      {{pid, name}, _log} = with_log(fn -> start_registry(providers: [NoTemplateProvider]) end)

      assert Process.alive?(pid)
      assert Registry.status(name).prompt_template_orphans == []

      # Control: the provider DID register, so the empty orphan list is a
      # fact about the verdict and not about an enumeration that found
      # nothing.
      assert [%{key: "prompttemplateaudittest.legacy"}] = Registry.status(name).ok
    end

    test "the Logger.error names the slug and the remedy" do
      log =
        capture_log(fn ->
          {_pid, _name} = start_registry(providers: [AbsentSlugProvider])
        end)

      assert log =~ "prompt_template_missing"
      assert log =~ @absent_slug
      assert log =~ "prompttemplateaudittest.absent"
      # The remedy is load-bearing, not prose: seed_defaults/0 is
      # INSERT-only, so editing the hardcoded default list alone does not
      # put the row on a live install. A reader who does only that half
      # gets a green test suite and an unchanged production install.
      assert log =~ "seed_defaults/0 is INSERT-only"
    end
  end

  describe "Responsibilities.prompt_template_audit/1" do
    test "returns the router's own taxonomy per key, sorted by key" do
      resolved = %Responsibilities.Responsibility{
        key: "aaa.resolved",
        trigger_kind: "cron",
        default_prompt_template: "memory.dreaming.v1"
      }

      missing = %Responsibilities.Responsibility{
        key: "zzz.missing",
        trigger_kind: "event",
        default_prompt_template: @absent_slug
      }

      none = %Responsibilities.Responsibility{
        key: "mmm.none",
        trigger_kind: "cron",
        default_prompt_template: nil
      }

      Platform.Orchestration.PromptTemplates.seed_defaults()

      entries = Responsibilities.prompt_template_audit([resolved, missing, none])

      assert Enum.map(entries, & &1.key) == ["aaa.resolved", "mmm.none", "zzz.missing"]
      assert Enum.map(entries, & &1.status) == [:resolved, :none, {:missing, @absent_slug}]

      # Only the two defect verdicts are orphans.
      assert Enum.map(Responsibilities.prompt_template_orphans(entries), & &1.key) ==
               ["zzz.missing"]
    end

    test "a row whose stored body is blank reads BLANK, not RESOLVED" do
      slug = "prompttemplateaudittest.blank.v1"

      # Inserted through the schema rather than `create_template/1` ON
      # PURPOSE: `PromptTemplate.changeset/2` runs `validate_required` on
      # `:content`, which trims, so a whitespace-only body is UNREACHABLE
      # through the public write path. The blank verdict therefore only ever
      # describes a row that got there another way — a hand-edit in psql, an
      # import, a migration that wrote "". Fixturing it through the changeset
      # is impossible; fixturing it through the struct is the honest
      # reproduction of the state the verdict exists to name.
      Platform.Repo.insert!(%Platform.Orchestration.PromptTemplate{
        slug: slug,
        name: "blank body fixture",
        description: "fixture for the blank verdict",
        content: "   \n  ",
        variables: []
      })

      entry = %Responsibilities.Responsibility{
        key: "prompttemplateaudittest.blankbody",
        trigger_kind: "cron",
        default_prompt_template: slug
      }

      assert [%{status: {:blank, ^slug}}] = Responsibilities.prompt_template_audit([entry])
    end
  end

  describe "mix responsibilities.prompt_audit" do
    alias Mix.Tasks.Responsibilities.PromptAudit

    # THE EXIT RULE IS THE DELIVERABLE, so it is asserted directly rather
    # than inferred from printed text. A text assertion on a runbook is not
    # an assertion of its effect.
    test "a CRON key with a missing template is a failing entry" do
      entries = [
        %{key: "k", trigger_kind: "cron", slug: @absent_slug, status: {:missing, @absent_slug}}
      ]

      assert [%{key: "k"}] = PromptAudit.failing_entries(entries)
    end

    test "a CRON key with a blank template is a failing entry" do
      entries = [%{key: "k", trigger_kind: "cron", slug: "s", status: {:blank, "s"}}]
      assert [%{key: "k"}] = PromptAudit.failing_entries(entries)
    end

    test "an EVENT key with a missing template is printed but does NOT fail the run" do
      # This is `meetings.summarize.v1`'s case and it is the spec behaving
      # correctly, not a hole. Its trigger is `event` (`meeting_finished`),
      # so a human just held the meeting; it degrades to a legacy fallback
      # MFA rather than to an empty prompt. DO NOT widen the rule to catch
      # it — losing the distinction between "fires unattended on a clock"
      # and "fires behind a human" removes the reason to have a rule.
      entries = [
        %{
          key: "meetings.summarize",
          trigger_kind: "event",
          slug: "meetings.summarize.v1",
          status: {:missing, "meetings.summarize.v1"}
        }
      ]

      assert PromptAudit.failing_entries(entries) == []

      # ...and it is still VISIBLE. A rule that exits 0 and also hides the
      # row would be indistinguishable from not checking.
      report = PromptAudit.format_report(entries)
      assert report =~ "meetings.summarize.v1"
      assert report =~ "MISSING"
      assert report =~ "event"
    end

    test "a CRON key that names no template at all does not fail the run" do
      entries = [%{key: "k", trigger_kind: "cron", slug: nil, status: :none}]
      assert PromptAudit.failing_entries(entries) == []
      assert PromptAudit.format_report(entries) =~ "(none)"
    end

    test "the report renders one row per key with the verdict and a summary count" do
      entries = [
        %{key: "b.key", trigger_kind: "cron", slug: "b.v1", status: :resolved},
        %{key: "a.key", trigger_kind: "event", slug: "a.v1", status: {:missing, "a.v1"}}
      ]

      report = PromptAudit.format_report(entries)

      # Sorted by key, so a.key precedes b.key regardless of input order.
      assert :binary.match(report, "a.key") < :binary.match(report, "b.key")

      # Every trigger value is separated from the slug beside it. Measured
      # on test-host at 3ab3b019 before this was pinned: a 12-wide TRIGGER column
      # rendered `chat_patterndesign.brand_check.v1`, because `chat_pattern`
      # is exactly 12 characters. The widest real trigger value is the one
      # that breaks a column sized to fit it.
      widest =
        PromptAudit.format_report([
          %{key: "k", trigger_kind: "chat_pattern", slug: "s.v1", status: :resolved}
        ])

      refute widest =~ "chat_patterns.v1"
      assert widest =~ "chat_pattern  s.v1"
      assert report =~ "2 responsibilities · 1 resolved · 1 missing · 0 blank"
    end
  end
end
