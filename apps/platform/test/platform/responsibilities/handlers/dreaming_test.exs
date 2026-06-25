defmodule Platform.Responsibilities.Handlers.DreamingTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.Dreaming` — the M8
  stage 2 provider that owns the `memory.dreaming` responsibility row
  and upserts parsed LLM output into the org context file
  `org/page/memory.md`.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.Handlers.Dreaming
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: Dreaming.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 3 * * *"},
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "declares one spec with the canonical key + cron expression" do
      [spec] = Dreaming.register()

      assert spec.key == "memory.dreaming"
      assert spec.feature == "memory"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 3 * * *"}
      assert spec.scope == "per_org"
      assert spec.context_provided == ["recent_journal", "org_identity"]
      assert spec.metadata["target_file_key"] == "org/page/memory.md"
    end
  end

  describe "handle_output/3" do
    test "accepts %{\"memory_body\" => string} and upserts the file" do
      body = "# Org Memory\n\nLearned: prefer short summaries."

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => body},
                 %{kind: :cron}
               )

      file = OrgContext.get_file(Dreaming.memory_file_key())
      assert file
      assert file.content == body
    end

    test "accepts %{\"summary\" => ...} alias too" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"summary" => "alt-key payload"},
                 %{kind: :cron}
               )

      file = OrgContext.get_file(Dreaming.memory_file_key())
      assert file.content == "alt-key payload"
    end

    test "accepts a bare string" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 "bare body",
                 %{kind: :cron}
               )

      assert OrgContext.get_file(Dreaming.memory_file_key()).content == "bare body"
    end

    test "rejects malformed output" do
      assert {:error, :invalid_output_shape} =
               Dreaming.handle_output(responsibility(), %{}, %{kind: :cron})

      assert {:error, :invalid_output_shape} =
               Dreaming.handle_output(responsibility(), %{"memory_body" => ""}, %{kind: :cron})
    end

    test "upsert bumps version on repeat fire (idempotent re-runs)" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "v1 body"},
                 %{kind: :cron}
               )

      v1 = OrgContext.get_file(Dreaming.memory_file_key()).version

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "v2 body"},
                 %{kind: :cron}
               )

      v2 = OrgContext.get_file(Dreaming.memory_file_key()).version
      assert v2 > v1
    end
  end

  describe "gather_context/2" do
    test "merges :recent_journal and :org_identity slots" do
      assert {:ok, ctx} = Dreaming.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :recent_journal)
      assert Map.has_key?(ctx, :org_identity)
    end
  end
end
