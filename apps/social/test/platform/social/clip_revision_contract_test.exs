defmodule Platform.Social.ClipRevisionContractTest do
  use ExUnit.Case, async: true

  test "the shared UUIDv5 vector matches exactly and malformed inputs are not repaired" do
    args = [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
      String.duplicate("0123456789abcdef", 4)
    ]

    assert {:ok, "2a18c828-9595-5b54-94a0-e061644b1a0e"} =
             apply(Platform.Social.ClipRevisionContract, :submission_id, args)

    for value <- [" x", "{11111111-1111-4111-8111-111111111111}", "INVALID"] do
      assert {:error, :invalid_identity} =
               apply(
                 Platform.Social.ClipRevisionContract,
                 :submission_id,
                 List.replace_at(args, 0, value)
               )
    end

    assert {:error, :invalid_identity} =
             apply(
               Platform.Social.ClipRevisionContract,
               :submission_id,
               List.replace_at(args, 3, String.upcase(List.last(args)))
             )
  end

  defp envelope do
    range = %{"start_s" => 10, "end_s" => 20}

    %{
      "file_id" => Ecto.UUID.generate(),
      "request_id" => Ecto.UUID.generate(),
      "base_render_id" => Ecto.UUID.generate(),
      "submission_id" => Ecto.UUID.generate(),
      "output" => %{
        "sha256" => String.duplicate("a", 64),
        "bytes" => 10,
        "duration_s" => 10,
        "width" => 1080,
        "height" => 1920,
        "fps" => 23.976
      },
      "provenance" => %{
        "provided_by" => "exporter",
        "tool_version" => "test-1",
        "source_fingerprint" => "sha256:" <> String.duplicate("b", 64),
        "requested_range" => range,
        "edited_range" => range,
        "exported" =>
          Map.merge(range, %{
            "continuous" => true,
            "handle_before_s" => 0,
            "handle_after_s" => 0,
            "spans" => [range]
          })
      }
    }
  end

  test "bounded exporter envelope preserves separated episode ranges and facts" do
    assert {:ok, input} = Platform.Social.ClipRevisionContract.return_input(envelope())
    assert input["byte_size"] == 10
    assert input["duration_s"] == 10.0
    assert input["fps"] == 23.976
    assert input["provenance"]["provided_by"] == "exporter"
    assert input["provenance"]["requested_range"] == %{"start_s" => 10.0, "end_s" => 20.0}
  end

  test "unknown, unbounded and invalid provenance refuses rather than being silently dropped" do
    p = envelope()["provenance"]

    variants = [
      Map.put(p, "transcript", "words"),
      Map.put(p, "tool_version", String.duplicate("x", 129)),
      Map.put(p, "source_fingerprint", "/private/source.mp4"),
      Map.put(p, "provided_by", "server"),
      put_in(p, ["requested_range", "start_s"], true),
      put_in(p, ["edited_range", "end_s"], 1),
      put_in(p, ["exported", "spans"], List.duplicate(%{"start_s" => 10, "end_s" => 20}, 257)),
      put_in(p, ["exported", "handle_after_s"], -1)
    ]

    for invalid <- variants do
      assert {:error, :invalid_provenance} =
               Platform.Social.ClipRevisionContract.return_input(
                 Map.put(envelope(), "provenance", invalid)
               )
    end

    assert {:error, :invalid_media_facts} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(envelope(), ["output", "fps"], false)
             )
  end

  test "return output requires positive duration and signed-64-safe integer dimensions and bytes" do
    for {key, invalid} <- [
          {"duration_s", 0},
          {"bytes", 9_223_372_036_854_775_808},
          {"width", 9_223_372_036_854_775_808},
          {"height", 9_223_372_036_854_775_808}
        ] do
      assert {:error, :invalid_media_facts} =
               Platform.Social.ClipRevisionContract.return_input(
                 put_in(envelope(), ["output", key], invalid)
               )
    end

    assert {:error, _} =
             Platform.Social.ClipRevisionContract.return_input(Map.delete(envelope(), "output"))
  end

  test "discontinuous edits retain playback order and repeated source without an enclosing range" do
    input = envelope()
    spans = [%{"start_s" => 10, "end_s" => 12}, %{"start_s" => 15, "end_s" => 20}]

    exported = %{
      "continuous" => false,
      "handle_before_s" => 0,
      "handle_after_s" => 0,
      "spans" => spans
    }

    input = put_in(input, ["provenance", "exported"], exported)
    assert {:ok, normalized} = Platform.Social.ClipRevisionContract.return_input(input)
    refute Map.has_key?(normalized["provenance"]["exported"], "start_s")

    assert {:error, :invalid_provenance} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(input, ["provenance", "exported", "start_s"], 10)
             )

    # Shared teaser: a later passage first, then an earlier overlapping passage.
    teaser = [%{"start_s" => 15, "end_s" => 17}, %{"start_s" => 10, "end_s" => 20}]

    assert {:ok, repeated} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(input, ["provenance", "exported", "spans"], teaser)
             )

    assert repeated["provenance"]["exported"]["spans"] == [
             %{"start_s" => 15.0, "end_s" => 17.0},
             %{"start_s" => 10.0, "end_s" => 20.0}
           ]

    assert {:error, :invalid_provenance} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(input, ["provenance", "exported", "spans"], [hd(spans)])
             )
  end

  test "notification classification never treats a crash or ambiguous result as definitely unsent" do
    assert {"failed", nil} =
             apply(Platform.Social.ClipRevisions, :notification_attempt, [
               fn -> {:error, :space_archived} end
             ])

    for fun <- [fn -> raise "after insertion" end, fn -> exit(:timeout) end, fn -> :unknown end] do
      assert {"uncertain", nil} =
               apply(Platform.Social.ClipRevisions, :notification_attempt, [fun])
    end

    id = Ecto.UUID.generate()

    assert {"sent", ^id} =
             apply(Platform.Social.ClipRevisions, :notification_attempt, [
               fn -> {:ok, %{id: id}} end
             ])
  end

  test "the exporter-produced synthetic return envelope is accepted and intake diagnostics are refused" do
    fixture =
      Path.expand("../../support/fixtures/clip_revision_return_contract.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    # The route owns clip_id; file_id is added only after an upload, never by the exporter.
    input = Map.delete(fixture, "clip_id")
    assert {:ok, normalized} = Platform.Social.ClipRevisionContract.return_input(input)
    assert normalized["byte_size"] == fixture["output"]["bytes"]

    assert normalized["provenance"]["exported"]["spans"] == [
             %{"start_s" => 15.0, "end_s" => 17.0},
             %{"start_s" => 10.0, "end_s" => 20.0}
           ]

    assert {:ok, id} =
             Platform.Social.ClipRevisionContract.submission_id(
               fixture["request_id"],
               fixture["clip_id"],
               fixture["base_render_id"],
               fixture["output"]["sha256"]
             )

    assert id == fixture["submission_id"]

    assert {:error, :field_not_allowed} =
             Platform.Social.ClipRevisionContract.return_input(
               Map.put(input, "provenance_unavailable", [%{"reason" => "edit_list_unreadable"}])
             )

    assert {:ok, "857c54f8-b6fa-5418-af1b-f6a3d000a17a"} =
             Platform.Social.ClipRevisionContract.submission_id(
               "01900000-0000-7000-8000-000000000001",
               "01900000-0000-7000-8000-000000000002",
               "01900000-0000-7000-8000-000000000003",
               String.duplicate("a", 64)
             )
  end

  test "fps follows the shared finite-positive rule rather than the seconds ceiling" do
    assert {:ok, input} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(envelope(), ["output", "fps"], 1.0e50)
             )

    assert input["fps"] == 1.0e50

    assert {:ok, _} =
             Platform.Social.ClipRevisionContract.return_input(
               put_in(envelope(), ["output", "width"], 9_223_372_036_854_775_807)
             )
  end
end
