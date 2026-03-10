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
    }
  );
}
