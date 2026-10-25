# Home Manager on the Mac is standalone (homeConfigurations."nsimon@nBookPro"),
# so `darwin-rebuild switch` used to leave it on an old generation. Activate it
# here, as the user and from the same flake revision. A failure only warns: the
# system switch has already happened.
{
  lib,
  outputs,
  username,
  hostname,
  ...
}:
let
  hm = outputs.homeConfigurations."${username}@${hostname}".activationPackage;
in
{
  system.activationScripts.postActivation.text = lib.mkAfter ''
    echo "activating Home Manager for ${username}..."
    sudo -u ${username} -H env HOME_MANAGER_BACKUP_EXT=hm-backup ${hm}/activate \
      || echo "warning: Home Manager activation failed; run home-manager switch by hand" >&2
  '';
}
