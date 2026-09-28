defmodule Platform.Responsibilities.GoalCadenceTest do
  @moduledoc """
  The admin-only, audited goal-heartbeat cadence write, and the upsert
  marker that lets it survive a redeploy (task 01a0e882 stage 2).
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures, only: [fabrikam_org_id: 0]

  alias Platform.Accounts.User
  alias Platform.Audit.Event
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.{GoalCadence, Responsibility}
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @key "agents.goal_heartbeat"
  @event_type "platform.responsibilities.cadence_changed"
  @topic "responsibilities:changed"

  # A throwaway provider for the unmarked CONTROL row in the redeploy test.
  defmodule ControlProvider do
    @moduledoc false
    def register do
      [
        %{
          key: "cadencetest.control",
          feature: "cadencetest",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 * * * *"},
          scope: "global",
          context_provided: [],
          output_contract: %{},
          default_prompt_template: "",
          cost_profile: "low_freq_capable"
        }
      ]
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        # Not an @example.com address: that domain derives admin on its own,
        # which would make a refusal pass for the wrong reason.
        email: "cadence-#{n}@example.com",
        name: "Cadence #{n}",
        oidc_sub: "oidc-cadence-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam_org_id(), role: role})
    |> Repo.insert!()

    user
  end

  defp admin! do
    admin = user!("admin")
    assert Tenancy.fabrikam_admin?(admin)
    admin
  end

  defp member! do
    member = user!("member")
    refute Tenancy.fabrikam_admin?(member)
    member
  end

  defp row!, do: Repo.get_by!(Responsibility, key: @key)

  defp audit_count do
    Repo.aggregate(from(e in Event, where: e.event_type == @event_type), :count)
  end

  defp audit_rows do
    Repo.all(from(e in Event, where: e.event_type == @event_type, order_by: e.inserted_at))
  end

  defp in_cron_bucket?(id), do: id in Enum.map(Responsibilities.get_by_trigger(:cron), & &1.id)

  # The row exists at its registered default: hourly, enabled, no marker.
  setup do
    {:ok, [row]} = Responsibilities.register(AgentsGoalHeartbeat)
    {:ok, row} = Responsibilities.update_responsibility(row, %{enabled: true})
    assert row.trigger_config == %{"expression" => "0 * * * *"}
    %{row: row}
  end

  # ── GoalCadence ──────────────────────────────────────────────────────────

  describe "GoalCadence round trip" do
    test "from_row(apply(to_trigger(c, h))) returns c for all five cadences; daily keeps its hour",
         %{row: row} do
      for {cadence, hour} <- [
            hourly: nil,
            every_4h: nil,
            twice_daily: nil,
            daily: 16,
            daily: 0,
            daily: 23,
            off: nil
          ] do
        assert {:ok, attrs} = GoalCadence.to_trigger(cadence, hour, row.trigger_config)
        changeset = Responsibility.changeset(row, attrs)
        assert changeset.valid?, "#{cadence} produced an invalid row"

        applied = Ecto.Changeset.apply_changes(changeset)

        expected_hour = if cadence == :daily, do: hour
        assert GoalCadence.from_row(applied) == %{cadence: cadence, hour_utc: expected_hour}

        if cadence != :off do
          assert applied.trigger_config["operator_set"] == true
          assert applied.trigger_config["cadence"] == Atom.to_string(cadence)
        end
      end
    end

    test "hours outside 0..23 are refused" do
      for bad <- [24, -1, nil, "9", 9.0] do
        assert GoalCadence.to_trigger(:daily, bad) == {:error, :bad_hour}
      end

      assert GoalCadence.to_trigger(:weekly, nil) == {:error, :bad_cadence}
    end

    test "an expression no cadence produces reads :custom and labels by name only" do
      row = %Responsibility{enabled: true, trigger_config: %{"expression" => "*/5 * * * *"}}
      assert GoalCadence.from_row(row) == %{cadence: :custom, hour_utc: nil}
      assert GoalCadence.label(:custom) == "Custom schedule"

      for c <- GoalCadence.cadences() do
        refute GoalCadence.label(c) =~ "*"
      end
    end
  end

  # ── authorisation ────────────────────────────────────────────────────────

  describe "admin only" do
    test "a non-admin root member is refused and nothing changes; an admin's identical call succeeds" do
      member = member!()
      before = row!()
      audits = audit_count()

      assert Responsibilities.set_goal_heartbeat_cadence(member, :daily, hour_utc: 16) ==
               {:error, :forbidden}

      after_row = row!()
      assert after_row.trigger_config == before.trigger_config
      assert after_row.enabled == before.enabled
      assert after_row.updated_at == before.updated_at
      assert audit_count() == audits

      # POSITIVE CONTROL: the same call from an admin goes through.
      admin = admin!()

      assert {:ok, %Responsibility{}} =
               Responsibilities.set_goal_heartbeat_cadence(admin, :daily, hour_utc: 16)

      assert row!().trigger_config["expression"] == "0 16 * * *"
      assert audit_count() == audits + 1
    end

    test "nil and non-user actors are refused" do
      assert Responsibilities.set_goal_heartbeat_cadence(nil, :off) == {:error, :forbidden}
      assert Responsibilities.set_goal_heartbeat_cadence(%{}, :off) == {:error, :forbidden}
      assert row!().enabled == true
    end
  end

  # ── audit ────────────────────────────────────────────────────────────────

  describe "audit" do
    test "hourly -> daily@16 writes one row with old and new values; a repeat writes none" do
      admin = admin!()
      audits = audit_count()
      row = row!()

      assert {:ok, updated} =
               Responsibilities.set_goal_heartbeat_cadence(admin, :daily, hour_utc: 16)

      assert audit_count() == audits + 1
      [event] = Enum.take(audit_rows(), -1)

      assert event.actor_id == admin.id
      assert event.actor_type == "user"
      assert event.action == "responsibility_cadence_changed"
      assert event.resource_type == "responsibility"
      assert event.resource_id == row.id

      assert event.metadata == %{
               "key" => @key,
               "old_cadence" => "hourly",
               "new_cadence" => "daily",
               "old_hour_utc" => nil,
               "new_hour_utc" => 16,
               "old_expression" => "0 * * * *",
               "new_expression" => "0 16 * * *",
               "old_enabled" => true,
               "new_enabled" => true
             }

      assert updated.trigger_config == %{
               "expression" => "0 16 * * *",
               "cadence" => "daily",
               "hour_utc" => 16,
               "operator_set" => true
             }

      stamp = row!().updated_at

      assert Responsibilities.set_goal_heartbeat_cadence(admin, :daily, hour_utc: 16) ==
               {:ok, :unchanged}

      assert audit_count() == audits + 1
      assert row!().updated_at == stamp
    end

    test "a bad hour from an admin writes nothing" do
      admin = admin!()
      audits = audit_count()

      assert Responsibilities.set_goal_heartbeat_cadence(admin, :daily, hour_utc: 24) ==
               {:error, :bad_hour}

      assert audit_count() == audits
      assert row!().trigger_config == %{"expression" => "0 * * * *"}
    end
  end

  # ── off ──────────────────────────────────────────────────────────────────

  describe "off" do
    test "off disables the row, keeps the expression and the prompt; hourly turns it back on" do
      admin = admin!()
      before = row!()
      assert in_cron_bucket?(before.id)

      assert {:ok, off} = Responsibilities.set_goal_heartbeat_cadence(admin, :off)
      assert off.enabled == false
      assert off.trigger_config == before.trigger_config
      assert off.default_prompt_template == before.default_prompt_template
      refute in_cron_bucket?(before.id)
      assert Responsibilities.goal_heartbeat_cadence() == %{cadence: :off, hour_utc: nil}

      [event] = Enum.take(audit_rows(), -1)
      assert event.metadata["old_enabled"] == true
      assert event.metadata["new_enabled"] == false
      assert event.metadata["new_cadence"] == "off"

      assert Responsibilities.set_goal_heartbeat_cadence(admin, :off) == {:ok, :unchanged}

      assert {:ok, on} = Responsibilities.set_goal_heartbeat_cadence(admin, :hourly)
      assert on.enabled == true
      assert in_cron_bucket?(before.id)
      assert Responsibilities.goal_heartbeat_cadence() == %{cadence: :hourly, hour_utc: nil}
    end
  end

  # ── survives redeploy ────────────────────────────────────────────────────

  describe "survives register/1" do
    test "an operator-set schedule survives the boot upsert; an unmarked control row is replaced" do
      admin = admin!()

      {:ok, [control]} = Responsibilities.register(ControlProvider)

      {:ok, _} =
        Responsibilities.update_responsibility(control, %{
          trigger_config: %{"expression" => "0 5 * * *"}
        })

      assert {:ok, _} = Responsibilities.set_goal_heartbeat_cadence(admin, :daily, hour_utc: 16)

      # Drift a declared, non-marker field so the test also sees the rest of
      # the row still refreshing from source on the marked row.
      {:ok, _} = Responsibilities.update_responsibility(row!(), %{metadata: %{"drifted" => true}})

      assert {:ok, [_]} = Responsibilities.register(AgentsGoalHeartbeat)
      assert {:ok, [_]} = Responsibilities.register(ControlProvider)

      heartbeat = row!()
      assert heartbeat.trigger_config["expression"] == "0 16 * * *"
      assert heartbeat.trigger_config["operator_set"] == true
      assert heartbeat.enabled == true
      assert heartbeat.metadata["task"] == "01a0b491"
      refute Map.has_key?(heartbeat.metadata, "drifted")

      # CONTROL: no marker, so the declared value wins exactly as before.
      assert Repo.get_by!(Responsibility, key: "cadencetest.control").trigger_config ==
               %{"expression" => "0 * * * *"}
    end

    test "off survives register/1 too" do
      admin = admin!()
      assert {:ok, _} = Responsibilities.set_goal_heartbeat_cadence(admin, :off)
      assert {:ok, [_]} = Responsibilities.register(AgentsGoalHeartbeat)
      assert row!().enabled == false
    end

    test "the on_conflict set list names exactly @upsert_replace_fields" do
      {declared, set} = Responsibilities.upsert_replace_fields()
      assert declared == set
    end
  end

  # ── broadcast ────────────────────────────────────────────────────────────

  describe "broadcast" do
    test "a real change broadcasts once; unchanged and forbidden calls broadcast nothing" do
      admin = admin!()
      member = member!()
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, @topic)

      assert {:ok, %Responsibility{}} =
               Responsibilities.set_goal_heartbeat_cadence(admin, :every_4h)

      assert_receive {:responsibilities_changed, :cron}
      refute_receive {:responsibilities_changed, :cron}, 50

      assert {:ok, :unchanged} = Responsibilities.set_goal_heartbeat_cadence(admin, :every_4h)
      refute_receive {:responsibilities_changed, :cron}, 50

      assert {:error, :forbidden} = Responsibilities.set_goal_heartbeat_cadence(member, :off)
      refute_receive {:responsibilities_changed, :cron}, 50
    end
  end
end
