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
    ;

  cfg = hostConfig.age;

  # Collect master identities
  masterIdentities = cfg.rekey.masterIdentities;
  agePlugins = cfg.rekey.agePlugins;

  # Copy master identity files to store as standalone paths (for remote builders)
  masterIdentityPaths = map (i: builtins.path { path = i.identity; }) masterIdentities;

  ageProgram = getExe agePackage;
  envPath = ''PATH="$PATH"${concatMapStrings (x: ":${escapeShellArg x}/bin") agePlugins}'';

  # Filter secrets with SOPS output configured
  sopsSecrets = filterAttrs (
    _name: secret: secret ? sopsOutput && secret.sopsOutput != null && secret.rekeyFile != null && !secret.intermediary
  ) cfg.secrets;

  # Convert to list with metadata
  secretsList = mapAttrsToList (
    name: secret:
    secret // { inherit name; }
  ) sopsSecrets;

  # Partition by format
  groupableSecrets = builtins.filter (s: s.sopsOutput.format != "binary") secretsList;
  binarySecrets = builtins.filter (s: s.sopsOutput.format == "binary") secretsList;

  # Group str/base64 secrets by file
  grouped = groupBy (s: s.sopsOutput.file) groupableSecrets;

  # Generate script to create a SOPS YAML file
  generateSopsFileScript =
    fileName: secrets:
    let
      sopsConfig = cfg.sops.configFile;
      outputPath = "${fileName}.enc.yaml";

      # Generate YAML entry for a secret
      generateYamlEntry =
        secret:
        let
          # Base64 encode if needed
          encodeCmd = if secret.sopsOutput.format == "base64" then " | ${pkgs.coreutils}/bin/base64 -w0" else "";
        in
        ''
          # Decrypt and encode ${secret.name}
          secret_value=$(${envPath} ${ageProgram} -d ${concatMapStrings (x: "-i \"${x}\" ") masterIdentityPaths}"${secret.rekeyFile}"${encodeCmd})
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
        --config ${escapeShellArg sopsConfig} \
        --filename-override "$out/${outputPath}" \
        "$yaml_tmp" > "$out/${outputPath}"

      rm -f "$yaml_tmp"
    '';

  # Generate script to create a binary SOPS file
  generateBinarySecretScript =
    secret:
    let
      sopsConfig = cfg.sops.configFile;
      outputPath = "${secret.sopsOutput.file}.enc";
    in
    ''
      echo "Generating binary SOPS file: ${outputPath}"

      # Create temp file for decrypted content
      binary_tmp=$(mktemp)
      trap "rm -f $binary_tmp" EXIT

      # Decrypt to temp file
      ${envPath} ${ageProgram} -d ${concatMapStrings (x: "-i \"${x}\" ") masterIdentityPaths}"${secret.rekeyFile}" > "$binary_tmp"

      # Encrypt with SOPS
      ${pkgs.sops}/bin/sops -e \
        --config ${escapeShellArg sopsConfig} \
        --filename-override "$out/${outputPath}" \
        "$binary_tmp" > "$out/${outputPath}"

      rm -f "$binary_tmp"
    '';

  # Build the full generation script
  generationScript = ''
    set -euo pipefail

    export PATH="${makeBinPath (with pkgs; [ coreutils sops ] ++ agePlugins)}"
    ${envPath}

    mkdir -p "$out"

    # Generate grouped YAML files
    ${concatStringsSep "\n" (mapAttrsToList generateSopsFileScript grouped)}

    # Generate binary files
    ${concatMapStrings generateBinarySecretScript binarySecrets}

    echo "SOPS secrets generated successfully in $out"
  '';

in
pkgs.runCommand "sops-secrets-${cfg.rekey.recipientIdentifier}"
  {
    nativeBuildInputs = [ agePackage pkgs.sops ] ++ agePlugins;
    # Add master identity files and SOPS config as environment variables
    # This forces Nix to track them as dependencies and copy them to remote builders
    inherit (cfg.sops) configFile;
    inherit masterIdentityPaths;
    # Prefer building locally for hardware key access (YubiKey, etc.)
    preferLocalBuild = true;
    # Don't allow substituting from binary cache since this depends on local secrets
    allowSubstitutes = false;
  }
  generationScript
