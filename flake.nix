{
  description = "SOPS output extension for agenix-rekey";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    agenix-rekey = {
      # url = "github:sini/agenix-rekey";
      url = "path:/home/sini/Documents/repos/sini/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix-rekey,
    }:
    {
      # Nixidy module with SOPS support
      nixidyModules = {
        default = import ./modules/nixidy.nix nixpkgs;
        agenix-rekey-to-sops = self.nixidyModules.default;
      };

      # Generic module (works for terranix too)
      sopsModules = {
        default = self.nixidyModules.default;
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
          pkgs ? nixpkgs,
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
          baseApps = agenix-rekey.configure {
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
        nixpkgs.lib.genAttrs systems (
          system:
          let
            pkgs' =
              if builtins.isAttrs pkgs then
                pkgs.${system} or (import nixpkgs { inherit system; })
              else
                import nixpkgs { inherit system; };
          in
          baseApps.${system}
          // {
            # Add sops-rekey app
            sops-rekey = import ./apps/sops-rekey.nix {
              nodes = import (agenix-rekey + "/nix/select-nodes.nix") {
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
}
