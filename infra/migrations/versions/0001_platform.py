"""Initial platform schema. Existing fresh local databases can be stamped 0001."""
from alembic import op
from services.api.database import meta
revision='0001'
down_revision=None
branch_labels=None
depends_on=None

def upgrade():meta.create_all(bind=op.get_bind())
def downgrade():meta.drop_all(bind=op.get_bind())
