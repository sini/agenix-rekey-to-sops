/*
  A module to import into flakes based on flake-parts.
  Extends agenix-rekey with SOPS functionality.

  Usage:
    imports = [
      inputs.agenix-rekey.flakeModule
      inputs.agenix-rekey-to-sops.flakeModule
    ];

    # Then in devshell, use:
    devshells.default.packages = [ config.agenix-rekey-sops.package ];
*/
{
  lib,
  self,
  config,
  inputs,
  flake-parts-lib,
  ...
}:
{
  imports = [
    inputs.agenix-rekey.flakeModule
  ];

  options.perSystem = flake-parts-lib.mkPerSystemOption (
    {
      config,
      system,
      pkgs,
      ...
    }:
    {
      options.agenix-rekey-sops = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ./nix/package.nix {
            allApps = [
              "edit-view"
              "generate"
              "rekey"
              "update-masterkeys"
              "sops-rekey"
            ];
            agenix-rekey = inputs.agenix-rekey;
          };
          description = ''
            The agenix wrapper script with SOPS support.
            This includes all standard agenix commands plus `sops-rekey`.
          '';
        };
      };

      # Expose sops-rekey as an app so it can be run with `nix run`
      config.apps.sops-rekey = {
        type = "app";
        program = lib.getExe (
          import ./apps/sops-rekey.nix {
            nodes = import (inputs.agenix-rekey + "/nix/select-nodes.nix") {
              inherit (config.agenix-rekey)
                nixosConfigurations
                darwinConfigurations
                homeConfigurations
                extraConfigurations
                collectHomeManagerConfigurations
                ;
              inherit (config.agenix-rekey.pkgs) lib;
            };
            inherit (config.agenix-rekey) pkgs;
            agePackage = _: config.agenix-rekey.agePackage;
            userFlake = self;
          }
        );
      };
    }
  );

  # Note: We can't extend flake.agenix-rekey because it's readOnly.
  # Instead, the wrapper script will handle sops-rekey specially.
}
