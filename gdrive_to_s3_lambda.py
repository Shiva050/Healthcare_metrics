"""
Lambda: Google Drive CSV  ->  S3 (with DynamoDB control table dedup)

Flow per file found in the target Drive folder:
  1. List CSV files from Google Drive folder (including modifiedTime)
  2. For each file, compute MD5 hash of its content
  3. Look up the file_id in the DynamoDB control table
     - Not found                        -> new file, download + upload to S3
     - Found, same md5, merge_status=SUCCESS -> already landed in Silver -> skip
     - Found, same md5, merge_status!=SUCCESS -> content unchanged but the
       last Redshift merge never completed (or we don't know that it did) ->
       re-offer it so the Step Function retries the merge
     - Found, different md5             -> content changed -> re-download + upload
  4. Upload to S3 as  <original_name>_<YYYYMMDD_HHMMSS>.csv
     (timestamp derived from Drive modifiedTime, not processing time)
  5. Upsert the control table with latest file_id, md5, drive_modified_at,
     s3_key, and merge_status=PENDING — the Step Function flips this to
     SUCCESS/FAILED once it knows whether the Redshift merge actually landed,
     so a merge failure after this Lambda has already run doesn't silently
     get skipped as "already processed" next time.
  6. Return summary["processed"] entries include file_id, drive_modified_at,
     and md5 for the downstream Step Function -> Redshift MERGE flow (it
     needs file_id to update this same DynamoDB record's merge_status)

Placeholders (replace before deploy):
  DRIVE_FOLDER_ID   - Google Drive folder ID
  S3_BUCKET_NAME    - destination S3 bucket
  DYNAMODB_TABLE    - DynamoDB control table name
  SECRET_NAME       - AWS Secrets Manager secret holding the Drive service-account JSON
"""

import hashlib
import io
import json
import logging
from datetime import datetime

import boto3
from botocore.exceptions import ClientError
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# PLACEHOLDERS — fill in before deploying
# ---------------------------------------------------------------------------
DRIVE_FOLDER_ID = "1b85W0o8Zd1OuS0lM99zWcUBOkojFi-wK"
S3_BUCKET_NAME  = "health-care-metrics-prj-bronze"
S3_PREFIX       = "health_care_metrics_drive_raw/"
DYNAMODB_TABLE  = "healthcare_metrics_source_drive_ledger"
SECRET_NAME     = "healthcare/gdrive-service-account"
# ---------------------------------------------------------------------------

# DynamoDB attribute names
ATTR_FILE_ID        = "file_id"           # partition key
ATTR_MD5            = "md5hash"
ATTR_S3_KEY         = "s3_key"
ATTR_DRIVE_MODIFIED = "drive_modified_at" # ISO-8601 from Drive API
ATTR_FILE_NAME      = "file_name"
ATTR_MERGE_STATUS   = "merge_status"      # PENDING | SUCCESS | FAILED — set by
                                           # this Lambda (PENDING) and by the
                                           # Step Function once the Redshift
                                           # merge finishes (SUCCESS/FAILED)

MERGE_STATUS_PENDING = "PENDING"
MERGE_STATUS_SUCCESS = "SUCCESS"

DRIVE_SCOPES = ["https://www.googleapis.com/auth/drive.readonly"]


# ---------------------------------------------------------------------------
# Clients (initialised once per Lambda container)
# ---------------------------------------------------------------------------
_s3       = boto3.client("s3")
_dynamodb = boto3.resource("dynamodb")
_secrets  = boto3.client("secretsmanager")


