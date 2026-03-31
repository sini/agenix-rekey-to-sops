# agenix-rekey-to-sops

SOPS output extension for [agenix-rekey](https://github.com/oddlama/agenix-rekey).

Seamlessly integrate SOPS-encrypted secrets with Kubernetes workflows while maintaining age-encrypted sources. Perfect for [nixidy](https://github.com/arnarg/nixidy) + [vals](https://github.com/helmfile/vals) deployments.

## Features

- 🎯 **Unified Command Interface** - Extends `agenix` with `sops-rekey` subcommand
- ⚡ **Smart Optimization** - Only regenerates when secrets change
- 🔍 **Config Change Detection** - Detects when secrets are added/removed
- 📦 **Secret Grouping** - Organize multiple secrets into single SOPS files
- 🎨 **Multiple Formats** - Support for `str`, `base64`, and `binary` outputs
- 🔗 **Vals Integration** - Auto-generates `ref+sops://` URIs
- 🧩 **Generic Design** - Works with nixidy, terranix, or any custom Nix config
- 🚀 **flake-parts Module** - Simple integration with `imports`

## Quick Start

### 1. Add to your flake (with flake-parts)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    agenix-rekey.url = "github:sini/agenix-rekey";  # Fork with extraConfigurations
    agenix-rekey-to-sops.url = "github:sini/agenix-rekey-to-sops";
    agenix-rekey-to-sops.inputs.agenix-rekey.follows = "agenix-rekey";

    nixidy.url = "github:arnarg/nixidy";
  };

  outputs = inputs @ { self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.agenix-rekey.flakeModule
        inputs.agenix-rekey-to-sops.flakeModule
      ];

      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { config, pkgs, system, ... }: {
        # Configure agenix-rekey
        agenix-rekey = {
          nixosConfigurations = self.nixosConfigurations;
          # Add your custom configurations
          extraConfigurations = self.nixidyEnvs.${system} or { };
        };

        # Add unified agenix command to devshell
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ config.agenix-rekey-sops.package ];
        };
      };

      flake = {
        # Define nixidy environments with SOPS support
        nixidyEnvs.x86_64-linux.production = inputs.nixidy.lib.mkEnv {
          pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
          modules = [
            inputs.agenix-rekey-to-sops.sopsModules.default
            ./production.nix
          ];
        };
      };
    };
}
```

### 2. Configure your environment (`production.nix`)

```nix
{
  age = {
    # SOPS configuration
    sops = {
      outputDir = ./.secrets/prod;
    };

    # Master identity for decryption
    rekey.masterIdentities = [ ./master-key.pub ];

    # Define secrets
    secrets = {
      database-password = {
        rekeyFile = ./secrets/db-pass.age;
        generator.script = "alnum";  # Auto-generate if missing

        sopsOutput = {
          file = "database";      # Creates database.enc.yaml
          key = "password";       # YAML key
          format = "str";         # Plain text
        };
      };

      api-key = {
        rekeyFile = ./secrets/api-key.age;
        sopsOutput = {
          file = "database";      # Groups into same file
          key = "api-key";
        };
      };

      tls-cert = {
        rekeyFile = ./secrets/tls.pem.age;
        sopsOutput = {
          file = "tls";
          key = "cert";
          format = "base64";      # For Kubernetes Secret.data
        };
      };
    };
  };

  # Use in nixidy manifests
  applications.myapp = {
    resources.secrets.database = {
      stringData = {
        # sopsRef returns: "ref+sops://.secrets/prod/database.enc.yaml#password"
        password = config.age.secrets.database-password.sopsRef;
        api-key = config.age.secrets.api-key.sopsRef;
      };
    };
  };
}
```

### 3. `.sops.yaml` configuration (auto-generated)

The tool auto-generates `.sops.yaml` in your `outputDir` with recipients extracted from `masterIdentities`. For example, if `outputDir = ./.secrets/prod`, it creates `.secrets/prod/.sops.yaml`:

**Note:** The generated config encrypts to your master identities. To encrypt to different recipients (e.g., CI-only keys), use `age.sops.recipients` option.

### 4. Use the unified `agenix` command

```bash
# Enter devshell
nix develop

# Generate missing age secrets
agenix generate

# Convert to SOPS format
agenix sops-rekey

# Add SOPS files to git
agenix sops-rekey -a

