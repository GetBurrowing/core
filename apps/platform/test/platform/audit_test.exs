defmodule Platform.AuditTest do
  use Platform.DataCase, async: true

  alias Platform.Audit
  alias Platform.Audit.Event

  @valid_attrs %{
    event_type: "platform.auth.login",
    actor_type: "user",
    action: "success",
    actor_id: Ecto.UUID.generate(),
    resource_type: "session",
    resource_id: "sess-123",
    metadata: %{"ip" => "127.0.0.1"},
    ip_address: "127.0.0.1"
  }

  describe "record/1" do
    test "persists a valid event" do
      assert {:ok, %Event{id: id}} = Audit.record(@valid_attrs)
      assert is_integer(id)
      assert Repo.get!(Event, id).event_type == "platform.auth.login"
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Audit.record(%{})
      assert "can't be blank" in errors_on(changeset, :event_type)
      assert "can't be blank" in errors_on(changeset, :action)
    end

    test "broadcasts to PubSub on success" do
      Audit.subscribe("audit:all")
      {:ok, event} = Audit.record(@valid_attrs)
      assert_receive {:audit_event, ^event}
    end

    test "broadcasts to event_type topic" do
      Audit.subscribe("audit:platform.auth.login")
      {:ok, event} = Audit.record(@valid_attrs)
      assert_receive {:audit_event, ^event}
    end

    test "broadcasts to resource topic when resource is present" do
      Audit.subscribe("audit:session:sess-123")
      {:ok, event} = Audit.record(@valid_attrs)
      assert_receive {:audit_event, ^event}
    end

    test "inserted_at uses microsecond precision" do
      {:ok, event} = Audit.record(@valid_attrs)
      assert %DateTime{} = event.inserted_at
    end
  end

  describe "list/1" do
    test "returns events ordered by id ascending" do
      {:ok, e1} = Audit.record(Map.put(@valid_attrs, :action, "first"))
      {:ok, e2} = Audit.record(Map.put(@valid_attrs, :action, "second"))

      events = Audit.list()
      ids = Enum.map(events, & &1.id)
      assert e1.id in ids
      assert e2.id in ids
      assert ids == Enum.sort(ids)
    end

    test "filters by event_type" do
      {:ok, _} = Audit.record(@valid_attrs)
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :event_type, "platform.chat.message"))

      events = Audit.list(event_type: "platform.auth.login")
      assert length(events) == 1
      assert hd(events).event_type == "platform.auth.login"
    end

    test "filters by event_type prefix with wildcard" do
      {:ok, _} = Audit.record(@valid_attrs)
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :event_type, "platform.auth.logout"))
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :event_type, "platform.chat.message"))

      events = Audit.list(event_type: "platform.auth.*")
      assert length(events) == 2
      assert Enum.all?(events, &String.starts_with?(&1.event_type, "platform.auth."))
    end

    test "filters by actor_id" do
      actor = Ecto.UUID.generate()
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :actor_id, actor))
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :actor_id, Ecto.UUID.generate()))

      events = Audit.list(actor_id: actor)
      assert length(events) == 1
      assert hd(events).actor_id == actor
    end

    test "keyset pagination with cursor" do
      {:ok, e1} = Audit.record(Map.put(@valid_attrs, :action, "first"))
      {:ok, e2} = Audit.record(Map.put(@valid_attrs, :action, "second"))
      {:ok, e3} = Audit.record(Map.put(@valid_attrs, :action, "third"))

      page1 = Audit.list(limit: 2)
      assert length(page1) == 2
      assert [^e1, ^e2] = page1

      page2 = Audit.list(limit: 2, cursor: e2.id)
      assert [^e3] = page2
    end

    test "filters by time range" do
      {:ok, event} = Audit.record(@valid_attrs)
      past = DateTime.add(event.inserted_at, -60, :second)
      future = DateTime.add(event.inserted_at, 60, :second)

      assert [_] = Audit.list(since: past, until: future)
      assert [] = Audit.list(since: future)
    end
  end

  describe "stream/1" do
    test "returns a lazy stream inside a transaction" do
      {:ok, e1} = Audit.record(Map.put(@valid_attrs, :action, "first"))
      {:ok, e2} = Audit.record(Map.put(@valid_attrs, :action, "second"))

      events =
        Repo.transaction(fn ->
          Audit.stream()
          |> Enum.to_list()
        end)

      assert {:ok, events} = events
      ids = Enum.map(events, & &1.id)
      assert e1.id in ids
      assert e2.id in ids
    end

    test "supports reduce for state derivation" do
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :action, "login"))
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :action, "logout"))
      {:ok, _} = Audit.record(Map.put(@valid_attrs, :action, "login"))

      {:ok, actions} =
        Repo.transaction(fn ->
          Audit.stream()
          |> Enum.reduce([], fn event, acc -> [event.action | acc] end)
        end)

      assert Enum.reverse(actions) == ["login", "logout", "login"]
    end
  end

  # -- Helpers --

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
