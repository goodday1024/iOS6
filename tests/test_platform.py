import os, tempfile, io, zipfile, json, stat, base64, hashlib, uuid
from pathlib import Path
if not os.getenv('TEST_USE_DATABASE_ENV'):
    os.environ['DATA_DIR']=tempfile.mkdtemp(prefix='retro6-test-')
    os.environ['DATABASE_URL']='sqlite:///:memory:'
os.environ['ADMIN_EMAIL']='admin@example.test'
os.environ['ADMIN_PASSWORD']='admin-test-password-123'
from fastapi.testclient import TestClient
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from services.api.main import app, limits
from services.api.package_security import validate, PackageError
ROOT=Path(__file__).resolve().parents[1]

def pack(version='1.0.0',bundle='com.retro.pixelnotes',extras=None):
    manifest=json.loads((ROOT/'examples/pixel-notes/manifest.json').read_text());manifest.update(version=version,id=bundle)
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('manifest.json',json.dumps(manifest));z.writestr('index.html',(ROOT/'examples/pixel-notes/index.html').read_bytes());z.writestr('assets/icon.png',(ROOT/'examples/pixel-notes/assets/icon.png').read_bytes())
        for name,data in (extras or {}).items():z.writestr(name,data)
    return out.getvalue()

def register(c,email):
    r=c.post('/v1/auth/register',json={'email':email,'password':'long-password-123'});assert r.status_code==200,r.text
    return {'Authorization':'Bearer '+r.json()['token']}
def upload(c,a,h,version='1.0.0'):
    r=c.post(f'/v1/developer/apps/{a}/builds',headers=h,files={'file':('Notes.simapp',pack(version),'application/zip')});assert r.status_code==200,r.text;return r.json()

