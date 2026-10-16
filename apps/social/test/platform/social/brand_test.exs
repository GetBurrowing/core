defmodule Platform.Social.BrandTest do
  @moduledoc """
  `Platform.Social.Brand` (Social 5/7): the provisional placeholders from
  design canvas 01a140fc-14a9, the per-profile merge, and the brand
  validation a profile write runs (hex colours, WCAG AA on the end card,
  logo in the profile's org).
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Brand, Profile}

  test "defaults are the canvas placeholders, verbatim" do
    d = Brand.defaults()
    assert d["caption_text"] == "#FFFFFF"
    assert d["caption_outline"] == "#000000"
    assert d["outline_px"] == 3
    assert d["highlight"] == "#FFD400"
    assert d["end_card_ground"] == "#111111"
    assert d["end_card_text"] == "#FFFFFF"
    assert d["font"] == "public_sans_black"
    assert d["logo_file_id"] == nil
    assert d["channel_name"] == "Channel name"
    assert d["handle"] == nil
    assert d["cta"] == "Full episode on YouTube"

    values = d |> Map.values() |> Enum.filter(&is_binary/1) |> Enum.map(&String.upcase/1)
    tokens = suite_token_colours()
    assert tokens != []
    assert Enum.all?(tokens, &(&1 not in values))
  end

  test "resolve/1 merges a profile's brand over the defaults; channel_url is home_url" do
    profile = %Profile{
      home_url: "https://example.com/@show",
      brand: %{
        "highlight" => "#00FF88",
        "channel_name" => "The Show",
        "handle" => nil,
        "junk" => 1
      }
    }

    b = Brand.resolve(profile)
    assert b["highlight"] == "#00FF88"
    assert b["channel_name"] == "The Show"
    assert b["caption_text"] == "#FFFFFF"
    assert b["channel_url"] == "https://example.com/@show"
    refute Map.has_key?(b, "junk")

    assert Brand.resolve(%Profile{brand: %{channel_url: "https://x.test"}})["channel_url"] ==
             "https://x.test"

    assert Brand.resolve(nil) == Map.put(Brand.defaults(), "channel_url", nil)
  end

  test "contrast_ratio/2 matches WCAG for known pairs" do
    assert_in_delta Brand.contrast_ratio("#FFFFFF", "#000000"), 21.0, 0.01
    assert_in_delta Brand.contrast_ratio("#FFFFFF", "#111111"), 18.88, 0.05
    assert_in_delta Brand.contrast_ratio("#777777", "#FFFFFF"), 4.48, 0.02
  end

  describe "a profile write validates its brand" do
    setup do
      org_id = org_id!()
      %{org_id: org_id}
    end

    test "valid overrides are stored", %{org_id: org_id} do
      assert {:ok, %Profile{brand: brand}} =
               Social.create_profile(org_id, %{
                 name: "Show",
                 brand: %{"highlight" => "#00FF88", "end_card_ground" => "#202020"}
               })

      assert brand["highlight"] == "#00FF88"
    end

    test "end card text that fails AA on the ground is refused", %{org_id: org_id} do
      assert {:error, changeset} =
               Social.create_profile(org_id, %{
                 name: "Low contrast",
                 brand: %{"end_card_ground" => "#777777"}
               })

      assert [msg] = errors_on(changeset).brand
      assert msg =~ "WCAG AA (4.5:1)"
      assert msg =~ "#777777"

      # the same check through an update, with the text colour the culprit
      {:ok, p} = Social.create_profile(org_id, %{name: "Ok"})

      assert {:error, cs} =
               Social.update_profile(org_id, p, %{brand: %{"end_card_text" => "#222222"}})

      assert errors_on(cs).brand |> hd() =~ "4.5:1"
    end

    test "bad colours, outline, font and unknown keys are each named", %{org_id: org_id} do
      assert {:error, changeset} =
               Social.create_profile(org_id, %{
                 name: "Bad",
                 brand: %{
                   "highlight" => "yellow",
                   "outline_px" => 20,
                   "font" => "comic_sans",
                   "colour" => "#FFFFFF"
                 }
               })

      errors = errors_on(changeset).brand
      assert Enum.any?(errors, &(&1 =~ "highlight must be a #RRGGBB colour"))
      assert Enum.any?(errors, &(&1 =~ "outline_px"))
      assert Enum.any?(errors, &(&1 =~ "font must be one of: public_sans_black"))
      assert Enum.any?(errors, &(&1 =~ "unknown brand keys: colour"))
    end

    test "logo_file_id must be an image file in the profile's org", %{org_id: org_id} do
      other_org_file = file!(org_id!())

      assert {:error, cs} =
               Social.create_profile(org_id, %{
                 name: "Logo",
                 brand: %{"logo_file_id" => other_org_file.id}
               })

      assert errors_on(cs).brand == ["logo_file_id must name a file in the profile's org"]

      assert {:error, cs} =
               Social.create_profile(org_id, %{
                 name: "Logo2",
                 brand: %{"logo_file_id" => Ecto.UUID.generate()}
               })

      assert errors_on(cs).brand == ["logo_file_id must name a file in the profile's org"]

      # a video in the right org is not a logo
      video = file!(org_id)

      assert {:error, cs} =
               Social.create_profile(org_id, %{
                 name: "Logo3",
                 brand: %{"logo_file_id" => video.id}
               })

      assert errors_on(cs).brand == ["logo_file_id must be an image file"]

      project = project!(org_id)

      {:ok, png} =
        Platform.Files.create_file(%{
          project_id: project.id,
          name: "logo.png",
          original_filename: "logo.png",
          content_type: "image/png",
          byte_size: 10,
          storage_key: "files/#{project.id}/#{unique()}/logo.png",
          content_hash: String.duplicate("b", 64)
        })

      assert {:ok, _} =
               Social.create_profile(org_id, %{name: "Logo4", brand: %{"logo_file_id" => png.id}})
    end
  end
end
