defmodule Platform.MixSupport do
  @moduledoc """
  Helpers invoked from `mix.exs` aliases.

  Lives here rather than under `lib/` on purpose: the `test` alias runs before
  the application is guaranteed to be compiled (`ecto.create` is what triggers
  `app.config`/compile), so a module under `lib/` may not be loaded when the
  alias needs it. `mix.exs` is evaluated at boot in every mix VM, so this module
  is always in memory.
  """

  @doc """
  Creates and migrates the test database, reporting and re-raising on failure.

  Each step is wrapped independently so the failing step is named. The only
  absorbed failure is a `Mix.Error` saying the database already exists, which is
  the benign concurrent-run race. Everything else is reported on stderr and
  propagated, so a run that could not prepare its database aborts instead of
  producing hundreds of misleading setup failures.
  """
  def prepare_test_database(runner \\ &Mix.Task.run/2) do
    run_step(runner, "ecto.create")
    # Computed after `ecto.create`, which compiles and configures the app.
    run_step(runner, "ecto.migrate", extension_migration_args())
    :ok
  end

  @doc """
  The `--migrations-path` flags that make `mix ecto.migrate` run core's
  migrations AND every build-time module's (ADR 0055 section 6), core's
  first. `[]` when no module has a migrations path, so the command is then
  exactly `mix ecto.migrate` over core's default path.

  Call it only after the app is compiled and configured (after
  `ecto.create`): it reads `Platform.Extensions`, which lives under `lib/`.
  """
  def extension_migration_args do
    paths =
      if Code.ensure_loaded?(Platform.Extensions),
        do: Platform.Extensions.migrations_paths(),
        else: []

    case paths do
      [] -> []
      paths -> Enum.flat_map(["priv/repo/migrations" | paths], &["--migrations-path", &1])
    end
  end

  defp run_step(runner, task, extra_args \\ []) do
    runner.(task, ["--quiet" | extra_args])
    :ok
  rescue
    error in [Mix.Error] ->
      message = Exception.message(error)

      if message =~ ~r/already exists/i do
        :ok
      else
        report(task, message)
        reraise(error, __STACKTRACE__)
      end

    error ->
      report(task, Exception.message(error))
      reraise(error, __STACKTRACE__)
  catch
    :exit, reason ->
      report(task, inspect(reason))
      exit(reason)
  end

  defp report(task, message) do
    database = System.get_env("PLATFORM_TEST_DATABASE", "platform_test")

    Mix.shell().error(
      "mix #{task} failed for database #{database}: #{message} " <>
        "- aborting the test run (the suite was NOT run)"
    )
  end
end

