# 구현 계획 — 편의점 단일 점포의 재고 손실 예측 및 프로모션 의사결정 지원

| 항목 | 내용 |
| --- | --- |
| Spec Kit 기능 | `001-convenience-store-inventory-risk` |
| 계획일 | 2026-11-18 |
| 근거 | [요구사항 명세](spec.md) · [설계 결정](backend/research.md) |

## Summary

점포 관리자가 상품과 재고로트를 등록하고, 판매와 폐기를 기록하며, 예상 폐기량과 정상 판매·1+1·2+1의 개당 이익을 조회하는 로컬 웹 앱을 구현한다. 로트 잔량과 변동이력을 한 트랜잭션에 반영하고, 위험과 행사 비교는 조회 시 계산한다.

## Technical Context

| 항목 | 계획 |
| --- | --- |
| 백엔드 | Python 3.12, Flask 3.1 계열, `mysql-connector-python`, `tzdata` |
| 데이터 저장 | MySQL 8.4 LTS, InnoDB, `utf8mb4`, 외래 키와 `CHECK` 제약. 연결 설정은 `INVENTORY_DB_*` 환경변수로 전달 |
| 프론트엔드 | 기술 스택 미정. 팀이 T002에서 화면 기술, 코드 경로, Flask 연동 방식과 실행 방법을 정한다. 한국어 브라우저 화면으로 시연한다. |
| 테스트 | `pytest`를 `test/requirements-dev.txt`에서 설치한다. 개발·시연과 분리된 MySQL 테스트 스키마와 고정 가능한 점포 시계를 사용한다. 로컬과 GitHub Actions의 실행 명령은 `python -m pytest -v test`다. 화면 연동 검수는 T002에서 확정한 계약을 사용한다. |
| 동시 처리 | 한 점포 관리자 기준. 두 연결의 동시 차감·중복 제출을 검수하며, 재고와 이력을 쓰는 트랜잭션을 짧게 유지 |
| 조회 성능 | 상품·날짜 인덱스로 최근 7일 판매와 로트 조회를 제한한다. 상품별 예측은 로트 정렬 후 한 번 순회한다. |
| 날짜 및 수치 | 점포 시간대 기본값 `Asia/Seoul`, 현지 업무일과 UTC 기록 시각 사용. 원화 가격은 정수, 예측과 이익 비교는 정확한 분수로 계산 |
| 실행 범위 | 단일 점포의 로컬 브라우저 시연. Flask 개발 서버는 루프백에 바인딩한다. 화면의 요청 보호 방식과 로컬 실행 구성은 T002에서 확정한다. |

## Constitution Check

| 시점 | 판정 | 근거 |
| --- | --- | --- |
| Phase 0 전 | 명세 기준으로 통과 | 설치된 `.specify/memory/constitution.md`는 Spec Kit 기본 템플릿 상태다. 업무 범위와 세 가지 확정 기준을 명세에서 가져왔다. |
| Phase 1 후 | 업무 명세 충족 | [데이터 모델](db/data-model.md), [화면 계약](front-end/contracts/ui.md), [검수 가이드](test/quickstart.md)가 21개 기능 요구사항과 5개 성공 기준을 연결한다. 프론트엔드 기술과 연동 상세는 팀 합의 작업 T002에서 구체화한다. |

## Project Structure

### 설계 문서

**설계 근거** [research.md](backend/research.md) · **ERD와 스키마** [data-model.md](db/data-model.md) · **화면 계약** [contracts/ui.md](front-end/contracts/ui.md) · **검수 가이드** [quickstart.md](test/quickstart.md)

### 구현 시 사용할 경로

