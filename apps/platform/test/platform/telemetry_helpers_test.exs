defmodule Platform.TelemetryHelpersTest do
  use ExUnit.Case, async: true

  alias Platform.TelemetryHelpers

  @event [:platform, :telemetry_helpers_test, :probe]

  defp attached?(id), do: Enum.any?(:telemetry.list_handlers(@event), &(&1.id == id))

  describe "attach_scoped/4 with a {key, value} discriminator" do
    test "forwards an emission whose metadata carries the value" do
      TelemetryHelpers.attach_scoped(@event, {:stack_id, "a"}, self())

      :telemetry.execute(@event, %{count: 1}, %{stack_id: "a"})

      assert_receive {:telemetry, @event, %{count: 1}, %{stack_id: "a"}}
    end

    test "does not forward an emission for a different value" do
      TelemetryHelpers.attach_scoped(@event, {:stack_id, "a"}, self())

      :telemetry.execute(@event, %{count: 1}, %{stack_id: "b"})

      refute_receive {:telemetry, _, _, _}, 50
    end

    test "does not forward an emission whose metadata lacks the key" do
      TelemetryHelpers.attach_scoped(@event, {:stack_id, "a"}, self())

      :telemetry.execute(@event, %{count: 1}, %{other: "a"})

      refute_receive {:telemetry, _, _, _}, 50
    end
  end

  describe "attach_scoped/4 with a list of events" do
    test "forwards each listed event under the same discriminator" do
      other = [:platform, :telemetry_helpers_test, :other]
      TelemetryHelpers.attach_scoped([@event, other], {:id, 1}, self())

      :telemetry.execute(@event, %{}, %{id: 1})
      :telemetry.execute(other, %{}, %{id: 1})
      :telemetry.execute(other, %{}, %{id: 2})

      assert_receive {:telemetry, @event, %{}, %{id: 1}}
      assert_receive {:telemetry, ^other, %{}, %{id: 1}}
      refute_receive {:telemetry, _, _, _}, 50
    end
  end

  describe "attach_scoped/4 with a fun discriminator" do
    test "forwards only emissions the fun accepts" do
      TelemetryHelpers.attach_scoped(@event, fn meta -> meta[:n] > 1 end, self(), tag: :probe)

      :telemetry.execute(@event, %{}, %{n: 2})
      assert_receive {:probe, @event, %{}, %{n: 2}}

      :telemetry.execute(@event, %{}, %{n: 1})
      refute_receive {:probe, _, _, _}, 50
    end

    test "a raising fun is forwarded as :discriminator_raised and the handler stays attached" do
      id =
        TelemetryHelpers.attach_scoped(@event, fn _meta -> raise "boom" end, self())

      :telemetry.execute(@event, %{}, %{n: 1})

      assert_receive {:telemetry, :discriminator_raised, @event, %RuntimeError{message: "boom"}}
      assert attached?(id)
    end
  end

  describe "attach_scoped/4 with the :caller discriminator" do
    test "forwards from the test process and from Task children, not from a bare spawn" do
      TelemetryHelpers.attach_scoped(@event, :caller, self())

      :telemetry.execute(@event, %{}, %{from: :test})
      assert_receive {:telemetry, @event, %{}, %{from: :test}}

      Task.async(fn -> :telemetry.execute(@event, %{}, %{from: :task}) end) |> Task.await()
      assert_receive {:telemetry, @event, %{}, %{from: :task}}

      {pid, ref} = spawn_monitor(fn -> :telemetry.execute(@event, %{}, %{from: :spawn}) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      refute_receive {:telemetry, _, _, _}, 50
    end
  end

  describe "attach_scoped/4 handler lifecycle" do
    setup do
      test_pid = self()
      mine = TelemetryHelpers.scoped_prefix() <> inspect(test_pid)

      # Registered BEFORE the attach, so ExUnit's LIFO on_exit order runs it
      # AFTER the helper's own detach. The on_exit process has no access to
      # the test's mailbox, so it finds the handler by the pid baked into
      # the id instead of by the exact id.
      on_exit(fn ->
        leaked = Enum.filter(:telemetry.list_handlers(@event), &String.starts_with?(&1.id, mine))
        assert leaked == [], "handler(s) survived the test: #{inspect(Enum.map(leaked, & &1.id))}"
      end)

      {:ok, id: TelemetryHelpers.attach_scoped(@event, {:k, :v}, test_pid)}
    end

    test "is listed during the test and gone after it exits", %{id: id} do
      assert attached?(id)
    end

    test "handler id starts with scoped_prefix/0", %{id: id} do
      assert String.starts_with?(id, TelemetryHelpers.scoped_prefix())
      assert TelemetryHelpers.scoped_prefix() == "telemetry-helpers-scoped-"
      assert String.contains?(id, inspect(self()))
    end
  end
end
