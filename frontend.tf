# ===================== Staff web interface =====================
# Static single-page app in a private S3 bucket, served over HTTPS by CloudFront.
# Sign-in uses the Cognito hosted UI (Authorization Code + PKCE); the page calls the API with the user's token.

locals {
  web_origin = "https://${aws_cloudfront_distribution.web.domain_name}"
  web_url    = "${local.web_origin}/"
  web_dir    = "${path.module}/frontend"

  cognito_origin = "https://${aws_cognito_user_pool_domain.staff.domain}.auth.${local.region}.amazoncognito.com"

  web_content_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
  }

  # The API origin uses a regional wildcard to avoid a dependency cycle (the API's CORS list references this distribution).
  web_csp = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' https://fonts.googleapis.com",
    "font-src https://fonts.gstatic.com",
    "img-src 'self' data:",
    "connect-src 'self' https://*.execute-api.${local.region}.amazonaws.com ${local.cognito_origin}",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "object-src 'none'",
  ])
}

resource "aws_s3_bucket" "web" {
  bucket        = "${local.prefix}-web-${local.account_id}"
  force_destroy = true # contents are build output, redeployed by Terraform
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${local.prefix}-web-oac"
  description                       = "CloudFront access to the Kredify staff web bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_response_headers_policy" "web" {
  name    = "${local.prefix}-web-security-headers"
  comment = "Security headers for the Kredify staff web interface"

  security_headers_config {
    content_security_policy {
      content_security_policy = local.web_csp
      override                = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
  }
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  comment             = "Kredify copilot staff web (${var.environment})"
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes edge locations in Africa
  http_version        = "http2and3"

  origin {
    origin_id                = "web-s3"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id           = "web-s3"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id # small app; always serve the latest release
    response_headers_policy_id = aws_cloudfront_response_headers_policy.web.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.web.arn, "${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket     = aws_s3_bucket.web.id
  policy     = data.aws_iam_policy_document.web_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.web]
}

# Static files from ./frontend (everything except a locally created config.js)
resource "aws_s3_object" "web_files" {
  for_each = setsubtract(fileset(local.web_dir, "**"), ["config.js"])

  bucket       = aws_s3_bucket.web.id
  key          = each.value
  source       = "${local.web_dir}/${each.value}"
  source_hash  = filemd5("${local.web_dir}/${each.value}")
  content_type = lookup(local.web_content_types, lower(regex("[^.]+$", each.value)), "application/octet-stream")
}

# Runtime settings, generated from this stack's outputs
resource "aws_s3_object" "web_config" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.js"
  content_type = local.web_content_types.js
  content = "window.KREDIFY_CONFIG = ${jsonencode({
    apiUrl         = "${aws_apigatewayv2_api.main.api_endpoint}/${aws_apigatewayv2_stage.main.name}"
    cognitoDomain  = local.cognito_origin
    clientId       = aws_cognito_user_pool_client.web.id
    redirectUri    = local.web_url
    environment    = var.environment
    caseDataGroups = var.case_data_groups
    groundingThreshold = var.grounding_threshold
  })};\n"
}
