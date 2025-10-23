# Output values for the infrastructure
# These can be referenced after deployment
# to get important resource identifiers
# such as bucket names and database names.

output "raw_bucket" {
  value = aws_s3_bucket.raw.bucket
}

output "curated_bucket" {
  value = aws_s3_bucket.curated.bucket
}

output "glue_database" {
  value = aws_glue_catalog_database.this.name
}

output "athena_output" {
  value = "s3://${aws_s3_bucket.curated.bucket}/athena-query-results/"
}

output "upload_hint" {
  value = "Upload CSVs to s3://${aws_s3_bucket.raw.bucket}/incoming/"
}

output "glue_job_name" {
  value = aws_glue_job.csv_to_parquet.name
}

output "lambda_name"   {
  value = aws_lambda_function.start_glue_job.function_name
}

output "crawler_name" {
  value = aws_glue_crawler.parquet_crawler.name
}