```text
db/
├── data-model.md        # ERD, 테이블과 제약
└── schema.sql           # MySQL 초기화 SQL
front-end/
└── contracts/
    └── ui.md            # 화면과 Flask 연동 계약
backend/
├── research.md          # 설계 결정과 검수 방식
├── requirements.txt     # Flask, MySQL 드라이버, tzdata
└── inventory_app/
    ├── __init__.py      # 앱 팩터리, 설정, 시간 공급자
    ├── db.py            # DB 연결, 트랜잭션, 초기화
    ├── inventory.py     # 상품·로트·판매·폐기·이력
    ├── risk.py          # 판매일 확인, 수요와 폐기 위험
    ├── promotions.py    # 후보 선정, 수익성 계산
    ├── routes.py        # 화면 조회와 폼 처리
    └── demo.py          # 시연 데이터 명령
test/
├── quickstart.md        # 실행과 검수 가이드
├── checklists/          # 요구사항 점검
├── fixtures/            # 위험·프로모션·폐기 테스트 데이터
├── requirements-dev.txt
├── conftest.py          # pytest 공통 픽스처
├── helpers.py           # 테스트 데이터 생성
├── test_environment.py
├── test_inventory.py
├── test_risk.py
├── test_promotions.py
└── test_web.py
```

화면 소스는 `front-end/`에 두고, 그 안의 경로와 실행 명령은 팀이 [화면 계약](front-end/contracts/ui.md#팀-결정과-화면별-소스-경로)에 기록한다. 화면에서 시작한 재고 변경은 `inventory.py`를 통과한다. `risk.py`는 커밋된 판매와 재고를 조회하고, `promotions.py`는 위험 결과와 상품 가격·원가를 사용한다. Flask는 저장소 루트에서 `backend.inventory_app`을 앱 경로로 사용하고 초기화 SQL은 `db/schema.sql`에서 읽는다. SQL 제약과 업무 규칙은 [데이터 모델](db/data-model.md)을 기준으로 구현한다.

## 구현 순서와 검수 기준

| 순서 | 작업 단위 | 근거 | 완료 확인 |
| --- | --- | --- | --- |
| 1 | Flask 설정, MySQL 연결과 6개 테이블, 테스트 기반을 준비하고 프론트엔드 기술을 팀에서 조율 | 전체 업무 공통 | 별도 스키마에서 초기화·외래 키·수량 제약을 확인한다. T002에서 화면 기술과 연동 방법을 기록한다. |
| 2 | 상품·로트 등록과 조회, 판매 및 로트별 차감 조회 | FR-INV-01~05, FR-WST-02~03 | S1-1~S1-3. 판매 가능 수량 부족, 동일 판매 재전송, 두 판매의 동시 차감 검증. |
| 3 | 폐기 처리, 변동 이력과 폐기 손실 | FR-WST-01~04 | S4-1~S4-3. 판매와 폐기 동시 요청, 이력 쓰기 오류 시 롤백 검증. |
| 4 | 날짜별 판매기록 확인, 수요 예측, 위험 조회 | FR-RSK-01~07 | S2-1~S2-5. 날짜 7일 범위, 자정 전환, 임박 3일·4일 경계와 중복 수요 배정 검증. |
| 5 | 프로모션 후보와 비교 화면 | FR-PRO-01~05 | S3-1~S3-4. 현재 판매가·매입원가 사용, 50% 경계 및 판매 가능 수량 조건 검증. |
| 6 | 전체 시연과 결과 대조 | SC-01~05 | 동일한 가상 데이터로 화면 결과와 DB 잔량·이력을 교차 확인. |

## 전환 기준

- 판매·폐기·로트 등록은 MySQL 트랜잭션에서 같은 상품의 행을 먼저 잠근 뒤 잔량과 기록을 함께 갱신한다. 두 MySQL 연결로 검증한 뒤 시연 데이터에 연결한다.
- 폐기 위험 계산은 판매기록 미확인, 관찰 기간 부족, 실제 판매 0을 구분한다. 행사는 재고 위험과 수익성 정보로 검토를 지원한다.
- 명세에서 제외한 다점포, 발주·출고·이동, 행사 적용·결제, POS 연동과 판매 증가 예측은 앱 구현 범위에서 제외한다.
- 백엔드와 DB 테스트 준비는 팀의 프론트엔드 결정과 병렬로 진행할 수 있다. 화면 구현과 Flask 연동 검수는 T002 이후 진행한다. 실행 절차와 별도 MySQL 스키마는 [검수 가이드](test/quickstart.md)를 따른다.
