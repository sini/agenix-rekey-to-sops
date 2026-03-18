# Minimal test to validate nixidy module schema
# Run with: nix eval --file test-minimal.nix --json
let
  nixpkgs = builtins.getFlake "nixpkgs";
  inherit (nixpkgs) lib;

  # Import our nixidy module
  nixidyModule = import ../../modules/nixidy.nix nixpkgs;

  # Evaluate a minimal configuration
  testConfig = lib.evalModules {
    modules = [
      nixidyModule
      {
        age = {
          sops = {
            outputDir = ./.secrets/env/test;
          };

          rekey.masterIdentities = [ ./master-key.pub ];

          secrets = {
            test-secret = {
              rekeyFile = ./secrets/test.age;
              sopsOutput = {
                file = "test";
                key = "my-secret";
                format = "str";
              };
            };

            test-base64-secret = {
              rekeyFile = ./secrets/test-cert.age;
              sopsOutput = {
                file = "tls";
                key = "cert.pem";
                format = "base64";
              };
            };
          };
        };
      }
    ];
  };

in
{
  # Test that sopsRef is computed correctly
  test-secret-sopsRef = testConfig.config.age.secrets.test-secret.sopsRef;
  test-base64-secret-sopsRef = testConfig.config.age.secrets.test-base64-secret.sopsRef;

  # Test that sopsOutput is properly set
  test-secret-file = testConfig.config.age.secrets.test-secret.sopsOutput.file;
  test-secret-key = testConfig.config.age.secrets.test-secret.sopsOutput.key;
  test-secret-format = testConfig.config.age.secrets.test-secret.sopsOutput.format;

  # Verify sops config
  sopsOutputDir = toString testConfig.config.age.sops.outputDir;
}
