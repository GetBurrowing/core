defmodule Platform.Regression.LivekitConfigAsyncGuardTest do
  use ExUnit.Case, async: true

  alias Platform.LivekitConfigAsyncGuard, as: Guard

  test "no asynchronous test module writes global LiveKit configuration" do
    sources =
      Path.wildcard(Path.expand("../../**/*.{ex,exs}", __DIR__))
      |> Enum.map(&{&1, File.read!(&1)})

    assert length(sources) > 1000, "source corpus unexpectedly empty or truncated"
    offenders = Guard.violations(sources)

    assert offenders == [],
           "async LiveKit config writers (module, file, line): #{inspect(offenders)}"
  end

  for {label, call} <- [
        {"direct", "Application.put_env(:platform, :livekit, [])"},
        {"multiline", "Application.put_env(\n :platform,\n :livekit,\n [])"},
        {"delete", "Application.delete_env(:platform, :livekit)"},
        {"aliased", "alias Application, as: App\n App.put_env(:platform, :livekit, [])"},
        {"bulk", "Application.put_all_env(platform: [livekit: []])"},
        {"imported", "import Application\n put_env(:platform, :livekit, [])"}
      ] do
    test "rejects #{label} asynchronous writes" do
      source =
        "defmodule Unsafe do\nuse ExUnit.Case, async: true\ndef change do\n#{unquote(call)}\nend\nend"

      assert [%{module: Unsafe, file: "fixture.exs", line: 1}] =
               Guard.violations([{"fixture.exs", source}])
    end
  end

  test "follows remote, aliased and imported helpers transitively across files" do
    helper =
      "defmodule Writer do\ndef change, do: Application.put_env(:platform, :livekit, [])\nend"

    bridge = "defmodule Bridge do\ndef change, do: Writer.change()\nend"

    for call <- ["Bridge.change()", "alias Bridge, as: B\nB.change()", "import Bridge\nchange()"] do
      caller =
        "defmodule Unsafe do\nuse ExUnit.Case, async: true\ndef change_config do\n#{call}\nend\nend"

      assert [%{module: Unsafe, file: "caller.exs", line: 1}] =
               Guard.violations([
                 {"helper.ex", helper},
                 {"bridge.ex", bridge},
                 {"caller.exs", caller}
               ])
    end
  end

  test "allows synchronous writers, async readers and misleading documentation" do
    source = ~S'''
    defmodule SafeWriter do
      @moduledoc "use ExUnit.Case, async: true"
      use ExUnit.Case, async: false
      def change, do: Application.put_env(:platform, :livekit, [])
    end
    defmodule Reader do
      use ExUnit.Case, async: true
      # Application.put_env(:platform, :livekit, [])
      @moduledoc "Application.delete_env(:platform, :livekit)"
      def example, do: "Application.put_env(:platform, :livekit, [])"
      def read, do: Application.get_env(:platform, :livekit)
    end
    '''

    assert Guard.violations([{"safe.exs", source}]) == []
  end
end
