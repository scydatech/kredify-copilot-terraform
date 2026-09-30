# Kredify Financing Operations Copilot

An internal AI assistant that helps Kredify financing staff find answers faster.

Staff sign in to a secure web page and ask questions in plain English, such as *"What documents are required for a working capital facility above NGN 5m?"* The copilot searches Kredify's approved policies and procedures, adds the merchant's case details where the user is allowed to see them, and returns a clear answer with links to the source documents.

It can:

- **Explain a policy:** rules, limits, conditions and exceptions
- **Find information:** a specific figure, step or requirement
- **Summarize a merchant case:** status, key figures, missing items and the policy that applies
- **Draft a reply:** a message to a merchant for staff to review and send

> **The copilot informs; staff decide.** It cannot approve, decline, disburse, restructure or write off financing, and it cannot take action in any system. Every answer is reviewed by a member of staff.

---

## How it works

```
Staff ─► Web app (CloudFront + S3)
     ─► Sign in (Cognito, with MFA)
     ─► API Gateway ─► Lambda orchestrator
                          ├─ DynamoDB: merchant case data (authorized roles only)
                          ├─ Bedrock Guardrail: block requests for financing decisions
                          ├─ Bedrock Knowledge Base: find relevant policy passages
                          ├─ Claude Sonnet 4.5 on Bedrock: write the answer (with safety guardrail)
                          └─ Bedrock Guardrail: score how well the answer matches the sources
     ◄─ Answer + sources + grounding score

Approved documents ─► S3 ─► Lambda ─► Knowledge Base ─► Titan Embeddings ─► S3 Vectors
```

When a policy document is added to or removed from the approved folder, the knowledge base updates automatically, so answers always reflect the latest approved content.

---

## AWS services and why they are used

| Service | Why it is used |
|---|---|
| **Amazon Bedrock – Claude Sonnet 4.5** | Understands staff questions and writes clear, well-structured answers and drafts. A managed model means no AI infrastructure to run, and data is not used to train models. |
| **Amazon Bedrock Knowledge Bases** | Searches Kredify's approved documents and supplies the most relevant passages, so answers are based on Kredify's own policies rather than general knowledge. |
| **Amazon Titan Text Embeddings V2** | Converts documents into a searchable form so the knowledge base can find passages by meaning, not just keywords. |
| **Amazon S3 Vectors** | Stores the searchable document data at low cost, without running a database cluster. |
| **Amazon Bedrock Guardrails** | Blocks requests for the AI to make financing decisions, filters harmful content and prompt attacks, masks sensitive data such as card numbers, and scores whether each answer is supported by the sources. |
| **Amazon S3** | Holds the approved source documents (only files in the approved folder are used) and the web app files. |
| **AWS Lambda** | Runs the copilot logic (access checks, search, AI call, safety checks) and the automatic document sync. Pay only when it runs; no servers to manage. |
| **Amazon DynamoDB** | Stores merchant case records that financing officers can include in summaries and drafts. |
| **Amazon API Gateway** | Provides the secure endpoint the web app calls, and rejects any request without a valid sign-in token. |
| **Amazon Cognito** | Handles staff sign-in with mandatory MFA. Accounts are created by administrators only, and roles (operations, financing officer, admin) control what each person can see. |
| **Amazon CloudFront** | Serves the web app over HTTPS with strict browser security settings, quickly for staff in Nigeria. |
| **Amazon EventBridge** | Runs an hourly document sync as a backstop, so no document change is missed. |
| **AWS KMS** | Encrypts documents, case data, search data and logs with a Kredify-managed key. |
| **AWS IAM** | Gives each component only the permissions it needs. |
| **Amazon CloudWatch** | Collects logs and raises alarms on errors, throttling and unusual guardrail activity. |
| **AWS CloudTrail** | Keeps an audit record of who accessed or changed resources, documents and the knowledge base. |
| **Amazon SNS** | Emails alarm notifications to the operations team. |
| **AWS X-Ray** | Traces requests to help diagnose slow or failed answers. |

All resources run in **eu-central-1 (Frankfurt)**, and AI processing stays within the EU.

---

## Built-in safeguards

- **Role-based access:** operations staff can ask policy questions; only financing officers and admins can use merchant case data.
- **No AI decisions:** requests to approve, disburse or write off financing are stopped before they reach the AI.
- **Answers with evidence:** every answer cites its sources and shows a grounding score. Answers that are not well supported by the documents carry a visible warning.
- **Drafts for review only:** merchant messages are clearly labelled as drafts for staff to check before sending.
- **Encrypted and audited:** data is encrypted at rest and in transit, and every request is logged.

---

## Project structure

```
kredify-copilot-terraform/
├── *.tf              # Terraform infrastructure (one file per area: cognito, lambda, guardrail, frontend, …)
├── frontend/         # Staff web app (HTML, CSS, JavaScript)
└── lambda_src/
    ├── orchestrator/ # Copilot request handling
    └── ingestion/    # Automatic knowledge base sync
```

---

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # set your region, environment and alarm email
terraform init
terraform apply
terraform output web_url                       # the staff web app address
```

Before first use, submit the Anthropic use-case form for Claude Sonnet 4.5 in the Amazon Bedrock console, upload approved documents to the `approved/` folder of the documents bucket, and create staff accounts in Cognito.