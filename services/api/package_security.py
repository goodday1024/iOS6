import io, json, re, stat, zipfile, hashlib
from pathlib import PurePosixPath
MAX_ZIP = 20 * 1024 * 1024
MAX_TOTAL = 60 * 1024 * 1024
ALLOWED = {'.html','.css','.js','.json','.png','.jpg','.jpeg','.webp','.gif','.woff','.woff2','.txt','.mp3','.wav'}
class PackageError(ValueError): pass

def safe_path(name):
    if not isinstance(name,str): raise PackageError('路径须为字符串')
    p = PurePosixPath(name)
    raw = name.rstrip('/').split('/')
    if any(not part or part.startswith('.') for part in raw): raise PackageError('路径须使用规范相对路径')
    if not name or '\\' in name or '\x00' in name or ':' in name or p.is_absolute() or '..' in p.parts or name.startswith('.') or any(part.startswith('.') for part in p.parts):
        raise PackageError('非法文件路径')
    return p

def validate(data):
    if len(data) > MAX_ZIP: raise PackageError('压缩包超过 20 MiB')
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            entries = z.infolist()
            if not 1 <= len(entries) <= 1000: raise PackageError('文件数量超限')
            total, names = 0, set()
            for e in entries:
                p = safe_path(e.filename)
                if e.filename.casefold() in names: raise PackageError('重复或大小写冲突路径')
                names.add(e.filename.casefold())
                mode = e.external_attr >> 16
                if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))): raise PackageError('禁止链接或特殊文件')
                if e.flag_bits & 1: raise PackageError('禁止加密 ZIP')
                total += e.file_size
                if e.file_size > 10*1024*1024 or total > MAX_TOTAL or e.file_size/max(1,e.compress_size) > 200: raise PackageError('解压资源配额超限')
                if not e.is_dir() and p.suffix.lower() not in ALLOWED: raise PackageError('不支持的文件类型')
            if 'manifest.json' not in z.namelist(): raise PackageError('缺少 manifest.json')
            if z.getinfo('manifest.json').file_size > 16384: raise PackageError('manifest 过大')
            m = json.loads(z.read('manifest.json'))
            if not isinstance(m,dict): raise PackageError('manifest 须为对象')
            if set(m)-{'schemaVersion','id','name','version','runtime','entry','icon','permissions','orientation','minSimulatorVersion'}: raise PackageError('manifest 含未支持字段')
            if m.get('schemaVersion') != 1 or m.get('runtime') != 'web': raise PackageError('仅支持 schemaVersion=1 的 web 应用')
            if not re.fullmatch(r'[a-z][a-z0-9]*(?:\.[a-z][a-z0-9-]*){2,}', m.get('id','')): raise PackageError('非法 bundle id')
            if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)',m.get('version','')): raise PackageError('版本须为 x.y.z')
            if not isinstance(m.get('name'),str) or not 1 <= len(m['name']) <= 80: raise PackageError('非法应用名')
            if m.get('orientation','portrait') != 'portrait': raise PackageError('本版仅支持竖屏')
            permissions = m.get('permissions')
            if not isinstance(permissions,list) or any(p != 'storage' for p in permissions) or len(permissions) != len(set(permissions)): raise PackageError('不支持的权限')
            for field in ('entry','icon'):
                name = m.get(field,''); safe_path(name)
                if name not in z.namelist() or z.getinfo(name).is_dir(): raise PackageError('缺少入口或图标')
            if PurePosixPath(m['entry']).suffix != '.html' or PurePosixPath(m['icon']).suffix != '.png': raise PackageError('入口须为 HTML，图标须为 PNG')
            if not z.read(m['icon']).startswith(b'\x89PNG\r\n\x1a\n'): raise PackageError('图标内容无效')
            min_version = m.get('minSimulatorVersion','1.0.0')
            if not re.fullmatch(r'\d+\.\d+\.\d+', min_version) or tuple(map(int,min_version.split('.'))) > (1,0,0): raise PackageError('所需运行时版本不支持')
            for e in entries:
                if not e.is_dir(): z.read(e) # CRC verification; never extract untrusted uploads
            m['permissions'] = permissions
            return m, hashlib.sha256(data).hexdigest()
    except PackageError:
        raise
    except (zipfile.BadZipFile, KeyError, ValueError, TypeError, AttributeError, UnicodeError, RuntimeError, NotImplementedError) as e:
        raise PackageError('损坏或不完整的应用包') from e

def signed_payload(build):
    m = build['manifest']
    return json.dumps({'appId':build['app_id'],'buildId':build['id'],'bundleId':m['id'],'version':m['version'],'sha256':build['sha256'],'permissions':m['permissions']},sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
