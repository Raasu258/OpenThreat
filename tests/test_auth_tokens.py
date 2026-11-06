"""
JWT handling tests (PyJWT).
"""

from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi import HTTPException

from backend.utils import auth

CLAIMS = {"user_id": 1, "username": "u", "email": "u@mailbox.org", "role": "viewer"}


@pytest.mark.unit
def test_roundtrip():
    token = auth.create_access_token(CLAIMS)
    payload = auth.decode_access_token(token)
    assert payload["user_id"] == 1
    assert "exp" in payload and "iat" in payload


@pytest.mark.unit
def test_expired_token_rejected():
    token = auth.create_access_token(CLAIMS, expires_delta=timedelta(seconds=-1))
    with pytest.raises(HTTPException) as exc:
        auth.decode_access_token(token)
    assert exc.value.status_code == 401


@pytest.mark.unit
def test_wrong_key_rejected():
    now = datetime.now(timezone.utc)
    forged = jwt.encode(
        {**CLAIMS, "role": "admin", "exp": now + timedelta(hours=1), "iat": now},
        "attacker-key-attacker-key-attacker-key",
        algorithm="HS256",
    )
    with pytest.raises(HTTPException):
        auth.decode_access_token(forged)


@pytest.mark.unit
def test_alg_none_rejected():
    now = datetime.now(timezone.utc)
    unsigned = jwt.encode(
        {**CLAIMS, "exp": now + timedelta(hours=1), "iat": now}, None, algorithm="none"
    )
    with pytest.raises(HTTPException):
        auth.decode_access_token(unsigned)


@pytest.mark.unit
def test_missing_exp_rejected():
    token = jwt.encode(
        {**CLAIMS, "iat": datetime.now(timezone.utc)}, auth.SECRET_KEY, algorithm="HS256"
    )
    with pytest.raises(HTTPException):
        auth.decode_access_token(token)
