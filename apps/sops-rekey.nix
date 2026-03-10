{
  pkgs,
  nodes,
  userFlake,
  agePackage,
  ...
}:
let
  inherit (pkgs.lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    getExe
    groupBy
    hasPrefix
    makeBinPath
    mapAttrsToList
    removePrefix
    unique
    ;

  # Build our own age master decrypt command
  userFlakeDir = toString userFlake.outPath;

  # Collect master identities from all SOPS nodes
  mergedMasterIdentities = unique (
    builtins.concatLists (
      builtins.map (x: x.config.age.rekey.masterIdentities or [ ]) (
        builtins.attrValues (filterAttrs (_n: v: v ? config.age.sops) nodes)
      )
    )
  );

  # Collect age plugins
  mergedAgePlugins = unique (
    builtins.concatLists (
      builtins.map (x: x.config.age.rekey.agePlugins or [ ]) (
        builtins.attrValues (filterAttrs (_n: v: v ? config.age.sops) nodes)
      )
    )
  );

  ageProgram = getExe agePackage;
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") mergedAgePlugins}'';

  toIdentityArgs = identities: concatStringsSep " " (builtins.map (x: "-i ${x.identity}") identities);
  decryptionMasterIdentityArgs = toIdentityArgs mergedMasterIdentities;

  ageMasterDecrypt = "${envPath} ${ageProgram} -d ${decryptionMasterIdentityArgs}";

  # SOPS extension: Filter for nodes with SOPS configuration
  # Works with any extraConfiguration (nixidy, terranix, etc) that has config.age.sops
  sopsNodes = filterAttrs (_n: v: v ? config.age.sops) nodes;

  # Helper to convert path relative to flake root
  relativeToFlake =
    filePath:
    let
      fileStr = builtins.unsafeDiscardStringContext (toString filePath);
    in
    if hasPrefix userFlakeDir fileStr then
      "." + removePrefix userFlakeDir fileStr
    else
      throw "Cannot determine true origin of ${fileStr} which doesn't seem to be a direct subpath of the flake directory ${userFlakeDir}";

  # Generate SOPS file for a group of secrets
  generateSopsFileScript =
    hostName: fileName: secrets:
    let
      hostCfg = (builtins.head secrets).hostConfig;
      outputDir = builtins.unsafeDiscardStringContext (toString hostCfg.age.sops.outputDir);
      sopsConfig = relativeToFlake hostCfg.age.sops.configFile;
      relativeOutputDir = relativeToFlake outputDir;
      outputPath = "${relativeOutputDir}/${fileName}.enc.yaml";

      # Generate YAML entry for a secret
      generateYamlEntry =
        secret:
        let
          # Base64 encode if needed
          encodeCmd =
            if secret.sopsOutput.format == "base64" then " | ${pkgs.coreutils}/bin/base64 -w0" else "";
          # Convert rekeyFile to relative path
          rekeyFileRelative = relativeToFlake secret.rekeyFile;
        in
        ''
          # Decrypt and encode ${secret.name}
          secret_value=$(${ageMasterDecrypt} ${escapeShellArg rekeyFileRelative}${encodeCmd})
          echo "${escapeShellArg secret.sopsOutput.key}: $secret_value" >> "$yaml_tmp"
        '';
    in
    ''
      echo "[1;32m  Generating[m [90mSOPS file [33m${hostName}[90m:[34m${fileName}.enc.yaml[m"

      # Create temp YAML file
      yaml_tmp=$(${pkgs.coreutils}/bin/mktemp)
      trap "rm -f $yaml_tmp" EXIT

      ${concatMapStrings generateYamlEntry secrets}

      # Encrypt with SOPS (use --filename-override for creation rule matching)
      mkdir -p ${escapeShellArg relativeOutputDir}
      if ${pkgs.sops}/bin/sops -e \
        --config ${escapeShellArg sopsConfig} \
        --filename-override ${escapeShellArg outputPath} \
        "$yaml_tmp" > ${escapeShellArg outputPath}; then
        echo "[1;32m      Created[m [34m${outputPath}[m"
      else
        echo "[1;31m      Failed to encrypt ${outputPath}[m" >&2
        rm -f "$yaml_tmp"
        exit 1
      fi

      rm -f "$yaml_tmp"

      # Track for git add
      SOPS_FILES+=("${outputPath}")
    '';

  # Generate binary SOPS file
  generateBinarySecretScript =
    secret:
    let
      outputDir = builtins.unsafeDiscardStringContext (toString secret.hostConfig.age.sops.outputDir);
      sopsConfig = relativeToFlake secret.hostConfig.age.sops.configFile;
      relativeOutputDir = relativeToFlake outputDir;
      outputPath = "${relativeOutputDir}/${secret.sopsOutput.file}.enc";
      # Convert rekeyFile to relative path
      rekeyFileRelative = relativeToFlake secret.rekeyFile;
    in
    ''
      echo "[1;32m  Generating[m [90mbinary SOPS file [34m${secret.name}[m"

      # Create temp file for decrypted content
      binary_tmp=$(${pkgs.coreutils}/bin/mktemp)
      trap "rm -f $binary_tmp" EXIT

      # Decrypt to temp file
      ${ageMasterDecrypt} ${escapeShellArg rekeyFileRelative} > "$binary_tmp"

      # Encrypt entire file with SOPS (use --filename-override for creation rule matching)
      mkdir -p ${escapeShellArg relativeOutputDir}
      if ${pkgs.sops}/bin/sops -e \
        --config ${escapeShellArg sopsConfig} \
        --filename-override ${escapeShellArg outputPath} \
        "$binary_tmp" > ${escapeShellArg outputPath}; then
        echo "[1;32m      Created[m [34m${outputPath}[m"
      else
        echo "[1;31m      Failed to encrypt ${outputPath}[m" >&2
        rm -f "$binary_tmp"
        exit 1
      fi

      rm -f "$binary_tmp"

      # Track for git add
      SOPS_FILES+=("${outputPath}")
    '';

  # Generate commands for a single nixidy host
  commandsForNixidyHost =
    hostName: hostCfg:
    let
      # Get all secrets with sopsOutput defined
      sopsSecrets = filterAttrs (
        _name: secret: secret ? sopsOutput && secret.rekeyFile != null && !secret.intermediary
      ) hostCfg.config.age.secrets;

      # Convert to list with metadata
      secretsList = mapAttrsToList (
        name: secret:
        secret
        // {
          inherit name;
          hostConfig = hostCfg.config;
        }
      ) sopsSecrets;

      # Partition by format
      groupableSecrets = builtins.filter (s: s.sopsOutput.format != "binary") secretsList;
      binarySecrets = builtins.filter (s: s.sopsOutput.format == "binary") secretsList;

      # Group str/base64 secrets by file
      grouped = groupBy (s: s.sopsOutput.file) groupableSecrets;
    in
    if secretsList == [ ] then
      ""
    else
      ''
        echo "[1;36m   Generating SOPS files for[m [32m${hostName}[m"

        # Generate grouped YAML files
        ${concatStringsSep "\n" (
          mapAttrsToList (fileName: secrets: generateSopsFileScript hostName fileName secrets) grouped
        )}

        # Generate binary files
        ${concatMapStrings generateBinarySecretScript binarySecrets}
      '';

  # Appended to PATH
  binPath = makeBinPath (
    with pkgs;
    [
      coreutils
      git
      sops
    ]
  );

