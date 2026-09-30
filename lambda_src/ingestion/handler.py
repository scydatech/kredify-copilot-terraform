"""
Kredify Knowledge Base ingestion.
Triggered by S3 changes under approved/ and by a schedule. Starts a Bedrock KB ingestion job.
If a job is already running:
  - S3-triggered runs raise an error so Lambda's async retry tries again a few minutes later;
  - scheduled runs simply skip (the next scheduled run will catch up).
Folder markers (keys ending in "/") are ignored.
"""
import json
import logging
import os
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

client = boto3.client("bedrock-agent")
KB_ID = os.environ["KNOWLEDGE_BASE_ID"]
DS_ID = os.environ["DATA_SOURCE_ID"]


class IngestionInProgress(Exception):
    """Raised for S3-triggered runs so Lambda's async retry re-attempts the sync."""


def handler(event, context):
    records = event.get("Records", [])
    trigger = "s3" if records else "schedule"
    keys = [unquote_plus(r["s3"]["object"]["key"]) for r in records if "s3" in r]
    keys = [k for k in keys if not k.endswith("/")]  # ignore folder markers such as "approved/"
    logger.info(json.dumps({"trigger": trigger, "changed_keys": keys[:50]}))

    if records and not keys:
        logger.info("Only folder markers changed; nothing to sync.")
        return {"status": "skipped"}

    try:
        resp = client.start_ingestion_job(
            knowledgeBaseId=KB_ID,
            dataSourceId=DS_ID,
            description=f"kredify {trigger} sync ({len(keys)} changed object(s))"[:200],
        )
        job = resp["ingestionJob"]
        logger.info(json.dumps({"ingestion_job_id": job["ingestionJobId"], "status": job["status"]}))
        return {"status": "started", "ingestion_job_id": job["ingestionJobId"]}
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConflictException":
            if records:
                logger.info("Ingestion already in progress; raising so Lambda retries this S3 event shortly.")
                raise IngestionInProgress("Ingestion job already running; will retry.") from e
            logger.info("Ingestion already in progress; skipping this scheduled run.")
            return {"status": "deferred"}
        raise