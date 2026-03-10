{
  description = "Example nixidy configuration with agenix-rekey SOPS output";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix-rekey = {
      url = "github:sini/agenix-rekey";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix-rekey-to-sops = {
      url = "path:../.."; # Parent directory
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.agenix-rekey.follows = "agenix-rekey";
    };
    nixidy.url = "github:arnarg/nixidy";
    nixidy.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix-rekey,
      agenix-rekey-to-sops,
      nixidy,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # Define nixidy environments with agenix-rekey integration
      # Note: We use extraConfigurations to support custom configs
      extraConfigurations = {
        production = nixidy.lib.mkEnv {
          inherit pkgs;
          modules = [
            agenix-rekey-to-sops.nixidyModules.default
            {
              age = {
                # SOPS configuration
                sops = {
                  configFile = ./.sops.yaml;
                  outputDir = ./. + "/.secrets/prod";
                };

                # Master identity for decrypting source secrets
                rekey = {
                  masterIdentities = [ /home/sini/Documents/repos/sini/nix-config/.secrets/pub/master.pub ];
                  agePlugins = [ pkgs.age-plugin-yubikey ];
                };

                # Secret definitions
                secrets = {
                  # OIDC secrets (grouped into oidc.enc.yaml)
                  hubble-ui-oidc-client-secret = {
                    rekeyFile = ./secrets/hubble-ui-oidc.age;
                    generator.script = "alnum";
                    sopsOutput = {
                      file = "oidc";
                      key = "hubble-ui";
                    };
                  };

                  grafana-oidc-client-secret = {
                    rekeyFile = ./secrets/grafana-oidc.age;
                    generator.script = "alnum";
                    sopsOutput = {
                      file = "oidc";
                      key = "grafana";
                    };
                  };
                };
              };
            }
          ];
        };
      };

      # Configure agenix-rekey with SOPS extension
      agenix-rekey = agenix-rekey-to-sops.configure {
        userFlake = self;
        inherit (self) extraConfigurations;
      };
    };
}
