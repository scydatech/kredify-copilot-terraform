resource "aws_bedrock_guardrail" "main" {
  name        = "${local.prefix}-guardrail"
  description = "Kredify copilot safety, PII and grounding controls"

  blocked_input_messaging   = "This request can't be processed by the Kredify copilot. Please rephrase, or contact the financing operations lead."
  blocked_outputs_messaging = "The copilot couldn't produce a compliant, well-grounded answer. Please consult the source policy or your team lead."

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE" # prompt-attack filter applies to input only
    }
  }

  # Staff may legitimately discuss merchants, so names/emails are allowed; secrets and card data are not.
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "PASSWORD"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_SECRET_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_CVV"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PIN"
      action = "BLOCK"
    }
    regexes_config {
      name        = "kredify-bvn-nin"
      description = "Nigerian BVN / NIN when labelled as such"
      pattern     = "(?i)\\b(bvn|nin)\\b[\\s:#-]*\\d{11}"
      action      = "ANONYMIZE"
    }
  }

  # Denied topics are checked on the staff question only, by the input guardrail below.

  word_policy_config {
    managed_word_lists_config {
      type = "PROFANITY"
    }
  }

  # Contextual grounding runs separately (flag-only) - see the grounding guardrail below.
}

# Immutable, numbered version used by the application. Any change to the guardrail
# publishes a new version (old versions are kept for audit) and the Lambda picks it up.
resource "aws_bedrock_guardrail_version" "main" {
  guardrail_arn = aws_bedrock_guardrail.main.guardrail_arn
  description   = "Kredify copilot guardrail release"
  skip_destroy  = true

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.main]
  }
}

# ===================== Input guardrail (staff question only) =====================
# Checked with ApplyGuardrail on the question BEFORE Claude is called. Keeping the
# denied topic here (not in the main guardrail) stops it firing on correct answers
# that merely mention approval rules, e.g. "above NGN 5m needs Credit Manager approval".
resource "aws_bedrock_guardrail" "input" {
  name        = "${local.prefix}-input-guardrail"
  description = "Kredify copilot: blocks staff requests for the AI to make financing decisions"

  blocked_input_messaging   = "The copilot can't approve, decline, disburse, restructure or write off financing. Those decisions are made by authorized staff under the Financing Policy."
  blocked_outputs_messaging = "The copilot can't approve, decline, disburse, restructure or write off financing. Those decisions are made by authorized staff under the Financing Policy."

  topic_policy_config {
    topics_config {
      name       = "final-financing-decisions"
      type       = "DENY"
      definition = "Requests for the assistant itself to approve, reject, disburse, restructure, or write off a specific financing application or loan, or to execute a payment or account change on a merchant's behalf."
      examples = [
        "Approve this merchant's loan now.",
        "Go ahead and disburse the facility to merchant M-1042.",
        "Write off the remaining balance for this merchant.",
      ]
    }
  }
}

resource "aws_bedrock_guardrail_version" "input" {
  guardrail_arn = aws_bedrock_guardrail.input.guardrail_arn
  description   = "Kredify copilot input guardrail release"
  skip_destroy  = true

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.input]
  }
}

# ===================== Grounding guardrail (flag-only) =====================
# Applied with ApplyGuardrail AFTER Claude answers. The application does not block on it:
# it attaches the grounding/relevance scores to the response and warns staff when they
# are low. Bedrock's grounding check scores long multi-source answers inconsistently,
# so blocking on it rejected correct answers.
resource "aws_bedrock_guardrail" "grounding" {
  name        = "${local.prefix}-grounding-guardrail"
  description = "Kredify copilot: scores how well answers are supported by retrieved sources (flag-only)"

  blocked_input_messaging   = "Grounding check."
  blocked_outputs_messaging = "Grounding check."

  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = var.grounding_threshold
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = 0.5
    }
  }
}

resource "aws_bedrock_guardrail_version" "grounding" {
  guardrail_arn = aws_bedrock_guardrail.grounding.guardrail_arn
  description   = "Kredify copilot grounding guardrail release"
  skip_destroy  = true

  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.grounding]
  }
}
