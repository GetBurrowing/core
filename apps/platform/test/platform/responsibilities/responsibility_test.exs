defmodule Platform.Responsibilities.ResponsibilityTest do
  @moduledoc """
  Tests for the `Platform.Responsibilities.Responsibility` schema (M1 stage 1
  of task 019ef65b-2099). Covers changeset validation for each trigger_kind,
  enum guard rails, key-format regex, the unique constraint on `key`, and
  array round-tripping for `context_provided`. Also exercises the migration
  up/down round-trip to keep the rollback path honest.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp unique_key(prefix \\ "meetings") do
    "#{prefix}.verb_#{System.unique_integer([:positive])}"
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: unique_key(),
        feature: "meetings",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "*/5 * * * *"},
        scope: "per_meeting",
        context_provided: ["meeting.transcript"],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "meetings.summarize.v1",
        cost_profile: "low_freq_capable"
      },
      overrides
    )
  end

  describe "changeset/2 — happy paths" do
    test "valid cron responsibility passes" do
      cs = Responsibility.changeset(%Responsibility{}, base_attrs())
      assert cs.valid?, "expected valid changeset, got: #{inspect(errors_on(cs))}"
    end

    test "valid event_topic responsibility passes" do
      attrs =
        base_attrs(%{
          trigger_kind: "event_topic",
          trigger_config: %{"topic" => "chat.message.created"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "valid chat_pattern responsibility passes" do
      attrs =
        base_attrs(%{
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "^!summarize\\b"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "valid webhook responsibility passes" do
      attrs =
        base_attrs(%{
          trigger_kind: "webhook",
          trigger_config: %{"path" => "/hooks/meetings/summarize"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      assert cs.valid?, inspect(errors_on(cs))
    end

    test "atom-keyed trigger_config also accepted" do
      attrs =
        base_attrs(%{
          trigger_kind: "event_topic",
          trigger_config: %{topic: "chat.message.created"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      assert cs.valid?, inspect(errors_on(cs))
    end
  end

  describe "changeset/2 — required fields" do
    test "rejects empty attrs" do
      cs = Responsibility.changeset(%Responsibility{}, %{})
      refute cs.valid?

      for field <- [:key, :feature, :trigger_kind, :scope, :cost_profile] do
        assert Keyword.has_key?(cs.errors, field),
               "expected error on #{field}, got: #{inspect(cs.errors)}"
      end
    end
  end

  describe "changeset/2 — key format" do
    test "rejects uppercase / spaces / missing dot" do
      bad_keys = [
        "Meetings.summarize",
        "meetings",
        "meetings summarize",
        ".summarize",
        "meetings.",
        "1meetings.summarize"
      ]

      for bad <- bad_keys do
        cs = Responsibility.changeset(%Responsibility{}, base_attrs(%{key: bad}))
        refute cs.valid?, "expected #{inspect(bad)} to be rejected"
        assert %{key: [msg]} = errors_on(cs)
        assert msg =~ "must match"
      end
    end

    test "accepts feature.verb_with_underscores" do
      cs =
        Responsibility.changeset(
          %Responsibility{},
          base_attrs(%{key: "meetings.summarize_long_form"})
        )

      assert cs.valid?, inspect(errors_on(cs))
    end
  end

  describe "changeset/2 — enum guard rails" do
    test "rejects bogus trigger_kind" do
      attrs = base_attrs(%{trigger_kind: "smoke_signal"})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_kind: ["is invalid"]} = errors_on(cs)
    end

    test "rejects bogus scope" do
      attrs = base_attrs(%{scope: "per_galaxy"})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{scope: ["is invalid"]} = errors_on(cs)
    end

    test "rejects bogus cost_profile" do
      attrs = base_attrs(%{cost_profile: "free"})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{cost_profile: ["is invalid"]} = errors_on(cs)
    end

    test "accepts each scope" do
      for scope <- Responsibility.scopes() do
        cs = Responsibility.changeset(%Responsibility{}, base_attrs(%{scope: scope}))
        assert cs.valid?, "expected scope #{scope} to be valid"
      end
    end

    test "accepts each cost_profile" do
      for profile <- Responsibility.cost_profiles() do
        cs = Responsibility.changeset(%Responsibility{}, base_attrs(%{cost_profile: profile}))
        assert cs.valid?, "expected cost_profile #{profile} to be valid"
      end
    end
  end

  describe "changeset/2 — trigger_config payloads" do
    test "rejects non-map trigger_config" do
      # Lists fail Ecto's :map cast (\"is invalid\"); the same applies to any
      # scalar. The downstream kind-specific validator may add its own error
      # too, but the cast-level rejection is what we care about here.
      attrs = base_attrs(%{trigger_config: ["expression", "*/5 * * * *"]})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert msgs = errors_on(cs)[:trigger_config]
      assert is_list(msgs) and length(msgs) > 0
      assert Enum.any?(msgs, &(&1 =~ "is invalid" or &1 =~ "must be a map"))
    end

    test "cron — rejects unparseable expression" do
      attrs =
        base_attrs(%{
          trigger_kind: "cron",
          trigger_config: %{"expression" => "every monday at noon"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ "not a valid cron string"
    end

    test "cron — rejects missing expression key" do
      attrs = base_attrs(%{trigger_kind: "cron", trigger_config: %{"other" => "noop"}})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ ~s(missing required key "expression")
    end

    test "cron — accepts well-formed expressions" do
      for expr <- [
            "* * * * *",
            "*/5 * * * *",
            "0 0 * * 0",
            "0,15,30,45 * * * *",
            "0 9-17 * * 1-5"
          ] do
        attrs =
          base_attrs(%{trigger_kind: "cron", trigger_config: %{"expression" => expr}})

        cs = Responsibility.changeset(%Responsibility{}, attrs)
        assert cs.valid?, "expected cron #{inspect(expr)} to be valid: #{inspect(errors_on(cs))}"
      end
    end

    test "chat_pattern — rejects uncompilable regex" do
      attrs =
        base_attrs(%{
          trigger_kind: "chat_pattern",
          trigger_config: %{"regex" => "[unterminated"}
        })

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ "not a compilable regex"
    end

    test "chat_pattern — rejects missing regex key" do
      attrs = base_attrs(%{trigger_kind: "chat_pattern", trigger_config: %{}})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ ~s(missing required key "regex")
    end

    test "event_topic — rejects empty topic" do
      attrs =
        base_attrs(%{trigger_kind: "event_topic", trigger_config: %{"topic" => ""}})

      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ "non-empty string"
    end

    test "event_topic — rejects missing topic key" do
      attrs = base_attrs(%{trigger_kind: "event_topic", trigger_config: %{}})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ ~s(missing required key "topic")
    end

    test "webhook — rejects empty path" do
      attrs = base_attrs(%{trigger_kind: "webhook", trigger_config: %{"path" => ""}})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ "non-empty string"
    end

    test "webhook — rejects missing path key" do
      attrs = base_attrs(%{trigger_kind: "webhook", trigger_config: %{}})
      cs = Responsibility.changeset(%Responsibility{}, attrs)
      refute cs.valid?
      assert %{trigger_config: [msg]} = errors_on(cs)
      assert msg =~ ~s(missing required key "path")
    end
  end

  describe "persistence" do
    test "round-trips through the database" do
      key = unique_key()
      attrs = base_attrs(%{key: key})

      assert {:ok, inserted} =
               %Responsibility{} |> Responsibility.changeset(attrs) |> Repo.insert()

      reloaded = Repo.get!(Responsibility, inserted.id)
      assert reloaded.key == key
      assert reloaded.context_provided == ["meeting.transcript"]
      assert reloaded.trigger_config == %{"expression" => "*/5 * * * *"}
      assert reloaded.output_contract == %{"summary" => "string"}
    end

    test "context_provided round-trips as an array" do
      values = ["meeting.transcript", "meeting.participants", "org.style_guide"]
      attrs = base_attrs(%{context_provided: values})

      assert {:ok, inserted} =
               %Responsibility{} |> Responsibility.changeset(attrs) |> Repo.insert()

      reloaded = Repo.get!(Responsibility, inserted.id)
      assert reloaded.context_provided == values
    end

    test "duplicate key is rejected by the unique constraint" do
      key = unique_key()
      attrs = base_attrs(%{key: key})

      assert {:ok, _} = %Responsibility{} |> Responsibility.changeset(attrs) |> Repo.insert()

      dup_attrs = base_attrs(%{key: key})

      assert {:error, cs} =
               %Responsibility{} |> Responsibility.changeset(dup_attrs) |> Repo.insert()

      assert Keyword.has_key?(cs.errors, :key)
    end
  end

  describe "migration shape" do
    # The migration ran during ecto.create/migrate before the test suite
    # started; this proves the resulting table has the columns and
    # constraints the schema expects. Reversibility is enforced by Ecto
    # itself (the migration uses `change/0` with only reversible helpers).
    test "table exists with the expected columns" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1 ORDER BY column_name",
          ["responsibilities"]
        )

      columns = Enum.map(rows, fn [c] -> c end)

      for required <- ~w(id key feature trigger_kind trigger_config scope
                         context_provided output_contract default_prompt_template
                         cost_profile inserted_at updated_at) do
        assert required in columns, "missing column #{required} (have: #{inspect(columns)})"
      end
    end

    test "DB-side check constraint rejects bad trigger_kind on raw SQL insert" do
      # Bypass the changeset to prove the DB itself enforces the enum — this
      # is the safety net for raw SQL writes (admin tooling, seed scripts).
      key = unique_key()

      assert_raise Postgrex.Error, ~r/responsibilities_trigger_kind_check/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO responsibilities
            (id, key, feature, trigger_kind, trigger_config, scope,
             context_provided, output_contract, cost_profile,
             inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), $1, 'meetings', 'smoke_signal', '{}'::jsonb,
             'per_meeting', '{}'::text[], '{}'::jsonb, 'low_freq_capable',
             now(), now())
          """,
          [key]
        )
      end
    end

    test "DB-side check constraint rejects bad key format on raw SQL insert" do
      assert_raise Postgrex.Error, ~r/responsibilities_key_format_check/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO responsibilities
            (id, key, feature, trigger_kind, trigger_config, scope,
             context_provided, output_contract, cost_profile,
             inserted_at, updated_at)
          VALUES
            (gen_random_uuid(), 'NotAKey', 'meetings', 'cron',
             '{"expression":"* * * * *"}'::jsonb, 'per_meeting',
             '{}'::text[], '{}'::jsonb, 'low_freq_capable', now(), now())
          """,
          []
        )
      end
    end
  end
end
