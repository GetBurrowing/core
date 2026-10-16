defmodule Platform.Social.Source.MeetingRecording do
  @moduledoc """
  DEFERRED clip source (Social 5/7). `meeting_recordings` has no scoped
  public read today: the only public reader is keyed by room, and the
  transcript read is unscoped. The ticket forbids the render worker reading
  a recording as an unscoped system process, so this source always refuses
  and says what to do instead. Social 6/7 (the meeting bridge) or RBAC adds
  the scoped read; this module is where it plugs in.
  """

  @behaviour Platform.Social.Source

  @message "meeting recordings are not a clip source yet: no scoped read exists; " <>
             "export the recording to Files and use it as a file source"

  @impl true
  def fetch(_clip, _profile, _dir), do: {:error, @message}
end
