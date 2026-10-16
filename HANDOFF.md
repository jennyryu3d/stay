# 남위례 햇살집 (stay)

- 단일 파일 앱: `index.html` (빌드 없음). 원본 작업본은 Claude 세션의 src/app.html → build.py 로 생성.
- 서버: Supabase **Linkvault** 프로젝트(gdjxgdwhjynmszxvlbsr)에 `stay_` 테이블로 같이 들어 있음. 설정 SQL은 `setup.sql`.
- 호스트 = 앱에서 가장 먼저 만든 계정 (stay_admins).
- 출입 비밀번호는 기본 카톡 전달 (stay_secret.show_in_app=false).
- 예약: 신청은 날짜를 잠그지 않음(대기 순번). 확정/호스트 사용만 겹침 금지.
- 백업: stay_backups 테이블, 매일 03:00 KST pg_cron, 30일 보관 + 앱에서 파일 받기.
