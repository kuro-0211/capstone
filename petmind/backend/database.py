"""SQLite observation, suggestion and command persistence, adapted from legacy backend."""
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, create_engine, event
from sqlalchemy.orm import declarative_base, sessionmaker
from sqlalchemy.pool import StaticPool

from .settings import settings


def utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)


kwargs = {'connect_args': {'check_same_thread': False}} if settings.database_url.startswith('sqlite') else {}
if settings.database_url in {'sqlite://', 'sqlite:///:memory:'}:
    kwargs['poolclass'] = StaticPool
engine = create_engine(settings.database_url, **kwargs)
if settings.database_url.startswith('sqlite'):
    @event.listens_for(engine, 'connect')
    def _enable_foreign_keys(connection, _record):
        connection.execute('PRAGMA foreign_keys=ON')

SessionLocal = sessionmaker(bind=engine)
Base = declarative_base()


class ObservationLog(Base):
    __tablename__ = 'observations'
    id = Column(Integer, primary_key=True)
    pet_id = Column(String, nullable=False, index=True)
    session_id = Column(String, nullable=False, index=True)
    observed_at = Column(DateTime, nullable=False, index=True)
    source = Column(String, nullable=False)
    context_json = Column(Text, nullable=False)
    summary = Column(Text, nullable=False)
    created_at = Column(DateTime, default=utcnow)
    __table_args__ = (UniqueConstraint('pet_id', 'session_id', 'observed_at', name='observation_identity'),)


class PetProfileLog(Base):
    __tablename__ = 'pet_profiles'
    pet_id = Column(String, primary_key=True)
    profile_json = Column(Text, nullable=False)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)


class CareSuggestionLog(Base):
    __tablename__ = 'care_suggestions'
    id = Column(Integer, primary_key=True)
    observation_id = Column(Integer, ForeignKey('observations.id'), nullable=False)
    pet_id = Column(String, nullable=False, index=True)
    state = Column(String, nullable=False)
    summary = Column(Text, nullable=False)
    reasons_json = Column(Text, nullable=False, default='[]')
    recommended_actions_json = Column(Text, nullable=False, default='[]')
    music_style = Column(String)
    severity = Column(String, nullable=False, default='info')
    status = Column(String, nullable=False, default='pending')
    provider = Column(String, nullable=False)
    context_json = Column(Text, nullable=False)
    retrieval_json = Column(Text, nullable=False)
    cited_ids_json = Column(Text, nullable=False, default='[]')
    question = Column(Text, nullable=False)
    created_at = Column(DateTime, default=utcnow, index=True)


class CareActionLog(Base):
    __tablename__ = 'care_actions'
    id = Column(Integer, primary_key=True)
    suggestion_id = Column(Integer, ForeignKey('care_suggestions.id'), nullable=False, unique=True)
    command_id = Column(String, nullable=False, unique=True, index=True)
    action_type = Column(String, nullable=False, default='music')
    status = Column(String, nullable=False, default='requested')
    request_json = Column(Text, nullable=False)
    result_json = Column(Text)
    error = Column(Text)
    created_at = Column(DateTime, default=utcnow)
    updated_at = Column(DateTime, default=utcnow, onupdate=utcnow)


class FeedbackLog(Base):
    __tablename__ = 'guardian_feedback'
    id = Column(Integer, primary_key=True)
    observation_id = Column(Integer, ForeignKey('observations.id'), nullable=False, index=True)
    suggestion_id = Column(Integer, ForeignKey('care_suggestions.id'))
    feedback_json = Column(Text, nullable=False)
    created_at = Column(DateTime, default=utcnow)


def init_db():
    Base.metadata.create_all(engine)


def get_db():
    with SessionLocal() as db:
        yield db