def _get_drive_service():
    """Build a Google Drive service client using a service-account JSON stored
    in AWS Secrets Manager."""
    secret = _secrets.get_secret_value(SecretId=SECRET_NAME)
    sa_info = json.loads(secret["SecretString"])
    creds = service_account.Credentials.from_service_account_info(
        sa_info, scopes=DRIVE_SCOPES
    )
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def _list_csvs(drive_service):
    """Return list of {id, name, modifiedTime} dicts for all CSV files in the target folder."""
    query = (
        f"'{DRIVE_FOLDER_ID}' in parents"
        " and mimeType='text/csv'"
        " and trashed=false"
    )
    results = []
    page_token = None
    while True:
        resp = drive_service.files().list(
            q=query,
            fields="nextPageToken, files(id, name, modifiedTime)",
            pageToken=page_token,
        ).execute()
        results.extend(resp.get("files", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return results


def _download_file(drive_service, file_id: str) -> bytes:
    """Download a Drive file and return its raw bytes."""
    request = drive_service.files().get_media(fileId=file_id)
    buf = io.BytesIO()
    downloader = MediaIoBaseDownload(buf, request)
    done = False
    while not done:
        _, done = downloader.next_chunk()
    return buf.getvalue()


def _md5(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def _get_control_record(table, file_id: str):
    """Fetch the DynamoDB record for file_id, or None if not present."""
    try:
        resp = table.get_item(Key={ATTR_FILE_ID: file_id})
        return resp.get("Item")
    except ClientError as e:
        logger.error("DynamoDB get_item error: %s", e)
        raise


def _upsert_control_record(table, file_id: str, file_name: str,
                            md5: str, s3_key: str, drive_modified_at: str):
    # Always PENDING here: we're only ever called right before handing the
    # file off for merging, so we can't yet know whether that merge will
    # succeed. The Step Function is what flips this to SUCCESS/FAILED.
    table.put_item(Item={
        ATTR_FILE_ID:        file_id,
        ATTR_FILE_NAME:      file_name,
        ATTR_MD5:            md5,
        ATTR_S3_KEY:         s3_key,
        ATTR_DRIVE_MODIFIED: drive_modified_at,
        ATTR_MERGE_STATUS:   MERGE_STATUS_PENDING,
    })


def _upload_to_s3(data: bytes, base_name: str, timestamp: str) -> str:
    """Upload bytes to S3, return the S3 key."""
    stem = base_name.removesuffix(".csv").removesuffix(".CSV")
    s3_key = f"{S3_PREFIX}{stem}_{timestamp}.csv"
    _s3.put_object(
        Bucket=S3_BUCKET_NAME,
        Key=s3_key,
        Body=data,
        ContentType="text/csv",
    )
    logger.info("Uploaded s3://%s/%s", S3_BUCKET_NAME, s3_key)
    return s3_key


# ---------------------------------------------------------------------------
# Lambda entry point
# ---------------------------------------------------------------------------
def lambda_handler(event, context):
    drive_service = _get_drive_service()
    table = _dynamodb.Table(DYNAMODB_TABLE)

    csv_files = _list_csvs(drive_service)
    logger.info("Found %d CSV file(s) in Drive folder.", len(csv_files))

    summary = {"processed": [], "skipped": [], "errors": []}

    for f in csv_files:
        file_id           = f["id"]
        file_name         = f["name"]
        drive_modified_at = f.get("modifiedTime", "")   # ISO-8601 e.g. "2024-06-15T10:30:00.000Z"

        try:
            record = _get_control_record(table, file_id)

            # --- Download to compute MD5 -----------------------------------
            data        = _download_file(drive_service, file_id)
            current_md5 = _md5(data)

            if record:
                unchanged = record[ATTR_MD5] == current_md5
                already_merged = record.get(ATTR_MERGE_STATUS) == MERGE_STATUS_SUCCESS
                if unchanged and already_merged:
                    logger.info("SKIP %s — unchanged (md5 match) and already merged", file_name)
                    summary["skipped"].append(file_name)
                    continue
                elif unchanged:
                    logger.info(
                        "RETRY %s — unchanged content but merge_status=%s, reprocessing",
                        file_name, record.get(ATTR_MERGE_STATUS, "<missing>"),
                    )
                else:
                    logger.info(
                        "CHANGED %s — md5 %s -> %s",
                        file_name, record[ATTR_MD5], current_md5,
                    )
            else:
                logger.info("NEW %s — not in control table", file_name)

            # --- Derive S3 timestamp from Drive modifiedTime ---------------
            drive_dt  = datetime.fromisoformat(drive_modified_at.replace("Z", "+00:00"))
            timestamp = drive_dt.strftime("%Y%m%d_%H%M%S")

            # --- Upload to S3 with Drive-derived timestamp -----------------
            s3_key = _upload_to_s3(data, file_name, timestamp)

            # --- Update control table --------------------------------------
            _upsert_control_record(
                table,
                file_id=file_id,
                file_name=file_name,
                md5=current_md5,
                s3_key=s3_key,
                drive_modified_at=drive_modified_at,
            )
            summary["processed"].append({
                "file_id":           file_id,
                "file":              file_name,
                "s3_key":            s3_key,
                "drive_modified_at": drive_modified_at,
                "md5":               current_md5,
            })

        except Exception as exc:
            logger.exception("ERROR processing %s: %s", file_name, exc)
            summary["errors"].append({"file": file_name, "error": str(exc)})

    logger.info(
        "Done. processed=%d  skipped=%d  errors=%d",
        len(summary["processed"]),
        len(summary["skipped"]),
        len(summary["errors"]),
    )
    return summary
