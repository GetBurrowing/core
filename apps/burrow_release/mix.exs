defmodule BurrowRelease.MixProject do
  @moduledoc """
  The with-modules release host (ADR 0055, task 01a0ee08): a Mix project with
  no code of its own whose deps are core plus the selected build-time
  modules, all by path. Its config is core's plus the module selection, and
  its release is the with-modules image. `apps/platform` alone remains the
  without-modules build.

  Stage 3 proves compilation and the asset path:

      mix deps.get && mix compile --warnings-as-errors
      mix assets.build     # generated @extensions entry + wrapper stylesheet

  Stage 4 builds and publishes the release image from
  `apps/burrow_release/Dockerfile`; `apps/platform/Dockerfile` builds the
  without-modules image.
  """
  use Mix.Project

  def project do
    [
      app: :burrow_release,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:platform, path: "../platform", env: Mix.env()},
      {:game_stream, path: "../game_stream", env: Mix.env()},
      {:social, path: "../social", env: Mix.env()}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      # `compile` first: the generator reads the configured extensions'
      # `assets/0`. Island profiles (excalidraw, emoji) are core's and are
      # wired for the image in stage 4.
      "assets.build": [
        "compile",
        "platform.extensions.assets --out assets/generated",
        "tailwind platform",
        "esbuild platform"
      ],
      # The image's asset build (stage 4): core's `assets.deploy` with this
      # host's generated inputs and output directory. Core's
      # `copy_excalidraw_assets.mjs` and `phx.digest` run in
      # apps/burrow_release/Dockerfile, which moves these outputs into core's
      # `priv/static` (the `from: :platform` the Endpoint serves) inside the
      # image only, so nothing is ever written into apps/platform's tree here.
      "assets.deploy": [
        "compile",
        "platform.extensions.assets --out assets/generated",
        "tailwind platform --minify",
        "esbuild platform --minify",
        "esbuild excalidraw --minify",
        "esbuild emoji --minify"
      ]
    ]
  end

  # The release reads core's runtime config as its own, so the with-modules
  # image reads the environment exactly as the without-modules image does; a
  # module reads its own settings in its own Application.start/2.
  defp releases do
    [
      platform: [
        applications: [platform: :permanent, game_stream: :permanent, social: :permanent],
        runtime_config_path: "../platform/config/runtime.exs"
      ]
    ]
  end
end