def test_complete_delivery_update_and_security():
    limits.clear()
    with TestClient(app) as c:
        dev=register(c,'dev@example.test');tester=register(c,'test@example.test');consumer=register(c,'consumer@example.test');stranger=register(c,'stranger@example.test')
        admin={'Authorization':'Bearer '+c.post('/v1/auth/login',json={'email':os.environ['ADMIN_EMAIL'],'password':os.environ['ADMIN_PASSWORD']}).json()['token']}
        a=c.post('/v1/developer/apps',headers=dev,json={'name':'Pixel Notes','bundle_id':'com.retro.pixelnotes','description':'记住每个想法'}).json()['id']
        assert c.post(f'/v1/developer/apps/{a}/builds',headers=stranger,files={'file':('evil.simapp',pack())}).status_code==403
        b=upload(c,a,dev)
        assert c.get('/v1/store/featured').json()==[]
        assert c.post(f'/v1/store/apps/{a}/install-ticket',headers=consumer,json={'build_id':b['id']}).status_code==403
        group=c.post('/v1/beta/groups',headers=dev,json={'build_id':b['id']}).json()
        code=c.post(f'/v1/beta/groups/{group["id"]}/invites',headers=dev).json()['code']
        assert c.post('/v1/beta/invites/redeem',headers=tester,json={'code':code}).status_code==200
        assert c.post('/v1/beta/invites/redeem',headers=consumer,json={'code':code}).status_code==409
        beta=c.get('/v1/beta/my-builds',headers=tester).json();assert beta[0]['build']['id']==b['id']
        ticket=c.post(f'/v1/store/apps/{a}/install-ticket',headers=tester,json={'build_id':b['id']}).json()
        assert ticket['channel']=='beta'
        data=c.get(ticket['downloadUrl']).content
        assert hashlib.sha256(data).hexdigest()==ticket['sha256']
        key=Ed25519PublicKey.from_public_bytes(base64.b64decode(c.get('/v1/keys').json()['publicKey']))
        key.verify(base64.b64decode(ticket['signature']),base64.b64decode(ticket['payload']))
        signed=json.loads(base64.b64decode(ticket['payload']));assert signed['appId']==a and signed['permissions']==['storage']
        import pytest
        with pytest.raises(Exception):key.verify(base64.b64decode(ticket['signature']),base64.b64decode(ticket['payload'])+b'changed')
        assert c.get(ticket['downloadUrl'].replace('mac=','mac=x')).status_code==403
        assert c.post('/v1/beta/feedback',headers=tester,json={'build_id':b['id'],'content':'Hello iOS 6 已保存'}).status_code==200
        assert c.get(f'/v1/developer/apps/{a}/feedback',headers=dev).json()[0]['content'].startswith('Hello')
        assert c.get(f'/v1/developer/apps/{a}/feedback',headers=stranger).status_code==403
        assert c.post(f'/v1/developer/apps/{a}/releases',headers=dev,json={'build_id':b['id']}).status_code==409
        review=c.post(f'/v1/developer/builds/{b["id"]}/submit-review',headers=dev).json()
        assert c.post(f'/v1/admin/reviews/{review["id"]}/approve',headers=dev,json={}).status_code==403
        assert c.post(f'/v1/admin/reviews/{review["id"]}/approve',headers=admin,json={'reason':'检查通过'}).status_code==200
        assert c.post(f'/v1/admin/reviews/{review["id"]}/approve',headers=admin,json={}).status_code==409
        assert c.post(f'/v1/developer/apps/{a}/releases',headers=dev,json={'build_id':b['id']}).status_code==200
        assert c.get('/v1/store/search?q=Pixel').json()[0]['id']==a
        assert c.get(f'/v1/store/apps/{a}/icon').content.startswith(b'\x89PNG')
        t=c.post(f'/v1/store/apps/{a}/install-ticket',headers=consumer,json={}).json();assert c.get(t['downloadUrl']).status_code==200
        assert c.post(f'/v1/store/apps/{a}/installed',headers=consumer,json={'build_id':b['id']}).status_code==200
        assert c.post(f'/v1/store/apps/{a}/ratings',headers=consumer,json={'stars':5,'text':'好用'}).status_code==200
        assert c.post(f'/v1/store/apps/{a}/ratings',headers=stranger,json={'stars':5}).status_code==403
        b2=upload(c,a,dev,'1.1.0')
        r2=c.post(f'/v1/developer/builds/{b2["id"]}/submit-review',headers=dev).json()
        c.post(f'/v1/admin/reviews/{r2["id"]}/approve',headers=admin,json={})
        c.post(f'/v1/developer/apps/{a}/releases',headers=dev,json={'build_id':b2['id']})
        assert c.get('/v1/store/updates',headers=consumer).json()[0]['build']['id']==b2['id']
        assert c.post(f'/v1/beta/groups/{group["id"]}/revoke',headers=dev).status_code==200
        assert c.get('/v1/beta/my-builds',headers=tester).json()==[]
        assert c.get(ticket['downloadUrl']).status_code==403
        assert c.post(f'/v1/admin/apps/{a}/remove',headers=admin,json={'reason':'撤销测试发布'}).status_code==200
        assert c.get('/v1/store/featured').json()==[]
        assert c.get('/v1/admin/audit',headers=admin).json()
        refreshed=c.post('/v1/auth/refresh',headers=dev);assert refreshed.status_code==200
        assert c.get('/v1/me',headers=dev).status_code==401
        new={'Authorization':'Bearer '+refreshed.json()['token']};c.post('/v1/auth/logout',headers=new);assert c.get('/v1/me',headers=new).status_code==401

def test_package_adversarial_cases():
    import pytest
    for name in ['../outside','/absolute','assets/../../escape','a\\b.js','.env','evil.exe','assets/a:evil.js']:
        with pytest.raises(PackageError):validate(pack(extras={name:b'malicious'}))
    with pytest.raises(PackageError):validate(b'not zip')
    out=io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(pack())) as source,zipfile.ZipFile(out,'w') as z:
        for name in source.namelist():z.writestr(name,source.read(name))
        e=zipfile.ZipInfo('assets/escape.js');e.create_system=3;e.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(e,'/etc/passwd')
    with pytest.raises(PackageError):validate(out.getvalue())
    with pytest.raises(PackageError):validate(pack(extras={'bomb.txt':b'a'*(2*1024*1024)}))
    with pytest.raises(PackageError):validate(pack(extras={'INDEX.html':b'duplicate'}))
    with pytest.raises(PackageError):validate(pack(version='01.0.0'))

