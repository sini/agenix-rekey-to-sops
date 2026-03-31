{ agenix-rekey, nixpkgs }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    literalExpression
    ;

  cfg = config.age;

  # agenix-rekey's module expects nixpkgs as first arg, then returns the module
  agenixRekeyModule = import (agenix-rekey + "/modules/agenix-rekey.nix") nixpkgs;

  # Build SOPS secrets as a derivation (when storageMode = "derivation")
  sopsSecrets =
    if cfg.sops.storageMode == "derivation" then
      import ../nix/sops-derivation.nix {
        inherit pkgs;
        hostConfig = config;
        agePackage = pkgs.rage;
      }
    else
      null;

in
{
  # Import agenix-rekey's module to get all standard options
  imports = [
    agenixRekeyModule
  ];

  # Stub out NixOS-specific options that agenix-rekey uses
  # but aren't available in nixidy's module system
  options = {
    assertions = mkOption {
      type = types.listOf types.unspecified;
      internal = true;
      default = [ ];
    };

    warnings = mkOption {
      type = types.listOf types.str;
      internal = true;
      default = [ ];
    };
  };

  # Provide default config for agenix-rekey compatibility
  config = {
    # Deprecated option
    rekey.secrets = lib.mkDefault { };

    # For SOPS configurations (both local and derivation modes), we need to provide a hostPubkey
    # even though we don't actually deploy to a host (we just generate SOPS files)
    # This is required by agenix-rekey but not used for SOPS output
    # Use a dummy age key - this is only needed to satisfy agenix-rekey's module requirements
    age.rekey.hostPubkey = lib.mkDefault "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq";

    # Assertions for SOPS configuration
    assertions = [
      {
        assertion = config.age.rekey.storageMode == "local" -> config.age.sops.outputDir != null;
        message = "age.sops.outputDir must be set when storageMode = \"local\"";
      }
    ];
  };

  # Extend age.secrets submodule with SOPS-specific options
  # The module system will automatically merge these with agenix-rekey's existing options
  options.age = {
    secrets = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = {
              # Stub for agenix's file option (not used in nixidy, but agenix-rekey sets it)
              file = mkOption {
                type = types.nullOr types.path;
                internal = true;
                default = null;
              };

              # SOPS-specific options
              sopsOutput = mkOption {
                type = types.nullOr (
                  types.submodule {
                    options = {
                      file = mkOption {
                        type = types.str;
                        description = ''
                          Which SOPS file to write this secret into.
                          For example, "databases" will create databases.enc.yaml
                        '';
                      };

                      key = mkOption {
                        type = types.str;
                        default = name;
                        defaultText = literalExpression "name";
                        description = ''
                          YAML key within the SOPS file for this secret.
                          Only used for str and base64 formats (not binary).
                        '';
                      };

                      format = mkOption {
                        type = types.enum [
                          "str"
                          "base64"
                          "binary"
                        ];
                        default = "str";
                        description = ''
                          Format determines encoding before SOPS encryption:
                          - str: Plain string (for Kubernetes stringData)
                          - base64: Base64 encoded (for Kubernetes data field)
                          - binary: Entire file encrypted as binary (no YAML wrapping)
                        '';
                      };
                    };
                  }
                );
                default = null;
                description = ''
                  SOPS output configuration for this secret.
                  If null, this secret will not be converted to SOPS format.
                '';
              };

              sopsRef = mkOption {
                type = types.str;
                readOnly = true;
                default =
                  if config.sopsOutput == null then
                    throw "age.secrets.${name}.sopsRef: sopsOutput must be defined to compute sopsRef"
                  else
                    let
                      # For derivation mode, use the store path
                      # For local mode, use outputDir
                      basePath =
                        if cfg.rekey.storageMode == "derivation" then
                          if sopsSecrets == null then
                            throw "age.secrets.${name}.sopsRef: SOPS derivation not built"
                          else
                            toString sopsSecrets
                        else if cfg.sops.outputDir != null then
                          builtins.unsafeDiscardStringContext (toString cfg.sops.outputDir)
                        else
                          throw "age.secrets.${name}.sopsRef: outputDir must be set when storageMode = \"local\"";

                      fileName =
                        if config.sopsOutput.format == "binary" then
                          "${config.sopsOutput.file}.enc"
                        else
                          "${config.sopsOutput.file}.enc.yaml";

                      fragment = if config.sopsOutput.format == "binary" then "" else "#${config.sopsOutput.key}";
                    in
                    "ref+sops://${basePath}/${fileName}${fragment}";
                defaultText = literalExpression ''
                  if storageMode == "derivation"
                  then "ref+sops://''${derivation}/''${file}.enc.yaml#''${key}"
                  else "ref+sops://''${outputDir}/''${file}.enc.yaml#''${key}"
                '';
                description = ''
                  The vals URI for referencing this secret in nixidy manifests.
                  This is a computed read-only attribute based on sopsOutput configuration.

                  In derivation mode, points to /nix/store path.
                  In local mode, points to outputDir path.

                  Use this in your Kubernetes Secret definitions like:
                    stringData.password = config.age.secrets."my-secret".sopsRef;
                '';
              };
            };
          }
        )
      );
    };

    # Add SOPS-specific top-level option
    sops = mkOption {
      type = types.submodule {
        options = {
          outputDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              The directory where SOPS encrypted files will be written.
              Must be constructed using path concatenation from your flake root.

              Only used when storageMode = "local".
              Example: ./. + "/.secrets/env/production"
            '';
          };

          defaultFile = mkOption {
            type = types.str;
            default = "sops-secrets";
            description = ''
              Default SOPS file name to use for secrets that don't specify sopsOutput.file.

              Secrets with rekeyFile but without sopsOutput will automatically
              be added to this SOPS file using their secret name as the key.

              Example: "secrets" will create secrets.enc.yaml
            '';
            example = "secrets";
          };

          recipients = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              Age recipients (public keys) to encrypt SOPS files to.

              If null (default), recipients are extracted from masterIdentities.
              If specified, these recipients are used instead for SOPS encryption.

              This allows encrypting SOPS outputs to different keys than the
              master identities used to decrypt source age files (e.g., CI-only keys).
            '';
            example = literalExpression ''
              [
                "age1ci_server_key..."
                "ssh-ed25519 AAAAC3NzaC1lZDI1NT..."
              ]
            '';
          };
        };
      };
      description = ''
        SOPS configuration for this nixidy environment.
      '';
    };
  };
}
