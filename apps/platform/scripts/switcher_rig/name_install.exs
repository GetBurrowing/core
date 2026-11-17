# rig.sh rpc <x> name_install.exs <name>
#
# Rig seeding (task 01a1ccd4 stage 4): give the install a distinct app name
# ("Install A", ...) so the switcher rows can be told apart. The same field
# an admin sets under branding; written directly because the rig user is not
# an admin. Prints `RIG name=<name>`.
import Ecto.Query

[name] = args

{1, _} =
  Platform.Repo.update_all(from(b in Platform.Branding.InstallBranding),
    set: [app_name: name]
  )

IO.puts("RIG name=#{Platform.Branding.app_name()}")