def test_team_analyst_cannot_modify():
    limits.clear()
    with TestClient(app) as c:
        owner=register(c,'owner@example.test');analyst=register(c,'analyst@example.test')
        team=c.get('/v1/developer/teams',headers=owner).json()[0]
        c.post(f'/v1/developer/teams/{team["id"]}/members',headers=owner,json={'email':'analyst@example.test','role':'Analyst'})
        app_id=c.post('/v1/developer/apps',headers=owner,json={'bundle_id':'com.retro.analyst','name':'Analyst'}).json()['id']
        assert c.get('/v1/developer/apps',headers=analyst).json()[0]['id']==app_id
        assert c.post('/v1/developer/apps',headers=analyst,json={'bundle_id':'com.retro.forbidden','name':'X','team_id':team['id']}).status_code==403
        assert c.post(f'/v1/developer/apps/{app_id}/builds',headers=analyst,files={'file':('a.simapp',pack())}).status_code==403

def test_idempotent_upload_group_and_invitation():
    limits.clear()
    with TestClient(app) as c:
        dev=register(c,'idempotency@example.test')
        body={'name':'Notes','bundle_id':'com.retro.pixelnotes.idempotent'}
        h={**dev,'Idempotency-Key':'create-app'}
        a1=c.post('/v1/developer/apps',headers=h,json=body);a2=c.post('/v1/developer/apps',headers=h,json=body)
        assert a1.json()==a2.json()
        assert c.post('/v1/developer/apps',headers=h,json={**body,'name':'changed'}).status_code==409
        aid=a1.json()['id'];data=pack(bundle=body['bundle_id']);h={**dev,'Idempotency-Key':'upload'}
        b1=c.post(f'/v1/developer/apps/{aid}/builds',headers=h,files={'file':('notes.simapp',data)}).json()
        b2=c.post(f'/v1/developer/apps/{aid}/builds',headers=h,files={'file':('notes.simapp',data)}).json();assert b1==b2
        h={**dev,'Idempotency-Key':'group'};body={'build_id':b1['id']}
        g1=c.post('/v1/beta/groups',headers=h,json=body).json();g2=c.post('/v1/beta/groups',headers=h,json=body).json();assert g1==g2
        h={**dev,'Idempotency-Key':'invite'}
        i1=c.post(f'/v1/beta/groups/{g1["id"]}/invites',headers=h).json();i2=c.post(f'/v1/beta/groups/{g1["id"]}/invites',headers=h).json();assert i1==i2

def test_malformed_manifest_types_fail_closed():
    import pytest
    for manifest in [[],{'schemaVersion':1,'runtime':'web','id':5}, {'schemaVersion':1,'runtime':'web','id':'com.retro.notes','version':[]},None]:
        b=io.BytesIO()
        with zipfile.ZipFile(b,'w') as z:z.writestr('manifest.json',json.dumps(manifest));z.writestr('index.html','hi');z.writestr('assets/icon.png',b'\x89PNG\r\n\x1a\n')
        with pytest.raises(PackageError):validate(b.getvalue())

