import os, json
from sqlalchemy import create_engine, MetaData, Table, Column, String, JSON, Float, Integer, UniqueConstraint, ForeignKey
from sqlalchemy.pool import StaticPool
url = os.getenv('DATABASE_URL','sqlite:///./data/platform.db')
if os.getenv('VERCEL') and not os.getenv('DATABASE_URL'):
    raise RuntimeError('DATABASE_URL must reference a persistent PostgreSQL database on Vercel')
if url.startswith('postgresql://'):
    url = url.replace('postgresql://','postgresql+psycopg://',1)
engine = create_engine(url,pool_pre_ping=True,**({'connect_args':{'check_same_thread':False}, **({'poolclass':StaticPool} if ':memory:' in url else {})} if url.startswith('sqlite') else {}))
meta=MetaData()
users=Table('users',meta,Column('id',String,primary_key=True),Column('email',String,unique=True,nullable=False),Column('password',String,nullable=False),Column('role',String,nullable=False),Column('created',Float))
sessions=Table('sessions',meta,Column('hash',String,primary_key=True),Column('user_id',String,ForeignKey('users.id')),Column('expires',Float))
teams=Table('teams',meta,Column('id',String,primary_key=True),Column('name',String),Column('owner_id',String,ForeignKey('users.id')))
members=Table('members',meta,Column('team_id',String,ForeignKey('teams.id'),primary_key=True),Column('user_id',String,ForeignKey('users.id'),primary_key=True),Column('role',String))
apps=Table('apps',meta,Column('id',String,primary_key=True),Column('bundle_id',String,unique=True),Column('team_id',String,ForeignKey('teams.id')),Column('name',String),Column('category',String),Column('description',String),Column('privacy',String),Column('created',Float))
builds=Table('builds',meta,Column('id',String,primary_key=True),Column('app_id',String,ForeignKey('apps.id')),Column('version',String),Column('sha256',String),Column('manifest',JSON),Column('validation',String),Column('created',Float),UniqueConstraint('app_id','version'))
reviews=Table('reviews',meta,Column('id',String,primary_key=True),Column('build_id',String,ForeignKey('builds.id'),unique=True),Column('status',String),Column('reason',String),Column('reviewer_id',String,ForeignKey('users.id')),Column('created',Float))
releases=Table('releases',meta,Column('app_id',String,ForeignKey('apps.id'),primary_key=True),Column('build_id',String,ForeignKey('builds.id')),Column('status',String),Column('notes',String),Column('created',Float))
groups=Table('beta_groups',meta,Column('id',String,primary_key=True),Column('app_id',String,ForeignKey('apps.id')),Column('build_id',String,ForeignKey('builds.id')),Column('name',String),Column('expires',Float))
invites=Table('beta_invites',meta,Column('hash',String,primary_key=True),Column('group_id',String,ForeignKey('beta_groups.id')),Column('expires',Float),Column('redeemed_by',String,ForeignKey('users.id')),Column('revoked',Integer,default=0))
beta_access=Table('beta_access',meta,Column('group_id',String,ForeignKey('beta_groups.id'),primary_key=True),Column('user_id',String,ForeignKey('users.id'),primary_key=True))
feedback=Table('feedback',meta,Column('id',String,primary_key=True),Column('user_id',String,ForeignKey('users.id')),Column('build_id',String,ForeignKey('builds.id')),Column('content',String),Column('device',JSON),Column('attachment_key',String),Column('created',Float))
ratings=Table('ratings',meta,Column('user_id',String,ForeignKey('users.id'),primary_key=True),Column('app_id',String,ForeignKey('apps.id'),primary_key=True),Column('stars',Integer),Column('text',String))
installs=Table('installations',meta,Column('user_id',String,ForeignKey('users.id'),primary_key=True),Column('app_id',String,ForeignKey('apps.id'),primary_key=True),Column('build_id',String,ForeignKey('builds.id')),Column('created',Float))
audit=Table('audit_logs',meta,Column('id',String,primary_key=True),Column('actor',String,ForeignKey('users.id')),Column('action',String),Column('target',String),Column('detail',String),Column('created',Float))
idempotency=Table('idempotency',meta,Column('user_id',String,ForeignKey('users.id'),primary_key=True),Column('key',String,primary_key=True),Column('request_hash',String),Column('response',JSON))

def one(conn,table,condition):
    r=conn.execute(table.select().where(condition)).mappings().first()
    return dict(r) if r else None

def many(conn,table,condition=None):
    q=table.select()
    if condition is not None:q=q.where(condition)
    return [dict(r) for r in conn.execute(q).mappings()]
uploads=Table('uploads',meta,Column('id',String,primary_key=True),Column('app_id',String,ForeignKey('apps.id')),Column('user_id',String,ForeignKey('users.id')),Column('status',String),Column('build_id',String,ForeignKey('builds.id')),Column('error',String),Column('created',Float))
