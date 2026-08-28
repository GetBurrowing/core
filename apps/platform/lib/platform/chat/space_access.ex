defmodule Platform.Chat.SpaceAccess do
  @moduledoc """
  Space-write authorization — one function answering "may this actor write to
  this space", composed by the `Platform.Chat` context functions so every
  future caller inherits it (task 01a01ce0, stage 1).

  `Platform.Chat.CanvasAccess` is the model this module copies. The difference
  is the resource: `CanvasAccess` resolves a canvas and then asks who may touch
  it, while this module answers the prior question about the SPACE itself, and
  returns the `Platform.Chat.Participant` row the write needs for attribution.

  ## The hole this closes

  `PlatformWeb.ChatLive.PinHooks`'s `"pin_toggle"` clause and `ShellLive`'s
  `"dismiss_agent"` clause both take a `space-id` out of the client's own
  event params. `PinHooks`'s only guard was `socket.assigns.current_participant`
  — membership of the space being VIEWED, never of the space named in the
  params — and `dismiss_agent` had no membership guard at all. A session open
  on space A could push a forged `space-id` for space B and pin, unpin, or
  evict an agent there.

  THE CHECK BELONGS IN THE CONTEXT FUNCTION, NOT THE HOOK. A guard in
  `pin_hooks.ex` protects one caller; a guard in `Chat.pin_message/2` protects
  every caller that has not been written yet. That is the entire shape of this
  change.

  ## SCOPE LIMIT, stated so nobody over-reads it

  This closes forged `space-id` params sent from a session open on a DIFFERENT
  space. It does NOT close "navigate to the target space's URL".
  `ChatLive.handle_params/3` calls `ensure_participant/2`, which INSERTS a
  `chat_participants` row with no authorization of its own, so for a space
  whose kind is implicitly joinable membership is minted one layer above this
  guard and `authorize_writer/2` then correctly passes.

  Task 01a01d0e narrowed that door but did not shut it: `chat_live.ex`'s
  `@implicitly_joinable_kinds` is `channel`, `system` and `execution`, and an
  internal user reaching any of those by URL still auto-joins by design (the
  rail lists every workspace channel to every internal user). `dm`, `group`,
  `meeting` and `guest_meeting` now require a pre-existing row.

  So the claim here is "membership is required and is no longer inferred from
  the wrong space", not "non-participants cannot write, full stop". Who may
  ENTER a channel is a separate question, and answering it is what would close
  the rest.

  ## Actors

  `t:actor/0` copies `Platform.Chat.CanvasAccess`'s `normalize_actor/1`
  BEHAVIOUR minus the `:system` clause:

      {:user, user_id} | {:agent, agent_id} | %{id: user_id} | nil

  A bare `%{id: _}` map (i.e. a `%Platform.Accounts.User{}`) is accepted as
  shorthand for `{:user, id}`, which is the shape a LiveView holds. Anything
  unrecognised — `nil` included — is *no principal* and DENIES. There is
  deliberately no clause promoting an unknown shape to a bypass.

  **`:system` is dropped on purpose.** `chat_pins.pinned_by` is a
  `chat_participants.id` and `Platform.Chat.Pin.changeset/2` runs
  `validate_required/2` on it, so a `:system` grant has no participant row to
  attribute the write to: it would authorize a write that then fails
  validation, or worse, invite a caller to supply the attribution itself. A
  principal with no participant row has nothing to write as, so it has no
  business writing here.

  ## Why neither existing predicate was reused

  Two spellings of "is this principal in this space" already exist. Both were
  read and both were rejected, for reasons that are properties of the
  functions rather than preferences:

    * `Chat.participant?/2` is a boolean `Repo.exists?` with NO
      `Platform.UUID.valid?/1` guard on either id. A forged non-UUID
      `space-id` — exactly the input this module exists to receive — raises
      `Ecto.Query.CastError` from inside `Repo`, i.e. a 500, instead of
      denying. It also returns a boolean, so it cannot supply the participant
      row the pin write needs for attribution.

    * `Chat.user_in_space?/2` is likewise a boolean, takes its arguments in
      the reversed order (`user_id, space_id`), and folds in an
      `is_nil(s.archived_at)` check that would duplicate
      `ensure_space_writable/1` and collapse `:forbidden` and
      `:space_archived` into one indistinguishable `false`.

  Neither is changed here. This module COMPOSES rather than consolidates; the
  duplication is recorded in the PR body instead of being resolved in an
  authorization stage.

  ## One lookup, guarded on both ids

  `chat_participants.space_id` and `.participant_id` are both `:binary_id`, so
  EITHER being malformed raises. The single private lookup guards both with
  `Platform.UUID.valid?/1` — the strict predicate, not a bare
  `Ecto.UUID.cast/1`, which hex-encodes a 16-byte binary and would let a
  16-character slug through to raise against the strict key anyway.
  `Chat.get_agent_participant/2` guards the same pair the same way.

  The lookup is parameterised by `participant_type` and is deliberately
  private: there is no public `Chat` function for it. A third public spelling
  of this question is what the reasons above are trying to avoid.

  `Repo.get_by/2` is safe against `Ecto.MultipleResultsError` here because
  `chat_participants` carries the unique index `chat_participants_unique` on
  `(space_id, participant_type, participant_id)`.

  ADR 0038 removed `left_at` from `chat_participants`, so the presence of the
  row IS membership and no soft-delete filter applies.
  """

  alias Platform.Chat.Participant
  alias Platform.Repo

  @typedoc """
  Acting principal. Mirrors `t:Platform.Chat.CanvasAccess.actor/0` minus
  `:system` — see the moduledoc for why that clause is absent.
  """
  @type actor :: {:user, binary()} | {:agent, binary()} | map() | nil

  @doc """
  Resolve the acting principal's participant row in `space_id`.

  Returns `{:ok, participant}` when `actor` holds a `chat_participants` row in
  that space, `{:error, :forbidden}` otherwise. A `nil` actor, an unrecognised
  actor shape, and a malformed (non-UUID) `space_id` all DENY rather than
  raise.

  The returned row is the attribution the caller writes with — see
  `Platform.Chat.pin_message/2`, which derives `:pinned_by` from it.
  """
  @spec authorize_writer(binary(), actor()) :: {:ok, Participant.t()} | {:error, :forbidden}
  def authorize_writer(space_id, actor) do
    case participant_for(space_id, normalize_actor(actor)) do
      %Participant{} = participant -> {:ok, participant}
      nil -> {:error, :forbidden}
    end
  end

  # ── Actors ────────────────────────────────────────────────────────────────

  # Copied from `CanvasAccess.normalize_actor/1` minus `:system`. Anything
  # unrecognised normalises to `nil` — no principal, no grant. There is
  # deliberately no clause that promotes an unknown shape to a bypass.
  defp normalize_actor({:user, id} = actor) when is_binary(id), do: actor
  defp normalize_actor({:agent, id} = actor) when is_binary(id), do: actor
  defp normalize_actor(%{id: id}) when is_binary(id), do: {:user, id}
  defp normalize_actor(_), do: nil

  # ── Participant lookup ────────────────────────────────────────────────────

  defp participant_for(space_id, {:user, user_id}),
    do: lookup_participant(space_id, "user", user_id)

  defp participant_for(space_id, {:agent, agent_id}),
    do: lookup_participant(space_id, "agent", agent_id)

  defp participant_for(_space_id, _actor), do: nil

  # ONE lookup for both principal kinds, parameterised by `participant_type`.
  # Both ids are `:binary_id` columns, so both are guarded — a forged
  # `space-id` is the input this module was written to receive.
  defp lookup_participant(space_id, participant_type, participant_id)
       when is_binary(space_id) and is_binary(participant_id) do
    if Platform.UUID.valid?(space_id) and Platform.UUID.valid?(participant_id) do
      Repo.get_by(Participant,
        space_id: space_id,
        participant_type: participant_type,
        participant_id: participant_id
      )
    end
  end

  defp lookup_participant(_space_id, _participant_type, _participant_id), do: nil
end
