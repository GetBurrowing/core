defmodule Platform.Audit.EventOwnerOrgTest do
  @moduledoc """
  ADR 0040 — actor_org_id and actor_type "federated_user" coverage on Audit.Event.

  Architect-finding-2 in ADR 0040: audit_events does NOT use the dual-key
  pattern from runtime_events. It extends its existing actor_id/actor_type
  model with a single actor_org_id column. These tests pin that contract.
  """

  use Platform.DataCase, async: true

  alias Platform.Audit.Event
  alias Platform.Repo

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides \\ %{}) do
    %{
      event_type: "test.event",
      actor_type: "system",
      action: "test_action"
    }
    |> Map.merge(overrides)
  end

  describe "actor_types/0" do
    test "returns the canonical enum values including federated_user and anonymous" do
      assert Event.actor_types() == ~w(system user agent anonymous federated_user)
    end
  end

  describe "actor_org_id field" do
    test "changeset accepts actor_org_id" do
      org_id = Ecto.UUID.generate()
      changeset = Event.changeset(%Event{}, valid_attrs(%{actor_org_id: org_id}))

      assert changeset.valid?
      assert get_field(changeset, :actor_org_id) == org_id
    end

    test "changeset accepts NULL actor_org_id (legacy / intra-org events)" do
      changeset = Event.changeset(%Event{}, valid_attrs())

      assert changeset.valid?
      assert is_nil(get_field(changeset, :actor_org_id))
    end

    test "actor_org_id persists to the database" do
      org_id = Ecto.UUID.generate()

      {:ok, event} =
        %Event{}
        |> Event.changeset(valid_attrs(%{actor_org_id: org_id}))
        |> Repo.insert()

      reloaded = Repo.get!(Event, event.id)
      assert reloaded.actor_org_id == org_id
    end
  end

  describe "actor_type validation (extension to add 'federated_user')" do
    test "accepts the new 'federated_user' value" do
      changeset = Event.changeset(%Event{}, valid_attrs(%{actor_type: "federated_user"}))
      assert changeset.valid?
    end

    test "still accepts pre-existing actor types: system, user, agent" do
      for t <- ~w(system user agent) do
        changeset = Event.changeset(%Event{}, valid_attrs(%{actor_type: t}))
        assert changeset.valid?, "Expected actor_type=#{t} to be valid"
      end
    end

    test "rejects unknown actor_type values" do
      changeset = Event.changeset(%Event{}, valid_attrs(%{actor_type: "made_up"}))

      refute changeset.valid?
      assert %{actor_type: [_message]} = errors_on(changeset)
    end

    test "federated_user actor_type with actor_id treated as opaque handle (no FK enforced)" do
      # When actor_type="federated_user", actor_id is a pseudonymous handle
      # from Platform.Federation.OwnerHandle, NOT a users.id. The schema does
      # NOT enforce a FK constraint, allowing the handle to be opaque.
      pseudonymous_handle = Ecto.UUID.generate()

      changeset =
        Event.changeset(
          %Event{},
          valid_attrs(%{
            actor_type: "federated_user",
            actor_id: pseudonymous_handle,
            actor_org_id: Ecto.UUID.generate()
          })
        )

      assert changeset.valid?
    end
  end

  describe "joint actor + org modeling" do
    test "intra-org event: actor_id set, actor_org_id NULL is acceptable" do
      changeset =
        Event.changeset(
          %Event{},
          valid_attrs(%{actor_type: "user", actor_id: Ecto.UUID.generate()})
        )

      assert changeset.valid?
    end

    test "federated event: actor_id (handle) and actor_org_id together" do
      changeset =
        Event.changeset(
          %Event{},
          valid_attrs(%{
            actor_type: "federated_user",
            actor_id: Ecto.UUID.generate(),
            actor_org_id: Ecto.UUID.generate()
          })
        )

      assert changeset.valid?
    end
  end
end
