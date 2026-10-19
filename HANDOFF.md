# 남위례 햇살집 (stay)

- 단일 파일 앱: `index.html` (빌드 없음). 원본 작업본은 Claude 세션의 src/app.html → build.py 로 생성.
- 서버: Supabase **Linkvault** 프로젝트(gdjxgdwhjynmszxvlbsr)에 `stay_` 테이블로 같이 들어 있음. 설정 SQL은 `setup.sql`.
- 호스트 = 앱에서 가장 먼저 만든 계정 (stay_admins).
- 출입 비밀번호는 기본 카톡 전달 (stay_secret.show_in_app=false).
- 예약: 신청은 날짜를 잠그지 않음(대기 순번). 확정/호스트 사용만 겹침 금지.
- 앞 순위가 확정돼도 겹치는 신청은 자동 마감하지 않고 "확정 후 대기"로 남음. 손님은 [계속 기다리기](wait_choice=wait) 또는 [취소하고 다른 날짜]를 고름. 앞 예약이 취소되면 자동으로 1순위. (v2.15.0)
- 백업: stay_backups 테이블, 매일 03:00 KST pg_cron, 30일 보관 + 앱에서 파일 받기.
- 사진: photos/ 폴더 + index.html의 PHOTO_GROUPS(집 안 / 창밖 풍경 / 건물 · 역). 첫 화면 큰 사진은 HERO_PHOTO. 호스트가 앱에서 올린 사진은 "집 안" 뒤에 붙음. (v2.19.0)
