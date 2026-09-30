output "api_endpoint" {
  description = "POST {api_endpoint}/v1/copilot with a Cognito token"
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/${aws_apigatewayv2_stage.main.name}"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.staff.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_hosted_ui_domain" {
  value = "https://${aws_cognito_user_pool_domain.staff.domain}.auth.${local.region}.amazoncognito.com"
}

output "docs_bucket" {
  description = "Upload approved documents to s3://<bucket>/approved/"
  value       = aws_s3_bucket.docs.bucket
}

output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.main.id
}

output "data_source_id" {
  value = aws_bedrockagent_data_source.docs.data_source_id
}

output "guardrail_id" {
  value = aws_bedrock_guardrail.main.guardrail_id
}

output "guardrail_version" {
  value = aws_bedrock_guardrail_version.main.version
}

output "case_table_name" {
  value = var.create_case_table ? aws_dynamodb_table.cases[0].name : null
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "web_url" {
  description = "Staff web interface"
  value       = local.web_url
}
