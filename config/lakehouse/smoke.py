"""Exercise distributed execution, Delta transactions, and RustFS storage."""
from uuid import uuid4

from pyspark.sql import SparkSession
from pyspark.sql.functions import lit

spark = SparkSession.builder.appName("flotilla-lakehouse-smoke").getOrCreate()
path = f"s3a://lakehouse/smoke/{uuid4().hex}"
try:
    assert spark.sparkContext.master == "spark://spark-master:7077"
    data = spark.range(100).repartition(2)
    data.explain()
    data.write.format("delta").save(path)
    spark.range(100, 110).withColumn("source", lit("append")).write.format(
        "delta"
    ).mode("append").option("mergeSchema", "true").save(path)
    spark.read.format("delta").load(path).createOrReplaceTempView("smoke")
    assert spark.sql("SELECT count(*) FROM smoke").first()[0] == 110
    assert spark.read.format("delta").option("versionAsOf", 0).load(path).count() == 100
    spark.sql(f"DELETE FROM delta.`{path}` WHERE id >= 100")
    assert spark.read.format("delta").load(path).count() == 100
    print(f"PASS: distributed SQL, schema evolution, time travel, delete: {path}")
finally:
    spark.stop()