# All agenix commands work:
agenix rekey       # Rekey age secrets
agenix edit <name> # Edit a secret
agenix view <name> # View a secret
```

## Command Reference

The unified `agenix` command includes all standard agenix-rekey commands plus SOPS support:

### `agenix generate`

Generates missing age-encrypted secrets using configured generators.

```bash
agenix generate
```

### `agenix sops-rekey`

Converts age-encrypted secrets to SOPS format. **Smart optimization** skips unchanged files.

```bash
agenix sops-rekey           # Generate SOPS files
agenix sops-rekey -a        # Also add to git
agenix sops-rekey --help    # Show all options
```

**Optimization features:**

- ✅ Skips files when content unchanged
- ✅ Detects when secrets added/removed from groups
- ✅ Batched decryption/encryption to minimize YubiKey unlocks
- ✅ Clear error messages for missing input files

### `agenix rekey`

Re-encrypts age secrets for hosts that require them.

```bash
agenix rekey
```

### `agenix edit <secret>`

Edit age-encrypted secret with `$EDITOR`.

```bash
agenix edit database-password
```

### `agenix view <secret>`

View decrypted age secret.

```bash
agenix view database-password
```

## Module Schema

### `age.sops` Options

Configure SOPS output for a configuration/environment:

```nix
age.sops = {
  outputDir = ./.secrets;      # Where to generate SOPS files (required)
  defaultFile = "sops-secrets"; # Default SOPS file name (optional, default: "sops-secrets")

  # By default, SOPS files are encrypted to the same age keys in `masterIdentities`
  # (used to decrypt source age files). To encrypt to different recipients (e.g., CI-only keys):
  recipients = [
    "age1ci_server_key..."
    "ssh-ed25519 AAAAofsomehost..."
  ];
};
```

### `age.secrets.<name>.sopsOutput` Options

Configure SOPS output for individual secrets:

```nix
age.secrets.my-secret = {
  rekeyFile = ./secrets/my-secret.age;  # Source age-encrypted file

  sopsOutput = {
    file = "app-secrets";  # SOPS filename (without .enc.yaml extension)
    key = "my-key";        # YAML key within the file
    format = "str";        # "str" (default) | "base64" | "binary"
  };
};
```

### Computed `sopsRef` Attribute

Every secret with `sopsOutput` gets a computed `sopsRef` attribute:

```nix
config.age.secrets.my-secret.sopsRef
# Returns: "ref+sops://.secrets/app-secrets.enc.yaml#my-key"
```

Use this in Kubernetes manifests for vals evaluation.

## Secret Formats

### `str` - Plain Text (default)

For passwords, tokens, API keys, connection strings:

```nix
database-password.sopsOutput = {
  file = "credentials";
  key = "database-password";
  format = "str";  # Can be omitted (default)
};
```

Generated YAML:

```yaml
database-password: my-secret-password
```

### `base64` - Base64 Encoded

For Kubernetes `Secret.data` fields (pre-encoded):

```nix
tls-cert.sopsOutput = {
  file = "tls";
  key = "cert.pem";
  format = "base64";
};
```

Generated YAML:

```yaml
cert.pem: LS0tLS1CRUdJTi...
```

**Why?** Kubernetes distinguishes between:

- `stringData` - plain text (use `format = "str"`)
- `data` - base64-encoded (use `format = "base64"`)

### `binary` - Entire File

For large files, binaries, or when you don't want YAML:

```nix
ca-bundle.sopsOutput = {
  file = "ca-bundle";
  format = "binary";
};
```

Generates `ca-bundle.enc` (not `.enc.yaml`) - entire file encrypted, no YAML wrapper.

## Secret Grouping

Multiple secrets with the same `file` value are grouped into one SOPS file:

```nix
age.secrets = {
  postgres-password.sopsOutput = { file = "database"; key = "postgres"; };
  mysql-password.sopsOutput = { file = "database"; key = "mysql"; };
  redis-password.sopsOutput = { file = "database"; key = "redis"; };
};
```

Generates single file `database.enc.yaml`:

```yaml
postgres: secret1
mysql: secret2
redis: secret3
```

## Smart Optimization

The `sops-rekey` command intelligently skips regeneration when possible:

### 1. Key Set Detection

Detects configuration changes (added/removed secrets):

```bash
$ agenix sops-rekey
   Generating SOPS files for prod
  Generating SOPS file prod:oidc.enc.yaml
      Key set changed (expected: ["argocd","grafana"], got: ["grafana"]), regenerating
      Created ./.secrets/prod/oidc.enc.yaml
```

### 2. Content Comparison

Compares plaintext content before regenerating:

```bash
$ agenix sops-rekey
   Generating SOPS files for prod
  Generating SOPS file prod:database.enc.yaml
      Content changed, regenerating
      Created ./.secrets/prod/database.enc.yaml
```

When content is unchanged:

```bash
$ agenix sops-rekey
   Generating SOPS files for prod
  Generating SOPS file prod:oidc.enc.yaml
      Unchanged, skipping
