defmodule Platform.CodeMode.RuntimeTest do
  @moduledoc "Task 01a114a8 stage 2: script semantics with no tools bound."

  use ExUnit.Case, async: true

  alias Platform.CodeMode.Limits
  alias Platform.CodeMode.Run

  test "eval returns the completion value (the ci.yml image smoke line)" do
    assert {:ok, 2} = Run.eval("1+1")
  end

  test "a script that returns runs as an async function body" do
    assert {:ok, 42} = Run.eval("const x = 2; return x * 21")
  end

  test "top-level await and inputs" do
    assert {:ok, 42} = Run.eval("await Promise.resolve(inputs.n + 1)", inputs: %{n: 41})
  end

  test "a syntax error is a script_error naming the line" do
    assert {:error, "script_error", message} = Run.eval("this is not js")
    assert message =~ "SyntaxError"
  end

  test "an unserialisable result is a script_error" do
    assert {:error, "script_error", message} = Run.eval("10n")
    assert message =~ "not JSON-serialisable"
  end

  test "a promise that never settles is reported, not waited on" do
    assert {:error, "script_error", message} = Run.eval("await new Promise(() => {})")
    assert message =~ "never settles"
  end

  test "deep recursion is a script_error" do
    assert {:error, "script_error", message} = Run.eval("function f(){ return f() + 1 } f()")
    assert message =~ "call stack"
  end

  test "a result over max_result_bytes is output_limit" do
    assert {:error, "output_limit", _} = Run.eval("'x'.repeat(200000)")
  end

  test "logs are captured and capped" do
    limits = %{Limits.get() | log_bytes: 10}

    assert {:ok, %{logs: ["hello"], logs_truncated: true}} =
             Platform.CodeMode.Runtime.run("console.log('hello'); console.log('world!'); 1", nil,
               limits: limits
             )
  end

  test "with no host every suite call is forbidden" do
    assert {:error, "forbidden", _} = Run.eval("suite.task_get({})")
  end
end
