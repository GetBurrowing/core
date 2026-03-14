defmodule Platform.Chat.SchemaTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Chat.Space

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  # ── Space ─────────────────────────────────────────────────────────────────────

  describe "Space.changeset/2" do
    defp space_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          workspace_id: Ecto.UUID.generate(),
          name: "General",
          slug: "general",
          kind: "channel"
        },
        overrides
      )
    end

    test "valid changeset" do
      assert Space.changeset(%Space{}, space_attrs()).valid?
    end

    test "invalid kind is rejected" do
      changeset = Space.changeset(%Space{}, space_attrs(%{kind: "invalid"}))
      refute changeset.valid?
      assert %{kind: [_]} = errors_on(changeset)
    end

    test "all valid kinds are accepted" do
      for kind <- ~w(channel dm group) do
        changeset = Space.changeset(%Space{}, space_attrs(%{kind: kind}))
        assert changeset.valid?, "expected kind=#{kind} to be valid"
      end
    end

    test "missing name fails validation" do
      changeset = Space.changeset(%Space{}, space_attrs(%{name: nil}))
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "missing slug fails validation" do
      changeset = Space.changeset(%Space{}, space_attrs(%{slug: nil}))
      refute changeset.valid?
      assert %{slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "slug unique constraint is declared" do
      changeset = Space.changeset(%Space{}, space_attrs())
      # Verify the unique_constraint is present on the changeset (not yet DB-validated).
      constraints = changeset.constraints

      assert Enum.any?(
               constraints,
               &(&1.type == :unique and &1.constraint == "chat_spaces_unique_slug")
             )
    end
  end

  # ── Participant ───────────────────────────────────────────────────────────────

  describe "Participant.changeset/2" do
    defp participant_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          space_id: Ecto.UUID.generate(),
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          role: "member",
          joined_at: DateTime.utc_now()
        },
        overrides
      )
    end

    test "valid changeset" do
      assert Participant.changeset(%Participant{}, participant_attrs()).valid?
    end

    test "invalid participant_type is rejected" do
      changeset =
        Participant.changeset(%Participant{}, participant_attrs(%{participant_type: "robot"}))

      refute changeset.valid?
      assert %{participant_type: [_]} = errors_on(changeset)
    end

    test "all valid participant_types are accepted" do
      for type <- ~w(user agent) do
        changeset =
          Participant.changeset(%Participant{}, participant_attrs(%{participant_type: type}))

        assert changeset.valid?, "expected participant_type=#{type} to be valid"
      end
    end

    test "all valid attention_modes are accepted" do
      for mode <- ~w(mention heartbeat active) do
        changeset =
          Participant.changeset(
            %Participant{},
            participant_attrs(%{attention_mode: mode})
          )

        assert changeset.valid?, "expected attention_mode=#{mode} to be valid"
      end
    end

    test "invalid attention_mode is rejected" do
      changeset =
        Participant.changeset(%Participant{}, participant_attrs(%{attention_mode: "always"}))

      refute changeset.valid?
      assert %{attention_mode: [_]} = errors_on(changeset)
    end

    test "missing joined_at fails validation" do
      changeset = Participant.changeset(%Participant{}, participant_attrs(%{joined_at: nil}))
      refute changeset.valid?
      assert %{joined_at: ["can't be blank"]} = errors_on(changeset)
    end
  end

  # ── Message ───────────────────────────────────────────────────────────────────

  describe "Message.changeset/2" do
    defp message_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          space_id: Ecto.UUID.generate(),
          participant_id: Ecto.UUID.generate(),
          content_type: "text",
          content: "Hello, world!"
        },
        overrides
      )
    end

    test "valid changeset" do
      assert Message.changeset(%Message{}, message_attrs()).valid?
    end

    test "uses integer primary key" do
      assert Message.__schema__(:primary_key) == [:id]
      assert Message.__schema__(:type, :id) == :id
    end

    test "invalid content_type is rejected" do
      changeset = Message.changeset(%Message{}, message_attrs(%{content_type: "video"}))
      refute changeset.valid?
      assert %{content_type: [_]} = errors_on(changeset)
    end

    test "all valid content_types are accepted" do
      for ct <- ~w(text system agent_action canvas) do
        changeset = Message.changeset(%Message{}, message_attrs(%{content_type: ct}))
        assert changeset.valid?, "expected content_type=#{ct} to be valid"
      end
    end

    test "missing space_id fails validation" do
      changeset = Message.changeset(%Message{}, message_attrs(%{space_id: nil}))
      refute changeset.valid?
      assert %{space_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  # ── Canvas ────────────────────────────────────────────────────────────────────

  describe "Canvas.changeset/2" do
    defp canvas_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          space_id: Ecto.UUID.generate(),
          created_by: Ecto.UUID.generate(),
          canvas_type: "table",
          title: "My Canvas"
        },
        overrides
      )
    end

    test "valid changeset" do
      assert Canvas.changeset(%Canvas{}, canvas_attrs()).valid?
    end

    test "invalid canvas_type is rejected" do
      changeset = Canvas.changeset(%Canvas{}, canvas_attrs(%{canvas_type: "spreadsheet"}))
      refute changeset.valid?
      assert %{canvas_type: [_]} = errors_on(changeset)
    end

    test "all valid canvas_types are accepted" do
      for ct <- ~w(table form code diagram dashboard custom) do
        changeset = Canvas.changeset(%Canvas{}, canvas_attrs(%{canvas_type: ct}))
        assert changeset.valid?, "expected canvas_type=#{ct} to be valid"
      end
    end

    test "missing created_by fails validation" do
      changeset = Canvas.changeset(%Canvas{}, canvas_attrs(%{created_by: nil}))
      refute changeset.valid?
      assert %{created_by: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
