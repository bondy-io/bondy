# Realm Key Encryption

Each realm owns key pairs that Bondy uses to sign and verify tokens and
tickets, and keys it uses to encrypt. Bondy can encrypt the private and the
encryption keys at rest under a master key that you supply. Public keys are
never encrypted.

Encryption is off by default. With `security.master_key.provider = none`,
realm keys are stored in plaintext, and disk encryption is the only at-rest
protection.

## Configuration

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `security.master_key.provider` | `none \| env \| aws_sm` | `none` | Where Bondy reads the master key. `none` disables encryption. |
| `security.master_key.env.var` | string | unset | With `provider = env`, the name of the environment variable that holds the key. |
| `security.master_key.aws_sm.secret_id` | string | unset | With `provider = aws_sm`, the AWS Secrets Manager secret. |
| `security.master_key.aws_sm.region` | string | unset | With `provider = aws_sm`, the secret's AWS region. |
| `security.master_key.aws_sm.field` | string | unset | Optional. With `provider = aws_sm`, the field to read when the secret string is a JSON object. Unset, the whole secret string is the key. |
| `security.master_key.encoding` | `base64 \| raw` | `base64` | How the value is encoded. `base64` decodes it; `raw` uses its bytes as they are. |
| `security.master_key.id` | integer | `1` | The key id written into every encrypted key. See the warning below. |

The master key must be exactly 32 bytes after decoding. To make one for the
`env` provider:

```
BONDY_SECRET_KEY=$(openssl rand -base64 32)
```

```
security.master_key.provider = env
security.master_key.env.var = BONDY_SECRET_KEY
```

The `aws_sm` provider reads AWS credentials from the environment of the Bondy
process, through `erlcloud_aws:auto_config/0`.

## Behaviour

- **Resolved on first use.** Bondy resolves the master key the first time it
  encrypts or decrypts a realm key, and keeps it in memory until the node
  stops. A change to the secret's value takes effect at the next restart.
- **Fails closed.** When a provider is set and the key cannot be resolved, or
  is not 32 bytes, the operation that needed it raises an error. Bondy never
  writes a realm key in plaintext because the master key is unavailable
  (`bondy_keyring_SUITE:fail_closed_missing_env`,
  `bondy_keyring_SUITE:fail_closed_invalid_key_size`).
- **Existing plaintext keys are encrypted.** After you set a provider, a realm
  whose keys are stored in plaintext has them rewritten as ciphertext the
  next time Bondy stores that realm: a create, an update, or a key generation
  (`bondy_realm_keys_encryption_SUITE:migrates_plaintext_on_enable`).
- **Bound to their slot.** Each encrypted key is authenticated with its realm
  URI, key id and field, so it does not decrypt in another slot
  (`bondy_keyring_SUITE:open_wrong_aad_fails`).
- **Setting the provider back to `none` does not decrypt anything.** Keys
  already stored as ciphertext stay ciphertext, and Bondy cannot read them
  without the master key.

## Clusters

Realm keys replicate between nodes as ciphertext. Every node must resolve the
same master key, with the same `id`. A node with a different key cannot
decrypt the realm keys written by its peers.

Back up the master key outside Bondy. Without it, encrypted realm keys cannot
be recovered.

> #### Do not change `security.master_key.id` {: .warning}
> Bondy serves only the key whose id equals the current
> `security.master_key.id`. An encrypted key written under any other id does
> not decrypt (`bondy_keyring_SUITE:lookup_key_only_current_id`). Changing the
> id therefore makes every realm key already encrypted unreadable, even when
> the master key itself is unchanged. Keep the default, and keep the value
> identical on every node.
>
> The id must be between 0 and 65535: the configuration refuses any other
> value, and so does the keyring when the value comes from `sys.config`
> (`bondy_keyring_SUITE:out_of_range_key_id_fails_closed`).
