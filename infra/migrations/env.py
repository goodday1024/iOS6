from alembic import context
from services.api.database import engine,meta
if context.is_offline_mode():
    with context.begin_transaction():
        context.configure(url=str(engine.url),target_metadata=meta,literal_binds=True);context.run_migrations()
else:
    with engine.connect() as conn:
        context.configure(connection=conn,target_metadata=meta,compare_type=True)
        with context.begin_transaction():context.run_migrations()
