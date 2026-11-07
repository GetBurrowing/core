defmodule Platform.Secretary.Input do
  @moduledoc """
  One readable thing `Platform.Secretary.Inputs.gather/3` hands the triage
  agent (task 01a1b721). Every field is plain data. `space_kind` is
  `channel | dm | group` for a chat message and nil otherwise; `member?`
  says whether the person is a participant of the space (an open channel
  they are not in is readable and arrives with `member?: false`).
  """

  @type t :: %__MODULE__{
          ref_type: String.t(),
          ref_id: Ecto.UUID.t(),
          kind: String.t(),
          title: String.t() | nil,
          text: String.t() | nil,
          space_id: Ecto.UUID.t() | nil,
          space_kind: String.t() | nil,
          member?: boolean(),
          mentioned?: boolean(),
          author_id: Ecto.UUID.t() | nil,
          author_label: String.t() | nil,
          at: DateTime.t() | nil,
          deadline_at: DateTime.t() | nil
        }

  @enforce_keys [:ref_type, :ref_id, :kind]
  defstruct ref_type: nil,
            ref_id: nil,
            kind: nil,
            title: nil,
            text: nil,
            space_id: nil,
            space_kind: nil,
            member?: false,
            mentioned?: false,
            author_id: nil,
            author_label: nil,
            at: nil,
            deadline_at: nil
end
