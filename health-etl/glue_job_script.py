# glue_job_script.py
# Sample AWS Glue job script to read CSV files from S3,
# transform them by adding an ingest date, and write
# them back to S3 in Parquet format partitioned by date.

import sys
import datetime as dt
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, [
    "RAW_BUCKET", "RAW_PREFIX",
    "CURATED_BUCKET", "CURATED_PREFIX",
    "S3_OBJECT_KEY"
])

RAW_BUCKET     = args["RAW_BUCKET"]
RAW_PREFIX     = args["RAW_PREFIX"]
CURATED_BUCKET = args["CURATED_BUCKET"]
CURATED_PREFIX = args["CURATED_PREFIX"]
OBJ_KEY        = args.get("S3_OBJECT_KEY", "")

# Partition by UTC ingest_date
ingest_date = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")

sc = SparkContext.getOrCreate()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session

# Guard: only process CSVs
if OBJ_KEY and not OBJ_KEY.lower().endswith(".csv"):
    print(f"Non-CSV detected ({OBJ_KEY}); skipping.")
    sys.exit(0)

src_path = f"s3://{RAW_BUCKET}/{OBJ_KEY}" if OBJ_KEY else f"s3://{RAW_BUCKET}/{RAW_PREFIX}"

df = (spark.read
          .option("header", "true")
          .option("inferSchema", "true")
          .csv(src_path))

df2 = df.withColumn("ingest_date", F.lit(ingest_date))

out_path = f"s3://{CURATED_BUCKET}/{CURATED_PREFIX}"

(df2
 .repartition(1)   # demo-friendly
 .write
 .mode("append")
 .partitionBy("ingest_date")
 .parquet(out_path))

print(f"Wrote Parquet to {out_path} partition={ingest_date}")
