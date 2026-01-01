{
  description = "Reproducible Attestable AMI with embedded application";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nitro-tee.url = "github:aws/nitrotpm-attestation-samples?dir=nix";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nitro-tee, crane, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Set up crane for Rust builds
        craneLib = (crane.mkLib pkgs).overrideToolchain (p: p.rust-bin.stable.latest.default);

        # Build nitro-tpm-attest from NitroTPM-Tools
        nitroTpmToolsSrc = builtins.fetchGit {
          url = "https://github.com/aws/NitroTPM-Tools.git";
          rev = "a37ff598acf32e3c8c2c85d53bb8f4025b0a12d7";
        };

        cargoArtifacts = craneLib.buildDepsOnly {
          src = nitroTpmToolsSrc;
          pname = "nitro-tpm-tools";
          version = "1.1.0";
          strictDeps = true;
          doCheck = false;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.tpm2-tss ];
        };

        nitroTpmAttest = craneLib.buildPackage {
          inherit cargoArtifacts;
          src = nitroTpmToolsSrc;
          pname = "nitro-tpm-attest";
          version = "1.1.0";
          cargoExtraArgs = "-p nitro-tpm-attest";
          strictDeps = true;
          doCheck = false;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.tpm2-tss pkgs.openssl ];
        };

        # Application script as a package in the nix store
        appScript = pkgs.writeShellScriptBin "app" (builtins.readFile ./app.sh);

        # NixOS configuration for our attestable image
        userConfig = { config, pkgs, lib, ... }: {
          environment.systemPackages = [ appScript pkgs.tpm2-tools nitroTpmAttest ];

          # systemd service to run app on boot
          systemd.services.app = {
            description = "Run attestable application on boot";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            path = [ appScript pkgs.coreutils pkgs.tpm2-tools nitroTpmAttest ];

            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${appScript}/bin/app";
              StandardOutput = "journal+console";
              StandardError = "journal+console";
            };
            environment = {
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

          # Export nitro-tpm-attest as a standalone package
          inherit nitroTpmAttest;
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
