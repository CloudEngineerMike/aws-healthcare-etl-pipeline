# Main configuration for the infrastructure
# This sets up resources
# such as S3 buckets, Glue databases,
# and IAM roles for the ETL pipeline.

# --- Terraform and AWS provider setup ---
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }
}

provider "aws" { region = var.aws_region }

resource "random_id" "suffix" { byte_length = 3 }

locals {
  suffix         = random_id.suffix.hex
  name_prefix    = "${var.project_name}-${local.suffix}"
  raw_bucket     = "${local.name_prefix}-raw"
  curated_bucket = "${local.name_prefix}-curated"
  glue_db_name   = replace("${var.project_name}_${local.suffix}", "-", "_")
  glue_job_name  = "${local.name_prefix}-csv-to-parquet"
}

# --- S3 buckets ---
resource "aws_s3_bucket" "raw" {
  bucket        = local.raw_bucket
  force_destroy = true
}

resource "aws_s3_bucket" "curated" {
  bucket        = local.curated_bucket
  force_destroy = true
}

resource "aws_s3_object" "folders" {
  for_each = toset(["incoming/", "athena/", "athena-query-results/", "scripts/"])
  bucket   = aws_s3_bucket.curated.bucket
  key      = each.value
}

# --- Glue IAM role ---
data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_role" {
  name               = "${local.name_prefix}-glue-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

data "aws_iam_policy_document" "glue_policy" {
  statement {
    sid = "S3Access"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*",
      aws_s3_bucket.curated.arn,
      "${aws_s3_bucket.curated.arn}/*"
    ]
  }

  statement {
    sid       = "GlueCatalog"
    actions   = ["glue:*"]
    resources = ["*"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_inline" {
  role   = aws_iam_role.glue_role.id
  name   = "${local.name_prefix}-glue-inline"
  policy = data.aws_iam_policy_document.glue_policy.json
}

# --- Glue Database ---
resource "aws_glue_catalog_database" "this" {
  name = local.glue_db_name
}

# --- Upload Glue script to S3 ---
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.curated.bucket
  key    = "scripts/glue_job_script.py"
  source = "${path.module}/glue_job_script.py"
  etag   = filemd5("${path.module}/glue_job_script.py")
}

# --- Glue Job (Spark) ---
resource "aws_glue_job" "csv_to_parquet" {
  name              = local.glue_job_name
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0" # PySpark 3
  number_of_workers = 2
  worker_type       = "G.1X"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.curated.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"            = "python"
    "--enable-metrics"          = "true"
    "--enable-glue-datacatalog" = "true"
    "--RAW_BUCKET"              = aws_s3_bucket.raw.bucket
    "--RAW_PREFIX"              = "incoming/"
    "--CURATED_BUCKET"          = aws_s3_bucket.curated.bucket
    "--CURATED_PREFIX"          = "athena/"
  }

  execution_property { max_concurrent_runs = 3 }
  depends_on = [aws_s3_object.glue_script]
}

resource "aws_cloudwatch_event_target" "s3_put_invokes_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_put_to_glue.name
  target_id = "invoke-start-glue-lambda"
  arn       = aws_lambda_function.start_glue_job.arn

  input_transformer {
    input_paths = {
      objectKey = "$.detail.object.key"
      bucket    = "$.detail.bucket.name"
    }
    input_template = jsonencode({
      "detail" : {
        "bucket" : { "name" : "<bucket>" },
        "object" : { "key" : "<objectKey>" }
      }
    })
  }
}

# Allow EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_glue_job.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_put_to_glue.arn
}

resource "aws_cloudwatch_event_rule" "s3_put_to_glue" {
  name        = "${local.name_prefix}-s3-object-created"
  description = "When a CSV is uploaded to raw/incoming/, start Glue job"
  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created"],
    "detail" : {
      "bucket" : { "name" : [aws_s3_bucket.raw.bucket] },
      "object" : { "key" : [{ "prefix" : "incoming/" }] }
    }
  })
}

# --- Glue Crawler over curated/ (every 15 min) ---
resource "aws_glue_crawler" "parquet_crawler" {
  name          = "${local.name_prefix}-parquet-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.this.name

  s3_target { path = "s3://${aws_s3_bucket.curated.bucket}/athena/" }

  schedule = "cron(0/15 * * * ? *)"
}

# --- Athena Workgroup ---
resource "aws_athena_workgroup" "wg" {
  name = "${local.name_prefix}-wg"
  configuration {
    result_configuration { output_location = "s3://${aws_s3_bucket.curated.bucket}/athena-query-results/" }
  }
  state = "ENABLED"
}

# --- Lambda function to start Glue job ---
data "archive_file" "start_glue_job_zip" {
  type        = "zip"
  output_path = "${path.module}/start_glue_job.zip"

  source {
    filename = "lambda_function.py"
    content  = <<-PY
      import os, json, boto3

      GLUE_JOB_NAME = os.environ["GLUE_JOB_NAME"]
      RAW_BUCKET     = os.environ["RAW_BUCKET"]      # for sanity/logging
      RAW_PREFIX     = os.environ["RAW_PREFIX"]      # for sanity/logging

      glue = boto3.client("glue")

      def handler(event, context):
          # EventBridge S3 event format
          # event["detail"]["object"]["key"] contains the S3 key
          try:
              key = event["detail"]["object"]["key"]
          except Exception:
              print("Event did not include S3 object key:", json.dumps(event))
              return {"ok": False, "reason": "missing key"}

          # Only kick off for CSVs (defensive)
          if not key.lower().endswith(".csv"):
              print(f"Skipping non-CSV upload: {key}")
              return {"ok": True, "skipped": True}

          print(f"Starting Glue job {GLUE_JOB_NAME} for {key}")
          resp = glue.start_job_run(
              JobName=GLUE_JOB_NAME,
              Arguments={
                  "--S3_OBJECT_KEY": key
              }
          )
          return {"ok": True, "jobRunId": resp.get("JobRunId")}
    PY
  }
}


# --- IAM role for Lambda ---
# Lambda assume role
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${local.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Lambda policy: logs + StartJobRun
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
  statement {
    sid       = "StartGlue"
    actions   = ["glue:StartJobRun"]
    resources = [aws_glue_job.csv_to_parquet.arn]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  role   = aws_iam_role.lambda_exec.id
  name   = "${local.name_prefix}-lambda-policy"
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# Lambda function
resource "aws_lambda_function" "start_glue_job" {
  function_name = "${local.name_prefix}-start-glue-job"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.handler"
  runtime       = "python3.12"
  filename      = data.archive_file.start_glue_job_zip.output_path
  timeout       = 30

  environment {
    variables = {
      GLUE_JOB_NAME = aws_glue_job.csv_to_parquet.name
      RAW_BUCKET    = aws_s3_bucket.raw.bucket
      RAW_PREFIX    = "incoming/"
    }
  }
}