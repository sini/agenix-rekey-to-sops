{
  description = "SOPS output extension for agenix-rekey";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    agenix-rekey = {
      url = "github:sini/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.devshell.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake =
        {
          config,
          lib,
          ...
        }:
        {
          # Module that extends agenix-rekey with SOPS output support
          sopsModules = {
            default = import ./modules/sops.nix {
              agenix-rekey = inputs.agenix-rekey;
              nixpkgs = inputs.nixpkgs;
            };
            agenix-rekey-to-sops = config.nixidyModules.default;
          };

          # Helper to configure agenix-rekey with sops-rekey app
          configure =
            {
              userFlake,
              extraConfigurations ? { },
              nixosConfigurations ? { },
              darwinConfigurations ? { },
              homeConfigurations ? { },
              collectHomeManagerConfigurations ? true,
              nodes ? { },
              pkgs ? inputs.nixpkgs,
              agePackage ? (p: p.rage),
              systems ? [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ],
            }:
            let
              # Get base agenix-rekey apps
              baseApps = inputs.agenix-rekey.configure {
                inherit
                  userFlake
                  extraConfigurations
                  nixosConfigurations
                  darwinConfigurations
                  homeConfigurations
                  collectHomeManagerConfigurations
                  nodes
                  pkgs
                  agePackage
                  systems
                  ;
              };
            in
            lib.genAttrs systems (
              system:
              let
                pkgs' =
                  if builtins.isAttrs pkgs then
                    pkgs.${system} or (import inputs.nixpkgs { inherit system; })
                  else
                    import inputs.nixpkgs { inherit system; };
              in
              baseApps.${system}
              // {
                # Add sops-rekey app
                sops-rekey = import ./apps/sops-rekey.nix {
                  nodes = import (inputs.agenix-rekey + "/nix/select-nodes.nix") {
                    inherit
                      nodes
                      nixosConfigurations
                      darwinConfigurations
                      homeConfigurations
                      extraConfigurations
                      collectHomeManagerConfigurations
                      ;
                    inherit (pkgs') lib;
                  };
                  inherit userFlake;
                  agePackage = agePackage pkgs';
                  pkgs = pkgs';
                };
              }
            );
        };

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        {
          devshells.default = {
            packages = with pkgs; [
              rage
              sops
              age
              jq
              yq-go
            ];
          };
        };
    };
}
