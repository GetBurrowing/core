defmodule Platform.Social.ClipHeadlinesTest do
  use ExUnit.Case, async: true
  alias Platform.Social.{ClipHeadlines, ClipLook}

  test "explicit templates pin exact assets, safe timing and emphasis; legacy absent stays unknown" do
    assert {:ok, nil} = ClipHeadlines.snapshot(ClipLook.default())

    for name <- ClipLook.headline_templates() -- ["legacy"] do
      assert {:ok, contract} =
               ClipHeadlines.snapshot(%{"title" => %{"template" => name, "secs" => 3.5}})

      assert contract["template"] == name
      assert contract["revision"] == 1

      assert contract["assets"]["logo_sha256"] ==
               "7cbddeac97ad8fe3aa53e867cf0e5648329f500e528f2302e1b2ebcba8bf767f"

      assert contract["timing"] == %{
               "entrance_s" => 0.2,
               "hold_s" => 3.05,
               "exit_s" => 0.25,
               "total_s" => 3.5
             }
    end

    assert {:error, :headline_timing_invalid} =
             ClipHeadlines.snapshot(%{"title" => %{"template" => "chrome-hook", "secs" => 20}})

    assert {:error, :headline_emphasis_stale} =
             ClipHeadlines.snapshot(%{
               "title" => %{
                 "template" => "chrome-hook",
                 "emphasis" => [2],
                 "emphasis_text" => "two words"
               }
             })

    assert {:error, _} = ClipLook.validate(%{"title" => %{"template" => "invented"}})
    assert {:error, _} = ClipLook.validate(%{"title" => %{"emphasis" => [1, 1]}})
  end

  test "human wording normalizes spaces without accepting internal control characters" do
    base = %Platform.Social.ClipRender{requested_start_s: 0.0, requested_end_s: 5.0}

    assert {:ok, %{"headline" => %{"requested_headline" => "Two words"}}} =
             Platform.Social.ClipFixes.validate(base, %{
               "operation" => "edit_headline",
               "headline" => "  Two   words  "
             })

    assert {:error, :invalid_headline} =
             Platform.Social.ClipFixes.validate(base, %{
               "operation" => "edit_headline",
               "headline" => "Two\nwords"
             })
  end

  test "content-free receipt requires exact contract and rejects injected wording and malformed content" do
    {:ok, contract} = ClipHeadlines.snapshot(%{"title" => %{"template" => "chrome-hook"}})
    digest = String.duplicate("a", 64)

    receipt =
      contract
      |> Map.delete("emphasis_text")
      |> Map.merge(%{
        "content" => %{"artifact" => "sha256:" <> digest, "sha256" => digest},
        "output_sha256" => digest
      })

    assert {:ok, ^receipt} = ClipHeadlines.receipt(contract, receipt)
    assert {:error, :headline_receipt_required} = ClipHeadlines.receipt(contract, nil)

    for invalid <- [
          Map.put(receipt, "wording", "must remain local"),
          put_in(receipt, ["content"], []),
          put_in(receipt, ["revision"], 2),
          put_in(receipt, ["content", "artifact"], "/mutable/review.toml")
        ] do
      assert {:error, :headline_receipt_invalid} = ClipHeadlines.receipt(contract, invalid)
    end
  end
end
