import os
from pathlib import Path
from .package_security import MAX_ZIP, PackageError
class BlobStore:
    def __init__(self):
        if os.getenv('VERCEL') and not os.getenv('S3_ENDPOINT'):
            raise RuntimeError('S3_ENDPOINT is required for durable .simapp storage on Vercel')
        self.bucket=os.getenv('S3_BUCKET','retro6')
        self.path=Path(os.getenv('DATA_DIR','/tmp/retro6' if os.getenv('VERCEL') else 'data'))/'blobs'
        if not os.getenv('S3_ENDPOINT'):self.path.mkdir(parents=True,exist_ok=True)
        self.client=None;self.external=None
        if os.getenv('S3_ENDPOINT'):
            import boto3
            from botocore.config import Config
            opts=dict(aws_access_key_id=os.environ['S3_ACCESS_KEY'],aws_secret_access_key=os.environ['S3_SECRET_KEY'],region_name='us-east-1',config=Config(signature_version='s3v4',s3={'addressing_style':'path'}))
            self.client=boto3.client('s3',endpoint_url=os.environ['S3_ENDPOINT'],**opts)
            self.external=boto3.client('s3',endpoint_url=os.getenv('S3_PUBLIC_ENDPOINT',os.environ['S3_ENDPOINT']),**opts)
    def put(self,key,data):
        if self.client:self.client.put_object(Bucket=self.bucket,Key=key,Body=data,ContentType='image/png' if key.endswith('.png') else 'application/zip')
        else:
            path=self.path/key;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    def get(self,key):
        if self.client:
            result=self.client.get_object(Bucket=self.bucket,Key=key)
            if result['ContentLength']>MAX_ZIP:result['Body'].close();raise PackageError('对象超过大小配额')
            data=result['Body'].read(MAX_ZIP+1);result['Body'].close()
        else:data=(self.path/key).read_bytes()
        if len(data)>MAX_ZIP:raise PackageError('对象超过大小配额')
        return data
    def delete(self,key):
        if self.client:self.client.delete_object(Bucket=self.bucket,Key=key)
        else:(self.path/key).unlink(missing_ok=True)
    def presign(self,key):
        if not self.external:raise PackageError('直传接口需要 S3 模式；本地模式请使用 multipart 构建上传')
        return self.external.generate_presigned_url('put_object',Params={'Bucket':self.bucket,'Key':key,'ContentType':'application/zip'},ExpiresIn=900)
    def presign_read(self,key,ttl=300):
        if not self.external:raise PackageError('签名直链需要 S3 模式')
        return self.external.generate_presigned_url('get_object',Params={'Bucket':self.bucket,'Key':key},ExpiresIn=ttl)
blobs=BlobStore()
