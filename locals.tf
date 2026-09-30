locals {
  # Every resource name starts with this, e.g. "kredify-dev-api"
  prefix     = "kredify-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  common_tags = {
    Project     = "kredify"
    Workload    = "financing-operations-copilot"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # "eu.anthropic.claude-sonnet-4-5-..." -> "anthropic.claude-sonnet-4-5-..."
  generation_base_model_id = replace(var.generation_model_id, "/^(global|us|eu|apac|jp|au)\\./", "")
  is_inference_profile     = local.generation_base_model_id != var.generation_model_id

  generation_model_resource_arns = concat(
    ["arn:${local.partition}:bedrock:*::foundation-model/${local.generation_base_model_id}"],
    local.is_inference_profile ? [
      "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/${var.generation_model_id}"
    ] : []
  )

  embedding_model_arn = "arn:${local.partition}:bedrock:${local.region}::foundation-model/${var.embedding_model_id}"
  kb_docs_prefix      = "approved/"
}
