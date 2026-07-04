defmodule Platform.Responsibilities.Handlers.TaskWeeklyReviewTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.TaskWeeklyReview` —
  the Triage Officer bundle's registration-only placeholder that fills
  out the `tasks.weekly_review` responsibility row so
  `Platform.Roles.Seeds` no longer references a key with no matching
  `responsibilities` row.

  Runtime lands in a follow-up ticket; this test file locks the spec
  shape + no-op behaviour so downstream stages catch drift.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.TaskWeeklyReview
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: TaskWeeklyReview.key(),
      feature: "tasks",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 16 * * 5"},
      scope: "per_project",
      context_provided: ["org_identity", "recent_journal"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = TaskWeeklyReview.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "tasks.weekly_review"
      assert spec.feature == "tasks"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 16 * * 5"}
      assert spec.scope == "per_project"
      assert spec.context_provided == ["org_identity", "recent_journal"]
      assert spec.default_prompt_template == "tasks.weekly_review.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = TaskWeeklyReview.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "output_contract flags followups as optional via trailing ?" do
      [spec] = TaskWeeklyReview.register()

      assert spec.output_contract["review"] == "string"
      assert spec.output_contract["followups"] == "list[string]?"
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = TaskWeeklyReview.register()

      assert spec.metadata["owner"] == "platform.tasks"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "triage_officer"
    end
  end

  describe "gather_context/2" do
    test "returns missing? slots for org_identity + recent_journal" do
      assert {:ok, ctx} = TaskWeeklyReview.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :org_identity)
      assert Map.has_key?(ctx, :recent_journal)
      assert ctx.org_identity.missing? == true
      assert ctx.recent_journal.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   TaskWeeklyReview.handle_output(
                     responsibility(),
                     %{"review" => "This week we shipped X.", "followups" => []},
                     %{kind: :cron}
                   )
        end)

      assert log =~ "[tasks.weekly_review]"
      assert log =~ "placeholder handler"
      assert log =~ "tasks.weekly_review.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok =
                   TaskWeeklyReview.handle_output(
                     responsibility(),
                     %{"review" => "Weekly digest.", "followups" => []}
                   )
        end)

      assert log =~ "[tasks.weekly_review]"
      assert log =~ "placeholder handler"
    end
  end

  describe "key/0 and template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = TaskWeeklyReview.register()
      assert TaskWeeklyReview.key() == spec.key
      assert TaskWeeklyReview.key() == "tasks.weekly_review"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = TaskWeeklyReview.register()
      assert TaskWeeklyReview.template_slug() == spec.default_prompt_template
      assert TaskWeeklyReview.template_slug() == "tasks.weekly_review.v1"
    end
  end
end
