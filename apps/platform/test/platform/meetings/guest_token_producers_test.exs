defmodule Platform.Meetings.GuestTokenProducersTest do
  @moduledoc """
  Pins the REASON the meeting-wide guest link was deleted in task
  `019fb955-1d7b` stage 1, not merely the fact of its deletion.

  `MeetingLive.handle_event("generate_guest_invite", …)` called
  `GuestInvite.sign/4` directly with `guest_space_id:` and `meeting_id:` and
  **no `:invite_id`**, from an OPTIONAL display name. One meeting, one
  forwardable URL, no row behind it: whoever opened it was unidentifiable, so
  transcript speech could not be attributed and action items had no principal.
  That is the exact property the stack's per-invite token exists to prevent.

  The invariant that replaces it is a claim about *producers*, so that is what
  this module tests:

    1. The surviving producer, `Meetings.invite_guest/2`, always stamps
       `invite_id` — including on the most minimal call a caller can make,
       which is where an "optional" field is most likely to be dropped.
    2. It is the ONLY producer: nothing under `lib/platform_web/` calls
       `GuestInvite.sign` any more.

  **Why (2) is a source-level assertion.** The stage's preferred form is
  behavioural — mint through the LiveView and inspect the payload. That form is
  not reachable *by construction*: this stage removed the LiveView's only mint
  path, so there is no web-layer call to exercise. A behavioural test can show
  that a given path stamps `invite_id`; it cannot show that no *other* path
  exists, because a second mint site would live in code the test never calls.
  Exclusivity is a negative claim over a whole layer, and the source tree is
  the only artefact that carries it. Test 2 therefore reads the layer, and
  carries its own positive control (see below) so that a scan which silently
  matches nothing cannot pass as a scan which found nothing.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.GuestInvite
  alias Platform.Meetings.Invite
  alias Platform.Repo
  alias Platform.Tasks

  defp meeting! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Guest Token Producers #{n}"})

    {:ok, meeting} =
      Meetings.create_meeting(%{project_id: project.id, name: "Producers #{n}"})

    meeting
  end

  describe "the surviving producer" do
    test "invite_guest/2 stamps invite_id on the minimal call" do
      meeting = meeting!()

      # Deliberately minimal: display_name only. No email, no expiry, no host
      # user. If `invite_id` were threaded from optional caller input rather
      # than from the inserted row, this is the call that would drop it.
      assert {:ok, %{invite: %Invite{} = invite, token: token}} =
               Meetings.invite_guest(meeting, %{display_name: "Juno Fairbanks"})

      assert {:ok, payload} = GuestInvite.verify(token)

      # The row exists and the token names THAT row — not the meeting, and not
      # nothing. Equality, not presence: a token carrying some other invite's
      # id would satisfy a mere `is_binary/1` check.
      assert payload.invite_id == invite.id
      assert Repo.get(Invite, invite.id)

      # Control on the assertion above: `verify/1` normalises `:invite_id` into
      # every payload it returns, so `Map.has_key?` would be true even for a
      # token minted without one. Prove the field discriminates by verifying a
      # token minted the OLD way — the shape the deleted LiveView handler
      # produced — and watching it come back nil.
      legacy =
        GuestInvite.sign(
          meeting.slug,
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix(),
          nil,
          meeting_id: meeting.id
        )

      assert {:ok, legacy_payload} = GuestInvite.verify(legacy)
      assert is_nil(legacy_payload.invite_id)
    end

    test "two guests on one meeting get two tokens naming two different rows" do
      meeting = meeting!()

      assert {:ok, %{invite: a, token: token_a}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest A"})

      assert {:ok, %{invite: b, token: token_b}} =
               Meetings.invite_guest(meeting, %{display_name: "Guest B"})

      assert {:ok, payload_a} = GuestInvite.verify(token_a)
      assert {:ok, payload_b} = GuestInvite.verify(token_b)

      # Not `token_a != token_b` — that passes on a meeting-wide token re-signed
      # with a fresh nonce, which is precisely the model being deleted.
      assert payload_a.invite_id == a.id
      assert payload_b.invite_id == b.id
      assert a.id != b.id
    end
  end

  describe "producer exclusivity" do
    test "no module under lib/platform_web/ mints a guest token" do
      web_files =
        Path.wildcard(
          Path.join([__DIR__, "..", "..", "..", "lib", "platform_web", "**", "*.ex*"])
        )

      # Control 1 — the scan found a corpus. Without this, a broken glob makes
      # the refute below true over an empty list.
      assert length(web_files) > 100,
             "expected the platform_web tree, found #{length(web_files)} files — glob is wrong"

      matcher = ~r/GuestInvite\.sign|Meetings\.GuestInvite\.sign/

      # Control 2 — the matcher can actually match. Point it at the one call
      # site that must survive; if this assertion fails the refute below proves
      # nothing, because a regex that matches nowhere matches here too.
      context_source =
        Path.join([__DIR__, "..", "..", "..", "lib", "platform", "meetings.ex"]) |> File.read!()

      assert Regex.match?(matcher, context_source),
             "Meetings.invite_guest/2 no longer calls GuestInvite.sign — this test's control is stale"

      offenders =
        web_files
        |> Enum.filter(&Regex.match?(matcher, File.read!(&1)))
        |> Enum.map(&Path.relative_to(&1, Path.join([__DIR__, "..", "..", ".."])))

      assert offenders == [],
             """
             The web layer mints guest tokens again: #{Enum.join(offenders, ", ")}

             A token signed outside `Meetings.invite_guest/2` has no
             `meeting_invites` row behind it, so it carries no `invite_id`. It
             is forwardable, its holder is unidentifiable, and it cannot be
             revoked without invalidating every other guest on the meeting.
             Mint through `Meetings.invite_guest/2` instead.
             """
    end
  end
end
