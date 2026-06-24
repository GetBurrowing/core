defmodule Platform.ResponsibilitiesTest do
  @moduledoc """
  Context-level tests for `Platform.Responsibilities` — CRUD plus the
  `upsert_by_key/1` idempotency / operator-state-preservation
  contract (ADR-0041 M1 stage 2).
  """
  use Platform.DataCase, async: true

  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility

  defp unique_key(prefix \\ "feat") do
    "#{prefix}.verb_#{System.unique_integer([:positive])}"
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: unique_key(),
        feature: "feat",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "*/5 * * * *"},
        scope: "global",
        context_provided: [],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "feat.summarize.v1",
        cost_profile: "low_freq_capable"
      },
      overrides
    )
  end

  describe "list_responsibilities/0" do
    test "returns rows ordered ascending by key" do
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "alpha.one"}))
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "charlie.three"}))
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: "bravo.two"}))

      keys = Responsibilities.list_responsibilities() |> Enum.map(& &1.key)

      # Filter to just the three we inserted (other tests may have leaked).
      ours = Enum.filter(keys, &(&1 in ["alpha.one", "bravo.two", "charlie.three"]))
      assert ours == ["alpha.one", "bravo.two", "charlie.three"]
    end

    test "returns empty list when no rows exist" do
      assert Responsibilities.list_responsibilities() == []
    end
  end

  describe "list_by_feature/1" do
    test "returns only rows for the named feature, ordered by key" do
      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{feature: "meetings", key: "meetings.b"})
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{feature: "meetings", key: "meetings.a"})
        )

      {:ok, _} =
        Responsibilities.create_responsibility(base_attrs(%{feature: "chat", key: "chat.z"}))

      meetings = Responsibilities.list_by_feature("meetings")
      assert Enum.map(meetings, & &1.feature) |> Enum.uniq() == ["meetings"]
      assert Enum.map(meetings, & &1.key) == ["meetings.a", "meetings.b"]
    end

    test "empty list on miss" do
      assert Responsibilities.list_by_feature("does_not_exist") == []
    end
  end

  describe "get/1" do
    test "returns the row by id" do
      {:ok, %Responsibility{id: id} = inserted} =
        Responsibilities.create_responsibility(base_attrs())

      assert %Responsibility{id: ^id, key: key} = Responsibilities.get(id)
      assert key == inserted.key
    end

    test "returns nil when id is unknown" do
      assert Responsibilities.get("00000000-0000-0000-0000-000000000000") == nil
    end
  end

  describe "get_by_key/1" do
    test "returns the matching row" do
      key = unique_key("meetings")
      {:ok, _} = Responsibilities.create_responsibility(base_attrs(%{key: key}))

      assert %Responsibility{key: ^key} = Responsibilities.get_by_key(key)
    end

    test "returns nil when no row carries that key" do
      assert Responsibilities.get_by_key("nope.miss") == nil
    end
  end

  describe "get_by_trigger/1" do
    test "filters by trigger_kind AND by enabled=true" do
      enabled_key = unique_key("ev")
      disabled_key = unique_key("ev")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: enabled_key,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "demo:enabled"}
          })
        )

      {:ok, disabled} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: disabled_key,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "demo:disabled"}
          })
        )

      {:ok, _} = Responsibilities.update_responsibility(disabled, %{enabled: false})

      rows = Responsibilities.get_by_trigger(:event_topic)
      keys = Enum.map(rows, & &1.key)

      assert enabled_key in keys, "expected the enabled row to come back"
      refute disabled_key in keys, "disabled rows must be filtered out"
    end

    test "filters out other trigger_kinds" do
      cron_key = unique_key("cron")
      webhook_key = unique_key("wh")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: cron_key,
            trigger_kind: "cron",
            trigger_config: %{"expression" => "0 0 * * *"}
          })
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: webhook_key,
            trigger_kind: "webhook",
            trigger_config: %{"path" => "/hooks/x"}
          })
        )

      cron_rows = Responsibilities.get_by_trigger(:cron) |> Enum.map(& &1.key)
      webhook_rows = Responsibilities.get_by_trigger(:webhook) |> Enum.map(& &1.key)
      chat_rows = Responsibilities.get_by_trigger(:chat_pattern) |> Enum.map(& &1.key)

      assert cron_key in cron_rows
      refute webhook_key in cron_rows
      assert webhook_key in webhook_rows
      assert chat_rows == []
    end

    test "returns rows ordered ascending by key" do
      a = unique_key("alpha")
      b = unique_key("bravo")

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: b,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "x:b"}
          })
        )

      {:ok, _} =
        Responsibilities.create_responsibility(
          base_attrs(%{
            key: a,
            trigger_kind: "event_topic",
            trigger_config: %{"topic" => "x:a"}
          })
        )

      keys = Responsibilities.get_by_trigger(:event_topic) |> Enum.map(& &1.key)
      ours = Enum.filter(keys, &(&1 in [a, b]))
      assert ours == Enum.sort([a, b])
    end
  end

  describe "create_responsibility/1" do
    test "happy path returns {:ok, %Responsibility{}}" do
      attrs = base_attrs()
      assert {:ok, %Responsibility{} = row} = Responsibilities.create_responsibility(attrs)
      assert row.key == attrs.key
      # Default for `enabled` is true at the schema level.
      assert row.enabled == true
      # Default for `metadata` is the empty map.
      assert row.metadata == %{}
    end

    test "invalid attrs return {:error, %Ecto.Changeset{}}" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.create_responsibility(base_attrs(%{key: "Bad.KEY"}))

      assert Keyword.has_key?(cs.errors, :key)
    end
  end

  describe "update_responsibility/2" do
    test "applies changes via changeset" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())

      assert {:ok, updated} =
               Responsibilities.update_responsibility(row, %{
                 default_prompt_template: "feat.summarize.v2"
               })

      assert updated.id == row.id
      assert updated.default_prompt_template == "feat.summarize.v2"
    end

    test "rejects invalid changes" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())

      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.update_responsibility(row, %{trigger_kind: "bogus"})

      assert Keyword.has_key?(cs.errors, :trigger_kind)
    end
  end

  describe "delete_responsibility/1" do
    test "removes the row" do
      {:ok, row} = Responsibilities.create_responsibility(base_attrs())
      assert {:ok, _} = Responsibilities.delete_responsibility(row)
      assert Responsibilities.get(row.id) == nil
    end
  end

  describe "upsert_by_key/1" do
    test "first call inserts; second call updates declared content fields in place" do
      key = unique_key("up")

      attrs_v1 =
        base_attrs(%{
          key: key,
          cost_profile: "low_freq_capable",
          default_prompt_template: "feat.summarize.v1",
          metadata: %{"version" => 1}
        })

      assert {:ok, v1} = Responsibilities.upsert_by_key(attrs_v1)
      assert v1.key == key
      assert v1.cost_profile == "low_freq_capable"
      original_id = v1.id

      attrs_v2 =
        base_attrs(%{
          key: key,
          cost_profile: "high_freq_low_cost",
          default_prompt_template: "feat.summarize.v2",
          metadata: %{"version" => 2}
        })

      assert {:ok, v2} = Responsibilities.upsert_by_key(attrs_v2)

      # Same row — original id preserved.
      assert v2.id == original_id

      # Declared content fields updated to the latest declaration.
      assert v2.cost_profile == "high_freq_low_cost"
      assert v2.default_prompt_template == "feat.summarize.v2"
      assert v2.metadata == %{"version" => 2}

      # And the DB really only has one row for this key.
      assert length(
               Responsibilities.list_responsibilities()
               |> Enum.filter(&(&1.key == key))
             ) == 1
    end

    test "preserves operator-set enabled=false across upserts" do
      key = unique_key("up")

      # Provider's first registration — defaults to enabled=true.
      assert {:ok, v1} = Responsibilities.upsert_by_key(base_attrs(%{key: key}))
      assert v1.enabled == true

      # Operator kills the responsibility via the admin path.
      {:ok, _disabled} = Responsibilities.update_responsibility(v1, %{enabled: false})
      assert Responsibilities.get_by_key(key).enabled == false

      # Provider re-registers at next boot — declared attrs would normally
      # come back with enabled=true (the schema default), but upsert must
      # NOT clobber the operator's kill-switch.
      attrs_v2 = base_attrs(%{key: key, cost_profile: "high_freq_low_cost"})
      assert {:ok, v2} = Responsibilities.upsert_by_key(attrs_v2)

      assert v2.id == v1.id
      assert v2.enabled == false, "operator-set enabled=false must survive boot-time upsert"

      # Declared content still updated though.
      assert v2.cost_profile == "high_freq_low_cost"
    end

    test "invalid attrs return {:error, changeset} without raising" do
      assert {:error, %Ecto.Changeset{} = cs} =
               Responsibilities.upsert_by_key(base_attrs(%{key: "Bad.KEY"}))

      assert Keyword.has_key?(cs.errors, :key)
    end
  end
end
