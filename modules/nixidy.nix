_nixpkgs:
{
  lib,
  config,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    literalExpression
    ;

  cfg = config.age;

  secretType = types.submodule (
    { name, config, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "The name of the secret.";
        };

        rekeyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            The path to the encrypted .age file for this secret. The file must
            be encrypted with one of the given master identities and not with
            a host-specific key.
          '';
        };

        generator = mkOption {
          type = types.nullOr (
            types.either types.str (
              types.submodule {
                options = {
                  script = mkOption {
                    type = types.either types.str (types.functionTo types.str);
                    description = "The generator script or reference to a named generator.";
                  };

                  dependencies = mkOption {
                    type = types.oneOf [
                      (types.listOf types.unspecified)
                      (types.attrsOf types.unspecified)
                    ];
                    default = [ ];
                    description = "Other secrets on which this secret depends.";
                  };

                  tags = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = "Optional list of tags for grouping secrets.";
                  };
                };
              }
            )
          );
          default = null;
          description = ''
            If defined, this generator will be used to bootstrap this secret when it doesn't exist.
          '';
        };

        intermediary = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether the secret is only required as an intermediary/repository secret and
            should not be rekeyed for deployment.
          '';
        };

        sopsOutput = mkOption {
          type = types.submodule {
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
          };
          description = ''
            SOPS output configuration for this secret.
          '';
        };

        sopsRef = mkOption {
          type = types.str;
          readOnly = true;
          default =
            let
              # Convert outputDir to string without checking existence
              outputDirStr = builtins.unsafeDiscardStringContext (toString cfg.sops.outputDir);
            in
            if config.sopsOutput.format == "binary" then
              "ref+sops://${outputDirStr}/${config.sopsOutput.file}.enc"
            else
              "ref+sops://${outputDirStr}/${config.sopsOutput.file}.enc.yaml#${config.sopsOutput.key}";
          defaultText = literalExpression ''
            if format == "binary"
            then "ref+sops://''${outputDir}/''${file}.enc"
            else "ref+sops://''${outputDir}/''${file}.enc.yaml#''${key}"
          '';
          description = ''
            The vals URI for referencing this secret in nixidy manifests.
            This is a computed read-only attribute based on sopsOutput configuration.

            Use this in your Kubernetes Secret definitions like:
              stringData.password = config.age.secrets."my-secret".sopsRef;
          '';
        };
      };
    }
  );

in
{
  options.age = {
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = { };
      description = ''
        Attrset of secrets for this nixidy configuration.
        Each secret will be generated from its rekeyFile and converted to SOPS format.
      '';
    };

    generators = mkOption {
      type = types.attrsOf (types.functionTo types.str);
      default = { };
      description = ''
        Attrset of reusable secret generator scripts.
        These can be referenced by name in secret generator definitions.
      '';
    };

    sops = mkOption {
      type = types.submodule {
        options = {
          configFile = mkOption {
            type = types.path;
            default = ./.sops.yaml;
            description = ''
              Path to the .sops.yaml configuration file.
              This file defines the age/pgp keys used for SOPS encryption.
            '';
          };

          outputDir = mkOption {
            type = types.path;
            description = ''
              The directory where SOPS encrypted files will be written.
              Must be constructed using path concatenation from your flake root.

              Example: ./. + "/.secrets/env/production"
            '';
          };
        };
      };
      description = ''
        SOPS configuration for this nixidy environment.
      '';
    };

    rekey = mkOption {
      type = types.submodule {
        options = {
          masterIdentities = mkOption {
            type =
              let
                identityPathType = types.coercedTo types.path toString types.str;
              in
              types.listOf (
                types.coercedTo identityPathType (p: if builtins.isAttrs p then p else { identity = p; }) (
                  types.submodule {
                    options = {
                      identity = mkOption {
                        type = identityPathType;
                        description = "Path to the master identity file.";
                      };
                      pubkey = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = "Optional explicit public key.";
                      };
                    };
                  }
                )
              );
            default = [ ];
            description = ''
              The list of age identities that will be used for decrypting the stored secrets
              to rekey them into SOPS format.
            '';
          };

          agePlugins = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = ''
              A list of age plugins that should be available during rekeying.
            '';
          };

          generatedSecretsDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              The path where all generated secrets should be stored by default.
            '';
          };
        };
      };
      default = { };
      description = ''
        Rekeying configuration for master identities and plugins.
      '';
    };
  };
}
