variable "aws_region" {
  description = "Region for the workload. Must support Bedrock (Claude Sonnet 4.5 + Titan Embeddings v2) and S3 Vectors."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Deployment environment; becomes part of every resource name (kredify-<env>-...)."
  type        = string
  default     = "dev"
  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.environment))
    error_message = "environment must be 2-8 lowercase letters/digits (e.g. dev, uat, prod)."
  }
}

variable "generation_model_id" {
  description = "Claude Sonnet 4.5 model or inference-profile ID used by the copilot."
  type        = string
  default     = "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "embedding_model_id" {
  description = "Embedding model for the Knowledge Base."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "embedding_dimensions" {
  description = "Embedding vector size (Titan v2 supports 256, 512, 1024)."
  type        = number
  default     = 1024
}

variable "kb_number_of_results" {
  description = "Chunks retrieved from the Knowledge Base per question."
  type        = number
  default     = 6
}

variable "max_output_tokens" {
  description = "Max tokens generated per copilot answer (keep answers within the 30s API Gateway limit)."
  type        = number
  default     = 1500
}

variable "grounding_threshold" {
  description = "Guardrail contextual-grounding threshold (0-0.99). Higher = stricter about unsupported claims."
  type        = number
  default     = 0.7
}

variable "cognito_callback_urls" {
  description = "OAuth callback URLs for the staff web interface."
  type        = list(string)
  default     = ["http://localhost:3000/callback"]
}

variable "cognito_logout_urls" {
  description = "OAuth sign-out URLs for the staff web interface."
  type        = list(string)
  default     = ["http://localhost:3000/"]
}

variable "allowed_cors_origins" {
  description = "Origins allowed to call the API from a browser (the staff web interface)."
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "case_data_groups" {
  description = "Cognito groups allowed to read merchant financing case data through the copilot."
  type        = list(string)
  default     = ["kredify-financing-officers", "kredify-admins"]
}

variable "document_publisher_principal_arns" {
  description = "IAM principal ARNs (roles/users) allowed to write or delete under approved/ in the docs bucket. Empty = no restriction (not recommended beyond dev). Include your Terraform/CI role if it uploads docs."
  type        = list(string)
  default     = []
}

variable "kb_sync_schedule" {
  description = "Backstop schedule for Knowledge Base sync (catches changes missed while a sync was already running)."
  type        = string
  default     = "rate(1 hour)"
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 90
}

variable "create_case_table" {
  description = "Create the kredify-<env>-merchant-cases DynamoDB table as the authorized financing data source. Set false if you will point the Lambda at an existing system."
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Create a Kredify CloudTrail trail. Set false if an organization trail already covers this account."
  type        = bool
  default     = true
}

variable "enable_model_invocation_logging" {
  description = "Enable Bedrock model-invocation logging. NOTE: this is a single per-account, per-region setting shared with other workloads (e.g. Moniva)."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Email for CloudWatch alarm notifications (leave empty to skip the subscription)."
  type        = string
  default     = ""
}
