defmodule PlatformWeb.SocialClipMusic do
  @moduledoc "Music controls share the exact-version appearance draft and render action."
  use PlatformWeb, :html
  alias Platform.Social.ClipMusic

  attr :track, :map, required: true
  attr :tracks, :list, required: true
  attr :base, :any, required: true
  attr :disabled, :boolean, required: true
  attr :target, :any, required: true
  attr :upload, :any, required: true

  def controls(assigns) do
    assigns = assign(assigns, :applied, ClipMusic.settings(assigns.base && assigns.base.look))

    ~H"""
    <section
      aria-label="Background music"
      class="space-y-2 border-t border-base-300 pt-3"
      data-role="clip-music"
    >
      <h3 class="text-sm font-semibold">Music</h3>
      <form phx-change="music" phx-target={@target} data-role="music-settings" class="space-y-2">
        <.input
          type="select"
          name="file_id"
          id="clip-music-song"
          label="Song"
          value={@track["file_id"] || ""}
          options={[
            {"None", ""}
            | Enum.map(@tracks, &{&1.name || &1.original_filename || "Project audio", &1.id})
          ]}
          disabled={@disabled}
        />
        <p :if={@tracks == []} class="text-xs text-subtle" data-role="music-empty">
          No project audio yet. Upload a song to begin.
        </p>
        <label for="clip-music-gain" class="block text-xs">Background volume</label>
        <input
          type="range"
          name="gain_db"
          id="clip-music-gain"
          aria-describedby="clip-music-gain-readout"
          min="-60"
          max="0"
          step="1"
          value={@track["gain_db"]}
          disabled={@disabled}
          class="range range-info range-sm w-full"
        />
        <output
          id="clip-music-gain-readout"
          for="clip-music-gain"
          class="font-mono text-xs"
          data-role="music-gain"
        >
          {@track["gain_db"]} dB
        </output>
        <.input
          type="select"
          name="muted"
          id="clip-music-muted"
          label="Music playback"
          value={to_string(@track["muted"])}
          options={[{"Mute", "true"}, {"On", "false"}]}
          disabled={@disabled or is_nil(@track["file_id"])}
        />
      </form>
      <div :if={@track["file_id"] && Enum.any?(@tracks, &(&1.id == @track["file_id"]))}>
        <p class="text-xs text-subtle">
          Audition original track (preview volume is separate from rendered gain).
        </p>
        <audio
          controls
          preload="none"
          src={"/files/blob/#{@track["file_id"]}"}
          class="h-10 w-full"
          aria-label="Preview selected song"
          data-role="music-preview"
        />
      </div>
      <p class="text-xs text-subtle" data-role="music-applied">
        Applied: {if @applied["muted"] or is_nil(@applied["file_id"]),
          do: "None / muted",
          else: "Selected song at #{@applied["gain_db"]} dB"}
      </p>
      <form phx-change="music_upload" phx-target={@target} data-role="music-upload">
        <label for={@upload.ref} class="text-xs font-semibold">Upload audio (up to 25 MB)</label>
        <.live_file_input
          upload={@upload}
          disabled={@disabled}
          class="file-input file-input-sm w-full"
        />
        <p :for={entry <- @upload.entries} class="text-xs text-info" role="status">
          Uploading {entry.client_name}: {entry.progress}%
        </p>
        <p
          :for={
            error <-
              upload_errors(@upload) ++ Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))
          }
          role="alert"
          class="text-xs text-error"
        >
          Audio upload failed: {error}
        </p>
      </form>
    </section>
    """
  end
end