def test_async_worker_validates_and_quarantines():
    from services.api import database as db
    from services.api.blobs import blobs
    from services.api.worker import validate_upload
    from services.api.main import uid,now
    limits.clear()
    with TestClient(app) as c:
        dev=register(c,'worker@example.test')
        aid=c.post('/v1/developer/apps',headers=dev,json={'bundle_id':'com.retro.worker','name':'Worker Notes'}).json()['id']
        user_id=c.get('/v1/me',headers=dev).json()['id']
        upload_id=uid();blobs.put('quarantine/'+upload_id,pack(bundle='com.retro.worker'))
        with db.engine.begin() as conn:conn.execute(db.uploads.insert().values(id=upload_id,app_id=aid,user_id=user_id,status='validating',created=now()))
        validate_upload(upload_id)
        row=c.get(f'/v1/developer/apps/{aid}/uploads/{upload_id}',headers=dev).json()
        assert row['status']=='validated' and row['build_id']
        with db.engine.connect() as conn:b=db.one(conn,db.builds,db.builds.c.id==row['build_id'])
        assert hashlib.sha256(blobs.get('packages/'+b['id']+'.simapp')).hexdigest()==b['sha256']
        import pytest
        with pytest.raises(FileNotFoundError):blobs.get('quarantine/'+upload_id)
        bad=uid();blobs.put('quarantine/'+bad,b'bad zip')
        with db.engine.begin() as conn:conn.execute(db.uploads.insert().values(id=bad,app_id=aid,user_id=user_id,status='validating',created=now()))
        validate_upload(bad)
        assert c.get(f'/v1/developer/apps/{aid}/uploads/{bad}',headers=dev).json()['status']=='failed'

def test_admin_mfa_when_configured(monkeypatch):
    import hmac,struct,time
    from services.api.main import verify_totp
    secret='JBSWY3DPEHPK3PXP'
    monkeypatch.setenv('ADMIN_TOTP_SECRET',secret)
    raw=hmac.new(base64.b32decode(secret),struct.pack('>Q',int(time.time())//30),hashlib.sha1).digest();off=raw[-1]&15
    otp=f'{(struct.unpack(">I",raw[off:off+4])[0]&0x7fffffff)%1000000:06d}'
    assert verify_totp(secret,otp) and not verify_totp(secret,'bad')
    limits.clear()
    with TestClient(app) as c:
        body={'email':os.environ['ADMIN_EMAIL'],'password':os.environ['ADMIN_PASSWORD']}
        assert c.post('/v1/auth/login',json=body).json()['code']=='MFA_REQUIRED'
        assert c.post('/v1/auth/login',json={**body,'otp':otp}).status_code==200

def test_screenshot_feedback_is_private():
    from services.api import database as db
    from services.api.main import uid,now
    from services.api.blobs import blobs
    limits.clear()
    with TestClient(app) as c:
        dev=register(c,'screenshots@example.test');other=register(c,'screen-other@example.test')
        a=c.post('/v1/developer/apps',headers=dev,json={'name':'Screen Notes','bundle_id':'com.retro.pixelnotes.screen'}).json()['id']
        data=pack(bundle='com.retro.pixelnotes.screen')
        b=c.post(f'/v1/developer/apps/{a}/builds',headers=dev,files={'file':('s.simapp',data)}).json()
        g=c.post('/v1/beta/groups',headers=dev,json={'build_id':b['id']}).json()
        code=c.post(f'/v1/beta/groups/{g["id"]}/invites',headers=dev).json()['code'];c.post('/v1/beta/invites/redeem',headers=dev,json={'code':code})
        f=c.post('/v1/beta/feedback',headers=dev,json={'build_id':b['id'],'content':'显示正常','device':{'model':'iPhone'}}).json()
        png=(ROOT/'examples/pixel-notes/assets/icon.png').read_bytes()
        endpoint=f'/v1/beta/feedback/{f["id"]}/screenshot'
        assert c.post(endpoint,headers=dev,files={'file':('s.png',png)}).status_code==200
        assert c.get(endpoint,headers=dev).content==png
        assert c.get(endpoint,headers=other).status_code==403
        assert c.post(endpoint,headers=other,files={'file':('s.png',png)}).status_code==403
        assert c.post(endpoint,headers=dev,files={'file':('s.png',b'not-png')}).status_code==400

def test_body_limit_on_chunked_requests():
    limits.clear()
    with TestClient(app) as c:
        def chunks():
            yield b'{"email":"'
            for _ in range(22):yield b'a'*(1024*1024)
            yield b'","password":"long-password"}'
        r=c.post('/v1/auth/register',content=chunks(),headers={'Content-Type':'application/json'})
        assert r.status_code==413,r.text
