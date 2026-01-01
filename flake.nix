{
  description = "Reproducible Attestable AMI with embedded application";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nitro-tee.url = "github:aws/nitrotpm-attestation-samples?dir=nix";
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, flake-utils, nitro-tee, crane, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages."${system}";
        craneLib = crane.mkLib pkgs;

        # Fetch NitroTPM-Tools source
        nitroTpmToolsSrc = builtins.fetchGit {
          url = "https://github.com/aws/NitroTPM-Tools";
          rev = "ec21ed738ba628fe460e524b3c485aed9564fe0a";
        };

        # Build nitro-tpm-attest binary
        nitroTpmAttest = let
          commonArgs = {
            src = nitroTpmToolsSrc;
            strictDeps = true;
            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [ pkgs.tpm2-tss pkgs.openssl ];
          };
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        in craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p nitro-tpm-attest";
          doCheck = false;
        });

        # Application script as a package in the nix store
        appScript = pkgs.writeShellScriptBin "app" (builtins.readFile ./app.sh);

        # NixOS configuration for our attestable image
        userConfig = { config, pkgs, lib, ... }: {
          # Include app in system packages
          environment.systemPackages = [ appScript pkgs.tpm2-tools pkgs.tpm2-tss pkgs.strace nitroTpmAttest ];

          # systemd service to run app on boot
          systemd.services.app = {
            description = "Run attestable application on boot";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            path = [ appScript pkgs.coreutils pkgs.tpm2-tools pkgs.strace nitroTpmAttest ];

            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${appScript}/bin/app";
              StandardOutput = "journal+console";
              StandardError = "journal+console";
            };
            environment = {
              TPM_DEVICE = "/dev/tpmrm0";
              TPM2TOOLS_TCTI = "device:/dev/tpmrm0";
            };
          };

          # Forward journal to serial console for EC2 get-console-output
          services.journald.extraConfig = ''
            ForwardToConsole=yes
            TTYPath=/dev/ttyS0
            MaxLevelConsole=info
          '';

          # Minimal networking for IMDS access (if needed by app.sh)
          networking.firewall.enable = true;
        };
      in
      {
        packages = {
          # Production image (no console access)
          raw-image = nitro-tee.lib.${system}.tee-image {
            inherit userConfig;
            isDebug = false;
          };

          # Debug image (console access enabled)
          raw-image-debug = nitro-tee.lib.${system}.tee-image {
            inherit userConfig;
            isDebug = true;
          };
        };

        # Expose utilities from nitro-tee
        apps = {
          create-ami = nitro-tee.apps.${system}.create-ami;
          boot-uefi-qemu = nitro-tee.apps.${system}.boot-uefi-qemu;
        };

        # Default package
        defaultPackage = self.packages.${system}.raw-image;
      }
    );
}