```

### 3. Batched Decryption/Encryption (YubiKey Optimization)

Minimizes YubiKey unlocks by batching operations:

```bash
$ agenix sops-rekey
   Decrypting age inputs (YubiKey unlock for age plugin)...
      Decrypted: ./secrets/demo-app-api-key.age
      Decrypted: ./secrets/demo-app-db-password.age
      Decrypted: ./secrets/grafana-oidc.age
      Decrypted: ./secrets/hubble-ui-oidc.age
   Decrypted 4 age files

   Generating SOPS files for production
  Generating SOPS file production:demo-app.enc.yaml
      Created ./.secrets/prod/demo-app.enc.yaml
  Generating SOPS file production:oidc.enc.yaml
      Unchanged, skipping
```

**Why this matters:**

- YubiKeys require PIN entry for different operations (age plugin vs smartcard)
- **Before**: 2\*N unlocks (decrypt + encrypt for each secret)
- **After**: 2-3 unlocks total (one age batch, 1-2 SOPS batches)

The tool decrypts all age files upfront to a temp directory, then processes SOPS operations referencing the pre-decrypted files.

### 4. Better Error Messages

Clear errors for missing files:

```bash
$ agenix sops-rekey
   Generating SOPS files for dev
  Generating SOPS file dev:oidc.enc.yaml
      Input file missing: ./secrets/argocd-oidc.age, regenerating
      Error: Cannot generate SOPS file - missing input files:
        ./secrets/argocd-oidc.age
      Run 'agenix generate' to create missing secrets
```

## Using in Nixidy Manifests

### Simple String Secret

```nix
{ config, ... }: {
  applications.myapp.resources.secrets.database = {
    type = "Opaque";
    stringData.password = config.age.secrets.database-password.sopsRef;
  };
}
```

### TLS Certificate (base64)

```nix
{ config, ... }: {
  applications.myapp.resources.secrets.app-tls = {
    type = "kubernetes.io/tls";
    data = {
      "tls.crt" = config.age.secrets.tls-cert.sopsRef;
      "tls.key" = config.age.secrets.tls-key.sopsRef;
    };
  };
}
```

### Environment Variables

```nix
{ config, ... }: {
  applications.myapp.resources.deployments.app = {
    spec.template.spec.containers = [{
      name = "app";
      env = [
        {
          name = "DB_PASSWORD";
          value = config.age.secrets.database-password.sopsRef;
        }
        {
          name = "API_KEY";
          value = config.age.secrets.api-key.sopsRef;
        }
      ];
    }];
  };
}
```

### Config File from Secret

```nix
{ config, ... }: {
  applications.myapp.resources.configMaps.app-config = {
    data."config.yaml" = ''
      database:
        password: ${config.age.secrets.database-password.sopsRef}
      api:
        key: ${config.age.secrets.api-key.sopsRef}
    '';
  };
}
```

## Deployment Workflow

### Development Workflow

```bash
# 1. Enter devshell with agenix command
nix develop

# 2. Generate age secrets (if missing)
agenix generate

# 3. Convert to SOPS format
agenix sops-rekey -a

# 4. Build Kubernetes manifests
nixidy build

# 5. Deploy with vals evaluation
helm template ./output | vals eval -f - | kubectl apply -f -
```

### CI/CD Workflow

```yaml
- name: Generate SOPS secrets
  run: |
    nix run .#agenix-rekey.x86_64-linux.generate
    nix run .#agenix-rekey.x86_64-linux.sops-rekey

- name: Build manifests
  run: nix run .#nixidy.x86_64-linux.production.build

- name: Deploy with vals
  run: |
    helm template ./output \
      | vals eval -f - \
      | kubectl apply -f -
```

### How Vals Works

When you deploy with vals:

1. **Parse URIs**: Vals finds all `ref+sops://` references
2. **Decrypt**: Uses SOPS to decrypt files with keys from `.sops.yaml`
3. **Extract**: Retrieves specific YAML keys (e.g., `#password`)
4. **Replace**: Substitutes URIs with plaintext values
5. **Apply**: Sends final manifests to Kubernetes

Example transformation:

**Before vals:**

```yaml
apiVersion: v1
kind: Secret
data:
  password: ref+sops://.secrets/prod/db.enc.yaml#password
```

**After vals:**

```yaml
apiVersion: v1
kind: Secret
data:
  password: my-actual-password
```

## Architecture

### Two-Layer Design

**Layer 1: agenix-rekey Fork** (Minimal, ~30 lines)

- Adds `extraConfigurations` parameter
- Generic support for custom config systems
- Potentially upstreamable

**Layer 2: This Flake** (Extension, ~600 lines)

