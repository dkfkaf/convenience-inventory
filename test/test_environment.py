"""Check the MySQL connection before running database integration tests."""

import os
from contextlib import closing

import mysql.connector
import pytest
from mysql.connector import errorcode


def _required_env(name):
    value = os.getenv(name, "").strip()
    if not value:
        pytest.fail(f"{name} 환경 변수에 값을 설정하세요.", pytrace=False)
    return value


def _mysql_port():
    try:
        port = int(os.getenv("INVENTORY_DB_PORT", "3306"))
    except ValueError:
        port = 0
    if not 1 <= port <= 65535:
        pytest.fail("INVENTORY_DB_PORT에는 1~65535 범위의 정수가 필요합니다.", pytrace=False)
    return port


def test_mysql_84_uses_the_designated_test_schema():
    test_schema = _required_env("INVENTORY_TEST_DB_NAME")
    app_schema = os.getenv("INVENTORY_DB_NAME", "").strip()
    if test_schema.casefold() == app_schema.casefold():
        pytest.fail(
            "INVENTORY_TEST_DB_NAME에는 개발·시연용 INVENTORY_DB_NAME과 다른 스키마를 지정하세요.",
            pytrace=False,
        )

    user = _required_env("INVENTORY_DB_USER")
    port = _mysql_port()
    try:
        with closing(mysql.connector.connect(
            host=os.getenv("INVENTORY_DB_HOST", "127.0.0.1"),
            port=port,
            user=user,
            password=os.getenv("INVENTORY_DB_PASSWORD", ""),
            database=test_schema,
            connection_timeout=5,
        )) as connection, closing(connection.cursor()) as cursor:
            cursor.execute("SELECT DATABASE(), VERSION()")
            database, version = cursor.fetchone()
    except mysql.connector.Error as error:
        hints = {
            errorcode.ER_BAD_DB_ERROR: "INVENTORY_TEST_DB_NAME에 지정한 스키마가 서버에 있는지 확인하세요.",
            errorcode.ER_ACCESS_DENIED_ERROR: "INVENTORY_DB_USER와 INVENTORY_DB_PASSWORD를 확인하세요.",
            errorcode.ER_DBACCESS_DENIED_ERROR: "테스트 계정의 스키마 접근 권한을 확인하세요.",
            errorcode.CR_CONN_HOST_ERROR: "MySQL이 실행 중인지, 호스트와 포트가 맞는지 확인하세요.",
        }
        hint = hints.get(error.errno, "테스트 DB 연결 설정과 MySQL 서버 상태를 확인하세요.")
        pytest.fail(f"테스트 DB 확인 실패 (MySQL 오류 {error.errno}). {hint}", pytrace=False)

    assert database == test_schema, f"선택된 스키마는 {database!r}, 기대값은 {test_schema!r}입니다."
    assert version.startswith("8.4."), f"MySQL 8.4가 필요하지만 서버 버전은 {version!r}입니다."
