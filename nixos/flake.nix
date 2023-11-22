{
  inputs.nixpkgs.url = "nixpkgs/nixos-23.05";
  outputs = { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib outPath;
      system = "aarch64-linux";
      modules = [
        "${outPath}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        ( { pkgs, config, ... }: {
          boot.kernelParams = [ "copytoram" ];

          nix = {
            package = pkgs.nixFlakes;
            extraOptions = "experimental-features = nix-command flakes";
          };
          environment.systemPackages = with pkgs; [ openssl git ];

          users.users.root.openssh.authorizedKeys.keys = [
            # Only used for connecting to the iso-booted system for debugging,
            # setting it to yours is recommended but technically optional.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILEIHPFhrmKl7KPP9MLC7EyXPWW/9OShgxrVd7ioKdNO mal@luca:oraclecloud"
          ];
          systemd.services.sshd.wantedBy = pkgs.lib.mkForce [ "multi-user.target" ];
          systemd.services.install = {
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" "polkit.service" ];
            path = [ "/run/current-system/sw/" ];
            environment = config.nix.envVars // {
              inherit (config.environment.sessionVariables) NIX_PATH;
              HOME = "/root";
            };
            serviceConfig.Type = "oneshot";
            script = builtins.readFile ./stage2.sh;
          };
        })
      ];
    in
    {
      defaultPackage.${system} = (lib.nixosSystem { inherit modules system; }).config.system.build.isoImage;
    };
}
