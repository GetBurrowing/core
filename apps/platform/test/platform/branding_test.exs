defmodule Platform.BrandingTest do
  @moduledoc """
  Task 01a0879a stage 1 — the `install_branding` singleton and
  `Platform.Branding`, the single read path for this install's PWA identity.

  What these tests are for:

    1. DEFAULTS ARE PINNED. A migrated database with no upload answers with
       Fabrikam's identity and the repo's own static asset paths. Those must not
       move silently.
    2. THE VALUE CHANGES WITHOUT A RESTART. `update_identity/2` then
       `app_name/0` reads it back in the same process, with no
       `Application.put_env` and no restart — the entire reason this lives in
       a table rather than in config.
    3. THE SINGLETON IS ENFORCED BY THE DATABASE. A second row would mean two
       different manifests depending on query order, and that failure is
       silent.
    4. AUTHORIZATION IS RE-CHECKED IN THE CONTEXT, not only on the route.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Branding
  alias Platform.Branding.IconStorage
  alias Platform.Branding.InstallBranding
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_user!(role) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "branding-#{n}@example.com",
        name: "Branding #{n}",
        oidc_sub: "oidc-branding-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("fabrikam").id,
      role: role
    })
    |> Repo.insert!()

    user
  end

  defp admin!, do: create_user!("admin")
  defp non_admin!, do: create_user!("member")

  # ── Defaults ───────────────────────────────────────────────────────────

  describe "defaults on a migrated database" do
    test "identity fields are Fabrikam's, and the colours are dark base-100" do
      assert Branding.app_name() == "Suite"

      # The one place a raw hex is allowed to live in the shipped change is
      # the migration's default row. It is repeated HERE, and only here,
      # because a defaults test that reads the value back from the code under
      # test would pin nothing.
      assert Branding.theme_color() == "#171b25"
      assert Branding.background_color() == "#171b25"
    end

    test "no upload means the seven variants resolve to the repo's static assets" do
      assert Branding.icon_url(:icon_192) == "/images/icon-192.png"
      assert Branding.icon_url(:icon_512) == "/images/icon-512.png"
      assert Branding.icon_url(:icon_512_maskable) == "/images/icon-512-maskable.png"
      assert Branding.icon_url(:apple_touch) == "/images/apple-touch-icon.png"
      assert Branding.icon_url(:favicon_32) == "/images/favicon-32.png"
      assert Branding.icon_url(:favicon_16) == "/images/favicon-16.png"
      assert Branding.icon_url(:favicon_ico) == "/images/favicon.ico"
    end

    test "every advertised variant is answerable" do
      for variant <- Branding.variants() do
        assert is_binary(Branding.icon_url(variant))
      end

      assert length(Branding.variants()) == 7
    end

    test "the seeded row has no upload and no derived variants" do
      assert %InstallBranding{source_storage_key: nil, derived: %{}, version: nil} =
               Branding.get()
    end
  end

  # ── The value changes without a restart ────────────────────────────────

  describe "update_identity/2" do
    test "a write is visible to the next read with no restart and no put_env" do
      admin = admin!()

      assert {:ok, _} = Branding.update_identity(admin, %{app_name: "SENTINEL-XYZ"})

      assert Branding.app_name() == "SENTINEL-XYZ"
      assert Branding.get().app_name == "SENTINEL-XYZ"
    end

    test "colours round-trip" do
      admin = admin!()

      assert {:ok, _} =
               Branding.update_identity(admin, %{
                 theme_color: "#Ab12Cd",
                 background_color: "#000102"
               })

      assert Branding.theme_color() == "#Ab12Cd"
      assert Branding.background_color() == "#000102"
    end

    test "broadcasts on the install_branding topic" do
      admin = admin!()
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Branding.pubsub_topic())

      assert {:ok, _} = Branding.update_identity(admin, %{app_name: "BROADCAST-XYZ"})

      assert_receive {:install_branding_updated, %InstallBranding{app_name: "BROADCAST-XYZ"}}
    end

    test "icon columns are not castable through the identity form" do
      admin = admin!()

      assert {:ok, branding} =
               Branding.update_identity(admin, %{
                 app_name: "Still Suite",
                 source_storage_key: "attacker/key.png",
                 version: "deadbeef"
               })

      assert branding.source_storage_key == nil
      assert branding.version == nil
    end
  end

  describe "colour validation" do
    setup do
      %{admin: admin!()}
    end

    for bad <- ["nonsense", "#fff", "171b25"] do
      test "rejects #{inspect(bad)}", %{admin: admin} do
        bad = unquote(bad)
        before = Branding.get()

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Branding.update_identity(admin, %{theme_color: bad})

        assert {_msg, _} = changeset.errors[:theme_color]
        assert Branding.theme_color() == before.theme_color
      end
    end

    test "rejects a bad background_color too", %{admin: admin} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Branding.update_identity(admin, %{background_color: "#12345"})

      assert {_msg, _} = changeset.errors[:background_color]
    end
  end

  # ── Singleton ──────────────────────────────────────────────────────────

  describe "the singleton is enforced by the database" do
    test "a second insert raises" do
      # Raw struct insert, no changeset: this asserts the DATABASE refuses a
      # second row, not that a changeset happens to guard against one.
      assert_raise Ecto.ConstraintError, ~r/install_branding_singleton_index/, fn ->
        Repo.insert!(%InstallBranding{
          app_name: "Impostor",
          theme_color: "#123456",
          background_color: "#123456"
        })
      end
    end

    test "get/0 still answers exactly one row afterwards" do
      assert Repo.aggregate(InstallBranding, :count) == 1
    end
  end

  # ── Authorization ──────────────────────────────────────────────────────

  describe "authorization is re-checked in the context" do
    test "a non-admin is refused and the row is unchanged" do
      before = Branding.get()

      assert {:error, :unauthorized} =
               Branding.update_identity(non_admin!(), %{app_name: "ESCALATED-XYZ"})

      assert Branding.get().app_name == before.app_name
    end

    test "nil actor is refused" do
      assert {:error, :unauthorized} = Branding.update_identity(nil, %{app_name: "NOBODY-XYZ"})
    end
  end

  # ── Uploading a source and deriving from it (stage 2) ──────────────────

  # A flat 600px square, big enough to clear the 512px floor. Generated
  # rather than committed so the pixel the assertions talk about is visible
  # in the test source.
  defp solid_png(rgb, side \\ 600) do
    {:ok, one} = VipsOperation.black(1, 1)
    {:ok, coloured} = VipsOperation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = VipsOperation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = VipsOperation.embed(cast, 0, 0, side, side, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = VipsOperation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VipsImage.write_to_buffer(srgb, ".png")
    bytes
  end

  defp upload!(bytes) do
    assert {:ok, branding} =
             Branding.put_source(admin!(), {:binary, bytes}, content_type: "image/png")

    branding
  end

  defp all_keys(%InstallBranding{} = b) do
    [b.source_storage_key | Map.values(b.derived || %{})]
  end

  defp stored?(key), do: match?({:ok, _}, IconStorage.get(key))

  describe "put_source/3 makes an upload the install's icons" do
    test "writes all seven derived blobs plus the source, and points the row at them" do
      branding = upload!(solid_png([200, 30, 40]))
      on_exit(fn -> Enum.each(all_keys(branding), &IconStorage.delete/1) end)

      assert map_size(branding.derived) == 7

      assert Enum.sort(Map.keys(branding.derived)) ==
               Branding.variants() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert branding.source_storage_key =~ ~r/^install-branding\/[0-9a-f]{12}\/source\.png$/
      assert Enum.all?(all_keys(branding), &stored?/1)
    end

    test "the version is the content hash of the SOURCE bytes, so new bytes get a new version" do
      bytes = solid_png([200, 30, 40])
      branding = upload!(bytes)
      on_exit(fn -> Enum.each(all_keys(branding), &IconStorage.delete/1) end)

      assert branding.version ==
               :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      assert String.length(branding.version) == 12
    end

    test "a SECOND upload gets a different version and the previous blobs are deleted" do
      first = upload!(solid_png([200, 30, 40]))
      first_keys = all_keys(first)
      assert Enum.all?(first_keys, &stored?/1)

      second = upload!(solid_png([10, 90, 220]))
      on_exit(fn -> Enum.each(all_keys(second), &IconStorage.delete/1) end)

      refute second.version == first.version

      # Stage 3 puts the version token in the URL. A version that failed to
      # move would serve the OLD bytes from cache under the new upload.
      refute second.source_storage_key == first.source_storage_key

      for key <- first_keys do
        refute stored?(key), "#{key} survived the replacement and is now orphaned"
      end

      assert Enum.all?(all_keys(second), &stored?/1)
    end

    test "re-uploading the SAME bytes is idempotent and does NOT delete the live blobs" do
      bytes = solid_png([200, 30, 40])
      first = upload!(bytes)
      second = upload!(bytes)
      on_exit(fn -> Enum.each(all_keys(second), &IconStorage.delete/1) end)

      assert second.version == first.version

      # The keys are identical, so a naive "delete the previous version"
      # would delete the blobs the committed row now points at.
      assert Enum.all?(all_keys(second), &stored?/1)
    end
  end

  describe "put_source/3 leaves the old branding intact when it cannot succeed" do
    test "a source under 512px is refused and nothing is written" do
      before = Branding.get()

      small = solid_png([200, 30, 40], 64)

      assert {:error, {:source_too_small, 64, 64}} =
               Branding.put_source(admin!(), {:binary, small}, content_type: "image/png")

      after_row = Branding.get()
      assert after_row.version == before.version
      assert after_row.source_storage_key == before.source_storage_key
      assert after_row.derived == before.derived
    end

    test "a file that is not an image is refused rather than crashing" do
      assert {:error, :unreadable_image} =
               Branding.put_source(admin!(), {:binary, "not an image"}, content_type: "image/png")

      assert Branding.get().source_storage_key == nil
    end

    test "an upload whose type is not on the allowlist never reaches storage" do
      assert {:error, {:unsupported_content_type, "image/svg+xml"}} =
               Branding.put_source(admin!(), {:binary, solid_png([1, 2, 3])},
                 content_type: "image/svg+xml"
               )

      assert Branding.get().source_storage_key == nil
    end

    test "a previous upload SURVIVES a later failed one, blobs and all" do
      good = upload!(solid_png([200, 30, 40]))
      on_exit(fn -> Enum.each(all_keys(good), &IconStorage.delete/1) end)

      assert {:error, :unreadable_image} =
               Branding.put_source(admin!(), {:binary, "garbage"}, content_type: "image/png")

      reread = Branding.get()
      assert reread.version == good.version
      assert reread.source_storage_key == good.source_storage_key
      assert Enum.all?(all_keys(good), &stored?/1)
    end
  end

  describe "put_source/3 authorization" do
    test "a non-admin is refused and no blob is written" do
      before = Branding.get()

      assert {:error, :unauthorized} =
               Branding.put_source(non_admin!(), {:binary, solid_png([1, 2, 3])},
                 content_type: "image/png"
               )

      assert Branding.get().version == before.version
    end

    test "nil actor is refused" do
      assert {:error, :unauthorized} =
               Branding.put_source(nil, {:binary, solid_png([1, 2, 3])},
                 content_type: "image/png"
               )
    end
  end
end
