defmodule Platform.Social.Renderer do
  @moduledoc """
  The clip renderer contract (task 01a140a9-69b7, Social 5/7): a source
  video plus timed words in, a 9:16 captioned MP4 with an end card out.

  The implementation is chosen ONLY by `config :social, :renderer` (default
  `Platform.Social.Renderer.Ffmpeg`; tests use `Platform.Social.Renderer.Fake`),
  read on every call. The product lead has not chosen between self-hosted OpenShorts
  and hosted Vizard; either drops in later as another module implementing
  this behaviour, with no change to the queue that calls it.

  **Speaker-follow crop is not in v1.** v1 crops statically, centred at
  `crop_x` (0..1 across the frame's spare width). Following a face needs a
  face tracker (OpenCV, or OpenShorts' pipeline), which ffmpeg alone does
  not have; it belongs behind this behaviour, in a renderer that has one.
  The canvas's "hold the last good crop" rule applies to that renderer.

  Input (`render/1`):

    * `source_path` - a local video file;
    * `start_s`, `end_s` - the clip in source seconds (already snapped);
    * `words` - `%{w, start_s, end_s}` in SOURCE seconds;
    * `speakers` - `%{start_s, name}` change points in SOURCE seconds;
    * `crop_x`, `brand` (`Platform.Social.Brand.resolve/1`), `out_path`;
    * `logo_path` - optional local image for the end card;
    * `width` 1080, `height` 1920, `end_card_s` 2.0.

  Output: `{:ok, %{path, duration_s, width, height, byte_size}}` or
  `{:error, readable}`. A missing binary or capability is an `{:error, _}`,
  never a raise.
  """

  @type input :: %{
          required(:source_path) => String.t(),
          required(:start_s) => number(),
          required(:end_s) => number(),
          required(:words) => [map()],
          required(:out_path) => String.t(),
          optional(:speakers) => [map()],
          optional(:crop_x) => number(),
          optional(:brand) => map(),
          optional(:logo_path) => String.t() | nil,
          optional(:width) => pos_integer(),
          optional(:height) => pos_integer(),
          optional(:end_card_s) => number()
        }

  @type output :: %{
          path: String.t(),
          duration_s: float(),
          width: pos_integer(),
          height: pos_integer(),
          byte_size: non_neg_integer()
        }

  @doc "Whether this node can render at all."
  @callback preflight() :: :ok | {:error, String.t()}

  @doc "Renders one clip."
  @callback render(input()) :: {:ok, output()} | {:error, String.t()}

  @doc "The configured renderer module, read on every call."
  @spec impl() :: module()
  def impl, do: Application.get_env(:social, :renderer, Platform.Social.Renderer.Ffmpeg)

  @doc "Defaults every renderer applies."
  @spec defaults() :: map()
  def defaults, do: %{width: 1080, height: 1920, end_card_s: 2.0, crop_x: 0.5, speakers: []}
end
