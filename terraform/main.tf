provider "vault" {
  address = "http://127.0.0.1:8200"
  token   = "abc123"
}

resource "vault_mount" "kv-v2" {
  path = "internalservices/kv"
  type = "kv-v2"
}

resource "vault_auth_backend" "approle" {
  type = "approle"

  tune {
    max_lease_ttl     = "60s"
    default_lease_ttl = "30s"
  }
}

resource "vault_approle_auth_backend_role" "agent" {
  backend        = vault_auth_backend.approle.path
  role_name      = "agent"
  token_policies = [vault_policy.agent.name]
  token_ttl      = 30
  token_max_ttl  = 60
}

resource "vault_policy" "agent" {
  name   = "agent"
  policy = data.vault_policy_document.agent.hcl
}

data "vault_policy_document" "agent" {
  rule {
    path         = "auth/token/create"
    capabilities = ["create", "update"]
  }

  rule {
    path         = "sys/tools/random/*"
    capabilities = ["create", "update"]
  }

  # NOTE: When using kv-v2, the data/ prefix is required in the policy, but not
  # for `vault put`/`vault get`
  # https://support.hashicorp.com/hc/en-us/articles/4407386653843-Vault-KV-V2-Secrets-Engine-Permission-Denied-
  rule {
    path         = "internalservices/kv/data/monitoring/prometheus-basic-auth"
    capabilities = ["read"]
  }
}

resource "vault_generic_secret" "htpasswd" {
  path = "${vault_mount.kv-v2.path}/monitoring/prometheus-basic-auth"

  data_json = <<EOT
{
  "username": "test",
  "password": "test",
  "htpasswd": "$apr1$3lcQaaG5$Hfd.F6Ac03Obz247iB8rv0"
}
EOT
}

resource "local_file" "role_id" {
  filename = "../role_id"
  content  = vault_approle_auth_backend_role.agent.role_id
}

resource "vault_approle_auth_backend_role_secret_id" "agent" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.agent.role_name
}

resource "local_file" "secret_id" {
  filename = "../secret_id"
  content  = vault_approle_auth_backend_role_secret_id.agent.secret_id
}
