defmodule Platform.MixSupportPrepareTestDatabaseTest do
  @moduledoc """
  Guards `Platform.MixSupport.prepare_test_database/1` against the swallow it
  replaced: one `rescue _ -> :noop catch :exit, _ -> :noop` wrapped BOTH the
  create and the migrate step, so `:econnrefused` became `:noop` and the suite
  ran anyway against a database that was never there.

  ## Why an injected runner

  The failure is injected by passing a stub in place of `&Mix.Task.run/2`. No
  database is stopped, no subprocess is spawned, no environment is manipulated
  — and, decisively, the two steps become INDEPENDENTLY testable, which is the
  property that matters, because they shared a single rescue. A fixture with a
  HEALTHY database exercises only the happy path and passes against a rescue
  that still eats everything; that is the vacuous version of this file.

  ## Assertion discipline

  Every failure case asserts the three components of the swallowed reason —
  the STEP name, the DATABASE name, the MESSAGE — independently, and asserts
  that the call still propagates. Nothing here asserts on a test or failure
  count: `N tests, N failures` is the SYMPTOM the outage produced, not the
  property under test, and a guard bonded to it would bounce whenever a test
  is added anywhere in the suite. No full formatted line is asserted verbatim,
  so rewording the message does not bounce this file either.

  The output assertions come BEFORE the propagation assertion on purpose: under
  the swallow, both are wrong, and the interesting one is that the cause never
  reached stderr. `outcome/1` classifies the call instead of asserting on it so
  that ordering is possible inside one `capture_io/2`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @database "platform_test_guard_fixture"
  @refused "tcp connect (localhost:5432): connection refused - :econnrefused"

  setup do
    original = System.get_env("PLATFORM_TEST_DATABASE")
    System.put_env("PLATFORM_TEST_DATABASE", @database)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("PLATFORM_TEST_DATABASE")
        value -> System.put_env("PLATFORM_TEST_DATABASE", value)
      end
    end)

    :ok
  end

  # Runs the helper and CLASSIFIES what came back, rather than asserting, so the
  # captured stderr can be asserted on first.
  defp outcome(runner) do
    {:returned, Platform.MixSupport.prepare_test_database(runner)}
  rescue
    error -> {:raised, error}
  catch
    :exit, reason -> {:exited, reason}
  end

  describe "a failing ecto.create" do
    test "reports the step, the database and the connection-refused reason, and raises" do
      runner = fn "ecto.create", _args ->
        raise DBConnection.ConnectionError, @refused
      end

      output =
        capture_io(:stderr, fn -> send(self(), {:outcome, outcome(runner)}) end)

      assert output =~ "ecto.create"
      assert output =~ @database
      assert output =~ "connection refused - :econnrefused"

      assert_received {:outcome, {:raised, %DBConnection.ConnectionError{}}}
    end

    test "reports and propagates an exit, the shape Mix.raise produces and production observed" do
      runner = fn "ecto.create", _args ->
        exit({:shutdown, {:failed_to_start_child, :db, @refused}})
      end

      output =
        capture_io(:stderr, fn -> send(self(), {:outcome, outcome(runner)}) end)

      assert output =~ "ecto.create"
      assert output =~ @database
      assert output =~ "connection refused - :econnrefused"

      assert_received {:outcome, {:exited, {:shutdown, {:failed_to_start_child, :db, @refused}}}}
    end
  end

  describe "a failing ecto.migrate after a successful ecto.create" do
    test "names ecto.migrate as the failing step and does not misattribute it to ecto.create" do
      runner = fn
        "ecto.create", _args -> :ok
        "ecto.migrate", _args -> raise RuntimeError, "relation \"schema_migrations\" is locked"
      end

      output =
        capture_io(:stderr, fn -> send(self(), {:outcome, outcome(runner)}) end)

      assert output =~ "ecto.migrate"
      refute output =~ "ecto.create"
      assert output =~ @database
      assert output =~ "relation \"schema_migrations\" is locked"

      assert_received {:outcome, {:raised, %RuntimeError{}}}
    end
  end

  describe "the healthy path" do
    test "runs both steps in order, returns normally, and says nothing on stderr" do
      test_pid = self()

      runner = fn task, args ->
        send(test_pid, {:ran, task, args})
        :ok
      end

      output =
        capture_io(:stderr, fn ->
          assert Platform.MixSupport.prepare_test_database(runner) == :ok
        end)

      assert output == ""
      assert_received {:ran, "ecto.create", ["--quiet"]}
      assert_received {:ran, "ecto.migrate", ["--quiet"]}
    end
  end
end
