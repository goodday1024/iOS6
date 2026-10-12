"""RQ worker entry point. ZIP validation is isolated from the HTTP request process."""
import time
from . import database as db
from .blobs import blobs
from .package_security import validate, PackageError

def validate_upload(upload_id):
    from .main import uid, now, init, log
    init()
    # Queue visibility can precede database commit. Retry without deleting the quarantine object.
    for attempt in range(20):
        with db.engine.connect() as c:row=db.one(c,db.uploads,db.uploads.c.id==upload_id)
        if not row or row['status']=='uploaded':time.sleep(0.1);continue
        break
    if not row or row['status']=='uploaded':raise RuntimeError('Upload transaction is not visible yet')
    if row['status']!='validating':return
    try:
        with db.engine.connect() as c:a=db.one(c,db.apps,db.apps.c.id==row['app_id'])
        data=blobs.get('quarantine/'+upload_id);manifest,sha=validate(data)
        if manifest['id']!=a['bundle_id']:raise PackageError('包 ID 与应用不符')
        build={'id':uid(),'app_id':a['id'],'version':manifest['version'],'sha256':sha,'manifest':manifest,'validation':'validated','created':now()}
        immutable='packages/'+build['id']+'.simapp'
        blobs.put(immutable,data)
        try:
            with db.engine.begin() as c:
                current=c.execute(db.uploads.select().where(db.uploads.c.id==upload_id).with_for_update()).mappings().first()
                if current['status']!='validating':blobs.delete(immutable);return
                c.execute(db.builds.insert().values(**build))
                c.execute(db.uploads.update().where(db.uploads.c.id==upload_id).values(status='validated',build_id=build['id']))
                log(c,{'id':row['user_id']},'build.validated',build['id'],sha)
        except Exception:
            blobs.delete(immutable);raise
    except Exception as e:
        with db.engine.begin() as c:c.execute(db.uploads.update().where((db.uploads.c.id==upload_id)&(db.uploads.c.status=='validating')).values(status='failed',error=str(e)[:500] if isinstance(e,PackageError) else '构建校验失败，版本可能已存在或存储不可用'))
    finally:
        blobs.delete('quarantine/'+upload_id)
