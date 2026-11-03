"""Create data only in the disposable Moto service launched by integration-test.py."""
import sys
from concurrent.futures import ThreadPoolExecutor
import boto3
from botocore.config import Config

client = boto3.client('s3', endpoint_url=sys.argv[1], aws_access_key_id='clouddock-fixture',
                      aws_secret_access_key='fixture-only-not-a-real-secret', region_name='us-east-1',
                      config=Config(max_pool_connections=16))
keys = [f'paging/entry{i:04d}.txt' for i in range(1205)]
keys += ['paging/资料 空+%&.txt', 'paging/same', 'paging/same/inside.txt', 'paging/empty/', 'paging/nested/deep.txt']
with ThreadPoolExecutor(max_workers=12) as pool:
    list(pool.map(lambda key: client.put_object(Bucket='fixture', Key=key, Body=b'fixture'), keys))
print(f'Seeded {len(keys)} isolated objects for pagination checks', flush=True)
