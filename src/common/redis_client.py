"""Shared Redis connection (feature queue + history ring + results)."""
import redis

from src.common import settings as S

_pool = None


def get_redis() -> redis.Redis:
    global _pool
    if _pool is None:
        _pool = redis.ConnectionPool.from_url(S.REDIS_URL, decode_responses=True)
    return redis.Redis(connection_pool=_pool)
