import os, time, uuid, json, secrets, hashlib, base64, hmac, io, zipfile, threading, struct
from pathlib import Path
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Depends, Request, UploadFile, File
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from sqlalchemy import and_, or_, func, event
from sqlalchemy.exc import IntegrityError
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
DATA=Path(os.getenv('DATA_DIR','/tmp/retro6' if os.getenv('VERCEL') else 'data')); DATA.mkdir(parents=True,exist_ok=True)
from . import database as db
from .package_security import validate, signed_payload, PackageError, MAX_ZIP
from .blobs import blobs
keyfile=DATA/'release-key.pem'
if os.getenv('RELEASE_KEY_BASE64'):
    signing=Ed25519PrivateKey.from_private_bytes(base64.b64decode(os.environ['RELEASE_KEY_BASE64']))
elif keyfile.exists():
    signing=serialization.load_pem_private_key(keyfile.read_bytes(),password=None)
else:
    if os.getenv('VERCEL'):raise RuntimeError('RELEASE_KEY_BASE64 is required for stable package signatures on Vercel')
    signing=Ed25519PrivateKey.generate()
    fd=os.open(keyfile,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'wb') as f:f.write(signing.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
public=base64.b64encode(signing.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
key_id=hashlib.sha256(base64.b64decode(public)).hexdigest()[:16]
TICKET_SECRET=signing.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())

def uid():return str(uuid.uuid4())
def now():return time.time()
def digest(s):return hashlib.sha256(s.encode()).hexdigest()
def password(p,salt=None):
    salt=salt or secrets.token_hex(16)
    return salt+':'+hashlib.scrypt(p.encode(),salt=bytes.fromhex(salt),n=16384,r=8,p=1).hex()
def fail(code,message,status=400):raise HTTPException(status,{'code':code,'message':message})

def verify_totp(secret,code):
    if not code or not code.isdigit() or len(code)!=6:return False
    try:key=base64.b32decode(secret.upper().replace(' ',''),casefold=True)
    except Exception:return False
    counter=int(now())//30
    for offset in (-1,0,1):
        raw=hmac.new(key,struct.pack('>Q',counter+offset),hashlib.sha1).digest();start=raw[-1]&15
        number=(struct.unpack('>I',raw[start:start+4])[0]&0x7fffffff)%1000000
        if hmac.compare_digest(f'{number:06d}',code):return True
    return False

def init():
    if db.engine.dialect.name=='sqlite':
        @event.listens_for(db.engine,'connect')
        def foreign_keys(conn,record):conn.execute('PRAGMA foreign_keys=ON')
    if not os.getenv('VERCEL'):db.meta.create_all(db.engine)
    admin=os.getenv('ADMIN_EMAIL'); p=os.getenv('ADMIN_PASSWORD')
    if admin and p:
        if len(p)<12:raise RuntimeError('ADMIN_PASSWORD must be at least 12 characters')
        with db.engine.begin() as c:
            if not db.one(c,db.users,db.users.c.email==admin.lower()):c.execute(db.users.insert().values(id=uid(),email=admin.lower(),password=password(p),role='admin',created=now()))

@asynccontextmanager
async def lifespan(app):
    init();yield
app=FastAPI(title='Retro6 Platform',version='1.0.0',lifespan=lifespan)
@app.get('/v1/config')
def configuration():
    return {'directUpload': bool(os.getenv('S3_ENDPOINT')), 'synchronousValidation': bool(os.getenv('VERCEL'))}
class BodySizeMiddleware:
    def __init__(self,app):self.app=app
    async def __call__(self,scope,receive,send):
        total=0
        async def limited_receive():
            nonlocal total
            message=await receive()
            if message['type']=='http.request':
                total+=len(message.get('body',b''))
                if total>MAX_ZIP+65536:fail('TOO_LARGE','请求体超过配额',413)
            return message
        await self.app(scope,limited_receive if scope['type']=='http' else receive,send)
app.add_middleware(BodySizeMiddleware)
limits=defaultdict(deque); limit_lock=threading.Lock()
@app.middleware('http')
async def guard(request:Request,call_next):
    req_id=uid()
    if request.url.path.startswith('/v1/'):
        bucket=(request.client.host if request.client else 'local', 'auth' if '/auth/' in request.url.path else 'api')
        with limit_lock:
            q=limits[bucket]; t=now()
            while q and q[0]<t-60:q.popleft()
            denied=len(q)>=(20 if bucket[1]=='auth' else 240)
            if not denied:q.append(t)
        if denied:return JSONResponse({'code':'RATE_LIMIT','message':'请稍后再试','requestId':req_id},429)
        size=request.headers.get('content-length')
        if size and (not size.isdigit() or int(size)>MAX_ZIP+65536):return JSONResponse({'code':'TOO_LARGE','message':'请求过大','requestId':req_id},413)
    response=await call_next(request)
    response.headers['X-Request-ID']=req_id
    response.headers['X-Content-Type-Options']='nosniff'
    response.headers['Referrer-Policy']='no-referrer'
    if request.url.path.startswith('/v1/') or request.url.path.startswith('/downloads/'):response.headers['Cache-Control']='no-store'
    return response
@app.exception_handler(HTTPException)
async def error(request,e):
    detail=e.detail if isinstance(e.detail,dict) else {'code':'ERROR','message':str(e.detail)}
    return JSONResponse({**detail,'requestId':uid()},status_code=e.status_code)
@app.exception_handler(IntegrityError)
async def conflict(request,e):return JSONResponse({'code':'CONFLICT','message':'记录已存在或请求冲突','requestId':uid()},409)

def user(request:Request):
    token=request.headers.get('authorization','').removeprefix('Bearer ')
    with db.engine.connect() as c:
        session=db.one(c,db.sessions,db.sessions.c.hash==digest(token))
        if not session or session['expires']<now():fail('UNAUTHORIZED','请登录',401)
        u=db.one(c,db.users,db.users.c.id==session['user_id'])
        return {k:v for k,v in u.items() if k!='password'}
def admin(u=Depends(user)):
    if u['role'] not in ('admin','reviewer'):fail('FORBIDDEN','需要审核员权限',403)
    return u

def owned(c,app_id,u,write=True):
    a=db.one(c,db.apps,db.apps.c.id==app_id)
    if not a:fail('NOT_FOUND','应用不存在',404)
    member=db.one(c,db.members,and_(db.members.c.team_id==a['team_id'],db.members.c.user_id==u['id']))
    if not member or (write and member['role']=='Analyst'):fail('FORBIDDEN','无团队操作权限',403)
    return a

def mutation(c,request,u,payload):
    key=request.headers.get('Idempotency-Key')
    if not key:return None,None,None
    if not 1 <= len(key) <= 128:fail('INVALID_KEY','幂等键长度须为 1–128')
    fingerprint=digest(request.url.path+json.dumps(payload,sort_keys=True,separators=(',',':')))
    saved=db.one(c,db.idempotency,and_(db.idempotency.c.user_id==u['id'],db.idempotency.c.key==key))
    if saved:
        if saved['request_hash']!=fingerprint:fail('IDEMPOTENCY_CONFLICT','幂等键不能复用于不同请求',409)
        blob=base64.b64decode(saved['response']['encrypted'])
        result=json.loads(AESGCM(TICKET_SECRET).decrypt(blob[:12],blob[12:],key.encode()))
        return result,key,fingerprint
    return None,key,fingerprint

def remember(c,u,key,fingerprint,result):
    if key:
        nonce=secrets.token_bytes(12)
        encrypted=nonce+AESGCM(TICKET_SECRET).encrypt(nonce,json.dumps(result,separators=(',',':')).encode(),key.encode())
        c.execute(db.idempotency.insert().values(user_id=u['id'],key=key,request_hash=fingerprint,response={'encrypted':base64.b64encode(encrypted).decode()}))
    return result

def log(c,u,action,target,detail=''):c.execute(db.audit.insert().values(id=uid(),actor=u['id'],action=action,target=target,detail=detail,created=now()))
def token_for(c,u):
    token=secrets.token_urlsafe(32);c.execute(db.sessions.insert().values(hash=digest(token),user_id=u['id'],expires=now()+86400*7))
    return {'token':token,'user':{k:v for k,v in u.items() if k!='password'}}
class Auth(BaseModel):
    email:str=Field(min_length=5,max_length=254)
    password:str=Field(min_length=10,max_length=128)
    otp:str|None=Field(default=None,max_length=6)
@app.post('/v1/auth/register')
def register(body:Auth):
    email=body.email.strip().lower()
    if '@' not in email:fail('INVALID','邮箱无效')
    with db.engine.begin() as c:
        u={'id':uid(),'email':email,'password':password(body.password),'role':'user','created':now()}
        c.execute(db.users.insert().values(**u));t=uid()
        c.execute(db.teams.insert().values(id=t,name=email.split('@')[0]+' 的团队',owner_id=u['id']))
        c.execute(db.members.insert().values(team_id=t,user_id=u['id'],role='Owner'))
        return token_for(c,u)
@app.post('/v1/auth/login')
def login(body:Auth):
    with db.engine.begin() as c:
        u=db.one(c,db.users,db.users.c.email==body.email.strip().lower())
        if not u or not hmac.compare_digest(u['password'],password(body.password,u['password'].split(':')[0])):fail('UNAUTHORIZED','邮箱或密码错误',401)
        totp_secret=os.getenv('ADMIN_TOTP_SECRET')
        if u['role'] in ('admin','reviewer') and totp_secret and not verify_totp(totp_secret,body.otp):fail('MFA_REQUIRED','需要有效的管理员 6 位动态口令',401)
        return token_for(c,u)
@app.post('/v1/auth/logout')
def logout(request:Request,u=Depends(user)):
    with db.engine.begin() as c:c.execute(db.sessions.delete().where(db.sessions.c.hash==digest(request.headers['authorization'][7:])))
    return {'ok':True}
@app.post('/v1/auth/refresh')
def refresh(request:Request,u=Depends(user)):
    with db.engine.begin() as c:
        result=c.execute(db.sessions.delete().where(db.sessions.c.hash==digest(request.headers['authorization'][7:])))
        if result.rowcount!=1:fail('UNAUTHORIZED','会话已轮换',401)
        return token_for(c,u)
@app.get('/v1/me')
def me(u=Depends(user)):return u
@app.get('/v1/keys')
def keys():return {'keyId':key_id,'publicKey':public,'algorithm':'Ed25519'}
@app.get('/health')
def health():
    with db.engine.connect() as c:c.execute(db.users.select().limit(1))
    return {'status':'ok','version':'1.0.0'}
@app.get('/v1/developer/teams')
def teams(u=Depends(user)):
    with db.engine.connect() as c:
        ids=[m['team_id'] for m in db.many(c,db.members,db.members.c.user_id==u['id'])]
        return db.many(c,db.teams,db.teams.c.id.in_(ids))
class Member(BaseModel):
    email:str
    role:str
@app.post('/v1/developer/teams/{team_id}/members')
def member(team_id:str,body:Member,u=Depends(user)):
    if body.role not in ('Admin','Developer','Analyst'):fail('INVALID','角色无效')
    with db.engine.begin() as c:
        m=db.one(c,db.members,and_(db.members.c.team_id==team_id,db.members.c.user_id==u['id']))
        if not m or m['role'] not in ('Owner','Admin'):fail('FORBIDDEN','需要团队管理员',403)
        target=db.one(c,db.users,db.users.c.email==body.email.lower())
        if not target:fail('NOT_FOUND','成员需先注册',404)
        c.execute(db.members.insert().values(team_id=team_id,user_id=target['id'],role=body.role));log(c,u,'member.add',team_id)
    return {'ok':True}
class AppBody(BaseModel):
    bundle_id:str=Field(pattern=r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*){2,}$')
    name:str=Field(min_length=1,max_length=80)
    category:str=Field(default='工具',max_length=40)
    description:str=Field(default='',max_length=4000)
    privacy:str=Field(default='数据仅保存在设备本地。',max_length=2000)
    team_id:str|None=None
@app.post('/v1/developer/apps')
def create_app(body:AppBody,request:Request,u=Depends(user)):
    with db.engine.begin() as c:
        cached,ik,fp=mutation(c,request,u,body.model_dump())
        if cached is not None:return cached
        members=db.many(c,db.members,db.members.c.user_id==u['id'])
        tid=body.team_id or (members[0]['team_id'] if members else None)
        if not any(m['team_id']==tid and m['role']!='Analyst' for m in members):fail('FORBIDDEN','无团队权限',403)
        a={**body.model_dump(exclude={'team_id'}),'id':uid(),'team_id':tid,'created':now()}
        c.execute(db.apps.insert().values(**a));log(c,u,'app.create',a['id']);return remember(c,u,ik,fp,a)
@app.get('/v1/developer/apps')
def developer_apps(u=Depends(user)):
    with db.engine.connect() as c:
        ids=[m['team_id'] for m in db.many(c,db.members,db.members.c.user_id==u['id'])]
        return db.many(c,db.apps,db.apps.c.team_id.in_(ids))
@app.get('/v1/developer/apps/{app_id}/builds')
def app_builds(app_id:str,u=Depends(user)):
    with db.engine.connect() as c:
        owned(c,app_id,u,False);result=db.many(c,db.builds,db.builds.c.app_id==app_id)
        for b in result:b['review']=db.one(c,db.reviews,db.reviews.c.build_id==b['id'])
        return result
@app.post('/v1/developer/apps/{app_id}/builds')
async def upload(app_id:str,request:Request,file:UploadFile=File(...),u=Depends(user)):
    if os.getenv('VERCEL'):fail('USE_DIRECT_UPLOAD','请通过直传接口上传应用包',413)
    with db.engine.connect() as c:owned(c,app_id,u)
    data=await file.read(MAX_ZIP+1)
    try:m,sha=validate(data)
    except PackageError as e:fail('INVALID_PACKAGE',str(e))
    b={'id':uid(),'app_id':app_id,'version':m['version'],'sha256':sha,'manifest':m,'validation':'validated','created':now()}
    try:
        with db.engine.begin() as c:
            a=owned(c,app_id,u)
            cached,ik,fp=mutation(c,request,u,{'sha256':sha})
            if cached is not None:return cached
            if m['id']!=a['bundle_id']:fail('BUNDLE_MISMATCH','包 ID 与应用不符')
            c.execute(db.builds.insert().values(**b));blobs.put('packages/'+b['id']+'.simapp',data);log(c,u,'build.validated',b['id'],sha);remember(c,u,ik,fp,b)
    except Exception:
        blobs.delete('packages/'+b['id']+'.simapp');raise
    return b

@app.post('/v1/developer/apps/{app_id}/builds/upload-url')
def upload_url(app_id:str,request:Request,u=Depends(user)):
    with db.engine.begin() as c:
        owned(c,app_id,u)
        cached,ik,fp=mutation(c,request,u,{})
        if cached is not None:return cached
        upload_id=uid()
        try:url=blobs.presign('quarantine/'+upload_id)
        except PackageError as e:fail('STORAGE_MODE',str(e))
        c.execute(db.uploads.insert().values(id=upload_id,app_id=app_id,user_id=u['id'],status='uploaded',created=now()))
        return remember(c,u,ik,fp,{'uploadId':upload_id,'uploadUrl':url,'headers':{'Content-Type':'application/zip'},'expiresAt':now()+900})
class CompleteBody(BaseModel):upload_id:str
@app.post('/v1/developer/apps/{app_id}/builds/complete')
def complete_upload(app_id:str,body:CompleteBody,u=Depends(user)):
    if not os.getenv('VERCEL'):
        import redis
        from rq import Queue, Retry
    with db.engine.begin() as c:
        owned(c,app_id,u)
        row=db.one(c,db.uploads,and_(db.uploads.c.id==body.upload_id,db.uploads.c.app_id==app_id,db.uploads.c.user_id==u['id']))
        if not row:fail('NOT_FOUND','上传不存在',404)
        if row['status']!='uploaded':return row
        if row['created']<now()-900:fail('EXPIRED','上传凭证已过期',410)
        job_id='validation-'+row['id']
        if os.getenv('VERCEL'):
            c.execute(db.uploads.update().where(db.uploads.c.id==row['id']).values(status='validating'))
        else:
            connection=redis.Redis.from_url(os.getenv('REDIS_URL','redis://localhost:6379/0'))
            try:
                queue=Queue('validation',connection=connection)
                # Enqueue under the transaction; worker waits briefly for the committed validating state.
                c.execute(db.uploads.update().where(db.uploads.c.id==row['id']).values(status='validating'))
                queue.enqueue('services.api.worker.validate_upload',row['id'],job_id=job_id,job_timeout=120,result_ttl=3600,retry=Retry(max=3,interval=[1,3,5]))
            except Exception:fail('QUEUE_UNAVAILABLE','校验队列不可用，请稍后重试',503)
    if os.getenv('VERCEL'):
        from .worker import validate_upload
        validate_upload(row['id'])
        with db.engine.connect() as c:
            return db.one(c,db.uploads,db.uploads.c.id==row['id'])
    return {**row,'status':'validating','jobId':job_id}
@app.get('/v1/developer/apps/{app_id}/uploads/{upload_id}')
def upload_status(app_id:str,upload_id:str,u=Depends(user)):
    with db.engine.connect() as c:
        owned(c,app_id,u,False)
        row=db.one(c,db.uploads,and_(db.uploads.c.id==upload_id,db.uploads.c.app_id==app_id))
        if not row:fail('NOT_FOUND','上传不存在',404)
        return row

def authorized_build(c,build_id,u):
    b=db.one(c,db.builds,db.builds.c.id==build_id)
    if not b:fail('NOT_FOUND','构建不存在',404)
    release=db.one(c,db.releases,and_(db.releases.c.app_id==b['app_id'],db.releases.c.build_id==build_id,db.releases.c.status=='published'))
    if release:return b,'production'
    for access in db.many(c,db.beta_access,db.beta_access.c.user_id==u['id']):
        g=db.one(c,db.groups,and_(db.groups.c.id==access['group_id'],db.groups.c.build_id==build_id,db.groups.c.expires>now()))
        if g:return b,'beta'
    fail('FORBIDDEN','构建未发布或测试权限已过期',403)
class ReviewBody(BaseModel):
    reason:str=Field(default='',max_length=2000)
@app.post('/v1/developer/builds/{build_id}/submit-review')
def submit(build_id:str,u=Depends(user)):
    with db.engine.begin() as c:
        b=db.one(c,db.builds,db.builds.c.id==build_id)
        if not b:fail('NOT_FOUND','构建不存在',404)
        owned(c,b['app_id'],u)
        r=db.one(c,db.reviews,db.reviews.c.build_id==build_id)
        if r:
            if r['status']=='rejected':c.execute(db.reviews.update().where(db.reviews.c.id==r['id']).values(status='in_review',reason=''));r['status']='in_review'
            return r
        r={'id':uid(),'build_id':build_id,'status':'in_review','reason':'','reviewer_id':None,'created':now()}
        c.execute(db.reviews.insert().values(**r));log(c,u,'review.submit',build_id);return r
@app.get('/v1/admin/reviews')
def queue(u=Depends(admin)):
    with db.engine.connect() as c:
        rows=db.many(c,db.reviews)
        for r in rows:
            r['build']=db.one(c,db.builds,db.builds.c.id==r['build_id']);r['app']=db.one(c,db.apps,db.apps.c.id==r['build']['app_id'])
        return rows
@app.post('/v1/admin/reviews/{review_id}/{decision}')
def decide(review_id:str,decision:str,body:ReviewBody,u=Depends(admin)):
    if decision not in ('approve','reject'):fail('INVALID','无效审核决定')
    if decision=='reject' and not body.reason.strip():fail('INVALID','拒绝需填写理由')
    with db.engine.begin() as c:
        r=db.one(c,db.reviews,db.reviews.c.id==review_id)
        if not r:fail('NOT_FOUND','审核不存在',404)
        result=c.execute(db.reviews.update().where(and_(db.reviews.c.id==review_id,db.reviews.c.status=='in_review')).values(status='approved' if decision=='approve' else 'rejected',reason=body.reason,reviewer_id=u['id']))
        if result.rowcount!=1:fail('CONFLICT','审核已处理',409)
        log(c,u,'review.'+decision,review_id,body.reason)
    return {'ok':True}
class ReleaseBody(BaseModel):
    build_id:str
    notes:str=Field(default='',max_length=4000)
@app.post('/v1/developer/apps/{app_id}/releases')
def publish(app_id:str,body:ReleaseBody,u=Depends(user)):
    with db.engine.begin() as c:
        owned(c,app_id,u)
        b=db.one(c,db.builds,and_(db.builds.c.id==body.build_id,db.builds.c.app_id==app_id))
        r=db.one(c,db.reviews,and_(db.reviews.c.build_id==body.build_id,db.reviews.c.status=='approved'))
        if not b or not r:fail('NOT_APPROVED','构建尚未通过审核',409)
        old=db.one(c,db.releases,db.releases.c.app_id==app_id)
        if old:
            ob=db.one(c,db.builds,db.builds.c.id==old['build_id'])
            if tuple(map(int,b['version'].split('.')))<tuple(map(int,ob['version'].split('.'))):fail('VERSION_DOWNGRADE','禁止降级发布；回滚请上传更高版本',409)
            c.execute(db.releases.update().where(db.releases.c.app_id==app_id).values(build_id=b['id'],status='published',notes=body.notes,created=now()))
        else:c.execute(db.releases.insert().values(app_id=app_id,build_id=b['id'],status='published',notes=body.notes,created=now()))
        log(c,u,'release.publish',b['id'],body.notes)
    return {'ok':True}
@app.post('/v1/admin/apps/{app_id}/remove')
def remove(app_id:str,body:ReviewBody,u=Depends(admin)):
    if not body.reason.strip():fail('INVALID','需填写下架原因')
    with db.engine.begin() as c:c.execute(db.releases.update().where(db.releases.c.app_id==app_id).values(status='removed'));log(c,u,'release.remove',app_id,body.reason)
    return {'ok':True}
class GroupBody(BaseModel):
    build_id:str
    name:str=Field(default='外部测试',min_length=1,max_length=80)
    days:int=Field(default=30,ge=1,le=90)
@app.post('/v1/beta/groups')
def group(body:GroupBody,request:Request,u=Depends(user)):
    with db.engine.begin() as c:
        cached,ik,fp=mutation(c,request,u,body.model_dump())
        if cached is not None:return cached
        b=db.one(c,db.builds,db.builds.c.id==body.build_id)
        if not b:fail('NOT_FOUND','构建不存在',404)
        owned(c,b['app_id'],u)
        g={'id':uid(),'app_id':b['app_id'],'build_id':b['id'],'name':body.name,'expires':now()+body.days*86400}
        c.execute(db.groups.insert().values(**g));log(c,u,'beta.group',g['id']);return remember(c,u,ik,fp,g)
@app.get('/v1/developer/apps/{app_id}/groups')
def list_groups(app_id:str,u=Depends(user)):
    with db.engine.connect() as c:owned(c,app_id,u,False);return db.many(c,db.groups,db.groups.c.app_id==app_id)
@app.post('/v1/beta/groups/{group_id}/invites')
def invite(group_id:str,request:Request,u=Depends(user)):
    with db.engine.begin() as c:
        cached,ik,fp=mutation(c,request,u,{})
        if cached is not None:return cached
        g=db.one(c,db.groups,db.groups.c.id==group_id)
        if not g or g['expires']<now():fail('NOT_FOUND','测试组不存在或已过期',404)
        owned(c,g['app_id'],u);token=secrets.token_urlsafe(24)
        c.execute(db.invites.insert().values(hash=digest(token),group_id=group_id,expires=g['expires'],revoked=0));log(c,u,'beta.invite',group_id)
        return remember(c,u,ik,fp,{'code':token,'expires':g['expires']})
class CodeBody(BaseModel):code:str=Field(min_length=16,max_length=128)
@app.post('/v1/beta/invites/redeem')
def redeem(body:CodeBody,u=Depends(user)):
    with db.engine.begin() as c:
        inv=db.one(c,db.invites,db.invites.c.hash==digest(body.code))
        if not inv or inv['revoked'] or inv['expires']<now():fail('INVALID_INVITE','邀请码无效或已过期',404)
        if inv['redeemed_by']==u['id']:return {'ok':True}
        updated=c.execute(db.invites.update().where(and_(db.invites.c.hash==inv['hash'],db.invites.c.redeemed_by.is_(None),db.invites.c.revoked==0)).values(redeemed_by=u['id']))
        if updated.rowcount!=1:fail('USED_INVITE','邀请码已使用',409)
        if not db.one(c,db.beta_access,and_(db.beta_access.c.group_id==inv['group_id'],db.beta_access.c.user_id==u['id'])):c.execute(db.beta_access.insert().values(group_id=inv['group_id'],user_id=u['id']))
        log(c,u,'beta.redeem',inv['group_id'])
    return {'ok':True}
@app.post('/v1/beta/groups/{group_id}/revoke')
def revoke(group_id:str,u=Depends(user)):
    with db.engine.begin() as c:
        g=db.one(c,db.groups,db.groups.c.id==group_id)
        if not g:fail('NOT_FOUND','测试组不存在',404)
        owned(c,g['app_id'],u);c.execute(db.groups.update().where(db.groups.c.id==group_id).values(expires=now()-1));c.execute(db.invites.update().where(db.invites.c.group_id==group_id).values(revoked=1));log(c,u,'beta.revoke',group_id)
    return {'ok':True}
@app.get('/v1/beta/my-builds')
def my_beta(u=Depends(user)):
    with db.engine.connect() as c:
        ids=[x['group_id'] for x in db.many(c,db.beta_access,db.beta_access.c.user_id==u['id'])];result=[]
        for g in db.many(c,db.groups,and_(db.groups.c.id.in_(ids),db.groups.c.expires>now())):
            b=db.one(c,db.builds,db.builds.c.id==g['build_id']);result.append({**db.one(c,db.apps,db.apps.c.id==g['app_id']),'build':b,'group':g,'channel':'beta'})
        return result
class FeedbackBody(BaseModel):
    build_id:str
    content:str=Field(min_length=1,max_length=4000)
    device:dict[str,str]|None=Field(default=None,max_length=8)
@app.post('/v1/beta/feedback')
def send_feedback(body:FeedbackBody,u=Depends(user)):
    with db.engine.begin() as c:
        authorized_build(c,body.build_id,u);f={'id':uid(),'user_id':u['id'],**body.model_dump(),'created':now()};c.execute(db.feedback.insert().values(**f));return f
@app.post('/v1/beta/feedback/{feedback_id}/screenshot')
async def screenshot(feedback_id:str,file:UploadFile=File(...),u=Depends(user)):
    with db.engine.connect() as c:
        f=db.one(c,db.feedback,and_(db.feedback.c.id==feedback_id,db.feedback.c.user_id==u['id']))
        if not f:fail('FORBIDDEN','只能为自己的反馈上传截图',403)
        authorized_build(c,f['build_id'],u)
    data=await file.read(2*1024*1024+1)
    if len(data)>2*1024*1024 or len(data)<24 or data[:8]!=b'\x89PNG\r\n\x1a\n' or data[12:16]!=b'IHDR':fail('INVALID_IMAGE','截图须为不超过 2 MiB 的 PNG')
    w,h=struct.unpack('>II',data[16:24])
    if not 1<=w<=4096 or not 1<=h<=4096:fail('INVALID_IMAGE','截图尺寸超过配额')
    key='feedback/'+feedback_id+'.png';blobs.put(key,data)
    with db.engine.begin() as c:c.execute(db.feedback.update().where(db.feedback.c.id==feedback_id).values(attachment_key=key))
    return {'ok':True}
@app.get('/v1/beta/feedback/{feedback_id}/screenshot')
def get_screenshot(feedback_id:str,u=Depends(user)):
    with db.engine.connect() as c:
        f=db.one(c,db.feedback,db.feedback.c.id==feedback_id)
        if not f or not f['attachment_key']:fail('NOT_FOUND','截图不存在',404)
        if f['user_id']!=u['id']:
            b=db.one(c,db.builds,db.builds.c.id==f['build_id']);owned(c,b['app_id'],u,False)
    return Response(blobs.get(f['attachment_key']),media_type='image/png',headers={'Content-Disposition':'inline; filename=feedback.png'})
@app.get('/v1/developer/apps/{app_id}/feedback')
def get_feedback(app_id:str,u=Depends(user)):
    with db.engine.connect() as c:
        owned(c,app_id,u,False);ids=[b['id'] for b in db.many(c,db.builds,db.builds.c.app_id==app_id)];return db.many(c,db.feedback,db.feedback.c.build_id.in_(ids))

def store_rows(c):
    result=[]
    for r in db.many(c,db.releases,db.releases.c.status=='published'):
        a=db.one(c,db.apps,db.apps.c.id==r['app_id']);b=db.one(c,db.builds,db.builds.c.id==r['build_id'])
        rs=db.many(c,db.ratings,db.ratings.c.app_id==a['id'])
        result.append({**a,'build':b,'release':r,'rating':round(sum(x['stars'] for x in rs)/len(rs),1) if rs else None,'ratingCount':len(rs),'channel':'production'})
    return result
@app.get('/v1/store/featured')
@app.get('/v1/store/search')
def store(q:str='',category:str=''):
    with db.engine.connect() as c:return [a for a in store_rows(c) if q.lower() in (a['name']+' '+a['description']).lower() and (not category or a['category']==category)]
@app.get('/v1/store/apps/{app_id}')
def store_detail(app_id:str):
    with db.engine.connect() as c:
        a=next((a for a in store_rows(c) if a['id']==app_id),None)
        if not a:fail('NOT_FOUND','应用未上架',404)
        a['ratings']=db.many(c,db.ratings,db.ratings.c.app_id==app_id);return a
class TicketBody(BaseModel):build_id:str|None=None
@app.post('/v1/store/apps/{app_id}/install-ticket')
def ticket(app_id:str,body:TicketBody,request:Request,u=Depends(user)):
    with db.engine.connect() as c:
        r=db.one(c,db.releases,and_(db.releases.c.app_id==app_id,db.releases.c.status=='published'))
        build_id=body.build_id or (r['build_id'] if r else '')
        b,channel=authorized_build(c,build_id,u)
        if b['app_id']!=app_id:fail('INVALID','构建不属于应用')
        exp=int(now()+300);payload=signed_payload(b);link=f'{build_id}.{u["id"]}.{exp}'
        mac=hmac.new(TICKET_SECRET,link.encode(),hashlib.sha256).hexdigest()
        download_url=(blobs.presign_read('packages/'+build_id+'.simapp') if os.getenv('VERCEL') else f'/downloads/{build_id}?user={u["id"]}&expires={exp}&mac={mac}')
        return {'buildId':b['id'],'appId':app_id,'version':b['version'],'manifest':b['manifest'],'channel':channel,'sha256':b['sha256'],'payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(signing.sign(payload)).decode(),'signatureKeyId':key_id,'expiresAt':exp,'downloadUrl':download_url}
@app.get('/downloads/{build_id}')
def download(build_id:str,user:str,expires:int,mac:str):
    if os.getenv('VERCEL'):fail('USE_SIGNED_URL','请重新获取安装票据并使用其中的下载地址',410)
    link=f'{build_id}.{user}.{expires}'
    if expires<now() or expires>now()+305 or not hmac.compare_digest(hmac.new(TICKET_SECRET,link.encode(),hashlib.sha256).hexdigest(),mac):fail('INVALID_TICKET','下载票据无效',403)
    with db.engine.connect() as c:authorized_build(c,build_id,{'id':user})
    try:data=blobs.get('packages/'+build_id+'.simapp')
    except (FileNotFoundError,PackageError):fail('NOT_FOUND','包文件缺失或超过配额',404)
    return Response(data,media_type='application/zip',headers={'Content-Disposition':f'attachment; filename={build_id}.simapp'})
@app.get('/v1/store/apps/{app_id}/icon')
def icon(app_id:str):
    with db.engine.connect() as c:
        r=db.one(c,db.releases,and_(db.releases.c.app_id==app_id,db.releases.c.status=='published'))
        if not r:fail('NOT_FOUND','未上架',404)
        b=db.one(c,db.builds,db.builds.c.id==r['build_id'])
    with zipfile.ZipFile(io.BytesIO(blobs.get('packages/'+b['id']+'.simapp'))) as z:return Response(z.read(b['manifest']['icon']),media_type='image/png')
class InstallBody(BaseModel):build_id:str
@app.post('/v1/store/apps/{app_id}/installed')
def installed(app_id:str,body:InstallBody,u=Depends(user)):
    with db.engine.begin() as c:
        b,ch=authorized_build(c,body.build_id,u)
        if b['app_id']!=app_id:fail('INVALID','构建不匹配')
        old=db.one(c,db.installs,and_(db.installs.c.user_id==u['id'],db.installs.c.app_id==app_id))
        if old:c.execute(db.installs.update().where(and_(db.installs.c.user_id==u['id'],db.installs.c.app_id==app_id)).values(build_id=b['id'],created=now()))
        else:c.execute(db.installs.insert().values(user_id=u['id'],app_id=app_id,build_id=b['id'],created=now()))
    return {'ok':True}
@app.delete('/v1/store/apps/{app_id}/installed')
def uninstall(app_id:str,u=Depends(user)):
    with db.engine.begin() as c:c.execute(db.installs.delete().where(and_(db.installs.c.user_id==u['id'],db.installs.c.app_id==app_id)))
    return {'ok':True}
@app.get('/v1/store/updates')
def updates(u=Depends(user)):
    with db.engine.connect() as c:
        existing={i['app_id']:i['build_id'] for i in db.many(c,db.installs,db.installs.c.user_id==u['id'])}
        return [a for a in store_rows(c) if a['id'] in existing and a['build']['id']!=existing[a['id']]]
class RatingBody(BaseModel):
    stars:int=Field(ge=1,le=5)
    text:str=Field(default='',max_length=2000)
@app.post('/v1/store/apps/{app_id}/ratings')
def rate(app_id:str,body:RatingBody,u=Depends(user)):
    with db.engine.begin() as c:
        cond=and_(db.installs.c.user_id==u['id'],db.installs.c.app_id==app_id)
        if not db.one(c,db.installs,cond):fail('FORBIDDEN','安装后才能评价',403)
        cond=and_(db.ratings.c.user_id==u['id'],db.ratings.c.app_id==app_id)
        if db.one(c,db.ratings,cond):c.execute(db.ratings.update().where(cond).values(**body.model_dump()))
        else:c.execute(db.ratings.insert().values(user_id=u['id'],app_id=app_id,**body.model_dump()))
    return {'ok':True}
@app.get('/v1/developer/apps/{app_id}/stats')
def stats(app_id:str,u=Depends(user)):
    with db.engine.connect() as c:
        owned(c,app_id,u,False)
        return {'installations':len(db.many(c,db.installs,db.installs.c.app_id==app_id)),'builds':len(db.many(c,db.builds,db.builds.c.app_id==app_id))}
@app.get('/v1/admin/audit')
def audit(u=Depends(admin)):
    with db.engine.connect() as c:return list(reversed(db.many(c,db.audit)))[:500]
WEB=Path(__file__).resolve().parents[2]/'apps'/'developer-web'
app.mount('/',StaticFiles(directory=WEB,html=True),name='web')
