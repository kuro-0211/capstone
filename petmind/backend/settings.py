"""Local development defaults; secrets never enter stored observations."""
import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / '.env')


@dataclass(frozen=True)
class Settings:
    database_url: str = os.getenv('PETMIND_DATABASE_URL', f'sqlite:///{ROOT / "petmind.db"}')
    provider: str = os.getenv('PETMIND_LLM_PROVIDER', 'gemini' if os.getenv('GEMINI_API_KEY') else 'rule')
    retrieval_mode: str = os.getenv('PETMIND_RETRIEVAL_MODE', 'mcp')
    semantic_enabled: bool = os.getenv('PETMIND_SEMANTIC_SEARCH', 'off').lower() == 'on'
    gemini_api_key: str | None = os.getenv('GEMINI_API_KEY')
    gemini_model: str = os.getenv('PETMIND_GEMINI_MODEL', 'gemini-3.5-flash-lite')
    gemini_timeout_seconds: float = float(os.getenv('PETMIND_GEMINI_TIMEOUT_SECONDS', '12'))
    action_timeout_seconds: int = int(os.getenv('PETMIND_ACTION_TIMEOUT_SECONDS', '30'))


settings = Settings()
