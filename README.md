# 🧬 Healthcare ETL: Serverless AWS Data Pipeline (Terraform + Glue + Athena)

This project demonstrates an **end-to-end, event-driven ETL pipeline** on AWS built entirely with **Terraform**.  
When a healthcare CSV file is uploaded to an S3 bucket, the pipeline automatically:

1. **Detects the upload** via **EventBridge**
2. **Invokes a Lambda function** that triggers an **AWS Glue job**
3. **Transforms the CSV → Parquet**, partitioned by `ingest_date`
4. **Stores results** in a curated S3 bucket
5. **Catalogs data** with AWS Glue Crawler
6. **Makes data queryable** in **Amazon Athena**


## ⚙️ Architecture Overview

```
flowchart LR
    A[S3 Raw Bucket (incoming/)] -->|Object Created Event| B[EventBridge Rule]
    B --> C[Lambda: start_glue_job]
    C --> D[Glue Job: csv_to_parquet]
    D --> E[S3 Curated Bucket (athena/)]
    E --> F[Glue Crawler]
    F --> G[Glue Data Catalog]
    G --> H[Athena Workgroup]
```
### 🧩 Tech Stack

| Layer          | Service                        | Purpose                            |
| -------------- | ------------------------------ | ---------------------------------- |
| IaC            | **Terraform**                  | Infrastructure provisioning        |
| Ingestion      | **Amazon S3**                  | Stores raw CSV uploads             |
| Orchestration  | **Amazon EventBridge**         | Detects uploads and triggers ETL   |
| Processing     | **AWS Lambda**                 | Starts Glue job with object key    |
| Transformation | **AWS Glue (PySpark)**         | Converts CSV → partitioned Parquet |
| Metadata       | **AWS Glue Crawler / Catalog** | Registers schema in Athena         |
| Query          | **Amazon Athena**              | Run SQL on curated Parquet data    |


### Quick Start
1. Clone the Repo
```bash
git clone https://github.com/<your-username>/health-etl.git
cd health-etl
```
2. Initialize Terraform
```bash
terraform init
```
3. Deploy the Stack
```bash
terraform apply -auto-approve
```
Terraform will output key resources such as:

- raw_bucket
- curated_bucket
- glue_database
- athena_output
- lambda_name
- crawler_name

### 📤 Upload a Test CSV
```bash
RAW_BUCKET=$(terraform output -raw raw_bucket)

cat > sample.csv <<'CSV'
patient_id,encounter_id,diagnosis,amount
p-1001,e-9001,flu,120.50
p-1002,e-9002,covid,350.00
CSV

aws s3 cp sample.csv s3://$RAW_BUCKET/incoming/sample.csv
```
This triggers:
- EventBridge → Lambda → Glue ETL job
- Output Parquet → `s3://<curated-bucket>/athena/ingest_date=YYYY-MM-DD/`

### 🔍 Verify Outputs

1. Check Parquet Files
```bash
CURATED=$(terraform output -raw curated_bucket)
aws s3 ls s3://$CURATED/athena/ --recursive --human-readable
```

2. Trigger the Crawler (optional)
```bash
CRAWLER=$(terraform output -raw crawler_name)
aws glue start-crawler --name "$CRAWLER"
```

3. Query in Athena
Open Athena Console → select:
- Database: `$(terraform output -raw glue_database)`
- Table: `athena`
Run:
```sql
SELECT ingest_date, COUNT(*) AS rows
FROM "<your_db>"."athena"
GROUP BY ingest_date
ORDER BY ingest_date DESC;
```
🧹 Cleanup

When you’re done, destroy all resources to avoid costs: `terraform destroy -auto-approve`

Double-check no buckets remain: `aws s3 ls | grep health-etl`

If any linger: `aws s3 rb s3://<bucket-name> --force`

### 🔒 Security Notes

- No secrets are committed — credentials come from your local AWS CLI profile.
- .gitignore excludes state files, keys, and local ZIPs.
- All roles/policies are project-scoped with least privilege.

#### 🧠 Author

Michael G. Smith
Cloud Engineer / Full-Stack Developer
Built with ❤️ using AWS Glue, Lambda, EventBridge, and Terraform.


> ⚡ Serverless, IaC-driven, and 100% teardown-safe — perfect for AWS ETL demos or data-engineering proofs of concept.











