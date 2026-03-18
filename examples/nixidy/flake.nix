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
      # nix --extra-experimental-features nix-command build .#nixidyEnvs.x86_64-linux.production.environmentPackage
      nixidyEnvs.${system}.production = nixidy.lib.mkEnv {
        inherit pkgs;
        modules = [
          agenix-rekey-to-sops.sopsModules.default
          (
            { config, ... }:
            {
              age = {
                # SOPS configuration
                sops = {
                  outputDir = ./. + "/.secrets/prod"; # Only used for local mode
                };

                # Master identity for decrypting source secrets
                rekey = {
                  recipientIdentifier = "production";
                  storageMode = "local"; # or "derivation"
                  masterIdentities = [ ./master.pub ];
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

                  # Demo application secrets (grouped into demo-app.enc.yaml)
                  # These demonstrate the full workflow:
                  # 1. Define secrets with rekeyFile (age-encrypted source)
                  # 2. Add sopsOutput config (which SOPS file to generate)
                  # 3. Use secret.sopsRef in Kubernetes manifests
                  # 4. Deploy with vals to resolve ref+sops:// URIs
                  demo-app-api-key = {
                    rekeyFile = ./secrets/demo-app-api-key.age;
                    generator.script = "alnum";
                    sopsOutput = {
                      file = "demo-app";
                      key = "api-key";
                      format = "str";
                    };
                  };

                  demo-app-db-password = {
                    rekeyFile = ./secrets/demo-app-db-password.age;
                    generator.script = "alnum";
                    sopsOutput = {
                      file = "demo-app";
                      key = "db-password";
                      format = "str";
                    };
                  };
                };
              };

              # Nixidy configuration for demo application
              nixidy.target.repository = "https://github.com/example/repo.git";
              nixidy.target.branch = "main";
              nixidy.target.rootPath = "./examples/nixidy/manifests/production/";

              applications.demo-app = {
                namespace = "demo-app";
                createNamespace = true;

                resources = {
                  # Secret with vals references
                  secrets.demo-app-secrets = {
                    metadata.name = "demo-app-secrets";
                    stringData = {
                      # These will be resolved by vals at deployment time
                      api-key = config.age.secrets.demo-app-api-key.sopsRef;
                      db-password = config.age.secrets.demo-app-db-password.sopsRef;
                    };
                  };

                  # Example deployment using the secrets
                  deployments.demo-app = {
                    metadata.name = "demo-app";
                    spec = {
                      replicas = 2;
                      selector.matchLabels.app = "demo-app";
                      template = {
                        metadata.labels.app = "demo-app";
                        spec.containers = [
                          {
                            name = "app";
                            image = "nginx:latest";
                            env = [
                              {
                                name = "API_KEY";
                                valueFrom.secretKeyRef = {
                                  name = "demo-app-secrets";
                                  key = "api-key";
                                };
                              }
                              {
                                name = "DB_PASSWORD";
                                valueFrom.secretKeyRef = {
                                  name = "demo-app-secrets";
                                  key = "db-password";
                                };
                              }
                            ];
                          }
                        ];
                      };
                    };
                  };
                };
              };
            }
          )
        ];
      };

      # Configure agenix-rekey with SOPS extension
      agenix-rekey = agenix-rekey-to-sops.configure {
        userFlake = self;
        # Flatten the nested nixidyEnvs structure for all systems
        extraConfigurations = builtins.foldl' (acc: system: acc // self.nixidyEnvs.${system}) { } [
          system
        ];
      };

      # Expose sops-rekey as a package for the wrapper to find (matches agenix-rekey pattern)
      packages.${system}.sops-rekey = self.agenix-rekey.${system}.sops-rekey;
    };
}