- SOPS module with schema ([modules/sops.nix](modules/sops.nix))
- `sops-rekey` command ([apps/sops-rekey.nix](apps/sops-rekey.nix))
- flake-parts integration ([flake-module.nix](flake-module.nix))
- Vals URI generation
- Optimization logic

### Benefits

- ✅ Minimal fork maintenance burden
- ✅ Clear extension boundaries
- ✅ Easy to propose core changes upstream
- ✅ Works with any custom config system (nixidy, terranix, etc.)

### Key Implementation Files

- [flake-module.nix](flake-module.nix) - flake-parts integration
- [modules/sops.nix](modules/sops.nix) - SOPS module schema
- [apps/sops-rekey.nix](apps/sops-rekey.nix) - SOPS generation with optimization
- [nix/package.nix](nix/package.nix) - Unified `agenix` wrapper script

## Alternative: Without flake-parts

If you're not using flake-parts, use the `configure` function:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix-rekey.url = "github:sini/agenix-rekey";
    agenix-rekey-to-sops.url = "github:sini/agenix-rekey-to-sops";
    nixidy.url = "github:arnarg/nixidy";
  };

  outputs = { self, nixpkgs, agenix-rekey-to-sops, nixidy, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    # Define nixidy environment
    nixidyEnvs.${system}.production = nixidy.lib.mkEnv {
      inherit pkgs;
      modules = [
        agenix-rekey-to-sops.sopsModules.default
        ./production.nix
      ];
    };

    # Get apps with sops-rekey
    agenix-rekey = agenix-rekey-to-sops.configure {
      userFlake = self;
      extraConfigurations = self.nixidyEnvs.${system};
    };

    # Use in devShell
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        self.agenix-rekey.${system}.rekey
        self.agenix-rekey.${system}.generate
        self.agenix-rekey.${system}.sops-rekey
      ];
    };
  };
}
```

## Requirements

### Required

- **agenix-rekey fork:** https://github.com/sini/agenix-rekey
  - Adds `extraConfigurations` support

- **SOPS:** For encryption/decryption
  ```bash
  nix-shell -p sops
  ```

### For Deployment

- **Vals:** For evaluating `ref+sops://` URIs

  ```bash
  nix-shell -p vals
  ```

- **kubectl:** For applying to Kubernetes
  ```bash
  nix-shell -p kubectl
  ```

## Examples

### Complete Working Example

See [examples/nixidy](./examples/nixidy/) for a complete working example with:

- ✅ Nixidy environment configuration
- ✅ SOPS secret grouping
- ✅ Multiple secret formats
- ✅ YubiKey master identity
- ✅ Real `.sops.yaml` configuration
- ✅ Kubernetes manifests using `sopsRef`

### Run the Example

```bash
cd examples/nixidy

# Generate and convert secrets
nix run .#agenix-rekey.x86_64-linux.generate
nix run .#agenix-rekey.x86_64-linux.sops-rekey

# View generated SOPS files
cat .secrets/prod/oidc.enc.yaml
cat .secrets/prod/demo-app.enc.yaml

# Build nixidy manifests
nix flake check
```

## Troubleshooting

### "No matching creation rule" error

**Cause:** `.sops.yaml` path pattern doesn't match output file path.

**Fix:** Verify `path_regex` in `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: \.secrets/prod/.*\.enc\.ya?ml$ # Must match outputDir
    age:
      - age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

### "age: no identity matched" error

**Cause:** Master identity not in secret's `publicKeys`.

**Fix:** Check secret configuration includes master identity:

```bash
nix eval .#nixidyEnvs.x86_64-linux.production.config.age.secrets.my-secret.publicKeys
```

### SOPS files always show "Unchanged, skipping" but don't have new secrets

**Cause:** Old pre-built script in cache.

**Fix:** Rebuild after configuration changes:

```bash
# With flake-parts
nix develop --refresh

# Without flake-parts
nix flake update
nix run .#agenix-rekey.x86_64-linux.sops-rekey
```

### Binary secrets generate YAML files

**Cause:** Format not set to `"binary"`.

**Fix:**

```nix
sopsOutput = {
  file = "my-file";
  format = "binary";  # Not "str"
};
```

Binary files have `.enc` extension (not `.enc.yaml`).

## Credits

Built on top of [agenix-rekey](https://github.com/oddlama/agenix-rekey) by oddlama.

Designed for use with:

- [nixidy](https://github.com/arnarg/nixidy) - Kubernetes with Nix
- [vals](https://github.com/helmfile/vals) - Secret templating
- [SOPS](https://github.com/getsops/sops) - Secrets OPerationS

## License

MIT
