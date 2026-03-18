{
  pkgs,
  hostConfig,
  agePackage,
}:
let
  inherit (pkgs.lib)
    concatMapStrings
    concatStringsSep
    escapeShellArg
    filterAttrs
    getExe
    groupBy
    makeBinPath
    mapAttrsToList
    splitString
    unique
    ;

  cfg = hostConfig.age;

  # Collect master identities
  masterIdentities = cfg.rekey.masterIdentities;
  agePlugins = cfg.rekey.agePlugins;

  # Copy master identity files to store as standalone paths (for remote builders)
  masterIdentityPaths = map (i: builtins.path { path = i.identity; }) masterIdentities;

  ageProgram = getExe agePackage;
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") agePlugins}'';

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

  # Extract unique recipients for SOPS encryption
  sopsRecipients = unique (builtins.map extractRecipient masterIdentities);
  sopsAgeRecipients = concatStringsSep "," sopsRecipients;

  # Generate .sops.yaml content
  sopsYamlContent = concatStringsSep "\n" [
    "creation_rules:"
    "  - path_regex: .*"
    "    age: ${sopsAgeRecipients}"
  ];

  # Filter secrets with SOPS output configured
  sopsSecrets = filterAttrs (
    _name: secret:
    secret ? sopsOutput && secret.sopsOutput != null && secret.rekeyFile != null && !secret.intermediary
  ) cfg.secrets;

  # Convert to list with metadata
  secretsList = mapAttrsToList (name: secret: secret // { inherit name; }) sopsSecrets;

  # Partition by format
  groupableSecrets = builtins.filter (s: s.sopsOutput.format != "binary") secretsList;
  binarySecrets = builtins.filter (s: s.sopsOutput.format == "binary") secretsList;

  # Group str/base64 secrets by file
  grouped = groupBy (s: s.sopsOutput.file) groupableSecrets;

  # Generate script to create a SOPS YAML file
  generateSopsFileScript =
    fileName: secrets:
    let
      outputPath = "${fileName}.enc.yaml";

      # Generate YAML entry for a secret
      generateYamlEntry =
        secret:
        let
          # Base64 encode if needed
          encodeCmd =
            if secret.sopsOutput.format == "base64" then " | ${pkgs.coreutils}/bin/base64 -w0" else "";
        in
        ''
          # Decrypt and encode ${secret.name}
          secret_value=$(${envPath} ${ageProgram} -d ${
            concatMapStrings (x: "-i \"${x}\" ") masterIdentityPaths
          }"${secret.rekeyFile}"${encodeCmd})
          echo "${escapeShellArg secret.sopsOutput.key}: $secret_value" >> "$yaml_tmp"
        '';
    in
    ''
      echo "Generating SOPS file: ${outputPath}"

      # Create temp YAML file
      yaml_tmp=$(mktemp)
      trap "rm -f $yaml_tmp" EXIT

      ${concatMapStrings generateYamlEntry secrets}

      # Encrypt with SOPS
      ${pkgs.sops}/bin/sops -e \
        --config "$out/.sops.yaml" \
        --age ${escapeShellArg sopsAgeRecipients} \
        --output-type yaml \
        "$yaml_tmp" > "$out/${outputPath}"

      rm -f "$yaml_tmp"
    '';

  # Generate script to create a binary SOPS file
  generateBinarySecretScript =
    secret:
    let
      outputPath = "${secret.sopsOutput.file}.enc";
    in
    ''
      echo "Generating binary SOPS file: ${outputPath}"

      # Create temp file for decrypted content
      binary_tmp=$(mktemp)
      trap "rm -f $binary_tmp" EXIT

      # Decrypt to temp file
      ${envPath} ${ageProgram} -d ${
        concatMapStrings (x: "-i \"${x}\" ") masterIdentityPaths
      }"${secret.rekeyFile}" > "$binary_tmp"

      # Encrypt with SOPS
      ${pkgs.sops}/bin/sops -e \
        --config "$out/.sops.yaml" \
        --age ${escapeShellArg sopsAgeRecipients} \
        "$binary_tmp" > "$out/${outputPath}"

      rm -f "$binary_tmp"
    '';

  # Build the full generation script
  generationScript = ''
    set -euo pipefail

    export PATH="${
      makeBinPath (
        with pkgs;
        [
          coreutils
          sops
        ]
        ++ agePlugins
      )
    }"
    ${envPath}

    mkdir -p "$out"

    # Write .sops.yaml for manual SOPS operations
    printf '%s\n' ${escapeShellArg sopsYamlContent} > "$out/.sops.yaml"

    # Generate grouped YAML files
    ${concatStringsSep "\n" (mapAttrsToList generateSopsFileScript grouped)}

    # Generate binary files
    ${concatMapStrings generateBinarySecretScript binarySecrets}

    echo "SOPS secrets generated successfully in $out"
  '';

in
pkgs.runCommand "sops-secrets-${cfg.rekey.recipientIdentifier}" {
  nativeBuildInputs = [
    agePackage
    pkgs.sops
  ]
  ++ agePlugins;
  inherit masterIdentityPaths;
  # Prefer building locally for hardware key access (YubiKey, etc.)
  preferLocalBuild = true;
  # Don't allow substituting from binary cache since this depends on local secrets
  allowSubstitutes = false;
} generationScript
