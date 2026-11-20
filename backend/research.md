# 설계 결정 — 단일 편의점 재고 위험 및 프로모션 비교

2026-11-18 · [확정 명세](../spec.md)

## 1. 백엔드와 DB

- **결정** — 팀 결정에 따라 Python 3.12·Flask 3.1 계열과 MySQL을 사용한다. 설계 기준은 MySQL 8.4 LTS의 InnoDB이며 Python에서는 공식 `mysql-connector-python`을 사용한다.
- **근거** — Flask에서 업무 서비스와 화면 연동을 나눌 수 있다. 개발자별 MySQL 스키마와 CI 서비스 DB에서 같은 SQL 제약과 동시 차감 방식을 검증한다. [MySQL Connector/Python 호환 버전](https://dev.mysql.com/doc/connectors/en/connector-python-versions.html) · [MySQL 연결 설정](https://dev.mysql.com/doc/connector-python/en/connector-python-connectargs.html)

## 2. 재고 차감과 요청 재전송

- **결정** — 변경 작업은 Connector/Python에서 `READ COMMITTED` 트랜잭션으로 시작한다. 로트 등록·판매·폐기는 같은 상품의 행을 `SELECT ... FOR UPDATE`로 먼저 잠그고 잔량을 검사한다. 재고·원인 기록·변동이력을 한 번에 커밋하고 실패하면 롤백한다.
- **근거** — 같은 상품에 대한 판매·폐기 요청이 동시에 남은 수량을 차감하는 것을 방지한다. DB 유일 제약, 수량 조건을 건 갱신과 요청 키 검사를 조합한다. 초기화 DDL은 업무 트랜잭션 밖에서 실행한다. [MySQL 잠금 읽기](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html) · [Connector/Python 트랜잭션 시작](https://dev.mysql.com/doc/connector-python/en/connector-python-api-mysqlconnection-start-transaction.html)
- **검토한 대안** — 변동이력만 저장하고 매번 합산하면 잔량 중복은 줄지만 조회와 차감이 복잡해진다. 현재 설계는 잔량과 변동이력을 함께 기록하고 검수에서 합계를 대조한다.

## 3. 점포 날짜와 판매기록 완전성

- **결정** — `ZoneInfo("Asia/Seoul")`를 기본 점포 시간대로 쓰고 `tzdata`를 의존성에 포함한다. 날짜는 점포 현지 날짜, 기록 시각은 UTC로 관리한다. 최근 7일은 현지 조회일을 제외한 직전 7개 달력일이다. 날짜별 판매기록 확인은 점포 단위로 저장한다.
- **근거** — 날짜 확인이 있어야 상품 판매건 0건을 판매량 0으로 해석할 수 있다. 소비기한 다음 날 0시에는 기한 상태와 판매 가능 수량만 바뀐다. UTC 기록 시각과 현지 업무일은 각각 조회 목적에 사용한다. [Python zoneinfo 데이터 소스](https://docs.python.org/3.12/library/zoneinfo.html#data-sources)
- **검토한 대안** — 날짜마다 모든 상품의 0개 판매 행을 생성하면 기록 누락과 실제 0을 분리할 수 있으나 상품 수만큼 불필요한 입력이 추가된다. 날짜 확인 테이블은 실제 판매가 들어온 날도 확인 전까지 미확인으로 표시할 수 있다.

## 4. 로트별 예측과 금액 계산

- **결정** — 일평균은 확인된 7일 합계 ÷ 7이다. 소비기한이 빠른 로트부터 기한까지의 누적 수요를 계산하고, 앞선 로트에 배정된 수량을 뺀 뒤 해당 잔량 범위 안에서 배정한다. 이익과 예상량은 `Fraction`으로 계산하고 화면에 표시할 때만 반올림한다.
- **근거** — 같은 상품의 수요는 상품 전체에 한 번 배정된다. 현재 모든 로트가 이미 보유 중이므로 각 기한까지의 수요 상한에서 앞선 배정을 차감할 수 있다. 현재 검수 예시의 예상 판매는 3개·6개이며, 무작위 10,000개 예측 사례를 일별 배정 결과와 비교해 같은 결과를 확인했다. 이 방식은 50% 경계와 예상 미판매가 정확히 0인 경우도 정확히 판단한다. [Python fractions](https://docs.python.org/3.12/library/fractions.html)
- **검토한 대안** — 날짜별 반복 배정도 동일한 정책을 구현할 수 있으므로 소형 검수 사례의 비교 기준으로 적합하다. 누적 방식은 기한까지의 날짜 수와 별개로 정렬된 로트를 한 번씩 순회한다.

## 5. 프론트엔드 팀 합의와 검수 환경

- **결정** — 프론트엔드는 React·Tailwind CSS·Vite로 확정했다. 팀이 T002에서 화면 소스 경로, 실행·빌드 명령과 Flask 연동 방식을 정하고 [화면 계약](../front-end/contracts/ui.md#팀-결정과-화면별-소스-경로)에 기록한다. 화면이 제공할 업무 결과와 입력은 해당 계약을 기준으로 한다.
- **근거** — 백엔드 담당은 프론트엔드의 실행·연동 방식 합의와 병렬로 Flask·MySQL 기반을 구축할 수 있고, 테스트 담당은 실제 MySQL에서 제약·차감·동시성을 준비할 수 있다. 화면 연동 검수는 기술과 전달 방식 합의 이후 확정한다.
- **검수 환경** — 개발과 시연·테스트에 서로 다른 MySQL 스키마를 사용한다. GitHub Actions의 Linux 러너에서 테스트용 MySQL 서비스 컨테이너를 실행하고, 별도 스키마에서 `python -m pytest -v test`를 실행한다. Flask 클라이언트와 MySQL 테스트 데이터는 pytest 픽스처로 재사용한다. [GitHub Actions 서비스 컨테이너](https://docs.github.com/en/actions/tutorials/use-containerized-services/use-docker-service-containers)