in
pkgs.writeShellScriptBin "agenix-sops-rekey" ''
  set -euo pipefail

  export PATH="''${PATH:+"''${PATH}:"}"${escapeShellArg binPath}

  function die() { echo "[1;31merror:[m $*" >&2; exit 1; }

  function show_help() {
    echo 'Usage: agenix sops-rekey [OPTIONS]'
    echo "Generate SOPS-encrypted files for nixidy configurations."
    echo ""
    echo 'OPTIONS:'
    echo '-h, --help                Show help'
    echo '-a, --add-to-git          Add generated SOPS files to git'
    echo '-f, --force               Force regeneration even if files exist'
  }

  ADD_TO_GIT=''${AGENIX_SOPS_ADD_TO_GIT-false}
  FORCE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      "help"|"--help"|"-help"|"-h")
        show_help
        exit 0
        ;;
      "-a"|"--add-to-git") ADD_TO_GIT=true ;;
      "-f"|"--force") FORCE=true ;;
      *) die "Invalid option '$1'" ;;
    esac
    shift
  done

  if [[ ! -e flake.nix ]]; then
    die "Please execute this script from your flake's root directory."
  fi

  # Track all generated SOPS files for git add
  SOPS_FILES=()

  ${
    if sopsNodes == { } then
      ''
        echo "[1;33mNo SOPS configurations found.[m"
        echo "Add extraConfigurations with age.sops schema to your flake to use sops-rekey."
        exit 0
      ''
    else
      concatStringsSep "\n" (mapAttrsToList commandsForNixidyHost sopsNodes)
  }

  # Add to git if requested
  if [[ "$ADD_TO_GIT" == true && ''${#SOPS_FILES[@]} -gt 0 ]]; then
    echo "[1;36m   Adding[m [36m''${#SOPS_FILES[@]} SOPS files to git[m"
    git add "''${SOPS_FILES[@]}"
  fi

  echo "[1;32m✓ SOPS generation complete[m"
''
