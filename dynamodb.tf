# Authorized financing case data (merchant_id + case_id). If Kredify's financing data lives in an
# existing system, set create_case_table = false and replace fetch_case_data() in the orchestrator.

resource "aws_dynamodb_table" "cases" {
  count = var.create_case_table ? 1 : 0

  name                        = "${local.prefix}-merchant-cases"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "merchant_id"
  range_key                   = "case_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "merchant_id"
    type = "S"
  }
  attribute {
    name = "case_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }
}