defmodule Platform.MixProject do
  use Mix.Project

  def project do
    [
      app: :platform,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: module_definition_opts(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Platform.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssl, :inets]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Experiment surface for the Elixir 1.20 `module_definition` compiler option
  # (task 01a0fd73). SUITE_MODULE_DEFINITION selects the variant:
  #
  #   * "compiled" (default) returns [], so the default build passes no
  #     1.20-only option at all and stays identical to a build without this
  #     hook. That keeps the `elixir: "~> 1.15"` requirement honest.
  #   * "interpreted" returns [module_definition: :interpreted].
  #
  # Anything else raises: a typo must never silently measure the default.
  #
  # Upstream downsides of :interpreted: compile-error stacktraces from module
  # bodies are less precise, and an anonymous function defined in a
  # defmodule body (outside any def) is limited to 20 arguments.
  #
  # Flipping the variant on a WARM _build is not a stale-artifact hazard: Mix
  # records elixirc_options in the compile manifest, so a flip in either
  # direction recompiles every platform file (911 of 911 on 1.20.4), while
  # re-running the same variant, or "compiled" against unset, is a no-op.
  # Measured in task 01a0fd73 stage 2; see
  # notes/2026-10-02-elixir-1.20.4-module-definition.md, which also records
  # why the default stays "compiled".
  #
  # Only this project carries the hook. apps/game_stream and apps/suite_release
  # compile platform as a path dep with this mix.exs, so it reaches platform
  # code in all three builds.
  defp module_definition_opts do
    case System.get_env("SUITE_MODULE_DEFINITION", "compiled") do
      "compiled" ->
        []

      "interpreted" ->
        [module_definition: :interpreted]

      other ->
        Mix.raise(
          "SUITE_MODULE_DEFINITION must be \"compiled\" or \"interpreted\", got: #{inspect(other)}"
        )
    end
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:assent, "~> 0.2"},
      {:ssl_verify_fun, "~> 1.1"},
      {:certifi, "~> 2.4"},
      {:mint, "~> 1.0"},
      {:castore, "~> 1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Runtime HTML parsing for Platform.Files.Extractor.HTML. Floki and not
      # LazyHTML deliberately: `lazy_html` is `only: :test` above AND is a NIF
      # (elixir_make + a c_src tree), so promoting it would put the first
      # compiled C into the production release. Floki is pure Elixir with no
      # dependencies of its own — its html5ever / fast_html backends are
      # separate packages we do not pull in.
      {:floki, "~> 0.38"},
      {:ecto_sql, "~> 3.10"},
      {:cloak_ecto, "~> 1.3"},
      {:req, "~> 0.5"},
      {:postgrex, ">= 0.0.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:oauth2, "~> 2.1"},
      {:mox, "~> 1.0", only: :test},
      # ex_json_schema: validates tools' real output against their
      # `returns_schema` (task 01a114a8 stage 3,
      # test/platform/code_mode/return_contract_test.exs). Already in every
      # env's tree through ex_mcp (pinned 0.11.3 in mix.lock), so declaring it
      # adds nothing to a release; an `only: :test` here would diverge from
      # that and mix refuses it.
      {:ex_json_schema, "~> 0.11"},
      {:web_push_encryption, "~> 0.3"},
      {:earmark, "~> 1.4"},
      {:makeup, "~> 1.2"},
      {:makeup_elixir, "~> 1.0"},
      {:makeup_js, "~> 0.1"},
      {:gun, "~> 2.1"},
      {:jose, "~> 1.11"},
      {:yaml_elixir, "~> 2.9"},
      {:nimble_csv, "~> 1.2"},
      # tzdata: IANA time-zone database backing `DateTime.shift_zone!/2`
      # for timezone-aware cron triggers (task 019f70e9 stage 6 — 03:00
      # America/Chicago dreaming firing survives DST transitions).
      {:tzdata, "~> 1.1"},
      # icalendar: TEST-ONLY. `Platform.Meetings.CalendarFeed` is our own
      # renderer — we do not use this library's serializer. It is here so
      # the feed tests assert against a real RFC 5545 parser
      # (`ICalendar.from_ics/1`, which performs line-unfolding and value
      # unescaping) instead of a regex over the payload. A regex passes on
      # output no calendar client would accept.
      {:icalendar, "~> 1.1", only: :test},
      # image / vix: libvips bindings, backing Platform.Branding.IconSet's
      # derivation of the seven PWA icon variants from one uploaded square
      # (task 01a0879a stage 2).
      #
      # `image` and NOT `mogrify`: mogrify shells out to an ImageMagick
      # binary that is not present in this repo's runtime image, so every
      # upload would die with `:enoent` at request time while every test
      # passed — the same failure mode the `gh` comment in
      # apps/platform/Dockerfile documents having already shipped once.
      # `vix` resolves a PRECOMPILED NIF that bundles its own libvips
      # (`VIX_COMPILATION_MODE` defaults to `PRECOMPILED_NIF_AND_LIBVIPS`),
      # so the runtime image needs no libvips package — verified by running
      # the derivation inside a container built from the Dockerfile's `app`
      # stage, not merely under `mix test`.
      {:image, "~> 0.54"},
      # swoosh + gen_smtp: the Email module's outbound path (task 01a0cf21
      # stage 2). Exactly one module calls them — Platform.Mail.Mailer, under
      # lib/platform/mail/ — and a guard test fails if any other file under
      # lib/ does. gen_smtp is optional in swoosh but required by its SMTP
      # adapter. Both are pure Erlang/Elixir: no NIFs, no system libraries.
      {:swoosh, "~> 1.28"},
      {:gen_smtp, "~> 1.3"},
      # mail: parses the MIME the Email module's IMAP poller fetches (task
      # 01a0cf21 stage 3). IMAP itself is spoken by
      # Platform.Mail.Imap.WireClient over :gen_tcp/:ssl (stage 7 dropped
      # mailroom, which failed against a real server). Pure Elixir: no NIFs,
      # no system libraries.
      {:mail, "~> 0.5"},
      # wasmex: the wasmtime runtime behind `suite_run` (task 01a114a8 stage
      # 2, Platform.CodeMode). Agent-written JavaScript runs in QuickJS-ng
      # compiled to wasm32-wasip1 (priv/code_mode/quickjs_cm.wasm), so a
      # memory-safety bug in the interpreter stays inside wasm linear memory
      # instead of running natively in the BEAM. `rustler_precompiled`
      # fetches the NIF per target at compile time (aarch64 and x86_64 linux
      # gnu are both in the package's checksum file); nothing compiles Rust.
      {:wasmex, "== 0.15.1"},
      # imp: Imp (DSPy for Elixir). PILOT dependency for task 01a0e8b5, used
      # ONLY by the meeting open_question classifier pilot
      # (lib/platform/meetings/open_question_pilot/**, the
      # open_question_classifier experiment surface and the
      # platform.open_question_pilot.* mix tasks). Do not adopt it anywhere
      # else in core; test/platform/meetings/open_question_pilot/
      # imp_scope_guard_test.exs enforces that. Pulls erlexec (C++ port) and
      # jaxon (C NIF), and requires req ~> 0.6 / mint ~> 1.8, which bumped
      # Req 0.5 -> 0.7 for all of core.
      {:imp, "~> 0.6"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": [
        "ecto.create",
        fn _args ->
          Mix.Task.run("ecto.migrate", Platform.MixSupport.extension_migration_args())
        end
      ],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "tailwind platform",
        "esbuild platform",
        "esbuild excalidraw",
        "esbuild emoji",
        "cmd --cd assets node scripts/copy_excalidraw_assets.mjs"
      ],
      "assets.deploy": [
        "tailwind platform --minify",
        "esbuild platform --minify",
        "esbuild excalidraw --minify",
        "esbuild emoji --minify",
        "cmd --cd assets node scripts/copy_excalidraw_assets.mjs",
        "phx.digest"
      ],
      test: [
        fn _args -> Platform.MixSupport.prepare_test_database() end,
        "test"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
