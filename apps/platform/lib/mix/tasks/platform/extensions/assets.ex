defmodule Mix.Tasks.Platform.Extensions.Assets do
  @moduledoc """
  Writes the with-modules build's generated asset inputs (ADR 0055, task
  01a0ee08 stage 3) from the configured extensions' `assets/0`:

      mix platform.extensions.assets --out assets/generated

  writes `<out>/extensions.js` (the `@extensions` esbuild entry) and
  `<out>/app.css` (core's stylesheet plus each module's, with a Tailwind
  `@source` per module). Run it from a release host, whose config lists the
  modules; the host's esbuild profile aliases `@extensions` to the first file
  and its Tailwind profile takes the second as `--input`. See
  `Platform.Extensions.AssetEntry`.

  Core's own build never runs this: with no extension configured the files
  would equal `js/extensions/none.js` and `app.css`, which core uses directly.
  """

  use Mix.Task

  alias Platform.Extensions.AssetEntry

  @shortdoc "Generate the with-modules @extensions entry and wrapper stylesheet"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [out: :string])
    if invalid != [], do: Mix.raise("unknown option(s): #{inspect(invalid)}")
    out = Path.expand(Keyword.get(opts, :out, "assets/generated"))

    # `compile`, not `app.config`: the extension list is compile-time config
    # (config.exs, which Mix has already loaded), and `app.config` would also
    # evaluate the runtime config, which under `MIX_ENV=prod` in an image
    # build raises for every unset secret (stage 4).
    Mix.Task.run("compile")

    assets = Platform.Extensions.assets()
    core_css = core_css()

    File.mkdir_p!(out)
    File.write!(Path.join(out, "extensions.js"), AssetEntry.js(assets, out))
    File.write!(Path.join(out, "app.css"), AssetEntry.css(assets, core_css, out))

    Mix.shell().info(
      "platform.extensions.assets: #{length(assets)} module(s) -> #{Path.relative_to_cwd(out)}"
    )
  end

  # Core's stylesheet in core's source tree: a host builds with core as a
  # path dependency, so the source is always there at build time.
  @core_css Path.expand("../../../../../assets/css/app.css", __DIR__)
  defp core_css, do: @core_css
end
