# ===================== Shared =====================
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ===================== Orchestrator (request handling + controlled data access) =====================
data "archive_file" "orchestrator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/orchestrator"
  output_path = "${path.module}/build/${local.prefix}-orchestrator.zip"
}

resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/lambda/${local.prefix}-orchestrator"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_iam_role" "orchestrator" {
  name               = "${local.prefix}-orchestrator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "orchestrator" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.orchestrator.arn}:*"]
  }
  statement {
    sid       = "RetrieveFromKnowledgeBase"
    actions   = ["bedrock:Retrieve"]
    resources = [aws_bedrockagent_knowledge_base.main.arn]
  }
  statement {
    sid       = "InvokeClaude"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = local.generation_model_resource_arns
  }
  statement {
    sid       = "ApplyGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [
      aws_bedrock_guardrail.main.guardrail_arn,
      aws_bedrock_guardrail.input.guardrail_arn,
      aws_bedrock_guardrail.grounding.guardrail_arn,
    ]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
  statement {
    sid       = "ReadApprovedDocsForSourceLinks"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.docs.arn}/${local.kb_docs_prefix}*"]
  }
  dynamic "statement" {
    for_each = var.create_case_table ? [1] : []
    content {
      sid       = "ReadCaseData"
      actions   = ["dynamodb:Query", "dynamodb:GetItem"]
      resources = [aws_dynamodb_table.cases[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "orchestrator" {
  name   = "${local.prefix}-orchestrator-policy"
  role   = aws_iam_role.orchestrator.id
  policy = data.aws_iam_policy_document.orchestrator.json
}

resource "aws_iam_role_policy_attachment" "orchestrator_xray" {
  role       = aws_iam_role.orchestrator.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${local.prefix}-orchestrator"
  description      = "Kredify copilot: auth checks, KB retrieval, case data access, Claude + guardrail"
  role             = aws_iam_role.orchestrator.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.orchestrator.output_path
  source_code_hash = data.archive_file.orchestrator.output_base64sha256
  memory_size      = 1024
  timeout          = 29 # API Gateway HTTP API integration limit is 30s
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.main.id
      MODEL_ID          = var.generation_model_id
      GUARDRAIL_ID      = aws_bedrock_guardrail.main.guardrail_id
      GUARDRAIL_VERSION = aws_bedrock_guardrail_version.main.version
      INPUT_GUARDRAIL_ID      = aws_bedrock_guardrail.input.guardrail_id
      INPUT_GUARDRAIL_VERSION = aws_bedrock_guardrail_version.input.version
      GROUNDING_GUARDRAIL_ID      = aws_bedrock_guardrail.grounding.guardrail_id
      GROUNDING_GUARDRAIL_VERSION = aws_bedrock_guardrail_version.grounding.version
      CASE_TABLE_NAME   = var.create_case_table ? aws_dynamodb_table.cases[0].name : ""
      DOCS_BUCKET = aws_s3_bucket.docs.bucket
      GROUNDING_WARN_BELOW = tostring(var.grounding_threshold)
      CASE_DATA_GROUPS  = join(",", var.case_data_groups)
      NUM_RESULTS       = tostring(var.kb_number_of_results)
      MAX_TOKENS        = tostring(var.max_output_tokens)
      LOG_LEVEL         = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.orchestrator.name
  }

  depends_on = [aws_iam_role_policy.orchestrator, aws_cloudwatch_log_group.orchestrator]
}

# ===================== Ingestion (S3 -> Knowledge Base sync) =====================
data "archive_file" "ingestion" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/ingestion"
  output_path = "${path.module}/build/${local.prefix}-kb-ingestion.zip"
}

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/aws/lambda/${local.prefix}-kb-ingestion"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_iam_role" "ingestion" {
  name               = "${local.prefix}-kb-ingestion-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "ingestion" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingestion.arn}:*"]
  }
  statement {
    sid       = "SyncKnowledgeBase"
    actions   = ["bedrock:StartIngestionJob", "bedrock:GetIngestionJob", "bedrock:ListIngestionJobs"]
    resources = [aws_bedrockagent_knowledge_base.main.arn]
  }
  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "ingestion" {
  name   = "${local.prefix}-kb-ingestion-policy"
  role   = aws_iam_role.ingestion.id
  policy = data.aws_iam_policy_document.ingestion.json
}

resource "aws_lambda_function" "ingestion" {
  function_name                  = "${local.prefix}-kb-ingestion"
  description                    = "Starts Bedrock KB ingestion when approved Kredify documents change"
  role                           = aws_iam_role.ingestion.arn
  runtime                        = "python3.12"
  architectures                  = ["arm64"]
  handler                        = "handler.handler"
  filename                       = data.archive_file.ingestion.output_path
  source_code_hash               = data.archive_file.ingestion.output_base64sha256
  memory_size                    = 256
  timeout                        = 60
  #   reserved_concurrent_executions = 1 # one sync at a time per data source  (removed: account concurrency limit is 10)
  kms_key_arn                    = aws_kms_key.main.arn

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = aws_bedrockagent_knowledge_base.main.id
      DATA_SOURCE_ID    = aws_bedrockagent_data_source.docs.data_source_id
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.ingestion.name
  }

  depends_on = [aws_iam_role_policy.ingestion, aws_cloudwatch_log_group.ingestion]
}

# Trigger 1: document added/changed/removed under approved/
resource "aws_lambda_permission" "ingestion_s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingestion.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.docs.arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "docs" {
  bucket = aws_s3_bucket.docs.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix       = local.kb_docs_prefix
  }

  depends_on = [aws_lambda_permission.ingestion_s3]
}

# Trigger 2: scheduled backstop sync
resource "aws_cloudwatch_event_rule" "kb_sync" {
  name                = "${local.prefix}-kb-sync-schedule"
  description         = "Periodic Kredify Knowledge Base sync"
  schedule_expression = var.kb_sync_schedule
}

resource "aws_cloudwatch_event_target" "kb_sync" {
  rule = aws_cloudwatch_event_rule.kb_sync.name
  arn  = aws_lambda_function.ingestion.arn
}

resource "aws_lambda_permission" "ingestion_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.kb_sync.arn
}
