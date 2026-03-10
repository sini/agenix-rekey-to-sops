# Nixidy Example with SOPS Output

This example demonstrates how to use agenix-rekey's SOPS extension to generate SOPS-encrypted files for nixidy/Kubernetes deployments.

**Note:** This uses the fork's `extraConfigurations` support, which allows agenix-rekey to work with custom configuration systems like nixidy and terranix.

## Setup

1. **Create master identity** (if you don't have one):
```bash
# YubiKey identity
age-plugin-yubikey --generate > master-key.pub

# Or regular age identity
age-keygen -o master-key
```

2. **Create .sops.yaml** configuration:
```yaml
creation_rules:
  - path_regex: \.secrets/env/production/.*\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
  - path_regex: \.secrets/env/staging/.*\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

3. **Generate secrets**:
```bash
# Generate missing age-encrypted secrets
agenix generate
```

4. **Convert to SOPS format**:
```bash
# Generate SOPS files from age secrets (new command!)
agenix sops-rekey -a  # -a adds to git
```

## Generated Output

After rekeying, you'll have SOPS files grouped by domain:

```
.secrets/env/production/
├── oidc.enc.yaml       # hubble-ui, grafana OIDC secrets
├── databases.enc.yaml  # postgres, redis passwords
└── tls.enc.yaml        # TLS cert and key (base64 encoded)
```

## Using in Nixidy Manifests

### String Secrets (passwords, tokens)

```nix
# In your nixidy configuration
{ config, ... }:
{
  kubernetes.resources.secrets.hubble-ui-oidc = {
    type = "Opaque";
    stringData.client-secret = config.age.secrets."hubble-ui-oidc-client-secret".sopsRef;
    # Expands to: "ref+sops://.../.secrets/env/production/oidc.enc.yaml#hubble-ui"
  };
}
```

### Base64 Secrets (TLS certs, binary data)

```nix
{
  kubernetes.resources.secrets.app-tls = {
    type = "kubernetes.io/tls";
    data = {
      "tls.crt" = config.age.secrets."app-tls-cert".sopsRef;
      "tls.key" = config.age.secrets."app-tls-key".sopsRef;
      # These return base64-encoded values
    };
  };
}
```

### Environment Variables

```nix
{
  kubernetes.resources.deployments.my-app = {
    spec.template.spec.containers = [
      {
        name = "app";
        env = [
          {
            name = "POSTGRES_PASSWORD";
            value = config.age.secrets."postgres-password".sopsRef;
          }
          {
            name = "OIDC_CLIENT_SECRET";
            value = config.age.secrets."hubble-ui-oidc-client-secret".sopsRef;
          }
        ];
      }
    ];
  };
}
```

## Deployment

Deploy with vals to evaluate the `ref+sops://` URIs:

```bash
# Nixidy generates Kubernetes manifests
nixidy build

# Deploy with vals evaluation
helm template ./output | vals eval -f - | kubectl apply -f -
```

Vals will decrypt the SOPS files using the keys configured in `.sops.yaml` and replace the URIs with plaintext values.

## Migration from Manual SOPS

**Before** (manually managed SOPS file):
```nix
secrets.hubble-ui-oidc-client-secret = {
  type = "Opaque";
  stringData.client-secret = environment.secrets.forOidcService "hubble-ui";
  # forOidcService returns hardcoded: "ref+sops://.../oidc.enc.yaml#hubble-ui"
};
```

**After** (agenix-rekey generated):
```nix
secrets.hubble-ui-oidc-client-secret = {
  type = "Opaque";
  stringData.client-secret = config.age.secrets."hubble-ui-oidc-client-secret".sopsRef;
  # sopsRef computed automatically from sopsOutput configuration
};
```

## Benefits

- ✅ **Automatic secret generation** with configurable generators
- ✅ **No manual SOPS file management** - files generated automatically
- ✅ **Secret grouping** - logical organization by domain/service
- ✅ **Type safety** - secrets defined in Nix with validation
- ✅ **DRY principle** - sopsRef computed from configuration
- ✅ **Multiple environments** - production/staging with different keys
