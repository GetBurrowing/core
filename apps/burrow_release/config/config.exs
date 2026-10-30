# The with-modules release host's config (ADR 0055, task 01a0ee08; Social
# added by task 01a140a8): core's
# config, imported, plus the module selection and the two asset profiles
# pointed at this host's generated inputs.
import Config

import_config "../../platform/config/config.exs"

config :platform, :extensions, [Platform.GameStream.Extension, Platform.Social.Extension]

# Written by `mix platform.extensions.assets --out assets/generated`; nothing
# is generated inside apps/platform.
generated = Path.expand("../assets/generated", __DIR__)
static = Path.expand("../priv/static/assets", __DIR__)

# Core's `platform` profile with two changes only: `@extensions` resolves to
# the generated entry instead of core's empty js/extensions/none.js, and the
# output and NODE_PATH are this host's.
config :esbuild,
  platform: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=#{static}/js --external:/fonts/* --external:/images/* --alias:@=. --alias:@extensions=#{generated}/extensions.js),
    cd: Path.expand("../../platform/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Core's two island profiles (`excalidraw`, `emoji`), unchanged except for the
# output directory and NODE_PATH, which become this host's. They are read from
# core's own config rather than retyped, so a flag core adds to either island
# reaches the with-modules image too. The islands do not import `@extensions`,
# so they are the same bytes in both flavours (stage 4,
# `docs/decisions/0055-extension-contract-and-build-time-modules.md § 4. Assets`).
core_esbuild =
  Path.expand("../../platform/config/config.exs", __DIR__)
  |> Config.Reader.read!(env: config_env(), target: config_target())
  |> Keyword.fetch!(:esbuild)

core_outdir = "--outdir=../priv/static/assets/js"

retarget_island = fn name ->
  profile = Keyword.fetch!(core_esbuild, name)
  args = Keyword.fetch!(profile, :args)

  unless core_outdir in args do
    raise "core's esbuild #{name} profile no longer passes #{core_outdir}; " <>
            "update apps/burrow_release/config/config.exs to retarget it"
  end

  Keyword.merge(profile,
    args: Enum.map(args, &if(&1 == core_outdir, do: "--outdir=#{static}/js", else: &1)),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  )
end

# Every island core defines is retargeted, not a hand-kept list: the image
# missed core's `terminal` island (task 01a17b17) for exactly that reason, so
# prod served /assets/js/terminal_island.js as a 404. `:platform` is replaced
# above with this host's generated entry point; `:version` is not a profile.
island_profiles =
  for {name, profile} <- core_esbuild,
      name != :platform,
      Keyword.keyword?(profile) and Keyword.has_key?(profile, :args),
      do: {name, retarget_island.(name)}

config :esbuild, island_profiles

# Social players are a separate ESM island; build_islands/1 deploys this profile.
config :esbuild,
  clip_players: [
    args:
      ~w(js/clip_players.js --bundle --format=esm --target=es2022 --outfile=#{static}/js/clip_players.js),
    cd: Path.expand("../../social/assets", __DIR__)
  ]

# The generated wrapper stylesheet imports core's app.css and adds each
# module's stylesheet and Tailwind `@source`.
#
# BURROW_HEROICONS_DIR (and its old name SUITE_HEROICONS_DIR, written with the
# same value so a core that reads only the old name still finds it; task
# 01a14b9e) points core's heroicons plugin at THIS host's deps:
# core's plugin otherwise looks in apps/platform/deps, which a host build does
# not have, and silently renders no vendored `hero-*` icon (stage 4,
# scripts/check-flavour-css.sh is the guard).
config :tailwind,
  platform: [
    args: ~w(--input=#{generated}/app.css --output=#{static}/css/app.css),
    cd: Path.expand("..", __DIR__),
    env: %{
      "BURROW_HEROICONS_DIR" => Path.expand("../deps/heroicons/optimized", __DIR__),
      "SUITE_HEROICONS_DIR" => Path.expand("../deps/heroicons/optimized", __DIR__)
    }
  ]
