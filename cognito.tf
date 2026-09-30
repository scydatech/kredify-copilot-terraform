# Staff authentication. Admin-created accounts only, MFA enforced.

resource "aws_cognito_user_pool" "staff" {
  name                     = "${local.prefix}-staff"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "ON"
  deletion_protection      = var.environment == "prod" ? "ACTIVE" : "INACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "staff" {
  domain       = "${local.prefix}-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.staff.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.staff.id

  generate_secret                      = false # browser SPA using Authorization Code + PKCE
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = concat(var.cognito_callback_urls, [local.web_url])
  logout_urls                          = concat(var.cognito_logout_urls, [local.web_url])

  # USER_PASSWORD_AUTH is enabled in dev only, to allow CLI testing.
  explicit_auth_flows = concat(
    ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    var.environment == "dev" ? ["ALLOW_USER_PASSWORD_AUTH"] : []
  )

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
  access_token_validity         = 1
  id_token_validity             = 1
  refresh_token_validity        = 12

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "hours"
  }
}

# Role groups; the orchestrator Lambda reads these from the JWT to authorize data access.
resource "aws_cognito_user_group" "operations" {
  name         = "kredify-operations"
  user_pool_id = aws_cognito_user_pool.staff.id
  description  = "Policy/procedure questions only; no merchant case data"
}

resource "aws_cognito_user_group" "financing_officers" {
  name         = "kredify-financing-officers"
  user_pool_id = aws_cognito_user_pool.staff.id
  description  = "Policy questions plus merchant case summaries and drafts"
}

resource "aws_cognito_user_group" "admins" {
  name         = "kredify-admins"
  user_pool_id = aws_cognito_user_pool.staff.id
  description  = "Full copilot access"
}
