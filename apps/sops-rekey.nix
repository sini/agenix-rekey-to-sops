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
    splitString
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

  ageProgram = getExe (if builtins.isFunction agePackage then agePackage pkgs else agePackage);
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") mergedAgePlugins}'';

  toIdentityArgs = identities: concatStringsSep " " (builtins.map (x: "-i ${x.identity}") identities);
  decryptionMasterIdentityArgs = toIdentityArgs mergedMasterIdentities;

  ageMasterDecrypt = "${envPath} ${ageProgram} -d ${decryptionMasterIdentityArgs}";

  # Extract age recipient public key from a master identity file
  extractRecipient =
    identity:
    if identity.pubkey or null != null then
      identity.pubkey
    else
      let
        content = builtins.readFile identity.identity;
        lines = splitString "\n" content;
        recipientLines = builtins.filter (
          l: builtins.match ".*Recipient: age1.*" l != null || builtins.match ".*public key: age1.*" l != null
        ) lines;
      in
      if recipientLines == [ ] then
        throw "Cannot extract age recipient from ${identity.identity}. Set pubkey explicitly in masterIdentities."
      else
        let
          line = builtins.head recipientLines;
          matched = builtins.match ".*(age1[a-z0-9]+).*" line;
        in
        if matched != null then builtins.head matched else throw "Cannot parse age recipient from: ${line}";

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
    sopsAgeRecipients: hostName: fileName: secrets:
    let
      hostCfg = (builtins.head secrets).hostConfig;
      outputDir = builtins.unsafeDiscardStringContext (toString hostCfg.age.sops.outputDir);
      relativeOutputDir = relativeToFlake outputDir;
      outputPath = "${relativeOutputDir}/${fileName}.enc.yaml";

      # Get all rekey files for validation
      rekeyFiles = builtins.map (s: relativeToFlake s.rekeyFile) secrets;

      # Get expected keys for comparison
      expectedKeys = builtins.sort builtins.lessThan (builtins.map (s: s.sopsOutput.key) secrets);
      expectedKeysJson = builtins.toJSON expectedKeys;

      # Generate YAML entry for a secret (using pre-decrypted file)
      generateYamlEntry =
        secret:
        let
          # Base64 encode if needed
          encodeCmd =
            if secret.sopsOutput.format == "base64" then " | ${pkgs.coreutils}/bin/base64 -w0" else "";
          # Convert rekeyFile to relative path
          rekeyFileRelative = relativeToFlake secret.rekeyFile;
          # Escaped path for lookup
          escapedPath = escapeShellArg rekeyFileRelative;
        in
        ''
          # Get pre-decrypted value for ${secret.name}
          if [[ -f "$DECRYPT_DIR/${escapedPath}" ]]; then
            secret_value=$(cat "$DECRYPT_DIR/${escapedPath}"${encodeCmd})
          else
            echo -e "\033[1;31m      Error: Decrypted file missing for ${escapedPath}\033[m" >&2
            exit 1
          fi
          echo "${escapeShellArg secret.sopsOutput.key}: $secret_value" >> "$yaml_tmp"
        '';
    in
    ''
      echo -e "\033[1;32m  Generating\033[m \033[90mSOPS file \033[33m${hostName}\033[90m:\033[34m${fileName}.enc.yaml\033[m"

      # Check if we can skip generation
      skip_generation=false
      needs_regeneration=false

      if [[ -f ${escapeShellArg outputPath} ]]; then
        # Check if SOPS recipients have changed
        existing_recipients=$(${pkgs.sops}/bin/sops -d --extract '["sops"]["age"]' ${escapeShellArg outputPath} 2>/dev/null | ${pkgs.yq-go}/bin/yq eval 'map(.recipient) | sort | @json' - 2>/dev/null || echo "[]")
        expected_recipients=$(echo ${escapeShellArg sopsAgeRecipients} | tr ',' '\n' | sort | ${pkgs.jq}/bin/jq -R . | ${pkgs.jq}/bin/jq -s .)

        if [[ "$existing_recipients" != "$expected_recipients" ]]; then
          echo -e "\033[1;33m      Recipients changed, regenerating\033[m"
          needs_regeneration=true
        fi

        # Check if key set matches
        if [[ "$needs_regeneration" == false ]]; then
          existing_keys=$(${pkgs.sops}/bin/sops -d ${escapeShellArg outputPath} 2>/dev/null | ${pkgs.yq-go}/bin/yq eval 'keys | sort | @json' - 2>/dev/null || echo "[]")
          expected_keys=${escapeShellArg expectedKeysJson}

          if [[ "$existing_keys" != "$expected_keys" ]]; then
            echo -e "\033[1;33m      Key set changed (expected: $expected_keys, got: $existing_keys), regenerating\033[m"
            needs_regeneration=true
          fi
        fi

        if [[ "$needs_regeneration" == false ]]; then
          # Keys match, check if all input files exist
          missing_inputs=false
          ${concatMapStrings (f: ''
            escapedPath=${escapeShellArg (escapeShellArg f)}
            if [[ ! -f "$DECRYPT_DIR/$escapedPath" ]]; then
              echo -e "\033[1;33m      Decrypted input missing: ${escapeShellArg f}, regenerating\033[m"
              missing_inputs=true
            fi
          '') rekeyFiles}

          if [[ "$missing_inputs" == true ]]; then
            needs_regeneration=true
          else
            # All inputs exist, compare plaintext content
            yaml_tmp=$(${pkgs.coreutils}/bin/mktemp)
            trap "rm -f $yaml_tmp" EXIT

            ${concatMapStrings generateYamlEntry secrets}

            # Compare plaintext YAML with decrypted existing file
            existing_decrypted=$(${pkgs.sops}/bin/sops -d ${escapeShellArg outputPath} 2>/dev/null | sort)
            new_plaintext=$(sort "$yaml_tmp")

            if [[ "$existing_decrypted" == "$new_plaintext" ]]; then
              echo -e "\033[1;90m      Unchanged, skipping\033[m"
              skip_generation=true
            else
              echo -e "\033[1;33m      Content changed, regenerating\033[m"
              needs_regeneration=true
            fi

            rm -f "$yaml_tmp"
          fi
        fi
      else
        needs_regeneration=true
      fi

      if [[ "$skip_generation" == false && "$needs_regeneration" == true ]]; then
        # Generate new file
        yaml_tmp=$(${pkgs.coreutils}/bin/mktemp)
        trap "rm -f $yaml_tmp" EXIT

        ${concatMapStrings generateYamlEntry secrets}

        # Encrypt with SOPS using age recipients from masterIdentities
        mkdir -p ${escapeShellArg relativeOutputDir}
        if ${pkgs.sops}/bin/sops -e \
          --config ${escapeShellArg "${relativeOutputDir}/.sops.yaml"} \
          --age ${escapeShellArg sopsAgeRecipients} \
          --output-type yaml \
          "$yaml_tmp" > ${escapeShellArg outputPath}; then
          echo -e "\033[1;32m      Created\033[m \033[34m${outputPath}\033[m"
        else
          echo -e "\033[1;31m      Failed to encrypt ${outputPath}\033[m" >&2
          rm -f "$yaml_tmp"
          exit 1
        fi

        rm -f "$yaml_tmp"
      fi

      # Track for git add
      SOPS_FILES+=("${outputPath}")
    '';

  # Generate binary SOPS file
  generateBinarySecretScript =
    sopsAgeRecipients: secret:
    let
      outputDir = builtins.unsafeDiscardStringContext (toString secret.hostConfig.age.sops.outputDir);
      relativeOutputDir = relativeToFlake outputDir;
      outputPath = "${relativeOutputDir}/${secret.sopsOutput.file}.enc";
      # Convert rekeyFile to relative path
      rekeyFileRelative = relativeToFlake secret.rekeyFile;
    in
    ''
      echo -e "\033[1;32m  Generating\033[m \033[90mbinary SOPS file \033[34m${secret.name}\033[m"

      # Check if we can skip generation
      skip_generation=false
      needs_regeneration=false

      escapedPath=${escapeShellArg (escapeShellArg rekeyFileRelative)}

      if [[ -f ${escapeShellArg outputPath} ]]; then
        # Check if decrypted input exists
        if [[ ! -f "$DECRYPT_DIR/$escapedPath" ]]; then
          echo -e "\033[1;33m      Decrypted input missing: ${escapeShellArg rekeyFileRelative}, regenerating\033[m"
          needs_regeneration=true
        else
          # Compare plaintext content with pre-decrypted file
          existing_decrypted=$(${pkgs.sops}/bin/sops -d ${escapeShellArg outputPath} 2>/dev/null)
          new_plaintext=$(cat "$DECRYPT_DIR/$escapedPath")

          if [[ "$existing_decrypted" == "$new_plaintext" ]]; then
            echo -e "\033[1;90m      Unchanged, skipping\033[m"
            skip_generation=true
          else
            echo -e "\033[1;33m      Content changed, regenerating\033[m"
            needs_regeneration=true
          fi
        fi
      else
        needs_regeneration=true
      fi

      if [[ "$skip_generation" == false && "$needs_regeneration" == true ]]; then
        # Verify decrypted input file exists
        if [[ ! -f "$DECRYPT_DIR/$escapedPath" ]]; then
          echo -e "\033[1;31m      Error: Cannot generate SOPS file - missing decrypted file: ${escapeShellArg rekeyFileRelative}\033[m" >&2
          echo -e "\033[1;33m      Run 'agenix generate' to create missing secrets\033[m" >&2
          exit 1
        fi

        # Encrypt entire file with SOPS using age recipients from masterIdentities
        mkdir -p ${escapeShellArg relativeOutputDir}
        if ${pkgs.sops}/bin/sops -e \
          --config ${escapeShellArg "${relativeOutputDir}/.sops.yaml"} \
          --age ${escapeShellArg sopsAgeRecipients} \
          "$DECRYPT_DIR/$escapedPath" > ${escapeShellArg outputPath}; then
          echo -e "\033[1;32m      Created\033[m \033[34m${outputPath}\033[m"
        else
          echo -e "\033[1;31m      Failed to encrypt ${outputPath}\033[m" >&2
          exit 1
        fi
      fi

      # Track for git add
      SOPS_FILES+=("${outputPath}")
    '';

  # Generate .sops.yaml content for a set of recipients
  sopsYamlContent =
    recipients:
    concatStringsSep "\n" [
      "creation_rules:"
      "  - path_regex: .*"
      "    age: ${concatStringsSep "," recipients}"
    ];

  # Generate commands for a single nixidy host
  commandsForNixidyHost =
    hostName: hostCfg:
    let
      # Extract recipients from this host's master identities
      hostMasterIdentities = hostCfg.config.age.rekey.masterIdentities or [ ];
      hostRecipients = unique (builtins.map extractRecipient hostMasterIdentities);
      sopsAgeRecipients = concatStringsSep "," hostRecipients;

      defaultFile = hostCfg.config.age.sops.defaultFile;
      outputDir = builtins.unsafeDiscardStringContext (toString hostCfg.config.age.sops.outputDir);
      relativeOutputDir = relativeToFlake outputDir;

      # Get all secrets with sopsOutput defined or a rekeyFile (using defaultFile fallback)
      sopsSecrets = filterAttrs (
        _name: secret:
        secret.rekeyFile != null && !secret.intermediary && (secret ? sopsOutput || defaultFile != null)
      ) hostCfg.config.age.secrets;

      # Convert to list with metadata, synthesizing sopsOutput for secrets that use defaultFile
      secretsList = mapAttrsToList (
        name: secret:
        let
          sopsOutput =
            if secret ? sopsOutput && secret.sopsOutput != null then
              secret.sopsOutput
            else
              {
                file = defaultFile;
                key = name;
                format = "str";
              };
        in
        secret
        // {
          inherit name sopsOutput;
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
        echo -e "\033[1;36m   Generating SOPS files for\033[m \033[32m${hostName}\033[m"

        # Write .sops.yaml to outputDir for manual SOPS operations (sops edit, sops -d)
        mkdir -p ${escapeShellArg relativeOutputDir}
        printf '%s\n' ${escapeShellArg (sopsYamlContent hostRecipients)} > ${escapeShellArg "${relativeOutputDir}/.sops.yaml"}
        echo -e "\033[1;32m  Generated\033[m \033[90m.sops.yaml in \033[34m${relativeOutputDir}\033[m"
        SOPS_FILES+=("${relativeOutputDir}/.sops.yaml")

        # Generate grouped YAML files
        ${concatStringsSep "\n" (
          mapAttrsToList (
            fileName: secrets: generateSopsFileScript sopsAgeRecipients hostName fileName secrets
          ) grouped
        )}

        # Generate binary files
        ${concatMapStrings (generateBinarySecretScript sopsAgeRecipients) binarySecrets}
      '';

  # Appended to PATH
  binPath = makeBinPath (
    with pkgs;
    [
      coreutils
      git
      jq
      sops
      yq-go
    ]
  );

in
pkgs.writeShellScriptBin "agenix-sops-rekey" ''
  set -euo pipefail

  export PATH="''${PATH:+"''${PATH}:"}"${escapeShellArg binPath}

  function die() { echo -e "\033[1;31merror:\033[m $*" >&2; exit 1; }

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
        echo -e "\033[1;33mNo SOPS configurations found.\033[m"
        echo "Add extraConfigurations with age.sops schema to your flake to use sops-rekey."
        exit 0
      ''
    else
      let
        # Collect all unique age files that need decryption
        allRekeyFiles = unique (
          builtins.concatLists (
            mapAttrsToList (
              _hostName: hostCfg:
              let
                sopsSecrets = filterAttrs (
                  _name: secret: secret ? sopsOutput && secret.rekeyFile != null && !secret.intermediary
                ) hostCfg.config.age.secrets;
              in
              builtins.map (s: relativeToFlake s.rekeyFile) (builtins.attrValues sopsSecrets)
            ) sopsNodes
          )
        );
      in
      ''
        # Create temp directory for decrypted age files
        DECRYPT_DIR=$(mktemp -d)
        trap 'rm -rf "$DECRYPT_DIR"' EXIT

        echo -e "\033[1;36m   Decrypting age inputs (YubiKey unlock for age plugin)...\033[m"

        # Decrypt all age files upfront to minimize YubiKey unlocks
        ${concatMapStrings (rekeyFile: ''
          file_path=${escapeShellArg rekeyFile}
          escaped_path=${escapeShellArg (escapeShellArg rekeyFile)}

          # Create directory structure
          mkdir -p "$(dirname "$DECRYPT_DIR/$escaped_path")"

          # Decrypt file
          if ${ageMasterDecrypt} "$file_path" > "$DECRYPT_DIR/$escaped_path" 2>/dev/null; then
            echo -e "\033[1;90m      Decrypted: $file_path\033[m"
          else
            echo -e "\033[1;31m      Failed to decrypt: $file_path\033[m" >&2
            exit 1
          fi
        '') allRekeyFiles}

        echo -e "\033[1;32m   Decrypted ${builtins.toString (builtins.length allRekeyFiles)} age files\033[m"
        echo ""

        ${concatStringsSep "\n" (mapAttrsToList commandsForNixidyHost sopsNodes)}
      ''
  }

  # Add to git if requested
  if [[ "$ADD_TO_GIT" == true && ''${#SOPS_FILES[@]} -gt 0 ]]; then
    echo -e "\033[1;36m   Adding\033[m \033[36m''${#SOPS_FILES[@]} SOPS files to git\033[m"
    git add "''${SOPS_FILES[@]}"
  fi

  echo -e "\033[1;32m✓ SOPS generation complete\033[m"
''
