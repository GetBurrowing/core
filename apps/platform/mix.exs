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
    run_step(runner, "ecto.migrate")
    :ok
  end

  defp run_step(runner, task) do
    runner.(task, ["--quiet"])
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
      {:icalendar, "~> 1.1", only: :test}
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
      "ecto.setup": ["ecto.create", "ecto.migrate"],
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
