#!/usr/bin/env bash
# =============================================================================
#  mycloud-deploy.sh — ЕДИНЫЙ САМОДОСТАТОЧНЫЙ установщик (обезличенный стек)
#  Один файл: 16 шаблонов зашиты внутрь (base64). Кидаешь на VPS и:
#      sudo bash mycloud-deploy.sh
#  Спросит данные по SSH -> deploy.conf, распакует шаблоны, отрендерит твоими
#  значениями и развернёт по фазам, с паузами на ручные шаги панели.
#  Подкоманды: wizard | config | render <имя> | run <фаза|all> | extract <каталог> | probe [хост…]
# =============================================================================
set -euo pipefail
# --- пре-парсер: вытащить --from <этап> ДО основного диспетчера (он знает только run/wizard/…) ---
FROM_STAGE=""
__ARGV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)   FROM_STAGE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --from=*) FROM_STAGE="${1#--from=}"; shift ;;
    *)        __ARGV+=("$1"); shift ;;
  esac
done
set -- "${__ARGV[@]+"${__ARGV[@]}"}"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "$PWD")"
CONF="${MYCLOUD_CONF:-$HERE/deploy.conf}"
# ре-деплой существующего бокса: если conf рядом нет — берём сохранённый при прошлом деплое
if [ ! -f "$CONF" ]; then
  for __c in /opt/*/.deploy/deploy.conf; do [ -f "$__c" ] && { CONF="$__c"; break; }; done
fi
TPL_DIR=""
VARS=(ROLE BRAND SLUG MAIN_DOMAIN RELAY_DOMAIN EXIT_IP RELAY_IP EXIT_NAME RELAY_NAME ACME_EMAIL USE_TAILSCALE SSH_PORT HARDEN GEO_BLOCK PQ TEST_SUB_UUID WDTT_PASS ADMIN_PASS AUTO_RELAY ACME_STAGING)
PH=(MAIN_DOMAIN RELAY_DOMAIN EXIT_IP RELAY_IP BRAND SLUG EXIT_NAME RELAY_NAME ACME_EMAIL SSH_PORT GEO_BLOCK PQ HARDEN TEST_SUB_UUID ACME_STAGING_LINE)
ASSUME_YES=0
if [ "${1:-}" = -y ] || [ "${1:-}" = --yes ]; then ASSUME_YES=1; shift || true; fi

c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }
say(){ echo "$(c '1;36' '»') $*"; }
pause(){ echo; echo "$(c '1;33' '⏸  РУЧНОЙ ШАГ:')"; echo "$*" | sed 's/^/    /'; read -rp "    Enter когда готово… " _ || true; }
die(){ echo "$(c '1;31' '✗') $*" >&2; exit 1; }

ensure_templates(){
  [ -n "$TPL_DIR" ] && [ -d "$TPL_DIR" ] && return 0
  TPL_DIR="$(mktemp -d /tmp/aldtpl.XXXXXX)"
  trap 'rm -rf "$TPL_DIR"' EXIT
  __extract_blobs "$TPL_DIR"
}

do_probe(){ ensure_templates; python3 "$TPL_DIR/vpn-probe.py" "$@"; }
do_update(){
  load
  local B="/opt/$SLUG" ts bdir d hc
  say "Обновление компонентов в $B (роль: $ROLE)"
  if [ -d "$B/panel" ]; then
    ts=$(date +%Y%m%d-%H%M%S); bdir="$B/backups/$ts"; mkdir -p "$bdir"
    [ -f "$B/panel/.env" ] && cp "$B/panel/.env" "$bdir/panel.env"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnawave-db$'; then
      docker exec remnawave-db sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' > "$bdir/pg.sql" 2>/dev/null && say "Бэкап БД: $bdir/pg.sql" || say "! дамп БД не снят — проверь имя контейнера"
    fi
    say "Бэкап панели: $bdir"
  fi
  for d in panel sub caddy node decoy; do
    [ -f "$B/$d/docker-compose.yml" ] || continue
    say "обновляю: $d"; ( cd "$B/$d" && docker compose pull && docker compose up -d ) || say "! $d: ошибка обновления"
  done
  docker restart "$SLUG-caddy" >/dev/null 2>&1 && say "Caddy перезапущен" || true
  ensure_templates; hc=$(mktemp); render health-check.sh > "$hc" 2>/dev/null && bash "$hc" || true; rm -f "$hc"
  do_probe "$MAIN_DOMAIN" "$RELAY_DOMAIN"
  say "Если панель обновлялась — проверь: профиль привязан, Response Rule Happ->XRAY_JSON на месте, .env SUB_PUBLIC_DOMAIN цел."
}

do_info(){
  load 2>/dev/null || { die "Нет конфига — деплой ещё не делался"; }
  local B="/opt/$SLUG"
  local CRED="$B/credentials.txt" SUMMARY="$B/summary.txt"
  local sub_uuid="${TEST_SUB_UUID:-}" admin_pass wdtt_pass api_pass
  admin_pass="$(grep -E '^\s*pass:' "$CRED" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  wdtt_pass="$(grep -E '^\s*wdtt-password:' "$CRED" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  # tailscale-адрес панели, если есть
  local ts_url=""
  if command -v tailscale >/dev/null 2>&1; then
    local th; th="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
    [ -n "$th" ] && ts_url="https://$th:8444"
  fi
  {
    echo "════════════════════════════════════════════════════════════"
    echo "  $BRAND — сводка развёртывания ($(date '+%Y-%m-%d %H:%M'))"
    echo "════════════════════════════════════════════════════════════"
    echo
    echo "── Серверы ──"
    echo "  Выход ($EXIT_NAME):  $MAIN_DOMAIN  ($EXIT_IP)"
    [ -n "${RELAY_IP:-}" ] && echo "  Релей ($RELAY_NAME):  $RELAY_DOMAIN  ($RELAY_IP)"
    echo
    echo "── Подписка / клиент ──"
    if [ -n "$sub_uuid" ]; then
      echo "  Подписка:  https://$MAIN_DOMAIN/api/sub/$sub_uuid"
      echo "  Страница:  https://$MAIN_DOMAIN/c/$sub_uuid/"
      echo "  (импортируй ссылку подписки в Shadowrocket/Happ/v2RayTun)"
    fi
    # попытка получить список пользователей через Remnawave API
    local _token="" _users=""
    if [ -n "$admin_pass" ]; then
      _token="$(curl -sf --max-time 4 -X POST http://127.0.0.1:3000/api/auth/login \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"$admin_pass\"}" 2>/dev/null \
        | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("response",{}).get("accessToken",""))' 2>/dev/null || true)"
    fi
    if [ -n "$_token" ] && [ -n "$MAIN_DOMAIN" ]; then
      _users="$(curl -sf --max-time 4 -H "Authorization: Bearer $_token" \
        http://127.0.0.1:3000/api/users 2>/dev/null \
        | MAIN_DOMAIN="$MAIN_DOMAIN" python3 -c '
import sys,json,os
d=json.load(sys.stdin)
us=d.get("response",{}).get("users",d.get("users",[]))
md=os.environ.get("MAIN_DOMAIN","")
for u in us:
    uid=u.get("shortUuid",""); name=u.get("username",u.get("name","?"))
    exp=u.get("expireAt","") or ""
    exp=exp[:10] if exp else "∞"
    if uid: print(f"  {name} (до {exp}):  https://{md}/api/sub/{uid}")
' 2>/dev/null || true)"
      if [ -n "$_users" ]; then
        echo "── Пользователи (активные подписки) ──"
        echo "$_users"
      fi
    fi
    [ -z "$sub_uuid" ] && [ -z "$_users" ] && echo "  shortUuid не задан — создай пользователя в панели"
    echo
    echo "── Доступ к панели (не публична) ──"
    [ -n "$ts_url" ] && echo "  Tailscale:  $ts_url"
    echo "  SSH-туннель: ssh -L 8081:127.0.0.1:8081 root@$EXIT_IP  →  https://localhost:8081"
    echo "  Логин:  admin  /  ${admin_pass:-<см. $CRED>}"
    echo
    echo "── WDTT (мобильный TURN-канал) ──"
    echo "  Сервер:  $EXIT_IP   DTLS: 56000/udp · WG: 56001/udp"
    echo "  Пароль:  ${wdtt_pass:-<см. $CRED>}"
    echo "  iOS:  github.com/anton48/vk-turn-proxy-ios → режим SRTP-WRAP-A"
    if [ -n "$wdtt_pass" ] && [ -n "$EXIT_IP" ]; then
      if command -v qrencode >/dev/null 2>&1; then
        echo "  QR (пароль для приложения):"
        qrencode -t ANSIUTF8 -m 1 "$wdtt_pass" 2>/dev/null || true
      else
        echo "  (установи qrencode для QR-кода: apt-get install -y qrencode)"
      fi
    fi
    echo
    echo "── Файлы ──"
    echo "  Доступы:  $CRED"
    echo "  Эта сводка:  $SUMMARY"
    echo "  Повторный вывод:  bash $0 info"
    echo "════════════════════════════════════════════════════════════"
  } | tee "$SUMMARY" 2>/dev/null
  chmod 600 "$SUMMARY" 2>/dev/null || true
}

do_reset(){
  load 2>/dev/null || true
  say "СБРОС VPN-стека${SLUG:+ (slug: $SLUG)}: удалю контейнеры, тома и /opt/$SLUG. НЕОБРАТИМО."
  local a; read -rp "  Подтвердите словом YES: " a || true
  [ "$a" = "YES" ] || { say "Отменено."; return 0; }
  say "После сброса сервер получит новый SSH-ключ. На своём ПК выполни:"
  say "  ssh-keygen -R ${EXIT_IP:-<IP сервера>}"
  [ -f "$CONF" ] && cp -f "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  for s in panel sub caddy node decoy; do
    [ -f "/opt/$SLUG/$s/docker-compose.yml" ] && ( cd "/opt/$SLUG/$s" && docker compose down -v >/dev/null 2>&1 ) || true
  done
  docker rm -f remnawave remnawave-db remnawave-redis remnawave-subscription-page remnanode >/dev/null 2>&1 || true
  # любые остатки *-caddy/-decoy (в т.ч. от других slug — host-network, дерутся за порты)
  local c; for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E -- '-(caddy|decoy|decoy-php)$' || true); do
    docker rm -f "$c" >/dev/null 2>&1 && say "убрал контейнер: $c" || true
  done
  docker network rm remnawave-network >/dev/null 2>&1 || true
  rm -rf "/opt/$SLUG" || true; rm -f "$CONF" || true
  say "Готово. Контейнеры сейчас:"; docker ps --format '  {{.Names}}' 2>/dev/null || true
  say "Дальше чистый деплой: запусти $0 → визард → пункт 1."
}

do_restore(){
  local explicit_arc="${1:-}"
  local arc=""

  if [ -n "$explicit_arc" ]; then
    # Путь к архиву передан явно (свежий сервер)
    [ -f "$explicit_arc" ] || { say "Файл не найден: $explicit_arc"; return 1; }
    arc="$explicit_arc"
  else
    # Ищем архивы в стандартном месте
    load 2>/dev/null || true
    local B_tmp="/opt/${SLUG:-}"
    local arcs=()
    while IFS= read -r f; do arcs+=("$f"); done < <(ls -t "$B_tmp/backups/"*.tar.gz 2>/dev/null || true)
    if [ "${#arcs[@]}" -eq 0 ]; then
      say "Нет архивов бэкапа в $B_tmp/backups/"
      say "Можно указать путь явно: bash $0 restore /path/to/backup.tar.gz"
      return 1
    fi
    say "Доступные бэкапы:"
    local i=1
    for f in "${arcs[@]}"; do
      printf '  %d) %s (%s)\n' "$i" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
      (( i++ )) || true
    done
    local ch; read -rp "  Выбери номер [1]: " ch || true
    ch="${ch:-1}"
    arc="${arcs[$((ch-1))]}"
    if [ ! -f "$arc" ]; then
      say "Неверный выбор: $ch — введи число от 1 до ${#arcs[@]}"
      return 1
    fi
  fi

  say "Восстанавливаю из: $arc"
  local tmp; tmp="$(mktemp -d)"
  tar -xzf "$arc" -C "$tmp" || { say "Не удалось распаковать архив"; rm -rf "$tmp"; return 1; }

  # Читаем SLUG из бэкапа если ещё не известен (свежий сервер без deploy.conf)
  if [ -z "${SLUG:-}" ] && [ -f "$tmp/deploy.conf" ]; then
    SLUG="$(grep '^SLUG=' "$tmp/deploy.conf" | cut -d= -f2- | tr -d "'\"")" || true
    say "  SLUG из архива: $SLUG"
  fi
  local B="/opt/$SLUG"

  # deploy.conf
  if [ -f "$tmp/deploy.conf" ]; then
    cp "$tmp/deploy.conf" "$CONF"
    say "  deploy.conf → $CONF"
    set -a; . "$CONF"; set +a
  fi

  # .env компонентов
  for comp in panel sub caddy node decoy; do
    if [ -f "$tmp/$comp.env" ]; then
      mkdir -p "$B/$comp"
      cp "$tmp/$comp.env" "$B/$comp/.env"
      say "  $comp.env → $B/$comp/.env"
    fi
  done

  # credentials.txt
  if [ -f "$tmp/credentials.txt" ]; then
    cp "$tmp/credentials.txt" "$B/credentials.txt"
    chmod 600 "$B/credentials.txt"
    say "  credentials.txt"
  fi

  # PostgreSQL
  if [ -f "$tmp/pg.sql" ]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnawave-db$'; then
      local ok; read -rp "  Восстановить БД из pg.sql? Текущие данные будут перезаписаны (yes/no) [no]: " ok || true
      if [ "${ok:-no}" = yes ]; then
        docker exec -i remnawave-db psql -U "${POSTGRES_USER:-postgres}" < "$tmp/pg.sql" >/dev/null 2>&1 \
          && say "  БД восстановлена" \
          || say "  ! ошибка восстановления БД — проверь pg.sql вручную"
      else
        mkdir -p "$B/backups"
        cp "$tmp/pg.sql" "$B/backups/restore-$(date +%Y%m%d%H%M%S).pg.sql" 2>/dev/null || true
        say "  БД пропущена — pg.sql сохранён в $B/backups/"
      fi
    else
      mkdir -p "$B/backups"
      cp "$tmp/pg.sql" "$B/backups/restore-$(date +%Y%m%d%H%M%S).pg.sql" 2>/dev/null || true
      say "  ! remnawave-db не запущен — pg.sql сохранён в $B/backups/"
      say "    после деплоя нажми b) ещё раз или запусти: bash $0 restore $arc"
    fi
  fi

  # Caddy data (сертификаты)
  if [ -d "$tmp/caddy_data" ]; then
    if docker inspect "$SLUG-caddy" >/dev/null 2>&1; then
      docker cp "$tmp/caddy_data/." "$SLUG-caddy:/data/" 2>/dev/null \
        && docker restart "$SLUG-caddy" >/dev/null 2>&1 \
        && say "  Caddy certs восстановлены, Caddy перезапущен" \
        || say "  ! ошибка восстановления Caddy certs"
    else
      mkdir -p "$B/caddy_data_restore"
      cp -r "$tmp/caddy_data/." "$B/caddy_data_restore/" 2>/dev/null || true
      say "  ! caddy не запущен — certs сохранены в $B/caddy_data_restore/"
      say "    после деплоя: docker cp $B/caddy_data_restore/. $SLUG-caddy:/data/ && docker restart $SLUG-caddy"
    fi
  fi

  rm -rf "$tmp"
  say "Готово."
  say "  Следующий шаг — деплой: bash $0 run"
}

do_backup(){
  load
  local B="/opt/$SLUG"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  local bdir="$B/backups/$ts"
  mkdir -p "$bdir"

  say "Бэкап $SLUG → $bdir"

  # конфиг визарда
  [ -f "$CONF" ] && cp "$CONF" "$bdir/deploy.conf" && say "  deploy.conf"

  # .env файлы компонентов
  for comp in panel sub caddy node decoy; do
    local ef="$B/$comp/.env"
    [ -f "$ef" ] && cp "$ef" "$bdir/$comp.env" && say "  $comp/.env"
  done

  # credentials и summary
  for f in credentials.txt summary.txt; do
    [ -f "$B/$f" ] && cp "$B/$f" "$bdir/$f" && say "  $f"
  done

  # дамп PostgreSQL
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^remnawave-db$'; then
    docker exec remnawave-db sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
      > "$bdir/pg.sql" 2>/dev/null \
      && say "  БД: pg.sql ($(du -sh "$bdir/pg.sql" 2>/dev/null | cut -f1))" \
      || say "  ! дамп БД не снят — контейнер remnawave-db не ответил"
  else
    say "  (remnawave-db не запущен — дамп БД пропущен)"
  fi

  # Caddy data (сертификаты)
  if docker inspect "$SLUG-caddy" >/dev/null 2>&1; then
    mkdir -p "$bdir/caddy_data"
    docker cp "$SLUG-caddy:/data/." "$bdir/caddy_data/" 2>/dev/null \
      && say "  Caddy data (сертификаты)" \
      || say "  ! не удалось сохранить Caddy data — сертификат будет перевыпущен при восстановлении"
  else
    say "  (caddy не запущен — сертификаты не сохранены)"
  fi

  # архив всего бэкапа
  local arc="$B/backups/${SLUG}-${ts}.tar.gz"
  tar -czf "$arc" -C "$bdir" . 2>/dev/null \
    && say "Архив: $arc ($(du -sh "$arc" 2>/dev/null | cut -f1))" \
    || say "! не удалось создать архив — файлы остались в $bdir"

  say "Готово. Все бэкапы: $B/backups/"
}

do_preflight(){
  # Обязательные поля по роли
  local ok=true
  _need(){ [ -n "${!1}" ] || { say "ОШИБКА: $1 не задан (запусти wizard)"; ok=false; }; }
  _ip(){ [[ "${!1}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { say "ПРЕДУПРЕЖДЕНИЕ: $1=${!1} не похоже на IPv4"; }; }
  case "${ROLE:-exit}" in
    exit|moonlight)
      _need MAIN_DOMAIN; _need EXIT_IP; _ip EXIT_IP ;;
    relay|sunshine)
      _need RELAY_DOMAIN; _need EXIT_IP; _ip EXIT_IP ;;
  esac
  $ok || die "Исправь конфиг перед деплоем."
  # Проверка портов 80/443
  for _p in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":$_p "; then
      say "ПРЕДУПРЕЖДЕНИЕ: порт $_p уже занят ($(ss -tlnp 2>/dev/null | grep ":$_p " | awk '{print $NF}' | head -1 || true))"
    fi
  done
}

do_stages(){
  load 2>/dev/null || true
  local what="${ROLE:-exit}"
  local W=26  # ширина колонки с именем фазы
  _s(){ printf "  %-${W}s %s\n" "$1" "$2"; }
  echo "Фазы для роли '$(c '1;32' "$what")' (--from <фаза> пропускает до указанной):"
  case "$what" in
    exit|moonlight)
      _s "wdtt-build.sh"        "Мобильный TURN-канал (аварийный VPN), UDP 56000/56001"
      _s "deploy-moonlight.sh"  "Docker-стек панели: Remnawave + БД + Redis + страница подписки"
      _s "provision.sh"         "Headless-настройка панели: admin, профиль, нода, тест-юзер, хосты"
      _s "deploy-node.sh exit"  "Xray-нода на выходном сервере (VLESS+Reality, Hysteria2)"
      _s "sync-hy2-cert.sh exit" "Копирует Hy2-сертификат из Caddy в контейнер ноды"
      _s "handoff-moonlight.sh" "Перехват порта 443: останавливает временный Caddy, поднимает основной"
      _s "kick-node.sh exit"    "Через API панели даёт ноде сигнал перечитать конфиг"
      _s "stealth.sh decoy"     "Деплоит страницу-заглушку (имитация облачного хранилища)"
      _s "stealth.sh caddy"     "Настраивает Caddy: / → декой, /api/sub/* → Remnawave, /c/* → connect"
      _s "deploy-decoy-pro.sh"  "Расширенные страницы декоя (pricing, docs, signup…)"
      _s "deploy-decoy-pages.sh" "Статические ассеты декоя (CSS, JS, шрифты)"
      _s "setup-connect-min.sh" "Минимальный connect-serve: страница /c/<uuid>/ для клиентов"
      _s "health-check.sh"      "Проверяет доступность панели, подписки, Hy2-сертификата"
      [ "${USE_TAILSCALE:-no}" = yes ] && \
      _s "setup-tailscale.sh"   "Подключает Tailscale, открывает панель на :8444 только внутри сети" ;;
    relay|sunshine)
      _s "provision-relay.sh"   "Готовит relay-сервер: ключи, bootstrap.env для sunshine-node"
      _s "setup-relay-ssh.sh"   "SSH на relay → запускает sunshine-node деплой удалённо"
      _s "kick-node.sh relay"   "Через API панели регистрирует relay-ноду"
      _s "health-check.sh"      "Проверяет доступность relay и Hy2-сертификата" ;;
    sunshine-node)
      _s "deploy-sunshine.sh"   "Docker-стек relay: xray-нода + Caddy на relay-сервере"
      _s "sync-hy2-cert.sh relay" "Копирует Hy2-сертификат relay из Caddy в контейнер ноды"
      _s "deploy-node.sh relay" "Регистрирует relay-ноду в панели через bootstrap.env"
      _s "deploy-decoy-sunshine.sh" "Страница-заглушка на relay (тот же бренд)"
      _s "health-check.sh"      "Проверяет relay" ;;
  esac
  echo ""
  echo "Пример: bash $0 --from provision.sh run"
}

do_rotate(){
  load
  local CRED="/opt/$SLUG/credentials.txt"
  say "Ротация паролей (панель Remnawave + WDTT)"

  # Читаем текущий пароль для API
  local cur_pass; cur_pass="$(grep -E '^\s*pass:' "$CRED" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  [ -z "$cur_pass" ] && die "Не могу прочитать текущий пароль из $CRED"

  local new_admin new_wdtt
  read -rp "  Новый пароль admin (Enter = сгенерировать): " new_admin || true
  [ -z "$new_admin" ] && new_admin="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)Aa1!"

  read -rp "  Новый пароль WDTT (Enter = сгенерировать): " new_wdtt || true
  [ -z "$new_wdtt" ] && new_wdtt="$(openssl rand -base64 12 | tr -d '/+=')"

  # Получаем токен Remnawave
  local token=""
  token="$(curl -sf --max-time 6 -X POST http://127.0.0.1:3000/api/auth/login \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$cur_pass\"}" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("response",{}).get("accessToken",""))' 2>/dev/null || true)"

  if [ -n "$token" ]; then
    local rc; rc="$(curl -sf --max-time 6 -o /dev/null -w '%{http_code}' \
      -X PATCH http://127.0.0.1:3000/api/auth/change-password \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $token" \
      -d "{\"oldPassword\":\"$cur_pass\",\"newPassword\":\"$new_admin\"}" 2>/dev/null || echo 0)"
    if [ "$rc" = 200 ] || [ "$rc" = 201 ]; then
      say "Admin пароль обновлён."
      sed -i "s|  pass: .*|  pass: $new_admin|" "$CRED" 2>/dev/null || true
      ADMIN_PASS="$new_admin"
      grep -q '^ADMIN_PASS=' "$CONF" 2>/dev/null \
        && sed -i "s|^ADMIN_PASS=.*|ADMIN_PASS=$(printf '%q' "$new_admin")|" "$CONF" \
        || printf 'ADMIN_PASS=%q\n' "$new_admin" >> "$CONF"
    else
      say "ПРЕДУПРЕЖДЕНИЕ: API вернул $rc — пароль панели не изменён. Смени вручную в Settings → Change Password."
    fi
  else
    say "ПРЕДУПРЕЖДЕНИЕ: не удалось авторизоваться в Remnawave API. Смени пароль вручную в панели."
  fi

  # WDTT: ищем конфиг
  local wdtt_cfg="/opt/$SLUG/wdtt/wdtt.conf"
  if [ -f "$wdtt_cfg" ]; then
    sed -i "s|^password=.*|password=$new_wdtt|" "$wdtt_cfg" 2>/dev/null \
      && docker restart "${SLUG:-mycloud}-wdtt" >/dev/null 2>&1 \
      && say "WDTT пароль обновлён и контейнер перезапущен." \
      || say "ПРЕДУПРЕЖДЕНИЕ: не удалось обновить WDTT конфиг — обнови вручную в $wdtt_cfg"
    # Обновляем credentials.txt
    grep -q 'wdtt-password:' "$CRED" 2>/dev/null \
      && sed -i "s|  wdtt-password: .*|  wdtt-password: $new_wdtt|" "$CRED" \
      || printf '  wdtt-password: %s\n' "$new_wdtt" >> "$CRED"
    WDTT_PASS="$new_wdtt"
    grep -q '^WDTT_PASS=' "$CONF" 2>/dev/null \
      && sed -i "s|^WDTT_PASS=.*|WDTT_PASS=$(printf '%q' "$new_wdtt")|" "$CONF" \
      || printf 'WDTT_PASS=%q\n' "$new_wdtt" >> "$CONF"
  else
    say "ПРЕДУПРЕЖДЕНИЕ: конфиг WDTT не найден по $wdtt_cfg — обнови пароль вручную."
    say "Новый WDTT пароль: $new_wdtt"
  fi

  say ""; say "Новые данные:"; say "  Admin:  $new_admin"; say "  WDTT:   $new_wdtt"
  say "Обновлено в: $CRED"
}

ask(){ local var="$1" prompt="$2" def="${3:-}" cur ans; cur="${!var:-$def}"; if [ "${ASSUME_YES:-0}" = 1 ]; then printf -v "$var" '%s' "$cur"; return; fi
  read -rp "  $prompt${cur:+ [$cur]}: " ans || true; printf -v "$var" '%s' "${ans:-$cur}"; }

wizard(){
  say "Мастер настройки (Enter — оставить значение в скобках)"
  set -a; [ -f "$CONF" ] && . "$CONF" || true; set +a

  _ask_yn(){
    local _var="$1" _prompt="$2" _dflt="$3" _v
    while true; do
      ask "$_var" "$_prompt" "$_dflt"
      _v="${!_var}"; _v="${_v,,}"
      if [ "$_v" = yes ] || [ "$_v" = no ]; then printf -v "$_var" '%s' "$_v"; break; fi
      say "  → Введите yes или no"
    done
  }

  say ""
  say "── Основное ────────────────────────────────────────────"
  ask ROLE     "Роль сервера: exit (выход/панель) или relay (релей)" "${ROLE:-exit}"
  ask BRAND    "Бренд (страница-декой)"                              "${BRAND:-MyCloud}"
  SLUG="$(printf '%s' "$BRAND" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
  say "  Slug (авто из бренда): $SLUG"
  ask SSH_PORT "SSH-порт (для UFW)"                                  "${SSH_PORT:-22}"
  _ask_yn HARDEN "Hardening SSH+firewall? (yes/no)"                 "${HARDEN:-no}"

  if [ "$ROLE" = exit ]; then
    say ""
    say "── Выходной сервер ─────────────────────────────────────"
    ask MAIN_DOMAIN "Домен выходного сервера (панель/подписка)"     "${MAIN_DOMAIN:-}"
    ask EXIT_IP     "Публичный IP выходного сервера"                "${EXIT_IP:-}"
    ask EXIT_NAME   "Имя выходного узла (метка)"                    "${EXIT_NAME:-Moonlight}"
    ask ACME_EMAIL  "E-mail для Let's Encrypt"                      "${ACME_EMAIL:-admin@${MAIN_DOMAIN:-example.com}}"
    _ask_yn USE_TAILSCALE "Скрывать панель через Tailscale? (yes/no)"                "${USE_TAILSCALE:-yes}"
    _ask_yn GEO_BLOCK     "Блокировать RU-домены/IP на выходе? (yes/no)"             "${GEO_BLOCK:-no}"
    _ask_yn PQ            "Post-quantum Reality ML-KEM-768? экспериментально (yes/no)" "${PQ:-no}"
    _ask_yn ACME_STAGING  "Staging-сертификат LE (тест без лимитов, браузер ругается)" "${ACME_STAGING:-no}"
    ask WDTT_PASS     "Пароль WDTT (пусто = сгенерируется при деплое)"               "${WDTT_PASS:-}"
    ask ADMIN_PASS    "Пароль admin-панели (пусто = сгенерируется при деплое)"         "${ADMIN_PASS:-}"
    TEST_SUB_UUID="${TEST_SUB_UUID:-}"

    say ""
    say "── Релей (оставьте IP пустым, если не планируете) ──────"
    ask RELAY_IP "Публичный IP релея"                               "${RELAY_IP:-}"
    if [ -n "$RELAY_IP" ]; then
      ask RELAY_DOMAIN "Домен релея"                               "${RELAY_DOMAIN:-}"
      ask RELAY_NAME   "Имя релея (метка)"                         "${RELAY_NAME:-Sunshine}"
      _ask_yn AUTO_RELAY "После exit сразу развернуть релей на $RELAY_IP? (yes/no)" "${AUTO_RELAY:-yes}"
    else
      RELAY_DOMAIN="${RELAY_DOMAIN:-}"; RELAY_NAME="${RELAY_NAME:-Sunshine}"; AUTO_RELAY="no"
    fi
  else
    say ""
    say "── Этот релей ──────────────────────────────────────────"
    ask RELAY_DOMAIN "Домен этого релея"                           "${RELAY_DOMAIN:-}"
    ask EXIT_IP      "IP выходного сервера (для пиринга)"          "${EXIT_IP:-}"
    ask EXIT_NAME    "Имя выходного узла (метка)"                  "${EXIT_NAME:-Moonlight}"
    ask RELAY_NAME   "Имя этого релея (метка)"                     "${RELAY_NAME:-Sunshine}"
    ask ACME_EMAIL   "E-mail для Let's Encrypt"                    "${ACME_EMAIL:-admin@${RELAY_DOMAIN:-example.com}}"
    MAIN_DOMAIN="${MAIN_DOMAIN:-}"; RELAY_IP="${RELAY_IP:-}"
    USE_TAILSCALE="${USE_TAILSCALE:-no}"; GEO_BLOCK="${GEO_BLOCK:-no}"; PQ="${PQ:-no}"; ACME_STAGING="${ACME_STAGING:-no}"
    TEST_SUB_UUID="${TEST_SUB_UUID:-}"; WDTT_PASS="${WDTT_PASS:-}"; ADMIN_PASS="${ADMIN_PASS:-}"; AUTO_RELAY="no"
  fi

  say ""
  say "── Проверьте настройки ─────────────────────────────────"
  for v in "${VARS[@]}"; do printf '  %-20s = %s\n' "$v" "${!v:-}"; done
  say ""
  local _ok; ask _ok "Сохранить? (yes — сохранить, no — начать заново)" "yes"
  if [ "${_ok:-yes}" != yes ]; then say "Перезапуск визарда..."; wizard; return; fi

  [ -f "$CONF" ] && cp -f "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  : > "$CONF"; for v in "${VARS[@]}"; do printf '%s=%q\n' "$v" "${!v:-}" >> "$CONF"; done
  say "Сохранил $CONF"
  do_info
}

load(){ [ -f "$CONF" ] || die "Нет $CONF — запусти: sudo bash $0 wizard"; set -a; . "$CONF"; set +a; }

render(){ # render <name> [out]
  ensure_templates
  local name="$1" out="${2:-/dev/stdout}" t="$TPL_DIR/$1"
  [ -f "$t" ] || t="$TPL_DIR/$1.tpl"; [ -f "$t" ] || die "нет шаблона: $1"
  local py=""; for k in "${PH[@]}"; do py+="s=s.replace('@@${k}@@', os.environ.get('${k}',''));"; done
  MAIN_DOMAIN="$MAIN_DOMAIN" RELAY_DOMAIN="$RELAY_DOMAIN" EXIT_IP="$EXIT_IP" RELAY_IP="$RELAY_IP" \
  BRAND="$BRAND" SLUG="$SLUG" EXIT_NAME="$EXIT_NAME" RELAY_NAME="$RELAY_NAME" \
  ACME_EMAIL="$ACME_EMAIL" SSH_PORT="$SSH_PORT" GEO_BLOCK="$GEO_BLOCK" PQ="$PQ" HARDEN="$HARDEN" TEST_SUB_UUID="$TEST_SUB_UUID" ACME_STAGING_LINE="$ACME_STAGING_LINE" \
  python3 - "$t" "$out" <<PY
import os,sys
s=open(sys.argv[1],encoding="utf-8").read()
$py
open(sys.argv[2],"w",encoding="utf-8").write(s) if sys.argv[2]!="/dev/stdout" else sys.stdout.write(s)
PY
}

WORK=""
phase(){ local script="$1"; shift || true
  say "Фаза: $script${*:+ $*}"
  local f="$WORK/$script"; render "$script" "$f"
  bash -n "$f" || die "синтаксическая ошибка в $script после рендера"
  if [ -n "${LOG_FILE:-}" ]; then
    bash "$f" "$@" 2>&1 | tee -a "$LOG_FILE" || die "ошибка в $script"
  else
    bash "$f" "$@"
  fi
  say "Готово: $script"; }

# обёртка для --from: пропускаем фазы до FROM_STAGE включительно, далее выполняем всё
run_phase(){
  if [ "$1" = "${FROM_STAGE:-}" ]; then STARTED=true; fi
  if "${STARTED:-true}"; then phase "$@"; fi
}

run(){
  load; ensure_templates
  WORK="/opt/$SLUG/.deploy"; mkdir -p "$WORK"
  LOG_FILE="/opt/$SLUG/deploy.log"
  ACME_STAGING_LINE=""
  [ "${ACME_STAGING:-no}" = yes ] && ACME_STAGING_LINE="    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"
  echo "=== Деплой $(date '+%Y-%m-%d %H:%M:%S')${FROM_STAGE:+ --from $FROM_STAGE} ===" >> "$LOG_FILE"
  say "Лог деплоя: $LOG_FILE"
  # сохраняем conf рядом с инстансом — чтобы будущий ре-деплой нашёл реальные значения откуда угодно
  [ -f "$CONF" ] && [ "$CONF" != "$WORK/deploy.conf" ] && cp -f "$CONF" "$WORK/deploy.conf" 2>/dev/null || true
  do_preflight
  # префлайт: убрать конфликтующие контейнеры ДРУГИХ slug (host-network Caddy/декой дерутся за порты)
  local __c; for __c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E -- '-(caddy|decoy|decoy-php)$' | grep -vE "^${SLUG}-" || true); do
    docker rm -f "$__c" >/dev/null 2>&1 && say "префлайт: убрал конфликтующий контейнер чужого slug — $__c"
  done
  local STARTED=true
  if [ -n "${FROM_STAGE:-}" ]; then STARTED=false; fi
  local what="${1:-$ROLE}"
  case "$what" in
    exit|moonlight)
      # WDTT первым — поднимаем мобильный TURN-канал до основного стека
      run_phase wdtt-build.sh
      run_phase deploy-moonlight.sh
      # headless-настройка панели (без дашборда): админ → профиль → нода →
      # SECRET_KEY из keygen в .env ноды → squad → тест-юзер → хосты → подписка
      export DOMAIN="$MAIN_DOMAIN" NODE_NAME="$EXIT_NAME" NODE_ADDRESS="$EXIT_IP" XRAY_CONFIG_FILE="/opt/$SLUG/node/xray-profile.json"
      run_phase provision.sh
      # Захватываем shortUuid тест-пользователя из Remnawave API
      _capture_test_uuid(){
        local _cred="/opt/$SLUG/credentials.txt"
        local _pass; _pass="$(grep -E '^\s*pass:' "$_cred" 2>/dev/null | awk '{print $2}' | head -1 || true)"
        [ -z "$_pass" ] && return 0
        local _tok; _tok="$(curl -sf --max-time 6 -X POST http://127.0.0.1:3000/api/auth/login \
          -H 'Content-Type: application/json' \
          -d "{\"username\":\"admin\",\"password\":\"$_pass\"}" 2>/dev/null \
          | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("response",{}).get("accessToken",""))' 2>/dev/null || true)"
        [ -z "$_tok" ] && return 0
        local _uuid; _uuid="$(curl -sf --max-time 6 -H "Authorization: Bearer $_tok" \
          http://127.0.0.1:3000/api/users 2>/dev/null \
          | python3 -c 'import sys,json;us=json.load(sys.stdin).get("response",{}).get("users",[]); print(us[0].get("shortUuid","") if us else "")' 2>/dev/null || true)"
        [ -z "$_uuid" ] && return 0
        TEST_SUB_UUID="$_uuid"
        grep -q '^TEST_SUB_UUID=' "$CONF" 2>/dev/null \
          && sed -i "s|^TEST_SUB_UUID=.*|TEST_SUB_UUID=$(printf '%q' "$_uuid")|" "$CONF" \
          || printf 'TEST_SUB_UUID=%q\n' "$_uuid" >> "$CONF"
        say "Тест-пользователь UUID: $_uuid"
      }
      _capture_test_uuid || true
      run_phase deploy-node.sh exit
      run_phase sync-hy2-cert.sh exit
      run_phase handoff-moonlight.sh
      # пнуть ноду через панель → конфиг ложится на освободившийся 443 (до stealth)
      run_phase kick-node.sh exit
      run_phase stealth.sh decoy
      run_phase stealth.sh caddy
      run_phase deploy-decoy-pro.sh
      run_phase deploy-decoy-pages.sh
      run_phase setup-connect-min.sh
      if $STARTED; then
        say "Happ: для Hysteria2 в Happ добавь Response Rule Happ → XRAY_JSON (для VLESS-клиентов необязательно)."
      fi
      run_phase health-check.sh
      # авто-релей: если в визарде включён AUTO_RELAY и есть IP релея — гоним relay в той же команде
      if $STARTED && [ "${AUTO_RELAY:-no}" = yes ] && [ -n "${RELAY_IP:-}" ]; then
        echo; say "$(c '1;36' '════ Авто-развёртывание релея ('"$RELAY_NAME"') ════')"
        FROM_STAGE="" run relay
      fi
      # Tailscale последним: нужен :8082 (stealth) и не должен мешать handoff на 443
      [ "${USE_TAILSCALE:-no}" = yes ] && run_phase setup-tailscale.sh
      $STARTED && do_info ;;
    relay|sunshine)
      run_phase provision-relay.sh
      run_phase setup-relay-ssh.sh
      run_phase kick-node.sh relay
      run_phase health-check.sh ;;
    sunshine-node)
      # запускается УДАЛЁННО на Sunshine через SSH из setup-relay-ssh.sh
      run_phase deploy-sunshine.sh
      run_phase sync-hy2-cert.sh relay
      run_phase deploy-node.sh relay
      run_phase deploy-decoy-sunshine.sh
      run_phase health-check.sh ;;
    *) run_phase "$what" ;;
  esac
  if [ -n "${FROM_STAGE:-}" ] && ! "$STARTED"; then echo "Этап '$FROM_STAGE' не найден!" >&2; return 1; fi
  say "Развёртывание ($what) завершено."
}

__extract_blobs(){
  local d="$1"; mkdir -p "$d"
  base64 -d > "$d/deploy-decoy-pages.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1kZWNv
eS1wYWdlcy5zaCDigJQg0YHQstGP0LfQvdGL0Lkg0LzQvdC+0LPQvtGB0YLRgNCw0L3QuNGH0L3Q
uNC6INC00LvRjyDQtNC10LrQvtGPIEBAQlJBTkRAQCBDbG91ZAojICDQn9GA0LXQstGA0LDRidCw
0LXRgiAi0LzRkdGA0YLQstGL0LUiINGB0YHRi9C70LrQuCAoIykg0LIg0YDQtdCw0LvRjNC90YvQ
tSDRgdGC0YDQsNC90LjRhtGLOgojICAgIC9wcmljaW5nIC9zZWN1cml0eSAvZG9jcyAvc3RhdHVz
IC9wcml2YWN5IC90ZXJtcyAvc3VwcG9ydCAvc2lnbnVwIC9yZXNldAojICDQntCx0YnQuNC5INGF
0LXQtNC10YAv0YTRg9GC0LXRgCwg0LXQtNC40L3Ri9C5IC9hc3NldHMvYXBwLmNzcyArIC9hc3Nl
dHMvYXBwLmpzLgojICBuZ2lueDogZXh0ZW5zaW9ubGVzcy3RgNC+0YPRgtC40L3QsyAoL3ByaWNp
bmcgLT4gcHJpY2luZy5odG1sKSArINC80L7QuiAvYXBpL3JlZ2lzdGVyCiMgINC4IC9hcGkvcmVz
ZXQgKNC90LXQudGC0YDQsNC70YzQvdGL0LUg0L7RgtCy0LXRgtGLLCDQsdC10Lcg0L/QtdGA0LXR
h9C40YHQu9C10L3QuNGPINCw0LrQutCw0YPQvdGC0L7QsikuCiMgINCR0Y3QutCw0L/QuNGCINCy
0YHRkSDQv9C10YDQtdC30LDQv9C40YHRi9Cy0LDQtdC80L7QtS4g0J7RgtC60LDRgiDigJQg0LIg
0LrQvtC90YbQtSDQstGL0LLQvtC00LAuCiMgINCi0YDQtdCx0YPQtdGCINGD0LbQtSDRgNCw0LfQ
stGR0YDQvdGD0YLQvtCz0L4g0LTQtdC60L7RjyAo0L/QvtGB0LvQtSBkZXBsb3ktZGVjb3ktcHJv
LnNoKS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbApST09UPS9vcHQv
QEBTTFVHQEAvZGVjb3kKRD0iJFJPT1QvZGF0YSIKdHM9JChkYXRlICslWSVtJWQtJUglTSVTKQoK
WyAtZCAiJEQvYXNzZXRzIiBdIHx8IHsgZWNobyAi0J3QtSDQvdCw0LnQtNC10L0gJEQvYXNzZXRz
IOKAlCDRgdC90LDRh9Cw0LvQsCDRgNCw0LfQstC10YDQvdC4IGRlcGxveS1kZWNveS1wcm8uc2gi
OyBleGl0IDE7IH0KCmVjaG8gIj09IFsxLzRdINCR0Y3QutCw0L8g0L/QtdGA0LXQt9Cw0L/QuNGB
0YvQstCw0LXQvNC+0LPQviA9PSIKZm9yIGYgaW4gaW5kZXguaHRtbCBuZ2lueC5jb25mIGFzc2V0
cy9hcHAuY3NzIGFzc2V0cy9hcHAuanM7IGRvCiAgWyAtZiAiJEQvJGYiIF0gJiYgY3AgLWEgIiRE
LyRmIiAiJEQvJGYuYmFrLiR0cyIgJiYgZWNobyAiICAkRC8kZi5iYWsuJHRzIgpkb25lClsgLWYg
IiRST09UL2RvY2tlci1jb21wb3NlLnltbCIgXSAmJiBjcCAtYSAiJFJPT1QvZG9ja2VyLWNvbXBv
c2UueW1sIiAiJFJPT1QvZG9ja2VyLWNvbXBvc2UueW1sLmJhay4kdHMiICYmIGVjaG8gIiAgJFJP
T1QvZG9ja2VyLWNvbXBvc2UueW1sLmJhay4kdHMiCgplY2hvICI9PSBbMi80XSDQn9C40YjRgyDR
gdGC0YDQsNC90LjRhtGLLCDRgdGC0LjQu9C4LCDRgdC60YDQuNC/0YIg0Lgg0LrQvtC90YTQuNCz
0LggPT0iCm1rZGlyIC1wICIkRC9hc3NldHMiCmNhdCA+ICIkRC9hc3NldHMvYXBwLmNzcyIgPDwn
REVDT1lfQVBQQ1NTJwo6cm9vdHsKICAtLWJnOiNlZWYyZjg7IC0tcGFuZWw6I2ZmZmZmZjsgLS1p
bms6IzEwMTcyODsgLS1tdXRlZDojNWI2Yjg2OwogIC0tbGluZTojZTJlOGYyOyAtLWJyYW5kOiMz
YTViZDk7IC0tYnJhbmQtcHJlc3M6IzJmNDlhZDsgLS1yaW5nOiM5ZGI0ZjQ7CiAgLS1vazojMWY5
ZDU3OyAtLXdhcm46I2MyM2IzYjsgLS1zaGFkb3c6MCAxOHB4IDUwcHggLTI0cHggcmdiYSgyMCw0
MCw5MCwuMzUpOwogIC0tcmFkaXVzOjE0cHg7Cn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9Cmh0
bWwsYm9keXttYXJnaW46MDtoZWlnaHQ6MTAwJX0KYm9keXsKICBmb250LWZhbWlseTotYXBwbGUt
c3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9udCwiU2Vnb2UgVUkiLFJvYm90byxIZWx2ZXRpY2EsQXJp
YWwsc2Fucy1zZXJpZjsKICBjb2xvcjp2YXIoLS1pbmspOyBiYWNrZ3JvdW5kOnZhcigtLWJnKTsK
ICAtd2Via2l0LWZvbnQtc21vb3RoaW5nOmFudGlhbGlhc2VkOyBsaW5lLWhlaWdodDoxLjU7CiAg
YmFja2dyb3VuZC1pbWFnZTpyYWRpYWwtZ3JhZGllbnQoMTEwMHB4IDU0MHB4IGF0IDg2JSAtMTAl
LCAjZGZlOGZiIDAlLCByZ2JhKDIyMywyMzIsMjUxLDApIDYwJSksCiAgICAgICAgICAgICAgICAg
ICByYWRpYWwtZ3JhZGllbnQoOTAwcHggNTAwcHggYXQgLTEwJSAxMTAlLCAjZTZlZmZiIDAlLCBy
Z2JhKDIzMCwyMzksMjUxLDApIDU1JSk7Cn0KYXtjb2xvcjppbmhlcml0O3RleHQtZGVjb3JhdGlv
bjpub25lfQoud3JhcHttYXgtd2lkdGg6MTE2MHB4O21hcmdpbjowIGF1dG87cGFkZGluZzowIDI0
cHh9CmhlYWRlcntwb3NpdGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDo1O2JhY2tkcm9wLWZpbHRl
cjpzYXR1cmF0ZSgxLjEpIGJsdXIoOHB4KTsKICBiYWNrZ3JvdW5kOnJnYmEoMjM4LDI0MiwyNDgs
Ljc4KTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKX0KLmJhcntkaXNwbGF5OmZs
ZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2hlaWdo
dDo2NnB4fQouYnJhbmR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTFweDtm
b250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LS4ycHh9Ci5tYXJre3dpZHRoOjMwcHg7aGVp
Z2h0OjMwcHg7ZmxleDpub25lfQpuYXYubGlua3N7ZGlzcGxheTpmbGV4O2dhcDoyOHB4O2ZvbnQt
c2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKX0KbmF2LmxpbmtzIGE6aG92ZXJ7Y29sb3I6dmFy
KC0taW5rKX0KLm5hdi1jdGF7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTZw
eH0KLmdob3N0e2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKX0KLmdob3N0OmhvdmVy
e2NvbG9yOnZhcigtLWluayl9Ci5idG57YXBwZWFyYW5jZTpub25lO2JvcmRlcjowO2N1cnNvcjpw
b2ludGVyO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDA7CiAgYm9yZGVyLXJhZGl1czoxMHB4
O3BhZGRpbmc6MTFweCAxOHB4O2JhY2tncm91bmQ6dmFyKC0tYnJhbmQpO2NvbG9yOiNmZmY7dHJh
bnNpdGlvbjpiYWNrZ3JvdW5kIC4xNXMsIHRyYW5zZm9ybSAuMDVzfQouYnRuOmhvdmVye2JhY2tn
cm91bmQ6dmFyKC0tYnJhbmQtcHJlc3MpfQouYnRuOmFjdGl2ZXt0cmFuc2Zvcm06dHJhbnNsYXRl
WSgxcHgpfQouYnRuLmJsb2Nre3dpZHRoOjEwMCU7cGFkZGluZzoxM3B4fQouYnRuW2Rpc2FibGVk
XXtvcGFjaXR5Oi42O2N1cnNvcjpkZWZhdWx0fQptYWlue3BhZGRpbmc6NjRweCAwIDI4cHh9Ci5n
cmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MS4wNWZyIC45NWZyO2dhcDo2
NHB4O2FsaWduLWl0ZW1zOmNlbnRlcn0KLmV5ZWJyb3d7Zm9udC1zaXplOjEyLjVweDtmb250LXdl
aWdodDo2MDA7bGV0dGVyLXNwYWNpbmc6LjEyZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2Nv
bG9yOnZhcigtLWJyYW5kKX0KaDF7Zm9udC1zaXplOjQ2cHg7bGluZS1oZWlnaHQ6MS4wODtsZXR0
ZXItc3BhY2luZzotMS4xcHg7bWFyZ2luOjE0cHggMCAxNnB4O2ZvbnQtd2VpZ2h0Ojc2MH0KLmxl
ZGV7Zm9udC1zaXplOjE3LjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWF4LXdpZHRoOjMwZW07bWFy
Z2luOjAgMCAyNnB4fQp1bC5mZWF0e2xpc3Qtc3R5bGU6bm9uZTtwYWRkaW5nOjA7bWFyZ2luOjA7
ZGlzcGxheTpncmlkO2dhcDoxM3B4O21heC13aWR0aDozMGVtfQp1bC5mZWF0IGxpe2Rpc3BsYXk6
ZmxleDtnYXA6MTFweDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O2ZvbnQtc2l6ZToxNXB4fQp1bC5m
ZWF0IHN2Z3tmbGV4Om5vbmU7bWFyZ2luLXRvcDoycHg7Y29sb3I6dmFyKC0tYnJhbmQpfQouaGVy
by1pbWd7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDIwcHg7bWFyZ2luOjI2cHggMCAwO2Rpc3BsYXk6
YmxvY2t9Ci50cnVzdHttYXJnaW4tdG9wOjI0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0t
bXV0ZWQpO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweH0KLmNhcmR7YmFj
a2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXIt
cmFkaXVzOnZhcigtLXJhZGl1cyk7CiAgYm94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO3BhZGRpbmc6
MzBweCAzMHB4IDI2cHh9Ci5jYXJkIGgye21hcmdpbjowIDAgNHB4O2ZvbnQtc2l6ZToyMXB4O2xl
dHRlci1zcGFjaW5nOi0uM3B4fQouY2FyZCAuc3Vie21hcmdpbjowIDAgMjJweDtjb2xvcjp2YXIo
LS1tdXRlZCk7Zm9udC1zaXplOjE0cHh9CmxhYmVse2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjEz
cHg7Zm9udC13ZWlnaHQ6NjAwO21hcmdpbjowIDAgN3B4O2NvbG9yOiMzMzQxNWN9Ci5maWVsZHtt
YXJnaW4tYm90dG9tOjE2cHh9CmlucHV0W3R5cGU9dGV4dF0saW5wdXRbdHlwZT1lbWFpbF0saW5w
dXRbdHlwZT1wYXNzd29yZF17d2lkdGg6MTAwJTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUp
O2JvcmRlci1yYWRpdXM6MTBweDsKICBwYWRkaW5nOjEycHggMTNweDtmb250OmluaGVyaXQ7YmFj
a2dyb3VuZDojZmJmY2ZlO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4xNXMsIGJveC1zaGFkb3cg
LjE1c30KaW5wdXQ6Zm9jdXN7b3V0bGluZTowO2JvcmRlci1jb2xvcjp2YXIoLS1icmFuZCk7Ym94
LXNoYWRvdzowIDAgMCA0cHggdmFyKC0tcmluZyl9Ci5yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW46LTJweCAwIDE4
cHh9Ci5yZW1lbWJlcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9u
dC1zaXplOjEzLjVweDtjb2xvcjp2YXIoLS1tdXRlZCl9Ci5saW5re2NvbG9yOnZhcigtLWJyYW5k
KTtmb250LXNpemU6MTMuNXB4O2ZvbnQtd2VpZ2h0OjYwMH0KLmxpbms6aG92ZXJ7dGV4dC1kZWNv
cmF0aW9uOnVuZGVybGluZX0KLm1zZ3tkaXNwbGF5Om5vbmU7bWFyZ2luOjAgMCAxNnB4O3BhZGRp
bmc6MTBweCAxMnB4O2JvcmRlci1yYWRpdXM6OXB4O2ZvbnQtc2l6ZToxMy41cHg7CiAgYmFja2dy
b3VuZDojZmRlY2VjO2NvbG9yOiNhMDI5Mjk7Ym9yZGVyOjFweCBzb2xpZCAjZjZjY2NjfQoubXNn
LnNob3d7ZGlzcGxheTpibG9ja30KLmFsdHttYXJnaW46MDt0ZXh0LWFsaWduOmNlbnRlcjtmb250
LXNpemU6MTMuNXB4O2NvbG9yOnZhcigtLW11dGVkKX0KLmRpdmlkZXJ7ZGlzcGxheTpmbGV4O2Fs
aWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDtjb2xvcjojOWFhN2JkO2ZvbnQtc2l6ZToxMnB4O21h
cmdpbjoyMHB4IDB9Ci5kaXZpZGVyOjpiZWZvcmUsLmRpdmlkZXI6OmFmdGVye2NvbnRlbnQ6IiI7
aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOnZhcigtLWxpbmUpO2ZsZXg6MX0KZm9vdGVye2JvcmRlci10
b3A6MXB4IHNvbGlkIHZhcigtLWxpbmUpO21hcmdpbi10b3A6NDhweDtiYWNrZ3JvdW5kOnJnYmEo
MjU1LDI1NSwyNTUsLjUpfQouZm9vdHtkaXNwbGF5OmZsZXg7ZmxleC13cmFwOndyYXA7Z2FwOjE4
cHggMjhweDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47
CiAgcGFkZGluZzoyMnB4IDA7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQouZm9v
dCBuYXZ7ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDoxOHB4fQouZm9vdCBhOmhvdmVy
e2NvbG9yOnZhcigtLWluayl9Ci5zdGF0dXN7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVt
czpjZW50ZXI7Z2FwOjhweH0KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVz
OjUwJTtiYWNrZ3JvdW5kOiNjMmM5ZDZ9Ci5kb3Qub2t7YmFja2dyb3VuZDp2YXIoLS1vayk7Ym94
LXNoYWRvdzowIDAgMCAzcHggcmdiYSgzMSwxNTcsODcsLjE1KX0KLnJldmVhbHtvcGFjaXR5OjA7
dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTBweCk7YW5pbWF0aW9uOnJpc2UgLjZzIGN1YmljLWJlemll
ciguMiwuNywuMiwxKSBmb3J3YXJkc30KLnJldmVhbC5kMnthbmltYXRpb24tZGVsYXk6LjA4c30K
QGtleWZyYW1lcyByaXNle3Rve29wYWNpdHk6MTt0cmFuc2Zvcm06bm9uZX19CkBtZWRpYSAocHJl
ZmVycy1yZWR1Y2VkLW1vdGlvbjpyZWR1Y2Upey5yZXZlYWx7YW5pbWF0aW9uOm5vbmU7b3BhY2l0
eToxO3RyYW5zZm9ybTpub25lfX0KQG1lZGlhIChtYXgtd2lkdGg6ODgwcHgpewogIG5hdi5saW5r
c3tkaXNwbGF5Om5vbmV9CiAgLmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcjtnYXA6NDBw
eH0KICBtYWlue3BhZGRpbmc6NDBweCAwIDE2cHh9CiAgaDF7Zm9udC1zaXplOjM2cHh9CiAgLnBp
dGNoe29yZGVyOjJ9LmF1dGh7b3JkZXI6MX0KICAuaGVyby1pbWd7ZGlzcGxheTpub25lfQp9Cgov
KiDilIDilIAgbXVsdGktcGFnZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLmxpbmtz
IGEuYWN0aXZle2NvbG9yOnZhcigtLWluayl9Ci5wYWdlLW1haW57cGFkZGluZzo1NnB4IDAgNDBw
eH0KLnBhZ2UtaGVhZHttYXgtd2lkdGg6NzYwcHg7bWFyZ2luOjAgMCAyOHB4fQoucGFnZS1oZWFk
IC5leWVicm93e21hcmdpbi1ib3R0b206OHB4fQoucGFnZS1oZWFkIGgxe2ZvbnQtc2l6ZTozOHB4
O2xpbmUtaGVpZ2h0OjEuMTttYXJnaW46NnB4IDAgMTBweH0KLnBhZ2UtaGVhZCBwe2NvbG9yOnZh
cigtLW11dGVkKTtmb250LXNpemU6MTdweDttYXgtd2lkdGg6NDJlbTttYXJnaW46MH0KLnByb3Nl
e21heC13aWR0aDo3MjBweDtjb2xvcjojMmEzODUwO2ZvbnQtc2l6ZToxNS41cHh9Ci5wcm9zZSBo
Mntmb250LXNpemU6MjBweDttYXJnaW46MzBweCAwIDEwcHg7bGV0dGVyLXNwYWNpbmc6LS4ycHh9
Ci5wcm9zZSBwe21hcmdpbjowIDAgMTRweH0KLnByb3NlIHVse21hcmdpbjowIDAgMTRweDtwYWRk
aW5nLWxlZnQ6MjBweH0KLnByb3NlIGxpe21hcmdpbjo2cHggMH0KLnByb3NlIC5tdXRlZHtjb2xv
cjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEzLjVweDttYXJnaW4tdG9wOjIycHh9Ci5tc2cub2t7
YmFja2dyb3VuZDojZTlmN2VmO2NvbG9yOiMxYzdhNDQ7Ym9yZGVyLWNvbG9yOiNiZmU2Y2R9Ci5j
ZW50ZXItY2FyZHttYXgtd2lkdGg6NDIwcHg7bWFyZ2luOjQ4cHggYXV0byA4cHh9Ci8qIHByaWNp
bmcgKi8KLnByaWNpbmd7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQo
MywxZnIpO2dhcDoyMHB4O21hcmdpbjo4cHggMCAwfQoudGllcntiYWNrZ3JvdW5kOnZhcigtLXBh
bmVsKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFk
aXVzKTtwYWRkaW5nOjI0cHg7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbn0KLnRp
ZXIuZmVhdC10aWVye2JvcmRlci1jb2xvcjp2YXIoLS1icmFuZCk7Ym94LXNoYWRvdzp2YXIoLS1z
aGFkb3cpfQoudGllciBoM3ttYXJnaW46MCAwIDJweDtmb250LXNpemU6MTdweH0KLnRpZXIgLnBy
aWNle2ZvbnQtc2l6ZTozMHB4O2ZvbnQtd2VpZ2h0Ojc0MDtsZXR0ZXItc3BhY2luZzotMXB4O21h
cmdpbjo2cHggMH0KLnRpZXIgLnByaWNlIHNwYW57Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6
NTAwO2NvbG9yOnZhcigtLW11dGVkKX0KLnRpZXIgdWx7bGlzdC1zdHlsZTpub25lO3BhZGRpbmc6
MDttYXJnaW46MTRweCAwIDIwcHg7ZGlzcGxheTpncmlkO2dhcDo5cHg7Zm9udC1zaXplOjE0cHg7
Y29sb3I6IzMzNDE1Y30KLnRpZXIgdWwgbGl7ZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRl
bXM6ZmxleC1zdGFydH0KLnRpZXIgdWwgc3Zne2ZsZXg6bm9uZTttYXJnaW4tdG9wOjJweDtjb2xv
cjp2YXIoLS1icmFuZCl9Ci50aWVyIC5idG57bWFyZ2luLXRvcDphdXRvO3RleHQtYWxpZ246Y2Vu
dGVyfQoudGFne2Rpc3BsYXk6aW5saW5lLWJsb2NrO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0
OjcwMDtsZXR0ZXItc3BhY2luZzouMDhlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7Y29sb3I6
dmFyKC0tYnJhbmQpO2JhY2tncm91bmQ6I2U4ZWRmZDtib3JkZXItcmFkaXVzOjk5OXB4O3BhZGRp
bmc6M3B4IDlweDthbGlnbi1zZWxmOmZsZXgtc3RhcnQ7bWFyZ2luLWJvdHRvbTo4cHh9Ci8qIHN0
YXR1cyAqLwouc3RhdHVzLWJhbm5lcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dh
cDoxMnB4O2JhY2tncm91bmQ6I2U5ZjdlZjtib3JkZXI6MXB4IHNvbGlkICNiZmU2Y2Q7Y29sb3I6
IzFjN2E0NDtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNnB4IDE4cHg7Zm9udC13ZWlnaHQ6
NjAwO21hcmdpbjowIDAgMThweH0KLmNvbXB7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRl
cjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjE0cHggMnB4O2JvcmRlci1i
b3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpO2ZvbnQtc2l6ZToxNXB4fQouY29tcDpsYXN0LW9m
LXR5cGV7Ym9yZGVyLWJvdHRvbTowfQoub3B7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVt
czpjZW50ZXI7Z2FwOjhweDtjb2xvcjp2YXIoLS1vayk7Zm9udC1zaXplOjEzLjVweDtmb250LXdl
aWdodDo2MDB9Ci5vcCAuZG90e2JhY2tncm91bmQ6dmFyKC0tb2spO2JveC1zaGFkb3c6MCAwIDAg
M3B4IHJnYmEoMzEsMTU3LDg3LC4xNSl9Ci8qIGRvY3MgKi8KLmRvY3N7ZGlzcGxheTpncmlkO2dy
aWQtdGVtcGxhdGUtY29sdW1uczoyMjBweCAxZnI7Z2FwOjQwcHg7YWxpZ24taXRlbXM6c3RhcnR9
Ci5kb2NzIG5hdi50b2N7cG9zaXRpb246c3RpY2t5O3RvcDo5MHB4O2Rpc3BsYXk6Z3JpZDtnYXA6
NnB4O2ZvbnQtc2l6ZToxNHB4fQouZG9jcyBuYXYudG9jIGF7Y29sb3I6dmFyKC0tbXV0ZWQpO3Bh
ZGRpbmc6NXB4IDB9Ci5kb2NzIG5hdi50b2MgYTpob3Zlcntjb2xvcjp2YXIoLS1pbmspfQpAbWVk
aWEgKG1heC13aWR0aDo4ODBweCl7CiAgLnByaWNpbmd7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFm
cn0KICAuZG9jc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfQogIC5kb2NzIG5hdi50b2N7cG9z
aXRpb246c3RhdGljfQogIC5wYWdlLWhlYWQgaDF7Zm9udC1zaXplOjMwcHh9Cn0KREVDT1lfQVBQ
Q1NTCgpjYXQgPiAiJEQvYXNzZXRzL2FwcC5qcyIgPDwnREVDT1lfQVBQSlMnCi8qIEBAQlJBTkRA
QCBDbG91ZCDigJQgd2ViIGNsaWVudCBib290c3RyYXAgKi8KKGZ1bmN0aW9uKCl7CiAgInVzZSBz
dHJpY3QiOwogIHZhciBBUEk9e3N0YXR1czoiL2FwaS9zdGF0dXMiLGF1dGg6Ii9hcGkvYXV0aCIs
cmVnaXN0ZXI6Ii9hcGkvcmVnaXN0ZXIiLHJlc2V0OiIvYXBpL3Jlc2V0In07CgogIGZ1bmN0aW9u
IGVsKGlkKXtyZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpO30KICBmdW5jdGlvbiBy
ZWFkeShmbil7aWYoZG9jdW1lbnQucmVhZHlTdGF0ZSE9PSJsb2FkaW5nIilmbigpO2Vsc2UgZG9j
dW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigiRE9NQ29udGVudExvYWRlZCIsZm4pO30KICBmdW5jdGlv
biBzaG93KG1zZyx0ZXh0LG9rKXtpZighbXNnKXJldHVybjttc2cudGV4dENvbnRlbnQ9dGV4dDtt
c2cuY2xhc3NOYW1lPSJtc2cgc2hvdyIrKG9rPyIgb2siOiIiKTt9CiAgZnVuY3Rpb24gY2xlYXIo
bXNnKXtpZihtc2cpbXNnLmNsYXNzTmFtZT0ibXNnIjt9CgogIHJlYWR5KGZ1bmN0aW9uKCl7CiAg
ICB2YXIgeXI9ZWwoInlyIik7IGlmKHlyKSB5ci50ZXh0Q29udGVudD1uZXcgRGF0ZSgpLmdldEZ1
bGxZZWFyKCk7CgogICAgLy8gc2VydmljZSBzdGF0dXMgaW5kaWNhdG9yIChmb290ZXIsIGV2ZXJ5
IHBhZ2UpCiAgICBmZXRjaChBUEkuc3RhdHVzLHtoZWFkZXJzOntBY2NlcHQ6ImFwcGxpY2F0aW9u
L2pzb24ifX0pCiAgICAgIC50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLm9rP3IuanNvbigpOlBy
b21pc2UucmVqZWN0KCk7fSkKICAgICAgLnRoZW4oZnVuY3Rpb24oZCl7CiAgICAgICAgdmFyIGRv
dD1lbCgic2RvdCIpLHQ9ZWwoInN0ZXh0Iik7CiAgICAgICAgaWYoZCYmZC5vbmxpbmUpe2RvdCYm
ZG90LmNsYXNzTGlzdC5hZGQoIm9rIik7dCYmKHQudGV4dENvbnRlbnQ9IkFsbCBzeXN0ZW1zIG9w
ZXJhdGlvbmFsIik7fQogICAgICAgIGVsc2V7dCYmKHQudGV4dENvbnRlbnQ9IkRlZ3JhZGVkIHBl
cmZvcm1hbmNlIik7fQogICAgICB9KQogICAgICAuY2F0Y2goZnVuY3Rpb24oKXt2YXIgdD1lbCgi
c3RleHQiKTt0JiYodC50ZXh0Q29udGVudD0iU3RhdHVzIHVuYXZhaWxhYmxlIik7fSk7CgogICAg
Ly8gc2lnbi1pbgogICAgdmFyIGxvZ2luPWVsKCJsb2dpbiIpOwogICAgaWYobG9naW4pewogICAg
ICB2YXIgbG1zZz1lbCgibXNnIiksbGJ0bj1lbCgic3VibWl0Iik7CiAgICAgIGxvZ2luLmFkZEV2
ZW50TGlzdGVuZXIoInN1Ym1pdCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVs
dCgpO2NsZWFyKGxtc2cpOwogICAgICAgIHZhciBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8fCIi
KS50cmltKCkscGFzcz1lbCgicGFzc3dvcmQiKS52YWx1ZXx8IiI7CiAgICAgICAgaWYoIWVtYWls
fHwhcGFzcyl7c2hvdyhsbXNnLCJFbnRlciB5b3VyIGVtYWlsIGFuZCBwYXNzd29yZCB0byBjb250
aW51ZS4iKTtyZXR1cm47fQogICAgICAgIGxidG4uZGlzYWJsZWQ9dHJ1ZTtsYnRuLnRleHRDb250
ZW50PSJTaWduaW5nIGlu4oCmIjsKICAgICAgICBmZXRjaChBUEkuYXV0aCx7bWV0aG9kOiJQT1NU
IixoZWFkZXJzOnsiQ29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJhcHBs
aWNhdGlvbi9qc29uIn0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtlbWFpbDplbWFp
bCxwYXNzd29yZDpwYXNzLHJlbWVtYmVyOiEhbG9naW4ucmVtZW1iZXIuY2hlY2tlZH0pfSkKICAg
ICAgICAudGhlbihmdW5jdGlvbihyKXsKICAgICAgICAgIGlmKHIuc3RhdHVzPT09NDI5KXNob3co
bG1zZywiVG9vIG1hbnkgYXR0ZW1wdHMuIFBsZWFzZSB3YWl0IGEgbW9tZW50IGFuZCB0cnkgYWdh
aW4uIik7CiAgICAgICAgICBlbHNlIHNob3cobG1zZywiRW1haWwgb3IgcGFzc3dvcmQgaXMgaW5j
b3JyZWN0LiIpOwogICAgICAgIH0pCiAgICAgICAgLmNhdGNoKGZ1bmN0aW9uKCl7c2hvdyhsbXNn
LCJDYW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hlY2sgeW91ciBjb25uZWN0aW9uIGFuZCB0cnkg
YWdhaW4uIik7fSkKICAgICAgICAuZmluYWxseShmdW5jdGlvbigpe2xidG4uZGlzYWJsZWQ9ZmFs
c2U7bGJ0bi50ZXh0Q29udGVudD0iU2lnbiBpbiI7fSk7CiAgICAgIH0pOwogICAgfQoKICAgIC8v
IGNyZWF0ZSBhY2NvdW50CiAgICB2YXIgc2lnbnVwPWVsKCJzaWdudXAiKTsKICAgIGlmKHNpZ251
cCl7CiAgICAgIHZhciBzbXNnPWVsKCJtc2ciKSxzYnRuPWVsKCJzdWJtaXQiKTsKICAgICAgc2ln
bnVwLmFkZEV2ZW50TGlzdGVuZXIoInN1Ym1pdCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2
ZW50RGVmYXVsdCgpO2NsZWFyKHNtc2cpOwogICAgICAgIHZhciBuYW1lPShlbCgibmFtZSIpLnZh
bHVlfHwiIikudHJpbSgpLAogICAgICAgICAgICBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8fCIi
KS50cmltKCksCiAgICAgICAgICAgIHBhc3M9ZWwoInBhc3N3b3JkIikudmFsdWV8fCIiOwogICAg
ICAgIGlmKCFuYW1lfHwhZW1haWx8fCFwYXNzKXtzaG93KHNtc2csIlBsZWFzZSBmaWxsIGluIGV2
ZXJ5IGZpZWxkIHRvIGNvbnRpbnVlLiIpO3JldHVybjt9CiAgICAgICAgaWYocGFzcy5sZW5ndGg8
MTApe3Nob3coc21zZywiVXNlIGF0IGxlYXN0IDEwIGNoYXJhY3RlcnMgZm9yIHlvdXIgcGFzc3dv
cmQuIik7cmV0dXJuO30KICAgICAgICBzYnRuLmRpc2FibGVkPXRydWU7c2J0bi50ZXh0Q29udGVu
dD0iQ3JlYXRpbmfigKYiOwogICAgICAgIGZldGNoKEFQSS5yZWdpc3Rlcix7bWV0aG9kOiJQT1NU
IixoZWFkZXJzOnsiQ29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJhcHBs
aWNhdGlvbi9qc29uIn0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtuYW1lOm5hbWUs
ZW1haWw6ZW1haWwscGFzc3dvcmQ6cGFzc30pfSkKICAgICAgICAudGhlbihmdW5jdGlvbihyKXty
ZXR1cm4gci5qc29uKCkuY2F0Y2goZnVuY3Rpb24oKXtyZXR1cm57fTt9KTt9KQogICAgICAgIC50
aGVuKGZ1bmN0aW9uKGope3Nob3coc21zZyxqLm1lc3NhZ2V8fCJDaGVjayB5b3VyIGluYm94IHRv
IGNvbmZpcm0geW91ciBlbWFpbC4iLHRydWUpO3NpZ251cC5yZXNldCgpO30pCiAgICAgICAgLmNh
dGNoKGZ1bmN0aW9uKCl7c2hvdyhzbXNnLCJDYW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hlY2sg
eW91ciBjb25uZWN0aW9uIGFuZCB0cnkgYWdhaW4uIik7fSkKICAgICAgICAuZmluYWxseShmdW5j
dGlvbigpe3NidG4uZGlzYWJsZWQ9ZmFsc2U7c2J0bi50ZXh0Q29udGVudD0iQ3JlYXRlIGFjY291
bnQiO30pOwogICAgICB9KTsKICAgIH0KCiAgICAvLyBwYXNzd29yZCByZXNldAogICAgdmFyIHJl
c2V0PWVsKCJyZXNldCIpOwogICAgaWYocmVzZXQpewogICAgICB2YXIgcm1zZz1lbCgibXNnIiks
cmJ0bj1lbCgic3VibWl0Iik7CiAgICAgIHJlc2V0LmFkZEV2ZW50TGlzdGVuZXIoInN1Ym1pdCIs
ZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO2NsZWFyKHJtc2cpOwogICAg
ICAgIHZhciBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8fCIiKS50cmltKCk7CiAgICAgICAgaWYo
IWVtYWlsKXtzaG93KHJtc2csIkVudGVyIHRoZSBlbWFpbCBmb3IgeW91ciBhY2NvdW50LiIpO3Jl
dHVybjt9CiAgICAgICAgcmJ0bi5kaXNhYmxlZD10cnVlO3JidG4udGV4dENvbnRlbnQ9IlNlbmRp
bmfigKYiOwogICAgICAgIGZldGNoKEFQSS5yZXNldCx7bWV0aG9kOiJQT1NUIixoZWFkZXJzOnsi
Q29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJhcHBsaWNhdGlvbi9qc29u
In0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtlbWFpbDplbWFpbH0pfSkKICAgICAg
ICAudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCkuY2F0Y2goZnVuY3Rpb24oKXtyZXR1
cm57fTt9KTt9KQogICAgICAgIC50aGVuKGZ1bmN0aW9uKGope3Nob3cocm1zZyxqLm1lc3NhZ2V8
fCJJZiBhbiBhY2NvdW50IGV4aXN0cywgd2Ugc2VudCByZXNldCBpbnN0cnVjdGlvbnMuIix0cnVl
KTtyZXNldC5yZXNldCgpO30pCiAgICAgICAgLmNhdGNoKGZ1bmN0aW9uKCl7c2hvdyhybXNnLCJD
YW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hlY2sgeW91ciBjb25uZWN0aW9uIGFuZCB0cnkgYWdh
aW4uIik7fSkKICAgICAgICAuZmluYWxseShmdW5jdGlvbigpe3JidG4uZGlzYWJsZWQ9ZmFsc2U7
cmJ0bi50ZXh0Q29udGVudD0iU2VuZCByZXNldCBsaW5rIjt9KTsKICAgICAgfSk7CiAgICB9CiAg
fSk7Cn0pKCk7CkRFQ09ZX0FQUEpTCgpjYXQgPiAiJEQvaW5kZXguaHRtbCIgPDwnREVDT1lfSU5E
RVgnCjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0
PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13
aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNvbnRlbnQ9Im5v
aW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJyZWZlcnJlciIgY29udGVudD0ibm8tcmVm
ZXJyZXIiIC8+Cjx0aXRsZT5AQEJSQU5EQEAgQ2xvdWQg4oCUIFNlY3VyZSBzdG9yYWdlIGZvciB5
b3VyIGZpbGVzPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVzY3JpcHRpb24iIGNvbnRlbnQ9IkBAQlJB
TkRAQCBDbG91ZCBrZWVwcyB5b3VyIGRvY3VtZW50cywgcGhvdG9zIGFuZCBiYWNrdXBzIGVuY3J5
cHRlZCBhbmQgYXZhaWxhYmxlIG9uIGV2ZXJ5IGRldmljZS4iIC8+CjxsaW5rIHJlbD0iaWNvbiIg
aHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFwcGxlLXRvdWNoLWljb24iIGhyZWY9
Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVsPSJtYW5pZmVzdCIgaHJlZj0iL2Fz
c2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9InN0eWxlc2hlZXQiIGhyZWY9Ii9h
c3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlcj4KICA8ZGl2IGNsYXNzPSJ3
cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9Ii8iPjxzdmcgY2xhc3M9Im1hcmsi
IHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxyZWN0
IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9IiMzYTViZDkiLz48cGF0aCBkPSJN
MTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1IDUgMCAwIDAtOS41My0xLjRBNCA0
IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2Zz48c3Bhbj5AQEJSQU5EQEAmbmJz
cDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJsaW5rcyI+CiAgICAgIDxhIGhyZWY9
Ii8jZmVhdHVyZXMiIGNsYXNzPSJhY3RpdmUiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhyZWY9Ii9w
cmljaW5nIj5QcmljaW5nPC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9h
PgogICAgICA8YSBocmVmPSIvZG9jcyI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFz
cz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4iPlNpZ24g
aW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVkPC9h
PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAiPgogIDxk
aXYgY2xhc3M9ImdyaWQiPgogICAgPHNlY3Rpb24gY2xhc3M9InBpdGNoIHJldmVhbCIgaWQ9ImZl
YXR1cmVzIj4KICAgICAgPGRpdiBjbGFzcz0iZXllYnJvdyI+RW5jcnlwdGVkIGZpbGUgc3RvcmFn
ZTwvZGl2PgogICAgICA8aDE+WW91ciBmaWxlcywgc2FmZSBhbmQgaW4gc3luYyBldmVyeXdoZXJl
LjwvaDE+CiAgICAgIDxwIGNsYXNzPSJsZWRlIj5AQEJSQU5EQEAgQ2xvdWQga2VlcHMgZG9jdW1l
bnRzLCBwaG90b3MgYW5kIGJhY2t1cHMgZW5jcnlwdGVkIGF0IHJlc3QgYW5kIHJlYWR5IG9uIGV2
ZXJ5IGRldmljZS4gU2hhcmUgYSBsaW5rLCByZXN0b3JlIGEgdmVyc2lvbiwga2VlcCB3b3JraW5n
IG9mZmxpbmUuPC9wPgogICAgICA8dWwgY2xhc3M9ImZlYXQiPgogICAgICAgIDxsaT48c3ZnIHdp
ZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTds
LTUtNSIvPjwvc3ZnPkVuZC10by1lbmQgZW5jcnlwdGlvbiB3aXRoIGNsaWVudC1zaWRlIGtleXM8
L2xpPgogICAgICAgIDxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIy
LjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlZlcnNpb24gaGlzdG9yeSBhbmQg
MzAtZGF5IGZpbGUgcmVjb3Zlcnk8L2xpPgogICAgICAgIDxsaT48c3ZnIHdpZHRoPSIxOCIgaGVp
Z2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3Zn
PkRlc2t0b3AsIG1vYmlsZSBhbmQgd2ViIOKAlCBhdXRvbWF0aWMgc3luYzwvbGk+CiAgICAgIDwv
dWw+CiAgICAgIDxpbWcgY2xhc3M9Imhlcm8taW1nIiBzcmM9Ii9hc3NldHMvaGVyby5zdmciIGFs
dD0iRmlsZXMgc3luY2VkIHRvIHRoZSBjbG91ZCIgd2lkdGg9IjQ2MCIgaGVpZ2h0PSIzMjAiIC8+
CiAgICAgIDxkaXYgY2xhc3M9InRydXN0Ij4KICAgICAgICA8c3ZnIHdpZHRoPSIxNiIgaGVpZ2h0
PSIxNiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xv
ciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNMTIgMjJzOC00IDgtMTBWNWwtOC0zLTggM3Y3
YzAgNiA4IDEwIDggMTBaIi8+PC9zdmc+CiAgICAgICAgRGF0YSBjZW50ZXJzIGluIHRoZSBFVSDC
tyA5OS45JSB1cHRpbWUKICAgICAgPC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPHNlY3Rpb24g
Y2xhc3M9ImF1dGggcmV2ZWFsIGQyIiBpZD0ic2lnbmluIj4KICAgICAgPGRpdiBjbGFzcz0iY2Fy
ZCI+CiAgICAgICAgPGgyPlNpZ24gaW48L2gyPgogICAgICAgIDxwIGNsYXNzPSJzdWIiPldlbGNv
bWUgYmFjay4gVXNlIHlvdXIgQEBCUkFOREBAIENsb3VkIGFjY291bnQuPC9wPgogICAgICAgIDxk
aXYgY2xhc3M9Im1zZyIgaWQ9Im1zZyIgcm9sZT0iYWxlcnQiPjwvZGl2PgogICAgICAgIDxmb3Jt
IGlkPSJsb2dpbiIgbm92YWxpZGF0ZT4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAg
ICAgICAgICAgPGxhYmVsIGZvcj0iZW1haWwiPkVtYWlsPC9sYWJlbD4KICAgICAgICAgICAgPGlu
cHV0IGlkPSJlbWFpbCIgbmFtZT0iZW1haWwiIHR5cGU9ImVtYWlsIiBhdXRvY29tcGxldGU9InVz
ZXJuYW1lIiBwbGFjZWhvbGRlcj0ieW91QGV4YW1wbGUuY29tIiByZXF1aXJlZCAvPgogICAgICAg
ICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgICAgICAgIDxsYWJl
bCBmb3I9InBhc3N3b3JkIj5QYXNzd29yZDwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBpZD0i
cGFzc3dvcmQiIG5hbWU9InBhc3N3b3JkIiB0eXBlPSJwYXNzd29yZCIgYXV0b2NvbXBsZXRlPSJj
dXJyZW50LXBhc3N3b3JkIiBwbGFjZWhvbGRlcj0i4oCi4oCi4oCi4oCi4oCi4oCi4oCi4oCiIiBy
ZXF1aXJlZCAvPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyb3ciPgog
ICAgICAgICAgICA8bGFiZWwgY2xhc3M9InJlbWVtYmVyIj48aW5wdXQgdHlwZT0iY2hlY2tib3gi
IG5hbWU9InJlbWVtYmVyIiAvPiBLZWVwIG1lIHNpZ25lZCBpbjwvbGFiZWw+CiAgICAgICAgICAg
IDxhIGNsYXNzPSJsaW5rIiBocmVmPSIvcmVzZXQiPkZvcmdvdCBwYXNzd29yZD88L2E+CiAgICAg
ICAgICA8L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBibG9jayIgdHlwZT0ic3Vi
bWl0IiBpZD0ic3VibWl0Ij5TaWduIGluPC9idXR0b24+CiAgICAgICAgPC9mb3JtPgogICAgICAg
IDxkaXYgY2xhc3M9ImRpdmlkZXIiPm9yPC9kaXY+CiAgICAgICAgPHAgY2xhc3M9ImFsdCI+TmV3
IHRvIEBAQlJBTkRAQCBDbG91ZD8gPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9zaWdudXAiPkNyZWF0
ZSBhbiBhY2NvdW50PC9hPjwvcD4KICAgICAgPC9kaXY+CiAgICA8L3NlY3Rpb24+CiAgPC9kaXY+
CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xh
c3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0i
c3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxh
IGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0
YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhy
ZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9h
PgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFO
REBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9h
cHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfSU5ERVgKCmNhdCA+
ICIkRC9wcmljaW5nLmh0bWwiIDw8J0RFQ09ZX1BSSUNJTkcnCjwhRE9DVFlQRSBodG1sPgo8aHRt
bCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0i
dmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAv
Pgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNvbnRlbnQ9Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0
YSBuYW1lPSJyZWZlcnJlciIgY29udGVudD0ibm8tcmVmZXJyZXIiIC8+Cjx0aXRsZT5QcmljaW5n
IOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29u
dGVudD0iQEBCUkFOREBAIENsb3VkIHByaWNpbmcg4oCUIGZyZWUsIFBsdXMgYW5kIEJ1c2luZXNz
IHBsYW5zIHdpdGggZW5kLXRvLWVuZCBlbmNyeXB0aW9uLiIgLz4KPGxpbmsgcmVsPSJpY29uIiBo
cmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0i
L2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNz
ZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fz
c2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9Indy
YXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIg
dmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qg
d2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0x
MC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQg
MCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNw
O0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0i
LyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciIGNsYXNzPSJh
Y3RpdmUiPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+
CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNz
PSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBp
bjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+
CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1h
aW4iPgogIDxkaXYgY2xhc3M9InBhZ2UtaGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5Q
cmljaW5nPC9kaXY+CiAgICA8aDE+U2ltcGxlIHBsYW5zIHRoYXQgc2NhbGUgd2l0aCB5b3UuPC9o
MT4KICAgIDxwPlN0YXJ0IGZyZWUuIFVwZ3JhZGUgd2hlbiB5b3UgbmVlZCBtb3JlIHNwYWNlIG9y
IHRlYW0gZmVhdHVyZXMuIEFsbCBwbGFucyBpbmNsdWRlIGVuZC10by1lbmQgZW5jcnlwdGlvbi48
L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icHJpY2luZyI+CiAgICA8ZGl2IGNsYXNzPSJ0aWVy
Ij48aDM+RnJlZTwvaDM+PGRpdiBjbGFzcz0icHJpY2UiPuKCrDA8c3Bhbj4vbW88L3NwYW4+PC9k
aXY+PHVsPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxw
YXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPjUgR0IgZW5jcnlwdGVkIHN0b3JhZ2U8L2xp
PjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9
Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlN5bmMgb24gMiBkZXZpY2VzPC9saT48bGk+PHN2ZyB3
aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ry
b2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3
bC01LTUiLz48L3N2Zz4zMC1kYXkgZmlsZSByZWNvdmVyeTwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4
IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+
PC9zdmc+TGluayBzaGFyaW5nPC9saT48L3VsPjxhIGNsYXNzPSJidG4gYmxvY2siIGhyZWY9Ii9z
aWdudXAiPkNvbnRhY3QgdXM8L2E+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ0aWVyIGZlYXQtdGll
ciI+PHNwYW4gY2xhc3M9InRhZyI+TW9zdCBwb3B1bGFyPC9zcGFuPjxoMz5QbHVzPC9oMz48ZGl2
IGNsYXNzPSJwcmljZSI+4oKsNDxzcGFuPi9tbzwvc3Bhbj48L2Rpdj48dWw+PGxpPjxzdmcgd2lk
dGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9r
ZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wt
NS01Ii8+PC9zdmc+MjAwIEdCIGVuY3J5cHRlZCBzdG9yYWdlPC9saT48bGk+PHN2ZyB3aWR0aD0i
MTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJj
dXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUi
Lz48L3N2Zz5VbmxpbWl0ZWQgZGV2aWNlczwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9
IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9y
IiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+VmVy
c2lvbiBoaXN0b3J5PC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0
aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5QYXNzd29yZC1wcm90ZWN0
ZWQgbGlua3M8L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIy
LjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlByaW9yaXR5IHN1cHBvcnQ8L2xp
PjwvdWw+PGEgY2xhc3M9ImJ0biBibG9jayIgaHJlZj0iL3NpZ251cCI+Q29udGFjdCB1czwvYT48
L2Rpdj4KICAgIDxkaXYgY2xhc3M9InRpZXIiPjxoMz5CdXNpbmVzczwvaDM+PGRpdiBjbGFzcz0i
cHJpY2UiPuKCrDEyPHNwYW4+L3VzZXIvbW88L3NwYW4+PC9kaXY+PHVsPjxsaT48c3ZnIHdpZHRo
PSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9
ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUt
NSIvPjwvc3ZnPjIgVEIgcGVyIHVzZXI8L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIx
OCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIg
c3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlRlYW0g
Zm9sZGVycyAmIHJvbGVzPC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdC
b3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5BZG1pbiBjb25zb2xl
ICYgYXVkaXQgbG9nPC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0
aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5TU08gLyBTQU1MPC9saT48
bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0i
bm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJN
MjAgNiA5IDE3bC01LTUiLz48L3N2Zz45OS45JSB1cHRpbWUgU0xBPC9saT48L3VsPjxhIGNsYXNz
PSJidG4gYmxvY2siIGhyZWY9Ii9zaWdudXAiPkNvbnRhY3QgdXM8L2E+PC9kaXY+CiAgPC9kaXY+
CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xh
c3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0i
c3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxh
IGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0
YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhy
ZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9h
PgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFO
REBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9h
cHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfUFJJQ0lORwoKY2F0
ID4gIiREL3NlY3VyaXR5Lmh0bWwiIDw8J0RFQ09ZX1NFQ1VSSVRZJwo8IURPQ1RZUEUgaHRtbD4K
PGh0bWwgbGFuZz0iZW4iPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5h
bWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9
MSIgLz4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4K
PG1ldGEgbmFtZT0icmVmZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+U2Vj
dXJpdHkg4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9u
IiBjb250ZW50PSJIb3cgQEBCUkFOREBAIENsb3VkIGVuY3J5cHRzIGFuZCBwcm90ZWN0cyB5b3Vy
IGZpbGVzOiBjbGllbnQtc2lkZSBrZXlzLCBBRVMtMjU2LCBUTFMgMS4zLCBFVSBkYXRhIGNlbnRl
cnMuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVs
PSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5r
IHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsg
cmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+
CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBo
cmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUi
IGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBm
aWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYu
OTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+
PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFz
cz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8
YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5IiBj
bGFzcz0iYWN0aXZlIj5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+
CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hv
c3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVm
PSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4K
CjxtYWluIGNsYXNzPSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFkIj4K
ICAgIDxkaXYgY2xhc3M9ImV5ZWJyb3ciPlNlY3VyaXR5PC9kaXY+CiAgICA8aDE+WW91ciBkYXRh
LCBlbmNyeXB0ZWQgZW5kIHRvIGVuZC48L2gxPgogICAgPHA+U2VjdXJpdHkgaXMgdGhlIGRlZmF1
bHQsIG5vdCBhbiBhZGQtb24uIEhlcmUgaXMgaG93IEBAQlJBTkRAQCBDbG91ZCBwcm90ZWN0cyB5
b3VyIGZpbGVzLjwvcD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJwcm9zZSI+CiAgICA8aDI+RW5j
cnlwdGlvbjwvaDI+CiAgICA8cD5GaWxlcyBhcmUgZW5jcnlwdGVkIG9uIHlvdXIgZGV2aWNlIGJl
Zm9yZSB0aGV5IGFyZSB1cGxvYWRlZC4gRW5jcnlwdGlvbiBrZXlzIGFyZSBkZXJpdmVkIGZyb20g
eW91ciBwYXNzd29yZCBhbmQgbmV2ZXIgbGVhdmUgeW91ciBkZXZpY2VzIGluIHBsYWludGV4dCwg
c28gd2UgY2Fubm90IHJlYWQgeW91ciBjb250ZW50LiBEYXRhIGF0IHJlc3QgaXMgc3RvcmVkIHdp
dGggQUVTLTI1NiBhbmQgYWxsIHRyYW5zcG9ydCBpcyBwcm90ZWN0ZWQgd2l0aCBUTFMgMS4zLjwv
cD4KICAgIDxoMj5JbmZyYXN0cnVjdHVyZTwvaDI+CiAgICA8cD5TdG9yYWdlIGFuZCBwcm9jZXNz
aW5nIHJ1biBpbiBJU08gMjcwMDEtY2VydGlmaWVkIGRhdGEgY2VudGVycyBpbiB0aGUgRXVyb3Bl
YW4gVW5pb24uIE9iamVjdCBzdG9yYWdlIGlzIHJlcGxpY2F0ZWQgYWNyb3NzIGF2YWlsYWJpbGl0
eSB6b25lcywgYW5kIGRlbGV0ZWQgZmlsZXMgcmVtYWluIHJlY292ZXJhYmxlIGZvciAzMCBkYXlz
IGJlZm9yZSB0aGV5IGFyZSBwdXJnZWQuPC9wPgogICAgPGgyPkFjY2VzcyAmYW1wOyBhY2NvdW50
czwvaDI+CiAgICA8dWw+CiAgICAgIDxsaT5PcHRpb25hbCB0d28tZmFjdG9yIGF1dGhlbnRpY2F0
aW9uIChUT1RQIGFuZCBzZWN1cml0eSBrZXlzKS48L2xpPgogICAgICA8bGk+U2Vzc2lvbiBhbmQg
ZGV2aWNlIG1hbmFnZW1lbnQgd2l0aCByZW1vdGUgc2lnbi1vdXQuPC9saT4KICAgICAgPGxpPlJh
dGUtbGltaXRlZCBhdXRoZW50aWNhdGlvbiBhbmQgYW5vbWFseSBhbGVydHMgb24gbmV3IHNpZ24t
aW5zLjwvbGk+CiAgICA8L3VsPgogICAgPGgyPlJlc3BvbnNpYmxlIGRpc2Nsb3N1cmU8L2gyPgog
ICAgPHA+Rm91bmQgc29tZXRoaW5nPyBXZSB3ZWxjb21lIHJlcG9ydHMgZnJvbSBzZWN1cml0eSBy
ZXNlYXJjaGVycy4gUmVhY2ggdXMgYXQgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Im1haWx0bzpzZWN1
cml0eUBAQE1BSU5fRE9NQUlOQEAiPnNlY3VyaXR5QEBATUFJTl9ET01BSU5AQDwvYT4g4oCUIHNl
ZSBhbHNvIG91ciA8YSBjbGFzcz0ibGluayIgaHJlZj0iLy53ZWxsLWtub3duL3NlY3VyaXR5LnR4
dCI+c2VjdXJpdHkudHh0PC9hPi48L3A+CiAgICA8cCBjbGFzcz0ibXV0ZWQiPkxhc3QgcmV2aWV3
ZWQ6IE5vdmVtYmVyIDIwMjUuPC9wPgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxkaXYg
Y2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNzPSJk
b3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPigKY8
L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5
PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9w
cml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9hPgogICAg
ICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRpdj7CqSA8
c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2Pgo8
L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9i
b2R5Pgo8L2h0bWw+CkRFQ09ZX1NFQ1VSSVRZCgpjYXQgPiAiJEQvcHJpdmFjeS5odG1sIiA8PCdE
RUNPWV9QUklWQUNZJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0iZW4iPgo8aGVhZD4KPG1l
dGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0
aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIgLz4KPG1ldGEgbmFtZT0icm9ib3RzIiBj
b250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1ldGEgbmFtZT0icmVmZXJyZXIiIGNvbnRl
bnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+UHJpdmFjeSBQb2xpY3kg4oCUIEBAQlJBTkRAQCBD
bG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJSQU5EQEAg
Q2xvdWQgcHJpdmFjeSBwb2xpY3kuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29u
LmljbyIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gt
aWNvbi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJt
YW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3Mi
IC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAg
PGEgY2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAg
MzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhl
aWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEz
LjUgMy41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIx
LjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+
PC9hPgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Q
cm9kdWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEg
aHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8
L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0i
Z2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBo
cmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRl
cj4KCjxtYWluIGNsYXNzPSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFk
Ij4KICAgIDxkaXYgY2xhc3M9ImV5ZWJyb3ciPkxlZ2FsPC9kaXY+CiAgICA8aDE+UHJpdmFjeSBQ
b2xpY3k8L2gxPgogICAgPHA+SG93IHdlIGhhbmRsZSB5b3VyIGRhdGEuIFRoaXMgc3VtbWFyeSBl
eHBsYWlucyB3aGF0IHdlIGNvbGxlY3QgYW5kIHdoeS48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFz
cz0icHJvc2UiPgogICAgPGgyPkluZm9ybWF0aW9uIHdlIGNvbGxlY3Q8L2gyPgogICAgPHA+QWNj
b3VudCBkZXRhaWxzIHlvdSBwcm92aWRlIChuYW1lLCBlbWFpbCksIGFuZCB0ZWNobmljYWwgZGF0
YSBuZWVkZWQgdG8gcnVuIHRoZSBzZXJ2aWNlIChkZXZpY2UgdHlwZSwgSVAgYWRkcmVzcywgbG9n
IHRpbWVzdGFtcHMpLiBZb3VyIGZpbGVzIGFyZSBlbmNyeXB0ZWQgd2l0aCBrZXlzIHdlIGRvIG5v
dCBob2xkLCBzbyB3ZSBjYW5ub3QgYWNjZXNzIHRoZWlyIGNvbnRlbnRzLjwvcD4KICAgIDxoMj5I
b3cgd2UgdXNlIGl0PC9oMj4KICAgIDxwPlRvIHByb3ZpZGUgYW5kIHNlY3VyZSB0aGUgc2Vydmlj
ZSwgdG8gY29tbXVuaWNhdGUgYWJvdXQgeW91ciBhY2NvdW50LCBhbmQgdG8gY29tcGx5IHdpdGgg
bGVnYWwgb2JsaWdhdGlvbnMuIFdlIGRvIG5vdCBzZWxsIHBlcnNvbmFsIGRhdGEgb3IgdXNlIGZp
bGUgY29udGVudHMgZm9yIGFkdmVydGlzaW5nLjwvcD4KICAgIDxoMj5TdG9yYWdlICZhbXA7IGVu
Y3J5cHRpb248L2gyPgogICAgPHA+RGF0YSBpcyBzdG9yZWQgaW4gdGhlIEV1cm9wZWFuIFVuaW9u
IGFuZCBlbmNyeXB0ZWQgYXQgcmVzdC4gQmFja3VwcyBhcmUgcmV0YWluZWQgZm9yIGRpc2FzdGVy
IHJlY292ZXJ5IGFuZCByb3RhdGVkIG9uIGEgZml4ZWQgc2NoZWR1bGUuPC9wPgogICAgPGgyPllv
dXIgcmlnaHRzPC9oMj4KICAgIDx1bD4KICAgICAgPGxpPkFjY2VzcywgY29ycmVjdCBvciBleHBv
cnQgeW91ciBkYXRhLjwvbGk+CiAgICAgIDxsaT5EZWxldGUgeW91ciBhY2NvdW50IGFuZCBhc3Nv
Y2lhdGVkIGZpbGVzLjwvbGk+CiAgICAgIDxsaT5PYmplY3QgdG8gb3IgcmVzdHJpY3QgY2VydGFp
biBwcm9jZXNzaW5nLjwvbGk+CiAgICA8L3VsPgogICAgPGgyPkNvbnRhY3Q8L2gyPgogICAgPHA+
UXVlc3Rpb25zIGFib3V0IHByaXZhY3k6IDxhIGNsYXNzPSJsaW5rIiBocmVmPSJtYWlsdG86cHJp
dmFjeUBAQE1BSU5fRE9NQUlOQEAiPnByaXZhY3lAQEBNQUlOX0RPTUFJTkBAPC9hPi48L3A+CiAg
ICA8cCBjbGFzcz0ibXV0ZWQiPkxhc3QgdXBkYXRlZDogTm92ZW1iZXIgMjAyNS48L3A+CiAgPC9k
aXY+CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYg
Y2xhc3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBp
ZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAg
IDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMi
PlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxh
IGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0
PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBC
UkFOREBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0
cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfUFJJVkFDWQoK
Y2F0ID4gIiREL3Rlcm1zLmh0bWwiIDw8J0RFQ09ZX1RFUk1TJwo8IURPQ1RZUEUgaHRtbD4KPGh0
bWwgbGFuZz0iZW4iPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9
InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIg
Lz4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1l
dGEgbmFtZT0icmVmZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+VGVybXMg
b2YgU2VydmljZSDigJQgQEBCUkFOREBAIENsb3VkPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVzY3Jp
cHRpb24iIGNvbnRlbnQ9IkBAQlJBTkRAQCBDbG91ZCB0ZXJtcyBvZiBzZXJ2aWNlLiIgLz4KPGxp
bmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91
Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlm
ZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVz
aGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgog
IDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2
ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRl
bj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJk
OSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAg
MC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFu
PkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4K
ICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3By
aWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+
CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNz
PSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBp
bjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+
CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1h
aW4iPgogIDxkaXYgY2xhc3M9InBhZ2UtaGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5M
ZWdhbDwvZGl2PgogICAgPGgxPlRlcm1zIG9mIFNlcnZpY2U8L2gxPgogICAgPHA+VGhlIHJ1bGVz
IGZvciB1c2luZyBAQEJSQU5EQEAgQ2xvdWQuIEJ5IHVzaW5nIHRoZSBzZXJ2aWNlIHlvdSBhZ3Jl
ZSB0byB0aGVzZSB0ZXJtcy48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icHJvc2UiPgogICAg
PGgyPjEuIEFjY291bnRzPC9oMj4KICAgIDxwPllvdSBhcmUgcmVzcG9uc2libGUgZm9yIGFjdGl2
aXR5IHVuZGVyIHlvdXIgYWNjb3VudCBhbmQgZm9yIGtlZXBpbmcgeW91ciBjcmVkZW50aWFscyBz
ZWN1cmUuIFlvdSBtdXN0IGJlIG9sZCBlbm91Z2ggdG8gZm9ybSBhIGJpbmRpbmcgY29udHJhY3Qg
aW4geW91ciBjb3VudHJ5LjwvcD4KICAgIDxoMj4yLiBBY2NlcHRhYmxlIHVzZTwvaDI+CiAgICA8
cD5EbyBub3QgdXNlIHRoZSBzZXJ2aWNlIHRvIHN0b3JlIG9yIGRpc3RyaWJ1dGUgdW5sYXdmdWwg
Y29udGVudCwgdG8gaW5mcmluZ2Ugb3RoZXJzJyByaWdodHMsIG9yIHRvIGRpc3J1cHQgdGhlIHNl
cnZpY2UuIFdlIG1heSBzdXNwZW5kIGFjY291bnRzIHRoYXQgdmlvbGF0ZSB0aGVzZSB0ZXJtcy48
L3A+CiAgICA8aDI+My4gQXZhaWxhYmlsaXR5PC9oMj4KICAgIDxwPldlIGFpbSBmb3IgaGlnaCBh
dmFpbGFiaWxpdHkgYnV0IHRoZSBzZXJ2aWNlIGlzIHByb3ZpZGVkICJhcyBpcyIuIFBsYW5uZWQg
bWFpbnRlbmFuY2UgaXMgYW5ub3VuY2VkIG9uIHRoZSBzdGF0dXMgcGFnZSB3aGVyZSBwcmFjdGlj
YWwuPC9wPgogICAgPGgyPjQuIExpbWl0YXRpb24gb2YgbGlhYmlsaXR5PC9oMj4KICAgIDxwPlRv
IHRoZSBleHRlbnQgcGVybWl0dGVkIGJ5IGxhdywgd2UgYXJlIG5vdCBsaWFibGUgZm9yIGluZGly
ZWN0IG9yIGNvbnNlcXVlbnRpYWwgZGFtYWdlcy4gS2VlcCB5b3VyIG93biBiYWNrdXBzIG9mIGNy
aXRpY2FsIGRhdGEuPC9wPgogICAgPGgyPjUuIENoYW5nZXM8L2gyPgogICAgPHA+V2UgbWF5IHVw
ZGF0ZSB0aGVzZSB0ZXJtczsgbWF0ZXJpYWwgY2hhbmdlcyB3aWxsIGJlIGNvbW11bmljYXRlZCBi
eSBlbWFpbCBvciBpbi1hcHAgbm90aWNlLjwvcD4KICAgIDxoMj5Db250YWN0PC9oMj4KICAgIDxw
PlF1ZXN0aW9uczogPGEgY2xhc3M9ImxpbmsiIGhyZWY9Im1haWx0bzpsZWdhbEBAQE1BSU5fRE9N
QUlOQEAiPmxlZ2FsQEBATUFJTl9ET01BSU5AQDwvYT4uPC9wPgogICAgPHAgY2xhc3M9Im11dGVk
Ij5MYXN0IHVwZGF0ZWQ6IE5vdmVtYmVyIDIwMjUuPC9wPgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9v
dGVyPgogIDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxz
cGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2lu
ZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJp
dHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAg
IDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRl
cm1zPC9hPgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2Pgog
ICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2
PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48
L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1RFUk1TCgpjYXQgPiAiJEQvc3RhdHVzLmh0
bWwiIDw8J0RFQ09ZX1NUQVRVUycKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhl
YWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVu
dD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJv
Ym90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVy
IiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlN5c3RlbSBTdGF0dXMg4oCUIEBAQlJB
TkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJMaXZl
IHN0YXR1cyBvZiBAQEJSQU5EQEAgQ2xvdWQgY29tcG9uZW50cy4iIC8+CjxsaW5rIHJlbD0iaWNv
biIgaHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFwcGxlLXRvdWNoLWljb24iIGhy
ZWY9Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVsPSJtYW5pZmVzdCIgaHJlZj0i
L2Fzc2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9InN0eWxlc2hlZXQiIGhyZWY9
Ii9hc3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlcj4KICA8ZGl2IGNsYXNz
PSJ3cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9Ii8iPjxzdmcgY2xhc3M9Im1h
cmsiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxy
ZWN0IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9IiMzYTViZDkiLz48cGF0aCBk
PSJNMTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1IDUgMCAwIDAtOS41My0xLjRB
NCA0IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2Zz48c3Bhbj5AQEJSQU5EQEAm
bmJzcDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJsaW5rcyI+CiAgICAgIDxhIGhy
ZWY9Ii8jZmVhdHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcmljaW5nIj5Qcmlj
aW5nPC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBo
cmVmPSIvZG9jcyI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0ibmF2LWN0YSI+
CiAgICAgIDxhIGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4iPlNpZ24gaW48L2E+CiAgICAg
IDxhIGNsYXNzPSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVkPC9hPgogICAgPC9kaXY+
CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAgcGFnZS1tYWluIj4KICA8ZGl2
IGNsYXNzPSJwYWdlLWhlYWQiPgogICAgPGRpdiBjbGFzcz0iZXllYnJvdyI+U3lzdGVtIFN0YXR1
czwvZGl2PgogICAgPGgxPkN1cnJlbnQgc2VydmljZSBzdGF0dXM8L2gxPgogICAgPHA+TGl2ZSBz
dGF0dXMgb2YgQEBCUkFOREBAIENsb3VkIGNvbXBvbmVudHMuIFN1YnNjcmliZSB0byB1cGRhdGVz
IG9uIHRoZSA8YSBjbGFzcz0ibGluayIgaHJlZj0iL3N1cHBvcnQiPnN1cHBvcnQgcGFnZTwvYT4u
PC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InByb3NlIiBzdHlsZT0ibWF4LXdpZHRoOjcyMHB4
Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cy1iYW5uZXIiPjxzcGFuIGNsYXNzPSJkb3Qgb2siPjwv
c3Bhbj4gQWxsIHN5c3RlbXMgb3BlcmF0aW9uYWw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNvbXAi
PjxzcGFuPkFQSTwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bh
bj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNvbXAiPjxzcGFuPldl
YiBhcHA8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+T3Bl
cmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjb21wIj48c3Bhbj5GaWxlIHN5
bmM8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+T3BlcmF0
aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjb21wIj48c3Bhbj5PYmplY3Qgc3Rv
cmFnZTwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj5PcGVy
YXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNvbXAiPjxzcGFuPkF1dGhlbnRp
Y2F0aW9uPC9zcGFuPjxzcGFuIGNsYXNzPSJvcCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPk9w
ZXJhdGlvbmFsPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY29tcCI+PHNwYW4+U2hhcmlu
ZyAmYW1wOyBsaW5rczwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNsYXNzPSJkb3QiPjwv
c3Bhbj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxwIGNsYXNzPSJtdXRlZCI+VXB0aW1l
IG92ZXIgdGhlIGxhc3QgOTAgZGF5czogOTkuOTclLiBUaW1lcyBzaG93biBpbiBVVEMuPC9wPgog
IDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8
ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNw
YW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2Pgog
ICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3Rh
dHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAg
ICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3Vw
cG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+
IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9h
c3NldHMvYXBwLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1NUQVRV
UwoKY2F0ID4gIiREL2RvY3MuaHRtbCIgPDwnREVDT1lfRE9DUycKPCFET0NUWVBFIGh0bWw+Cjxo
dG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1l
PSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEi
IC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+Cjxt
ZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPkRvY3Mg
4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250
ZW50PSJAQEJSQU5EQEAgQ2xvdWQgZG9jdW1lbnRhdGlvbjogZ2V0dGluZyBzdGFydGVkLCB1cGxv
YWRzLCBzaGFyaW5nLCBzeW5jIGNsaWVudHMgYW5kIEFQSS4iIC8+CjxsaW5rIHJlbD0iaWNvbiIg
aHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFwcGxlLXRvdWNoLWljb24iIGhyZWY9
Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVsPSJtYW5pZmVzdCIgaHJlZj0iL2Fz
c2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9InN0eWxlc2hlZXQiIGhyZWY9Ii9h
c3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlcj4KICA8ZGl2IGNsYXNzPSJ3
cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9Ii8iPjxzdmcgY2xhc3M9Im1hcmsi
IHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxyZWN0
IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9IiMzYTViZDkiLz48cGF0aCBkPSJN
MTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1IDUgMCAwIDAtOS41My0xLjRBNCA0
IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2Zz48c3Bhbj5AQEJSQU5EQEAmbmJz
cDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJsaW5rcyI+CiAgICAgIDxhIGhyZWY9
Ii8jZmVhdHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcmljaW5nIj5QcmljaW5n
PC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVm
PSIvZG9jcyIgY2xhc3M9ImFjdGl2ZSI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFz
cz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4iPlNpZ24g
aW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVkPC9h
PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAgcGFnZS1t
YWluIj4KICA8ZGl2IGNsYXNzPSJwYWdlLWhlYWQiPgogICAgPGRpdiBjbGFzcz0iZXllYnJvdyI+
RG9jczwvZGl2PgogICAgPGgxPkRvY3VtZW50YXRpb248L2gxPgogICAgPHA+RXZlcnl0aGluZyB5
b3UgbmVlZCB0byBnZXQgdGhlIG1vc3Qgb3V0IG9mIEBAQlJBTkRAQCBDbG91ZC48L3A+CiAgPC9k
aXY+CiAgPGRpdiBjbGFzcz0iZG9jcyI+CiAgICA8bmF2IGNsYXNzPSJ0b2MiPgogICAgICA8YSBo
cmVmPSIjc3RhcnQiPkdldHRpbmcgc3RhcnRlZDwvYT4KICAgICAgPGEgaHJlZj0iI3VwbG9hZCI+
VXBsb2FkaW5nIGZpbGVzPC9hPgogICAgICA8YSBocmVmPSIjc2hhcmUiPlNoYXJpbmc8L2E+CiAg
ICAgIDxhIGhyZWY9IiNzeW5jIj5TeW5jIGNsaWVudHM8L2E+CiAgICAgIDxhIGhyZWY9IiNhcGki
PkFQSTwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0icHJvc2UiPgogICAgICA8aDIgaWQ9
InN0YXJ0Ij5HZXR0aW5nIHN0YXJ0ZWQ8L2gyPgogICAgICA8cD5DcmVhdGUgYW4gYWNjb3VudCwg
aW5zdGFsbCB0aGUgZGVza3RvcCBvciBtb2JpbGUgYXBwLCBhbmQgeW91ciBmaWxlcyBiZWdpbiBz
eW5jaW5nIGF1dG9tYXRpY2FsbHkuIFRoZSB3ZWIgYXBwIGlzIGF2YWlsYWJsZSBmcm9tIGFueSBi
cm93c2VyIHdpdGhvdXQgaW5zdGFsbGF0aW9uLjwvcD4KICAgICAgPGgyIGlkPSJ1cGxvYWQiPlVw
bG9hZGluZyBmaWxlczwvaDI+CiAgICAgIDxwPkRyYWcgZmlsZXMgaW50byB0aGUgd2ViIGFwcCBv
ciBkcm9wIHRoZW0gaW50byB5b3VyIHN5bmNlZCBmb2xkZXIuIFVwbG9hZHMgYXJlIGVuY3J5cHRl
ZCBvbiB5b3VyIGRldmljZSBiZWZvcmUgdGhleSBsZWF2ZSBpdC4gTGFyZ2UgZmlsZXMgYXJlIGNo
dW5rZWQgYW5kIHJlc3VtYWJsZS48L3A+CiAgICAgIDxoMiBpZD0ic2hhcmUiPlNoYXJpbmc8L2gy
PgogICAgICA8cD5DcmVhdGUgYSBzaGFyZSBsaW5rIGZvciBhbnkgZmlsZSBvciBmb2xkZXIuIExp
bmtzIGNhbiBiZSBwYXNzd29yZC1wcm90ZWN0ZWQgYW5kIGdpdmVuIGFuIGV4cGlyeSBkYXRlLiBS
ZXZva2UgYWNjZXNzIGF0IGFueSB0aW1lIGZyb20gdGhlIGZpbGUgbWVudS48L3A+CiAgICAgIDxo
MiBpZD0ic3luYyI+U3luYyBjbGllbnRzPC9oMj4KICAgICAgPHVsPgogICAgICAgIDxsaT5EZXNr
dG9wOiBXaW5kb3dzLCBtYWNPUywgTGludXguPC9saT4KICAgICAgICA8bGk+TW9iaWxlOiBpT1Mg
YW5kIEFuZHJvaWQuPC9saT4KICAgICAgICA8bGk+V2ViOiBhbnkgbW9kZXJuIGJyb3dzZXIuPC9s
aT4KICAgICAgPC91bD4KICAgICAgPGgyIGlkPSJhcGkiPkFQSTwvaDI+CiAgICAgIDxwPkF1dG9t
YXRlIHVwbG9hZHMgYW5kIGFjY291bnQgdGFza3Mgd2l0aCB0aGUgUkVTVCBBUEkuIEF1dGhlbnRp
Y2F0ZSB3aXRoIGEgcGVyc29uYWwgdG9rZW4gZnJvbSB5b3VyIGFjY291bnQgc2V0dGluZ3MuIEZ1
bGwgcmVmZXJlbmNlIGlzIGF2YWlsYWJsZSB0byBzaWduZWQtaW4gdXNlcnMuPC9wPgogICAgICA8
cCBjbGFzcz0ibXV0ZWQiPk5lZWQgaGVscD8gVmlzaXQgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9z
dXBwb3J0Ij5TdXBwb3J0PC9hPi48L3A+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9tYWluPgoKPGZv
b3Rlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48
c3BhbiBjbGFzcz0iZG90IiBpZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tp
bmcgc3RhdHVz4oCmPC9zcGFuPjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3Vy
aXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAg
ICA8YSBocmVmPSIvcHJpdmFjeSI+UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5U
ZXJtczwvYT4KICAgICAgPGEgaHJlZj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4K
ICAgIDxkaXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rp
dj4KICA8L2Rpdj4KPC9mb290ZXI+CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+
PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgpERUNPWV9ET0NTCgpjYXQgPiAiJEQvc2lnbnVwLmh0
bWwiIDw8J0RFQ09ZX1NJR05VUCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhl
YWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVu
dD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJv
Ym90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVy
IiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPkNyZWF0ZSB5b3VyIGFjY291bnQg4oCU
IEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50
PSJDcmVhdGUgYW4gQEBCUkFOREBAIENsb3VkIGFjY291bnQg4oCUIDUgR0IgZnJlZSwgZW5kLXRv
LWVuZCBlbmNyeXB0ZWQuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIg
Lz4KPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5w
bmciIC8+CjxsaW5rIHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVz
dCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+Cjwv
aGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xh
c3M9ImJyYW5kIiBocmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIi
IGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0i
MzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41
IDAgMCAwIC40LTYuOTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBm
aWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgog
ICAgPG5hdiBjbGFzcz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0
PC9hPgogICAgICA8YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0i
L3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+CiAg
ICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3Qi
IGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVmPSIv
c2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4KCjxt
YWluIGNsYXNzPSJ3cmFwIj4KICA8c2VjdGlvbiBjbGFzcz0iYXV0aCIgc3R5bGU9ImdyaWQtY29s
dW1uOjEvLTEiPgogICAgPGRpdiBjbGFzcz0iY2FyZCBjZW50ZXItY2FyZCI+CiAgICAgIDxoMj5D
cmVhdGUgeW91ciBhY2NvdW50PC9oMj4KICAgICAgPHAgY2xhc3M9InN1YiI+U3RhcnQgd2l0aCA1
IEdCIGZyZWUuIE5vIGNyZWRpdCBjYXJkIHJlcXVpcmVkLjwvcD4KICAgICAgPGRpdiBjbGFzcz0i
bXNnIiBpZD0ibXNnIiByb2xlPSJhbGVydCI+PC9kaXY+CiAgICAgIDxmb3JtIGlkPSJzaWdudXAi
IG5vdmFsaWRhdGU+CiAgICAgICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICAgICAgPGxhYmVs
IGZvcj0ibmFtZSI+TmFtZTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgaWQ9Im5hbWUiIG5hbWU9
Im5hbWUiIHR5cGU9InRleHQiIGF1dG9jb21wbGV0ZT0ibmFtZSIgcGxhY2Vob2xkZXI9IllvdXIg
bmFtZSIgcmVxdWlyZWQgLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmaWVs
ZCI+CiAgICAgICAgICA8bGFiZWwgZm9yPSJlbWFpbCI+RW1haWw8L2xhYmVsPgogICAgICAgICAg
PGlucHV0IGlkPSJlbWFpbCIgbmFtZT0iZW1haWwiIHR5cGU9ImVtYWlsIiBhdXRvY29tcGxldGU9
ImVtYWlsIiBwbGFjZWhvbGRlcj0ieW91QGV4YW1wbGUuY29tIiByZXF1aXJlZCAvPgogICAgICAg
IDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBmb3I9
InBhc3N3b3JkIj5QYXNzd29yZDwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgaWQ9InBhc3N3b3Jk
IiBuYW1lPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0ibmV3LXBhc3N3
b3JkIiBwbGFjZWhvbGRlcj0iQXQgbGVhc3QgMTAgY2hhcmFjdGVycyIgcmVxdWlyZWQgLz4KICAg
ICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYmxvY2siIHR5cGU9InN1Ym1p
dCIgaWQ9InN1Ym1pdCI+Q3JlYXRlIGFjY291bnQ8L2J1dHRvbj4KICAgICAgPC9mb3JtPgogICAg
ICA8cCBjbGFzcz0iYWx0Ij5BbHJlYWR5IGhhdmUgYW4gYWNjb3VudD8gPGEgY2xhc3M9Imxpbmsi
IGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPjwvcD4KICAgIDwvZGl2PgogIDwvc2VjdGlvbj4K
PC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFz
cz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJz
dGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEg
aHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL3N0YXR1cyI+U3Rh
dHVzPC9hPgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+UHJpdmFjeTwvYT4KICAgICAgPGEgaHJl
Zj0iL3Rlcm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJlZj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+
CiAgICA8L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5E
QEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2Fw
cC5qcyIgZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgpERUNPWV9TSUdOVVAKCmNhdCA+
ICIkRC9yZXNldC5odG1sIiA8PCdERUNPWV9SRVNFVCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxh
bmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3
cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+Cjxt
ZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5h
bWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlJlc2V0IHBhc3N3
b3JkIOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIg
Y29udGVudD0iUmVzZXQgeW91ciBAQEJSQU5EQEAgQ2xvdWQgcGFzc3dvcmQuIiAvPgo8bGluayBy
ZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1p
Y29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZlc3Qi
IGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNoZWV0
IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAgPGRp
diBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3ZnIGNs
YXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0
cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+
PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAwLTku
NTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+QEBC
UkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgogICAg
ICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJpY2lu
ZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAg
ICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5h
di1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9h
PgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAg
IDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4KCjxtYWluIGNsYXNzPSJ3cmFwIj4KICA8c2VjdGlv
biBjbGFzcz0iYXV0aCIgc3R5bGU9ImdyaWQtY29sdW1uOjEvLTEiPgogICAgPGRpdiBjbGFzcz0i
Y2FyZCBjZW50ZXItY2FyZCI+CiAgICAgIDxoMj5SZXNldCB5b3VyIHBhc3N3b3JkPC9oMj4KICAg
ICAgPHAgY2xhc3M9InN1YiI+RW50ZXIgeW91ciBlbWFpbCBhbmQgd2Ugd2lsbCBzZW5kIHJlc2V0
IGluc3RydWN0aW9ucy48L3A+CiAgICAgIDxkaXYgY2xhc3M9Im1zZyIgaWQ9Im1zZyIgcm9sZT0i
YWxlcnQiPjwvZGl2PgogICAgICA8Zm9ybSBpZD0icmVzZXQiIG5vdmFsaWRhdGU+CiAgICAgICAg
PGRpdiBjbGFzcz0iZmllbGQiPgogICAgICAgICAgPGxhYmVsIGZvcj0iZW1haWwiPkVtYWlsPC9s
YWJlbD4KICAgICAgICAgIDxpbnB1dCBpZD0iZW1haWwiIG5hbWU9ImVtYWlsIiB0eXBlPSJlbWFp
bCIgYXV0b2NvbXBsZXRlPSJlbWFpbCIgcGxhY2Vob2xkZXI9InlvdUBleGFtcGxlLmNvbSIgcmVx
dWlyZWQgLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYmxvY2si
IHR5cGU9InN1Ym1pdCIgaWQ9InN1Ym1pdCI+U2VuZCByZXNldCBsaW5rPC9idXR0b24+CiAgICAg
IDwvZm9ybT4KICAgICAgPHAgY2xhc3M9ImFsdCI+PGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii8jc2ln
bmluIj5CYWNrIHRvIHNpZ24gaW48L2E+PC9wPgogICAgPC9kaXY+CiAgPC9zZWN0aW9uPgo8L21h
aW4+Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJz
dGF0dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0
Ij5DaGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVm
PSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8
L2E+CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIv
dGVybXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAg
IDwvbmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBD
bG91ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpz
IiBkZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1JFU0VUCgpjYXQgPiAiJEQv
c3VwcG9ydC5odG1sIiA8PCdERUNPWV9TVVBQT1JUJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFu
Zz0iZW4iPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9InZpZXdw
b3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIgLz4KPG1l
dGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1ldGEgbmFt
ZT0icmVmZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+U3VwcG9ydCDigJQg
QEBCUkFOREBAIENsb3VkPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVzY3JpcHRpb24iIGNvbnRlbnQ9
IkBAQlJBTkRAQCBDbG91ZCBoZWxwIGFuZCBzdXBwb3J0LiIgLz4KPGxpbmsgcmVsPSJpY29uIiBo
cmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0i
L2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNz
ZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fz
c2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9Indy
YXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIg
dmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qg
d2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0x
MC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQg
MCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNw
O0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0i
LyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciPlByaWNpbmc8
L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9
Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAg
ICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEg
Y2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8
L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1haW4iPgogIDxkaXYgY2xh
c3M9InBhZ2UtaGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5TdXBwb3J0PC9kaXY+CiAg
ICA8aDE+SGVscCAmYW1wOyBzdXBwb3J0PC9oMT4KICAgIDxwPkFuc3dlcnMgdG8gY29tbW9uIHF1
ZXN0aW9ucywgYW5kIGhvdyB0byByZWFjaCB1cy48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0i
cHJvc2UiPgogICAgPGgyPkZyZXF1ZW50bHkgYXNrZWQ8L2gyPgogICAgPHA+PHN0cm9uZz5Ib3cg
ZG8gSSByZWNvdmVyIGEgZGVsZXRlZCBmaWxlPzwvc3Ryb25nPiBEZWxldGVkIGZpbGVzIHN0YXkg
aW4geW91ciB0cmFzaCBmb3IgMzAgZGF5cy4gT3BlbiB0aGUgd2ViIGFwcCwgZ28gdG8gVHJhc2gg
YW5kIGNob29zZSBSZXN0b3JlLjwvcD4KICAgIDxwPjxzdHJvbmc+Q2FuIEkgYWNjZXNzIGZpbGVz
IG9mZmxpbmU/PC9zdHJvbmc+IFllcy4gVGhlIGRlc2t0b3AgYW5kIG1vYmlsZSBhcHBzIGtlZXAg
YSBsb2NhbCBjb3B5IGFuZCBzeW5jIGNoYW5nZXMgd2hlbiB5b3UgcmVjb25uZWN0LjwvcD4KICAg
IDxwPjxzdHJvbmc+SG93IGRvIEkgZW5hYmxlIHR3by1mYWN0b3IgYXV0aGVudGljYXRpb24/PC9z
dHJvbmc+IEFjY291bnQgc2V0dGluZ3Mg4oaSIFNlY3VyaXR5IOKGkiBUd28tZmFjdG9yIGF1dGhl
bnRpY2F0aW9uLjwvcD4KICAgIDxoMj5Db250YWN0IHVzPC9oMj4KICAgIDxwPkVtYWlsIDxhIGNs
YXNzPSJsaW5rIiBocmVmPSJtYWlsdG86c3VwcG9ydEBAQE1BSU5fRE9NQUlOQEAiPnN1cHBvcnRA
QEBNQUlOX0RPTUFJTkBAPC9hPiBhbmQgd2UgdXN1YWxseSByZXBseSB3aXRoaW4gb25lIGJ1c2lu
ZXNzIGRheS4gRm9yIHNlcnZpY2Ugc3RhdHVzIHNlZSB0aGUgPGEgY2xhc3M9ImxpbmsiIGhyZWY9
Ii9zdGF0dXMiPnN0YXR1cyBwYWdlPC9hPi48L3A+CiAgPC9kaXY+CjwvbWFpbj4KCjxmb290ZXI+
CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4g
Y2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0
YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+
U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEg
aHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8
L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8
ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAg
PC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2Ny
aXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfU1VQUE9SVAoKY2F0ID4gIiREL25naW54LmNvbmYi
IDw8J0RFQ09ZX05HSU5YJwpsaW1pdF9yZXFfem9uZSAkYmluYXJ5X3JlbW90ZV9hZGRyIHpvbmU9
YXV0aF9saW1pdDoxMG0gcmF0ZT0zci9tOwpsaW1pdF9yZXFfc3RhdHVzIDQyOTsKCm1hcCAkcmVx
dWVzdF9pZCAkYXV0aF9lcnJvcl9tc2cgewogICAgZGVmYXVsdCAgICAgICAiSW5jb3JyZWN0IGVt
YWlsIG9yIHBhc3N3b3JkLiBQbGVhc2UgdHJ5IGFnYWluLiI7CiAgICAifl5bMC0zXSIgICAgICJB
Y2NvdW50IG5vdCBmb3VuZC4iOwogICAgIn5eWzQtN10iICAgICAiSW5jb3JyZWN0IHBhc3N3b3Jk
LiI7CiAgICAifl5bOC1iXSIgICAgICJBY2NvdW50IHRlbXBvcmFyaWx5IGxvY2tlZC4gVHJ5IGFn
YWluIGxhdGVyLiI7CiAgICAifl5bYy1mXSIgICAgICJUb28gbWFueSBhdHRlbXB0cy4gUGxlYXNl
IHdhaXQgYW5kIHRyeSBhZ2Fpbi4iOwp9CgpzZXJ2ZXIgewogICAgbGlzdGVuIDgwOwogICAgbGlz
dGVuIFs6Ol06ODA7CiAgICBzZXJ2ZXJfbmFtZSBfOwoKICAgIGFkZF9oZWFkZXIgWC1Db250ZW50
LVR5cGUtT3B0aW9ucyAibm9zbmlmZiIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBYLUZyYW1lLU9w
dGlvbnMgIlNBTUVPUklHSU4iIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgWC1QZXJtaXR0ZWQtQ3Jv
c3MtRG9tYWluLVBvbGljaWVzICJub25lIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFgtUm9ib3Rz
LVRhZyAibm9pbmRleCwgbm9mb2xsb3ciIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgWC1YU1MtUHJv
dGVjdGlvbiAiMTsgbW9kZT1ibG9jayIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBSZWZlcnJlci1Q
b2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFN0cmljdC1UcmFuc3Bv
cnQtU2VjdXJpdHkgIm1heC1hZ2U9MTU1NTIwMDA7IGluY2x1ZGVTdWJEb21haW5zIiBhbHdheXM7
CiAgICBhZGRfaGVhZGVyIENvbnRlbnQtU2VjdXJpdHktUG9saWN5ICJkZWZhdWx0LXNyYyAnc2Vs
Zic7IHNjcmlwdC1zcmMgJ3NlbGYnOyBzdHlsZS1zcmMgJ3NlbGYnICd1bnNhZmUtaW5saW5lJzsg
aW1nLXNyYyAnc2VsZicgZGF0YTo7IGNvbm5lY3Qtc3JjICdzZWxmJzsgZm9udC1zcmMgJ3NlbGYn
OyBvYmplY3Qtc3JjICdub25lJzsgZnJhbWUtYW5jZXN0b3JzICdub25lJzsgYmFzZS11cmkgJ3Nl
bGYnOyIgYWx3YXlzOwoKICAgIHNlcnZlcl90b2tlbnMgb2ZmOwogICAgYWNjZXNzX2xvZyBvZmY7
CgogICAgIyDQodGC0LDRgtC40LrQsCDQv9GA0LjQu9C+0LbQtdC90LjRjyDigJQg0L7RgtC00LDR
kdC8INC90LDQv9GA0Y/QvNGD0Y4g0YEg0LTQu9C40L3QvdGL0Lwg0LrRjdGI0L7QvCwg0LrQsNC6
INC90LDRgdGC0L7Rj9GJ0LjQuSDQsdC40LvQtAogICAgbG9jYXRpb24gXn4gL2Fzc2V0cy8gewog
ICAgICAgIHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGV4cGlyZXMgMzBkOwog
ICAgICAgIGFkZF9oZWFkZXIgQ2FjaGUtQ29udHJvbCAicHVibGljLCBpbW11dGFibGUiIGFsd2F5
czsKICAgICAgICBhZGRfaGVhZGVyIFgtQ29udGVudC1UeXBlLU9wdGlvbnMgIm5vc25pZmYiIGFs
d2F5czsKICAgICAgICB0cnlfZmlsZXMgJHVyaSA9NDA0OwogICAgfQoKICAgIGxvY2F0aW9uIC8g
ewogICAgICAgIHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGluZGV4IGluZGV4
Lmh0bWw7CiAgICAgICAgdHJ5X2ZpbGVzICR1cmkgJHVyaS5odG1sICR1cmkvIC9pbmRleC5odG1s
OwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvc3RhdHVzJCB7CiAgICAgICAgZGVmYXVsdF90
eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVBvd2VyZWQtQnkgIkBA
U0xVR0BALWFwaSIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVx
dWVzdF9pZCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgWC1Db250ZW50LVR5cGUtT3B0aW9u
cyAibm9zbmlmZiIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJu
by1yZWZlcnJlciIgYWx3YXlzOwogICAgICAgIHJldHVybiAyMDAgJ3sib25saW5lIjp0cnVlLCJt
YWludGVuYW5jZSI6ZmFsc2UsInZlcnNpb24iOiIzLjIuNyIsImJ1aWxkIjoiMjAyNS4xMS4wMiIs
InByb2R1Y3QiOiJAQEJSQU5EQEAgQ2xvdWQiLCJhcGkiOiIxLjAifSc7CiAgICB9CgogICAgZXJy
b3JfcGFnZSA0MjkgPSBAcmF0ZV9saW1pdGVkOwogICAgbG9jYXRpb24gQHJhdGVfbGltaXRlZCB7
CiAgICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRl
ciBSZXRyeS1BZnRlciAiMjAiIGFsd2F5czsKICAgICAgICByZXR1cm4gNDI5ICd7InN0YXR1cyI6
ImVycm9yIiwibWVzc2FnZSI6IlRvbyBtYW55IHJlcXVlc3RzLiBUcnkgYWdhaW4gaW4gMjAgc2Vj
b25kcy4ifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9hdXRoJCB7CiAgICAgICAgbGlt
aXRfcmVxIHpvbmU9YXV0aF9saW1pdCBidXJzdD0yIG5vZGVsYXk7CiAgICAgICAgYWNjZXNzX2xv
ZyAvdmFyL2xvZy9teWZha2VzaXRlL2FjY2Vzcy5sb2cgY29tYmluZWQ7CiAgICAgICAgZGVmYXVs
dF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQg
IiRyZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBTZXQtQ29va2llICJhYl9z
ZXNzaW9uPWV5SmhiR2NpT2lKSVV6STFOaUo5LiRyZXF1ZXN0X2lkLnNpZzsgUGF0aD0vOyBIdHRw
T25seTsgU2VjdXJlOyBTYW1lU2l0ZT1TdHJpY3QiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVy
IFNldC1Db29raWUgIl9fSG9zdC1hYl9wcml2YWN5PWFjazsgUGF0aD0vOyBTZWN1cmU7IFNhbWVT
aXRlPVN0cmljdCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJu
by1yZWZlcnJlciIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MDEgJ3sic3RhdHVzIjoiZXJyb3Ii
LCJtZXNzYWdlIjoiJGF1dGhfZXJyb3JfbXNnIn0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9h
cGkvcmVnaXN0ZXIkIHsKICAgICAgICBsaW1pdF9yZXEgem9uZT1hdXRoX2xpbWl0IGJ1cnN0PTIg
bm9kZWxheTsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBh
ZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICBhZGRf
aGVhZGVyIFJlZmVycmVyLVBvbGljeSAibm8tcmVmZXJyZXIiIGFsd2F5czsKICAgICAgICByZXR1
cm4gMjAwICd7InN0YXR1cyI6Im9rIiwibWVzc2FnZSI6IkNoZWNrIHlvdXIgaW5ib3gg4oCUIHdl
IHNlbnQgYSB2ZXJpZmljYXRpb24gbGluayB0byBjb25maXJtIHlvdXIgZW1haWwuIn0nOwogICAg
fQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvcmVzZXQkIHsKICAgICAgICBsaW1pdF9yZXEgem9uZT1h
dXRoX2xpbWl0IGJ1cnN0PTIgbm9kZWxheTsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRp
b24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFs
d2F5czsKICAgICAgICBhZGRfaGVhZGVyIFJlZmVycmVyLVBvbGljeSAibm8tcmVmZXJyZXIiIGFs
d2F5czsKICAgICAgICByZXR1cm4gMjAwICd7InN0YXR1cyI6Im9rIiwibWVzc2FnZSI6IklmIGFu
IGFjY291bnQgZXhpc3RzIGZvciB0aGF0IGVtYWlsLCB3ZSBqdXN0IHNlbnQgcmVzZXQgaW5zdHJ1
Y3Rpb25zLiJ9JzsKICAgIH0KCiAgICBsb2NhdGlvbiB+IF4vYXBpL2ZpbGVzKC8uKik/JCB7CiAg
ICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBY
LVJlcXVlc3QtSWQgIiRyZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDQwMSAneyJz
dGF0dXMiOiJlcnJvciIsIm1lc3NhZ2UiOiJBdXRoZW50aWNhdGlvbiByZXF1aXJlZCJ9JzsKICAg
IH0KCiAgICBsb2NhdGlvbiB+IF4vYXBpL3VzZXJzKC8uKik/JCB7CiAgICAgICAgZGVmYXVsdF90
eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQgIiRy
ZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDQwMSAneyJzdGF0dXMiOiJlcnJvciIs
Im1lc3NhZ2UiOiJBdXRoZW50aWNhdGlvbiByZXF1aXJlZCJ9JzsKICAgIH0KCiAgICBsb2NhdGlv
biB+IF4vYXBpL3NldHRpbmdzJCB7CiAgICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pz
b247CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQgIiRyZXF1ZXN0X2lkIiBhbHdheXM7
CiAgICAgICAgcmV0dXJuIDIwMCAneyJzdGF0dXMiOiJvayIsImxhbmciOiJlbiIsInRoZW1lIjoi
YXV0byIsIm5vdGlmaWNhdGlvbnMiOnRydWUsInR3b19mYWN0b3IiOmZhbHNlLCJzdG9yYWdlIjp7
InVzZWQiOjQ4OTIzMTAwMDAsInRvdGFsIjoyMTQ3NDgzNjQ4MH0sImxhc3RfbG9naW4iOiIyMDI2
LTA0LTEwVDE4OjMyOjA3WiJ9JzsKICAgIH0KCiAgICBsb2NhdGlvbiA9IC9yb2JvdHMudHh0IHsK
ICAgICAgICBkZWZhdWx0X3R5cGUgdGV4dC9wbGFpbjsKICAgICAgICByZXR1cm4gMjAwICdVc2Vy
LWFnZW50OiAqCkFsbG93OiAvCkRpc2FsbG93OiAvYXBpLwpEaXNhbGxvdzogL2FkbWluLwpEaXNh
bGxvdzogL2ludGVybmFsLwonOwogICAgfQoKICAgIGxvY2F0aW9uID0gL2hlYXJ0YmVhdCB7CiAg
ICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgcmV0dXJuIDIwMCAn
eyJvayI6dHJ1ZSwidHMiOiRtc2VjfSc7CiAgICB9CgogICAgbG9jYXRpb24gPSAvLndlbGwta25v
d24vc2VjdXJpdHkudHh0IHsKICAgICAgICBkZWZhdWx0X3R5cGUgdGV4dC9wbGFpbjsKICAgICAg
ICBhZGRfaGVhZGVyIEFjY2Vzcy1Db250cm9sLUFsbG93LU9yaWdpbiAiKiIgYWx3YXlzOwogICAg
ICAgIHJldHVybiAyMDAgJ0NvbnRhY3Q6IG1haWx0bzphZG1pbkBAQE1BSU5fRE9NQUlOQEAKUHJl
ZmVycmVkLUxhbmd1YWdlczogZW4KRXhwaXJlczogMjAyNy0wMS0wMVQwMDowMDowMFoKJzsKICAg
IH0KCiAgICBsb2NhdGlvbiB+IF4vXC53ZWxsLWtub3duLyg/IXNlY3VyaXR5XC50eHQpIHsgcmV0
dXJuIDQwNDsgfQoKICAgIGxvY2F0aW9uID0gL2Zhdmljb24uaWNvIHsKICAgICAgICByb290IC91
c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBleHBpcmVzIDMwZDsKICAgICAgICBhZGRfaGVh
ZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1tdXRhYmxlIiBhbHdheXM7CiAgICB9CiAgICBs
b2NhdGlvbiA9IC9hcHBsZS10b3VjaC1pY29uLnBuZyB7CiAgICAgICAgcm9vdCAvdXNyL3NoYXJl
L25naW54L2h0bWw7CiAgICAgICAgZXhwaXJlcyAzMGQ7CiAgICAgICAgYWRkX2hlYWRlciBDYWNo
ZS1Db250cm9sICJwdWJsaWMsIGltbXV0YWJsZSIgYWx3YXlzOwogICAgfQoKICAgIGxvY2F0aW9u
ID0gL2xvZy1yb3RhdGUtYnktc2l6ZS5zaCB7IHJldHVybiA0MDQ7IH0KICAgIGxvY2F0aW9uID0g
L2RhdGEvbG9nLXJvdGF0ZS1ieS1zaXplLnNoIHsgcmV0dXJuIDQwNDsgfQoKICAgIGxvY2F0aW9u
IH4gXC5waHAkIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBm
YXN0Y2dpX3Bhc3MgcGhwLWZwbTo5MDAwOwogICAgICAgIGZhc3RjZ2lfaW5kZXggaW5kZXgucGhw
OwogICAgICAgIGZhc3RjZ2lfcGFyYW0gU0NSSVBUX0ZJTEVOQU1FICRkb2N1bWVudF9yb290JGZh
c3RjZ2lfc2NyaXB0X25hbWU7CiAgICAgICAgaW5jbHVkZSBmYXN0Y2dpX3BhcmFtczsKICAgICAg
ICBmYXN0Y2dpX2hpZGVfaGVhZGVyIFgtUG93ZXJlZC1CeTsKICAgIH0KCiAgICBsb2NhdGlvbiB+
IF4vKD86XC5odC4qfFwuZ2l0Lip8XC5lbnYuKnxkYXRhL3xjb25maWcvfGxpYi98M3JkcGFydHkv
fHRlbXBsYXRlcy8pIHsgcmV0dXJuIDQwNDsgfQoKICAgIGVycm9yX3BhZ2UgNTAwIDUwMiA1MDMg
NTA0IC81MHguaHRtbDsKICAgIGxvY2F0aW9uID0gLzUweC5odG1sIHsgcm9vdCAvdXNyL3NoYXJl
L25naW54L2h0bWw7IH0KfQpERUNPWV9OR0lOWAoKY2F0ID4gIiRST09UL2RvY2tlci1jb21wb3Nl
LnltbCIgPDwnREVDT1lfQ09NUE9TRScKc2VydmljZXM6CiAgZmFrZXNpdGU6CiAgICBpbWFnZTog
bmdpbng6YWxwaW5lCiAgICBjb250YWluZXJfbmFtZTogQEBTTFVHQEAtZGVjb3kKICAgIHJlc3Rh
cnQ6IHVubGVzcy1zdG9wcGVkCiAgICBwb3J0czoKICAgICAgLSAiMTI3LjAuMC4xOjgwODA6ODAi
CiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9hcHBsZS10b3VjaC1pY29uLnBuZzovdXNyL3No
YXJlL25naW54L2h0bWwvYXBwbGUtdG91Y2gtaWNvbi5wbmc6cm8KICAgICAgLSAuL2RhdGEvZmF2
aWNvbi5pY286L3Vzci9zaGFyZS9uZ2lueC9odG1sL2Zhdmljb24uaWNvOnJvCiAgICAgIC0gLi9k
YXRhL2luZGV4Lmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL2luZGV4Lmh0bWw6cm8KICAgICAg
LSAuL2RhdGEvcHJpY2luZy5odG1sOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9wcmljaW5nLmh0bWw6
cm8KICAgICAgLSAuL2RhdGEvc2VjdXJpdHkuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvc2Vj
dXJpdHkuaHRtbDpybwogICAgICAtIC4vZGF0YS9wcml2YWN5Lmh0bWw6L3Vzci9zaGFyZS9uZ2lu
eC9odG1sL3ByaXZhY3kuaHRtbDpybwogICAgICAtIC4vZGF0YS90ZXJtcy5odG1sOi91c3Ivc2hh
cmUvbmdpbngvaHRtbC90ZXJtcy5odG1sOnJvCiAgICAgIC0gLi9kYXRhL3N0YXR1cy5odG1sOi91
c3Ivc2hhcmUvbmdpbngvaHRtbC9zdGF0dXMuaHRtbDpybwogICAgICAtIC4vZGF0YS9kb2NzLmh0
bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL2RvY3MuaHRtbDpybwogICAgICAtIC4vZGF0YS9zaWdu
dXAuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvc2lnbnVwLmh0bWw6cm8KICAgICAgLSAuL2Rh
dGEvcmVzZXQuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvcmVzZXQuaHRtbDpybwogICAgICAt
IC4vZGF0YS9zdXBwb3J0Lmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL3N1cHBvcnQuaHRtbDpy
bwogICAgICAtIC4vZGF0YS9hc3NldHM6L3Vzci9zaGFyZS9uZ2lueC9odG1sL2Fzc2V0czpybwog
ICAgICAtIC4vZGF0YS9uZ2lueC5jb25mOi9ldGMvbmdpbngvY29uZi5kL2RlZmF1bHQuY29uZjpy
bwogICAgICAtIC4vZGF0YS9waHBpbmZvLnBocDovdXNyL3NoYXJlL25naW54L2h0bWwvcGhwaW5m
by5waHA6cm8KICAgICAgLSAuL2RhdGEvcm9ib3RzLnR4dDovdXNyL3NoYXJlL25naW54L2h0bWwv
cm9ib3RzLnR4dDpybwogICAgICAtIC4vZGF0YS9zdGF0dXMucGhwOi91c3Ivc2hhcmUvbmdpbngv
aHRtbC9zdGF0dXMucGhwOnJvCiAgICAgIC0gLi9kYXRhL1ZFUlNJT046L3Vzci9zaGFyZS9uZ2lu
eC9odG1sL1ZFUlNJT046cm8KICAgICAgLSAvdmFyL2xvZy9teWZha2VzaXRlOi92YXIvbG9nL215
ZmFrZXNpdGUKICAgIG5ldHdvcmtzOiBbZmFrZXNpdGVdCiAgICBkZXBlbmRzX29uOiBbcGhwLWZw
bV0KICBwaHAtZnBtOgogICAgaW1hZ2U6IHBocDo4LjMtZnBtLWFscGluZQogICAgY29udGFpbmVy
X25hbWU6IEBAU0xVR0BALWRlY295LXBocAogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAg
IHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL3N0YXR1cy5waHA6L3Vzci9zaGFyZS9uZ2lueC9odG1s
L3N0YXR1cy5waHA6cm8KICAgICAgLSAuL2RhdGEvcGhwaW5mby5waHA6L3Vzci9zaGFyZS9uZ2lu
eC9odG1sL3BocGluZm8ucGhwOnJvCiAgICBuZXR3b3JrczogW2Zha2VzaXRlXQpuZXR3b3JrczoK
ICBmYWtlc2l0ZToKICAgIGRyaXZlcjogYnJpZGdlCkRFQ09ZX0NPTVBPU0UKCmVjaG8gIj09IFsz
LzRdINCf0LXRgNC10YHQvtC30LTQsNGOINC60L7QvdGC0LXQudC90LXRgCDQuCDQv9C10YDQtdGH
0LjRgtGL0LLQsNGOINC60L7QvdGE0LjQsyA9PSIKY2QgIiRST09UIgpkb2NrZXIgY29tcG9zZSB1
cCAtZApkb2NrZXIgZXhlYyBAQFNMVUdAQC1kZWNveSBuZ2lueCAtdCAyPi9kZXYvbnVsbCAmJiBk
b2NrZXIgZXhlYyBAQFNMVUdAQC1kZWNveSBuZ2lueCAtcyByZWxvYWQgMj4vZGV2L251bGwgfHwg
ZG9ja2VyIHJlc3RhcnQgQEBTTFVHQEAtZGVjb3kgPi9kZXYvbnVsbAoKZWNobyAiPT0gWzQvNF0g
0J/RgNC+0LLQtdGA0LrQsCDQvNCw0YDRiNGA0YPRgtC+0LIg0L3QsCAxMjcuMC4wLjE6ODA4MCA9
PSIKc2xlZXAgMwpjaGVjaygpeyBjb2RlPSQoY3VybCAtcyAtbyAvdG1wL19iIC13ICcle2h0dHBf
Y29kZX0nICJodHRwOi8vMTI3LjAuMC4xOjgwODAkMSIpOyB0aXRsZT0kKGdyZXAgLW9pRSAnPHRp
dGxlPltePF0qPC90aXRsZT4nIC90bXAvX2IgfCBoZWFkIC0xIHwgc2VkIC1FICdzLzxcLz90aXRs
ZT4vL2cnKTsgcHJpbnRmICIgICUtMTJzIEhUVFAgJXMgIHwgJXNcbiIgIiQxIiAiJGNvZGUiICIk
dGl0bGUiOyB9CmZvciBwIGluIC8gL3ByaWNpbmcgL3NlY3VyaXR5IC9kb2NzIC9zdGF0dXMgL3By
aXZhY3kgL3Rlcm1zIC9zdXBwb3J0IC9zaWdudXAgL3Jlc2V0OyBkbyBjaGVjayAiJHAiOyBkb25l
CmVjaG8gLW4gIiAgL2FwaS9yZWdpc3RlcjogIjsgY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly8xMjcu
MC4wLjE6ODA4MC9hcGkvcmVnaXN0ZXIgLUggJ0NvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNv
bicgLWQgJ3siZW1haWwiOiJhQGIuY28ifSc7IGVjaG8KZWNobyAtbiAiICAvYXBpL3Jlc2V0OiAg
ICAiOyBjdXJsIC1zIC1YIFBPU1QgaHR0cDovLzEyNy4wLjAuMTo4MDgwL2FwaS9yZXNldCAtSCAn
Q29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9qc29uJyAtZCAneyJlbWFpbCI6ImFAYi5jbyJ9Jzsg
ZWNobwplY2hvICLQntGC0LrQsNGCOiBmb3IgZiBpbiBpbmRleC5odG1sIG5naW54LmNvbmYgYXNz
ZXRzL2FwcC5jc3MgYXNzZXRzL2FwcC5qczsgZG8gY3AgXCJcJEQvXCRmLmJhay4kdHNcIiBcIiRE
L1wkZlwiOyBkb25lOyBjcCBcIiRST09UL2RvY2tlci1jb21wb3NlLnltbC5iYWsuJHRzXCIgXCIk
Uk9PVC9kb2NrZXItY29tcG9zZS55bWxcIjsgcm0gLWYgJEQve3ByaWNpbmcsc2VjdXJpdHkscHJp
dmFjeSx0ZXJtcyxzdGF0dXMsZG9jcyxzaWdudXAscmVzZXQsc3VwcG9ydH0uaHRtbDsgY2QgXCIk
Uk9PVFwiICYmIGRvY2tlciBjb21wb3NlIHVwIC1kICYmIGRvY2tlciByZXN0YXJ0IEBAU0xVR0BA
LWRlY295Igo=
__B64__
  base64 -d > "$d/deploy-decoy-pro.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1kZWNv
eS1wcm8uc2gg4oCUIMKr0YLRj9C20ZHQu9GL0LnCuyDQtNC10LrQvtC5IEBAQlJBTkRAQCBDbG91
ZCAo0YDQtdGE0LDQudC9INGB0YLQtdC70YHQsCAjNCkKIyAg0KfRgtC+INC00LXQu9Cw0LXRgjoK
IyAgIOKAoiDRgNCw0LfQvdC+0YHQuNGCIENTUy9KUy/QuNC70LvRjtGB0YLRgNCw0YbQuNGOINCy
INC+0YLQtNC10LvRjNC90YvQtSDRhNCw0LnQu9GLIC9hc3NldHMvICjQutCw0Log0L3QsNGB0YLQ
vtGP0YnQuNC5INCx0LjQu9C0KQojICAg4oCiINC80L7QvdGC0LjRgNGD0LXRgiAuL2RhdGEvYXNz
ZXRzINCyINC60L7QvdGC0LXQudC90LXRgCBuZ2lueAojICAg4oCiINCy0LXRiNCw0LXRgiBDYWNo
ZS1Db250cm9sOiBwdWJsaWMsIGltbXV0YWJsZSDQvdCwIC9hc3NldHMvCiMgICDigKIg0YPQttC4
0LzQsNC10YIgQ1NQINC00L4gJ3NlbGYnICjRg9Cx0LjRgNCw0LXRgiDRhdCy0L7RgdGC0YsgY2Ru
anMvZ29vZ2xlINC40Lcg0YjQsNCx0LvQvtC90LApCiMgICDigKIg0LzQvtC6LUFQSSDQv9C10YDQ
tdCy0LXQtNGR0L0g0L3QsCDQsNC90LPQu9C40LnRgdC60LjQuSDQv9C+0LQg0LHRgNC10L3QtCBA
QEJSQU5EQEAgQ2xvdWQKIyAg0JHRjdC60LDQv9C40YIgaW5kZXguaHRtbCwgbmdpbnguY29uZiwg
ZG9ja2VyLWNvbXBvc2UueW1sLiDQntGC0LrQsNGCIOKAlCDQsiDQutC+0L3RhtC1INCy0YvQstC+
0LTQsC4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbApST09UPS9vcHQv
QEBTTFVHQEAvZGVjb3kKRD0iJFJPT1QvZGF0YSIKdHM9JChkYXRlICslWSVtJWQtJUglTSVTKQoK
WyAtZCAiJEQiIF0gfHwgeyBlY2hvICLQndC1INC90LDQudC00LXQvSAkRCDigJQg0LTQtdC60L7Q
uSDQvdC1INGA0LDQt9Cy0ZHRgNC90YPRgiDQvdCwINGN0YLQvtC8INGF0L7RgdGC0LU/IjsgZXhp
dCAxOyB9CgplY2hvICI9PSBbMS81XSDQkdGN0LrQsNC/ID09Igpmb3IgZiBpbiBpbmRleC5odG1s
IG5naW54LmNvbmY7IGRvCiAgWyAtZiAiJEQvJGYiIF0gJiYgY3AgLWEgIiRELyRmIiAiJEQvJGYu
YmFrLiR0cyIgJiYgZWNobyAiICAkRC8kZi5iYWsuJHRzIgpkb25lClsgLWYgIiRST09UL2RvY2tl
ci1jb21wb3NlLnltbCIgXSAmJiBjcCAtYSAiJFJPT1QvZG9ja2VyLWNvbXBvc2UueW1sIiAiJFJP
T1QvZG9ja2VyLWNvbXBvc2UueW1sLmJhay4kdHMiICYmIGVjaG8gIiAgJFJPT1QvZG9ja2VyLWNv
bXBvc2UueW1sLmJhay4kdHMiCgplY2hvICI9PSBbMi81XSDQn9C40YjRgyDQsNGB0YHQtdGC0Yss
INGB0YLRgNCw0L3QuNGG0YMg0Lgg0LrQvtC90YTQuNCz0LggPT0iCm1rZGlyIC1wICIkRC9hc3Nl
dHMiCmNhdCA+ICIkRC9hc3NldHMvYXBwLmNzcyIgPDwnREVDT1lfQVBQQ1NTJwo6cm9vdHsKICAt
LWJnOiNlZWYyZjg7IC0tcGFuZWw6I2ZmZmZmZjsgLS1pbms6IzEwMTcyODsgLS1tdXRlZDojNWI2
Yjg2OwogIC0tbGluZTojZTJlOGYyOyAtLWJyYW5kOiMzYTViZDk7IC0tYnJhbmQtcHJlc3M6IzJm
NDlhZDsgLS1yaW5nOiM5ZGI0ZjQ7CiAgLS1vazojMWY5ZDU3OyAtLXdhcm46I2MyM2IzYjsgLS1z
aGFkb3c6MCAxOHB4IDUwcHggLTI0cHggcmdiYSgyMCw0MCw5MCwuMzUpOwogIC0tcmFkaXVzOjE0
cHg7Cn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9Cmh0bWwsYm9keXttYXJnaW46MDtoZWlnaHQ6
MTAwJX0KYm9keXsKICBmb250LWZhbWlseTotYXBwbGUtc3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9u
dCwiU2Vnb2UgVUkiLFJvYm90byxIZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZjsKICBjb2xvcjp2
YXIoLS1pbmspOyBiYWNrZ3JvdW5kOnZhcigtLWJnKTsKICAtd2Via2l0LWZvbnQtc21vb3RoaW5n
OmFudGlhbGlhc2VkOyBsaW5lLWhlaWdodDoxLjU7CiAgYmFja2dyb3VuZC1pbWFnZTpyYWRpYWwt
Z3JhZGllbnQoMTEwMHB4IDU0MHB4IGF0IDg2JSAtMTAlLCAjZGZlOGZiIDAlLCByZ2JhKDIyMywy
MzIsMjUxLDApIDYwJSksCiAgICAgICAgICAgICAgICAgICByYWRpYWwtZ3JhZGllbnQoOTAwcHgg
NTAwcHggYXQgLTEwJSAxMTAlLCAjZTZlZmZiIDAlLCByZ2JhKDIzMCwyMzksMjUxLDApIDU1JSk7
Cn0KYXtjb2xvcjppbmhlcml0O3RleHQtZGVjb3JhdGlvbjpub25lfQoud3JhcHttYXgtd2lkdGg6
MTE2MHB4O21hcmdpbjowIGF1dG87cGFkZGluZzowIDI0cHh9CmhlYWRlcntwb3NpdGlvbjpzdGlj
a3k7dG9wOjA7ei1pbmRleDo1O2JhY2tkcm9wLWZpbHRlcjpzYXR1cmF0ZSgxLjEpIGJsdXIoOHB4
KTsKICBiYWNrZ3JvdW5kOnJnYmEoMjM4LDI0MiwyNDgsLjc4KTtib3JkZXItYm90dG9tOjFweCBz
b2xpZCB2YXIoLS1saW5lKX0KLmJhcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1
c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2hlaWdodDo2NnB4fQouYnJhbmR7ZGlzcGxheTpm
bGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTFweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNw
YWNpbmc6LS4ycHh9Ci5tYXJre3dpZHRoOjMwcHg7aGVpZ2h0OjMwcHg7ZmxleDpub25lfQpuYXYu
bGlua3N7ZGlzcGxheTpmbGV4O2dhcDoyOHB4O2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11
dGVkKX0KbmF2LmxpbmtzIGE6aG92ZXJ7Y29sb3I6dmFyKC0taW5rKX0KLm5hdi1jdGF7ZGlzcGxh
eTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTZweH0KLmdob3N0e2ZvbnQtc2l6ZToxNHB4
O2NvbG9yOnZhcigtLW11dGVkKX0KLmdob3N0OmhvdmVye2NvbG9yOnZhcigtLWluayl9Ci5idG57
YXBwZWFyYW5jZTpub25lO2JvcmRlcjowO2N1cnNvcjpwb2ludGVyO2ZvbnQ6aW5oZXJpdDtmb250
LXdlaWdodDo2MDA7CiAgYm9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTFweCAxOHB4O2JhY2tn
cm91bmQ6dmFyKC0tYnJhbmQpO2NvbG9yOiNmZmY7dHJhbnNpdGlvbjpiYWNrZ3JvdW5kIC4xNXMs
IHRyYW5zZm9ybSAuMDVzfQouYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYnJhbmQtcHJlc3Mp
fQouYnRuOmFjdGl2ZXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxcHgpfQouYnRuLmJsb2Nre3dpZHRo
OjEwMCU7cGFkZGluZzoxM3B4fQouYnRuW2Rpc2FibGVkXXtvcGFjaXR5Oi42O2N1cnNvcjpkZWZh
dWx0fQptYWlue3BhZGRpbmc6NjRweCAwIDI4cHh9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRl
bXBsYXRlLWNvbHVtbnM6MS4wNWZyIC45NWZyO2dhcDo2NHB4O2FsaWduLWl0ZW1zOmNlbnRlcn0K
LmV5ZWJyb3d7Zm9udC1zaXplOjEyLjVweDtmb250LXdlaWdodDo2MDA7bGV0dGVyLXNwYWNpbmc6
LjEyZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2NvbG9yOnZhcigtLWJyYW5kKX0KaDF7Zm9u
dC1zaXplOjQ2cHg7bGluZS1oZWlnaHQ6MS4wODtsZXR0ZXItc3BhY2luZzotMS4xcHg7bWFyZ2lu
OjE0cHggMCAxNnB4O2ZvbnQtd2VpZ2h0Ojc2MH0KLmxlZGV7Zm9udC1zaXplOjE3LjVweDtjb2xv
cjp2YXIoLS1tdXRlZCk7bWF4LXdpZHRoOjMwZW07bWFyZ2luOjAgMCAyNnB4fQp1bC5mZWF0e2xp
c3Qtc3R5bGU6bm9uZTtwYWRkaW5nOjA7bWFyZ2luOjA7ZGlzcGxheTpncmlkO2dhcDoxM3B4O21h
eC13aWR0aDozMGVtfQp1bC5mZWF0IGxpe2Rpc3BsYXk6ZmxleDtnYXA6MTFweDthbGlnbi1pdGVt
czpmbGV4LXN0YXJ0O2ZvbnQtc2l6ZToxNXB4fQp1bC5mZWF0IHN2Z3tmbGV4Om5vbmU7bWFyZ2lu
LXRvcDoycHg7Y29sb3I6dmFyKC0tYnJhbmQpfQouaGVyby1pbWd7d2lkdGg6MTAwJTttYXgtd2lk
dGg6NDIwcHg7bWFyZ2luOjI2cHggMCAwO2Rpc3BsYXk6YmxvY2t9Ci50cnVzdHttYXJnaW4tdG9w
OjI0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2Rpc3BsYXk6ZmxleDthbGln
bi1pdGVtczpjZW50ZXI7Z2FwOjhweH0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9y
ZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7CiAg
Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO3BhZGRpbmc6MzBweCAzMHB4IDI2cHh9Ci5jYXJkIGgy
e21hcmdpbjowIDAgNHB4O2ZvbnQtc2l6ZToyMXB4O2xldHRlci1zcGFjaW5nOi0uM3B4fQouY2Fy
ZCAuc3Vie21hcmdpbjowIDAgMjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjE0cHh9
CmxhYmVse2Rpc3BsYXk6YmxvY2s7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO21hcmdp
bjowIDAgN3B4O2NvbG9yOiMzMzQxNWN9Ci5maWVsZHttYXJnaW4tYm90dG9tOjE2cHh9CmlucHV0
W3R5cGU9ZW1haWxdLGlucHV0W3R5cGU9cGFzc3dvcmRde3dpZHRoOjEwMCU7Ym9yZGVyOjFweCBz
b2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjEwcHg7CiAgcGFkZGluZzoxMnB4IDEzcHg7
Zm9udDppbmhlcml0O2JhY2tncm91bmQ6I2ZiZmNmZTt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAu
MTVzLCBib3gtc2hhZG93IC4xNXN9CmlucHV0OmZvY3Vze291dGxpbmU6MDtib3JkZXItY29sb3I6
dmFyKC0tYnJhbmQpO2JveC1zaGFkb3c6MCAwIDAgNHB4IHZhcigtLXJpbmcpfQoucm93e2Rpc3Bs
YXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47
bWFyZ2luOi0ycHggMCAxOHB4fQoucmVtZW1iZXJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNl
bnRlcjtnYXA6OHB4O2ZvbnQtc2l6ZToxMy41cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQoubGlua3tj
b2xvcjp2YXIoLS1icmFuZCk7Zm9udC1zaXplOjEzLjVweDtmb250LXdlaWdodDo2MDB9Ci5saW5r
OmhvdmVye3RleHQtZGVjb3JhdGlvbjp1bmRlcmxpbmV9Ci5tc2d7ZGlzcGxheTpub25lO21hcmdp
bjowIDAgMTZweDtwYWRkaW5nOjEwcHggMTJweDtib3JkZXItcmFkaXVzOjlweDtmb250LXNpemU6
MTMuNXB4OwogIGJhY2tncm91bmQ6I2ZkZWNlYztjb2xvcjojYTAyOTI5O2JvcmRlcjoxcHggc29s
aWQgI2Y2Y2NjY30KLm1zZy5zaG93e2Rpc3BsYXk6YmxvY2t9Ci5hbHR7bWFyZ2luOjA7dGV4dC1h
bGlnbjpjZW50ZXI7Zm9udC1zaXplOjEzLjVweDtjb2xvcjp2YXIoLS1tdXRlZCl9Ci5kaXZpZGVy
e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7Y29sb3I6IzlhYTdiZDtm
b250LXNpemU6MTJweDttYXJnaW46MjBweCAwfQouZGl2aWRlcjo6YmVmb3JlLC5kaXZpZGVyOjph
ZnRlcntjb250ZW50OiIiO2hlaWdodDoxcHg7YmFja2dyb3VuZDp2YXIoLS1saW5lKTtmbGV4OjF9
CmZvb3Rlcntib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1saW5lKTttYXJnaW4tdG9wOjQ4cHg7
YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC41KX0KLmZvb3R7ZGlzcGxheTpmbGV4O2ZsZXgt
d3JhcDp3cmFwO2dhcDoxOHB4IDI4cHg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVu
dDpzcGFjZS1iZXR3ZWVuOwogIHBhZGRpbmc6MjJweCAwO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZh
cigtLW11dGVkKX0KLmZvb3QgbmF2e2Rpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6MThw
eH0KLmZvb3QgYTpob3Zlcntjb2xvcjp2YXIoLS1pbmspfQouc3RhdHVze2Rpc3BsYXk6aW5saW5l
LWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHh9Ci5kb3R7d2lkdGg6OHB4O2hlaWdodDo4
cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojYzJjOWQ2fQouZG90Lm9re2JhY2tncm91
bmQ6dmFyKC0tb2spO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMzEsMTU3LDg3LC4xNSl9Ci5y
ZXZlYWx7b3BhY2l0eTowO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwcHgpO2FuaW1hdGlvbjpyaXNl
IC42cyBjdWJpYy1iZXppZXIoLjIsLjcsLjIsMSkgZm9yd2FyZHN9Ci5yZXZlYWwuZDJ7YW5pbWF0
aW9uLWRlbGF5Oi4wOHN9CkBrZXlmcmFtZXMgcmlzZXt0b3tvcGFjaXR5OjE7dHJhbnNmb3JtOm5v
bmV9fQpAbWVkaWEgKHByZWZlcnMtcmVkdWNlZC1tb3Rpb246cmVkdWNlKXsucmV2ZWFse2FuaW1h
dGlvbjpub25lO29wYWNpdHk6MTt0cmFuc2Zvcm06bm9uZX19CkBtZWRpYSAobWF4LXdpZHRoOjg4
MHB4KXsKICBuYXYubGlua3N7ZGlzcGxheTpub25lfQogIC5ncmlke2dyaWQtdGVtcGxhdGUtY29s
dW1uczoxZnI7Z2FwOjQwcHh9CiAgbWFpbntwYWRkaW5nOjQwcHggMCAxNnB4fQogIGgxe2ZvbnQt
c2l6ZTozNnB4fQogIC5waXRjaHtvcmRlcjoyfS5hdXRoe29yZGVyOjF9CiAgLmhlcm8taW1ne2Rp
c3BsYXk6bm9uZX0KfQpERUNPWV9BUFBDU1MKCmNhdCA+ICIkRC9hc3NldHMvYXBwLmpzIiA8PCdE
RUNPWV9BUFBKUycKLyogQEBCUkFOREBAIENsb3VkIOKAlCB3ZWIgY2xpZW50IGJvb3RzdHJhcCAq
LwooZnVuY3Rpb24oKXsKICAidXNlIHN0cmljdCI7CiAgdmFyIEFQST17c3RhdHVzOiIvYXBpL3N0
YXR1cyIsYXV0aDoiL2FwaS9hdXRoIixzZXR0aW5nczoiL2FwaS9zZXR0aW5ncyJ9OwoKICBmdW5j
dGlvbiBlbChpZCl7cmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTt9CiAgZnVuY3Rp
b24gcmVhZHkoZm4pe2lmKGRvY3VtZW50LnJlYWR5U3RhdGUhPT0ibG9hZGluZyIpZm4oKTtlbHNl
IGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoIkRPTUNvbnRlbnRMb2FkZWQiLGZuKTt9CgogIHJl
YWR5KGZ1bmN0aW9uKCl7CiAgICB2YXIgeXI9ZWwoInlyIik7IGlmKHlyKSB5ci50ZXh0Q29udGVu
dD1uZXcgRGF0ZSgpLmdldEZ1bGxZZWFyKCk7CgogICAgLy8gc2VydmljZSBzdGF0dXMgaW5kaWNh
dG9yCiAgICBmZXRjaChBUEkuc3RhdHVzLHtoZWFkZXJzOntBY2NlcHQ6ImFwcGxpY2F0aW9uL2pz
b24ifX0pCiAgICAgIC50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLm9rP3IuanNvbigpOlByb21p
c2UucmVqZWN0KCk7fSkKICAgICAgLnRoZW4oZnVuY3Rpb24oZCl7CiAgICAgICAgdmFyIGRvdD1l
bCgic2RvdCIpLHQ9ZWwoInN0ZXh0Iik7CiAgICAgICAgaWYoZCYmZC5vbmxpbmUpe2RvdCYmZG90
LmNsYXNzTGlzdC5hZGQoIm9rIik7dCYmKHQudGV4dENvbnRlbnQ9IkFsbCBzeXN0ZW1zIG9wZXJh
dGlvbmFsIik7fQogICAgICAgIGVsc2V7dCYmKHQudGV4dENvbnRlbnQ9IkRlZ3JhZGVkIHBlcmZv
cm1hbmNlIik7fQogICAgICB9KQogICAgICAuY2F0Y2goZnVuY3Rpb24oKXt2YXIgdD1lbCgic3Rl
eHQiKTt0JiYodC50ZXh0Q29udGVudD0iU3RhdHVzIHVuYXZhaWxhYmxlIik7fSk7CgogICAgLy8g
c2lnbi1pbgogICAgdmFyIGZvcm09ZWwoImxvZ2luIiksbXNnPWVsKCJtc2ciKSxidG49ZWwoInN1
Ym1pdCIpOwogICAgZnVuY3Rpb24gc2hvdyh0KXtpZighbXNnKXJldHVybjttc2cudGV4dENvbnRl
bnQ9dDttc2cuY2xhc3NMaXN0LmFkZCgic2hvdyIpO30KICAgIGlmKGZvcm0pewogICAgICBmb3Jt
LmFkZEV2ZW50TGlzdGVuZXIoInN1Ym1pdCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2ZW50
RGVmYXVsdCgpOwogICAgICAgIG1zZyYmbXNnLmNsYXNzTGlzdC5yZW1vdmUoInNob3ciKTsKICAg
ICAgICB2YXIgZW1haWw9KGVsKCJlbWFpbCIpLnZhbHVlfHwiIikudHJpbSgpLHBhc3M9ZWwoInBh
c3N3b3JkIikudmFsdWV8fCIiOwogICAgICAgIGlmKCFlbWFpbHx8IXBhc3Mpe3Nob3coIkVudGVy
IHlvdXIgZW1haWwgYW5kIHBhc3N3b3JkIHRvIGNvbnRpbnVlLiIpO3JldHVybjt9CiAgICAgICAg
YnRuLmRpc2FibGVkPXRydWU7YnRuLnRleHRDb250ZW50PSJTaWduaW5nIGlu4oCmIjsKICAgICAg
ICBmZXRjaChBUEkuYXV0aCx7bWV0aG9kOiJQT1NUIiwKICAgICAgICAgIGhlYWRlcnM6eyJDb250
ZW50LVR5cGUiOiJhcHBsaWNhdGlvbi9qc29uIixBY2NlcHQ6ImFwcGxpY2F0aW9uL2pzb24ifSwK
ICAgICAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe2VtYWlsOmVtYWlsLHBhc3N3b3JkOnBhc3Ms
cmVtZW1iZXI6ISFmb3JtLnJlbWVtYmVyLmNoZWNrZWR9KX0pCiAgICAgICAgLnRoZW4oZnVuY3Rp
b24ocil7CiAgICAgICAgICBpZihyLnN0YXR1cz09PTQyOSlzaG93KCJUb28gbWFueSBhdHRlbXB0
cy4gUGxlYXNlIHdhaXQgYSBtb21lbnQgYW5kIHRyeSBhZ2Fpbi4iKTsKICAgICAgICAgIGVsc2Ug
c2hvdygiRW1haWwgb3IgcGFzc3dvcmQgaXMgaW5jb3JyZWN0LiIpOwogICAgICAgIH0pCiAgICAg
ICAgLmNhdGNoKGZ1bmN0aW9uKCl7c2hvdygiQ2Fubm90IHJlYWNoIHRoZSBzZXJ2ZXIuIENoZWNr
IHlvdXIgY29ubmVjdGlvbiBhbmQgdHJ5IGFnYWluLiIpO30pCiAgICAgICAgLmZpbmFsbHkoZnVu
Y3Rpb24oKXtidG4uZGlzYWJsZWQ9ZmFsc2U7YnRuLnRleHRDb250ZW50PSJTaWduIGluIjt9KTsK
ICAgICAgfSk7CiAgICB9CiAgfSk7Cn0pKCk7CkRFQ09ZX0FQUEpTCgpjYXQgPiAiJEQvYXNzZXRz
L2hlcm8uc3ZnIiA8PCdERUNPWV9IRVJPU1ZHJwo8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9y
Zy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDQ2MCAzMjAiIGZpbGw9Im5vbmUiIHJvbGU9ImltZyIg
YXJpYS1sYWJlbD0iRmlsZXMgaW4gdGhlIGNsb3VkIj4KICA8ZGVmcz4KICAgIDxsaW5lYXJHcmFk
aWVudCBpZD0iZzEiIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zm
c2V0PSIwIiBzdG9wLWNvbG9yPSIjNWI3OGU2Ii8+PHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9y
PSIjM2E1YmQ5Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogIDwvZGVmcz4KICA8cmVjdCB4PSI0
MCIgeT0iNjAiIHdpZHRoPSIzODAiIGhlaWdodD0iMjEwIiByeD0iMTgiIGZpbGw9IiNmZmZmZmYi
IHN0cm9rZT0iI2UyZThmMiIvPgogIDxyZWN0IHg9IjQwIiB5PSI2MCIgd2lkdGg9IjM4MCIgaGVp
Z2h0PSI0NiIgcng9IjE4IiBmaWxsPSIjZjNmNmZjIi8+CiAgPGNpcmNsZSBjeD0iNjQiIGN5PSI4
MyIgcj0iNSIgZmlsbD0iI2NmZDhlYSIvPjxjaXJjbGUgY3g9IjgyIiBjeT0iODMiIHI9IjUiIGZp
bGw9IiNjZmQ4ZWEiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSI4MyIgcj0iNSIgZmlsbD0iI2NmZDhl
YSIvPgogIDxyZWN0IHg9IjY0IiB5PSIxMjgiIHdpZHRoPSIxNTAiIGhlaWdodD0iMTQiIHJ4PSI3
IiBmaWxsPSIjZTdlZGY3Ii8+CiAgPHJlY3QgeD0iNjQiIHk9IjE1NiIgd2lkdGg9IjMyMCIgaGVp
Z2h0PSIxMCIgcng9IjUiIGZpbGw9IiNlZWYyZjgiLz4KICA8cmVjdCB4PSI2NCIgeT0iMTc4IiB3
aWR0aD0iMzAwIiBoZWlnaHQ9IjEwIiByeD0iNSIgZmlsbD0iI2VlZjJmOCIvPgogIDxyZWN0IHg9
IjY0IiB5PSIyMDAiIHdpZHRoPSIyNjAiIGhlaWdodD0iMTAiIHJ4PSI1IiBmaWxsPSIjZWVmMmY4
Ii8+CiAgPGc+CiAgICA8cmVjdCB4PSIyNTAiIHk9IjEyMCIgd2lkdGg9IjEzNCIgaGVpZ2h0PSI5
MiIgcng9IjEyIiBmaWxsPSJ1cmwoI2cxKSIvPgogICAgPHBhdGggZD0iTTI4NiAxNzZoNDRhMTMg
MTMgMCAwIDAgMS42LTI1LjkgMTkgMTkgMCAwIDAtMzYtNS40QTE1IDE1IDAgMCAwIDI4NiAxNzZa
IiBmaWxsPSIjZmZmIiBvcGFjaXR5PSIuOTUiLz4KICAgIDxwYXRoIGQ9Ik0zMTYgMTU4djIybS0x
MS0xMSAxMSAxMSAxMS0xMSIgc3Ryb2tlPSIjM2E1YmQ5IiBzdHJva2Utd2lkdGg9IjMiIHN0cm9r
ZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPgogIDwvZz4KICA8Y2ly
Y2xlIGN4PSIzOTIiIGN5PSIyNDgiIHI9IjI2IiBmaWxsPSIjZWFmMGZjIi8+CiAgPHBhdGggZD0i
TTM4NCAyNDhsNiA2IDEyLTEyIiBzdHJva2U9IiMzYTViZDkiIHN0cm9rZS13aWR0aD0iMy40IiBz
dHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KPC9zdmc+CkRF
Q09ZX0hFUk9TVkcKCmNhdCA+ICIkRC9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgPDwnREVDT1lf
TUFOSUZFU1QnCnsKICAibmFtZSI6ICJAQEJSQU5EQEAgQ2xvdWQiLAogICJzaG9ydF9uYW1lIjog
IkBAQlJBTkRAQCIsCiAgInN0YXJ0X3VybCI6ICIvIiwKICAiZGlzcGxheSI6ICJzdGFuZGFsb25l
IiwKICAiYmFja2dyb3VuZF9jb2xvciI6ICIjZWVmMmY4IiwKICAidGhlbWVfY29sb3IiOiAiIzNh
NWJkOSIsCiAgImljb25zIjogWwogICAgeyAic3JjIjogIi9hcHBsZS10b3VjaC1pY29uLnBuZyIs
ICJzaXplcyI6ICIxODB4MTgwIiwgInR5cGUiOiAiaW1hZ2UvcG5nIiB9LAogICAgeyAic3JjIjog
Ii9mYXZpY29uLmljbyIsICJzaXplcyI6ICJhbnkiLCAidHlwZSI6ICJpbWFnZS94LWljb24iIH0K
ICBdCn0KREVDT1lfTUFOSUZFU1QKCmNhdCA+ICIkRC9pbmRleC5odG1sIiA8PCdERUNPWV9JTkRF
WCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9
IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdp
ZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9p
bmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZl
cnJlciIgLz4KPHRpdGxlPkBAQlJBTkRAQCBDbG91ZCDigJQgU2VjdXJlIHN0b3JhZ2UgZm9yIHlv
dXIgZmlsZXM8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iQEBCUkFO
REBAIENsb3VkIGtlZXBzIHlvdXIgZG9jdW1lbnRzLCBwaG90b3MgYW5kIGJhY2t1cHMgZW5jcnlw
dGVkIGFuZCBhdmFpbGFibGUgb24gZXZlcnkgZGV2aWNlLiIgLz4KPGxpbmsgcmVsPSJpY29uIiBo
cmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0i
L2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNz
ZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fz
c2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9Indy
YXAgYmFyIj4KICAgIDxkaXYgY2xhc3M9ImJyYW5kIj4KICAgICAgPHN2ZyBjbGFzcz0ibWFyayIg
dmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+CiAgICAg
ICAgPHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPgog
ICAgICAgIDxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAw
IDAgMC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPgogICAgICA8
L3N2Zz4KICAgICAgPHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+CiAgICA8L2Rpdj4K
ICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iIyI+UHJvZHVjdDwvYT4KICAg
ICAgPGEgaHJlZj0iIyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iIyI+U2VjdXJpdHk8L2E+
CiAgICAgIDxhIGhyZWY9IiMiPkRvY3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5h
di1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3QiIGhyZWY9IiNzaWduaW4iPlNpZ24gaW48L2E+
CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9IiNzaWduaW4iPkdldCBzdGFydGVkPC9hPgogICAg
PC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAiPgogIDxkaXYgY2xh
c3M9ImdyaWQiPgogICAgPHNlY3Rpb24gY2xhc3M9InBpdGNoIHJldmVhbCI+CiAgICAgIDxkaXYg
Y2xhc3M9ImV5ZWJyb3ciPkVuY3J5cHRlZCBmaWxlIHN0b3JhZ2U8L2Rpdj4KICAgICAgPGgxPllv
dXIgZmlsZXMsIHNhZmUgYW5kIGluIHN5bmMgZXZlcnl3aGVyZS48L2gxPgogICAgICA8cCBjbGFz
cz0ibGVkZSI+QEBCUkFOREBAIENsb3VkIGtlZXBzIGRvY3VtZW50cywgcGhvdG9zIGFuZCBiYWNr
dXBzIGVuY3J5cHRlZCBhdCByZXN0IGFuZCByZWFkeSBvbiBldmVyeSBkZXZpY2UuIFNoYXJlIGEg
bGluaywgcmVzdG9yZSBhIHZlcnNpb24sIGtlZXAgd29ya2luZyBvZmZsaW5lLjwvcD4KICAgICAg
PHVsIGNsYXNzPSJmZWF0Ij4KICAgICAgICA8bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgi
IHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0
cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5FbmQtdG8t
ZW5kIGVuY3J5cHRpb24gd2l0aCBjbGllbnQtc2lkZSBrZXlzPC9saT4KICAgICAgICA8bGk+PHN2
ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5
IDE3bC01LTUiLz48L3N2Zz5WZXJzaW9uIGhpc3RvcnkgYW5kIDMwLWRheSBmaWxlIHJlY292ZXJ5
PC9saT4KICAgICAgICA8bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
Mi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5EZXNrdG9wLCBtb2JpbGUgYW5k
IHdlYiDigJQgYXV0b21hdGljIHN5bmM8L2xpPgogICAgICA8L3VsPgogICAgICA8aW1nIGNsYXNz
PSJoZXJvLWltZyIgc3JjPSIvYXNzZXRzL2hlcm8uc3ZnIiBhbHQ9IkZpbGVzIHN5bmNlZCB0byB0
aGUgY2xvdWQiIHdpZHRoPSI0NjAiIGhlaWdodD0iMzIwIiAvPgogICAgICA8ZGl2IGNsYXNzPSJ0
cnVzdCI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTYiIGhlaWdodD0iMTYiIHZpZXdCb3g9IjAgMCAy
NCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMiI+
PHBhdGggZD0iTTEyIDIyczgtNCA4LTEwVjVsLTgtMy04IDN2N2MwIDYgOCAxMCA4IDEwWiIvPjwv
c3ZnPgogICAgICAgIERhdGEgY2VudGVycyBpbiB0aGUgRVUgwrcgOTkuOSUgdXB0aW1lCiAgICAg
IDwvZGl2PgogICAgPC9zZWN0aW9uPgoKICAgIDxzZWN0aW9uIGNsYXNzPSJhdXRoIHJldmVhbCBk
MiIgaWQ9InNpZ25pbiI+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICAgIDxoMj5TaWdu
IGluPC9oMj4KICAgICAgICA8cCBjbGFzcz0ic3ViIj5XZWxjb21lIGJhY2suIFVzZSB5b3VyIEBA
QlJBTkRAQCBDbG91ZCBhY2NvdW50LjwvcD4KICAgICAgICA8ZGl2IGNsYXNzPSJtc2ciIGlkPSJt
c2ciIHJvbGU9ImFsZXJ0Ij48L2Rpdj4KICAgICAgICA8Zm9ybSBpZD0ibG9naW4iIG5vdmFsaWRh
dGU+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgICAgICAgIDxsYWJlbCBmb3I9
ImVtYWlsIj5FbWFpbDwvbGFiZWw+CiAgICAgICAgICAgIDxpbnB1dCBpZD0iZW1haWwiIG5hbWU9
ImVtYWlsIiB0eXBlPSJlbWFpbCIgYXV0b2NvbXBsZXRlPSJ1c2VybmFtZSIgcGxhY2Vob2xkZXI9
InlvdUBleGFtcGxlLmNvbSIgcmVxdWlyZWQgLz4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAg
PGRpdiBjbGFzcz0iZmllbGQiPgogICAgICAgICAgICA8bGFiZWwgZm9yPSJwYXNzd29yZCI+UGFz
c3dvcmQ8L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgaWQ9InBhc3N3b3JkIiBuYW1lPSJwYXNz
d29yZCIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0iY3VycmVudC1wYXNzd29yZCIgcGxh
Y2Vob2xkZXI9IuKAouKAouKAouKAouKAouKAouKAouKAoiIgcmVxdWlyZWQgLz4KICAgICAgICAg
IDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icm93Ij4KICAgICAgICAgICAgPGxhYmVsIGNs
YXNzPSJyZW1lbWJlciI+PGlucHV0IHR5cGU9ImNoZWNrYm94IiBuYW1lPSJyZW1lbWJlciIgLz4g
S2VlcCBtZSBzaWduZWQgaW48L2xhYmVsPgogICAgICAgICAgICA8YSBjbGFzcz0ibGluayIgaHJl
Zj0iIyI+Rm9yZ290IHBhc3N3b3JkPzwvYT4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGJ1
dHRvbiBjbGFzcz0iYnRuIGJsb2NrIiB0eXBlPSJzdWJtaXQiIGlkPSJzdWJtaXQiPlNpZ24gaW48
L2J1dHRvbj4KICAgICAgICA8L2Zvcm0+CiAgICAgICAgPGRpdiBjbGFzcz0iZGl2aWRlciI+b3I8
L2Rpdj4KICAgICAgICA8cCBjbGFzcz0iYWx0Ij5OZXcgdG8gQEBCUkFOREBAIENsb3VkPyA8YSBj
bGFzcz0ibGluayIgaHJlZj0iIyI+Q3JlYXRlIGFuIGFjY291bnQ8L2E+PC9wPgogICAgICA8L2Rp
dj4KICAgIDwvc2VjdGlvbj4KICA8L2Rpdj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNz
PSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBp
ZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFu
PjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iIyI+U2VjdXJpdHk8L2E+CiAgICAgIDxh
IGhyZWY9IiMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0iIyI+UHJpdmFjeTwvYT4KICAgICAg
PGEgaHJlZj0iIyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9IiMiPlN1cHBvcnQ8L2E+CiAgICA8
L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xv
dWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+Cgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMi
IGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfSU5ERVgKCmNhdCA+ICIkRC9u
Z2lueC5jb25mIiA8PCdERUNPWV9OR0lOWCcKbGltaXRfcmVxX3pvbmUgJGJpbmFyeV9yZW1vdGVf
YWRkciB6b25lPWF1dGhfbGltaXQ6MTBtIHJhdGU9M3IvbTsKbGltaXRfcmVxX3N0YXR1cyA0Mjk7
CgptYXAgJHJlcXVlc3RfaWQgJGF1dGhfZXJyb3JfbXNnIHsKICAgIGRlZmF1bHQgICAgICAgIklu
Y29ycmVjdCBlbWFpbCBvciBwYXNzd29yZC4gUGxlYXNlIHRyeSBhZ2Fpbi4iOwogICAgIn5eWzAt
M10iICAgICAiQWNjb3VudCBub3QgZm91bmQuIjsKICAgICJ+Xls0LTddIiAgICAgIkluY29ycmVj
dCBwYXNzd29yZC4iOwogICAgIn5eWzgtYl0iICAgICAiQWNjb3VudCB0ZW1wb3JhcmlseSBsb2Nr
ZWQuIFRyeSBhZ2FpbiBsYXRlci4iOwogICAgIn5eW2MtZl0iICAgICAiVG9vIG1hbnkgYXR0ZW1w
dHMuIFBsZWFzZSB3YWl0IGFuZCB0cnkgYWdhaW4uIjsKfQoKc2VydmVyIHsKICAgIGxpc3RlbiA4
MDsKICAgIGxpc3RlbiBbOjpdOjgwOwogICAgc2VydmVyX25hbWUgXzsKCiAgICBhZGRfaGVhZGVy
IFgtQ29udGVudC1UeXBlLU9wdGlvbnMgIm5vc25pZmYiIGFsd2F5czsKICAgIGFkZF9oZWFkZXIg
WC1GcmFtZS1PcHRpb25zICJTQU1FT1JJR0lOIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFgtUGVy
bWl0dGVkLUNyb3NzLURvbWFpbi1Qb2xpY2llcyAibm9uZSIgYWx3YXlzOwogICAgYWRkX2hlYWRl
ciBYLVJvYm90cy1UYWcgIm5vaW5kZXgsIG5vZm9sbG93IiBhbHdheXM7CiAgICBhZGRfaGVhZGVy
IFgtWFNTLVByb3RlY3Rpb24gIjE7IG1vZGU9YmxvY2siIGFsd2F5czsKICAgIGFkZF9oZWFkZXIg
UmVmZXJyZXItUG9saWN5ICJuby1yZWZlcnJlciIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBTdHJp
Y3QtVHJhbnNwb3J0LVNlY3VyaXR5ICJtYXgtYWdlPTE1NTUyMDAwOyBpbmNsdWRlU3ViRG9tYWlu
cyIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBDb250ZW50LVNlY3VyaXR5LVBvbGljeSAiZGVmYXVs
dC1zcmMgJ3NlbGYnOyBzY3JpcHQtc3JjICdzZWxmJzsgc3R5bGUtc3JjICdzZWxmJyAndW5zYWZl
LWlubGluZSc7IGltZy1zcmMgJ3NlbGYnIGRhdGE6OyBjb25uZWN0LXNyYyAnc2VsZic7IGZvbnQt
c3JjICdzZWxmJzsgb2JqZWN0LXNyYyAnbm9uZSc7IGZyYW1lLWFuY2VzdG9ycyAnbm9uZSc7IGJh
c2UtdXJpICdzZWxmJzsiIGFsd2F5czsKCiAgICBzZXJ2ZXJfdG9rZW5zIG9mZjsKICAgIGFjY2Vz
c19sb2cgb2ZmOwoKICAgICMg0KHRgtCw0YLQuNC60LAg0L/RgNC40LvQvtC20LXQvdC40Y8g4oCU
INC+0YLQtNCw0ZHQvCDQvdCw0L/RgNGP0LzRg9GOINGBINC00LvQuNC90L3Ri9C8INC60Y3RiNC+
0LwsINC60LDQuiDQvdCw0YHRgtC+0Y/RidC40Lkg0LHQuNC70LQKICAgIGxvY2F0aW9uIF5+IC9h
c3NldHMvIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBleHBp
cmVzIDMwZDsKICAgICAgICBhZGRfaGVhZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1tdXRh
YmxlIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBYLUNvbnRlbnQtVHlwZS1PcHRpb25zICJu
b3NuaWZmIiBhbHdheXM7CiAgICAgICAgdHJ5X2ZpbGVzICR1cmkgPTQwNDsKICAgIH0KCiAgICBs
b2NhdGlvbiAvIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBp
bmRleCBpbmRleC5odG1sOwogICAgICAgIHRyeV9maWxlcyAkdXJpICR1cmkvIC9pbmRleC5odG1s
OwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvc3RhdHVzJCB7CiAgICAgICAgZGVmYXVsdF90
eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVBvd2VyZWQtQnkgIkBA
U0xVR0BALWFwaSIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVx
dWVzdF9pZCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgWC1Db250ZW50LVR5cGUtT3B0aW9u
cyAibm9zbmlmZiIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJu
by1yZWZlcnJlciIgYWx3YXlzOwogICAgICAgIHJldHVybiAyMDAgJ3sib25saW5lIjp0cnVlLCJt
YWludGVuYW5jZSI6ZmFsc2UsInZlcnNpb24iOiIzLjIuNyIsImJ1aWxkIjoiMjAyNS4xMS4wMiIs
InByb2R1Y3QiOiJAQEJSQU5EQEAgQ2xvdWQiLCJhcGkiOiIxLjAifSc7CiAgICB9CgogICAgZXJy
b3JfcGFnZSA0MjkgPSBAcmF0ZV9saW1pdGVkOwogICAgbG9jYXRpb24gQHJhdGVfbGltaXRlZCB7
CiAgICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRl
ciBSZXRyeS1BZnRlciAiMjAiIGFsd2F5czsKICAgICAgICByZXR1cm4gNDI5ICd7InN0YXR1cyI6
ImVycm9yIiwibWVzc2FnZSI6IlRvbyBtYW55IHJlcXVlc3RzLiBUcnkgYWdhaW4gaW4gMjAgc2Vj
b25kcy4ifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9hdXRoJCB7CiAgICAgICAgbGlt
aXRfcmVxIHpvbmU9YXV0aF9saW1pdCBidXJzdD0yIG5vZGVsYXk7CiAgICAgICAgYWNjZXNzX2xv
ZyAvdmFyL2xvZy9teWZha2VzaXRlL2FjY2Vzcy5sb2cgY29tYmluZWQ7CiAgICAgICAgZGVmYXVs
dF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQg
IiRyZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBTZXQtQ29va2llICJhYl9z
ZXNzaW9uPWV5SmhiR2NpT2lKSVV6STFOaUo5LiRyZXF1ZXN0X2lkLnNpZzsgUGF0aD0vOyBIdHRw
T25seTsgU2VjdXJlOyBTYW1lU2l0ZT1TdHJpY3QiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVy
IFNldC1Db29raWUgIl9fSG9zdC1hYl9wcml2YWN5PWFjazsgUGF0aD0vOyBTZWN1cmU7IFNhbWVT
aXRlPVN0cmljdCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJu
by1yZWZlcnJlciIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MDEgJ3sic3RhdHVzIjoiZXJyb3Ii
LCJtZXNzYWdlIjoiJGF1dGhfZXJyb3JfbXNnIn0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9h
cGkvZmlsZXMoLy4qKT8kIHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsK
ICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAg
ICAgICByZXR1cm4gNDAxICd7InN0YXR1cyI6ImVycm9yIiwibWVzc2FnZSI6IkF1dGhlbnRpY2F0
aW9uIHJlcXVpcmVkIn0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvdXNlcnMoLy4qKT8k
IHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRfaGVh
ZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICByZXR1cm4gNDAx
ICd7InN0YXR1cyI6ImVycm9yIiwibWVzc2FnZSI6IkF1dGhlbnRpY2F0aW9uIHJlcXVpcmVkIn0n
OwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvc2V0dGluZ3MkIHsKICAgICAgICBkZWZhdWx0
X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAi
JHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICByZXR1cm4gMjAwICd7InN0YXR1cyI6Im9rIiwi
bGFuZyI6ImVuIiwidGhlbWUiOiJhdXRvIiwibm90aWZpY2F0aW9ucyI6dHJ1ZSwidHdvX2ZhY3Rv
ciI6ZmFsc2UsInN0b3JhZ2UiOnsidXNlZCI6NDg5MjMxMDAwMCwidG90YWwiOjIxNDc0ODM2NDgw
fSwibGFzdF9sb2dpbiI6IjIwMjYtMDQtMTBUMTg6MzI6MDdaIn0nOwogICAgfQoKICAgIGxvY2F0
aW9uID0gL3JvYm90cy50eHQgewogICAgICAgIGRlZmF1bHRfdHlwZSB0ZXh0L3BsYWluOwogICAg
ICAgIHJldHVybiAyMDAgJ1VzZXItYWdlbnQ6ICoKQWxsb3c6IC8KRGlzYWxsb3c6IC9hcGkvCkRp
c2FsbG93OiAvYWRtaW4vCkRpc2FsbG93OiAvaW50ZXJuYWwvCic7CiAgICB9CgogICAgbG9jYXRp
b24gPSAvaGVhcnRiZWF0IHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsK
ICAgICAgICByZXR1cm4gMjAwICd7Im9rIjp0cnVlLCJ0cyI6JG1zZWN9JzsKICAgIH0KCiAgICBs
b2NhdGlvbiA9IC8ud2VsbC1rbm93bi9zZWN1cml0eS50eHQgewogICAgICAgIGRlZmF1bHRfdHlw
ZSB0ZXh0L3BsYWluOwogICAgICAgIGFkZF9oZWFkZXIgQWNjZXNzLUNvbnRyb2wtQWxsb3ctT3Jp
Z2luICIqIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDIwMCAnQ29udGFjdDogbWFpbHRvOmFkbWlu
QEBATUFJTl9ET01BSU5AQApQcmVmZXJyZWQtTGFuZ3VhZ2VzOiBlbgpFeHBpcmVzOiAyMDI3LTAx
LTAxVDAwOjAwOjAwWgonOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9cLndlbGwta25vd24vKD8h
c2VjdXJpdHlcLnR4dCkgeyByZXR1cm4gNDA0OyB9CgogICAgbG9jYXRpb24gPSAvZmF2aWNvbi5p
Y28gewogICAgICAgIHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGV4cGlyZXMg
MzBkOwogICAgICAgIGFkZF9oZWFkZXIgQ2FjaGUtQ29udHJvbCAicHVibGljLCBpbW11dGFibGUi
IGFsd2F5czsKICAgIH0KICAgIGxvY2F0aW9uID0gL2FwcGxlLXRvdWNoLWljb24ucG5nIHsKICAg
ICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBleHBpcmVzIDMwZDsKICAg
ICAgICBhZGRfaGVhZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1tdXRhYmxlIiBhbHdheXM7
CiAgICB9CgogICAgbG9jYXRpb24gPSAvbG9nLXJvdGF0ZS1ieS1zaXplLnNoIHsgcmV0dXJuIDQw
NDsgfQogICAgbG9jYXRpb24gPSAvZGF0YS9sb2ctcm90YXRlLWJ5LXNpemUuc2ggeyByZXR1cm4g
NDA0OyB9CgogICAgbG9jYXRpb24gfiBcLnBocCQgewogICAgICAgIHJvb3QgL3Vzci9zaGFyZS9u
Z2lueC9odG1sOwogICAgICAgIGZhc3RjZ2lfcGFzcyBwaHAtZnBtOjkwMDA7CiAgICAgICAgZmFz
dGNnaV9pbmRleCBpbmRleC5waHA7CiAgICAgICAgZmFzdGNnaV9wYXJhbSBTQ1JJUFRfRklMRU5B
TUUgJGRvY3VtZW50X3Jvb3QkZmFzdGNnaV9zY3JpcHRfbmFtZTsKICAgICAgICBpbmNsdWRlIGZh
c3RjZ2lfcGFyYW1zOwogICAgICAgIGZhc3RjZ2lfaGlkZV9oZWFkZXIgWC1Qb3dlcmVkLUJ5Owog
ICAgfQoKICAgIGxvY2F0aW9uIH4gXi8oPzpcLmh0Lip8XC5naXQuKnxcLmVudi4qfGRhdGEvfGNv
bmZpZy98bGliL3wzcmRwYXJ0eS98dGVtcGxhdGVzLykgeyByZXR1cm4gNDA0OyB9CgogICAgZXJy
b3JfcGFnZSA1MDAgNTAyIDUwMyA1MDQgLzUweC5odG1sOwogICAgbG9jYXRpb24gPSAvNTB4Lmh0
bWwgeyByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsgfQp9CkRFQ09ZX05HSU5YCgpjYXQgPiAi
JFJPT1QvZG9ja2VyLWNvbXBvc2UueW1sIiA8PCdERUNPWV9DT01QT1NFJwpzZXJ2aWNlczoKICBm
YWtlc2l0ZToKICAgIGltYWdlOiBuZ2lueDphbHBpbmUKICAgIGNvbnRhaW5lcl9uYW1lOiBAQFNM
VUdAQC1kZWNveQogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIHBvcnRzOgogICAgICAt
ICIxMjcuMC4wLjE6ODA4MDo4MCIKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL2FwcGxlLXRv
dWNoLWljb24ucG5nOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9hcHBsZS10b3VjaC1pY29uLnBuZzpy
bwogICAgICAtIC4vZGF0YS9mYXZpY29uLmljbzovdXNyL3NoYXJlL25naW54L2h0bWwvZmF2aWNv
bi5pY286cm8KICAgICAgLSAuL2RhdGEvaW5kZXguaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwv
aW5kZXguaHRtbDpybwogICAgICAtIC4vZGF0YS9hc3NldHM6L3Vzci9zaGFyZS9uZ2lueC9odG1s
L2Fzc2V0czpybwogICAgICAtIC4vZGF0YS9uZ2lueC5jb25mOi9ldGMvbmdpbngvY29uZi5kL2Rl
ZmF1bHQuY29uZjpybwogICAgICAtIC4vZGF0YS9waHBpbmZvLnBocDovdXNyL3NoYXJlL25naW54
L2h0bWwvcGhwaW5mby5waHA6cm8KICAgICAgLSAuL2RhdGEvcm9ib3RzLnR4dDovdXNyL3NoYXJl
L25naW54L2h0bWwvcm9ib3RzLnR4dDpybwogICAgICAtIC4vZGF0YS9zdGF0dXMucGhwOi91c3Iv
c2hhcmUvbmdpbngvaHRtbC9zdGF0dXMucGhwOnJvCiAgICAgIC0gLi9kYXRhL1ZFUlNJT046L3Vz
ci9zaGFyZS9uZ2lueC9odG1sL1ZFUlNJT046cm8KICAgICAgLSAvdmFyL2xvZy9teWZha2VzaXRl
Oi92YXIvbG9nL215ZmFrZXNpdGUKICAgIG5ldHdvcmtzOiBbZmFrZXNpdGVdCiAgICBkZXBlbmRz
X29uOiBbcGhwLWZwbV0KICBwaHAtZnBtOgogICAgaW1hZ2U6IHBocDo4LjMtZnBtLWFscGluZQog
ICAgY29udGFpbmVyX25hbWU6IEBAU0xVR0BALWRlY295LXBocAogICAgcmVzdGFydDogdW5sZXNz
LXN0b3BwZWQKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL3N0YXR1cy5waHA6L3Vzci9zaGFy
ZS9uZ2lueC9odG1sL3N0YXR1cy5waHA6cm8KICAgICAgLSAuL2RhdGEvcGhwaW5mby5waHA6L3Vz
ci9zaGFyZS9uZ2lueC9odG1sL3BocGluZm8ucGhwOnJvCiAgICBuZXR3b3JrczogW2Zha2VzaXRl
XQpuZXR3b3JrczoKICBmYWtlc2l0ZToKICAgIGRyaXZlcjogYnJpZGdlCkRFQ09ZX0NPTVBPU0UK
CmVjaG8gIj09IFszLzVdINCk0LDQudC70Ysg0LfQsNC/0LjRgdCw0L3RiyA9PSIKCmVjaG8gIj09
IFs0LzVdINCf0LXRgNC10YHQvtC30LTQsNGOINC60L7QvdGC0LXQudC90LXRgCAo0L/RgNC40LzQ
tdC90Y/RjiDQvNC+0L3RgtCw0LYgL2Fzc2V0cykg0Lgg0L/QtdGA0LXRh9C40YLRi9Cy0LDRjiDQ
utC+0L3RhNC40LMgPT0iCmNkICIkUk9PVCIKZG9ja2VyIGNvbXBvc2UgdXAgLWQKZG9ja2VyIGV4
ZWMgQEBTTFVHQEAtZGVjb3kgbmdpbnggLXMgcmVsb2FkIDI+L2Rldi9udWxsIHx8IGRvY2tlciBy
ZXN0YXJ0IEBAU0xVR0BALWRlY295ID4vZGV2L251bGwKCmVjaG8gIj09IFs1LzVdINCf0YDQvtCy
0LXRgNC60LAg0L3QsCAxMjcuMC4wLjE6ODA4MCA9PSIKc2xlZXAgMwplY2hvICItLS0gLyAo0LrQ
vtC0ICsg0YDQsNC30LzQtdGAOyDQstC10YEg0YPRiNGR0Lsg0LIg0LDRgdGB0LXRgtGLKSAtLS0i
CmN1cmwgLXMgLW8gL2Rldi9udWxsIC13ICcgIEhUVFAgJXtodHRwX2NvZGV9ICBwYWdlX2J5dGVz
PSV7c2l6ZV9kb3dubG9hZH1cbicgaHR0cDovLzEyNy4wLjAuMTo4MDgwLwplY2hvICItLS0gL2Fz
c2V0cy9hcHAuY3NzIC0tLSIKY3VybCAtcyAtRCAtIC1vIC9kZXYvbnVsbCBodHRwOi8vMTI3LjAu
MC4xOjgwODAvYXNzZXRzL2FwcC5jc3MgfCBncmVwIC1pRSAnSFRUUC98XmNvbnRlbnQtdHlwZXxe
Y2FjaGUtY29udHJvbHxeY29udGVudC1sZW5ndGgnIHwgc2VkICdzL14vICAvJwplY2hvICItLS0g
L2Fzc2V0cy9hcHAuanMgLS0tIgpjdXJsIC1zIC1EIC0gLW8gL2Rldi9udWxsIGh0dHA6Ly8xMjcu
MC4wLjE6ODA4MC9hc3NldHMvYXBwLmpzICB8IGdyZXAgLWlFICdIVFRQL3xeY29udGVudC10eXBl
fF5jYWNoZS1jb250cm9sfF5jb250ZW50LWxlbmd0aCcgfCBzZWQgJ3MvXi8gIC8nCmVjaG8gIi0t
LSAvYXNzZXRzL2hlcm8uc3ZnIC0tLSIKY3VybCAtcyAtRCAtIC1vIC9kZXYvbnVsbCBodHRwOi8v
MTI3LjAuMC4xOjgwODAvYXNzZXRzL2hlcm8uc3ZnIHwgZ3JlcCAtaUUgJ0hUVFAvfF5jb250ZW50
LXR5cGV8XmNhY2hlLWNvbnRyb2wnIHwgc2VkICdzL14vICAvJwplY2hvICItLS0gL2Fzc2V0cy9z
aXRlLndlYm1hbmlmZXN0IC0tLSIKY3VybCAtcyAtRCAtIC1vIC9kZXYvbnVsbCBodHRwOi8vMTI3
LjAuMC4xOjgwODAvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QgfCBncmVwIC1pRSAnSFRUUC98XmNv
bnRlbnQtdHlwZScgfCBzZWQgJ3MvXi8gIC8nCmVjaG8gIi0tLSAvYXBpL3N0YXR1cyAtLS0iCmVj
aG8gLW4gIiAgIjsgY3VybCAtcyBodHRwOi8vMTI3LjAuMC4xOjgwODAvYXBpL3N0YXR1czsgZWNo
bwplY2hvICItLS0gL2FwaS9hdXRoIChQT1NUIC0+INCw0L3Qs9C70LjQudGB0LrQsNGPINC+0YjQ
uNCx0LrQsCkgLS0tIgplY2hvIC1uICIgICI7IGN1cmwgLXMgLVggUE9TVCBodHRwOi8vMTI3LjAu
MC4xOjgwODAvYXBpL2F1dGggLUggJ0NvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbicgLWQg
J3siZW1haWwiOiJhQGIuY28iLCJwYXNzd29yZCI6IngifSc7IGVjaG8KZWNobyAiLS0tINC90LXR
gdGD0YnQtdGB0YLQstGD0Y7RidC40Lkg0LDRgdGB0LXRgiAo0LbQtNGR0LwgNDA0LCDQvdC1IEhU
TUwt0YTQvtC70LvQsdGN0LopIC0tLSIKY3VybCAtcyAtbyAvZGV2L251bGwgLXcgJyAgSFRUUCAl
e2h0dHBfY29kZX1cbicgaHR0cDovLzEyNy4wLjAuMTo4MDgwL2Fzc2V0cy9ub3BlLmpzCmVjaG8K
ZWNobyAi4pyFINCT0L7RgtC+0LLQvi4g0KLQtdC/0LXRgNGMINGB0L3QsNGA0YPQttC4ICjQstC4
0L3QtNCwLCBWUE4g0JLQq9Ca0JspOiIKZWNobyAiICAgY3VybC5leGUgLXNJIGh0dHBzOi8vQEBN
QUlOX0RPTUFJTkBAL2Fzc2V0cy9hcHAuanMgICAtPiAyMDAgKyBDYWNoZS1Db250cm9sOiBwdWJs
aWMsIGltbXV0YWJsZSIKZWNobyAiICAgY3VybC5leGUgLXNJIGh0dHBzOi8vQEBNQUlOX0RPTUFJ
TkBAL2Fzc2V0cy9hcHAuY3NzICAtPiAyMDAsIGNvbnRlbnQtdHlwZSB0ZXh0L2NzcyIKZWNobyAi
ICAgY3VybC5leGUgLXNJIGh0dHBzOi8vQEBNQUlOX0RPTUFJTkBAICAgICAgICAgICAgICAgICAt
PiBDU1Ag0YPQttC1INCx0LXQtyBjZG5qcy9nb29nbGUiCmVjaG8gIiAgIGN1cmwuZXhlIC1zICBo
dHRwczovL0BATUFJTl9ET01BSU5AQCB8IGZpbmRzdHIgL2kgXCJhc3NldHNcIiAgLT4g0LLQuNC0
0L3RiyDRgdGB0YvQu9C60Lgg0L3QsCAvYXNzZXRzLyoiCmVjaG8KZWNobyAi0J7RgtC60LDRgiwg
0LXRgdC70Lgg0YfRgtC+LdGC0L4g0L/QvtC10YXQsNC70L46IgplY2hvICIgICBjcCBcIiREL2lu
ZGV4Lmh0bWwuYmFrLiR0c1wiIFwiJEQvaW5kZXguaHRtbFwiIgplY2hvICIgICBjcCBcIiREL25n
aW54LmNvbmYuYmFrLiR0c1wiIFwiJEQvbmdpbnguY29uZlwiIgplY2hvICIgICBjcCBcIiRST09U
L2RvY2tlci1jb21wb3NlLnltbC5iYWsuJHRzXCIgXCIkUk9PVC9kb2NrZXItY29tcG9zZS55bWxc
IiIKZWNobyAiICAgY2QgXCIkUk9PVFwiICYmIGRvY2tlciBjb21wb3NlIHVwIC1kICYmIGRvY2tl
ciByZXN0YXJ0IEBAU0xVR0BALWRlY295Igo=
__B64__
  base64 -d > "$d/deploy-decoy-sunshine.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1kZWNv
eS1zdW5zaGluZS5zaCDigJQg0L/QsNGA0LjRgtC10YIg0LTQtdC60L7RjyDQvdCwIEBAUkVMQVlf
TkFNRUBAINGBIEBARVhJVF9OQU1FQEAKIyAg0JfQsNC80LXQvdGP0LXRgiDRgdGC0LDRgNGD0Y4g
0L/RgNC+0YHRgtGD0Y4g0YHRgtGA0LDQvdC40YbRgyDCq015U3BoZXJlwrsgKENhZGR5IGZpbGVf
c2VydmVyKSDQvdCwINGC0L7RgiDQttC1CiMgINC60L7QvdGC0LXQudC90LXRgNC90YvQuSDRgdCw
0LnRgiDCq0BAQlJBTkRAQCBDbG91ZMK7ICjQvNC90L7Qs9C+0YHRgtGA0LDQvdC40YfQvdC40Lop
LCDRh9GC0L4g0Lgg0L3QsCBAQEVYSVRfTkFNRUBALAojICDQuCDQv9C10YDQtdC60LvRjtGH0LDQ
tdGCIENhZGR5IEBAUkVMQVlfTkFNRUBAINC90LAg0L/RgNC+0LrRgdC40YDQvtCy0LDQvdC40LUg
0LIg0LTQtdC60L7QuSAoMTI3LjAuMC4xOjgwODApLgojICDQl9Cw0L/Rg9GB0Log0L3QsCDQodCV
0KDQktCV0KDQlSBTVU5TSElORTogIHN1ZG8gYmFzaCBkZXBsb3ktZGVjb3ktc3Vuc2hpbmUuc2gK
IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbAoKRE9NQUlOPSJAQFJFTEFZ
X0RPTUFJTkBAIgpBQ01FX0VNQUlMPSJhZG1pbkBAQFNMVUdAQC5jb20iCldTX1BBVEg9Ii93c25n
IgpYSFRUUF9QQVRIPSIveGgiCkRFQ09ZPSIvb3B0L0BAU0xVR0BAL2RlY295IgpDQUREWUZJTEU9
Ii9vcHQvQEBTTFVHQEAvY2FkZHkvQ2FkZHlmaWxlIgpDQUREWV9DVFI9IkBAU0xVR0BALWNhZGR5
Igp0cz0kKGRhdGUgKyVZJW0lZC0lSCVNJVMpCgpbIC1kIC9vcHQvQEBTTFVHQEAvY2FkZHkgXSB8
fCB7IGVjaG8gItCd0LXRgiAvb3B0L0BAU0xVR0BAL2NhZGR5IOKAlCDRgdC90LDRh9Cw0LvQsCBk
ZXBsb3ktc3Vuc2hpbmUuc2giOyBleGl0IDE7IH0KCmVjaG8gIj09IFsxLzVdINCR0LDQt9CwINC0
0LXQutC+0Y8gKG15ZmFrZXNpdGU6IGZhdmljb24vcGhwL3JvYm90cy9WRVJTSU9OKSAtPiAkREVD
T1kgPT0iCmNvbW1hbmQgLXYgZ2l0ID4vZGV2L251bGwgfHwgeyBhcHQtZ2V0IHVwZGF0ZSAteSA+
L2Rldi9udWxsICYmIGFwdC1nZXQgaW5zdGFsbCAteSBnaXQgPi9kZXYvbnVsbDsgfQppZiBbIC1k
ICIkREVDT1kvLmdpdCIgXTsgdGhlbiBnaXQgLUMgIiRERUNPWSIgcHVsbCAtLWZmLW9ubHkgfHwg
dHJ1ZQplbHNlIHJtIC1yZiAiJERFQ09ZIjsgZ2l0IGNsb25lIC0tZGVwdGggMSBodHRwczovL2dp
dGh1Yi5jb20vaXF1YmlrL215ZmFrZXNpdGUuZ2l0ICIkREVDT1kiOyBmaQpta2RpciAtcCAiJERF
Q09ZL2RhdGEvYXNzZXRzIiAvdmFyL2xvZy9teWZha2VzaXRlCgplY2hvICI9PSBbMi81XSDQmtC7
0LDQtNGDINC/0L7QstC10YDRhSDRgdGC0YDQsNC90LjRhtGLIEBAQlJBTkRAQCBDbG91ZCwg0LDR
gdGB0LXRgtGLLCBuZ2lueC5jb25mLCBjb21wb3NlID09IgpjYXQgPiAiJERFQ09ZL2RhdGEvbmdp
bnguY29uZiIgPDwnREVDT1lfTkdJTlgnCmxpbWl0X3JlcV96b25lICRiaW5hcnlfcmVtb3RlX2Fk
ZHIgem9uZT1hdXRoX2xpbWl0OjEwbSByYXRlPTNyL207CmxpbWl0X3JlcV9zdGF0dXMgNDI5OwoK
bWFwICRyZXF1ZXN0X2lkICRhdXRoX2Vycm9yX21zZyB7CiAgICBkZWZhdWx0ICAgICAgICJJbmNv
cnJlY3QgZW1haWwgb3IgcGFzc3dvcmQuIFBsZWFzZSB0cnkgYWdhaW4uIjsKICAgICJ+XlswLTNd
IiAgICAgIkFjY291bnQgbm90IGZvdW5kLiI7CiAgICAifl5bNC03XSIgICAgICJJbmNvcnJlY3Qg
cGFzc3dvcmQuIjsKICAgICJ+Xls4LWJdIiAgICAgIkFjY291bnQgdGVtcG9yYXJpbHkgbG9ja2Vk
LiBUcnkgYWdhaW4gbGF0ZXIuIjsKICAgICJ+XltjLWZdIiAgICAgIlRvbyBtYW55IGF0dGVtcHRz
LiBQbGVhc2Ugd2FpdCBhbmQgdHJ5IGFnYWluLiI7Cn0KCnNlcnZlciB7CiAgICBsaXN0ZW4gODA7
CiAgICBsaXN0ZW4gWzo6XTo4MDsKICAgIHNlcnZlcl9uYW1lIF87CgogICAgYWRkX2hlYWRlciBY
LUNvbnRlbnQtVHlwZS1PcHRpb25zICJub3NuaWZmIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFgt
RnJhbWUtT3B0aW9ucyAiU0FNRU9SSUdJTiIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBYLVBlcm1p
dHRlZC1Dcm9zcy1Eb21haW4tUG9saWNpZXMgIm5vbmUiIGFsd2F5czsKICAgIGFkZF9oZWFkZXIg
WC1Sb2JvdHMtVGFnICJub2luZGV4LCBub2ZvbGxvdyIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBY
LVhTUy1Qcm90ZWN0aW9uICIxOyBtb2RlPWJsb2NrIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFJl
ZmVycmVyLVBvbGljeSAibm8tcmVmZXJyZXIiIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgU3RyaWN0
LVRyYW5zcG9ydC1TZWN1cml0eSAibWF4LWFnZT0xNTU1MjAwMDsgaW5jbHVkZVN1YkRvbWFpbnMi
IGFsd2F5czsKICAgIGFkZF9oZWFkZXIgQ29udGVudC1TZWN1cml0eS1Qb2xpY3kgImRlZmF1bHQt
c3JjICdzZWxmJzsgc2NyaXB0LXNyYyAnc2VsZic7IHN0eWxlLXNyYyAnc2VsZicgJ3Vuc2FmZS1p
bmxpbmUnOyBpbWctc3JjICdzZWxmJyBkYXRhOjsgY29ubmVjdC1zcmMgJ3NlbGYnOyBmb250LXNy
YyAnc2VsZic7IG9iamVjdC1zcmMgJ25vbmUnOyBmcmFtZS1hbmNlc3RvcnMgJ25vbmUnOyBiYXNl
LXVyaSAnc2VsZic7IiBhbHdheXM7CgogICAgc2VydmVyX3Rva2VucyBvZmY7CiAgICBhY2Nlc3Nf
bG9nIG9mZjsKCiAgICAjINCh0YLQsNGC0LjQutCwINC/0YDQuNC70L7QttC10L3QuNGPIOKAlCDQ
vtGC0LTQsNGR0Lwg0L3QsNC/0YDRj9C80YPRjiDRgSDQtNC70LjQvdC90YvQvCDQutGN0YjQvtC8
LCDQutCw0Log0L3QsNGB0YLQvtGP0YnQuNC5INCx0LjQu9C0CiAgICBsb2NhdGlvbiBefiAvYXNz
ZXRzLyB7CiAgICAgICAgcm9vdCAvdXNyL3NoYXJlL25naW54L2h0bWw7CiAgICAgICAgZXhwaXJl
cyAzMGQ7CiAgICAgICAgYWRkX2hlYWRlciBDYWNoZS1Db250cm9sICJwdWJsaWMsIGltbXV0YWJs
ZSIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgWC1Db250ZW50LVR5cGUtT3B0aW9ucyAibm9z
bmlmZiIgYWx3YXlzOwogICAgICAgIHRyeV9maWxlcyAkdXJpID00MDQ7CiAgICB9CgogICAgbG9j
YXRpb24gLyB7CiAgICAgICAgcm9vdCAvdXNyL3NoYXJlL25naW54L2h0bWw7CiAgICAgICAgaW5k
ZXggaW5kZXguaHRtbDsKICAgICAgICB0cnlfZmlsZXMgJHVyaSAkdXJpLmh0bWwgJHVyaS8gL2lu
ZGV4Lmh0bWw7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9zdGF0dXMkIHsKICAgICAgICBk
ZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUG93ZXJl
ZC1CeSAiQEBTTFVHQEAtYXBpIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3Qt
SWQgIiRyZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBYLUNvbnRlbnQtVHlw
ZS1PcHRpb25zICJub3NuaWZmIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBSZWZlcnJlci1Q
b2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDIwMCAneyJvbmxpbmUi
OnRydWUsIm1haW50ZW5hbmNlIjpmYWxzZSwidmVyc2lvbiI6IjMuMi43IiwiYnVpbGQiOiIyMDI1
LjExLjAyIiwicHJvZHVjdCI6IkBAQlJBTkRAQCBDbG91ZCIsImFwaSI6IjEuMCJ9JzsKICAgIH0K
CiAgICBlcnJvcl9wYWdlIDQyOSA9IEByYXRlX2xpbWl0ZWQ7CiAgICBsb2NhdGlvbiBAcmF0ZV9s
aW1pdGVkIHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBh
ZGRfaGVhZGVyIFJldHJ5LUFmdGVyICIyMCIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MjkgJ3si
c3RhdHVzIjoiZXJyb3IiLCJtZXNzYWdlIjoiVG9vIG1hbnkgcmVxdWVzdHMuIFRyeSBhZ2FpbiBp
biAyMCBzZWNvbmRzLiJ9JzsKICAgIH0KCiAgICBsb2NhdGlvbiB+IF4vYXBpL2F1dGgkIHsKICAg
ICAgICBsaW1pdF9yZXEgem9uZT1hdXRoX2xpbWl0IGJ1cnN0PTIgbm9kZWxheTsKICAgICAgICBh
Y2Nlc3NfbG9nIC92YXIvbG9nL215ZmFrZXNpdGUvYWNjZXNzLmxvZyBjb21iaW5lZDsKICAgICAg
ICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVx
dWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFNldC1Db29r
aWUgImFiX3Nlc3Npb249ZXlKaGJHY2lPaUpJVXpJMU5pSjkuJHJlcXVlc3RfaWQuc2lnOyBQYXRo
PS87IEh0dHBPbmx5OyBTZWN1cmU7IFNhbWVTaXRlPVN0cmljdCIgYWx3YXlzOwogICAgICAgIGFk
ZF9oZWFkZXIgU2V0LUNvb2tpZSAiX19Ib3N0LWFiX3ByaXZhY3k9YWNrOyBQYXRoPS87IFNlY3Vy
ZTsgU2FtZVNpdGU9U3RyaWN0IiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBSZWZlcnJlci1Q
b2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDQwMSAneyJzdGF0dXMi
OiJlcnJvciIsIm1lc3NhZ2UiOiIkYXV0aF9lcnJvcl9tc2cifSc7CiAgICB9CgogICAgbG9jYXRp
b24gfiBeL2FwaS9yZWdpc3RlciQgewogICAgICAgIGxpbWl0X3JlcSB6b25lPWF1dGhfbGltaXQg
YnVyc3Q9MiBub2RlbGF5OwogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwog
ICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAg
ICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJuby1yZWZlcnJlciIgYWx3YXlzOwogICAg
ICAgIHJldHVybiAyMDAgJ3sic3RhdHVzIjoib2siLCJtZXNzYWdlIjoiQ2hlY2sgeW91ciBpbmJv
eCDigJQgd2Ugc2VudCBhIHZlcmlmaWNhdGlvbiBsaW5rIHRvIGNvbmZpcm0geW91ciBlbWFpbC4i
fSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9yZXNldCQgewogICAgICAgIGxpbWl0X3Jl
cSB6b25lPWF1dGhfbGltaXQgYnVyc3Q9MiBub2RlbGF5OwogICAgICAgIGRlZmF1bHRfdHlwZSBh
cHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVxdWVz
dF9pZCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgUmVmZXJyZXItUG9saWN5ICJuby1yZWZl
cnJlciIgYWx3YXlzOwogICAgICAgIHJldHVybiAyMDAgJ3sic3RhdHVzIjoib2siLCJtZXNzYWdl
IjoiSWYgYW4gYWNjb3VudCBleGlzdHMgZm9yIHRoYXQgZW1haWwsIHdlIGp1c3Qgc2VudCByZXNl
dCBpbnN0cnVjdGlvbnMuIn0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvZmlsZXMoLy4q
KT8kIHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRf
aGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICByZXR1cm4g
NDAxICd7InN0YXR1cyI6ImVycm9yIiwibWVzc2FnZSI6IkF1dGhlbnRpY2F0aW9uIHJlcXVpcmVk
In0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvdXNlcnMoLy4qKT8kIHsKICAgICAgICBk
ZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVz
dC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICByZXR1cm4gNDAxICd7InN0YXR1cyI6
ImVycm9yIiwibWVzc2FnZSI6IkF1dGhlbnRpY2F0aW9uIHJlcXVpcmVkIn0nOwogICAgfQoKICAg
IGxvY2F0aW9uIH4gXi9hcGkvc2V0dGluZ3MkIHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGlj
YXRpb24vanNvbjsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQi
IGFsd2F5czsKICAgICAgICByZXR1cm4gMjAwICd7InN0YXR1cyI6Im9rIiwibGFuZyI6ImVuIiwi
dGhlbWUiOiJhdXRvIiwibm90aWZpY2F0aW9ucyI6dHJ1ZSwidHdvX2ZhY3RvciI6ZmFsc2UsInN0
b3JhZ2UiOnsidXNlZCI6NDg5MjMxMDAwMCwidG90YWwiOjIxNDc0ODM2NDgwfSwibGFzdF9sb2dp
biI6IjIwMjYtMDQtMTBUMTg6MzI6MDdaIn0nOwogICAgfQoKICAgIGxvY2F0aW9uID0gL3JvYm90
cy50eHQgewogICAgICAgIGRlZmF1bHRfdHlwZSB0ZXh0L3BsYWluOwogICAgICAgIHJldHVybiAy
MDAgJ1VzZXItYWdlbnQ6ICoKQWxsb3c6IC8KRGlzYWxsb3c6IC9hcGkvCkRpc2FsbG93OiAvYWRt
aW4vCkRpc2FsbG93OiAvaW50ZXJuYWwvCic7CiAgICB9CgogICAgbG9jYXRpb24gPSAvaGVhcnRi
ZWF0IHsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsKICAgICAgICByZXR1
cm4gMjAwICd7Im9rIjp0cnVlLCJ0cyI6JG1zZWN9JzsKICAgIH0KCiAgICBsb2NhdGlvbiA9IC8u
d2VsbC1rbm93bi9zZWN1cml0eS50eHQgewogICAgICAgIGRlZmF1bHRfdHlwZSB0ZXh0L3BsYWlu
OwogICAgICAgIGFkZF9oZWFkZXIgQWNjZXNzLUNvbnRyb2wtQWxsb3ctT3JpZ2luICIqIiBhbHdh
eXM7CiAgICAgICAgcmV0dXJuIDIwMCAnQ29udGFjdDogbWFpbHRvOmFkbWluQEBATUFJTl9ET01B
SU5AQApQcmVmZXJyZWQtTGFuZ3VhZ2VzOiBlbgpFeHBpcmVzOiAyMDI3LTAxLTAxVDAwOjAwOjAw
WgonOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9cLndlbGwta25vd24vKD8hc2VjdXJpdHlcLnR4
dCkgeyByZXR1cm4gNDA0OyB9CgogICAgbG9jYXRpb24gPSAvZmF2aWNvbi5pY28gewogICAgICAg
IHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGV4cGlyZXMgMzBkOwogICAgICAg
IGFkZF9oZWFkZXIgQ2FjaGUtQ29udHJvbCAicHVibGljLCBpbW11dGFibGUiIGFsd2F5czsKICAg
IH0KICAgIGxvY2F0aW9uID0gL2FwcGxlLXRvdWNoLWljb24ucG5nIHsKICAgICAgICByb290IC91
c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBleHBpcmVzIDMwZDsKICAgICAgICBhZGRfaGVh
ZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1tdXRhYmxlIiBhbHdheXM7CiAgICB9CgogICAg
bG9jYXRpb24gPSAvbG9nLXJvdGF0ZS1ieS1zaXplLnNoIHsgcmV0dXJuIDQwNDsgfQogICAgbG9j
YXRpb24gPSAvZGF0YS9sb2ctcm90YXRlLWJ5LXNpemUuc2ggeyByZXR1cm4gNDA0OyB9CgogICAg
bG9jYXRpb24gfiBcLnBocCQgewogICAgICAgIHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwog
ICAgICAgIGZhc3RjZ2lfcGFzcyBwaHAtZnBtOjkwMDA7CiAgICAgICAgZmFzdGNnaV9pbmRleCBp
bmRleC5waHA7CiAgICAgICAgZmFzdGNnaV9wYXJhbSBTQ1JJUFRfRklMRU5BTUUgJGRvY3VtZW50
X3Jvb3QkZmFzdGNnaV9zY3JpcHRfbmFtZTsKICAgICAgICBpbmNsdWRlIGZhc3RjZ2lfcGFyYW1z
OwogICAgICAgIGZhc3RjZ2lfaGlkZV9oZWFkZXIgWC1Qb3dlcmVkLUJ5OwogICAgfQoKICAgIGxv
Y2F0aW9uIH4gXi8oPzpcLmh0Lip8XC5naXQuKnxcLmVudi4qfGRhdGEvfGNvbmZpZy98bGliL3wz
cmRwYXJ0eS98dGVtcGxhdGVzLykgeyByZXR1cm4gNDA0OyB9CgogICAgZXJyb3JfcGFnZSA1MDAg
NTAyIDUwMyA1MDQgLzUweC5odG1sOwogICAgbG9jYXRpb24gPSAvNTB4Lmh0bWwgeyByb290IC91
c3Ivc2hhcmUvbmdpbngvaHRtbDsgfQp9CkRFQ09ZX05HSU5YCgpjYXQgPiAiJERFQ09ZL2RhdGEv
aW5kZXguaHRtbCIgPDwnREVDT1lfSU5ERVgnCjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJl
biI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQi
IGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBu
YW1lPSJyb2JvdHMiIGNvbnRlbnQ9Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJy
ZWZlcnJlciIgY29udGVudD0ibm8tcmVmZXJyZXIiIC8+Cjx0aXRsZT5AQEJSQU5EQEAgQ2xvdWQg
4oCUIFNlY3VyZSBzdG9yYWdlIGZvciB5b3VyIGZpbGVzPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVz
Y3JpcHRpb24iIGNvbnRlbnQ9IkBAQlJBTkRAQCBDbG91ZCBrZWVwcyB5b3VyIGRvY3VtZW50cywg
cGhvdG9zIGFuZCBiYWNrdXBzIGVuY3J5cHRlZCBhbmQgYXZhaWxhYmxlIG9uIGV2ZXJ5IGRldmlj
ZS4iIC8+CjxsaW5rIHJlbD0iaWNvbiIgaHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9
ImFwcGxlLXRvdWNoLWljb24iIGhyZWY9Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsg
cmVsPSJtYW5pZmVzdCIgaHJlZj0iL2Fzc2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayBy
ZWw9InN0eWxlc2hlZXQiIGhyZWY9Ii9hc3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4K
PGhlYWRlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhy
ZWY9Ii8iPjxzdmcgY2xhc3M9Im1hcmsiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIg
YXJpYS1oaWRkZW49InRydWUiPjxyZWN0IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZp
bGw9IiMzYTViZDkiLz48cGF0aCBkPSJNMTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45
OCA1IDUgMCAwIDAtOS41My0xLjRBNCA0IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48
L3N2Zz48c3Bhbj5AQEJSQU5EQEAmbmJzcDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNz
PSJsaW5rcyI+CiAgICAgIDxhIGhyZWY9Ii8jZmVhdHVyZXMiIGNsYXNzPSJhY3RpdmUiPlByb2R1
Y3Q8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcmljaW5nIj5QcmljaW5nPC9hPgogICAgICA8YSBocmVm
PSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvZG9jcyI+RG9jczwvYT4K
ICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9z
dCIgaHJlZj0iLyNzaWduaW4iPlNpZ24gaW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9
Ii9zaWdudXAiPkdldCBzdGFydGVkPC9hPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoK
PG1haW4gY2xhc3M9IndyYXAiPgogIDxkaXYgY2xhc3M9ImdyaWQiPgogICAgPHNlY3Rpb24gY2xh
c3M9InBpdGNoIHJldmVhbCIgaWQ9ImZlYXR1cmVzIj4KICAgICAgPGRpdiBjbGFzcz0iZXllYnJv
dyI+RW5jcnlwdGVkIGZpbGUgc3RvcmFnZTwvZGl2PgogICAgICA8aDE+WW91ciBmaWxlcywgc2Fm
ZSBhbmQgaW4gc3luYyBldmVyeXdoZXJlLjwvaDE+CiAgICAgIDxwIGNsYXNzPSJsZWRlIj5AQEJS
QU5EQEAgQ2xvdWQga2VlcHMgZG9jdW1lbnRzLCBwaG90b3MgYW5kIGJhY2t1cHMgZW5jcnlwdGVk
IGF0IHJlc3QgYW5kIHJlYWR5IG9uIGV2ZXJ5IGRldmljZS4gU2hhcmUgYSBsaW5rLCByZXN0b3Jl
IGEgdmVyc2lvbiwga2VlcCB3b3JraW5nIG9mZmxpbmUuPC9wPgogICAgICA8dWwgY2xhc3M9ImZl
YXQiPgogICAgICAgIDxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAw
IDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIy
LjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPkVuZC10by1lbmQgZW5jcnlwdGlv
biB3aXRoIGNsaWVudC1zaWRlIGtleXM8L2xpPgogICAgICAgIDxsaT48c3ZnIHdpZHRoPSIxOCIg
aGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJl
bnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwv
c3ZnPlZlcnNpb24gaGlzdG9yeSBhbmQgMzAtZGF5IGZpbGUgcmVjb3Zlcnk8L2xpPgogICAgICAg
IDxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxs
PSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9
Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPkRlc2t0b3AsIG1vYmlsZSBhbmQgd2ViIOKAlCBhdXRv
bWF0aWMgc3luYzwvbGk+CiAgICAgIDwvdWw+CiAgICAgIDxpbWcgY2xhc3M9Imhlcm8taW1nIiBz
cmM9Ii9hc3NldHMvaGVyby5zdmciIGFsdD0iRmlsZXMgc3luY2VkIHRvIHRoZSBjbG91ZCIgd2lk
dGg9IjQ2MCIgaGVpZ2h0PSIzMjAiIC8+CiAgICAgIDxkaXYgY2xhc3M9InRydXN0Ij4KICAgICAg
ICA8c3ZnIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJu
b25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyIj48cGF0aCBkPSJNMTIg
MjJzOC00IDgtMTBWNWwtOC0zLTggM3Y3YzAgNiA4IDEwIDggMTBaIi8+PC9zdmc+CiAgICAgICAg
RGF0YSBjZW50ZXJzIGluIHRoZSBFVSDCtyA5OS45JSB1cHRpbWUKICAgICAgPC9kaXY+CiAgICA8
L3NlY3Rpb24+CgogICAgPHNlY3Rpb24gY2xhc3M9ImF1dGggcmV2ZWFsIGQyIiBpZD0ic2lnbmlu
Ij4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGgyPlNpZ24gaW48L2gyPgogICAg
ICAgIDxwIGNsYXNzPSJzdWIiPldlbGNvbWUgYmFjay4gVXNlIHlvdXIgQEBCUkFOREBAIENsb3Vk
IGFjY291bnQuPC9wPgogICAgICAgIDxkaXYgY2xhc3M9Im1zZyIgaWQ9Im1zZyIgcm9sZT0iYWxl
cnQiPjwvZGl2PgogICAgICAgIDxmb3JtIGlkPSJsb2dpbiIgbm92YWxpZGF0ZT4KICAgICAgICAg
IDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgICAgICAgPGxhYmVsIGZvcj0iZW1haWwiPkVtYWls
PC9sYWJlbD4KICAgICAgICAgICAgPGlucHV0IGlkPSJlbWFpbCIgbmFtZT0iZW1haWwiIHR5cGU9
ImVtYWlsIiBhdXRvY29tcGxldGU9InVzZXJuYW1lIiBwbGFjZWhvbGRlcj0ieW91QGV4YW1wbGUu
Y29tIiByZXF1aXJlZCAvPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJm
aWVsZCI+CiAgICAgICAgICAgIDxsYWJlbCBmb3I9InBhc3N3b3JkIj5QYXNzd29yZDwvbGFiZWw+
CiAgICAgICAgICAgIDxpbnB1dCBpZD0icGFzc3dvcmQiIG5hbWU9InBhc3N3b3JkIiB0eXBlPSJw
YXNzd29yZCIgYXV0b2NvbXBsZXRlPSJjdXJyZW50LXBhc3N3b3JkIiBwbGFjZWhvbGRlcj0i4oCi
4oCi4oCi4oCi4oCi4oCi4oCi4oCiIiByZXF1aXJlZCAvPgogICAgICAgICAgPC9kaXY+CiAgICAg
ICAgICA8ZGl2IGNsYXNzPSJyb3ciPgogICAgICAgICAgICA8bGFiZWwgY2xhc3M9InJlbWVtYmVy
Ij48aW5wdXQgdHlwZT0iY2hlY2tib3giIG5hbWU9InJlbWVtYmVyIiAvPiBLZWVwIG1lIHNpZ25l
ZCBpbjwvbGFiZWw+CiAgICAgICAgICAgIDxhIGNsYXNzPSJsaW5rIiBocmVmPSIvcmVzZXQiPkZv
cmdvdCBwYXNzd29yZD88L2E+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xh
c3M9ImJ0biBibG9jayIgdHlwZT0ic3VibWl0IiBpZD0ic3VibWl0Ij5TaWduIGluPC9idXR0b24+
CiAgICAgICAgPC9mb3JtPgogICAgICAgIDxkaXYgY2xhc3M9ImRpdmlkZXIiPm9yPC9kaXY+CiAg
ICAgICAgPHAgY2xhc3M9ImFsdCI+TmV3IHRvIEBAQlJBTkRAQCBDbG91ZD8gPGEgY2xhc3M9Imxp
bmsiIGhyZWY9Ii9zaWdudXAiPkNyZWF0ZSBhbiBhY2NvdW50PC9hPjwvcD4KICAgICAgPC9kaXY+
CiAgICA8L3NlY3Rpb24+CiAgPC9kaXY+CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0i
d3JhcCBmb290Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9
InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48
L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAg
ICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3ki
PlByaXZhY3k8L2E+CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhy
ZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlk
PSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVy
Pgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+Cjwv
aHRtbD4KREVDT1lfSU5ERVgKCmNhdCA+ICIkREVDT1kvZGF0YS9wcmljaW5nLmh0bWwiIDw8J0RF
Q09ZX1BSSUNJTkcnCjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0
YSBjaGFyc2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRo
PWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNv
bnRlbnQ9Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJyZWZlcnJlciIgY29udGVu
dD0ibm8tcmVmZXJyZXIiIC8+Cjx0aXRsZT5QcmljaW5nIOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3Rp
dGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iQEBCUkFOREBAIENsb3VkIHBy
aWNpbmcg4oCUIGZyZWUsIFBsdXMgYW5kIEJ1c2luZXNzIHBsYW5zIHdpdGggZW5kLXRvLWVuZCBl
bmNyeXB0aW9uLiIgLz4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+Cjxs
aW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAv
Pgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+
CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+
Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJi
cmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxs
PSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiBy
eD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAg
MCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0i
I2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxu
YXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4K
ICAgICAgPGEgaHJlZj0iL3ByaWNpbmciIGNsYXNzPSJhY3RpdmUiPlByaWNpbmc8L2E+CiAgICAg
IDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5E
b2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEgY2xh
c3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0
biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9o
ZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1haW4iPgogIDxkaXYgY2xhc3M9InBhZ2Ut
aGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5QcmljaW5nPC9kaXY+CiAgICA8aDE+U2lt
cGxlIHBsYW5zIHRoYXQgc2NhbGUgd2l0aCB5b3UuPC9oMT4KICAgIDxwPlN0YXJ0IGZyZWUuIFVw
Z3JhZGUgd2hlbiB5b3UgbmVlZCBtb3JlIHNwYWNlIG9yIHRlYW0gZmVhdHVyZXMuIEFsbCBwbGFu
cyBpbmNsdWRlIGVuZC10by1lbmQgZW5jcnlwdGlvbi48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFz
cz0icHJpY2luZyI+CiAgICA8ZGl2IGNsYXNzPSJ0aWVyIj48aDM+RnJlZTwvaDM+PGRpdiBjbGFz
cz0icHJpY2UiPuKCrDA8c3Bhbj4vbW88L3NwYW4+PC9kaXY+PHVsPjxsaT48c3ZnIHdpZHRoPSIx
OCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1
cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIv
Pjwvc3ZnPjUgR0IgZW5jcnlwdGVkIHN0b3JhZ2U8L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVp
Z2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRD
b2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3Zn
PlN5bmMgb24gMiBkZXZpY2VzPC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZp
ZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9r
ZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz4zMC1kYXkgZmls
ZSByZWNvdmVyeTwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIw
IDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9
IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+TGluayBzaGFyaW5nPC9saT48
L3VsPjxhIGNsYXNzPSJidG4gYmxvY2siIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVkPC9hPjwv
ZGl2PgogICAgPGRpdiBjbGFzcz0idGllciBmZWF0LXRpZXIiPjxzcGFuIGNsYXNzPSJ0YWciPk1v
c3QgcG9wdWxhcjwvc3Bhbj48aDM+UGx1czwvaDM+PGRpdiBjbGFzcz0icHJpY2UiPuKCrDQ8c3Bh
bj4vbW88L3NwYW4+PC9kaXY+PHVsPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmll
d0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPjIwMCBHQiBlbmNy
eXB0ZWQgc3RvcmFnZTwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94
PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lk
dGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+VW5saW1pdGVkIGRldmlj
ZXM8L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0
IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxw
YXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlZlcnNpb24gaGlzdG9yeTwvbGk+PGxpPjxz
dmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYg
OSAxN2wtNS01Ii8+PC9zdmc+UGFzc3dvcmQtcHJvdGVjdGVkIGxpbmtzPC9saT48bGk+PHN2ZyB3
aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ry
b2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3
bC01LTUiLz48L3N2Zz5Qcmlvcml0eSBzdXBwb3J0PC9saT48L3VsPjxhIGNsYXNzPSJidG4gYmxv
Y2siIGhyZWY9Ii9zaWdudXAiPlN0YXJ0IFBsdXM8L2E+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ0
aWVyIj48aDM+QnVzaW5lc3M8L2gzPjxkaXYgY2xhc3M9InByaWNlIj7igqwxMjxzcGFuPi91c2Vy
L21vPC9zcGFuPjwvZGl2Pjx1bD48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdC
b3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13
aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz4yIFRCIHBlciB1c2Vy
PC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIg
ZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0
aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5UZWFtIGZvbGRlcnMgJiByb2xlczwvbGk+PGxp
Pjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIw
IDYgOSAxN2wtNS01Ii8+PC9zdmc+QWRtaW4gY29uc29sZSAmIGF1ZGl0IGxvZzwvbGk+PGxpPjxz
dmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUi
IHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYg
OSAxN2wtNS01Ii8+PC9zdmc+U1NPIC8gU0FNTDwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWln
aHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+
OTkuOSUgdXB0aW1lIFNMQTwvbGk+PC91bD48YSBjbGFzcz0iYnRuIGJsb2NrIiBocmVmPSIvc2ln
bnVwIj5Db250YWN0IHNhbGVzPC9hPjwvZGl2PgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgog
IDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNs
YXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0
dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNl
Y3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhy
ZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9h
PgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRp
dj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwv
ZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3Njcmlw
dD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1BSSUNJTkcKCmNhdCA+ICIkREVDT1kvZGF0YS9zZWN1
cml0eS5odG1sIiA8PCdERUNPWV9TRUNVUklUWScKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9
ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9y
dCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRh
IG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9
InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlNlY3VyaXR5IOKAlCBA
QEJSQU5EQEAgQ2xvdWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0i
SG93IEBAQlJBTkRAQCBDbG91ZCBlbmNyeXB0cyBhbmQgcHJvdGVjdHMgeW91ciBmaWxlczogY2xp
ZW50LXNpZGUga2V5cywgQUVTLTI1NiwgVExTIDEuMywgRVUgZGF0YSBjZW50ZXJzLiIgLz4KPGxp
bmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91
Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlm
ZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVz
aGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgog
IDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2
ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRl
bj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJk
OSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAg
MC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFu
PkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4K
ICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3By
aWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSIgY2xhc3M9ImFjdGl2
ZSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+
CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIv
I3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+
R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFz
cz0id3JhcCBwYWdlLW1haW4iPgogIDxkaXYgY2xhc3M9InBhZ2UtaGVhZCI+CiAgICA8ZGl2IGNs
YXNzPSJleWVicm93Ij5TZWN1cml0eTwvZGl2PgogICAgPGgxPllvdXIgZGF0YSwgZW5jcnlwdGVk
IGVuZCB0byBlbmQuPC9oMT4KICAgIDxwPlNlY3VyaXR5IGlzIHRoZSBkZWZhdWx0LCBub3QgYW4g
YWRkLW9uLiBIZXJlIGlzIGhvdyBAQEJSQU5EQEAgQ2xvdWQgcHJvdGVjdHMgeW91ciBmaWxlcy48
L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icHJvc2UiPgogICAgPGgyPkVuY3J5cHRpb248L2gy
PgogICAgPHA+RmlsZXMgYXJlIGVuY3J5cHRlZCBvbiB5b3VyIGRldmljZSBiZWZvcmUgdGhleSBh
cmUgdXBsb2FkZWQuIEVuY3J5cHRpb24ga2V5cyBhcmUgZGVyaXZlZCBmcm9tIHlvdXIgcGFzc3dv
cmQgYW5kIG5ldmVyIGxlYXZlIHlvdXIgZGV2aWNlcyBpbiBwbGFpbnRleHQsIHNvIHdlIGNhbm5v
dCByZWFkIHlvdXIgY29udGVudC4gRGF0YSBhdCByZXN0IGlzIHN0b3JlZCB3aXRoIEFFUy0yNTYg
YW5kIGFsbCB0cmFuc3BvcnQgaXMgcHJvdGVjdGVkIHdpdGggVExTIDEuMy48L3A+CiAgICA8aDI+
SW5mcmFzdHJ1Y3R1cmU8L2gyPgogICAgPHA+U3RvcmFnZSBhbmQgcHJvY2Vzc2luZyBydW4gaW4g
SVNPIDI3MDAxLWNlcnRpZmllZCBkYXRhIGNlbnRlcnMgaW4gdGhlIEV1cm9wZWFuIFVuaW9uLiBP
YmplY3Qgc3RvcmFnZSBpcyByZXBsaWNhdGVkIGFjcm9zcyBhdmFpbGFiaWxpdHkgem9uZXMsIGFu
ZCBkZWxldGVkIGZpbGVzIHJlbWFpbiByZWNvdmVyYWJsZSBmb3IgMzAgZGF5cyBiZWZvcmUgdGhl
eSBhcmUgcHVyZ2VkLjwvcD4KICAgIDxoMj5BY2Nlc3MgJmFtcDsgYWNjb3VudHM8L2gyPgogICAg
PHVsPgogICAgICA8bGk+T3B0aW9uYWwgdHdvLWZhY3RvciBhdXRoZW50aWNhdGlvbiAoVE9UUCBh
bmQgc2VjdXJpdHkga2V5cykuPC9saT4KICAgICAgPGxpPlNlc3Npb24gYW5kIGRldmljZSBtYW5h
Z2VtZW50IHdpdGggcmVtb3RlIHNpZ24tb3V0LjwvbGk+CiAgICAgIDxsaT5SYXRlLWxpbWl0ZWQg
YXV0aGVudGljYXRpb24gYW5kIGFub21hbHkgYWxlcnRzIG9uIG5ldyBzaWduLWlucy48L2xpPgog
ICAgPC91bD4KICAgIDxoMj5SZXNwb25zaWJsZSBkaXNjbG9zdXJlPC9oMj4KICAgIDxwPkZvdW5k
IHNvbWV0aGluZz8gV2Ugd2VsY29tZSByZXBvcnRzIGZyb20gc2VjdXJpdHkgcmVzZWFyY2hlcnMu
IFJlYWNoIHVzIGF0IDxhIGNsYXNzPSJsaW5rIiBocmVmPSJtYWlsdG86c2VjdXJpdHlAQEBNQUlO
X0RPTUFJTkBAIj5zZWN1cml0eUBAQE1BSU5fRE9NQUlOQEA8L2E+IOKAlCBzZWUgYWxzbyBvdXIg
PGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii8ud2VsbC1rbm93bi9zZWN1cml0eS50eHQiPnNlY3VyaXR5
LnR4dDwvYT4uPC9wPgogICAgPHAgY2xhc3M9Im11dGVkIj5MYXN0IHJldmlld2VkOiBOb3ZlbWJl
ciAyMDI1LjwvcD4KICA8L2Rpdj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3cmFw
IGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0ic2Rv
dCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwvZGl2
PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAg
PGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+UHJp
dmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJlZj0i
L3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9Inly
Ij4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+Cjxz
Y3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1s
PgpERUNPWV9TRUNVUklUWQoKY2F0ID4gIiRERUNPWS9kYXRhL3ByaXZhY3kuaHRtbCIgPDwnREVD
T1lfUFJJVkFDWScKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRh
IGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9
ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29u
dGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50
PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlByaXZhY3kgUG9saWN5IOKAlCBAQEJSQU5EQEAgQ2xv
dWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iQEBCUkFOREBAIENs
b3VkIHByaXZhY3kgcG9saWN5LiIgLz4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5p
Y28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWlj
b24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFu
aWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAv
Pgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxh
IGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMy
IDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWln
aHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41
IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41
WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwv
YT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJv
ZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhy
ZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9h
PgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdo
b3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJl
Zj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+
Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1haW4iPgogIDxkaXYgY2xhc3M9InBhZ2UtaGVhZCI+
CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5MZWdhbDwvZGl2PgogICAgPGgxPlByaXZhY3kgUG9s
aWN5PC9oMT4KICAgIDxwPkhvdyB3ZSBoYW5kbGUgeW91ciBkYXRhLiBUaGlzIHN1bW1hcnkgZXhw
bGFpbnMgd2hhdCB3ZSBjb2xsZWN0IGFuZCB3aHkuPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9
InByb3NlIj4KICAgIDxoMj5JbmZvcm1hdGlvbiB3ZSBjb2xsZWN0PC9oMj4KICAgIDxwPkFjY291
bnQgZGV0YWlscyB5b3UgcHJvdmlkZSAobmFtZSwgZW1haWwpLCBhbmQgdGVjaG5pY2FsIGRhdGEg
bmVlZGVkIHRvIHJ1biB0aGUgc2VydmljZSAoZGV2aWNlIHR5cGUsIElQIGFkZHJlc3MsIGxvZyB0
aW1lc3RhbXBzKS4gWW91ciBmaWxlcyBhcmUgZW5jcnlwdGVkIHdpdGgga2V5cyB3ZSBkbyBub3Qg
aG9sZCwgc28gd2UgY2Fubm90IGFjY2VzcyB0aGVpciBjb250ZW50cy48L3A+CiAgICA8aDI+SG93
IHdlIHVzZSBpdDwvaDI+CiAgICA8cD5UbyBwcm92aWRlIGFuZCBzZWN1cmUgdGhlIHNlcnZpY2Us
IHRvIGNvbW11bmljYXRlIGFib3V0IHlvdXIgYWNjb3VudCwgYW5kIHRvIGNvbXBseSB3aXRoIGxl
Z2FsIG9ibGlnYXRpb25zLiBXZSBkbyBub3Qgc2VsbCBwZXJzb25hbCBkYXRhIG9yIHVzZSBmaWxl
IGNvbnRlbnRzIGZvciBhZHZlcnRpc2luZy48L3A+CiAgICA8aDI+U3RvcmFnZSAmYW1wOyBlbmNy
eXB0aW9uPC9oMj4KICAgIDxwPkRhdGEgaXMgc3RvcmVkIGluIHRoZSBFdXJvcGVhbiBVbmlvbiBh
bmQgZW5jcnlwdGVkIGF0IHJlc3QuIEJhY2t1cHMgYXJlIHJldGFpbmVkIGZvciBkaXNhc3RlciBy
ZWNvdmVyeSBhbmQgcm90YXRlZCBvbiBhIGZpeGVkIHNjaGVkdWxlLjwvcD4KICAgIDxoMj5Zb3Vy
IHJpZ2h0czwvaDI+CiAgICA8dWw+CiAgICAgIDxsaT5BY2Nlc3MsIGNvcnJlY3Qgb3IgZXhwb3J0
IHlvdXIgZGF0YS48L2xpPgogICAgICA8bGk+RGVsZXRlIHlvdXIgYWNjb3VudCBhbmQgYXNzb2Np
YXRlZCBmaWxlcy48L2xpPgogICAgICA8bGk+T2JqZWN0IHRvIG9yIHJlc3RyaWN0IGNlcnRhaW4g
cHJvY2Vzc2luZy48L2xpPgogICAgPC91bD4KICAgIDxoMj5Db250YWN0PC9oMj4KICAgIDxwPlF1
ZXN0aW9ucyBhYm91dCBwcml2YWN5OiA8YSBjbGFzcz0ibGluayIgaHJlZj0ibWFpbHRvOnByaXZh
Y3lAQEBNQUlOX0RPTUFJTkBAIj5wcml2YWN5QEBATUFJTl9ET01BSU5AQDwvYT4uPC9wPgogICAg
PHAgY2xhc3M9Im11dGVkIj5MYXN0IHVwZGF0ZWQ6IE5vdmVtYmVyIDIwMjUuPC9wPgogIDwvZGl2
Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNs
YXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9
InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8
YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5T
dGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBo
cmVmPSIvdGVybXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwv
YT4KICAgIDwvbmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJB
TkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMv
YXBwLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1BSSVZBQ1kKCmNh
dCA+ICIkREVDT1kvZGF0YS90ZXJtcy5odG1sIiA8PCdERUNPWV9URVJNUycKPCFET0NUWVBFIGh0
bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0
YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNj
YWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ci
IC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxl
PlRlcm1zIG9mIFNlcnZpY2Ug4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9
ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJSQU5EQEAgQ2xvdWQgdGVybXMgb2Ygc2VydmljZS4i
IC8+CjxsaW5rIHJlbD0iaWNvbiIgaHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFw
cGxlLXRvdWNoLWljb24iIGhyZWY9Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVs
PSJtYW5pZmVzdCIgaHJlZj0iL2Fzc2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9
InN0eWxlc2hlZXQiIGhyZWY9Ii9hc3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhl
YWRlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9
Ii8iPjxzdmcgY2xhc3M9Im1hcmsiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJp
YS1oaWRkZW49InRydWUiPjxyZWN0IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9
IiMzYTViZDkiLz48cGF0aCBkPSJNMTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1
IDUgMCAwIDAtOS41My0xLjRBNCA0IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2
Zz48c3Bhbj5AQEJSQU5EQEAmbmJzcDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJs
aW5rcyI+CiAgICAgIDxhIGhyZWY9Ii8jZmVhdHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhy
ZWY9Ii9wcmljaW5nIj5QcmljaW5nPC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3Vy
aXR5PC9hPgogICAgICA8YSBocmVmPSIvZG9jcyI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRp
diBjbGFzcz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4i
PlNpZ24gaW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFy
dGVkPC9hPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAg
cGFnZS1tYWluIj4KICA8ZGl2IGNsYXNzPSJwYWdlLWhlYWQiPgogICAgPGRpdiBjbGFzcz0iZXll
YnJvdyI+TGVnYWw8L2Rpdj4KICAgIDxoMT5UZXJtcyBvZiBTZXJ2aWNlPC9oMT4KICAgIDxwPlRo
ZSBydWxlcyBmb3IgdXNpbmcgQEBCUkFOREBAIENsb3VkLiBCeSB1c2luZyB0aGUgc2VydmljZSB5
b3UgYWdyZWUgdG8gdGhlc2UgdGVybXMuPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InByb3Nl
Ij4KICAgIDxoMj4xLiBBY2NvdW50czwvaDI+CiAgICA8cD5Zb3UgYXJlIHJlc3BvbnNpYmxlIGZv
ciBhY3Rpdml0eSB1bmRlciB5b3VyIGFjY291bnQgYW5kIGZvciBrZWVwaW5nIHlvdXIgY3JlZGVu
dGlhbHMgc2VjdXJlLiBZb3UgbXVzdCBiZSBvbGQgZW5vdWdoIHRvIGZvcm0gYSBiaW5kaW5nIGNv
bnRyYWN0IGluIHlvdXIgY291bnRyeS48L3A+CiAgICA8aDI+Mi4gQWNjZXB0YWJsZSB1c2U8L2gy
PgogICAgPHA+RG8gbm90IHVzZSB0aGUgc2VydmljZSB0byBzdG9yZSBvciBkaXN0cmlidXRlIHVu
bGF3ZnVsIGNvbnRlbnQsIHRvIGluZnJpbmdlIG90aGVycycgcmlnaHRzLCBvciB0byBkaXNydXB0
IHRoZSBzZXJ2aWNlLiBXZSBtYXkgc3VzcGVuZCBhY2NvdW50cyB0aGF0IHZpb2xhdGUgdGhlc2Ug
dGVybXMuPC9wPgogICAgPGgyPjMuIEF2YWlsYWJpbGl0eTwvaDI+CiAgICA8cD5XZSBhaW0gZm9y
IGhpZ2ggYXZhaWxhYmlsaXR5IGJ1dCB0aGUgc2VydmljZSBpcyBwcm92aWRlZCAiYXMgaXMiLiBQ
bGFubmVkIG1haW50ZW5hbmNlIGlzIGFubm91bmNlZCBvbiB0aGUgc3RhdHVzIHBhZ2Ugd2hlcmUg
cHJhY3RpY2FsLjwvcD4KICAgIDxoMj40LiBMaW1pdGF0aW9uIG9mIGxpYWJpbGl0eTwvaDI+CiAg
ICA8cD5UbyB0aGUgZXh0ZW50IHBlcm1pdHRlZCBieSBsYXcsIHdlIGFyZSBub3QgbGlhYmxlIGZv
ciBpbmRpcmVjdCBvciBjb25zZXF1ZW50aWFsIGRhbWFnZXMuIEtlZXAgeW91ciBvd24gYmFja3Vw
cyBvZiBjcml0aWNhbCBkYXRhLjwvcD4KICAgIDxoMj41LiBDaGFuZ2VzPC9oMj4KICAgIDxwPldl
IG1heSB1cGRhdGUgdGhlc2UgdGVybXM7IG1hdGVyaWFsIGNoYW5nZXMgd2lsbCBiZSBjb21tdW5p
Y2F0ZWQgYnkgZW1haWwgb3IgaW4tYXBwIG5vdGljZS48L3A+CiAgICA8aDI+Q29udGFjdDwvaDI+
CiAgICA8cD5RdWVzdGlvbnM6IDxhIGNsYXNzPSJsaW5rIiBocmVmPSJtYWlsdG86bGVnYWxAQEBN
QUlOX0RPTUFJTkBAIj5sZWdhbEBAQE1BSU5fRE9NQUlOQEA8L2E+LjwvcD4KICAgIDxwIGNsYXNz
PSJtdXRlZCI+TGFzdCB1cGRhdGVkOiBOb3ZlbWJlciAyMDI1LjwvcD4KICA8L2Rpdj4KPC9tYWlu
PgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3Rh
dHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+
Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0i
L3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9h
PgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rl
cm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJlZj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8
L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xv
dWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIg
ZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgpERUNPWV9URVJNUwoKY2F0ID4gIiRERUNP
WS9kYXRhL3N0YXR1cy5odG1sIiA8PCdERUNPWV9TVEFUVVMnCjwhRE9DVFlQRSBodG1sPgo8aHRt
bCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0i
dmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAv
Pgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNvbnRlbnQ9Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0
YSBuYW1lPSJyZWZlcnJlciIgY29udGVudD0ibm8tcmVmZXJyZXIiIC8+Cjx0aXRsZT5TeXN0ZW0g
U3RhdHVzIOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlv
biIgY29udGVudD0iTGl2ZSBzdGF0dXMgb2YgQEBCUkFOREBAIENsb3VkIGNvbXBvbmVudHMuIiAv
Pgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVsPSJhcHBs
ZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5rIHJlbD0i
bWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJz
dHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFk
ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBocmVmPSIv
Ij48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEt
aGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIj
M2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYuOTggNSA1
IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+
PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFzcz0ibGlu
a3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8YSBocmVm
PSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0
eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYg
Y2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5T
aWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRl
ZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4KCjxtYWluIGNsYXNzPSJ3cmFwIHBh
Z2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFkIj4KICAgIDxkaXYgY2xhc3M9ImV5ZWJy
b3ciPlN5c3RlbSBTdGF0dXM8L2Rpdj4KICAgIDxoMT5DdXJyZW50IHNlcnZpY2Ugc3RhdHVzPC9o
MT4KICAgIDxwPkxpdmUgc3RhdHVzIG9mIEBAQlJBTkRAQCBDbG91ZCBjb21wb25lbnRzLiBTdWJz
Y3JpYmUgdG8gdXBkYXRlcyBvbiB0aGUgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9zdXBwb3J0Ij5z
dXBwb3J0IHBhZ2U8L2E+LjwvcD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJwcm9zZSIgc3R5bGU9
Im1heC13aWR0aDo3MjBweCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMtYmFubmVyIj48c3BhbiBj
bGFzcz0iZG90IG9rIj48L3NwYW4+IEFsbCBzeXN0ZW1zIG9wZXJhdGlvbmFsPC9kaXY+CiAgICA8
ZGl2IGNsYXNzPSJjb21wIj48c3Bhbj5BUEk8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBj
bGFzcz0iZG90Ij48L3NwYW4+T3BlcmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNz
PSJjb21wIj48c3Bhbj5XZWIgYXBwPC9zcGFuPjxzcGFuIGNsYXNzPSJvcCI+PHNwYW4gY2xhc3M9
ImRvdCI+PC9zcGFuPk9wZXJhdGlvbmFsPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY29t
cCI+PHNwYW4+RmlsZSBzeW5jPC9zcGFuPjxzcGFuIGNsYXNzPSJvcCI+PHNwYW4gY2xhc3M9ImRv
dCI+PC9zcGFuPk9wZXJhdGlvbmFsPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY29tcCI+
PHNwYW4+T2JqZWN0IHN0b3JhZ2U8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBjbGFzcz0i
ZG90Ij48L3NwYW4+T3BlcmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjb21w
Ij48c3Bhbj5BdXRoZW50aWNhdGlvbjwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNsYXNz
PSJkb3QiPjwvc3Bhbj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNv
bXAiPjxzcGFuPlNoYXJpbmcgJmFtcDsgbGlua3M8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3Bh
biBjbGFzcz0iZG90Ij48L3NwYW4+T3BlcmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8cCBjbGFz
cz0ibXV0ZWQiPlVwdGltZSBvdmVyIHRoZSBsYXN0IDkwIGRheXM6IDk5Ljk3JS4gVGltZXMgc2hv
d24gaW4gVVRDLjwvcD4KICA8L2Rpdj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3
cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0i
c2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwv
ZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAg
ICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+
UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJl
Zj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9
InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+
CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9o
dG1sPgpERUNPWV9TVEFUVVMKCmNhdCA+ICIkREVDT1kvZGF0YS9kb2NzLmh0bWwiIDw8J0RFQ09Z
X0RPQ1MnCjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0YSBjaGFy
c2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmlj
ZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNvbnRlbnQ9
Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJyZWZlcnJlciIgY29udGVudD0ibm8t
cmVmZXJyZXIiIC8+Cjx0aXRsZT5Eb2NzIOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3RpdGxlPgo8bWV0
YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iQEBCUkFOREBAIENsb3VkIGRvY3VtZW50YXRp
b246IGdldHRpbmcgc3RhcnRlZCwgdXBsb2Fkcywgc2hhcmluZywgc3luYyBjbGllbnRzIGFuZCBB
UEkuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVs
PSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5r
IHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsg
cmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+
CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBo
cmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUi
IGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBm
aWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYu
OTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+
PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFz
cz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8
YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5T
ZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiIGNsYXNzPSJhY3RpdmUiPkRvY3M8L2E+
CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hv
c3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVm
PSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4K
CjxtYWluIGNsYXNzPSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFkIj4K
ICAgIDxkaXYgY2xhc3M9ImV5ZWJyb3ciPkRvY3M8L2Rpdj4KICAgIDxoMT5Eb2N1bWVudGF0aW9u
PC9oMT4KICAgIDxwPkV2ZXJ5dGhpbmcgeW91IG5lZWQgdG8gZ2V0IHRoZSBtb3N0IG91dCBvZiBA
QEJSQU5EQEAgQ2xvdWQuPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImRvY3MiPgogICAgPG5h
diBjbGFzcz0idG9jIj4KICAgICAgPGEgaHJlZj0iI3N0YXJ0Ij5HZXR0aW5nIHN0YXJ0ZWQ8L2E+
CiAgICAgIDxhIGhyZWY9IiN1cGxvYWQiPlVwbG9hZGluZyBmaWxlczwvYT4KICAgICAgPGEgaHJl
Zj0iI3NoYXJlIj5TaGFyaW5nPC9hPgogICAgICA8YSBocmVmPSIjc3luYyI+U3luYyBjbGllbnRz
PC9hPgogICAgICA8YSBocmVmPSIjYXBpIj5BUEk8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xh
c3M9InByb3NlIj4KICAgICAgPGgyIGlkPSJzdGFydCI+R2V0dGluZyBzdGFydGVkPC9oMj4KICAg
ICAgPHA+Q3JlYXRlIGFuIGFjY291bnQsIGluc3RhbGwgdGhlIGRlc2t0b3Agb3IgbW9iaWxlIGFw
cCwgYW5kIHlvdXIgZmlsZXMgYmVnaW4gc3luY2luZyBhdXRvbWF0aWNhbGx5LiBUaGUgd2ViIGFw
cCBpcyBhdmFpbGFibGUgZnJvbSBhbnkgYnJvd3NlciB3aXRob3V0IGluc3RhbGxhdGlvbi48L3A+
CiAgICAgIDxoMiBpZD0idXBsb2FkIj5VcGxvYWRpbmcgZmlsZXM8L2gyPgogICAgICA8cD5EcmFn
IGZpbGVzIGludG8gdGhlIHdlYiBhcHAgb3IgZHJvcCB0aGVtIGludG8geW91ciBzeW5jZWQgZm9s
ZGVyLiBVcGxvYWRzIGFyZSBlbmNyeXB0ZWQgb24geW91ciBkZXZpY2UgYmVmb3JlIHRoZXkgbGVh
dmUgaXQuIExhcmdlIGZpbGVzIGFyZSBjaHVua2VkIGFuZCByZXN1bWFibGUuPC9wPgogICAgICA8
aDIgaWQ9InNoYXJlIj5TaGFyaW5nPC9oMj4KICAgICAgPHA+Q3JlYXRlIGEgc2hhcmUgbGluayBm
b3IgYW55IGZpbGUgb3IgZm9sZGVyLiBMaW5rcyBjYW4gYmUgcGFzc3dvcmQtcHJvdGVjdGVkIGFu
ZCBnaXZlbiBhbiBleHBpcnkgZGF0ZS4gUmV2b2tlIGFjY2VzcyBhdCBhbnkgdGltZSBmcm9tIHRo
ZSBmaWxlIG1lbnUuPC9wPgogICAgICA8aDIgaWQ9InN5bmMiPlN5bmMgY2xpZW50czwvaDI+CiAg
ICAgIDx1bD4KICAgICAgICA8bGk+RGVza3RvcDogV2luZG93cywgbWFjT1MsIExpbnV4LjwvbGk+
CiAgICAgICAgPGxpPk1vYmlsZTogaU9TIGFuZCBBbmRyb2lkLjwvbGk+CiAgICAgICAgPGxpPldl
YjogYW55IG1vZGVybiBicm93c2VyLjwvbGk+CiAgICAgIDwvdWw+CiAgICAgIDxoMiBpZD0iYXBp
Ij5BUEk8L2gyPgogICAgICA8cD5BdXRvbWF0ZSB1cGxvYWRzIGFuZCBhY2NvdW50IHRhc2tzIHdp
dGggdGhlIFJFU1QgQVBJLiBBdXRoZW50aWNhdGUgd2l0aCBhIHBlcnNvbmFsIHRva2VuIGZyb20g
eW91ciBhY2NvdW50IHNldHRpbmdzLiBGdWxsIHJlZmVyZW5jZSBpcyBhdmFpbGFibGUgdG8gc2ln
bmVkLWluIHVzZXJzLjwvcD4KICAgICAgPHAgY2xhc3M9Im11dGVkIj5OZWVkIGhlbHA/IFZpc2l0
IDxhIGNsYXNzPSJsaW5rIiBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4uPC9wPgogICAgPC9k
aXY+CiAgPC9kaXY+CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4K
ICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bh
bj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxu
YXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9
Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+
CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0
Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwv
c3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNy
Yz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lf
RE9DUwoKY2F0ID4gIiRERUNPWS9kYXRhL3NpZ251cC5odG1sIiA8PCdERUNPWV9TSUdOVVAnCjwh
RE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYt
OCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwg
aW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBuYW1lPSJyb2JvdHMiIGNvbnRlbnQ9Im5vaW5kZXgs
IG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJyZWZlcnJlciIgY29udGVudD0ibm8tcmVmZXJyZXIi
IC8+Cjx0aXRsZT5DcmVhdGUgeW91ciBhY2NvdW50IOKAlCBAQEJSQU5EQEAgQ2xvdWQ8L3RpdGxl
Pgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iQ3JlYXRlIGFuIEBAQlJBTkRAQCBD
bG91ZCBhY2NvdW50IOKAlCA1IEdCIGZyZWUsIGVuZC10by1lbmQgZW5jcnlwdGVkLiIgLz4KPGxp
bmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91
Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlm
ZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVz
aGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgog
IDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2
ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRl
bj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJk
OSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAg
MC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFu
PkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4K
ICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3By
aWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+
CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNz
PSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBp
bjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+
CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCI+CiAgPHNl
Y3Rpb24gY2xhc3M9ImF1dGgiIHN0eWxlPSJncmlkLWNvbHVtbjoxLy0xIj4KICAgIDxkaXYgY2xh
c3M9ImNhcmQgY2VudGVyLWNhcmQiPgogICAgICA8aDI+Q3JlYXRlIHlvdXIgYWNjb3VudDwvaDI+
CiAgICAgIDxwIGNsYXNzPSJzdWIiPlN0YXJ0IHdpdGggNSBHQiBmcmVlLiBObyBjcmVkaXQgY2Fy
ZCByZXF1aXJlZC48L3A+CiAgICAgIDxkaXYgY2xhc3M9Im1zZyIgaWQ9Im1zZyIgcm9sZT0iYWxl
cnQiPjwvZGl2PgogICAgICA8Zm9ybSBpZD0ic2lnbnVwIiBub3ZhbGlkYXRlPgogICAgICAgIDxk
aXYgY2xhc3M9ImZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBmb3I9Im5hbWUiPk5hbWU8L2xhYmVs
PgogICAgICAgICAgPGlucHV0IGlkPSJuYW1lIiBuYW1lPSJuYW1lIiB0eXBlPSJ0ZXh0IiBhdXRv
Y29tcGxldGU9Im5hbWUiIHBsYWNlaG9sZGVyPSJZb3VyIG5hbWUiIHJlcXVpcmVkIC8+CiAgICAg
ICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICAgICAgPGxhYmVsIGZv
cj0iZW1haWwiPkVtYWlsPC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBpZD0iZW1haWwiIG5hbWU9
ImVtYWlsIiB0eXBlPSJlbWFpbCIgYXV0b2NvbXBsZXRlPSJlbWFpbCIgcGxhY2Vob2xkZXI9Inlv
dUBleGFtcGxlLmNvbSIgcmVxdWlyZWQgLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNs
YXNzPSJmaWVsZCI+CiAgICAgICAgICA8bGFiZWwgZm9yPSJwYXNzd29yZCI+UGFzc3dvcmQ8L2xh
YmVsPgogICAgICAgICAgPGlucHV0IGlkPSJwYXNzd29yZCIgbmFtZT0icGFzc3dvcmQiIHR5cGU9
InBhc3N3b3JkIiBhdXRvY29tcGxldGU9Im5ldy1wYXNzd29yZCIgcGxhY2Vob2xkZXI9IkF0IGxl
YXN0IDEwIGNoYXJhY3RlcnMiIHJlcXVpcmVkIC8+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1
dHRvbiBjbGFzcz0iYnRuIGJsb2NrIiB0eXBlPSJzdWJtaXQiIGlkPSJzdWJtaXQiPkNyZWF0ZSBh
Y2NvdW50PC9idXR0b24+CiAgICAgIDwvZm9ybT4KICAgICAgPHAgY2xhc3M9ImFsdCI+QWxyZWFk
eSBoYXZlIGFuIGFjY291bnQ/IDxhIGNsYXNzPSJsaW5rIiBocmVmPSIvI3NpZ25pbiI+U2lnbiBp
bjwvYT48L3A+CiAgICA8L2Rpdj4KICA8L3NlY3Rpb24+CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRp
diBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9
ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1c+KA
pjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJp
dHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0i
L3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAg
ICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2PsKp
IDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAgPC9kaXY+
CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8
L2JvZHk+CjwvaHRtbD4KREVDT1lfU0lHTlVQCgpjYXQgPiAiJERFQ09ZL2RhdGEvcmVzZXQuaHRt
bCIgPDwnREVDT1lfUkVTRVQnCjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJlbiI+CjxoZWFk
Pgo8bWV0YSBjaGFyc2V0PSJVVEYtOCIgLz4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9
IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIiAvPgo8bWV0YSBuYW1lPSJyb2Jv
dHMiIGNvbnRlbnQ9Im5vaW5kZXgsIG5vZm9sbG93IiAvPgo8bWV0YSBuYW1lPSJyZWZlcnJlciIg
Y29udGVudD0ibm8tcmVmZXJyZXIiIC8+Cjx0aXRsZT5SZXNldCBwYXNzd29yZCDigJQgQEBCUkFO
REBAIENsb3VkPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVzY3JpcHRpb24iIGNvbnRlbnQ9IlJlc2V0
IHlvdXIgQEBCUkFOREBAIENsb3VkIHBhc3N3b3JkLiIgLz4KPGxpbmsgcmVsPSJpY29uIiBocmVm
PSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0iL2Fw
cGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRz
L3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0
cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9IndyYXAg
YmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIgdmll
d0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lk
dGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41
IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQgMCAw
IDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Ns
b3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iLyNm
ZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciPlByaWNpbmc8L2E+
CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9k
b2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAg
PGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xh
c3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rp
dj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCI+CiAgPHNlY3Rpb24gY2xhc3M9ImF1dGgi
IHN0eWxlPSJncmlkLWNvbHVtbjoxLy0xIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQgY2VudGVyLWNh
cmQiPgogICAgICA8aDI+UmVzZXQgeW91ciBwYXNzd29yZDwvaDI+CiAgICAgIDxwIGNsYXNzPSJz
dWIiPkVudGVyIHlvdXIgZW1haWwgYW5kIHdlIHdpbGwgc2VuZCByZXNldCBpbnN0cnVjdGlvbnMu
PC9wPgogICAgICA8ZGl2IGNsYXNzPSJtc2ciIGlkPSJtc2ciIHJvbGU9ImFsZXJ0Ij48L2Rpdj4K
ICAgICAgPGZvcm0gaWQ9InJlc2V0IiBub3ZhbGlkYXRlPgogICAgICAgIDxkaXYgY2xhc3M9ImZp
ZWxkIj4KICAgICAgICAgIDxsYWJlbCBmb3I9ImVtYWlsIj5FbWFpbDwvbGFiZWw+CiAgICAgICAg
ICA8aW5wdXQgaWQ9ImVtYWlsIiBuYW1lPSJlbWFpbCIgdHlwZT0iZW1haWwiIGF1dG9jb21wbGV0
ZT0iZW1haWwiIHBsYWNlaG9sZGVyPSJ5b3VAZXhhbXBsZS5jb20iIHJlcXVpcmVkIC8+CiAgICAg
ICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJsb2NrIiB0eXBlPSJzdWJtaXQi
IGlkPSJzdWJtaXQiPlNlbmQgcmVzZXQgbGluazwvYnV0dG9uPgogICAgICA8L2Zvcm0+CiAgICAg
IDxwIGNsYXNzPSJhbHQiPjxhIGNsYXNzPSJsaW5rIiBocmVmPSIvI3NpZ25pbiI+QmFjayB0byBz
aWduIGluPC9hPjwvcD4KICAgIDwvZGl2PgogIDwvc2VjdGlvbj4KPC9tYWluPgoKPGZvb3Rlcj4K
ICA8ZGl2IGNsYXNzPSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBj
bGFzcz0iZG90IiBpZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3Rh
dHVz4oCmPC9zcGFuPjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5T
ZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBo
cmVmPSIvcHJpdmFjeSI+UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwv
YT4KICAgICAgPGEgaHJlZj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxk
aXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8
L2Rpdj4KPC9mb290ZXI+CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3Jp
cHQ+CjwvYm9keT4KPC9odG1sPgpERUNPWV9SRVNFVAoKY2F0ID4gIiRERUNPWS9kYXRhL3N1cHBv
cnQuaHRtbCIgPDwnREVDT1lfU1VQUE9SVCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVu
Ij4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIg
Y29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5h
bWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJl
ZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlN1cHBvcnQg4oCUIEBAQlJB
TkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJS
QU5EQEAgQ2xvdWQgaGVscCBhbmQgc3VwcG9ydC4iIC8+CjxsaW5rIHJlbD0iaWNvbiIgaHJlZj0i
L2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFwcGxlLXRvdWNoLWljb24iIGhyZWY9Ii9hcHBs
ZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVsPSJtYW5pZmVzdCIgaHJlZj0iL2Fzc2V0cy9z
aXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9InN0eWxlc2hlZXQiIGhyZWY9Ii9hc3NldHMv
YXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGJh
ciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9Ii8iPjxzdmcgY2xhc3M9Im1hcmsiIHZpZXdC
b3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJpYS1oaWRkZW49InRydWUiPjxyZWN0IHdpZHRo
PSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9IiMzYTViZDkiLz48cGF0aCBkPSJNMTAuNSAy
MS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1IDUgMCAwIDAtOS41My0xLjRBNCA0IDAgMCAw
IDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2Zz48c3Bhbj5AQEJSQU5EQEAmbmJzcDtDbG91
ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJsaW5rcyI+CiAgICAgIDxhIGhyZWY9Ii8jZmVh
dHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcmljaW5nIj5QcmljaW5nPC9hPgog
ICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvZG9j
cyI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0ibmF2LWN0YSI+CiAgICAgIDxh
IGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4iPlNpZ24gaW48L2E+CiAgICAgIDxhIGNsYXNz
PSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVkPC9hPgogICAgPC9kaXY+CiAgPC9kaXY+
CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAgcGFnZS1tYWluIj4KICA8ZGl2IGNsYXNzPSJw
YWdlLWhlYWQiPgogICAgPGRpdiBjbGFzcz0iZXllYnJvdyI+U3VwcG9ydDwvZGl2PgogICAgPGgx
PkhlbHAgJmFtcDsgc3VwcG9ydDwvaDE+CiAgICA8cD5BbnN3ZXJzIHRvIGNvbW1vbiBxdWVzdGlv
bnMsIGFuZCBob3cgdG8gcmVhY2ggdXMuPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InByb3Nl
Ij4KICAgIDxoMj5GcmVxdWVudGx5IGFza2VkPC9oMj4KICAgIDxwPjxzdHJvbmc+SG93IGRvIEkg
cmVjb3ZlciBhIGRlbGV0ZWQgZmlsZT88L3N0cm9uZz4gRGVsZXRlZCBmaWxlcyBzdGF5IGluIHlv
dXIgdHJhc2ggZm9yIDMwIGRheXMuIE9wZW4gdGhlIHdlYiBhcHAsIGdvIHRvIFRyYXNoIGFuZCBj
aG9vc2UgUmVzdG9yZS48L3A+CiAgICA8cD48c3Ryb25nPkNhbiBJIGFjY2VzcyBmaWxlcyBvZmZs
aW5lPzwvc3Ryb25nPiBZZXMuIFRoZSBkZXNrdG9wIGFuZCBtb2JpbGUgYXBwcyBrZWVwIGEgbG9j
YWwgY29weSBhbmQgc3luYyBjaGFuZ2VzIHdoZW4geW91IHJlY29ubmVjdC48L3A+CiAgICA8cD48
c3Ryb25nPkhvdyBkbyBJIGVuYWJsZSB0d28tZmFjdG9yIGF1dGhlbnRpY2F0aW9uPzwvc3Ryb25n
PiBBY2NvdW50IHNldHRpbmdzIOKGkiBTZWN1cml0eSDihpIgVHdvLWZhY3RvciBhdXRoZW50aWNh
dGlvbi48L3A+CiAgICA8aDI+Q29udGFjdCB1czwvaDI+CiAgICA8cD5FbWFpbCA8YSBjbGFzcz0i
bGluayIgaHJlZj0ibWFpbHRvOnN1cHBvcnRAQEBNQUlOX0RPTUFJTkBAIj5zdXBwb3J0QEBATUFJ
Tl9ET01BSU5AQDwvYT4gYW5kIHdlIHVzdWFsbHkgcmVwbHkgd2l0aGluIG9uZSBidXNpbmVzcyBk
YXkuIEZvciBzZXJ2aWNlIHN0YXR1cyBzZWUgdGhlIDxhIGNsYXNzPSJsaW5rIiBocmVmPSIvc3Rh
dHVzIj5zdGF0dXMgcGFnZTwvYT4uPC9wPgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxk
aXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNz
PSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPi
gKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3Vy
aXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9
Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9hPgog
ICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRpdj7C
qSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2
Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3NjcmlwdD4K
PC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1NVUFBPUlQKCmNhdCA+ICIkREVDT1kvZGF0YS9hc3NldHMv
YXBwLmNzcyIgPDwnREVDT1lfQVBQQ1NTJwo6cm9vdHsKICAtLWJnOiNlZWYyZjg7IC0tcGFuZWw6
I2ZmZmZmZjsgLS1pbms6IzEwMTcyODsgLS1tdXRlZDojNWI2Yjg2OwogIC0tbGluZTojZTJlOGYy
OyAtLWJyYW5kOiMzYTViZDk7IC0tYnJhbmQtcHJlc3M6IzJmNDlhZDsgLS1yaW5nOiM5ZGI0ZjQ7
CiAgLS1vazojMWY5ZDU3OyAtLXdhcm46I2MyM2IzYjsgLS1zaGFkb3c6MCAxOHB4IDUwcHggLTI0
cHggcmdiYSgyMCw0MCw5MCwuMzUpOwogIC0tcmFkaXVzOjE0cHg7Cn0KKntib3gtc2l6aW5nOmJv
cmRlci1ib3h9Cmh0bWwsYm9keXttYXJnaW46MDtoZWlnaHQ6MTAwJX0KYm9keXsKICBmb250LWZh
bWlseTotYXBwbGUtc3lzdGVtLEJsaW5rTWFjU3lzdGVtRm9udCwiU2Vnb2UgVUkiLFJvYm90byxI
ZWx2ZXRpY2EsQXJpYWwsc2Fucy1zZXJpZjsKICBjb2xvcjp2YXIoLS1pbmspOyBiYWNrZ3JvdW5k
OnZhcigtLWJnKTsKICAtd2Via2l0LWZvbnQtc21vb3RoaW5nOmFudGlhbGlhc2VkOyBsaW5lLWhl
aWdodDoxLjU7CiAgYmFja2dyb3VuZC1pbWFnZTpyYWRpYWwtZ3JhZGllbnQoMTEwMHB4IDU0MHB4
IGF0IDg2JSAtMTAlLCAjZGZlOGZiIDAlLCByZ2JhKDIyMywyMzIsMjUxLDApIDYwJSksCiAgICAg
ICAgICAgICAgICAgICByYWRpYWwtZ3JhZGllbnQoOTAwcHggNTAwcHggYXQgLTEwJSAxMTAlLCAj
ZTZlZmZiIDAlLCByZ2JhKDIzMCwyMzksMjUxLDApIDU1JSk7Cn0KYXtjb2xvcjppbmhlcml0O3Rl
eHQtZGVjb3JhdGlvbjpub25lfQoud3JhcHttYXgtd2lkdGg6MTE2MHB4O21hcmdpbjowIGF1dG87
cGFkZGluZzowIDI0cHh9CmhlYWRlcntwb3NpdGlvbjpzdGlja3k7dG9wOjA7ei1pbmRleDo1O2Jh
Y2tkcm9wLWZpbHRlcjpzYXR1cmF0ZSgxLjEpIGJsdXIoOHB4KTsKICBiYWNrZ3JvdW5kOnJnYmEo
MjM4LDI0MiwyNDgsLjc4KTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1saW5lKX0KLmJh
cntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1i
ZXR3ZWVuO2hlaWdodDo2NnB4fQouYnJhbmR7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRl
cjtnYXA6MTFweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LS4ycHh9Ci5tYXJre3dp
ZHRoOjMwcHg7aGVpZ2h0OjMwcHg7ZmxleDpub25lfQpuYXYubGlua3N7ZGlzcGxheTpmbGV4O2dh
cDoyOHB4O2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKX0KbmF2LmxpbmtzIGE6aG92
ZXJ7Y29sb3I6dmFyKC0taW5rKX0KLm5hdi1jdGF7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNl
bnRlcjtnYXA6MTZweH0KLmdob3N0e2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLW11dGVkKX0K
Lmdob3N0OmhvdmVye2NvbG9yOnZhcigtLWluayl9Ci5idG57YXBwZWFyYW5jZTpub25lO2JvcmRl
cjowO2N1cnNvcjpwb2ludGVyO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDA7CiAgYm9yZGVy
LXJhZGl1czoxMHB4O3BhZGRpbmc6MTFweCAxOHB4O2JhY2tncm91bmQ6dmFyKC0tYnJhbmQpO2Nv
bG9yOiNmZmY7dHJhbnNpdGlvbjpiYWNrZ3JvdW5kIC4xNXMsIHRyYW5zZm9ybSAuMDVzfQouYnRu
OmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYnJhbmQtcHJlc3MpfQouYnRuOmFjdGl2ZXt0cmFuc2Zv
cm06dHJhbnNsYXRlWSgxcHgpfQouYnRuLmJsb2Nre3dpZHRoOjEwMCU7cGFkZGluZzoxM3B4fQou
YnRuW2Rpc2FibGVkXXtvcGFjaXR5Oi42O2N1cnNvcjpkZWZhdWx0fQptYWlue3BhZGRpbmc6NjRw
eCAwIDI4cHh9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MS4wNWZy
IC45NWZyO2dhcDo2NHB4O2FsaWduLWl0ZW1zOmNlbnRlcn0KLmV5ZWJyb3d7Zm9udC1zaXplOjEy
LjVweDtmb250LXdlaWdodDo2MDA7bGV0dGVyLXNwYWNpbmc6LjEyZW07dGV4dC10cmFuc2Zvcm06
dXBwZXJjYXNlO2NvbG9yOnZhcigtLWJyYW5kKX0KaDF7Zm9udC1zaXplOjQ2cHg7bGluZS1oZWln
aHQ6MS4wODtsZXR0ZXItc3BhY2luZzotMS4xcHg7bWFyZ2luOjE0cHggMCAxNnB4O2ZvbnQtd2Vp
Z2h0Ojc2MH0KLmxlZGV7Zm9udC1zaXplOjE3LjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWF4LXdp
ZHRoOjMwZW07bWFyZ2luOjAgMCAyNnB4fQp1bC5mZWF0e2xpc3Qtc3R5bGU6bm9uZTtwYWRkaW5n
OjA7bWFyZ2luOjA7ZGlzcGxheTpncmlkO2dhcDoxM3B4O21heC13aWR0aDozMGVtfQp1bC5mZWF0
IGxpe2Rpc3BsYXk6ZmxleDtnYXA6MTFweDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O2ZvbnQtc2l6
ZToxNXB4fQp1bC5mZWF0IHN2Z3tmbGV4Om5vbmU7bWFyZ2luLXRvcDoycHg7Y29sb3I6dmFyKC0t
YnJhbmQpfQouaGVyby1pbWd7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDIwcHg7bWFyZ2luOjI2cHgg
MCAwO2Rpc3BsYXk6YmxvY2t9Ci50cnVzdHttYXJnaW4tdG9wOjI0cHg7Zm9udC1zaXplOjEzcHg7
Y29sb3I6dmFyKC0tbXV0ZWQpO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhw
eH0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1s
aW5lKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7CiAgYm94LXNoYWRvdzp2YXIoLS1zaGFk
b3cpO3BhZGRpbmc6MzBweCAzMHB4IDI2cHh9Ci5jYXJkIGgye21hcmdpbjowIDAgNHB4O2ZvbnQt
c2l6ZToyMXB4O2xldHRlci1zcGFjaW5nOi0uM3B4fQouY2FyZCAuc3Vie21hcmdpbjowIDAgMjJw
eDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjE0cHh9CmxhYmVse2Rpc3BsYXk6YmxvY2s7
Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO21hcmdpbjowIDAgN3B4O2NvbG9yOiMzMzQx
NWN9Ci5maWVsZHttYXJnaW4tYm90dG9tOjE2cHh9CmlucHV0W3R5cGU9ZW1haWxdLGlucHV0W3R5
cGU9cGFzc3dvcmRde3dpZHRoOjEwMCU7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3Jk
ZXItcmFkaXVzOjEwcHg7CiAgcGFkZGluZzoxMnB4IDEzcHg7Zm9udDppbmhlcml0O2JhY2tncm91
bmQ6I2ZiZmNmZTt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMTVzLCBib3gtc2hhZG93IC4xNXN9
CmlucHV0OmZvY3Vze291dGxpbmU6MDtib3JkZXItY29sb3I6dmFyKC0tYnJhbmQpO2JveC1zaGFk
b3c6MCAwIDAgNHB4IHZhcigtLXJpbmcpfQoucm93e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpj
ZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luOi0ycHggMCAxOHB4fQou
cmVtZW1iZXJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O2ZvbnQtc2l6
ZToxMy41cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQoubGlua3tjb2xvcjp2YXIoLS1icmFuZCk7Zm9u
dC1zaXplOjEzLjVweDtmb250LXdlaWdodDo2MDB9Ci5saW5rOmhvdmVye3RleHQtZGVjb3JhdGlv
bjp1bmRlcmxpbmV9Ci5tc2d7ZGlzcGxheTpub25lO21hcmdpbjowIDAgMTZweDtwYWRkaW5nOjEw
cHggMTJweDtib3JkZXItcmFkaXVzOjlweDtmb250LXNpemU6MTMuNXB4OwogIGJhY2tncm91bmQ6
I2ZkZWNlYztjb2xvcjojYTAyOTI5O2JvcmRlcjoxcHggc29saWQgI2Y2Y2NjY30KLm1zZy5zaG93
e2Rpc3BsYXk6YmxvY2t9Ci5hbHR7bWFyZ2luOjA7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXpl
OjEzLjVweDtjb2xvcjp2YXIoLS1tdXRlZCl9Ci5kaXZpZGVye2Rpc3BsYXk6ZmxleDthbGlnbi1p
dGVtczpjZW50ZXI7Z2FwOjEycHg7Y29sb3I6IzlhYTdiZDtmb250LXNpemU6MTJweDttYXJnaW46
MjBweCAwfQouZGl2aWRlcjo6YmVmb3JlLC5kaXZpZGVyOjphZnRlcntjb250ZW50OiIiO2hlaWdo
dDoxcHg7YmFja2dyb3VuZDp2YXIoLS1saW5lKTtmbGV4OjF9CmZvb3Rlcntib3JkZXItdG9wOjFw
eCBzb2xpZCB2YXIoLS1saW5lKTttYXJnaW4tdG9wOjQ4cHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwy
NTUsMjU1LC41KX0KLmZvb3R7ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDoxOHB4IDI4
cHg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOwogIHBh
ZGRpbmc6MjJweCAwO2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLW11dGVkKX0KLmZvb3QgbmF2
e2Rpc3BsYXk6ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6MThweH0KLmZvb3QgYTpob3Zlcntjb2xv
cjp2YXIoLS1pbmspfQouc3RhdHVze2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDo4cHh9Ci5kb3R7d2lkdGg6OHB4O2hlaWdodDo4cHg7Ym9yZGVyLXJhZGl1czo1MCU7
YmFja2dyb3VuZDojYzJjOWQ2fQouZG90Lm9re2JhY2tncm91bmQ6dmFyKC0tb2spO2JveC1zaGFk
b3c6MCAwIDAgM3B4IHJnYmEoMzEsMTU3LDg3LC4xNSl9Ci5yZXZlYWx7b3BhY2l0eTowO3RyYW5z
Zm9ybTp0cmFuc2xhdGVZKDEwcHgpO2FuaW1hdGlvbjpyaXNlIC42cyBjdWJpYy1iZXppZXIoLjIs
LjcsLjIsMSkgZm9yd2FyZHN9Ci5yZXZlYWwuZDJ7YW5pbWF0aW9uLWRlbGF5Oi4wOHN9CkBrZXlm
cmFtZXMgcmlzZXt0b3tvcGFjaXR5OjE7dHJhbnNmb3JtOm5vbmV9fQpAbWVkaWEgKHByZWZlcnMt
cmVkdWNlZC1tb3Rpb246cmVkdWNlKXsucmV2ZWFse2FuaW1hdGlvbjpub25lO29wYWNpdHk6MTt0
cmFuc2Zvcm06bm9uZX19CkBtZWRpYSAobWF4LXdpZHRoOjg4MHB4KXsKICBuYXYubGlua3N7ZGlz
cGxheTpub25lfQogIC5ncmlke2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnI7Z2FwOjQwcHh9CiAg
bWFpbntwYWRkaW5nOjQwcHggMCAxNnB4fQogIGgxe2ZvbnQtc2l6ZTozNnB4fQogIC5waXRjaHtv
cmRlcjoyfS5hdXRoe29yZGVyOjF9CiAgLmhlcm8taW1ne2Rpc3BsYXk6bm9uZX0KfQoKLyog4pSA
4pSAIG11bHRpLXBhZ2Ug4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCi5saW5rcyBhLmFj
dGl2ZXtjb2xvcjp2YXIoLS1pbmspfQoucGFnZS1tYWlue3BhZGRpbmc6NTZweCAwIDQwcHh9Ci5w
YWdlLWhlYWR7bWF4LXdpZHRoOjc2MHB4O21hcmdpbjowIDAgMjhweH0KLnBhZ2UtaGVhZCAuZXll
YnJvd3ttYXJnaW4tYm90dG9tOjhweH0KLnBhZ2UtaGVhZCBoMXtmb250LXNpemU6MzhweDtsaW5l
LWhlaWdodDoxLjE7bWFyZ2luOjZweCAwIDEwcHh9Ci5wYWdlLWhlYWQgcHtjb2xvcjp2YXIoLS1t
dXRlZCk7Zm9udC1zaXplOjE3cHg7bWF4LXdpZHRoOjQyZW07bWFyZ2luOjB9Ci5wcm9zZXttYXgt
d2lkdGg6NzIwcHg7Y29sb3I6IzJhMzg1MDtmb250LXNpemU6MTUuNXB4fQoucHJvc2UgaDJ7Zm9u
dC1zaXplOjIwcHg7bWFyZ2luOjMwcHggMCAxMHB4O2xldHRlci1zcGFjaW5nOi0uMnB4fQoucHJv
c2UgcHttYXJnaW46MCAwIDE0cHh9Ci5wcm9zZSB1bHttYXJnaW46MCAwIDE0cHg7cGFkZGluZy1s
ZWZ0OjIwcHh9Ci5wcm9zZSBsaXttYXJnaW46NnB4IDB9Ci5wcm9zZSAubXV0ZWR7Y29sb3I6dmFy
KC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMy41cHg7bWFyZ2luLXRvcDoyMnB4fQoubXNnLm9re2JhY2tn
cm91bmQ6I2U5ZjdlZjtjb2xvcjojMWM3YTQ0O2JvcmRlci1jb2xvcjojYmZlNmNkfQouY2VudGVy
LWNhcmR7bWF4LXdpZHRoOjQyMHB4O21hcmdpbjo0OHB4IGF1dG8gOHB4fQovKiBwcmljaW5nICov
Ci5wcmljaW5ne2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDMsMWZy
KTtnYXA6MjBweDttYXJnaW46OHB4IDAgMH0KLnRpZXJ7YmFja2dyb3VuZDp2YXIoLS1wYW5lbCk7
Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOnZhcigtLXJhZGl1cyk7
cGFkZGluZzoyNHB4O2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW59Ci50aWVyLmZl
YXQtdGllcntib3JkZXItY29sb3I6dmFyKC0tYnJhbmQpO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93
KX0KLnRpZXIgaDN7bWFyZ2luOjAgMCAycHg7Zm9udC1zaXplOjE3cHh9Ci50aWVyIC5wcmljZXtm
b250LXNpemU6MzBweDtmb250LXdlaWdodDo3NDA7bGV0dGVyLXNwYWNpbmc6LTFweDttYXJnaW46
NnB4IDB9Ci50aWVyIC5wcmljZSBzcGFue2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjUwMDtj
b2xvcjp2YXIoLS1tdXRlZCl9Ci50aWVyIHVse2xpc3Qtc3R5bGU6bm9uZTtwYWRkaW5nOjA7bWFy
Z2luOjE0cHggMCAyMHB4O2Rpc3BsYXk6Z3JpZDtnYXA6OXB4O2ZvbnQtc2l6ZToxNHB4O2NvbG9y
OiMzMzQxNWN9Ci50aWVyIHVsIGxpe2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmZs
ZXgtc3RhcnR9Ci50aWVyIHVsIHN2Z3tmbGV4Om5vbmU7bWFyZ2luLXRvcDoycHg7Y29sb3I6dmFy
KC0tYnJhbmQpfQoudGllciAuYnRue21hcmdpbi10b3A6YXV0bzt0ZXh0LWFsaWduOmNlbnRlcn0K
LnRhZ3tkaXNwbGF5OmlubGluZS1ibG9jaztmb250LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7
bGV0dGVyLXNwYWNpbmc6LjA4ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2NvbG9yOnZhcigt
LWJyYW5kKTtiYWNrZ3JvdW5kOiNlOGVkZmQ7Ym9yZGVyLXJhZGl1czo5OTlweDtwYWRkaW5nOjNw
eCA5cHg7YWxpZ24tc2VsZjpmbGV4LXN0YXJ0O21hcmdpbi1ib3R0b206OHB4fQovKiBzdGF0dXMg
Ki8KLnN0YXR1cy1iYW5uZXJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJw
eDtiYWNrZ3JvdW5kOiNlOWY3ZWY7Ym9yZGVyOjFweCBzb2xpZCAjYmZlNmNkO2NvbG9yOiMxYzdh
NDQ7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTZweCAxOHB4O2ZvbnQtd2VpZ2h0OjYwMDtt
YXJnaW46MCAwIDE4cHh9Ci5jb21we2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVz
dGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47cGFkZGluZzoxNHB4IDJweDtib3JkZXItYm90dG9t
OjFweCBzb2xpZCB2YXIoLS1saW5lKTtmb250LXNpemU6MTVweH0KLmNvbXA6bGFzdC1vZi10eXBl
e2JvcmRlci1ib3R0b206MH0KLm9we2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDo4cHg7Y29sb3I6dmFyKC0tb2spO2ZvbnQtc2l6ZToxMy41cHg7Zm9udC13ZWlnaHQ6
NjAwfQoub3AgLmRvdHtiYWNrZ3JvdW5kOnZhcigtLW9rKTtib3gtc2hhZG93OjAgMCAwIDNweCBy
Z2JhKDMxLDE1Nyw4NywuMTUpfQovKiBkb2NzICovCi5kb2Nze2Rpc3BsYXk6Z3JpZDtncmlkLXRl
bXBsYXRlLWNvbHVtbnM6MjIwcHggMWZyO2dhcDo0MHB4O2FsaWduLWl0ZW1zOnN0YXJ0fQouZG9j
cyBuYXYudG9je3Bvc2l0aW9uOnN0aWNreTt0b3A6OTBweDtkaXNwbGF5OmdyaWQ7Z2FwOjZweDtm
b250LXNpemU6MTRweH0KLmRvY3MgbmF2LnRvYyBhe2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5n
OjVweCAwfQouZG9jcyBuYXYudG9jIGE6aG92ZXJ7Y29sb3I6dmFyKC0taW5rKX0KQG1lZGlhICht
YXgtd2lkdGg6ODgwcHgpewogIC5wcmljaW5ne2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9CiAg
LmRvY3N7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0KICAuZG9jcyBuYXYudG9je3Bvc2l0aW9u
OnN0YXRpY30KICAucGFnZS1oZWFkIGgxe2ZvbnQtc2l6ZTozMHB4fQp9CkRFQ09ZX0FQUENTUwoK
Y2F0ID4gIiRERUNPWS9kYXRhL2Fzc2V0cy9hcHAuanMiIDw8J0RFQ09ZX0FQUEpTJwovKiBAQEJS
QU5EQEAgQ2xvdWQg4oCUIHdlYiBjbGllbnQgYm9vdHN0cmFwICovCihmdW5jdGlvbigpewogICJ1
c2Ugc3RyaWN0IjsKICB2YXIgQVBJPXtzdGF0dXM6Ii9hcGkvc3RhdHVzIixhdXRoOiIvYXBpL2F1
dGgiLHJlZ2lzdGVyOiIvYXBpL3JlZ2lzdGVyIixyZXNldDoiL2FwaS9yZXNldCJ9OwoKICBmdW5j
dGlvbiBlbChpZCl7cmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTt9CiAgZnVuY3Rp
b24gcmVhZHkoZm4pe2lmKGRvY3VtZW50LnJlYWR5U3RhdGUhPT0ibG9hZGluZyIpZm4oKTtlbHNl
IGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoIkRPTUNvbnRlbnRMb2FkZWQiLGZuKTt9CiAgZnVu
Y3Rpb24gc2hvdyhtc2csdGV4dCxvayl7aWYoIW1zZylyZXR1cm47bXNnLnRleHRDb250ZW50PXRl
eHQ7bXNnLmNsYXNzTmFtZT0ibXNnIHNob3ciKyhvaz8iIG9rIjoiIik7fQogIGZ1bmN0aW9uIGNs
ZWFyKG1zZyl7aWYobXNnKW1zZy5jbGFzc05hbWU9Im1zZyI7fQoKICByZWFkeShmdW5jdGlvbigp
ewogICAgdmFyIHlyPWVsKCJ5ciIpOyBpZih5cikgeXIudGV4dENvbnRlbnQ9bmV3IERhdGUoKS5n
ZXRGdWxsWWVhcigpOwoKICAgIC8vIHNlcnZpY2Ugc3RhdHVzIGluZGljYXRvciAoZm9vdGVyLCBl
dmVyeSBwYWdlKQogICAgZmV0Y2goQVBJLnN0YXR1cyx7aGVhZGVyczp7QWNjZXB0OiJhcHBsaWNh
dGlvbi9qc29uIn19KQogICAgICAudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5vaz9yLmpzb24o
KTpQcm9taXNlLnJlamVjdCgpO30pCiAgICAgIC50aGVuKGZ1bmN0aW9uKGQpewogICAgICAgIHZh
ciBkb3Q9ZWwoInNkb3QiKSx0PWVsKCJzdGV4dCIpOwogICAgICAgIGlmKGQmJmQub25saW5lKXtk
b3QmJmRvdC5jbGFzc0xpc3QuYWRkKCJvayIpO3QmJih0LnRleHRDb250ZW50PSJBbGwgc3lzdGVt
cyBvcGVyYXRpb25hbCIpO30KICAgICAgICBlbHNle3QmJih0LnRleHRDb250ZW50PSJEZWdyYWRl
ZCBwZXJmb3JtYW5jZSIpO30KICAgICAgfSkKICAgICAgLmNhdGNoKGZ1bmN0aW9uKCl7dmFyIHQ9
ZWwoInN0ZXh0Iik7dCYmKHQudGV4dENvbnRlbnQ9IlN0YXR1cyB1bmF2YWlsYWJsZSIpO30pOwoK
ICAgIC8vIHNpZ24taW4KICAgIHZhciBsb2dpbj1lbCgibG9naW4iKTsKICAgIGlmKGxvZ2luKXsK
ICAgICAgdmFyIGxtc2c9ZWwoIm1zZyIpLGxidG49ZWwoInN1Ym1pdCIpOwogICAgICBsb2dpbi5h
ZGRFdmVudExpc3RlbmVyKCJzdWJtaXQiLGZ1bmN0aW9uKGUpewogICAgICAgIGUucHJldmVudERl
ZmF1bHQoKTtjbGVhcihsbXNnKTsKICAgICAgICB2YXIgZW1haWw9KGVsKCJlbWFpbCIpLnZhbHVl
fHwiIikudHJpbSgpLHBhc3M9ZWwoInBhc3N3b3JkIikudmFsdWV8fCIiOwogICAgICAgIGlmKCFl
bWFpbHx8IXBhc3Mpe3Nob3cobG1zZywiRW50ZXIgeW91ciBlbWFpbCBhbmQgcGFzc3dvcmQgdG8g
Y29udGludWUuIik7cmV0dXJuO30KICAgICAgICBsYnRuLmRpc2FibGVkPXRydWU7bGJ0bi50ZXh0
Q29udGVudD0iU2lnbmluZyBpbuKApiI7CiAgICAgICAgZmV0Y2goQVBJLmF1dGgse21ldGhvZDoi
UE9TVCIsaGVhZGVyczp7IkNvbnRlbnQtVHlwZSI6ImFwcGxpY2F0aW9uL2pzb24iLEFjY2VwdDoi
YXBwbGljYXRpb24vanNvbiJ9LAogICAgICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7ZW1haWw6
ZW1haWwscGFzc3dvcmQ6cGFzcyxyZW1lbWJlcjohIWxvZ2luLnJlbWVtYmVyLmNoZWNrZWR9KX0p
CiAgICAgICAgLnRoZW4oZnVuY3Rpb24ocil7CiAgICAgICAgICBpZihyLnN0YXR1cz09PTQyOSlz
aG93KGxtc2csIlRvbyBtYW55IGF0dGVtcHRzLiBQbGVhc2Ugd2FpdCBhIG1vbWVudCBhbmQgdHJ5
IGFnYWluLiIpOwogICAgICAgICAgZWxzZSBzaG93KGxtc2csIkVtYWlsIG9yIHBhc3N3b3JkIGlz
IGluY29ycmVjdC4iKTsKICAgICAgICB9KQogICAgICAgIC5jYXRjaChmdW5jdGlvbigpe3Nob3co
bG1zZywiQ2Fubm90IHJlYWNoIHRoZSBzZXJ2ZXIuIENoZWNrIHlvdXIgY29ubmVjdGlvbiBhbmQg
dHJ5IGFnYWluLiIpO30pCiAgICAgICAgLmZpbmFsbHkoZnVuY3Rpb24oKXtsYnRuLmRpc2FibGVk
PWZhbHNlO2xidG4udGV4dENvbnRlbnQ9IlNpZ24gaW4iO30pOwogICAgICB9KTsKICAgIH0KCiAg
ICAvLyBjcmVhdGUgYWNjb3VudAogICAgdmFyIHNpZ251cD1lbCgic2lnbnVwIik7CiAgICBpZihz
aWdudXApewogICAgICB2YXIgc21zZz1lbCgibXNnIiksc2J0bj1lbCgic3VibWl0Iik7CiAgICAg
IHNpZ251cC5hZGRFdmVudExpc3RlbmVyKCJzdWJtaXQiLGZ1bmN0aW9uKGUpewogICAgICAgIGUu
cHJldmVudERlZmF1bHQoKTtjbGVhcihzbXNnKTsKICAgICAgICB2YXIgbmFtZT0oZWwoIm5hbWUi
KS52YWx1ZXx8IiIpLnRyaW0oKSwKICAgICAgICAgICAgZW1haWw9KGVsKCJlbWFpbCIpLnZhbHVl
fHwiIikudHJpbSgpLAogICAgICAgICAgICBwYXNzPWVsKCJwYXNzd29yZCIpLnZhbHVlfHwiIjsK
ICAgICAgICBpZighbmFtZXx8IWVtYWlsfHwhcGFzcyl7c2hvdyhzbXNnLCJQbGVhc2UgZmlsbCBp
biBldmVyeSBmaWVsZCB0byBjb250aW51ZS4iKTtyZXR1cm47fQogICAgICAgIGlmKHBhc3MubGVu
Z3RoPDEwKXtzaG93KHNtc2csIlVzZSBhdCBsZWFzdCAxMCBjaGFyYWN0ZXJzIGZvciB5b3VyIHBh
c3N3b3JkLiIpO3JldHVybjt9CiAgICAgICAgc2J0bi5kaXNhYmxlZD10cnVlO3NidG4udGV4dENv
bnRlbnQ9IkNyZWF0aW5n4oCmIjsKICAgICAgICBmZXRjaChBUEkucmVnaXN0ZXIse21ldGhvZDoi
UE9TVCIsaGVhZGVyczp7IkNvbnRlbnQtVHlwZSI6ImFwcGxpY2F0aW9uL2pzb24iLEFjY2VwdDoi
YXBwbGljYXRpb24vanNvbiJ9LAogICAgICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7bmFtZTpu
YW1lLGVtYWlsOmVtYWlsLHBhc3N3b3JkOnBhc3N9KX0pCiAgICAgICAgLnRoZW4oZnVuY3Rpb24o
cil7cmV0dXJuIHIuanNvbigpLmNhdGNoKGZ1bmN0aW9uKCl7cmV0dXJue307fSk7fSkKICAgICAg
ICAudGhlbihmdW5jdGlvbihqKXtzaG93KHNtc2csai5tZXNzYWdlfHwiQ2hlY2sgeW91ciBpbmJv
eCB0byBjb25maXJtIHlvdXIgZW1haWwuIix0cnVlKTtzaWdudXAucmVzZXQoKTt9KQogICAgICAg
IC5jYXRjaChmdW5jdGlvbigpe3Nob3coc21zZywiQ2Fubm90IHJlYWNoIHRoZSBzZXJ2ZXIuIENo
ZWNrIHlvdXIgY29ubmVjdGlvbiBhbmQgdHJ5IGFnYWluLiIpO30pCiAgICAgICAgLmZpbmFsbHko
ZnVuY3Rpb24oKXtzYnRuLmRpc2FibGVkPWZhbHNlO3NidG4udGV4dENvbnRlbnQ9IkNyZWF0ZSBh
Y2NvdW50Ijt9KTsKICAgICAgfSk7CiAgICB9CgogICAgLy8gcGFzc3dvcmQgcmVzZXQKICAgIHZh
ciByZXNldD1lbCgicmVzZXQiKTsKICAgIGlmKHJlc2V0KXsKICAgICAgdmFyIHJtc2c9ZWwoIm1z
ZyIpLHJidG49ZWwoInN1Ym1pdCIpOwogICAgICByZXNldC5hZGRFdmVudExpc3RlbmVyKCJzdWJt
aXQiLGZ1bmN0aW9uKGUpewogICAgICAgIGUucHJldmVudERlZmF1bHQoKTtjbGVhcihybXNnKTsK
ICAgICAgICB2YXIgZW1haWw9KGVsKCJlbWFpbCIpLnZhbHVlfHwiIikudHJpbSgpOwogICAgICAg
IGlmKCFlbWFpbCl7c2hvdyhybXNnLCJFbnRlciB0aGUgZW1haWwgZm9yIHlvdXIgYWNjb3VudC4i
KTtyZXR1cm47fQogICAgICAgIHJidG4uZGlzYWJsZWQ9dHJ1ZTtyYnRuLnRleHRDb250ZW50PSJT
ZW5kaW5n4oCmIjsKICAgICAgICBmZXRjaChBUEkucmVzZXQse21ldGhvZDoiUE9TVCIsaGVhZGVy
czp7IkNvbnRlbnQtVHlwZSI6ImFwcGxpY2F0aW9uL2pzb24iLEFjY2VwdDoiYXBwbGljYXRpb24v
anNvbiJ9LAogICAgICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7ZW1haWw6ZW1haWx9KX0pCiAg
ICAgICAgLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpLmNhdGNoKGZ1bmN0aW9uKCl7
cmV0dXJue307fSk7fSkKICAgICAgICAudGhlbihmdW5jdGlvbihqKXtzaG93KHJtc2csai5tZXNz
YWdlfHwiSWYgYW4gYWNjb3VudCBleGlzdHMsIHdlIHNlbnQgcmVzZXQgaW5zdHJ1Y3Rpb25zLiIs
dHJ1ZSk7cmVzZXQucmVzZXQoKTt9KQogICAgICAgIC5jYXRjaChmdW5jdGlvbigpe3Nob3cocm1z
ZywiQ2Fubm90IHJlYWNoIHRoZSBzZXJ2ZXIuIENoZWNrIHlvdXIgY29ubmVjdGlvbiBhbmQgdHJ5
IGFnYWluLiIpO30pCiAgICAgICAgLmZpbmFsbHkoZnVuY3Rpb24oKXtyYnRuLmRpc2FibGVkPWZh
bHNlO3JidG4udGV4dENvbnRlbnQ9IlNlbmQgcmVzZXQgbGluayI7fSk7CiAgICAgIH0pOwogICAg
fQogIH0pOwp9KSgpOwpERUNPWV9BUFBKUwoKY2F0ID4gIiRERUNPWS9kYXRhL2Fzc2V0cy9oZXJv
LnN2ZyIgPDwnREVDT1lfSEVST1NWRycKPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAw
MC9zdmciIHZpZXdCb3g9IjAgMCA0NjAgMzIwIiBmaWxsPSJub25lIiByb2xlPSJpbWciIGFyaWEt
bGFiZWw9IkZpbGVzIGluIHRoZSBjbG91ZCI+CiAgPGRlZnM+CiAgICA8bGluZWFyR3JhZGllbnQg
aWQ9ImcxIiB4MT0iMCIgeTE9IjAiIHgyPSIxIiB5Mj0iMSI+CiAgICAgIDxzdG9wIG9mZnNldD0i
MCIgc3RvcC1jb2xvcj0iIzViNzhlNiIvPjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iIzNh
NWJkOSIvPgogICAgPC9saW5lYXJHcmFkaWVudD4KICA8L2RlZnM+CiAgPHJlY3QgeD0iNDAiIHk9
IjYwIiB3aWR0aD0iMzgwIiBoZWlnaHQ9IjIxMCIgcng9IjE4IiBmaWxsPSIjZmZmZmZmIiBzdHJv
a2U9IiNlMmU4ZjIiLz4KICA8cmVjdCB4PSI0MCIgeT0iNjAiIHdpZHRoPSIzODAiIGhlaWdodD0i
NDYiIHJ4PSIxOCIgZmlsbD0iI2YzZjZmYyIvPgogIDxjaXJjbGUgY3g9IjY0IiBjeT0iODMiIHI9
IjUiIGZpbGw9IiNjZmQ4ZWEiLz48Y2lyY2xlIGN4PSI4MiIgY3k9IjgzIiByPSI1IiBmaWxsPSIj
Y2ZkOGVhIi8+PGNpcmNsZSBjeD0iMTAwIiBjeT0iODMiIHI9IjUiIGZpbGw9IiNjZmQ4ZWEiLz4K
ICA8cmVjdCB4PSI2NCIgeT0iMTI4IiB3aWR0aD0iMTUwIiBoZWlnaHQ9IjE0IiByeD0iNyIgZmls
bD0iI2U3ZWRmNyIvPgogIDxyZWN0IHg9IjY0IiB5PSIxNTYiIHdpZHRoPSIzMjAiIGhlaWdodD0i
MTAiIHJ4PSI1IiBmaWxsPSIjZWVmMmY4Ii8+CiAgPHJlY3QgeD0iNjQiIHk9IjE3OCIgd2lkdGg9
IjMwMCIgaGVpZ2h0PSIxMCIgcng9IjUiIGZpbGw9IiNlZWYyZjgiLz4KICA8cmVjdCB4PSI2NCIg
eT0iMjAwIiB3aWR0aD0iMjYwIiBoZWlnaHQ9IjEwIiByeD0iNSIgZmlsbD0iI2VlZjJmOCIvPgog
IDxnPgogICAgPHJlY3QgeD0iMjUwIiB5PSIxMjAiIHdpZHRoPSIxMzQiIGhlaWdodD0iOTIiIHJ4
PSIxMiIgZmlsbD0idXJsKCNnMSkiLz4KICAgIDxwYXRoIGQ9Ik0yODYgMTc2aDQ0YTEzIDEzIDAg
MCAwIDEuNi0yNS45IDE5IDE5IDAgMCAwLTM2LTUuNEExNSAxNSAwIDAgMCAyODYgMTc2WiIgZmls
bD0iI2ZmZiIgb3BhY2l0eT0iLjk1Ii8+CiAgICA8cGF0aCBkPSJNMzE2IDE1OHYyMm0tMTEtMTEg
MTEgMTEgMTEtMTEiIHN0cm9rZT0iIzNhNWJkOSIgc3Ryb2tlLXdpZHRoPSIzIiBzdHJva2UtbGlu
ZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KICA8L2c+CiAgPGNpcmNsZSBj
eD0iMzkyIiBjeT0iMjQ4IiByPSIyNiIgZmlsbD0iI2VhZjBmYyIvPgogIDxwYXRoIGQ9Ik0zODQg
MjQ4bDYgNiAxMi0xMiIgc3Ryb2tlPSIjM2E1YmQ5IiBzdHJva2Utd2lkdGg9IjMuNCIgc3Ryb2tl
LWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+Cjwvc3ZnPgpERUNPWV9I
RVJPU1ZHCgpjYXQgPiAiJERFQ09ZL2RhdGEvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIDw8J0RF
Q09ZX01BTklGRVNUJwp7CiAgIm5hbWUiOiAiQEBCUkFOREBAIENsb3VkIiwKICAic2hvcnRfbmFt
ZSI6ICJAQEJSQU5EQEAiLAogICJzdGFydF91cmwiOiAiLyIsCiAgImRpc3BsYXkiOiAic3RhbmRh
bG9uZSIsCiAgImJhY2tncm91bmRfY29sb3IiOiAiI2VlZjJmOCIsCiAgInRoZW1lX2NvbG9yIjog
IiMzYTViZDkiLAogICJpY29ucyI6IFsKICAgIHsgInNyYyI6ICIvYXBwbGUtdG91Y2gtaWNvbi5w
bmciLCAic2l6ZXMiOiAiMTgweDE4MCIsICJ0eXBlIjogImltYWdlL3BuZyIgfSwKICAgIHsgInNy
YyI6ICIvZmF2aWNvbi5pY28iLCAic2l6ZXMiOiAiYW55IiwgInR5cGUiOiAiaW1hZ2UveC1pY29u
IiB9CiAgXQp9CkRFQ09ZX01BTklGRVNUCgpjYXQgPiAiJERFQ09ZL2RvY2tlci1jb21wb3NlLnlt
bCIgPDwnREVDT1lfQ09NUE9TRScKc2VydmljZXM6CiAgZmFrZXNpdGU6CiAgICBpbWFnZTogbmdp
bng6YWxwaW5lCiAgICBjb250YWluZXJfbmFtZTogQEBTTFVHQEAtZGVjb3kKICAgIHJlc3RhcnQ6
IHVubGVzcy1zdG9wcGVkCiAgICBwb3J0czoKICAgICAgLSAiMTI3LjAuMC4xOjgwODA6ODAiCiAg
ICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9hcHBsZS10b3VjaC1pY29uLnBuZzovdXNyL3NoYXJl
L25naW54L2h0bWwvYXBwbGUtdG91Y2gtaWNvbi5wbmc6cm8KICAgICAgLSAuL2RhdGEvZmF2aWNv
bi5pY286L3Vzci9zaGFyZS9uZ2lueC9odG1sL2Zhdmljb24uaWNvOnJvCiAgICAgIC0gLi9kYXRh
L2luZGV4Lmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL2luZGV4Lmh0bWw6cm8KICAgICAgLSAu
L2RhdGEvcHJpY2luZy5odG1sOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9wcmljaW5nLmh0bWw6cm8K
ICAgICAgLSAuL2RhdGEvc2VjdXJpdHkuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvc2VjdXJp
dHkuaHRtbDpybwogICAgICAtIC4vZGF0YS9wcml2YWN5Lmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9o
dG1sL3ByaXZhY3kuaHRtbDpybwogICAgICAtIC4vZGF0YS90ZXJtcy5odG1sOi91c3Ivc2hhcmUv
bmdpbngvaHRtbC90ZXJtcy5odG1sOnJvCiAgICAgIC0gLi9kYXRhL3N0YXR1cy5odG1sOi91c3Iv
c2hhcmUvbmdpbngvaHRtbC9zdGF0dXMuaHRtbDpybwogICAgICAtIC4vZGF0YS9kb2NzLmh0bWw6
L3Vzci9zaGFyZS9uZ2lueC9odG1sL2RvY3MuaHRtbDpybwogICAgICAtIC4vZGF0YS9zaWdudXAu
aHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvc2lnbnVwLmh0bWw6cm8KICAgICAgLSAuL2RhdGEv
cmVzZXQuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvcmVzZXQuaHRtbDpybwogICAgICAtIC4v
ZGF0YS9zdXBwb3J0Lmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL3N1cHBvcnQuaHRtbDpybwog
ICAgICAtIC4vZGF0YS9hc3NldHM6L3Vzci9zaGFyZS9uZ2lueC9odG1sL2Fzc2V0czpybwogICAg
ICAtIC4vZGF0YS9uZ2lueC5jb25mOi9ldGMvbmdpbngvY29uZi5kL2RlZmF1bHQuY29uZjpybwog
ICAgICAtIC4vZGF0YS9waHBpbmZvLnBocDovdXNyL3NoYXJlL25naW54L2h0bWwvcGhwaW5mby5w
aHA6cm8KICAgICAgLSAuL2RhdGEvcm9ib3RzLnR4dDovdXNyL3NoYXJlL25naW54L2h0bWwvcm9i
b3RzLnR4dDpybwogICAgICAtIC4vZGF0YS9zdGF0dXMucGhwOi91c3Ivc2hhcmUvbmdpbngvaHRt
bC9zdGF0dXMucGhwOnJvCiAgICAgIC0gLi9kYXRhL1ZFUlNJT046L3Vzci9zaGFyZS9uZ2lueC9o
dG1sL1ZFUlNJT046cm8KICAgICAgLSAvdmFyL2xvZy9teWZha2VzaXRlOi92YXIvbG9nL215ZmFr
ZXNpdGUKICAgIG5ldHdvcmtzOiBbZmFrZXNpdGVdCiAgICBkZXBlbmRzX29uOiBbcGhwLWZwbV0K
ICBwaHAtZnBtOgogICAgaW1hZ2U6IHBocDo4LjMtZnBtLWFscGluZQogICAgY29udGFpbmVyX25h
bWU6IEBAU0xVR0BALWRlY295LXBocAogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIHZv
bHVtZXM6CiAgICAgIC0gLi9kYXRhL3N0YXR1cy5waHA6L3Vzci9zaGFyZS9uZ2lueC9odG1sL3N0
YXR1cy5waHA6cm8KICAgICAgLSAuL2RhdGEvcGhwaW5mby5waHA6L3Vzci9zaGFyZS9uZ2lueC9o
dG1sL3BocGluZm8ucGhwOnJvCiAgICBuZXR3b3JrczogW2Zha2VzaXRlXQpuZXR3b3JrczoKICBm
YWtlc2l0ZToKICAgIGRyaXZlcjogYnJpZGdlCkRFQ09ZX0NPTVBPU0UKCmVjaG8gIj09IFszLzVd
INCf0L7QtNC90LjQvNCw0Y4g0LrQvtC90YLQtdC50L3QtdGAINC00LXQutC+0Y8gKDEyNy4wLjAu
MTo4MDgwKSA9PSIKY2QgIiRERUNPWSIKZG9ja2VyIGNvbXBvc2UgdXAgLWQKZG9ja2VyIGV4ZWMg
QEBTTFVHQEAtZGVjb3kgbmdpbnggLXQgMj4vZGV2L251bGwgJiYgZG9ja2VyIGV4ZWMgQEBTTFVH
QEAtZGVjb3kgbmdpbnggLXMgcmVsb2FkIDI+L2Rldi9udWxsIHx8IGRvY2tlciByZXN0YXJ0IEBA
U0xVR0BALWRlY295ID4vZGV2L251bGwKc2xlZXAgMwplY2hvIC1uICIgINC70L7QutCw0LvRjNC9
0L4gL3ByaWNpbmc6ICI7IGN1cmwgLXMgLW8gL2Rldi9udWxsIC13ICcle2h0dHBfY29kZX1cbicg
aHR0cDovLzEyNy4wLjAuMTo4MDgwL3ByaWNpbmcKCmVjaG8gIj09IFs0LzVdINCf0LXRgNC10LrQ
u9GO0YfQsNGOIENhZGR5IEBAUkVMQVlfTkFNRUBAOiDQutC+0YDQtdC90YwgLT4g0LTQtdC60L7Q
uSAo0LLQvNC10YHRgtC+IGZpbGVfc2VydmVyKSA9PSIKY3AgLWEgIiRDQUREWUZJTEUiICIkQ0FE
RFlGSUxFLmJhay4kdHMiICYmIGVjaG8gIiAg0LHRjdC60LDQvzogJENBRERZRklMRS5iYWsuJHRz
IgpjYXQgPiAiJENBRERZRklMRSIgPDxDQUREWQp7CiAgICBzZXJ2ZXJzIDo4NDQzIHsKICAgICAg
ICBwcm90b2NvbHMgaDEKICAgIH0KICAgIGVtYWlsICR7QUNNRV9FTUFJTH0KfQoke0RPTUFJTn06
ODQ0MyB7CiAgICBAd3MgcGF0aCAke1dTX1BBVEh9ICR7V1NfUEFUSH0vKgogICAgaGFuZGxlIEB3
cyB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1MwogICAgfQogICAgQHhoIHBh
dGggJHtYSFRUUF9QQVRIfSAke1hIVFRQX1BBVEh9LyoKICAgIGhhbmRsZSBAeGggewogICAgICAg
IHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjIwNTQKICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAg
cmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6ODA4MAogICAgfQp9CkNBRERZCmlmIGRvY2tlciBleGVj
ICIkQ0FERFlfQ1RSIiBjYWRkeSB2YWxpZGF0ZSAtLWNvbmZpZyAvZXRjL2NhZGR5L0NhZGR5Zmls
ZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICBkb2NrZXIgZXhlYyAiJENBRERZX0NUUiIgY2FkZHkg
cmVsb2FkIC0tY29uZmlnIC9ldGMvY2FkZHkvQ2FkZHlmaWxlICYmIGVjaG8gIiAgY2FkZHkgcmVs
b2FkIE9LIiBcCiAgICB8fCB7IGVjaG8gIiAgcmVsb2FkINC90LUg0L/RgNC+0YjRkdC7IOKAlCDR
gNC10YHRgtCw0YDRgiI7IGRvY2tlciByZXN0YXJ0ICIkQ0FERFlfQ1RSIjsgfQplbHNlCiAgZWNo
byAiICB2YWxpZGF0ZSDQvdC10LTQvtGB0YLRg9C/0LXQvSDigJQg0YDQtdGB0YLQsNGA0YIiOyBk
b2NrZXIgcmVzdGFydCAiJENBRERZX0NUUiIKZmkKCmVjaG8gIj09IFs1LzVdINCf0YDQvtCy0LXR
gNC60LAg0YfQtdGA0LXQtyDRgdCw0LwgQ2FkZHkgKDg0NDMsINCyINC+0LHRhdC+0LQgUmVhbGl0
eSkgPT0iCnNsZWVwIDMKZm9yIHAgaW4gLyAvcHJpY2luZyAvc3RhdHVzOyBkbwogIHByaW50ZiAi
ICAlLTEwcyAiICIkcCIKICBmb3IgX2kgaW4gMSAyIDM7IGRvCiAgICBjb2RlPSQoY3VybCAtc2sg
LW8gL2Rldi9udWxsIC13ICcle2h0dHBfY29kZX0nIC0tcmVzb2x2ZSAiJHtET01BSU59Ojg0NDM6
MTI3LjAuMC4xIiAiaHR0cHM6Ly8ke0RPTUFJTn06ODQ0MyRwIiAyPi9kZXYvbnVsbCkgfHwgY29k
ZT0iMDAwIgogICAgWyAiJGNvZGUiICE9ICIwMDAiIF0gJiYgeyBlY2hvICIkY29kZSI7IGJyZWFr
OyB9CiAgICBbICIkX2kiID0gIjMiIF0gJiYgZWNobyAiMDAwIChDYWRkeSDQtdGJ0ZEg0L/QtdGA
0LXQt9Cw0LPRgNGD0LbQsNC10YLRgdGPIOKAlCDQvdC+0YDQvNCwKSIKICAgIHNsZWVwIDIKICBk
b25lCmRvbmUKZWNobwplY2hvICLinIUgQEBSRUxBWV9OQU1FQEAg0YLQtdC/0LXRgNGMINC+0YLQ
tNCw0ZHRgiDRgtC+0YIg0LbQtSDCq0BAQlJBTkRAQCBDbG91ZMK7LCDRh9GC0L4g0LggQEBFWElU
X05BTUVAQC4iCmVjaG8gItCh0L3QsNGA0YPQttC4IChWUE4g0JLQq9Ca0JspOiBjdXJsLmV4ZSAt
c0kgaHR0cHM6Ly9AQFJFTEFZX0RPTUFJTkBAL3ByaWNpbmciCmVjaG8gItCe0YLQutCw0YIgQ2Fk
ZHk6IGNwIFwiJENBRERZRklMRS5iYWsuJHRzXCIgXCIkQ0FERFlGSUxFXCIgJiYgZG9ja2VyIHJl
c3RhcnQgJENBRERZX0NUUiIK
__B64__
  base64 -d > "$d/deploy-moonlight.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1tb29u
bGlnaHQuc2ggIOKAlCAgQEBFWElUX05BTUVAQCAoQEBNQUlOX0RPTUFJTkBAKSAg0KTQkNCX0JAg
MQojICDQp9C40YHRgtCw0Y8g0LLQtdGA0YHQuNGPINGB0L4g0LLRgdC10LzQuCDQuNGB0L/RgNCw
0LLQu9C10L3QuNGP0LzQuC4g0JjQtNC10LzQv9C+0YLQtdC90YLQvdCwLgojID09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09CiMgINCU0LXQu9Cw0LXRgiDRgdCw0Lw6IERvY2tlciwgSVB2NiBvZmYsIFVGVyAo
0LLQutC7LiAyMjIyINC4IDQ0My91ZHApLCDQv9Cw0L3QtdC70YwgUmVtbmF3YXZlLAojICDRgdGC
0YDQsNC90LjRhtGDINC/0L7QtNC/0LjRgdC60LggKNCz0L7RgtC+0LLRi9C5INC+0LHRgNCw0Lcp
LCBDYWRkeSDQndCQIDQ0MyAo0L/QsNC90LXQu9GMINC+0YLQutGA0YvQstCw0LXRgtGB0Y8g0L/Q
viDQtNC+0LzQtdC90YMpLAojICBSZWFsaXR5LdC60LvRjtGH0LgsINCz0L7RgtC+0LLRi9C5IFhy
YXkt0L/RgNC+0YTQuNC70Ywg0L3QsCA0INC/0YDQvtGC0L7QutC+0LvQsCAoc2VsZnN0ZWFsLCDR
gSBIeXN0ZXJpYTIsINCx0LXQtyDQs9C10L4t0LHQu9C+0LrQsCkuCiMgINCX0LDQv9GD0YHQujog
IHN1ZG8gYmFzaCBkZXBsb3ktbW9vbmxpZ2h0LnNoCiMgPT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0Kc2V0
IC1ldW8gcGlwZWZhaWwKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tINCd0JDQodCi0KDQ
ntCZ0JrQmCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KRE9NQUlOPSJA
QE1BSU5fRE9NQUlOQEAiCkFDTUVfRU1BSUw9ImFkbWluQEBAU0xVR0BALmNvbSIKUkVBTElUWV9T
Tkk9InlhaG9vLmNvbSIKV1NfUEFUSD0iL3dzbmciClhIVFRQX1BBVEg9Ii94aCIKU1VCX1BBVEg9
Ii9zdWIiCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCkJBU0U9L29wdC9AQFNMVUdAQApsb2coKXsg
ZWNobyAtZSAiXG5cMDMzWzE7MzZtPT0+ICQqXDAzM1swbSI7IH0Kb2soKXsgIGVjaG8gLWUgIlww
MzNbMTszMm0gIE9LICQqXDAzM1swbSI7IH0Kd2FybigpeyBlY2hvIC1lICJcMDMzWzE7MzNtICAh
ICQqXDAzM1swbSI7IH0KCltbICRFVUlEIC1lcSAwIF1dIHx8IHsgZWNobyAi0JfQsNC/0YPRgdGC
0Lgg0YfQtdGA0LXQtyBzdWRvOiBzdWRvIGJhc2ggJDAiOyBleGl0IDE7IH0KY29tbWFuZCAtdiBh
cHQtZ2V0ID4vZGV2L251bGwgfHwgeyBlY2hvICLQndGD0LbQtdC9IFVidW50dS9EZWJpYW4gKGFw
dCkuIjsgZXhpdCAxOyB9Cm1rZGlyIC1wICIkQkFTRSIve3BhbmVsLHN1YixjYWRkeSxub2RlfQoK
IyAtLS0gMC4g0JHQsNC30L7QstGL0LUg0L/QsNC60LXRgtGLICsgRE5TLdC/0YDQvtCy0LXRgNC6
0LAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjAvNiDQkdCw
0LfQvtCy0YvQtSDQv9Cw0LrQtdGC0Ysg0Lgg0L/RgNC+0LLQtdGA0LrQsCBETlMiCmV4cG9ydCBE
RUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUKYXB0LWdldCB1cGRhdGUgLXkgPi9kZXYvbnVs
bAphcHQtZ2V0IGluc3RhbGwgLXkgY3VybCBvcGVuc3NsIGNhLWNlcnRpZmljYXRlcyBnbnVwZyA+
L2Rldi9udWxsCm9rICJjdXJsL29wZW5zc2wvY2EtY2VydGlmaWNhdGVzINC90LAg0LzQtdGB0YLQ
tSIKTVlJUD0kKGN1cmwgLWZzUzQgaHR0cHM6Ly9hcGkuaXBpZnkub3JnIDI+L2Rldi9udWxsIHx8
IGhvc3RuYW1lIC1JIHwgYXdrICd7cHJpbnQgJDF9JykKRE5TSVA9JChnZXRlbnQgYWhvc3RzdjQg
IiRET01BSU4iIHwgYXdrICd7cHJpbnQgJDE7IGV4aXR9JyB8fCB0cnVlKQppZiBbWyAtbiAiJE1Z
SVAiICYmICIkRE5TSVAiID09ICIkTVlJUCIgXV07IHRoZW4KICBvayAiRE5TOiAkRE9NQUlOIC0+
ICRNWUlQIgplbHNlCiAgd2FybiAi0JTQvtC80LXQvSAkRE9NQUlOINGD0LrQsNC30YvQstCw0LXR
giDQvdCwICcke0ROU0lQOi3QvdC40YfQtdCz0L59Jywg0LAg0YHQtdGA0LLQtdGAICckTVlJUCcu
IgogIHdhcm4gItCR0LXQtyDQv9GA0LDQstC40LvRjNC90L7QuSBBLdC30LDQv9C40YHQuCDRgdC1
0YDRgtC40YTQuNC60LDRgiDQvdC1INCy0YvQv9GD0YHRgtC40YLRgdGPLiBBOiAkRE9NQUlOIC0+
ICRNWUlQIChETlMgb25seSkuIgogIHdhcm4gItCf0YDQvtC00L7Qu9C20YMg0YfQtdGA0LXQtyAx
NSDRgdC10Lo7INC/0L7RgtC+0Lwg0L/RgNC+0YHRgtC+INC/0LXRgNC10LfQsNC/0YPRgdGC0Lgg
0YHQutGA0LjQv9GCLiIKICBzbGVlcCAxNQpmaQp3YXJuICJMZXQncyBFbmNyeXB0OiDQu9C40LzQ
uNGCIDUg0YHQtdGA0YLQuNGE0LjQutCw0YLQvtCyINC90LAgJERPTUFJTiDQsiDQvdC10LTQtdC7
0Y4g4oCUINC90LUg0LPQvtC90Y/QuSDQtNC10L/Qu9C+0Lkg0L/QviDQutGA0YPQs9GDLiIKCiMg
LS0tIDEuIERvY2tlciAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0KbG9nICIxLzYgRG9ja2VyIgppZiBjb21tYW5kIC12IGRvY2tl
ciA+L2Rldi9udWxsICYmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVsbCAyPiYxOyB0
aGVuIG9rICJEb2NrZXIg0YPQttC1INGB0YLQvtC40YIiCmVsc2UgY3VybCAtZnNTTCBodHRwczov
L2dldC5kb2NrZXIuY29tIHwgc2g7IG9rICJEb2NrZXIg0YPRgdGC0LDQvdC+0LLQu9C10L0iOyBm
aQoKIyAtLS0gMi4gSVB2NiBvZmYgKyDRhNC+0YDQstCw0YDQtNC40L3QsyAtLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KbG9nICIyLzYgSVB2NiBvZmYgKyBp
cF9mb3J3YXJkIgpjYXQgPi9ldGMvc3lzY3RsLmQvOTktQEBTTFVHQEAuY29uZiA8PCdFT0YnCm5l
dC5pcHY2LmNvbmYuYWxsLmRpc2FibGVfaXB2NiA9IDEKbmV0LmlwdjYuY29uZi5kZWZhdWx0LmRp
c2FibGVfaXB2NiA9IDEKbmV0LmlwdjYuY29uZi5sby5kaXNhYmxlX2lwdjYgPSAxCm5ldC5pcHY0
LmlwX2ZvcndhcmQgPSAxCkVPRgpzeXNjdGwgLS1zeXN0ZW0gPi9kZXYvbnVsbApvayAiSVB2NiDQ
stGL0LrQu9GO0YfQtdC9IgoKIyAtLS0gMy4gVUZXIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjMvNiBGaXJld2Fs
bCIKYXB0LWdldCBpbnN0YWxsIC15IHVmdyA+L2Rldi9udWxsCnVmdyAtLWZvcmNlIHJlc2V0ID4v
ZGV2L251bGwKdWZ3IGRlZmF1bHQgZGVueSBpbmNvbWluZyA+L2Rldi9udWxsCnVmdyBkZWZhdWx0
IGFsbG93IG91dGdvaW5nID4vZGV2L251bGwKZm9yIHAgaW4gMjIvdGNwIDgwL3RjcCA0NDMvdGNw
IDQ0My91ZHAgMjA4My90Y3AgMjIyMi90Y3AgNTYwMDAvdWRwIDU2MDAxL3VkcDsgZG8gdWZ3IGFs
bG93ICIkcCIgPi9kZXYvbnVsbDsgZG9uZQp1ZncgLS1mb3JjZSBlbmFibGUgPi9kZXYvbnVsbApv
ayAi0J7RgtC60YDRi9GC0Ys6IDIyLDgwLDQ0My90Y3AgwrcgNDQzL3VkcCDCtyAyMDgzL3RjcChY
SFRUUCkgwrcgMjIyMi90Y3Ao0L3QvtC00LApIMK3IDU2MDAwLDU2MDAxL3VkcChXRFRUKSIKCiMg
LS0tIDQuINCf0LDQvdC10LvRjCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KbG9nICI0LzYg0J/QsNC90LXQu9GMIFJlbW5hd2F2
ZSIKY2QgIiRCQVNFL3BhbmVsIgpbWyAtZiBkb2NrZXItY29tcG9zZS55bWwgXV0gfHwgY3VybCAt
ZnNTTCAtbyBkb2NrZXItY29tcG9zZS55bWwgXAogIGh0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250
ZW50LmNvbS9yZW1uYXdhdmUvYmFja2VuZC9yZWZzL2hlYWRzL21haW4vZG9ja2VyLWNvbXBvc2Ut
cHJvZC55bWwKaWYgW1sgISAtZiAuZW52IF1dOyB0aGVuCiAgY3VybCAtZnNTTCAtbyAuZW52IGh0
dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbS9yZW1uYXdhdmUvYmFja2VuZC9yZWZzL2hl
YWRzL21haW4vLmVudi5zYW1wbGUKICBzZWQgLWkgInMvXkpXVF9BVVRIX1NFQ1JFVD0uKi9KV1Rf
QVVUSF9TRUNSRVQ9JChvcGVuc3NsIHJhbmQgLWhleCA2NCkvIiAuZW52CiAgc2VkIC1pICJzL15K
V1RfQVBJX1RPS0VOU19TRUNSRVQ9LiovSldUX0FQSV9UT0tFTlNfU0VDUkVUPSQob3BlbnNzbCBy
YW5kIC1oZXggNjQpLyIgLmVudgogIHNlZCAtaSAicy9eTUVUUklDU19QQVNTPS4qL01FVFJJQ1Nf
UEFTUz0kKG9wZW5zc2wgcmFuZCAtaGV4IDY0KS8iIC5lbnYKICBzZWQgLWkgInMvXldFQkhPT0tf
U0VDUkVUX0hFQURFUj0uKi9XRUJIT09LX1NFQ1JFVF9IRUFERVI9JChvcGVuc3NsIHJhbmQgLWhl
eCA2NCkvIiAuZW52CiAgUEc9JChvcGVuc3NsIHJhbmQgLWhleCAyNCkKICBzZWQgLWkgInMvXlBP
U1RHUkVTX1BBU1NXT1JEPS4qL1BPU1RHUkVTX1BBU1NXT1JEPSRQRy8iIC5lbnYKICBzZWQgLWkg
InN8XlwoREFUQUJBU0VfVVJMPVwicG9zdGdyZXNxbDovL3Bvc3RncmVzOlwpW15AXSpcKEAuKlwp
fFwxJFBHXDJ8IiAuZW52CiAgb2sgIi5lbnYg0YHQvtC30LTQsNC9LCDRgdC10LrRgNC10YLRiyDR
gdCz0LXQvdC10YDQuNGA0L7QstCw0L3RiyIKZWxzZSBvayAiLmVudiDRg9C20LUg0LXRgdGC0Yws
INC90LUg0YLRgNC+0LPQsNGOIjsgZmkKZG9ja2VyIGNvbXBvc2UgdXAgLWQKb2sgItCf0LDQvdC1
0LvRjCDQvdCwIDEyNy4wLjAuMTozMDAwIgoKIyAtLS0gNS4g0J/QvtC00L/QuNGB0LrQsCAo0LPQ
vtGC0L7QstGL0Lkg0L7QsdGA0LDQtzsg0L3QtSDQutGA0LjRgtC40YfQvdC+LCDQtdGB0LvQuCDQ
vdC1INCy0YHRgtCw0L3QtdGCKSAtLS0tLS0tLS0tLS0tLS0KbG9nICI1LzYg0KHRgtGA0LDQvdC4
0YbQsCDQv9C+0LTQv9C40YHQutC4IgpjZCAiJEJBU0Uvc3ViIgpjYXQgPiBkb2NrZXItY29tcG9z
ZS55bWwgPDwnRU9GJwpzZXJ2aWNlczoKICByZW1uYXdhdmUtc3Vic2NyaXB0aW9uLXBhZ2U6CiAg
ICBpbWFnZTogcmVtbmF3YXZlL3N1YnNjcmlwdGlvbi1wYWdlOmxhdGVzdAogICAgY29udGFpbmVy
X25hbWU6IHJlbW5hd2F2ZS1zdWJzY3JpcHRpb24tcGFnZQogICAgcmVzdGFydDogYWx3YXlzCiAg
ICBlbnZfZmlsZTogLmVudgogICAgcG9ydHM6CiAgICAgIC0gJzEyNy4wLjAuMTozMDEwOjMwMTAn
CiAgICBuZXR3b3JrczoKICAgICAgLSByZW1uYXdhdmUtbmV0d29yawpuZXR3b3JrczoKICByZW1u
YXdhdmUtbmV0d29yazoKICAgIGV4dGVybmFsOiB0cnVlCiAgICBuYW1lOiByZW1uYXdhdmUtbmV0
d29yawpFT0YKW1sgLWYgLmVudiBdXSB8fCBjYXQgPiAuZW52IDw8J0VPRicKQVBQX1BPUlQ9MzAx
MApSRU1OQVdBVkVfUEFORUxfVVJMPWh0dHA6Ly9yZW1uYXdhdmU6MzAwMApNRVRBX1RJVExFPU15
U3BoZXJlCkVPRgpkb2NrZXIgY29tcG9zZSB1cCAtZCB8fCB3YXJuICJzdWItcGFnZSDQvdC1INCy
0YHRgtCw0LvQsCDigJQg0L3QtSDQutGA0LjRgtC40YfQvdC+INGB0LXQudGH0LDRgSAo0L3Rg9C2
0L3QsCDQv9C+0LfQttC1INC00LvRjyBRUikuIgpvayAi0J/QvtC00L/QuNGB0LrQsCAo0L/QvtC/
0YvRgtC60LApINC90LAgMTI3LjAuMC4xOjMwMTAiCgojIC0tLSA2LiBDYWRkeSDQndCQIDQ0MyAr
IFJlYWxpdHkt0LrQu9GO0YfQuCArINC/0YDQvtGE0LjQu9GMIC0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0KbG9nICI2LzYgQ2FkZHkg0L3QsCA0NDMgKyDQutC70Y7Rh9C4ICsg0L/RgNC+
0YTQuNC70YwiCmlmIFtbIC1mICIkQkFTRS9jYWRkeS9DYWRkeWZpbGUiIF1dICYmIGdyZXAgLXEg
Jzg0NDMnICIkQkFTRS9jYWRkeS9DYWRkeWZpbGUiICYmIGdyZXAgLXEgIiR7RE9NQUlOfSIgIiRC
QVNFL2NhZGR5L0NhZGR5ZmlsZSI7IHRoZW4KICBvayAiQ2FkZHkg0YPQttC1INC90LAgODQ0MyDQ
tNC70Y8gJHtET01BSU59IChoYW5kb2ZmL3N0ZWFsdGgg0L/RgNC40LzQtdC90ZHQvSkg4oCUIENh
ZGR5ZmlsZSDQvdC1INGC0YDQvtCz0LDRjiAo0LjQvdCw0YfQtSDRgdC70L7QvNCw0Y4g0YHRgtC1
0LvRgSDQuCDQv9C+0LTQtdGA0YPRgdGMINGBIFhyYXkg0LfQsCA0NDMpIgplbHNlCmNhdCA+ICIk
QkFTRS9jYWRkeS9DYWRkeWZpbGUiIDw8RU9GCiR7RE9NQUlOfSB7CiAgICBoYW5kbGVfcGF0aCAk
e1NVQl9QQVRIfS8qIHsKICAgICAgICByZXZlcnNlX3Byb3h5IDEyNy4wLjAuMTozMDEwCiAgICB9
CiAgICBoYW5kbGUgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMDAKICAgIH0K
fQpFT0YKZmkKY2F0ID4gIiRCQVNFL2NhZGR5L2RvY2tlci1jb21wb3NlLnltbCIgPDwnRU9GJwpz
ZXJ2aWNlczoKICBjYWRkeToKICAgIGltYWdlOiBjYWRkeToyCiAgICBjb250YWluZXJfbmFtZTog
QEBTTFVHQEAtY2FkZHkKICAgIHJlc3RhcnQ6IGFsd2F5cwogICAgbmV0d29ya19tb2RlOiBob3N0
CiAgICB2b2x1bWVzOgogICAgICAtIC4vQ2FkZHlmaWxlOi9ldGMvY2FkZHkvQ2FkZHlmaWxlOnJv
CiAgICAgIC0gY2FkZHlfZGF0YTovZGF0YQogICAgICAtIGNhZGR5X2NvbmZpZzovY29uZmlnCnZv
bHVtZXM6CiAgY2FkZHlfZGF0YToKICBjYWRkeV9jb25maWc6CkVPRgpjZCAiJEJBU0UvY2FkZHki
ICYmIGRvY2tlciBjb21wb3NlIHVwIC1kCm9rICJDYWRkeSDQt9Cw0L/Rg9GJ0LXQvSAo0YHQstC1
0LbQuNC5INCx0L7QutGBOiDQv9Cw0L3QtdC70Ywg0L3QsCBodHRwczovLyR7RE9NQUlOfS87INC3
0LDRgdGC0LXQu9GB0LXQvdC90YvQuTog0L/QsNC90LXQu9GMINCy0L3Rg9GC0YDQuCBsb2NhbGhv
c3Q6ODA4MSkiCgppZiBbWyAhIC1mICIkQkFTRS9ub2RlL3JlYWxpdHkuZW52IiBdXTsgdGhlbgog
IEtFWVM9JChkb2NrZXIgcnVuIC0tcm0gZ2hjci5pby94dGxzL3hyYXktY29yZTpsYXRlc3QgeDI1
NTE5IDI+L2Rldi9udWxsIHx8IHRydWUpCiAgUFJJVj0kKGVjaG8gIiRLRVlTIiB8IGdyZXAgLWlF
ICdwcml2YXRlJyB8IGF3ayAne3ByaW50ICRORn0nKQogIFBVQj0kKGVjaG8gICIkS0VZUyIgfCBn
cmVwIC1pRSAncHVibGljfHBhc3N3b3JkJyB8IGF3ayAne3ByaW50ICRORn0nKQogIFNJRD0kKG9w
ZW5zc2wgcmFuZCAtaGV4IDgpCiAgaWYgW1sgLXogIiRQUklWIiB8fCAteiAiJFBVQiIgXV07IHRo
ZW4KICAgIHdhcm4gItCd0LUg0YDQsNGB0L/QsNGA0YHQuNC7INC60LvRjtGH0LggUmVhbGl0eS4g
0JLRgNGD0YfQvdGD0Y46IGRvY2tlciBydW4gLS1ybSBnaGNyLmlvL3h0bHMveHJheS1jb3JlOmxh
dGVzdCB4MjU1MTkiCiAgICBQUklWPSLQktCh0KLQkNCS0KxfUFJJVkFURSI7IFBVQj0i0JLQodCi
0JDQktCsX1BVQkxJQyIKICBmaQogIGNhdCA+ICIkQkFTRS9ub2RlL3JlYWxpdHkuZW52IiA8PEVP
RgpSRUFMSVRZX1BSSVZBVEVfS0VZPSRQUklWClJFQUxJVFlfUFVCTElDX0tFWT0kUFVCClJFQUxJ
VFlfU0hPUlRfSUQ9JFNJRApFT0YKICBvayAiUmVhbGl0eS3QutC70Y7Rh9C4INCyICRCQVNFL25v
ZGUvcmVhbGl0eS5lbnYiCmZpCnNvdXJjZSAiJEJBU0Uvbm9kZS9yZWFsaXR5LmVudiIKCmNhdCA+
ICIkQkFTRS9ub2RlL3hyYXktcHJvZmlsZS5qc29uIiA8PEVPRgp7CiAgImluYm91bmRzIjogWwog
ICAgeyAidGFnIjogIlZMRVNTLVJFQUxJVFkiLCAibGlzdGVuIjogIjAuMC4wLjAiLCAicG9ydCI6
IDQ0MywgInByb3RvY29sIjogInZsZXNzIiwKICAgICAgInNldHRpbmdzIjogeyAiY2xpZW50cyI6
IFtdLCAiZGVjcnlwdGlvbiI6ICJub25lIiwgImZhbGxiYWNrcyI6IFsgeyAiZGVzdCI6ICIxMjcu
MC4wLjE6ODQ0MyIgfSBdIH0sCiAgICAgICJzdHJlYW1TZXR0aW5ncyI6IHsgIm5ldHdvcmsiOiAi
dGNwIiwgInNlY3VyaXR5IjogInJlYWxpdHkiLAogICAgICAgICJyZWFsaXR5U2V0dGluZ3MiOiB7
ICJzaG93IjogZmFsc2UsICJkZXN0IjogIjEyNy4wLjAuMTo4NDQzIiwgInNlcnZlck5hbWVzIjog
WyIke0RPTUFJTn0iXSwKICAgICAgICAgICJwcml2YXRlS2V5IjogIiR7UkVBTElUWV9QUklWQVRF
X0tFWX0iLCAic2hvcnRJZHMiOiBbIiR7UkVBTElUWV9TSE9SVF9JRH0iXSB9IH0sCiAgICAgICJz
bmlmZmluZyI6IHsgImVuYWJsZWQiOiB0cnVlLCAiZGVzdE92ZXJyaWRlIjogWyJodHRwIiwidGxz
IiwicXVpYyJdIH0gfSwKICAgIHsgInRhZyI6ICJWTEVTUy1XUyIsICJsaXN0ZW4iOiAiMTI3LjAu
MC4xIiwgInBvcnQiOiAyMDUzLCAicHJvdG9jb2wiOiAidmxlc3MiLAogICAgICAic2V0dGluZ3Mi
OiB7ICJjbGllbnRzIjogW10sICJkZWNyeXB0aW9uIjogIm5vbmUiIH0sCiAgICAgICJzdHJlYW1T
ZXR0aW5ncyI6IHsgIm5ldHdvcmsiOiAid3MiLCAic2VjdXJpdHkiOiAibm9uZSIsICJ3c1NldHRp
bmdzIjogeyAicGF0aCI6ICIke1dTX1BBVEh9IiB9IH0gfSwKICAgIHsgInRhZyI6ICJWTEVTUy1Y
SFRUUCIsICJsaXN0ZW4iOiAiMC4wLjAuMCIsICJwb3J0IjogMjA4MywgInByb3RvY29sIjogInZs
ZXNzIiwKICAgICAgInNldHRpbmdzIjogeyAiY2xpZW50cyI6IFtdLCAiZGVjcnlwdGlvbiI6ICJu
b25lIiB9LAogICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogInhodHRwIiwgInNl
Y3VyaXR5IjogInJlYWxpdHkiLAogICAgICAgICJyZWFsaXR5U2V0dGluZ3MiOiB7ICJzaG93Ijog
ZmFsc2UsICJkZXN0IjogIjEyNy4wLjAuMTo4NDQzIiwgInNlcnZlck5hbWVzIjogWyIke0RPTUFJ
Tn0iXSwKICAgICAgICAgICJwcml2YXRlS2V5IjogIiR7UkVBTElUWV9QUklWQVRFX0tFWX0iLCAi
c2hvcnRJZHMiOiBbIiR7UkVBTElUWV9TSE9SVF9JRH0iXSB9LAogICAgICAgICJ4aHR0cFNldHRp
bmdzIjogeyAicGF0aCI6ICIke1hIVFRQX1BBVEh9IiwgIm1vZGUiOiAiYXV0byIgfSB9IH0sCiAg
ICB7ICJ0YWciOiAiSFlTVEVSSUEyIiwgImxpc3RlbiI6ICIwLjAuMC4wIiwgInBvcnQiOiA0NDMs
ICJwcm90b2NvbCI6ICJoeXN0ZXJpYSIsCiAgICAgICJzZXR0aW5ncyI6IHsgImNsaWVudHMiOiBb
XSB9LAogICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogImh5c3RlcmlhIiwgInNl
Y3VyaXR5IjogInRscyIsCiAgICAgICAgInRsc1NldHRpbmdzIjogeyAiYWxwbiI6IFsiaDMiXSwg
ImNlcnRpZmljYXRlcyI6IFsgeyAiY2VydGlmaWNhdGVGaWxlIjogIi9jZXJ0cy9oeTIuY3J0Iiwg
ImtleUZpbGUiOiAiL2NlcnRzL2h5Mi5rZXkiIH0gXSB9LAogICAgICAgICJoeXN0ZXJpYVNldHRp
bmdzIjogeyAidmVyc2lvbiI6IDIsICJ1ZHBJZGxlVGltZW91dCI6IDYwIH0gfSB9CiAgXSwKICAi
b3V0Ym91bmRzIjogWwogICAgeyAidGFnIjogImRpcmVjdCIsICJwcm90b2NvbCI6ICJmcmVlZG9t
IiwgInNldHRpbmdzIjogeyAiZG9tYWluU3RyYXRlZ3kiOiAiVXNlSVB2NCIgfSB9LAogICAgeyAi
dGFnIjogImJsb2NrIiwgInByb3RvY29sIjogImJsYWNraG9sZSIgfQogIF0sCiAgImRucyI6IHsg
InNlcnZlcnMiOiBbIjEuMS4xLjEiLCI4LjguOC44Il0sICJxdWVyeVN0cmF0ZWd5IjogIlVzZUlQ
djQiIH0sCiAgInJvdXRpbmciOiB7ICJkb21haW5TdHJhdGVneSI6ICJJUElmTm9uTWF0Y2giLCAi
cnVsZXMiOiBbXSB9Cn0KRU9GCm9rICLQn9GA0L7RhNC40LvRjCDQs9C+0YLQvtCyOiAkQkFTRS9u
b2RlL3hyYXktcHJvZmlsZS5qc29uIgoKY2F0IDw8RU9GCgo9PT09PT09PT09PT09PT09PT09PT09
PT0gINCk0JDQl9CQIDEg0JPQntCi0J7QktCQICA9PT09PT09PT09PT09PT09PT09PT09PT0K0J/Q
sNC90LXQu9GMINC+0YLQutGA0YvQstCw0LXRgtGB0Y8g0L/QvjogIGh0dHBzOi8vJHtET01BSU59
LyAgIChDYWRkeSDQvdCwIDQ0MykK0J/QvtC00L7QttC00LggfjMwINGB0LXQuiDQvdCwINCy0YvQ
v9GD0YHQuiDRgdC10YDRgtC40YTQuNC60LDRgtCwLgoK0JTQsNC70YzRiNC1INCg0KPQmtCQ0JzQ
mCDQsiDQv9Cw0L3QtdC70LgsINC/0L4g0L/QvtGA0Y/QtNC60YM6CiAgQS4gaHR0cHM6Ly8ke0RP
TUFJTn0vICAtPiDRgdC+0LfQtNCw0Lkg0LDQtNC80LjQvdCwLgogIEIuINCd0L7QtNGLIC0+INCh
0L7Qt9C00LDRgtGMOiDQuNC80Y8gbW9vbmxpZ2h0LWV4aXQsINCw0LTRgNC10YEgJHtNWUlQfSwg
Tm9kZSBQb3J0IDIyMjIuCiAgICAgU0VDUkVUX0tFWSDQutC+0L/QuNGA0YPQuSDQmtCd0J7Qn9Ca
0J7QmS3QmNCa0J7QndCa0J7QmSAo0L/QvtC70LUg0L7QsdGA0LXQt9Cw0L3Qviwg0LzRi9GI0LrQ
vtC5INC90LUg0LLRi9C00LXQu9GP0YLRjCEpLgogIEMuINCf0YDQvtGE0LjQu9C4IC0+IERlZmF1
bHQtUHJvZmlsZSAtPiAi0JrQvtC90YTQuNCzLiBYcmF5IjoKICAgICBDdHJsK0EgLT4gRGVsZXRl
IC0+INCy0YHRgtCw0LLRjCDRgdC+0LTQtdGA0LbQuNC80L7QtSAkQkFTRS9ub2RlL3hyYXktcHJv
ZmlsZS5qc29uIC0+INCh0L7RhdGA0LDQvdC4LgogIEQuINCd0L7QtNGLIC0+IG1vb25saWdodC1l
eGl0IC0+INCf0YDQvtGE0LjQu9C4IC0+INCY0LfQvNC10L3QuNGC0YwgLT4g0LLRi9Cx0LXRgNC4
IERlZmF1bHQtUHJvZmlsZQogICAgICjQvtGC0LzQtdGC0Ywg0LLRgdC1IDQg0LjQvdCx0LDRg9C9
0LTQsCwg0LLQutC7LiBIWVNURVJJQTIpIC0+INCy0L3QuNC30YMg0KHQvtGF0YDQsNC90LjRgtGM
LiAo0J/RgNC+0YTQuNC70Ywg0J7QkdCv0JfQkNCdINCx0YvRgtGMINC/0YDQuNCy0Y/Qt9Cw0L0u
KQoK0J/QvtGC0L7QvCDQvdCwINGB0LXRgNCy0LXRgNC1INC/0L4g0L7Rh9C10YDQtdC00Lg6CiAg
RS4gc3VkbyBiYXNoIGRlcGxveS1ub2RlLW1vb25saWdodC5zaCAgICAgKNC/0L7QtNC90LjQvNC1
0YIg0L3QvtC00YM7IFNFQ1JFVF9LRVkg0LLRgdGC0LDQstC40YjRjCDQsiBuYW5vKQogIEYuIHN1
ZG8gYmFzaCBoYW5kb2ZmLW1vb25saWdodC5zaCAgICAgICAgIChDYWRkeSAtPiA4NDQzLCA0NDMg
0L7RgtC00LDRkdC8INC90L7QtNC1LCDRgSDQsNCy0YLQvtC+0YLQutCw0YLQvtC8KQogIEcuIHN1
ZG8gYmFzaCBzeW5jLWh5Mi1jZXJ0LnNoICAgICAgICAgICAgICjQv9C+0LvQvtC20LjRgtGMIExF
LdGB0LXRgNGCINCyIG5vZGUvY2VydHMg0LTQu9GPIEh5c3RlcmlhMikKCtCa0LvRjtGH0LggUmVh
bGl0eSDQtNC70Y8g0LHRg9C00YPRidC10LPQviBAQFJFTEFZX05BTUVAQDogJEJBU0Uvbm9kZS9y
ZWFsaXR5LmVudgo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PQpFT0YK
__B64__
  base64 -d > "$d/deploy-node.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1ub2Rl
LnNoIOKAlCDQutC+0L3RgtC10LnQvdC10YAg0L3QvtC00YsgWHJheSAoQEBFWElUX05BTUVAQCDQ
uNC70LggQEBSRUxBWV9OQU1FQEApCiMgINCQ0YDQs9GD0LzQtdC90YI6IGV4aXQgKEBARVhJVF9O
QU1FQEAsINC90YPQttC10L0gaGFuZG9mZikgfCByZWxheSAoQEBSRUxBWV9OQU1FQEAsIDQ0MyDR
gdCy0L7QsdC+0LTQtdC9KQojICDQl9Cw0L/Rg9GB0Lo6ICBzdWRvIGJhc2ggZGVwbG95LW5vZGUu
c2ggZXhpdHxyZWxheQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CnNldCAtZXVvIHBpcGVmYWlsCkJB
U0U9L29wdC9AQFNMVUdAQApNT0RFPSIkezE6LWV4aXR9IgpvaygpeyBlY2hvIC1lICJcMDMzWzE7
MzJtICBPSyAkKlwwMzNbMG0iOyB9CltbICRFVUlEIC1lcSAwIF1dIHx8IHsgZWNobyAi0JfQsNC/
0YPRgdGC0Lgg0YfQtdGA0LXQtyBzdWRvIjsgZXhpdCAxOyB9Cgp1ZncgYWxsb3cgMjIyMi90Y3Ag
Pi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKbWtkaXIgLXAgIiRCQVNFL25vZGUvY2VydHMiICYmIGNk
ICIkQkFTRS9ub2RlIgoKY2F0ID4gZG9ja2VyLWNvbXBvc2UueW1sIDw8J0VPRicKc2VydmljZXM6
CiAgcmVtbmFub2RlOgogICAgaW1hZ2U6IHJlbW5hd2F2ZS9ub2RlOmxhdGVzdAogICAgY29udGFp
bmVyX25hbWU6IHJlbW5hbm9kZQogICAgaG9zdG5hbWU6IHJlbW5hbm9kZQogICAgcmVzdGFydDog
YWx3YXlzCiAgICBuZXR3b3JrX21vZGU6IGhvc3QKICAgIGVudl9maWxlOgogICAgICAtIC5lbnYK
ICAgIHZvbHVtZXM6CiAgICAgIC0gLi9jZXJ0czovY2VydHM6cm8gICAgICMg0YHQtdGA0YLRiyBI
eXN0ZXJpYTIgKHN5bmMtaHkyLWNlcnQuc2gg0LrQu9Cw0LTRkdGCINGB0Y7QtNCwKQpFT0YKCiMg
LS0g0L/QvtC70YPRh9C40YLRjCBTRUNSRVRfS0VZOiDQuNGB0YLQvtGH0L3QuNC6INC30LDQstC4
0YHQuNGCINC+0YIg0YDQvtC70LggLS0KS0VZPSIiCmlmIFsgIiRNT0RFIiA9IHJlbGF5IF07IHRo
ZW4KICBCT09UU1RSQVA9IiR7UkVMQVlfQk9PVFNUUkFQOi19IgogIFsgLXogIiRCT09UU1RSQVAi
IF0gJiYgQk9PVFNUUkFQPSIkKGZpbmQgL29wdCAtbmFtZSAncmVsYXktYm9vdHN0cmFwLmVudicg
Mj4vZGV2L251bGwgfCBoZWFkIC0xKSIKICBpZiBbIC1uICIkQk9PVFNUUkFQIiBdICYmIFsgLWYg
IiRCT09UU1RSQVAiIF07IHRoZW4KICAgIEtFWT0iJChncmVwICdeU0VDUkVUX0tFWT0nICIkQk9P
VFNUUkFQIiB8IGN1dCAtZD0gLWYyLSkiCiAgICBbIC1uICIkS0VZIiBdICYmIHByaW50ZiAnTk9E
RV9QT1JUPTIyMjJcblNFQ1JFVF9LRVk9JXNcbicgIiRLRVkiID4gLmVudiAgICAgICAmJiBvayAi
U0VDUkVUX0tFWSDQstC30Y/RgiDQuNC3IHJlbGF5LWJvb3RzdHJhcC5lbnYgKNC00LvQuNC90LAg
JHsjS0VZfSkiCiAgZmkKZWxzZQogICMgZXhpdDogcHJvdmlzaW9uLnNoINC/0LjRiNC10YIgU0VD
UkVUX0tFWSDQsiAuZW52INC00L4g0Y3RgtC+0LPQviDRiNCw0LPQsCAoaGVhZGxlc3Mt0L/Rg9GC
0YwpCiAgWyAtZiAuZW52IF0gJiYgS0VZPSIkKGdyZXAgJ15TRUNSRVRfS0VZPScgLmVudiAyPi9k
ZXYvbnVsbCB8IGN1dCAtZD0gLWYyLSkiCiAgWyAtbiAiJEtFWSIgXSAmJiBvayAiU0VDUkVUX0tF
WSDRg9C20LUg0LIgLmVudiAocHJvdmlzaW9uLnNoLCDQtNC70LjQvdCwICR7I0tFWX0pIOKAlCDR
gNGD0YfQvdC+0Lkg0YjQsNCzINC/0YDQvtC/0YPRidC10L0iCmZpCgppZiBbIC16ICIkS0VZIiBd
IHx8IFsgIiR7I0tFWX0iIC1sdCAxMDAgXTsgdGhlbgogIHByaW50ZiAnTk9ERV9QT1JUPTIyMjJc
blNFQ1JFVF9LRVk9XG4nID4gLmVudgogIGlmIFsgIiRNT0RFIiA9IHJlbGF5IF07IHRoZW4KICAg
IGVjaG8gIj4+PiByZWxheS1ib290c3RyYXAuZW52INC90LUg0L3QsNC50LTQtdC9INC40LvQuCBT
RUNSRVRfS0VZINC/0YPRgdGCLiIKICAgIGVjaG8gIj4+PiDQntGC0LrRgNC+0LXRgtGB0Y8gbmFu
byDigJQg0LLRgdGC0LDQstGMIFNFQ1JFVF9LRVkg0LjQtyDQv9Cw0L3QtdC70LggTW9vbmxpZ2h0
INC60L3QvtC/0LrQvtC5LdC40LrQvtC90LrQvtC5LiIKICBlbHNlCiAgICBlY2hvICI+Pj4g0J7R
gtC60YDQvtC10YLRgdGPIG5hbm86INCy0YHRgtCw0LLRjCBTRUNSRVRfS0VZINC40Lcg0L/QsNC9
0LXQu9C4INC+0LTQvdC+0Lkg0YHRgtGA0L7QutC+0LksINC30LDRgtC10LwgQ3RybCtPLCBFbnRl
ciwgQ3RybCtYLiIKICBmaQogIHJlYWQgLXIgLXAgItCd0LDQttC80LggRW50ZXIg0YfRgtC+0LHR
iyDQvtGC0LrRgNGL0YLRjCBuYW5vLi4uIiBfCiAgbmFubyAuZW52CiAgS0VZPSIkKGdyZXAgJ15T
RUNSRVRfS0VZPScgLmVudiB8IGN1dCAtZD0gLWYyLSkiCmZpCgplY2hvICLQlNC70LjQvdCwIFNF
Q1JFVF9LRVk6ICR7I0tFWX0gKNC90L7RgNC80LAgfjIwMDAtMjYwMCkuIgppZiBlY2hvICIkS0VZ
IiB8IGJhc2U2NCAtZCAyPi9kZXYvbnVsbCB8IHRhaWwgLWMgMyB8IGdyZXAgLXEgJ30nOyB0aGVu
CiAgb2sgItCa0LvRjtGHINGG0LXQu9GL0LkuIgplbHNlCiAgZWNobyAtZSAiXDAzM1sxOzMzbSAg
ISDQmtC70Y7RhyDQv9C+0YXQvtC20LUg0L7QsdGA0LXQt9Cw0L0uINCe0YLQutGA0L7QuSDRgdC9
0L7QstCwOiBuYW5vICRCQVNFL25vZGUvLmVudlwwMzNbMG0iCmZpCgpkb2NrZXIgY29tcG9zZSB1
cCAtZCAtLWZvcmNlLXJlY3JlYXRlCnNsZWVwIDUKZG9ja2VyIHBzIC0tZm9ybWF0ICJ0YWJsZSB7
ey5OYW1lc319XHR7ey5TdGF0dXN9fSIKZWNobyAiLS0tINC70L7Qs9C4INC90L7QtNGLIC0tLSI7
IGRvY2tlciBsb2dzIHJlbW5hbm9kZSAtLXRhaWwgMjAKZWNobwppZiBbICIkTU9ERSIgPSByZWxh
eSBdOyB0aGVuCiAgZWNobyAiPj4+INCW0LTRgyDQv9C+0YDRgiA0NDMgKNC90L7QtNCwINC00L7Q
u9C20L3QsCDQv9C+0LvRg9GH0LjRgtGMINC40L3QsdCw0YPQvdC00Ysg0Lgg0L/QvtC00L3Rj9GC
0YwgWHJheSnigKYiCiAgX3dhaXRlZD0wCiAgd2hpbGUgWyAiJF93YWl0ZWQiIC1sdCA5MCBdOyBk
bwogICAgaWYgc3MgLXRsbnAgMj4vZGV2L251bGwgfCBncmVwIC1xICc6NDQzICc7IHRoZW4KICAg
ICAgZWNobyAiICDinJMgdGNwLzQ0MyDQs9C+0YLQvtCyICgke193YWl0ZWR90YEpIgogICAgICBi
cmVhawogICAgZmkKICAgIHNsZWVwIDM7IF93YWl0ZWQ9JCgoX3dhaXRlZCszKSkKICBkb25lCiAg
aWYgISBzcyAtdGxucCAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgJzo0NDMgJzsgdGhlbgogICAgZWNo
byAiICAhIHRjcC80NDMg0LLRgdGRINC10YnRkSDQvdC1INGB0LvRg9GI0LDQtdGC0YHRjyDQv9C+
0YHQu9C1IDkw0YEiCiAgICBlY2hvICIgICEg0J/RgNC+0LLQtdGA0Yw6IGRvY2tlciBsb2dzIHJl
bW5hbm9kZSB8IHRhaWwgLTMwIgogICAgZWNobyAiICAhINCj0LHQtdC00LjRgdGMINGH0YLQviDQ
vdC+0LTQsCDQt9Cw0YDQtdCz0LjRgdGC0YDQuNGA0L7QstCw0L3QsCDQsiDQv9Cw0L3QtdC70Lgg
TW9vbmxpZ2h0INC4INC/0L7Qu9GD0YfQuNC70LAg0LjQvdCx0LDRg9C90LTRiyIKICBmaQogIGVj
aG8gIj4+PiDQn9C+0LTQutC70Y7Rh9Cw0LnRgdGPINGH0LXRgNC10LcgJ3ZpYSBAQFJFTEFZX05B
TUVAQCcg0Lgg0L/RgNC+0LLQtdGA0Ywg0LLQvdC10YjQvdC40LkgSVAgPSBAQEVYSVRfTkFNRUBA
LiIKZWxzZQogIGVjaG8gIj4+PiDQldGB0LvQuCByZW1uYW5vZGUg0LTQtdGA0LbQuNGC0YHRjyBV
cCDQuCDQsiDQu9C+0LPQsNGFINC90LXRgiAnUmVxdWlyZWQnLydJbnZhbGlkJyDigJQg0LLRgdGR
INC+0LouIgogIGVjaG8gIj4+PiBYcmF5INC/0L7QutCwINCd0JUg0LfQsNC50LzRkdGCIDQ0MyAo
0LXQs9C+INC00LXRgNC20LjRgiBDYWRkeSkg4oCUINGN0YLQviDQvdC+0YDQvNCw0LvRjNC90L4u
IgogIGVjaG8gIj4+PiDQodC70LXQtNGD0Y7RidC40Lkg0YjQsNCzOiBzdWRvIGJhc2ggaGFuZG9m
Zi1tb29ubGlnaHQuc2giCmZpCg==
__B64__
  base64 -d > "$d/deploy-sunshine.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1zdW5zaGluZS5zaCAg4oCUICBAQFJFTEFZX05BTUVAQCAoQEBSRUxBWV9ET01BSU5AQCkgINCk0JDQl9CQIDEgIFvQoNCV0KLQoNCQ0J3QodCb0K/QotCe0KBdCiMgIEBAUkVMQVlfTkFNRUBAINC/0YDQvtGJ0LUgQEBFWElUX05BTUVAQDog0L/QsNC90LXQu9C4INC90LXRgiAtPiDRhdC10L3QtNC+0YTRhCDQndCVINC90YPQttC10L0uCiMgIENhZGR5INGB0YDQsNC30YMg0L3QsCA4NDQzICjRgdC10YDRgiDRh9C10YDQtdC3INC/0L7RgNGCIDgwKSwg0L3QvtC00LAgUmVhbGl0eSDQsdC10YDRkdGCIDQ0MyDRh9C40YHRgtC+LgojICDQktC10YHRjCDQutC70LjQtdC90YLRgdC60LjQuSDRgtGA0LDRhNC40Log0LrQsNGB0LrQsNC00L7QvCDRg9GF0L7QtNC40YIg0L3QsCBAQEVYSVRfTkFNRUBAICjQstGL0YXQvtC0ID0gSVAgQEBFWElUX05BTUVAQCkuCiMgINCX0LDQv9GD0YHQujogIHN1ZG8gYmFzaCBkZXBsb3ktc3Vuc2hpbmUuc2gKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbApvaygpeyAgZWNobyAiICDinJMgJCoiOyB9Cndhcm4oKXsgZWNobyAiICAhICQqIjsgfQpkaWUoKXsgZWNobyAiICDinJcgJCoiID4mMjsgZXhpdCAxOyB9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSDQndCQ0KHQotCg0J7QmdCa0JggLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCkRPTUFJTj0iQEBSRUxBWV9ET01BSU5AQCIgICAgICAgICAgICAgICAgICAjINC00L7QvNC10L0gQEBSRUxBWV9OQU1FQEAgKEEt0LfQsNC/0LjRgdGMIC0+IElQIEBAUkVMQVlfTkFNRUBAKQpBQ01FX0VNQUlMPSJAQEFDTUVfRU1BSUxAQCIKV1NfUEFUSD0iL3dzbmciClhIVFRQX1BBVEg9Ii94aCIKIyAtLS0g0L/QsNGA0LDQvNC10YLRgNGLINC60LDRgdC60LDQtNCwINC90LAgQEBFWElUX05BTUVAQCAo0LLRi9GF0L7QtNC90L7QuSDRgdC10YDQstC10YApIC0tLQpNT09OX0lQPSIke0VYSVRfSVA6LUBARVhJVF9JUEBAfSIKTU9PTl9TTkk9IiR7UkVMQVlfRE9NQUlOOi1AQFJFTEFZX0RPTUFJTkBAfSIKIyBSZWFsaXR5LdC60LvRjtGH0LggTW9vbmxpZ2h0INC4IFVVSUQg0YHQtdGA0LLQuNGBLdGO0LfQtdGA0LAg0LHQtdGA0ZHQvCDQuNC3IHJlbGF5LWJvb3RzdHJhcC5lbnYgKHByb3Zpc2lvbi1yZWxheS5zaCkKQk9PVFNUUkFQPSIke1JFTEFZX0JPT1RTVFJBUDotL29wdC8kQkFTRS9yZWxheS1ib290c3RyYXAuZW52fSIKWyAtZiAiJEJPT1RTVFJBUCIgXSB8fCBCT09UU1RSQVA9IiQoZmluZCAvb3B0IC1uYW1lICdyZWxheS1ib290c3RyYXAuZW52JyAyPi9kZXYvbnVsbCB8IGhlYWQgLTEpIgppZiBbIC1mICIkQk9PVFNUUkFQIiBdOyB0aGVuCiAgc291cmNlICIkQk9PVFNUUkFQIgogIE1PT05fUFVCS0VZPSIke01PT05fUFVCS0VZOi19IgogIE1PT05fU0hPUlRJRD0iJHtNT09OX1NIT1JUSUQ6LX0iCiAgU0VSVklDRV9VVUlEPSIke1NFUlZJQ0VfVVVJRDotfSIKICAjIFJlYWxpdHkt0LrQu9GO0YfQuCBTdW5zaGluZSDRgtC+0LbQtSDQvNC+0LPRg9GCINCx0YvRgtGMINCyIGJvb3RzdHJhcAogIFJFTEFZX1BSSVY9IiR7UkVMQVlfUFJJVjotfSIKICBSRUxBWV9QVUI9IiR7UkVMQVlfUFVCOi19IgogIFJFTEFZX1NJRD0iJHtSRUxBWV9TSUQ6LX0iCiAgb2sgInJlbGF5LWJvb3RzdHJhcC5lbnYg0LfQsNCz0YDRg9C20LXQvSIKZWxzZQogIHdhcm4gInJlbGF5LWJvb3RzdHJhcC5lbnYg0L3QtSDQvdCw0LnQtNC10L0g4oCUINC40YHQv9C+0LvRjNC30YPRjtGC0YHRjyDQt9Cw0YXQsNGA0LTQutC+0LbQtdC90L3Ri9C1INC60LvRjtGH0LggKNGD0YHRgtCw0YDQtdCy0YjQuNC1ISkiCiAgTU9PTl9QVUJLRVk9IkBATU9PTl9QVUJLRVlfUExBQ0VIT0xERVJAQCIKICBNT09OX1NIT1JUSUQ9IkBATU9PTl9TSE9SVElEX1BMQUNFSE9MREVSQEAiCiAgU0VSVklDRV9VVUlEPSIiCiAgUkVMQVlfUFJJVj0iIjsgUkVMQVlfUFVCPSIiOyBSRUxBWV9TSUQ9IiIKZmkKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoKQkFTRT0vb3B0L0BAU0xVR0BACmxvZygpeyBlY2hvIC1lICJcblwwMzNbMTszNm09PT4gJCpcMDMzWzBtIjsgfQpvaygpeyAgZWNobyAtZSAiXDAzM1sxOzMybSAgT0sgJCpcMDMzWzBtIjsgfQp3YXJuKCl7IGVjaG8gLWUgIlwwMzNbMTszM20gICEgJCpcMDMzWzBtIjsgfQoKW1sgJEVVSUQgLWVxIDAgXV0gfHwgeyBlY2hvICLQl9Cw0L/Rg9GB0YLQuCDRh9C10YDQtdC3IHN1ZG86IHN1ZG8gYmFzaCAkMCI7IGV4aXQgMTsgfQpjb21tYW5kIC12IGFwdC1nZXQgPi9kZXYvbnVsbCB8fCB7IGVjaG8gItCd0YPQttC10L0gVWJ1bnR1L0RlYmlhbiAoYXB0KS4iOyBleGl0IDE7IH0KbWtkaXIgLXAgIiRCQVNFIi97Y2FkZHksbm9kZSxkZWNveX0KCiMgLS0tIDAuINCf0LDQutC10YLRiyArIEROUyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KbG9nICIwLzUg0J/QsNC60LXRgtGLINC4IEROUyIKZXhwb3J0IERFQklBTl9GUk9OVEVORD1ub25pbnRlcmFjdGl2ZQphcHQtZ2V0IHVwZGF0ZSAteSA+L2Rldi9udWxsCmFwdC1nZXQgaW5zdGFsbCAteSBjdXJsIG9wZW5zc2wgY2EtY2VydGlmaWNhdGVzID4vZGV2L251bGwKTVlJUD0kKGN1cmwgLWZzUzQgaHR0cHM6Ly9hcGkuaXBpZnkub3JnIDI+L2Rldi9udWxsIHx8IGhvc3RuYW1lIC1JIHwgYXdrICd7cHJpbnQgJDF9JykKRE5TSVA9JChnZXRlbnQgYWhvc3RzdjQgIiRET01BSU4iIHwgYXdrICd7cHJpbnQgJDE7IGV4aXR9JyB8fCB0cnVlKQppZiBbWyAtbiAiJE1ZSVAiICYmICIkRE5TSVAiID09ICIkTVlJUCIgXV07IHRoZW4KICBvayAiRE5TOiAkRE9NQUlOIC0+ICRNWUlQICjRjdGC0L4gQEBSRUxBWV9OQU1FQEApIgplbHNlCiAgd2FybiAi0JTQvtC80LXQvSAkRE9NQUlOINGD0LrQsNC30YvQstCw0LXRgiDQvdCwICcke0ROU0lQOi3QvdC40YfQtdCz0L59Jywg0LAg0YHQtdGA0LLQtdGAICckTVlJUCcuIgogIHdhcm4gItCd0YPQttC90LAgQS3Qt9Cw0L/QuNGB0Yw6ICRET01BSU4gLT4gJE1ZSVAgKEROUyBvbmx5KS4g0JHQtdC3INC90LXRkSDRgdC10YDRgiDQvdC1INCy0YvQv9GD0YHRgtC40YLRgdGPLiIKICB3YXJuICLQn9GA0L7QtNC+0LvQttGDINGH0LXRgNC10LcgMTUg0YHQtdC6OyDQv9C+0YLQvtC8INC/0LXRgNC10LfQsNC/0YPRgdGC0Lgg0YHQutGA0LjQv9GCLiIKICBzbGVlcCAxNQpmaQoKIyAtLS0gMS4gRG9ja2VyIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjEvNSBEb2NrZXIiCmlmIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgJiYgZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gb2sgIkRvY2tlciDRg9C20LUg0YHRgtC+0LjRgiIKZWxzZSBjdXJsIC1mc1NMIGh0dHBzOi8vZ2V0LmRvY2tlci5jb20gfCBzaDsgb2sgIkRvY2tlciDRg9GB0YLQsNC90L7QstC70LXQvSI7IGZpCgojIC0tLSAyLiBJUHY2IG9mZiArINGE0L7RgNCy0LDRgNC00LjQvdCzIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjIvNSBJUHY2IG9mZiArIGlwX2ZvcndhcmQiCmNhdCA+L2V0Yy9zeXNjdGwuZC85OS1AQFNMVUdAQC5jb25mIDw8J0VPRicKbmV0LmlwdjYuY29uZi5hbGwuZGlzYWJsZV9pcHY2ID0gMQpuZXQuaXB2Ni5jb25mLmRlZmF1bHQuZGlzYWJsZV9pcHY2ID0gMQpuZXQuaXB2Ni5jb25mLmxvLmRpc2FibGVfaXB2NiA9IDEKbmV0LmlwdjQuaXBfZm9yd2FyZCA9IDEKRU9GCnN5c2N0bCAtLXN5c3RlbSA+L2Rldi9udWxsCm9rICJJUHY2INCy0YvQutC70Y7Rh9C10L0iCgojIC0tLSAzLiBVRlcgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmxvZyAiMy81IEZpcmV3YWxsIgphcHQtZ2V0IGluc3RhbGwgLXkgdWZ3ID4vZGV2L251bGwKdWZ3IC0tZm9yY2UgcmVzZXQgPi9kZXYvbnVsbAp1ZncgZGVmYXVsdCBkZW55IGluY29taW5nID4vZGV2L251bGwKdWZ3IGRlZmF1bHQgYWxsb3cgb3V0Z29pbmcgPi9kZXYvbnVsbApmb3IgcCBpbiAyMi90Y3AgODAvdGNwIDQ0My90Y3AgNDQzL3VkcCAyMDgzL3RjcCAyMjIyL3RjcDsgZG8gdWZ3IGFsbG93ICIkcCIgPi9kZXYvbnVsbDsgZG9uZQp1ZncgLS1mb3JjZSBlbmFibGUgPi9kZXYvbnVsbApvayAi0J7RgtC60YDRi9GC0Ys6IDIyLDgwLDQ0My90Y3AgwrcgNDQzL3VkcCDCtyAyMDgzL3RjcChYSFRUUCkgwrcgMjIyMi90Y3Ao0L3QvtC00LApIgoKIyAtLS0gNC4gQ2FkZHkg0L3QsCA4NDQzICjQtNC10LrQvtC5ICsgd3MveGh0dHApLCDRgdC10YDRgiDRh9C10YDQtdC3INC/0L7RgNGCIDgwIC0tLS0tLS0tLS0tLS0tLS0tCmxvZyAiNC81IENhZGR5INC90LAgODQ0MyArINC00LXQutC+0LkiCmNhdCA+ICIkQkFTRS9kZWNveS9pbmRleC5odG1sIiA8PCdFT0YnCjwhZG9jdHlwZSBodG1sPjxodG1sIGxhbmc9InJ1Ij48aGVhZD48bWV0YSBjaGFyc2V0PSJ1dGYtOCI+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPk15U3BoZXJlIOKAlCDQvtCx0LvQsNGH0L3QvtC1INGF0YDQsNC90LjQu9C40YnQtTwvdGl0bGU+CjxzdHlsZT5ib2R5e2ZvbnQtZmFtaWx5OnN5c3RlbS11aSxBcmlhbCxzYW5zLXNlcmlmO2JhY2tncm91bmQ6IzBmMTIyMTtjb2xvcjojZThlYWYyOwpkaXNwbGF5OmZsZXg7bWluLWhlaWdodDoxMDB2aDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MH0KLmN7dGV4dC1hbGlnbjpjZW50ZXI7bWF4LXdpZHRoOjUyMHB4O3BhZGRpbmc6NDBweH1oMXtmb250LXNpemU6MnJlbTttYXJnaW46MCAwIC41cmVtfQpwe29wYWNpdHk6Ljc7bGluZS1oZWlnaHQ6MS42fS5ie2Rpc3BsYXk6aW5saW5lLWJsb2NrO21hcmdpbi10b3A6MThweDtwYWRkaW5nOjEwcHggMjBweDsKYm9yZGVyOjFweCBzb2xpZCAjM2EzZjVjO2JvcmRlci1yYWRpdXM6OHB4O2NvbG9yOiM5ZmIwZmY7dGV4dC1kZWNvcmF0aW9uOm5vbmV9PC9zdHlsZT4KPC9oZWFkPjxib2R5PjxkaXYgY2xhc3M9ImMiPjxoMT5NeVNwaGVyZTwvaDE+CjxwPtCb0LjRh9C90L7QtSDQvtCx0LvQsNGH0L3QvtC1INGF0YDQsNC90LjQu9C40YnQtS4g0KTQsNC50LvRiywg0YHQuNC90YXRgNC+0L3QuNC30LDRhtC40Y8sINC00L7RgdGC0YPQvyDRgSDQu9GO0LHQvtCz0L4g0YPRgdGC0YDQvtC50YHRgtCy0LAuPC9wPgo8YSBjbGFzcz0iYiIgaHJlZj0iL2xvZ2luIj7QktC+0LnRgtC4PC9hPjwvZGl2PjwvYm9keT48L2h0bWw+CkVPRgpjYXQgPiAiJEJBU0UvY2FkZHkvQ2FkZHlmaWxlIiA8PEVPRgp7CiAgICBzZXJ2ZXJzIDo4NDQzIHsKICAgICAgICBwcm90b2NvbHMgaDEKICAgIH0KICAgIGVtYWlsICR7QUNNRV9FTUFJTH0KfQoke0RPTUFJTn06ODQ0MyB7CiAgICBAd3MgcGF0aCAke1dTX1BBVEh9ICR7V1NfUEFUSH0vKgogICAgaGFuZGxlIEB3cyB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1MwogICAgfQogICAgQHhoIHBhdGggJHtYSFRUUF9QQVRIfSAke1hIVFRQX1BBVEh9LyoKICAgIGhhbmRsZSBAeGggewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjIwNTQKICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAgcm9vdCAqIC9zcnYvZGVjb3kKICAgICAgICBmaWxlX3NlcnZlcgogICAgfQp9CkVPRgpjYXQgPiAiJEJBU0UvY2FkZHkvZG9ja2VyLWNvbXBvc2UueW1sIiA8PEVPRgpzZXJ2aWNlczoKICBjYWRkeToKICAgIGltYWdlOiBjYWRkeToyCiAgICBjb250YWluZXJfbmFtZTogQEBTTFVHQEAtY2FkZHkKICAgIHJlc3RhcnQ6IGFsd2F5cwogICAgbmV0d29ya19tb2RlOiBob3N0CiAgICB2b2x1bWVzOgogICAgICAtIC4vQ2FkZHlmaWxlOi9ldGMvY2FkZHkvQ2FkZHlmaWxlOnJvCiAgICAgIC0gJHtCQVNFfS9kZWNveTovc3J2L2RlY295OnJvCiAgICAgIC0gY2FkZHlfZGF0YTovZGF0YQogICAgICAtIGNhZGR5X2NvbmZpZzovY29uZmlnCnZvbHVtZXM6CiAgY2FkZHlfZGF0YToKICBjYWRkeV9jb25maWc6CkVPRgpjZCAiJEJBU0UvY2FkZHkiICYmIGRvY2tlciBjb21wb3NlIHVwIC1kCm9rICJDYWRkeSDQvdCwIDg0NDMgKNC00LXQutC+0LkgTXlTcGhlcmUg0LIg0LrQvtGA0L3QtSkuINCh0LXRgNGCINCy0YvQv9GD0YHRgtC40YLRgdGPINGH0LXRgNC10Lcg0L/QvtGA0YIgODAuIgoKIyAtLS0gNS4gUmVhbGl0eS3QutC70Y7Rh9C4IEBAUkVMQVlfTkFNRUBAICsg0L/RgNC+0YTQuNC70Ywg0YEg0LrQsNGB0LrQsNC00L7QvCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjUvNSBSZWFsaXR5LdC60LvRjtGH0LggQEBSRUxBWV9OQU1FQEAgKyDQv9GA0L7RhNC40LvRjCDRgSDQutCw0YHQutCw0LTQvtC8INC90LAgQEBFWElUX05BTUVAQCIKaWYgW1sgISAtZiAiJEJBU0Uvbm9kZS9yZWFsaXR5LmVudiIgXV07IHRoZW4KICBLRVlTPSQoZG9ja2VyIHJ1biAtLXJtIGdoY3IuaW8veHRscy94cmF5LWNvcmU6bGF0ZXN0IHgyNTUxOSAyPi9kZXYvbnVsbCB8fCB0cnVlKQogIFBSSVY9JChlY2hvICIkS0VZUyIgfCBncmVwIC1pRSAncHJpdmF0ZScgfCBhd2sgJ3twcmludCAkTkZ9JykKICBQVUI9JChlY2hvICAiJEtFWVMiIHwgZ3JlcCAtaUUgJ3B1YmxpY3xwYXNzd29yZCcgfCBhd2sgJ3twcmludCAkTkZ9JykKICBTSUQ9JChvcGVuc3NsIHJhbmQgLWhleCA4KQogIGlmIFtbIC16ICIkUFJJViIgfHwgLXogIiRQVUIiIF1dOyB0aGVuCiAgICB3YXJuICLQndC1INGA0LDRgdC/0LDRgNGB0LjQuyDQutC70Y7Rh9C4LiDQktGA0YPRh9C90YPRjjogZG9ja2VyIHJ1biAtLXJtIGdoY3IuaW8veHRscy94cmF5LWNvcmU6bGF0ZXN0IHgyNTUxOSIKICAgIFBSSVY9ItCS0KHQotCQ0JLQrF9QUklWQVRFIjsgUFVCPSLQktCh0KLQkNCS0KxfUFVCTElDIgogIGZpCiAgY2F0ID4gIiRCQVNFL25vZGUvcmVhbGl0eS5lbnYiIDw8RU9GClJFQUxJVFlfUFJJVkFURV9LRVk9JFBSSVYKUkVBTElUWV9QVUJMSUNfS0VZPSRQVUIKUkVBTElUWV9TSE9SVF9JRD0kU0lECkVPRgogIG9rICJSZWFsaXR5LdC60LvRjtGH0LggQEBSRUxBWV9OQU1FQEAg0LIgJEJBU0Uvbm9kZS9yZWFsaXR5LmVudiIKZmkKc291cmNlICIkQkFTRS9ub2RlL3JlYWxpdHkuZW52IgoKY2F0ID4gIiRCQVNFL25vZGUvc3Vuc2hpbmUtcHJvZmlsZS5qc29uIiA8PEVPRgp7CiAgImluYm91bmRzIjogWwogICAgeyAidGFnIjogIlNVTi1SRUFMSVRZIiwgImxpc3RlbiI6ICIwLjAuMC4wIiwgInBvcnQiOiA0NDMsICJwcm90b2NvbCI6ICJ2bGVzcyIsCiAgICAgICJzZXR0aW5ncyI6IHsgImNsaWVudHMiOiBbXSwgImRlY3J5cHRpb24iOiAibm9uZSIgfSwKICAgICAgInN0cmVhbVNldHRpbmdzIjogeyAibmV0d29yayI6ICJ0Y3AiLCAic2VjdXJpdHkiOiAicmVhbGl0eSIsCiAgICAgICAgInJlYWxpdHlTZXR0aW5ncyI6IHsgInNob3ciOiBmYWxzZSwgImRlc3QiOiAiMTI3LjAuMC4xOjg0NDMiLAogICAgICAgICAgInNlcnZlck5hbWVzIjogWyIke0RPTUFJTn0iXSwKICAgICAgICAgICJwcml2YXRlS2V5IjogIiR7UkVBTElUWV9QUklWQVRFX0tFWX0iLCAic2hvcnRJZHMiOiBbIiR7UkVBTElUWV9TSE9SVF9JRH0iXSB9IH0sCiAgICAgICJzbmlmZmluZyI6IHsgImVuYWJsZWQiOiB0cnVlLCAiZGVzdE92ZXJyaWRlIjogWyJodHRwIiwidGxzIiwicXVpYyJdIH0gfSwKICAgIHsgInRhZyI6ICJTVU4tV1MiLCAibGlzdGVuIjogIjEyNy4wLjAuMSIsICJwb3J0IjogMjA1MywgInByb3RvY29sIjogInZsZXNzIiwKICAgICAgInNldHRpbmdzIjogeyAiY2xpZW50cyI6IFtdLCAiZGVjcnlwdGlvbiI6ICJub25lIiB9LAogICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogIndzIiwgInNlY3VyaXR5IjogIm5vbmUiLCAid3NTZXR0aW5ncyI6IHsgInBhdGgiOiAiJHtXU19QQVRIfSIgfSB9IH0sCiAgICB7ICJ0YWciOiAiU1VOLVhIVFRQIiwgImxpc3RlbiI6ICIxMjcuMC4wLjEiLCAicG9ydCI6IDIwNTQsICJwcm90b2NvbCI6ICJ2bGVzcyIsCiAgICAgICJzZXR0aW5ncyI6IHsgImNsaWVudHMiOiBbXSwgImRlY3J5cHRpb24iOiAibm9uZSIgfSwKICAgICAgInN0cmVhbVNldHRpbmdzIjogeyAibmV0d29yayI6ICJ4aHR0cCIsICJzZWN1cml0eSI6ICJyZWFsaXR5IiwKICAgICAgICAicmVhbGl0eVNldHRpbmdzIjogeyAic2hvdyI6IGZhbHNlLCAiZGVzdCI6ICIxMjcuMC4wLjE6ODQ0MyIsICJzZXJ2ZXJOYW1lcyI6IFsiJHtET01BSU59Il0sCiAgICAgICAgICAicHJpdmF0ZUtleSI6ICIke1JFQUxJVFlfUFJJVkFURV9LRVl9IiwgInNob3J0SWRzIjogWyIke1JFQUxJVFlfU0hPUlRfSUR9Il0gfSwKICAgICAgICAieGh0dHBTZXR0aW5ncyI6IHsgInBhdGgiOiAiJHtYSFRUUF9QQVRIfSIsICJtb2RlIjogImF1dG8iIH0gfSB9CiAgXSwKICAib3V0Ym91bmRzIjogWwogICAgeyAidGFnIjogInRvLW1vb25saWdodCIsICJwcm90b2NvbCI6ICJ2bGVzcyIsCiAgICAgICJzZXR0aW5ncyI6IHsgInZuZXh0IjogWyB7CiAgICAgICAgImFkZHJlc3MiOiAiJHtNT09OX0lQfSIsICJwb3J0IjogNDQzLAogICAgICAgICJ1c2VycyI6IFsgeyAiaWQiOiAiX19TRVJWSUNFX1VTRVJfVVVJRF9fIiwgImVuY3J5cHRpb24iOiAibm9uZSIsICJmbG93IjogInh0bHMtcnByeC12aXNpb24iIH0gXQogICAgICB9IF0gfSwKICAgICAgInN0cmVhbVNldHRpbmdzIjogeyAibmV0d29yayI6ICJ0Y3AiLCAic2VjdXJpdHkiOiAicmVhbGl0eSIsCiAgICAgICAgInJlYWxpdHlTZXR0aW5ncyI6IHsgInNlcnZlck5hbWUiOiAiJHtNT09OX1NOSX0iLCAiZmluZ2VycHJpbnQiOiAiY2hyb21lIiwKICAgICAgICAgICJwdWJsaWNLZXkiOiAiJHtNT09OX1BVQktFWX0iLCAic2hvcnRJZCI6ICIke01PT05fU0hPUlRJRH0iIH0gfSB9LAogICAgeyAidGFnIjogImRpcmVjdCIsICJwcm90b2NvbCI6ICJmcmVlZG9tIiwgInNldHRpbmdzIjogeyAiZG9tYWluU3RyYXRlZ3kiOiAiVXNlSVB2NCIgfSB9LAogICAgeyAidGFnIjogImJsb2NrIiwgInByb3RvY29sIjogImJsYWNraG9sZSIgfQogIF0sCiAgImRucyI6IHsgInNlcnZlcnMiOiBbIjEuMS4xLjEiLCI4LjguOC44Il0sICJxdWVyeVN0cmF0ZWd5IjogIlVzZUlQdjQiIH0sCiAgInJvdXRpbmciOiB7ICJkb21haW5TdHJhdGVneSI6ICJBc0lzIiwgInJ1bGVzIjogWwogICAgeyAidHlwZSI6ICJmaWVsZCIsICJpbmJvdW5kVGFnIjogWyJTVU4tUkVBTElUWSIsIlNVTi1XUyIsIlNVTi1YSFRUUCJdLCAib3V0Ym91bmRUYWciOiAidG8tbW9vbmxpZ2h0IiB9CiAgXSB9Cn0KRU9GCm9rICLQn9GA0L7RhNC40LvRjCBAQFJFTEFZX05BTUVAQCDQs9C+0YLQvtCyOiAkQkFTRS9ub2RlL3N1bnNoaW5lLXByb2ZpbGUuanNvbiIKCmNhdCA8PEVPRgoKPT09PT09PT09PT09PT09PT09PT09PT09ICBTVU5TSElORSDQpNCQ0JfQkCAxINCT0J7QotCe0JLQkCAgPT09PT09PT09PT09PT09PT09PT09PT09CkNhZGR5INC90LAgODQ0MyAo0LTQtdC60L7QuSksINGB0LXRgNGCINC00LvRjyAke0RPTUFJTn0g0LLRi9C/0YPRgdC60LDQtdGC0YHRjyDRh9C10YDQtdC3INC/0L7RgNGCIDgwLgpSZWFsaXR5LdC60LvRjtGH0LggQEBSRUxBWV9OQU1FQEA6ICAkQkFTRS9ub2RlL3JlYWxpdHkuZW52CiAgUFVCTElDX0tFWSA9ICR7UkVBTElUWV9QVUJMSUNfS0VZfQogIFNIT1JUX0lEICAgPSAke1JFQUxJVFlfU0hPUlRfSUR9CiAgKNGN0YLQuCDQtNCy0LAg0L3Rg9C20L3RiyDQtNC70Y8g0YXQvtGB0YLQsCAiUmVhbGl0eSB2aWEgQEBSRUxBWV9OQU1FQEAiINCyINC/0LDQvdC10LvQuCkKCtCU0LDQu9GM0YjQtSDQoNCj0JrQkNCc0Jgg0LIg0L/QsNC90LXQu9C4IEBARVhJVF9OQU1FQEAgKGh0dHBzOi8vJHtNT09OX1NOSX0vKSwg0L/QviDQv9C+0YDRj9C00LrRgyDigJQg0YHQvC4gU1VOU0hJTkUtUkVBRE1FLm1kOgogIEEuINCf0L7Qu9GM0LfQvtCy0LDRgtC10LvQuCAtPiDRgdC+0LfQtNCw0YLRjCDRgdC10YDQstC40YEt0Y7Qt9C10YDQsCAo0L3QsNC/0YAuIHN2Yy1zdW5zaGluZSksINC/0YDQuNCy0Y/Qt9Cw0YLRjCDQuiDRgtC+0LzRgyDQttC1INGB0LrQstCw0LTRgywKICAgICDQs9C00LUg0LvQtdC20LDRgiDQuNC90LHQsNGD0L3QtNGLIEBARVhJVF9OQU1FQEAgKNGH0YLQvtCx0Ysg0LXQs9C+IFVVSUQg0LHRi9C7INCy0LDQu9C40LTQtdC9INC90LAgUmVhbGl0eS3QuNC90LHQsNGD0L3QtNC1IEBARVhJVF9OQU1FQEApLgogICAgINCh0LrQvtC/0LjRgNC+0LLQsNGC0Ywg0LXQs9C+IFVVSUQuCiAgQi4g0J3QsCDQodCV0KDQktCV0KDQlSBAQFJFTEFZX05BTUVAQCDQv9C+0LTRgdGC0LDQstC40YLRjCDRjdGC0L7RgiBVVUlEINCyINC/0YDQvtGE0LjQu9GMICjQstC80LXRgdGC0L4g0L/Qu9C10LnRgdGF0L7Qu9C00LXRgNCwKToKICAgICAgIHNlZCAtaSAncy9fX1NFUlZJQ0VfVVNFUl9VVUlEX18v0JLQkNCoX1VVSUQvJyAkQkFTRS9ub2RlL3N1bnNoaW5lLXByb2ZpbGUuanNvbgogICAgICAgY2F0ICRCQVNFL25vZGUvc3Vuc2hpbmUtcHJvZmlsZS5qc29uICAgICAgIyDQv9GA0L7QstC10YDRjCwg0YfRgtC+INC/0LvQtdC50YHRhdC+0LvQtNC10YDQsCDQsdC+0LvRjNGI0LUg0L3QtdGCCiAgQy4g0J/RgNC+0YTQuNC70LggLT4g0YHQvtC30LTQsNGC0Ywg0L3QvtCy0YvQuSDQv9GA0L7RhNC40LvRjCAiQEBSRUxBWV9OQU1FQEAtUHJvZmlsZSIgLT4g0JrQvtC90YTQuNCzIFhyYXkgLT4KICAgICDQstGB0YLQsNCy0LjRgtGMINGB0L7QtNC10YDQttC40LzQvtC1IHN1bnNoaW5lLXByb2ZpbGUuanNvbiAtPiDQodC+0YXRgNCw0L3QuNGC0YwuCiAgRC4g0J3QvtC00YsgLT4g0YHQvtC30LTQsNGC0Ywg0L3QvtC00YM6INC40LzRjyBzdW5zaGluZS1yZWxheSwg0LDQtNGA0LXRgSAke01ZSVB9LCBOb2RlIFBvcnQgMjIyMi4KICAgICDQn9GA0L7RhNC40LvRjCA9IEBAUkVMQVlfTkFNRUBALVByb2ZpbGUsINC+0YLQvNC10YLQuNGC0YwgMyDQuNC90LHQsNGD0L3QtNCwLCDQodCe0KXQoNCQ0J3QmNCi0Kwg0LLRi9Cx0L7RgCDQuNC90LHQsNGD0L3QtNC+0LIuCiAgICAg0KHQutC+0L/QuNGA0L7QstCw0YLRjCBTRUNSRVRfS0VZINC60L3QvtC/0LrQvtC5LdC40LrQvtC90LrQvtC5LgogIEUuINCS0L3Rg9GC0YDQtdC90L3QuNC1INGB0LrQstCw0LTRizog0LTQvtCx0LDQstC40YLRjCDQuNC90LHQsNGD0L3QtNGLIEBAUkVMQVlfTkFNRUBAINCyINGB0LrQstCw0LQg0Lgg0YPQsdC10LTQuNGC0YzRgdGPLCDRh9GC0L4g0LIg0YHQutCy0LDQtGUg0LXRgdGC0Ywg0Y7Qt9C10YAKICAgICAo0LjQvdCw0YfQtSDQvdC+0LTQsCBAQFJFTEFZX05BTUVAQCDQv9C+0LvRg9GH0LjRgiBpbmJvdW5kczpbXSDigJQg0LrQsNC6INCx0YvQu9C+INC90LAgQEBFWElUX05BTUVAQCkuCiAgRi4g0KXQvtGB0YLRiyAtPiDRgdC+0LfQtNCw0YLRjCAzINGF0L7RgdGC0LAgInZpYSBAQFJFTEFZX05BTUVAQCI6CiAgICAgICBSZWFsaXR5OiDQsNC00YDQtdGBICR7RE9NQUlOfTo0NDMsIFNOSSAke0RPTUFJTn0sIHB1YmtleS9zaG9ydElkIOKAlCBAQFJFTEFZX05BTUVAQCAo0YHQvC4g0LLRi9GI0LUpCiAgICAgICBXU1M6ICAgINCw0LTRgNC10YEgJHtET01BSU59OjQ0MywgU2VjdXJpdHkgVExTLCBTTkkrSG9zdCAke0RPTUFJTn0sIHBhdGggJHtXU19QQVRIfQogICAgICAgWEhUVFA6ICDQsNC00YDQtdGBICR7RE9NQUlOfTo0NDMsIFNlY3VyaXR5IFRMUywgU05JK0hvc3QgJHtET01BSU59LCBwYXRoICR7WEhUVFBfUEFUSH0KCtCf0L7RgtC+0Lwg0L3QsCBAQFJFTEFZX05BTUVAQDoKICBHLiBzdWRvIGJhc2ggZGVwbG95LW5vZGUtc3Vuc2hpbmUuc2ggICAo0L/QvtC00L3QuNC80LXRgiDQvdC+0LTRgzsgU0VDUkVUX0tFWSDQstGB0YLQsNCy0LjRiNGMINCyIG5hbm8pCgrQn9GA0L7QstC10YDQutCwOiDQv9C+0LTQutC70Y7Rh9C40YLRjNGB0Y8g0YfQtdGA0LXQtyAidmlhIEBAUkVMQVlfTkFNRUBAIiAtPiDQstC90LXRiNC90LjQuSBJUCDQtNC+0LvQttC10L0g0LHRi9GC0YwgJHtNT09OX0lQfSAoQEBFWElUX05BTUVAQCksCtCwINCy0YXQvtC0IOKAlCDRh9C10YDQtdC3ICR7RE9NQUlOfSAoQEBSRUxBWV9OQU1FQEApLgo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CkVPRgo=
__B64__
  base64 -d > "$d/gen_config.py.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJAQEJSQU5EQEA6IGJ1aWxkIE1lcmlkaWFuLVBXQSBj
b25maWcuanNvbiBmcm9tIGEgUmVtbmF3YXZlIHN1YnNjcmlwdGlvbi4KVXNhZ2U6IGdlbl9jb25m
aWcucHkgPHN1Yl9maWxlPiA8YXBwcy5qc29uPiBbc3Vic2NyaXB0aW9uX3VybF0gW2NsaWVudF9u
YW1lXQo8c3ViX2ZpbGU+OiBiYXNlNjQt0L/QvtC00L/QuNGB0LrQsCwg0LvQuNCx0L4g0YHQv9C4
0YHQvtC6IHVybCDQv9C+INGB0YLRgNC+0LrQsNC8LCDQu9C40LHQviBpbmZvLUpTT04uCkh5c3Rl
cmlhMiDRgdC40L3RgtC10LfQuNGA0YPQtdGC0YHRjyDQvtGC0LTQtdC70YzQvdC+IChSZW1uYXdh
dmUg0L3QtSDQutC70LDQtNGR0YIg0LXQs9C+INCyIGJhc2U2NC3Qv9C+0LTQv9C40YHQutGDKS4i
IiIKaW1wb3J0IHN5cywganNvbiwgYmFzZTY0LCBpbywgcmUKZnJvbSB1cmxsaWIucGFyc2UgaW1w
b3J0IHVybHBhcnNlLCB1bnF1b3RlLCBxdW90ZQp0cnk6CiAgICBpbXBvcnQgc2Vnbm8KZXhjZXB0
IEltcG9ydEVycm9yOgogICAgc3lzLmV4aXQoItCd0YPQttC10L0gc2Vnbm86IGFwdC1nZXQgaW5z
dGFsbCAteSBweXRob24zLXNlZ25vICjQuNC70LggcGlwIGluc3RhbGwgc2Vnbm8pIikKClNFUlZF
Ul9OQU1FPSJAQEJSQU5EQEAiOyBTRVJWRVJfSUNPTj0iXFUwMDAxRjMxOSI7IENPTE9SPSJzbGF0
ZSIgICAjIPCfjJkKUkVMQVlfSE9TVF9TVUZGSVg9IkBAUkVMQVlfRE9NQUlOQEAiOyBSRUxBWV9O
QU1FPSJAQFJFTEFZX05BTUVAQCIKSFkyX0VOQUJMRT1UcnVlICAgICAgICAgICAgICAgICAgICAg
ICAgICAjINGB0LjQvdGC0LXQt9C40YDQvtCy0LDRgtGMINC60LDRgNGC0L7Rh9C60LggSHlzdGVy
aWEyCkhZMl9URU1QTEFURT0iaHlzdGVyaWEyOi8ve3V1aWR9QHtob3N0fTo0NDMvP3NuaT17aG9z
dH0mYWxwbj1oMyZpbnNlY3VyZT0wI3tuYW1lfSIKCmRlZiBxcih1KToKICAgIGI9aW8uQnl0ZXNJ
TygpOyBzZWduby5tYWtlKHUpLnNhdmUoYixraW5kPSJwbmciLHNjYWxlPTEyKQogICAgcmV0dXJu
IGJhc2U2NC5iNjRlbmNvZGUoYi5nZXR2YWx1ZSgpKS5kZWNvZGUoImFzY2lpIikKZGVmIGxhYmVs
X29mKHUpOgogICAgcmV0dXJuIHVucXVvdGUodS5zcGxpdCgiIyIsMSlbMV0pIGlmICIjIiBpbiB1
IGVsc2UgIkNvbm5lY3Rpb24iCmRlZiBob3N0X29mKHUpOgogICAgdHJ5OiByZXR1cm4gdXJscGFy
c2UodSkuaG9zdG5hbWUgb3IgIiIKICAgIGV4Y2VwdCBFeGNlcHRpb246IHJldHVybiAiIgpkZWYg
c2x1ZyhzKToKICAgIHJldHVybiAoIiIuam9pbihjLmxvd2VyKCkgaWYgYy5pc2FsbnVtKCkgZWxz
ZSAiLSIgZm9yIGMgaW4gcykuc3RyaXAoIi0iKVs6NDBdKSBvciAiYyIKZGVmIGJhc2VfbGFiZWwo
bGJsKToKICAgIHJldHVybiByZS5zdWIocidccypcKFteKV0qXClccyokJywnJyxsYmwpLnN0cmlw
KCkKCnJhdz1vcGVuKHN5cy5hcmd2WzFdLGVuY29kaW5nPSJ1dGYtOCIsZXJyb3JzPSJyZXBsYWNl
IikucmVhZCgpLnN0cmlwKCkKYXBwcz1qc29uLmxvYWQob3BlbihzeXMuYXJndlsyXSxlbmNvZGlu
Zz0idXRmLTgiKSkKc3ViX3VybD1zeXMuYXJndlszXSBpZiBsZW4oc3lzLmFyZ3YpPjMgZWxzZSAi
IgpjbGllbnQgPXN5cy5hcmd2WzRdIGlmIGxlbihzeXMuYXJndik+NCBlbHNlICIiCgpsaW5rcz1b
XQpwYXJzZWQ9Tm9uZQp0cnk6IHBhcnNlZD1qc29uLmxvYWRzKHJhdykKZXhjZXB0IEV4Y2VwdGlv
bjogcGFyc2VkPU5vbmUKaWYgaXNpbnN0YW5jZShwYXJzZWQsZGljdCkgYW5kIHBhcnNlZC5nZXQo
ImxpbmtzIik6CiAgICBsaW5rcz1wYXJzZWRbImxpbmtzIl07IHN1Yl91cmw9c3ViX3VybCBvciBw
YXJzZWQuZ2V0KCJzdWJzY3JpcHRpb25VcmwiLCIiKQogICAgY2xpZW50PWNsaWVudCBvciAocGFy
c2VkLmdldCgidXNlciIpIG9yIHt9KS5nZXQoInVzZXJuYW1lIiwiIikKZWxzZToKICAgIHRleHQ9
cmF3CiAgICBpZiAiOi8vIiBub3QgaW4gcmF3OgogICAgICAgIHRyeToKICAgICAgICAgICAgZGVj
PWJhc2U2NC5iNjRkZWNvZGUocmF3KyI9IiooLWxlbihyYXcpJTQpKS5kZWNvZGUoInV0Zi04Iiwi
cmVwbGFjZSIpCiAgICAgICAgICAgIGlmICI6Ly8iIGluIGRlYzogdGV4dD1kZWMKICAgICAgICBl
eGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBsaW5rcz1bbG4uc3RyaXAoKSBmb3IgbG4gaW4gdGV4
dC5zcGxpdGxpbmVzKCkgaWYgIjovLyIgaW4gbG5dCgpwcm90b2NvbHM9W107IHJlbGF5X3VybHM9
W10KZm9yIHUgaW4gbGlua3M6CiAgICBpZiBub3QgdTogY29udGludWUKICAgIGl0ZW09eyJrZXki
OnNsdWcobGFiZWxfb2YodSkpLCJsYWJlbCI6bGFiZWxfb2YodSksInVybCI6dSwicXJfYjY0Ijpx
cih1KX0KICAgIChyZWxheV91cmxzIGlmIGhvc3Rfb2YodSkuZW5kc3dpdGgoUkVMQVlfSE9TVF9T
VUZGSVgpIGVsc2UgcHJvdG9jb2xzKS5hcHBlbmQoaXRlbSkKCiMgLS0tIEh5c3RlcmlhMiAo0YHQ
uNC90YLQtdC3INC40LcgVVVJRCDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8gKyDRhdC+0YHRgtC+
0LIpIC0tLQppZiBIWTJfRU5BQkxFOgogICAgbT1yZS5zZWFyY2gocid2bGVzczovLyhbXkA/XSsp
QCcsICIgIi5qb2luKGxpbmtzKSkKICAgIHV1aWQ9bS5ncm91cCgxKSBpZiBtIGVsc2UgIiIKICAg
IGlmIHV1aWQ6CiAgICAgICAgaWYgcHJvdG9jb2xzOgogICAgICAgICAgICBkaD1ob3N0X29mKHBy
b3RvY29sc1swXVsidXJsIl0pOyBubT0oYmFzZV9sYWJlbChwcm90b2NvbHNbMF1bImxhYmVsIl0p
IG9yICJEaXJlY3QiKSsiIChIeXN0ZXJpYTIpIgogICAgICAgICAgICB1cmw9SFkyX1RFTVBMQVRF
LmZvcm1hdCh1dWlkPXV1aWQsaG9zdD1kaCxuYW1lPXF1b3RlKG5tLHNhZmU9IigpIikpCiAgICAg
ICAgICAgIHByb3RvY29scy5hcHBlbmQoeyJrZXkiOnNsdWcobm0pLCJsYWJlbCI6bm0sInVybCI6
dXJsLCJxcl9iNjQiOnFyKHVybCl9KQogICAgICAgIGlmIHJlbGF5X3VybHM6CiAgICAgICAgICAg
IHJoPWhvc3Rfb2YocmVsYXlfdXJsc1swXVsidXJsIl0pOyBubT0oYmFzZV9sYWJlbChyZWxheV91
cmxzWzBdWyJsYWJlbCJdKSBvciBSRUxBWV9OQU1FKSsiIChIeXN0ZXJpYTIpIgogICAgICAgICAg
ICB1cmw9SFkyX1RFTVBMQVRFLmZvcm1hdCh1dWlkPXV1aWQsaG9zdD1yaCxuYW1lPXF1b3RlKG5t
LHNhZmU9IigpIikpCiAgICAgICAgICAgIHJlbGF5X3VybHMuYXBwZW5kKHsia2V5IjpzbHVnKG5t
KSwibGFiZWwiOm5tLCJ1cmwiOnVybCwicXJfYjY0Ijpxcih1cmwpfSkKCmZvciBpLHAgaW4gZW51
bWVyYXRlKHByb3RvY29scyk6IHBbInJlY29tbWVuZGVkIl09KGk9PTApCnJlbGF5cz1beyJpcCI6
IiIsIm5hbWUiOlJFTEFZX05BTUUsInVybHMiOnJlbGF5X3VybHN9XSBpZiByZWxheV91cmxzIGVs
c2UgW10KCmNmZz17InZlcnNpb24iOjEsImNsaWVudF9uYW1lIjpjbGllbnQgb3IgIiIsInNlcnZl
cl9pcCI6IiIsImRvbWFpbiI6IiIsCiAgICAgInByb3RvY29scyI6cHJvdG9jb2xzLCJyZWxheXMi
OnJlbGF5cywiYXBwcyI6YXBwcywKICAgICAic2VydmVyX25hbWUiOlNFUlZFUl9OQU1FLCJzZXJ2
ZXJfaWNvbiI6U0VSVkVSX0lDT04sImNvbG9yIjpDT0xPUn0KaWYgc3ViX3VybDoKICAgIGNmZ1si
c3Vic2NyaXB0aW9uX3VybCJdPXN1Yl91cmw7IGNmZ1sic3Vic2NyaXB0aW9uX3FyX2I2NCJdPXFy
KHN1Yl91cmwpCnByaW50KGpzb24uZHVtcHMoY2ZnLGVuc3VyZV9hc2NpaT1GYWxzZSxpbmRlbnQ9
MikpCg==
__B64__
  base64 -d > "$d/handoff-moonlight.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGhhbmRvZmYtbW9v
bmxpZ2h0LnNoICDigJQgIEBARVhJVF9OQU1FQEAgINCk0JDQl9CQIDMKIyAg0KPQstC+0LTQuNGC
IENhZGR5INGBIDQ0MyDQvdCwIDg0NDMsINC+0YLQtNCw0ZHRgiA0NDMg0L3QvtC00LUgKFhyYXkg
UmVhbGl0eSksINC/0YDQvtCy0LXRgNGP0LXRgiDQv9Cw0L3QtdC70YwuCiMgINCV0KHQm9CYINC/
0LDQvdC10LvRjCDQvdC1INC+0YLQstC10YLQuNC70LAg4oCUINCh0JDQnCDQstC+0LfQstGA0LDR
idCw0LXRgiBDYWRkeSDQvdCwIDQ0MyAo0L/QsNC90LXQu9GMINC90LUg0L/RgNC+0L/QsNC00ZHR
gikuCiMgINCX0LDQv9GD0YHQujogIHN1ZG8gYmFzaCBoYW5kb2ZmLW1vb25saWdodC5zaAojID09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09CkRPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpXU19QQVRIPSIvd3Nu
ZyIKWEhUVFBfUEFUSD0iL3hoIgpTVUJfUEFUSD0iL3N1YiIKY2QgL29wdC9AQFNMVUdAQC9jYWRk
eSB8fCB7IGVjaG8gItCd0LXRgiAvb3B0L0BAU0xVR0BAL2NhZGR5IjsgZXhpdCAxOyB9CgojINC4
0LTQtdC80L/QvtGC0LXQvdGC0L3QvtGB0YLRjDog0LXRgdC70LggNDQzINGD0LbQtSDQtNC10YDQ
ttC40YIg0L3QvtC00LAgKHJ3LWNvcmUveHJheSksIGhhbmRvZmYg0YPQttC1INGB0LTQtdC70LDQ
vSDigJQg0LLRi9GF0L7QtNC40LwKaWYgc3MgLXRsbnAgMj4vZGV2L251bGwgfCBncmVwICc6NDQz
ICcgfCBncmVwIC1xaUUgJ3J3LWNvcmV8eHJheSc7IHRoZW4KICBlY2hvICI9PT4gNDQzINGD0LbQ
tSDQt9CwIFhyYXkg0L3QvtC00YssIENhZGR5INC90LAg0YTQvtC70LHRjdC60LUg4oCUIGhhbmRv
ZmYg0YPQttC1INCy0YvQv9C+0LvQvdC10L0sINC/0YDQvtC/0YPRgdC60LDRji4iCiAgZXhpdCAw
CmZpCgojINCa0KDQmNCi0JjQp9Cd0J46IHRhaWxzY2FsZSBzZXJ2ZSDQvNC+0LMg0LfQsNC90Y/R
gtGMIDo0NDMg0L3QsCB0YWlsbmV0LdC40L3RgtC10YDRhNC10LnRgdC1IOKAlCDRgtC+0LPQtNCw
IFhyYXkKIyDQvdC1INGB0LzQvtC20LXRgiDRgdC00LXQu9Cw0YLRjCBiaW5kIDAuMC4wLjA6NDQz
LiDQodC90LjQvNCw0LXQvCBzZXJ2ZSDRgSA0NDMg0Lgg0L/QtdGA0LXQvdC+0YHQuNC8INC90LAg
ODQ0NC4KaWYgY29tbWFuZCAtdiB0YWlsc2NhbGUgPi9kZXYvbnVsbCAyPiYxICYmIHNzIC10bG5w
IDI+L2Rldi9udWxsIHwgZ3JlcCAnOjQ0MyAnIHwgZ3JlcCAtcWkgdGFpbHNjYWxlOyB0aGVuCiAg
ZWNobyAiPT0+IHRhaWxzY2FsZSBzZXJ2ZSDQtNC10YDQttC40YIgOjQ0MyDigJQg0L/QtdGA0LXQ
vdC+0YjRgyDQvdCwIDo4NDQ0LCDRh9GC0L7QsdGLINC+0YHQstC+0LHQvtC00LjRgtGMIDQ0MyDQ
tNC70Y8gWHJheeKApiIKICB0YWlsc2NhbGUgc2VydmUgLS1odHRwcz00NDMgb2ZmIDI+L2Rldi9u
dWxsIHx8IHRhaWxzY2FsZSBzZXJ2ZSByZXNldCAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgc2xlZXAg
MQogIHRhaWxzY2FsZSBzZXJ2ZSAtLWJnIC0taHR0cHM9ODQ0NCAiaHR0cDovLzEyNy4wLjAuMTo4
MDgyIiAyPi9kZXYvbnVsbCB8fCB0cnVlCmZpCgplY2hvICI9PT4g0J/QtdGA0LXQstC+0LbRgyBD
YWRkeSDQvdCwIDg0NDMgKNGE0L7Qu9Cx0Y3QuiDQtNC70Y8gUmVhbGl0eSkuLi4iCmNhdCA+IENh
ZGR5ZmlsZSA8PEVPRgoke0RPTUFJTn06ODQ0MyB7CiAgICBoYW5kbGVfcGF0aCAke1NVQl9QQVRI
fS8qIHsKICAgICAgICByZXZlcnNlX3Byb3h5IDEyNy4wLjAuMTozMDEwCiAgICB9CiAgICBAd3Mg
cGF0aCAke1dTX1BBVEh9ICR7V1NfUEFUSH0vKgogICAgaGFuZGxlIEB3cyB7CiAgICAgICAgcmV2
ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1MwogICAgfQogICAgQHhoIHBhdGggJHtYSFRUUF9QQVRI
fSAke1hIVFRQX1BBVEh9LyoKICAgIGhhbmRsZSBAeGggewogICAgICAgIHJldmVyc2VfcHJveHkg
MTI3LjAuMC4xOjIwNTQKICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAx
MjcuMC4wLjE6MzAwMAogICAgfQp9CkVPRgpkb2NrZXIgY29tcG9zZSByZXN0YXJ0CgplY2hvICI9
PT4g0J/QtdGA0LXQt9Cw0L/Rg9GB0LrQsNGOINC90L7QtNGDLCDRh9GC0L7QsdGLIFhyYXkg0LfQ
sNC90Y/QuyDQvtGB0LLQvtCx0L7QtNC40LLRiNC40LnRgdGPIDQ0My4uLiIKZG9ja2VyIHJlc3Rh
cnQgcmVtbmFub2RlID4vZGV2L251bGwgMj4mMSB8fCB0cnVlCgplY2hvICI9PT4g0J/RgNC+0LLQ
tdGA0Y/Rjiwg0L7RgtCy0LXRh9Cw0LXRgiDQu9C4INC/0LDQvdC10LvRjCDRh9C10YDQtdC3INC9
0L7QtNGDICjQtNC+IDYg0L/QvtC/0YvRgtC+0LopLi4uIgpDT0RFPTAwMApmb3IgaSBpbiAxIDIg
MyA0IDUgNjsgZG8KICBzbGVlcCA1CiAgQ09ERT0kKGN1cmwgLXMgLW8gL2Rldi9udWxsIC13ICIl
e2h0dHBfY29kZX0iIC0tbWF4LXRpbWUgNiAiaHR0cHM6Ly8ke0RPTUFJTn0vIiB8fCBlY2hvICIw
MDAiKQogIGVjaG8gIiAg0L/QvtC/0YvRgtC60LAgJGk6IEhUVFAgJENPREUiCiAgY2FzZSAiJENP
REUiIGluIDIwMHwzMDF8MzAyfDMwN3wzMDgpIGJyZWFrOzsgZXNhYwpkb25lCgpjYXNlICIkQ09E
RSIgaW4KICAyMDB8MzAxfDMwMnwzMDd8MzA4KQogICAgZWNobyAiPT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0iCiAgICBlY2hvICIg0KPQodCf0JXQpTog
0L/QsNC90LXQu9GMINGA0LDQsdC+0YLQsNC10YIg0YfQtdGA0LXQtyDQvdC+0LTRgyAoSFRUUCAk
Q09ERSkuIgogICAgZWNobyAiIDQ0MyDRgtC10L/QtdGA0Ywg0LfQsCBYcmF5OiIKICAgIHNzIC10
bG5wIHwgZ3JlcCAnOjQ0MyAnIHx8IHRydWUKICAgIGVjaG8gIj09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IgogICAgOzsKICAqKQogICAgZWNobyAi0J/Q
sNC90LXQu9GMINC90LUg0L7RgtCy0LXRgtC40LvQsCAo0LrQvtC0ICRDT0RFKSDigJQg0J7QotCa
0JDQojog0LLQvtC30LLRgNCw0YnQsNGOIENhZGR5INC90LAgNDQzLiIKICAgIGNhdCA+IENhZGR5
ZmlsZSA8PEVPRgoke0RPTUFJTn0gewogICAgaGFuZGxlX3BhdGggJHtTVUJfUEFUSH0vKiB7CiAg
ICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MzAxMAogICAgfQogICAgaGFuZGxlIHsKICAg
ICAgICByZXZlcnNlX3Byb3h5IDEyNy4wLjAuMTozMDAwCiAgICB9Cn0KRU9GCiAgICBkb2NrZXIg
Y29tcG9zZSByZXN0YXJ0CiAgICBlY2hvICLQntGC0LrQsNGCINGB0LTQtdC70LDQvTog0L/QsNC9
0LXQu9GMINGB0L3QvtCy0LAg0LTQvtGB0YLRg9C/0L3QsCDQvdCwIGh0dHBzOi8vJHtET01BSU59
LyIKICAgIGVjaG8gIi0tLSDQu9C+0LPQuCDQvdC+0LTRiyDQtNC70Y8g0YDQsNC30LHQvtGA0LAg
KNC/0YDQuNGI0LvQuCDQuNGFINC80L3QtSkgLS0tIgogICAgZG9ja2VyIGxvZ3MgcmVtbmFub2Rl
IC0tdGFpbCAyNQogICAgOzsKZXNhYwo=
__B64__
  base64 -d > "$d/health-check.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGhlYWx0aC1jaGVj
ay5zaCDigJQg0YHQvtGB0YLQvtGP0L3QuNC1INGD0LfQu9CwIEBAQlJBTkRAQCAoQEBFWElUX05B
TUVAQCDQuNC70LggQEBSRUxBWV9OQU1FQEApCiMgINCa0LvQsNC00ZHRiNGMINC90LAg0YHQtdGA
0LLQtdGALCDQt9Cw0L/Rg9GB0LrQsNC10YjRjCDQu9C+0LrQsNC70YzQvdC+OiBiYXNoIGhlYWx0
aC1jaGVjay5zaAojICDQodCw0Lwg0L7Qv9GA0LXQtNC10LvRj9C10YIg0YDQvtC70YwuINCf0YDQ
vtCy0LXRgNGP0LXRgiDRgdC40YHRgtC10LzRgywgRG9ja2VyLCDQv9C+0YDRgtGLLCBUTFMsINC0
0LXQutC+0LksINC/0LDQvdC10LvRjCwKIyAgV0RUVCwg0LggKNC00LvRjyBAQFJFTEFZX05BTUVA
QCkg0LTQvtGB0YLQuNC20LjQvNC+0YHRgtGMIEBARVhJVF9OQU1FQEAg0LTQu9GPINC60LDRgdC6
0LDQtNCwLgojICBFeGl0OiAwIOKAlCDQsdC10Lcg0L/QsNC00LXQvdC40LkgKHdhcm4g0LTQvtC/
0YPRgdGC0LjQvNGLKSwgMyDigJQg0LXRgdGC0YwgRkFJTC4KIyAg0JrQvtC90YTQuNCzINC/0LXR
gNC10L7Qv9GA0LXQtNC10LvRj9C10YLRgdGPINGH0LXRgNC10LcgZW52LCDRgdC8LiDQsdC70L7Q
uiDQvdC40LbQtS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLXVvIHBpcGVmYWlsICAgIyDQ
ndCVIC1lOiDQvNGLINGB0YfQuNGC0LDQtdC8INGE0LXQudC70YssINCwINC90LUg0L/QsNC00LDQ
tdC8INC90LAg0L/QtdGA0LLQvtC8CgojIC0tLS0g0LrQvtC90YTQuNCzICjQv9C10YDQtdC+0L/R
gNC10LTQtdC70Y/QtdC80L4g0YfQtdGA0LXQtyBlbnYpIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLQo6ICIke0RPTUFJTjo9QEBNQUlOX0RPTUFJTkBAfSIKOiAiJHtNT09OX0lQ
Oj1AQEVYSVRfSVBAQH0iCjogIiR7UEFORUxfUE9SVDo9MzAwMH0iCjogIiR7REVDT1lfUE9SVDo9
ODA4MH0iCjogIiR7U1VCX1VSTDo9fSIgICAgICAgICAgICAjINC+0L/Rhi46INC/0L7Qu9C90YvQ
uSBVUkwg0L/QvtC00L/QuNGB0LrQuCDQtNC70Y8g0L/RgNC+0LLQtdGA0LrQuCAoMjAwICsg0L3Q
tdC/0YPRgdGC0L4pCjogIiR7VExTX1dBUk5fREFZUzo9MjF9Igo6ICIke1RMU19GQUlMX0RBWVM6
PTd9Igo6ICIke0RJU0tfV0FSTjo9ODV9IiAgICAgICAgIyAlINC30LDQvdGP0YLQvtGB0YLQuCDQ
tNC40YHQutCwINC00LvRjyBXQVJOCjogIiR7Uk9MRTo9fSIgICAgICAgICAgICAgICMgYXV0byB8
IG1vb25saWdodCB8IHN1bnNoaW5lClNMVUc9IiR7U0xVRzotQEBTTFVHQEB9IiAgICMg0LTQu9GP
INC/0YPRgtC10LkgL29wdC8kU0xVRy8uLi4KCiMgLS0tLSDRhtCy0LXRgtCwIC8g0YHRh9GR0YLR
h9C40LrQuCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tCmlmIFsgLXQgMSBdOyB0aGVuIFI9JCdcZVszMW0nOyBHPSQnXGVbMzJtJzsgWT0kJ1xl
WzMzbSc7IEI9JCdcZVsxbSc7IEM9JCdcZVszNm0nOyBYPSQnXGVbMG0nCmVsc2UgUj07IEc9OyBZ
PTsgQj07IEM9OyBYPTsgZmkKUD0wOyBXPTA7IEY9MApzZWN0aW9uKCl7IHByaW50ZiAiXG4ke0J9
JHtDfT09ICVzID09JHtYfVxuIiAiJDEiOyB9CnBhc3MoKXsgUD0kKChQKzEpKTsgcHJpbnRmICIg
ICR7R33inJMke1h9ICVzXG4iICIkMSI7IH0Kd2FybigpeyBXPSQoKFcrMSkpOyBwcmludGYgIiAg
JHtZfSEke1h9ICVzXG4iICIkMSI7IH0KZmFpbCgpeyBGPSQoKEYrMSkpOyBwcmludGYgIiAgJHtS
feKclyR7WH0gJXNcbiIgIiQxIjsgfQppbmZvKCl7IHByaW50ZiAiICAgICR7Q30lcyR7WH1cbiIg
IiQxIjsgfQoKaGF2ZSgpeyBjb21tYW5kIC12ICIkMSIgPi9kZXYvbnVsbCAyPiYxOyB9CgojIC0t
LS0g0L7Qv9GA0LXQtNC10LvQtdC90LjQtSDRgNC+0LvQuCAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmRldGVjdF9yb2xlKCl7CiAgWyAtbiAi
JFJPTEUiIF0gJiYgWyAiJFJPTEUiICE9IGF1dG8gXSAmJiB7IGVjaG8gIiRST0xFIjsgcmV0dXJu
OyB9CiAgaWYgc3MgLWx0bkggMj4vZGV2L251bGwgfCBncmVwIC1xRSAiWzouXSR7UEFORUxfUE9S
VH1cYiI7IHRoZW4KICAgIGVjaG8gbW9vbmxpZ2h0CiAgZWxzZQogICAgZWNobyBzdW5zaGluZQog
IGZpCn0KUk9MRT0kKGRldGVjdF9yb2xlKQpwcmludGYgIiR7Qn3Qo9C30LXQuzogJXMgICDQtNC+
0LzQtdC9OiAlcyAgICVzJHtYfVxuIiAiJFJPTEUiICIkRE9NQUlOIiAiJChkYXRlICcrJVktJW0t
JWQgJUg6JU06JVMgJVonKSIKCiMgLS0tLSDQv9C+0YDRgiDRgdC70YPRiNCw0LXRgtGB0Y8/ICh0
Y3AvdWRwKSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KUE9S
VFNfVENQPSIiOyBQT1JUU19VRFA9IiIKbG9hZF9wb3J0cygpewogIFBPUlRTX1RDUD0kKHNzIC1s
dG5IIDI+L2Rldi9udWxsIHwgYXdrICd7cHJpbnQgJDR9JyB8IHNlZCAtRSAncy8uKls6Ll0oWzAt
OV0rKSQvXDEvJyB8IHNvcnQgLXVuIHwgdHIgJ1xuJyAnICcpCiAgUE9SVFNfVURQPSQoc3MgLWx1
bkggMj4vZGV2L251bGwgfCBhd2sgJ3twcmludCAkNH0nIHwgc2VkIC1FICdzLy4qWzouXShbMC05
XSspJC9cMS8nIHwgc29ydCAtdW4gfCB0ciAnXG4nICcgJykKfQpsaXN0ZW5zKCl7ICMgJDEgcHJv
dG8odGNwL3VkcCkgJDIgcG9ydAogIGxvY2FsIGxpc3Q7IFsgIiQxIiA9IHVkcCBdICYmIGxpc3Q9
JFBPUlRTX1VEUCB8fCBsaXN0PSRQT1JUU19UQ1AKICBjYXNlICIgJGxpc3QgIiBpbiAqIiAkMiAi
KikgcmV0dXJuIDA7OyAqKSByZXR1cm4gMTs7IGVzYWMKfQpwb3J0X2NoZWNrKCl7ICMgJDEgcHJv
dG8gJDIgcG9ydCAkMyDQvtC/0LjRgdCw0L3QuNC1CiAgaWYgbGlzdGVucyAiJDEiICIkMiI7IHRo
ZW4gcGFzcyAiJDEvJDIg0YHQu9GD0YjQsNC10YLRgdGPICgkMykiOyBlbHNlIGZhaWwgIiQxLyQy
INCd0JUg0YHQu9GD0YjQsNC10YLRgdGPICgkMykiOyBmaQp9CgojIC0tLS0gMS4g0YHQuNGB0YLQ
tdC80LAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLQpjaGVja19zeXN0ZW0oKXsKICBzZWN0aW9uICLQodC40YHRgtC10LzQsCIKICBp
bmZvICJ1cHRpbWU6JCh1cHRpbWUgLXAgMj4vZGV2L251bGwgfCBzZWQgJ3MvdXAgLy8nKSDCtyBs
b2FkOiQoYXdrICd7cHJpbnQgJDEsJDIsJDN9JyAvcHJvYy9sb2FkYXZnKSIKICAjINC00LjRgdC6
CiAgbG9jYWwgdXNlZDsgdXNlZD0kKGRmIC1QIC8gfCBhd2sgJ05SPT0ye2dzdWIoIiUiLCIiLCQ1
KTtwcmludCAkNX0nKQogIGlmIFsgIiR7dXNlZDotMH0iIC1nZSAiJERJU0tfV0FSTiIgXTsgdGhl
biB3YXJuICLQtNC40YHQuiAvINC30LDQvdGP0YIgJHt1c2VkfSUgKNC/0L7RgNC+0LMgJHtESVNL
X1dBUk59JSkiCiAgZWxzZSBwYXNzICLQtNC40YHQuiAvINC30LDQvdGP0YIgJHt1c2VkfSUiOyBm
aQogICMg0L/QsNC80Y/RgtGMCiAgaWYgaGF2ZSBmcmVlOyB0aGVuCiAgICBsb2NhbCBtZW1saW5l
OyBtZW1saW5lPSQoZnJlZSAtbSB8IGF3ayAnL15NZW06L3twcmludGYgIiVkLyVkINCc0JEgKNGB
0LLQvtCx0L7QtNC90L4gJWQpIiwkMywkMiwkN30nKQogICAgaW5mbyAi0L/QsNC80Y/RgtGMOiAk
bWVtbGluZSIKICBmaQp9CgojIC0tLS0gMi4gZG9ja2VyIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmNoZWNrX2RvY2tlcigpewog
IHNlY3Rpb24gIkRvY2tlciIKICBpZiAhIGhhdmUgZG9ja2VyOyB0aGVuIHdhcm4gImRvY2tlciDQ
vdC1INC90LDQudC00LXQvSDigJQg0L/RgNC+0L/Rg9GB0LrQsNGOIjsgcmV0dXJuOyBmaQogIGlm
ICEgZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAyPiYxOyB0aGVuIGZhaWwgImRvY2tlciBkYWVtb24g
0L3QtSDQvtGC0LLQtdGH0LDQtdGCIjsgcmV0dXJuOyBmaQogIHBhc3MgImRvY2tlciBkYWVtb24g
0L7RgtCy0LXRh9Cw0LXRgiIKICBsb2NhbCBhbnk9MAogIHdoaWxlIElGUz0nOycgcmVhZCAtciBu
YW1lIHN0YXR1czsgZG8KICAgIFsgLXogIiRuYW1lIiBdICYmIGNvbnRpbnVlCiAgICBhbnk9MQog
ICAgY2FzZSAiJHN0YXR1cyIgaW4KICAgICAgKlJlc3RhcnRpbmcqKSBmYWlsICLQutC+0L3RgtC1
0LnQvdC10YAgJG5hbWU6ICRzdGF0dXMiIDs7CiAgICAgICp1bmhlYWx0aHkqKSAgZmFpbCAi0LrQ
vtC90YLQtdC50L3QtdGAICRuYW1lOiAkc3RhdHVzIiA7OwogICAgICAqRXhpdGVkKnwqRGVhZCop
IHdhcm4gItC60L7QvdGC0LXQudC90LXRgCAkbmFtZTogJHN0YXR1cyIgOzsKICAgICAgKmhlYWx0
aHkqKSAgICBwYXNzICLQutC+0L3RgtC10LnQvdC10YAgJG5hbWU6IGhlYWx0aHkiIDs7CiAgICAg
IFVwKikgICAgICAgICAgcGFzcyAi0LrQvtC90YLQtdC50L3QtdGAICRuYW1lOiB1cCIgOzsKICAg
ICAgKikgICAgICAgICAgICB3YXJuICLQutC+0L3RgtC10LnQvdC10YAgJG5hbWU6ICRzdGF0dXMi
IDs7CiAgICBlc2FjCiAgZG9uZSA8IDwoZG9ja2VyIHBzIC1hIC0tZm9ybWF0ICd7ey5OYW1lc319
O3t7LlN0YXR1c319JyAyPi9kZXYvbnVsbCkKICBbICIkYW55IiA9IDAgXSAmJiB3YXJuICLQutC+
0L3RgtC10LnQvdC10YDQvtCyINC90LUg0L3QsNC50LTQtdC90L4iCn0KCiMgLS0tLSAzLiDQv9C+
0YDRgtGLIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLQpjaGVja19wb3J0cygpewogIHNlY3Rpb24gItCf0L7RgNGC0YsiCiAgbG9h
ZF9wb3J0cwogIHBvcnRfY2hlY2sgdGNwIDQ0MyAgIlJlYWxpdHkvV1NTL1hIVFRQIChYcmF5KSIK
ICAjIEh5c3RlcmlhMiDQtNC10YDQttC40YIgVURQLzQ0MyDRh9C10YDQtdC3IHJhdyBzb2NrZXQg
0LLQvdGD0YLRgNC4IERvY2tlciDigJQgc3Mg0LXQs9C+INC90LUg0LLQuNC00LjRgi4KICAjINCf
0YDQvtCy0LXRgNGP0LXQvCDRh9C10YDQtdC3IG5jIC11eiAoMSDQv9Cw0LrQtdGCLCDRgtCw0LnQ
vNCw0YPRgiAx0YEpINC40LvQuCDRh9C10YDQtdC3INGE0LDQutGCINGH0YLQviDQvdC+0LTQsCBV
cCArIGNlcnQg0L/RgNC40LzQvtC90YLQuNGA0L7QstCw0L0uCiAgaWYgbmMgLXV6IC13MSAxMjcu
MC4wLjEgNDQzIDI+L2Rldi9udWxsOyB0aGVuCiAgICBwYXNzICJ1ZHAvNDQzINGB0LvRg9GI0LDQ
tdGC0YHRjyAoSHlzdGVyaWEyKSIKICBlbGlmIGRvY2tlciBpbnNwZWN0IHJlbW5hbm9kZSAtLWZv
cm1hdCAne3suU3RhdGUuUnVubmluZ319JyAyPi9kZXYvbnVsbCB8IGdyZXAgLXEgdHJ1ZSBcCiAg
ICAgICAmJiBbIC1mICIvb3B0LyRTTFVHL25vZGUvY2VydHMvaHkyLmNydCIgXTsgdGhlbgogICAg
cGFzcyAidWRwLzQ0MyBIeXN0ZXJpYTI6INC90L7QtNCwIFVwICsg0YHQtdGA0YLQuNGE0LjQutCw
0YIg0L3QsCDQvNC10YHRgtC1IChyYXcgc29ja2V0LCBzcyDQvdC1INCy0LjQtNC40YIg4oCUINC9
0L7RgNC80LApIgogIGVsc2UKICAgIGZhaWwgInVkcC80NDMg0J3QlSDRgdC70YPRiNCw0LXRgtGB
0Y8gKEh5c3RlcmlhMikg4oCUINC90L7QtNCwINC90LUg0LfQsNC/0YPRidC10L3QsCDQuNC70Lgg
0YHQtdGA0YLQuNGE0LjQutCw0YIg0L7RgtGB0YPRgtGB0YLQstGD0LXRgiIKICBmaQogIGlmIFtb
ICIkUk9MRSIgPT0gKm1vb25saWdodCogXV0gfHwgW1sgIiRST0xFIiA9PSAqZXhpdCogXV07IHRo
ZW4KICAgIHBvcnRfY2hlY2sgdGNwIDg0NDMgICJDYWRkeSBmYWxsYmFjayAoUmVhbGl0eSBkZXN0
KSIKICAgIGlmIGxpc3RlbnMgdGNwICIkUEFORUxfUE9SVCIgfHwgbGlzdGVucyB0Y3AgODA4MTsg
dGhlbiBwYXNzICJ0Y3AvJFBBTkVMX1BPUlQg0LjQu9C4IDgwODEgKNC/0LDQvdC10LvRjCwg0LvQ
vtC60LDQu9GM0L3QvikiOyBlbHNlIHdhcm4gInRjcC8kUEFORUxfUE9SVCDQv9Cw0L3QtdC70Ywg
0L3QtSDRgdC70YPRiNCw0LXRgiI7IGZpCiAgICBpZiBsaXN0ZW5zIHRjcCAiJERFQ09ZX1BPUlQi
OyB0aGVuIHBhc3MgInRjcC8kREVDT1lfUE9SVCAo0LTQtdC60L7QuSkiOyBlbHNlIGZhaWwgInRj
cC8kREVDT1lfUE9SVCDQtNC10LrQvtC5INC90LUg0YHQu9GD0YjQsNC10YIiOyBmaQogICAgbGlz
dGVucyB1ZHAgNTYwMDAgJiYgcGFzcyAidWRwLzU2MDAwIChXRFRUIERUTFMpIiB8fCB3YXJuICJ1
ZHAvNTYwMDAgV0RUVCBEVExTINC90LUg0YHQu9GD0YjQsNC10YIiCiAgICBsaXN0ZW5zIHVkcCA1
NjAwMSAmJiBwYXNzICJ1ZHAvNTYwMDEgKFdEVFQgV0cpIiAgIHx8IHdhcm4gInVkcC81NjAwMSBX
RFRUIFdHINC90LUg0YHQu9GD0YjQsNC10YIiCiAgZmkKfQoKIyAtLS0tIDQuIFRMUy3RgdC10YDR
gtC40YTQuNC60LDRgiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0KY2hlY2tfdGxzKCl7CiAgc2VjdGlvbiAiVExTICgkRE9NQUlOOjQ0MykiCiAg
aWYgISBoYXZlIG9wZW5zc2w7IHRoZW4gd2FybiAib3BlbnNzbCDQvdC10YIg4oCUINC/0YDQvtC/
0YPRgdC60LDRjiI7IHJldHVybjsgZmkKICBsb2NhbCBlbmQgdHMgbm93IGRheXMgY3J0PSIiCiAg
IyBSZWFsaXR5INC90LAgOjQ0MyDQtNGA0L7Qv9Cw0LXRgiDQvtCx0YvRh9C90YvQuSBUTFMt0YXQ
tdC90LTRiNC10LnQuiDigJQg0YHQvdCw0YfQsNC70LAg0LjRidC10Lwg0YHQtdGA0YIg0LIg0YLQ
vtC80LUgQ2FkZHkKICBjcnQ9JChkb2NrZXIgcnVuIC0tcm0gLXYgY2FkZHlfY2FkZHlfZGF0YTov
Y2Q6cm8gYWxwaW5lIFwKICAgIHNoIC1jICJjYXQgL2NkL2NhZGR5L2NlcnRpZmljYXRlcy9hY21l
LXYwMi5hcGkubGV0c2VuY3J5cHQub3JnLWRpcmVjdG9yeS8kRE9NQUlOLyRET01BSU4uY3J0IDI+
L2Rldi9udWxsIiBcCiAgICAyPi9kZXYvbnVsbCB8fCB0cnVlKQogICMg0YTQvtC70LHRjdC6OiBo
eTIuY3J0ICjRgtC+0YIg0LbQtSDRgdC10YDRgiwg0YHQutC+0L/QuNGA0L7QstCw0L3QvdGL0Lkg
0LTQu9GPIEh5c3RlcmlhMikKICBbIC16ICIkY3J0IiBdICYmIFsgLWYgIi9vcHQvJFNMVUcvbm9k
ZS9jZXJ0cy9oeTIuY3J0IiBdICYmIGNydD0iJChjYXQgL29wdC8kU0xVRy9ub2RlL2NlcnRzL2h5
Mi5jcnQpIgogIGlmIFsgLW4gIiRjcnQiIF07IHRoZW4KICAgIGVuZD0kKGVjaG8gIiRjcnQiIHwg
b3BlbnNzbCB4NTA5IC1ub291dCAtZW5kZGF0ZSAyPi9kZXYvbnVsbCB8IGN1dCAtZD0gLWYyKQog
IGVsc2UKICAgICMg0L/QvtGB0LvQtdC00L3QuNC5INGE0L7Qu9Cx0Y3Qujog0L/RgNGP0LzQvtC5
IFRMUyAo0YDQsNCx0L7RgtCw0LXRgiDQtdGB0LvQuCDQvdCwIDQ0MyDQvdC1IFJlYWxpdHkpCiAg
ICBlbmQ9JChlY2hvIHwgdGltZW91dCA4IG9wZW5zc2wgc19jbGllbnQgLWNvbm5lY3QgIiRET01B
SU46NDQzIiAtc2VydmVybmFtZSAiJERPTUFJTiIgMj4vZGV2L251bGwgXAogICAgICAgICAgfCBv
cGVuc3NsIHg1MDkgLW5vb3V0IC1lbmRkYXRlIDI+L2Rldi9udWxsIHwgY3V0IC1kPSAtZjIpCiAg
ZmkKICBpZiBbIC16ICIkZW5kIiBdOyB0aGVuIGZhaWwgItC90LUg0YPQtNCw0LvQvtGB0Ywg0L/Q
vtC70YPRh9C40YLRjCDRgdC10YDRgtC40YTQuNC60LDRgiDRgSAkRE9NQUlOOjQ0MyI7IHJldHVy
bjsgZmkKICB0cz0kKGRhdGUgLWQgIiRlbmQiICslcyAyPi9kZXYvbnVsbCk7IG5vdz0kKGRhdGUg
KyVzKQogIGlmIFsgLXogIiR0cyIgXTsgdGhlbiB3YXJuICLRgdC10YDRgtC40YTQuNC60LDRgiDQ
tdGB0YLRjCwg0L3QviDQtNCw0YLRgyDQvdC1INGA0LDQt9C+0LHRgNCw0YLRjCAoJGVuZCkiOyBy
ZXR1cm47IGZpCiAgZGF5cz0kKCggKHRzIC0gbm93KSAvIDg2NDAwICkpCiAgaWYgICBbICIkZGF5
cyIgLWx0ICIkVExTX0ZBSUxfREFZUyIgXTsgdGhlbiBmYWlsICLRgdC10YDRgtC40YTQuNC60LDR
giDQuNGB0YLQtdC60LDQtdGCINGH0LXRgNC10LcgJHtkYXlzfSDQtNC9LiAoJGVuZCkiCiAgZWxp
ZiBbICIkZGF5cyIgLWx0ICIkVExTX1dBUk5fREFZUyIgXTsgdGhlbiB3YXJuICLRgdC10YDRgtC4
0YTQuNC60LDRgiDQuNGB0YLQtdC60LDQtdGCINGH0LXRgNC10LcgJHtkYXlzfSDQtNC9LiAoJGVu
ZCkiCiAgZWxzZSBwYXNzICLRgdC10YDRgtC40YTQuNC60LDRgiDQstCw0LvQuNC00LXQvSwg0LXR
idGRICR7ZGF5c30g0LTQvS4gKCRlbmQpIjsgZmkKfQoKIyAtLS0tIDUuINC00LXQutC+0LkgKyDR
gdC60LLQvtC30L3QsNGPINGG0LXQv9C+0YfQutCwIDQ0MyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0KY2hlY2tfZGVjb3koKXsKICBzZWN0aW9uICLQlNC10LrQvtC5IC8g
0YbQtdC/0L7Rh9C60LAgNDQzIgogIGxvY2FsIGNvZGUKICBjb2RlPSQoY3VybCAtcyAtbyAvZGV2
L251bGwgLXcgJyV7aHR0cF9jb2RlfScgImh0dHA6Ly8xMjcuMC4wLjE6JHtERUNPWV9QT1JUfS8i
IDI+L2Rldi9udWxsKQogIFsgIiRjb2RlIiA9IDIwMCBdICYmIHBhc3MgItC00LXQutC+0Lkg0LvQ
vtC60LDQu9GM0L3QviAxMjcuMC4wLjE6JHtERUNPWV9QT1JUfS8g4oaSIDIwMCIgfHwgZmFpbCAi
0LTQtdC60L7QuSDQu9C+0LrQsNC70YzQvdC+IOKGkiAke2NvZGU6LTAwMH0iCiAgIyDRgdC60LLQ
vtC30YwgUmVhbGl0eSBmYWxsYmFjayAtPiBDYWRkeSAtPiDQtNC10LrQvtC5ICjRgdC+INGB0YLQ
vtGA0L7QvdGLINGB0LDQvNC+0LPQviDRgdC10YDQstC10YDQsCkKICBjb2RlPSQoY3VybCAtcyAt
byAvZGV2L251bGwgLXcgJyV7aHR0cF9jb2RlfScgLS1yZXNvbHZlICIke0RPTUFJTn06NDQzOjEy
Ny4wLjAuMSIgImh0dHBzOi8vJHtET01BSU59LyIgMj4vZGV2L251bGwpCiAgWyAiJGNvZGUiID0g
MjAwIF0gJiYgcGFzcyAiaHR0cHM6Ly8ke0RPTUFJTn0vICg0NDPihpJSZWFsaXR5IGZhbGxiYWNr
4oaSQ2FkZHnihpLQtNC10LrQvtC5KSDihpIgMjAwIiBcCiAgICAgICAgICAgICAgICAgICAgIHx8
IHdhcm4gImh0dHBzOi8vJHtET01BSU59LyDihpIgJHtjb2RlOi0wMDB9ICjQv9GA0L7QstC10YDR
jCBDYWRkeS9SZWFsaXR5IGRlc3QpIgp9CgojIC0tLS0gNi4g0L/QsNC90LXQu9GMIC0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmNo
ZWNrX3BhbmVsKCl7CiAgc2VjdGlvbiAi0J/QsNC90LXQu9GMIFJlbW5hd2F2ZSIKICBsb2NhbCBj
b2RlIHVybAogIGZvciB1cmwgaW4gImh0dHA6Ly8xMjcuMC4wLjE6JHtQQU5FTF9QT1JUfS9hcGkv
YXV0aC9zdGF0dXMiICAgICAgICAgICAgICAiaHR0cHM6Ly8xMjcuMC4wLjE6ODA4MS9hcGkvYXV0
aC9zdGF0dXMiICAgICAgICAgICAgICAiaHR0cHM6Ly9sb2NhbGhvc3Q6ODA4MS9hcGkvYXV0aC9z
dGF0dXMiOyBkbwogICAgY29kZT0kKGN1cmwgLXNrIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2Nv
ZGV9JyAiJHVybCIgMj4vZGV2L251bGwpCiAgICBjYXNlICIkY29kZSIgaW4KICAgICAgMDAwfCIi
KSBjb250aW51ZSA7OwogICAgICA1KikgIGZhaWwgItC/0LDQvdC10LvRjCAkdXJsIOKGkiAke2Nv
ZGV9IjsgcmV0dXJuIDs7CiAgICAgICopICAgcGFzcyAi0L/QsNC90LXQu9GMICR1cmwg4oaSICR7
Y29kZX0iOyByZXR1cm4gOzsKICAgIGVzYWMKICBkb25lCiAgZmFpbCAi0L/QsNC90LXQu9GMINC9
0LUg0L7RgtCy0LXRh9Cw0LXRgiAo0L/RgNC+0LLQtdGA0LXQvdC+OiA6JHtQQU5FTF9QT1JUfSDQ
uCA6ODA4MSkiCn0KCiMgLS0tLSA3LiDQv9C+0LTQv9C40YHQutCwICjQvtC/0YYuKSAtLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpjaGVja19zdWIo
KXsKICBbIC16ICIkU1VCX1VSTCIgXSAmJiB7IHNlY3Rpb24gItCf0L7QtNC/0LjRgdC60LAiOyBp
bmZvICJTVUJfVVJMINC90LUg0LfQsNC00LDQvSDigJQg0L/RgNC+0L/Rg9GB0LogKNC30LDQv9GD
0YHRgtC4INGBIFNVQl9VUkw9Li4uKSI7IHJldHVybjsgfQogIHNlY3Rpb24gItCf0L7QtNC/0LjR
gdC60LAiCiAgbG9jYWwgY29kZSBsZW4KICBjb2RlPSQoY3VybCAtcyAtbyAvdG1wL19zdWIgLXcg
JyV7aHR0cF9jb2RlfScgIiRTVUJfVVJMIiAyPi9kZXYvbnVsbCk7IGxlbj0kKHdjIC1jIDwgL3Rt
cC9fc3ViIDI+L2Rldi9udWxsKQogIGlmIFsgIiRjb2RlIiA9IDIwMCBdICYmIFsgIiR7bGVuOi0w
fSIgLWd0IDUwIF07IHRoZW4gcGFzcyAi0L/QvtC00L/QuNGB0LrQsCDihpIgMjAwLCAke2xlbn0g
0LHQsNC50YIiCiAgZWxzZSBmYWlsICLQv9C+0LTQv9C40YHQutCwIOKGkiAke2NvZGU6LTAwMH0s
ICR7bGVuOi0wfSDQsdCw0LnRgiI7IGZpCiAgcm0gLWYgL3RtcC9fc3ViCn0KCiMgLS0tLSA4LiBX
RFRUIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0KY2hlY2tfd2R0dCgpewogIHNlY3Rpb24gIldEVFQiCiAgaWYgISBoYXZlIHN5
c3RlbWN0bDsgdGhlbiBpbmZvICJzeXN0ZW1jdGwg0L3QtdGCIOKAlCDQv9GA0L7Qv9GD0YHQuiI7
IHJldHVybjsgZmkKICBpZiBzeXN0ZW1jdGwgbGlzdC11bml0LWZpbGVzIDI+L2Rldi9udWxsIHwg
Z3JlcCAtcSAnXndkdHQuc2VydmljZSc7IHRoZW4KICAgIGlmIHN5c3RlbWN0bCBpcy1hY3RpdmUg
LS1xdWlldCB3ZHR0OyB0aGVuIHBhc3MgIndkdHQuc2VydmljZSBhY3RpdmUiCiAgICBlbHNlIGZh
aWwgIndkdHQuc2VydmljZSDQndCVIGFjdGl2ZSAoJChzeXN0ZW1jdGwgaXMtYWN0aXZlIHdkdHQg
Mj4vZGV2L251bGwpKSI7IGZpCiAgZWxzZSBpbmZvICJ3ZHR0LnNlcnZpY2Ug0L3QtSDRg9GB0YLQ
sNC90L7QstC70LXQvSDigJQg0L/RgNC+0L/Rg9GB0LoiOyBmaQp9CgojIC0tLS0gOS4g0LrQsNGB
0LrQsNC0IChAQFJFTEFZX05BTUVAQCAtPiBAQEVYSVRfTkFNRUBAKSAtLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tCmNoZWNrX2Nhc2NhZGUoKXsKICBzZWN0aW9uICLQmtCw0YHQ
utCw0LQg4oaSIEBARVhJVF9OQU1FQEAgKCRNT09OX0lQOjQ0MykiCiAgaWYgdGltZW91dCA1IGJh
c2ggLWMgImV4ZWMgMzw+L2Rldi90Y3AvJHtNT09OX0lQfS80NDMiIDI+L2Rldi9udWxsOyB0aGVu
CiAgICBwYXNzICJ0Y3AgJHtNT09OX0lQfTo0NDMg0LTQvtGB0YLQuNC20LjQvCAo0LrQsNGB0LrQ
sNC0INC40LzQtdC10YIg0LLRi9GF0L7QtCkiCiAgZWxzZQogICAgZmFpbCAidGNwICR7TU9PTl9J
UH06NDQzINCd0JUg0LTQvtGB0YLQuNC20LjQvCDigJQg0LrQsNGB0LrQsNC0INC+0LHQvtGA0LLQ
sNC9IgogIGZpCn0KCiMgLS0tLSDQv9GA0L7Qs9C+0L0gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KY2hlY2tfc3lzdGVtCmNo
ZWNrX2RvY2tlcgpjaGVja19wb3J0cwpjaGVja190bHMKaWYgW1sgIiRST0xFIiA9PSAqbW9vbmxp
Z2h0KiBdXSB8fCBbWyAiJFJPTEUiID09ICpleGl0KiBdXTsgdGhlbgogIGNoZWNrX2RlY295OyBj
aGVja19wYW5lbDsgY2hlY2tfc3ViOyBjaGVja193ZHR0CmVsc2UKICBjaGVja19jYXNjYWRlCmZp
CgojIC0tLS0g0LjRgtC+0LMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpwcmludGYgIlxuJHtCfdCY0YLQvtCzOiR7WH0g
JHtHfSVkIG9rJHtYfSDCtyAke1l9JWQgd2FybiR7WH0gwrcgJHtSfSVkIGZhaWwke1h9XG4iICIk
UCIgIiRXIiAiJEYiClsgIiRGIiAtZ3QgMCBdICYmIGV4aXQgMyB8fCBleGl0IDAK
__B64__
  base64 -d > "$d/kick-node.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGtpY2stbm9kZS5z
aCDigJQg0L/QuNC90LDQtdGCINC90L7QtNGDINGH0LXRgNC10Lcg0L/QsNC90LXQu9GMLCDRh9GC
0L7QsdGLINGC0LAg0LfQsNC70LjQu9CwIFhyYXkt0LrQvtC90YTQuNCzLgojICDQkNGA0LPRg9C8
0LXQvdGCOiBleGl0IChleGl0LdC90L7QtNCwLCDQtNC+IHN0ZWFsdGgpIHwgcmVsYXkgKEBAUkVM
QVlfTkFNRUBALCDRgSBNb29ubGlnaHQpCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0Kc2V0IC1ldW8g
cGlwZWZhaWwKU0xVRz0iQEBTTFVHQEAiCk1BSU5fRE9NQUlOPSJAQE1BSU5fRE9NQUlOQEAiCkNS
RURfRklMRT0iL29wdC8kU0xVRy9jcmVkZW50aWFscy50eHQiCk1PREU9IiR7MTotZXhpdH0iCgpv
aygpeyAgIGVjaG8gIiAg4pyTICQqIjsgfQp3YXJuKCl7IGVjaG8gIiAgISAkKiI7IH0KZGllKCl7
ICBlY2hvICIgIOKclyAkKiIgPiYyOyBleGl0IDE7IH0KCmp2YWwoKXsgcHl0aG9uMyAtICIkMSIg
IiQyIiA8PCdQWScgMj4vZGV2L251bGwKaW1wb3J0IHN5cyxqc29uCnRyeTogZD1qc29uLmxvYWRz
KHN5cy5hcmd2WzFdKQpleGNlcHQgRXhjZXB0aW9uOiBzeXMuZXhpdCgxKQpmb3IgayBpbiBzeXMu
YXJndlsyXS5zcGxpdCgnLicpOgogICAgaWYgaXNpbnN0YW5jZShkLGxpc3QpOgogICAgICAgIHRy
eTogZD1kW2ludChrKV0KICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBzeXMuZXhpdCgxKQogICAg
ZWxpZiBpc2luc3RhbmNlKGQsZGljdCk6IGQ9ZC5nZXQoaykKICAgIGVsc2U6IHN5cy5leGl0KDEp
CiAgICBpZiBkIGlzIE5vbmU6IHN5cy5leGl0KDEpCnByaW50KGQgaWYgbm90IGlzaW5zdGFuY2Uo
ZCwoZGljdCxsaXN0KSkgZWxzZSBqc29uLmR1bXBzKGQpKQpQWQp9CgpbIC1mICIkQ1JFRF9GSUxF
IiBdIHx8IGRpZSAi0L3QtdGCICRDUkVEX0ZJTEUiCkFETUlOX1BBU1M9IiQoZ3JlcCAtRSAnXlxz
KnBhc3M6JyAiJENSRURfRklMRSIgfCBhd2sgJ3twcmludCAkMn0nIHwgaGVhZCAtMSkiClsgLW4g
IiRBRE1JTl9QQVNTIiBdIHx8IGRpZSAi0L/QsNGA0L7Qu9GMINCw0LTQvNC40L3QsCDQvdC1INC9
0LDQudC00LXQvSDQsiAkQ1JFRF9GSUxFIgoKUkVTT0xWRV9BUkdTPSgpCkFQSV9CQVNFPSJodHRw
Oi8vMTI3LjAuMC4xOjMwMDAvYXBpIgpzdGF0dXNfb2soKXsKICBsb2NhbCBjOyBjPSIkKGN1cmwg
LXNTIC1rIC1vIC9kZXYvbnVsbCAiJHtSRVNPTFZFX0FSR1NbQF19IiAtdyAnJXtodHRwX2NvZGV9
JyAgICAgIiR7QVBJX0JBU0V9L2F1dGgvc3RhdHVzIiAyPi9kZXYvbnVsbCkiOyBbIC1uICIkYyIg
XSAmJiBbICIkYyIgLWdlIDIwMCBdIDI+L2Rldi9udWxsICYmIFsgIiRjIiAtbHQgNTAwIF0gMj4v
ZGV2L251bGwKfQphcGkoKXsKICBsb2NhbCBtZXRob2Q9IiQxIiBwYXRoPSIkMiIgYm9keT0iJHsz
Oi19IiByZXNwIGNvZGUKICBsb2NhbCBhcmdzPSgtc1MgLWsgLS1odHRwMS4xICIke1JFU09MVkVf
QVJHU1tAXX0iIC1YICIkbWV0aG9kIiAiJHtBUElfQkFTRX0ke3BhdGh9IgogICAgICAgICAgICAg
IC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIC1IICJYLVJlbW5hd2F2ZS1DbGll
bnQtVHlwZTogYnJvd3NlciIpCiAgWyAtbiAiJHtUT0tFTjotfSIgXSAmJiBhcmdzKz0oLUggIkF1
dGhvcml6YXRpb246IEJlYXJlciAkVE9LRU4iKQogIFsgLW4gIiRib2R5IiBdICYmIGFyZ3MrPSgt
ZCAiJGJvZHkiKQogIHJlc3A9IiQoY3VybCAiJHthcmdzW0BdfSIgLXcgJCdcbiV7aHR0cF9jb2Rl
fScpIiB8fCByZXR1cm4gMQogIGNvZGU9IiR7cmVzcCMjKiQnXG4nfSI7IHJlc3A9IiR7cmVzcCUk
J1xuJyp9IgogIFsgIiRjb2RlIiAtZ2UgMjAwIF0gJiYgWyAiJGNvZGUiIC1sdCAzMDAgXSB8fCBy
ZXR1cm4gMQogIHByaW50ZiAnJXMnICIkcmVzcCIKfQoKIyAtLSDQvdCw0LnRgtC4INGA0LDQsdC+
0YfQuNC5INGN0L3QtNC/0L7QuNC90YIg0L/QsNC90LXQu9C4IC0tCmlmIHN0YXR1c19vazsgdGhl
bgogIG9rICLQv9Cw0L3QtdC70Ywg0LTQvtGB0YLRg9C/0L3QsCAoMTI3LjAuMC4xOjMwMDApIgpl
bHNlCiAgQVBJX0JBU0U9Imh0dHBzOi8vbG9jYWxob3N0OjgwODEvYXBpIgogIGlmIHN0YXR1c19v
azsgdGhlbgogICAgb2sgItC/0LDQvdC10LvRjCDQtNC+0YHRgtGD0L/QvdCwIChsb2NhbGhvc3Q6
ODA4MSkiCiAgZWxpZiBbICIkTU9ERSIgPSBleGl0IF07IHRoZW4KICAgICMg0LTQviBzdGVhbHRo
INC/0LDQvdC10LvRjCDQvNC+0LbQtdGCINCx0YvRgtGMINC90LAg0L/Rg9Cx0LvQuNGH0L3QvtC8
INC00L7QvNC10L3QtQogICAgZm9yIHAgaW4gODQ0MyA0NDM7IGRvCiAgICAgIGM9IiQoY3VybCAt
c1MgLWsgLW8gL2Rldi9udWxsIC0tcmVzb2x2ZSAiJE1BSU5fRE9NQUlOOiRwOjEyNy4wLjAuMSIg
ICAgICAgICAgICAgLXcgJyV7aHR0cF9jb2RlfScgImh0dHBzOi8vJE1BSU5fRE9NQUlOOiRwL2Fw
aS9hdXRoL3N0YXR1cyIgMj4vZGV2L251bGwgfHwgdHJ1ZSkiCiAgICAgIGlmIFsgLW4gIiRjIiBd
ICYmIFsgIiRjIiAtZ2UgMjAwIF0gMj4vZGV2L251bGwgJiYgWyAiJGMiIC1sdCA1MDAgXSAyPi9k
ZXYvbnVsbDsgdGhlbgogICAgICAgIEFQSV9CQVNFPSJodHRwczovLyRNQUlOX0RPTUFJTjokcC9h
cGkiCiAgICAgICAgUkVTT0xWRV9BUkdTPSgtLXJlc29sdmUgIiRNQUlOX0RPTUFJTjokcDoxMjcu
MC4wLjEiKQogICAgICAgIG9rICLQv9Cw0L3QtdC70Ywg0LTQvtGB0YLRg9C/0L3QsCAoJE1BSU5f
RE9NQUlOOiRwKSIKICAgICAgICBicmVhawogICAgICBmaQogICAgZG9uZQogICAgc3RhdHVzX29r
IHx8IHsgd2FybiAi0L/QsNC90LXQu9GMINC90LUg0L7RgtCy0LXRh9Cw0LXRgiDigJQg0L/RgNC+
0L/Rg9GB0LrQsNGOICjQvdCw0LbQvNC4IFJlc3RhcnQg0L3QsCDQvdC+0LTQtSDQsiDQv9Cw0L3Q
tdC70Lgg0LLRgNGD0YfQvdGD0Y4pIjsgZXhpdCAwOyB9CiAgZWxzZQogICAgZGllICLQv9Cw0L3Q
tdC70YwgTW9vbmxpZ2h0INC90LUg0L7RgtCy0LXRh9Cw0LXRgiIKICBmaQpmaQoKVE9LRU49IiIK
bG9naW49IiQoYXBpIFBPU1QgL2F1dGgvbG9naW4gIntcInVzZXJuYW1lXCI6XCJhZG1pblwiLFwi
cGFzc3dvcmRcIjpcIiRBRE1JTl9QQVNTXCJ9IikiICAgfHwgZGllICLQu9C+0LPQuNC9INC90LUg
0L/RgNC+0YjRkdC7IgpUT0tFTj0iJChqdmFsICIkbG9naW4iIHJlc3BvbnNlLmFjY2Vzc1Rva2Vu
KSI7IFsgLW4gIiRUT0tFTiIgXSB8fCBUT0tFTj0iJChqdmFsICIkbG9naW4iIGFjY2Vzc1Rva2Vu
KSIKWyAtbiAiJFRPS0VOIiBdIHx8IGRpZSAi0YLQvtC60LXQvSDQvdC1INC/0L7Qu9GD0YfQtdC9
IgoKIyAtLSDQvdCw0LnRgtC4IFVVSUQg0L3QvtC00YsgLS0KaWYgWyAiJE1PREUiID0gcmVsYXkg
XTsgdGhlbgogIEJPT1RTVFJBUD0iL29wdC8kU0xVRy9yZWxheS1ib290c3RyYXAuZW52IgogIFsg
LWYgIiRCT09UU1RSQVAiIF0gJiYgc291cmNlICIkQk9PVFNUUkFQIgogIE5PREVfVVVJRD0iJHtS
RUxBWV9OT0RFX1VVSUQ6LX0iCiAgaWYgWyAteiAiJE5PREVfVVVJRCIgXTsgdGhlbgogICAgTk9E
RV9VVUlEPSIkKGRvY2tlciBleGVjIC1pIHJlbW5hd2F2ZS1kYiBwc3FsIC1VIHBvc3RncmVzIC1k
IHBvc3RncmVzIC10QWMgICAgICAgIlNFTEVDVCB1dWlkIEZST00gbm9kZXMgV0hFUkUgbmFtZT0n
QEBSRUxBWV9OQU1FQEAnIExJTUlUIDE7IiAyPi9kZXYvbnVsbCB8IHRyIC1kICdbOnNwYWNlOl0n
KSIgfHwgTk9ERV9VVUlEPSIiCiAgZmkKICBbIC1uICIkTk9ERV9VVUlEIiBdIHx8IGRpZSAiVVVJ
RCDQvdC+0LTRiyBAQFJFTEFZX05BTUVAQCDQvdC1INC90LDQudC00LXQvSIKICBOT0RFX0xBQkVM
PSJAQFJFTEFZX05BTUVAQCIKZWxzZQogIE5PREVfVVVJRD0iJChhcGkgR0VUIC9ub2RlcyAyPi9k
ZXYvbnVsbCB8IHB5dGhvbjMgLWMgJ2ltcG9ydCBzeXMsanNvbgp0cnk6CiAgZD1qc29uLmxvYWQo
c3lzLnN0ZGluKTsgcj1kLmdldCgicmVzcG9uc2UiLGQpOyBhPXIgaWYgaXNpbnN0YW5jZShyLGxp
c3QpIGVsc2Ugci5nZXQoIm5vZGVzIixbXSkKICBwcmludChhWzBdWyJ1dWlkIl0gaWYgYSBlbHNl
ICIiKQpleGNlcHQgRXhjZXB0aW9uOiBwcmludCgiIiknKSIKICBbIC1uICIkTk9ERV9VVUlEIiBd
IHx8IHsgd2FybiAi0L3QvtC00LAg0L3QtSDQvdCw0LnQtNC10L3QsCDQsiDQv9Cw0L3QtdC70Lgg
4oCUINC/0YDQvtC/0YPRgdC60LDRjiI7IGV4aXQgMDsgfQogIE5PREVfTEFCRUw9ImV4aXQiCmZp
CgphcGkgUE9TVCAiL25vZGVzLyROT0RFX1VVSUQvYWN0aW9ucy9lbmFibGUiICA+L2Rldi9udWxs
IDI+JjEgfHwgdHJ1ZQphcGkgUE9TVCAiL25vZGVzLyROT0RFX1VVSUQvYWN0aW9ucy9yZXN0YXJ0
IiA+L2Rldi9udWxsIDI+JjEgICAmJiBvayAi0L/QsNC90LXQu9GMINC/0LjQvdCw0LXRgiDQvdC+
0LTRgyAkTk9ERV9MQUJFTCAoJE5PREVfVVVJRCkg4oCUINC60L7QvdGE0LjQsyDQt9Cw0LvRkdGC
0LjRgiIgICB8fCB3YXJuICLRgNC10YHRgtCw0YDRgiDQvdC1INC/0YDQvtGI0ZHQuyDRh9C10YDQ
tdC3IEFQSSDigJQg0L3QsNC20LzQuCBSZXN0YXJ0INCyINC/0LDQvdC10LvQuCDQstGA0YPRh9C9
0YPRjiIKCmVjaG8gIiAg0LbQtNGDIDE10YHigKYiOyBzbGVlcCAxNQoKaWYgWyAiJE1PREUiID0g
ZXhpdCBdOyB0aGVuCiAgaWYgc3MgLXRsbnAgMj4vZGV2L251bGwgfCBncmVwIC1xICc6NDQzJzsg
dGhlbgogICAgb2sgIlhyYXkg0L3QsCA0NDMg4oCUINC90L7QtNCwINC+0LHRgdC70YPQttC40LLQ
sNC10YIg0YLRgNCw0YTQuNC6IgogIGVsc2UKICAgIHdhcm4gIjQ0MyDQv9C+0LrQsCDQv9GD0YHR
gtC+IOKAlCDQtdGB0LvQuCDRgtCw0Log0Lgg0L7RgdGC0LDQvdC10YLRgdGPLCDQvdCw0LbQvNC4
IFJlc3RhcnQg0L3QsCDQvdC+0LTQtSDQsiDQv9Cw0L3QtdC70LgiCiAgZmkKZmkK
__B64__
  base64 -d > "$d/post-deploy-gate.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIHBvc3QtZGVwbG95
LWdhdGUuc2gg4oCUIMKr0LLQvtGA0L7RgtCwwrsg0L/QvtGB0LvQtSDQtNC10L/Qu9C+0Y86INC2
0LTQsNGC0Ywg0YEg0YDQtdGC0YDQsNGP0LzQuCwg0YfRgtC+INGB0LXRgNCy0LjRgQojICDRgNC1
0LDQu9GM0L3QviDQv9C+0LTQvdGP0LvRgdGPLCDQuCDQstC10YDQvdGD0YLRjCDQvdC10L3Rg9C7
0LXQstC+0Lkg0LrQvtC0LCDQtdGB0LvQuCDQvdC10YIuINCb0L7QstC40YIg0YDQvtCy0L3QviDR
gtC+LCDQvdCwINGH0ZHQvAojICDQvNGLINCz0L7RgNC10LvQuDog0LrQvtC90YLQtdC50L3QtdGA
INCyIFJlc3RhcnRpbmcsIEhUVFAg0L3QtSAyMDAsINC/0L7RgNGCINC90LUg0YHQu9GD0YjQsNC1
0YIuCiMKIyAg0KHQn9Ce0KHQntCRIDEg4oCUINC60LDQuiDQsdC40LHQu9C40L7RgtC10LrQsCDQ
siDQutC+0L3RhtC1INC00LXQv9C70L7QuS3RgdC60YDQuNC/0YLQsDoKIyAgICAgc291cmNlIC9y
b290L3Bvc3QtZGVwbG95LWdhdGUuc2gKIyAgICAgZ2F0ZV9jb250YWluZXIgQEBTTFVHQEAtZGVj
b3kgNDAgXAojICAgICAgICYmIGdhdGVfaHR0cCBodHRwOi8vMTI3LjAuMC4xOjgwODAvIDIwMCAz
MCBcCiMgICAgICAgJiYgZ2F0ZV9odHRwIGh0dHA6Ly8xMjcuMC4wLjE6ODA4MC9wcmljaW5nIDIw
MCAxNSBcCiMgICAgICAgfHwgeyBlY2hvICLQlNCV0J/Qm9Ce0Jkg0J3QlSDQn9Cg0J7QqNCB0Jsg
0JLQntCg0J7QotCQIjsgZXhpdCAzOyB9CiMKIyAg0KHQn9Ce0KHQntCRIDIg4oCUINC+0YLQtNC1
0LvRjNC90L7QuSDQutC+0LzQsNC90LTQvtC5OgojICAgICAuL3Bvc3QtZGVwbG95LWdhdGUuc2gg
Y29udGFpbmVyIEBAU0xVR0BALWRlY295IDQwCiMgICAgIC4vcG9zdC1kZXBsb3ktZ2F0ZS5zaCBo
dHRwIGh0dHA6Ly8xMjcuMC4wLjE6ODA4MC8gMjAwIDMwCiMgICAgIC4vcG9zdC1kZXBsb3ktZ2F0
ZS5zaCBwb3J0IHRjcCAxMjcuMC4wLjEgODQ0MyAyMAojICAgICAuL3Bvc3QtZGVwbG95LWdhdGUu
c2ggdGxzIEBATUFJTl9ET01BSU5AQCA3CiMKIyAg0JLQvtC30LLRgNCw0YI6IDAg4oCUINC/0YDQ
vtGI0LvQviwgMyDigJQg0L3QtSDQtNC+0LbQtNCw0LvQuNGB0Ywv0YPQv9Cw0LvQvi4KIyA9PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PQoKaWYgWyAtdCAxIF07IHRoZW4gX1I9JCdcZVszMW0nOyBfRz0kJ1xl
WzMybSc7IF9ZPSQnXGVbMzNtJzsgX1g9JCdcZVswbScKZWxzZSBfUj07IF9HPTsgX1k9OyBfWD07
IGZpCl9vaygpeyAgIHByaW50ZiAiICAke19HfeKckyR7X1h9ICVzXG4iICIkMSI7IH0KX2JhZCgp
eyAgcHJpbnRmICIgICR7X1J94pyXJHtfWH0gJXNcbiIgIiQxIjsgfQpfd2FpdCgpeyBwcmludGYg
IiAgJHtfWX3igKYke19YfSAlc1xuIiAiJDEiOyB9CgojIGdhdGVfcG9ydCBQUk9UTyBIT1NUIFBP
UlQgW3RpbWVvdXQ9MzBdCmdhdGVfcG9ydCgpewogIGxvY2FsIHByb3RvPSQxIGhvc3Q9JDIgcG9y
dD0kMyB0bz0kezQ6LTMwfSB0PTAKICBfd2FpdCAi0LbQtNGDICR7cHJvdG99LyR7cG9ydH0g0L3Q
sCAke2hvc3R9ICjQtNC+ICR7dG990YEp4oCmIgogIHdoaWxlIFsgIiR0IiAtbHQgIiR0byIgXTsg
ZG8KICAgIGlmIFsgIiRwcm90byIgPSB1ZHAgXTsgdGhlbgogICAgICAjINC00LvRjyB1ZHAg0L3Q
sNC00ZHQttC90L7QuSDQv9GA0L7QstC10YDQutC4IMKr0YHQu9GD0YjQsNC10YLCuyDQvdC10YI7
INGB0LzQvtGC0YDQuNC8INC70L7QutCw0LvRjNC90YvQuSBzcwogICAgICBpZiBzcyAtbHVuSCAy
Pi9kZXYvbnVsbCB8IGdyZXAgLXFFICJbOi5dJHtwb3J0fVxiIjsgdGhlbiBfb2sgInVkcC8ke3Bv
cnR9INGB0LvRg9GI0LDQtdGC0YHRjyI7IHJldHVybiAwOyBmaQogICAgZWxzZQogICAgICBpZiB0
aW1lb3V0IDMgYmFzaCAtYyAiZXhlYyAzPD4vZGV2L3RjcC8ke2hvc3R9LyR7cG9ydH0iIDI+L2Rl
di9udWxsOyB0aGVuIF9vayAidGNwLyR7cG9ydH0g0L/RgNC40L3QuNC80LDQtdGCINGB0L7QtdC0
0LjQvdC10L3QuNGPIjsgcmV0dXJuIDA7IGZpCiAgICBmaQogICAgc2xlZXAgMjsgdD0kKCh0KzIp
KQogIGRvbmUKICBfYmFkICIke3Byb3RvfS8ke3BvcnR9INC90LUg0L/QvtC00L3Rj9C70YHRjyDQ
t9CwICR7dG990YEiOyByZXR1cm4gMwp9CgojIGdhdGVfaHR0cCBVUkwgW2V4cGVjdGVkX2NvZGU9
MjAwXSBbdGltZW91dD0zMF0KZ2F0ZV9odHRwKCl7CiAgbG9jYWwgdXJsPSQxIGV4cD0kezI6LTIw
MH0gdG89JHszOi0zMH0gdD0wIGNvZGUKICBfd2FpdCAi0LbQtNGDICR7dXJsfSDihpIgJHtleHB9
ICjQtNC+ICR7dG990YEp4oCmIgogIHdoaWxlIFsgIiR0IiAtbHQgIiR0byIgXTsgZG8KICAgIGNv
ZGU9JChjdXJsIC1zIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2NvZGV9JyAtLW1heC10aW1lIDUg
IiR1cmwiIDI+L2Rldi9udWxsKQogICAgWyAiJGNvZGUiID0gIiRleHAiIF0gJiYgeyBfb2sgIiR7
dXJsfSDihpIgJHtjb2RlfSI7IHJldHVybiAwOyB9CiAgICBzbGVlcCAyOyB0PSQoKHQrMikpCiAg
ZG9uZQogIF9iYWQgIiR7dXJsfSDihpIgJHtjb2RlOi0wMDB9ICjQttC00LDQu9C4ICR7ZXhwfSki
OyByZXR1cm4gMwp9CgojIGdhdGVfY29udGFpbmVyIE5BTUUgW3RpbWVvdXQ9MzBdCiMgICBvayA9
IHJ1bm5pbmcg0Jgg0L3QtSBSZXN0YXJ0aW5nINCYIChoZWFsdGh5INCY0JvQmCDQsdC10LcgaGVh
bHRoY2hlY2spCmdhdGVfY29udGFpbmVyKCl7CiAgbG9jYWwgbmFtZT0kMSB0bz0kezI6LTMwfSB0
PTAgc3QgcnMgaGwKICBfd2FpdCAi0LbQtNGDINC60L7QvdGC0LXQudC90LXRgCAke25hbWV9ICjQ
tNC+ICR7dG990YEp4oCmIgogIHdoaWxlIFsgIiR0IiAtbHQgIiR0byIgXTsgZG8KICAgIHN0PSQo
ZG9ja2VyIGluc3BlY3QgLWYgJ3t7LlN0YXRlLlN0YXR1c319JyAiJG5hbWUiIDI+L2Rldi9udWxs
KQogICAgcnM9JChkb2NrZXIgaW5zcGVjdCAtZiAne3suU3RhdGUuUmVzdGFydGluZ319JyAiJG5h
bWUiIDI+L2Rldi9udWxsKQogICAgaGw9JChkb2NrZXIgaW5zcGVjdCAtZiAne3tpZiAuU3RhdGUu
SGVhbHRofX17ey5TdGF0ZS5IZWFsdGguU3RhdHVzfX17e2Vsc2V9fW5vbmV7e2VuZH19JyAiJG5h
bWUiIDI+L2Rldi9udWxsKQogICAgaWYgWyAiJHN0IiA9IHJ1bm5pbmcgXSAmJiBbICIkcnMiID0g
ZmFsc2UgXSAmJiB7IFsgIiRobCIgPSBoZWFsdGh5IF0gfHwgWyAiJGhsIiA9IG5vbmUgXTsgfTsg
dGhlbgogICAgICBfb2sgItC60L7QvdGC0LXQudC90LXRgCAke25hbWV9OiBydW5uaW5nJCggWyAi
JGhsIiA9IGhlYWx0aHkgXSAmJiBlY2hvICcsIGhlYWx0aHknKSI7IHJldHVybiAwCiAgICBmaQog
ICAgIyDQtdGB0LvQuCDQvtC9INGP0LLQvdC+INC60YDQsNGI0LvRg9C/0LjRgiDigJQg0L3QtSDQ
ttC00ZHQvCDQstC10YHRjCDRgtCw0LnQvNCw0YPRgiDQt9GA0Y8sINC90L4g0LTQsNC00LjQvCDQ
v9Cw0YDRgyDRhtC40LrQu9C+0LIKICAgIHNsZWVwIDI7IHQ9JCgodCsyKSkKICBkb25lCiAgX2Jh
ZCAi0LrQvtC90YLQtdC50L3QtdGAICR7bmFtZX06IHN0YXR1cz0ke3N0Oi0/fSByZXN0YXJ0aW5n
PSR7cnM6LT99IGhlYWx0aD0ke2hsOi0/fSIKICBbIC1uICIke25hbWU6LX0iIF0gJiYgZG9ja2Vy
IGxvZ3MgLS10YWlsIDE1ICIkbmFtZSIgMj4mMSB8IHNlZCAncy9eLyAgICAgIHwgLycKICByZXR1
cm4gMwp9CgojIGdhdGVfdGxzIERPTUFJTiBbbWluX2RheXM9N10KZ2F0ZV90bHMoKXsKICBsb2Nh
bCBkb21haW49JDEgbWluPSR7MjotN30gZW5kIHRzIG5vdyBkYXlzCiAgZW5kPSQoZWNobyB8IHRp
bWVvdXQgOCBvcGVuc3NsIHNfY2xpZW50IC1jb25uZWN0ICIke2RvbWFpbn06NDQzIiAtc2VydmVy
bmFtZSAiJGRvbWFpbiIgMj4vZGV2L251bGwgXAogICAgICAgIHwgb3BlbnNzbCB4NTA5IC1ub291
dCAtZW5kZGF0ZSAyPi9kZXYvbnVsbCB8IGN1dCAtZD0gLWYyKQogIFsgLXogIiRlbmQiIF0gJiYg
eyBfYmFkICIke2RvbWFpbn06INGB0LXRgNGC0LjRhNC40LrQsNGCINC90LUg0L/QvtC70YPRh9C1
0L0iOyByZXR1cm4gMzsgfQogIHRzPSQoZGF0ZSAtZCAiJGVuZCIgKyVzIDI+L2Rldi9udWxsKTsg
bm93PSQoZGF0ZSArJXMpOyBkYXlzPSQoKCAodHMgLSBub3cpIC8gODY0MDAgKSkKICBpZiBbICIk
ZGF5cyIgLWdlICIkbWluIiBdOyB0aGVuIF9vayAiJHtkb21haW59OiDRgdC10YDRgtC40YTQuNC6
0LDRgiDQtdGJ0ZEgJHtkYXlzfSDQtNC9LiI7IHJldHVybiAwCiAgZWxzZSBfYmFkICIke2RvbWFp
bn06INGB0LXRgNGC0LjRhNC40LrQsNGCINC40YHRgtC10LrQsNC10YIg0YfQtdGA0LXQtyAke2Rh
eXN9INC00L0uICjQv9C+0YDQvtCzICR7bWlufSkiOyByZXR1cm4gMzsgZmkKfQoKIyAtLS0tIHN0
YW5kYWxvbmUt0YDQtdC20LjQvDog0LXRgdC70Lgg0YHQutGA0LjQv9GCINC30LDQv9GD0YnQtdC9
INC90LDQv9GA0Y/QvNGD0Y4sINCwINC90LUg0YfQtdGA0LXQtyBzb3VyY2UgLS0tLS0tCiMgKNCy
IGJhc2g6ICR7QkFTSF9TT1VSQ0VbMF19ID09ICQwINGC0L7Qu9GM0LrQviDQv9GA0Lgg0L/RgNGP
0LzQvtC8INC30LDQv9GD0YHQutC1KQppZiBbICIke0JBU0hfU09VUkNFWzBdOi0kMH0iID0gIiQw
IiBdOyB0aGVuCiAgY21kPSR7MTotfTsgc2hpZnQgfHwgdHJ1ZQogIGNhc2UgIiRjbWQiIGluCiAg
ICBwb3J0KSAgICAgIGdhdGVfcG9ydCAiJEAiIDs7CiAgICBodHRwKSAgICAgIGdhdGVfaHR0cCAi
JEAiIDs7CiAgICBjb250YWluZXIpIGdhdGVfY29udGFpbmVyICIkQCIgOzsKICAgIHRscykgICAg
ICAgZ2F0ZV90bHMgIiRAIiA7OwogICAgKikgY2F0IDw8VVNBR0UKcG9zdC1kZXBsb3ktZ2F0ZS5z
aCDigJQg0LLQvtGA0L7RgtCwINC/0YDQvtCy0LXRgNC60Lgg0L/QvtGB0LvQtSDQtNC10L/Qu9C+
0Y8KICBwb3J0ICBQUk9UTyBIT1NUIFBPUlQgW3RpbWVvdXRdICAgICAuLyQoYmFzZW5hbWUgIiQw
IikgcG9ydCB0Y3AgMTI3LjAuMC4xIDg0NDMgMjAKICBodHRwICBVUkwgW2NvZGVdIFt0aW1lb3V0
XSAgICAgICAgICAuLyQoYmFzZW5hbWUgIiQwIikgaHR0cCBodHRwOi8vMTI3LjAuMC4xOjgwODAv
IDIwMCAzMAogIGNvbnRhaW5lciBOQU1FIFt0aW1lb3V0XSAgICAgICAgICAgIC4vJChiYXNlbmFt
ZSAiJDAiKSBjb250YWluZXIgQEBTTFVHQEAtZGVjb3kgNDAKICB0bHMgICBET01BSU4gW21pbl9k
YXlzXSAgICAgICAgICAgICAuLyQoYmFzZW5hbWUgIiQwIikgdGxzIEBATUFJTl9ET01BSU5AQCA3
CtCY0LvQuCDQsiDQtNC10L/Qu9C+0LU6ICBzb3VyY2UgJChiYXNlbmFtZSAiJDAiKTsgZ2F0ZV9j
b250YWluZXIgLi4uICYmIGdhdGVfaHR0cCAuLi4gfHwgZXhpdCAzClVTQUdFCiAgICAgICBleGl0
IDIgOzsKICBlc2FjCmZpCg==
__B64__
  base64 -d > "$d/provision-relay.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHByb3Zpc2lvbi1yZWxheS5zaCDigJQgaGVhZGxlc3Mg0L3QsNGB0YLRgNC+0LnQutCwINGA0LXQu9C10Y8gQEBSRUxBWV9OQU1FQEAg0YfQtdGA0LXQtyBBUEkg0L/QsNC90LXQu9C4IEBARVhJVF9OQU1FQEAuCiMg0JfQsNC/0YPRgdC60LDQtdGC0YHRjyDQndCQIE1PT05MSUdIVC4g0KHQvtC30LTQsNGR0YI6CiMgICAtINGB0LXRgNCy0LjRgS3RjtC30LXRgNCwINC60LDRgdC60LDQtNCwIChyZWxheS11c2VyKSDihpIg0LHQtdGA0ZHRgiDQtdCz0L4gVVVJRCDQtNC70Y8gb3V0Ym91bmQKIyAgIC0gcmVsYXkgY29uZmlnLXByb2ZpbGUg0YEgU1VOLSog0LjQvdCx0LDRg9C90LTQsNC80Lgg0Lggb3V0Ym91bmQg0L3QsCBAQEVYSVRfTkFNRUBACiMgICAtINC90L7QtNGDIEBAUkVMQVlfTkFNRUBAICjQsNC00YDQtdGBID0gUkVMQVlfSVApCiMgICAtIFNFQ1JFVF9LRVkg0L3QvtC00Ysg4oaSIC9vcHQvQEBTTFVHQEAvbm9kZS1AQFJFTEFZX05BTUVAQC5lbnYKIyAgIC0gcmVsYXktYm9vdHN0cmFwLmVudiDihpIgL29wdC9AQFNMVUdAQC9yZWxheS1ib290c3RyYXAuZW52ICjQtNC70Y8gZGVwbG95LXN1bnNoaW5lKQpzZXQgLWV1byBwaXBlZmFpbApTTFVHPSJAQFNMVUdAQCIKRVhJVF9OQU1FPSJAQEVYSVRfTkFNRUBAIgpSRUxBWV9OQU1FPSJAQFJFTEFZX05BTUVAQCIKUkVMQVlfSVA9IkBAUkVMQVlfSVBAQCIKUkVMQVlfRE9NQUlOPSJAQFJFTEFZX0RPTUFJTkBAIgpNQUlOX0RPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpOT0RFX1BPUlQ9MjIyMgpXU19QQVRIPSIvd3NuZyIKWEhUVFBfUEFUSD0iL3hoIgpQUk9GSUxFX05BTUU9IkBAUkVMQVlfTkFNRUBALVByb2ZpbGUiClNFUlZJQ0VfVVNFUj0icmVsYXktY2FzY2FkZS11c2VyIgoKYygpeyBwcmludGYgJ1wwMzNbJXNtJyAiJDEiOyB9CmxvZygpeyBlY2hvOyBlY2hvICIkKGMgJzE7MzYnKeKWtiQoYyAwKSAkKiI7IH0Kb2soKXsgIGVjaG8gIiAgJChjICcxOzMyJyninJMkKGMgMCkgJCoiOyB9Cndhcm4oKXsgZWNobyAiICAkKGMgJzE7MzMnKSEkKGMgMCkgJCoiOyB9CmRpZSgpeyBlY2hvICIgICQoYyAnMTszMScp4pyXJChjIDApICQqIiA+JjI7IGV4aXQgMTsgfQpqdmFsKCl7IHB5dGhvbjMgLSAiJDEiICIkMiIgPDwnUFknIDI+L2Rldi9udWxsCmltcG9ydCBzeXMsanNvbgp0cnk6IGQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSkKZXhjZXB0IEV4Y2VwdGlvbjogc3lzLmV4aXQoMSkKZm9yIGsgaW4gc3lzLmFyZ3ZbMl0uc3BsaXQoJy4nKToKICAgIGlmIGlzaW5zdGFuY2UoZCxsaXN0KToKICAgICAgICB0cnk6IGQ9ZFtpbnQoayldCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogc3lzLmV4aXQoMSkKICAgIGVsaWYgaXNpbnN0YW5jZShkLGRpY3QpOiBkPWQuZ2V0KGspCiAgICBlbHNlOiBzeXMuZXhpdCgxKQogICAgaWYgZCBpcyBOb25lOiBzeXMuZXhpdCgxKQpwcmludChkIGlmIG5vdCBpc2luc3RhbmNlKGQsKGRpY3QsbGlzdCkpIGVsc2UganNvbi5kdW1wcyhkKSkKUFkKfQoKIyDilIDilIAg0LDQstGC0L7RgNC40LfQsNGG0LjRjyDQvdCwINC/0LDQvdC10LvQuCAo0LLQvdGD0YLRgNC10L3QvdC40Lkg0LzQsNGA0YjRgNGD0YIgbG9jYWxob3N0OjgwODEsINCyINC+0LHRhdC+0LQg0YHRgtC10LvRgdCwKSDilIDilIAKQ1JFRF9GSUxFPSIvb3B0LyRTTFVHL2NyZWRlbnRpYWxzLnR4dCIKWyAtZiAiJENSRURfRklMRSIgXSB8fCBkaWUgItC90LXRgiAkQ1JFRF9GSUxFIOKAlCDQt9Cw0L/Rg9GB0YLQuCBwcm92aXNpb24gZXhpdCDQv9C10YDQstGL0LwiCkFETUlOX1BBU1M9IiQoZ3JlcCAtRSAnXlxzKnBhc3M6JyAiJENSRURfRklMRSIgfCBhd2sgJ3twcmludCAkMn0nIHwgaGVhZCAtMSkiClsgLW4gIiRBRE1JTl9QQVNTIiBdIHx8IGRpZSAi0L3QtSDQvdCw0YjRkdC7INC/0LDRgNC+0LvRjCDQsiAkQ1JFRF9GSUxFIgoKUkVTT0xWRV9BUkdTPSgpCnN0YXR1c19vaygpeyBsb2NhbCBjOyBjPSIkKGN1cmwgLXNTIC1rIC1vIC9kZXYvbnVsbCAiJHtSRVNPTFZFX0FSR1NbQF19IiAtdyAnJXtodHRwX2NvZGV9JyAiJHtBUElfQkFTRX0vYXV0aC9zdGF0dXMiIDI+L2Rldi9udWxsKSI7IFsgLW4gIiRjIiBdICYmIFsgIiRjIiAtZ2UgMjAwIF0gMj4vZGV2L251bGwgJiYgWyAiJGMiIC1sdCA1MDAgXSAyPi9kZXYvbnVsbDsgfQpUT0tFTj0iIgphcGkoKXsKICBsb2NhbCBtZXRob2Q9IiQxIiBwYXRoPSIkMiIgYm9keT0iJHszOi19IiByZXNwIGNvZGUKICBsb2NhbCBhcmdzPSgtc1MgLWsgIiR7UkVTT0xWRV9BUkdTW0BdfSIgLVggIiRtZXRob2QiICIke0FQSV9CQVNFfSR7cGF0aH0iCiAgICAgICAgICAgICAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgLUggIlgtUmVtbmF3YXZlLUNsaWVudC1UeXBlOiBicm93c2VyIikKICBbIC1uICIkVE9LRU4iIF0gJiYgYXJncys9KC1IICJBdXRob3JpemF0aW9uOiBCZWFyZXIgJFRPS0VOIikKICBbIC1uICIkYm9keSIgXSAmJiBhcmdzKz0oLWQgIiRib2R5IikKICByZXNwPSIkKGN1cmwgIiR7YXJnc1tAXX0iIC13ICQnXG4le2h0dHBfY29kZX0nKSIgfHwgeyBlY2hvICIgIOKclyBjdXJsINGD0L/QsNC7INC90LAgJG1ldGhvZCAkcGF0aCIgPiYyOyByZXR1cm4gMTsgfQogIGNvZGU9IiR7cmVzcCMjKiQnXG4nfSI7IHJlc3A9IiR7cmVzcCUkJ1xuJyp9IgogIGlmIFsgIiRjb2RlIiAtbHQgMjAwIF0gfHwgWyAiJGNvZGUiIC1nZSAzMDAgXTsgdGhlbgogICAgeyBlY2hvOyBlY2hvICIgICEgQVBJICRtZXRob2QgJHBhdGgg4oaSIEhUVFAgJGNvZGUiOyBlY2hvICIkcmVzcCIgfCBzZWQgJ3MvXi8gICAgLyc7IH0gPiYyOyByZXR1cm4gMQogIGZpCiAgcHJpbnRmICclcycgIiRyZXNwIgp9Cgpsb2cgItCY0YnRgyDQv9Cw0L3QtdC70YzigKYiCkFQSV9CQVNFPSJodHRwOi8vMTI3LjAuMC4xOjMwMDAvYXBpIjsgUkVTT0xWRV9BUkdTPSgpCmlmIHN0YXR1c19vazsgdGhlbgogIG9rICLQv9Cw0L3QtdC70Ywg0L/QviDQv9GA0Y/QvNC+0LzRgyDQvNCw0YDRiNGA0YPRgtGDICgxMjcuMC4wLjE6MzAwMCkiCmVsc2UKICBmb3IgcCBpbiA4MDgxX2h0dHBzIDQ0MyA4NDQzOyBkbwogICAgaWYgWyAiJHAiID0gIjgwODFfaHR0cHMiIF07IHRoZW4KICAgICAgQVBJX0JBU0U9Imh0dHBzOi8vbG9jYWxob3N0OjgwODEvYXBpIjsgUkVTT0xWRV9BUkdTPSgpCiAgICBlbHNlCiAgICAgIEFQSV9CQVNFPSJodHRwczovLyR7TUFJTl9ET01BSU59OiR7cH0vYXBpIjsgUkVTT0xWRV9BUkdTPSgtLXJlc29sdmUgIiR7TUFJTl9ET01BSU59OiR7cH06MTI3LjAuMC4xIikKICAgIGZpCiAgICBzdGF0dXNfb2sgJiYgeyBvayAi0L/QsNC90LXQu9GMINC90LAgJHAiOyBicmVhazsgfQogICAgWyAiJHAiID0gODQ0MyBdICYmIGRpZSAi0L/QsNC90LXQu9GMINC90LUg0L7RgtCy0LXRh9Cw0LXRgiDQvdC4INC90LAgMzAwMC84MDgxLzQ0My84NDQzIgogIGRvbmUKZmkKbG9naW49IiQoYXBpIFBPU1QgL2F1dGgvbG9naW4gIntcInVzZXJuYW1lXCI6XCJhZG1pblwiLFwicGFzc3dvcmRcIjpcIiRBRE1JTl9QQVNTXCJ9IikiIHx8IGRpZSAi0LvQvtCz0LjQvSDQvdC1INC/0YDQvtGI0ZHQuyIKVE9LRU49IiQoanZhbCAiJGxvZ2luIiByZXNwb25zZS5hY2Nlc3NUb2tlbikiOyBbIC1uICIkVE9LRU4iIF0gfHwgVE9LRU49IiQoanZhbCAiJGxvZ2luIiBhY2Nlc3NUb2tlbikiClsgLW4gIiRUT0tFTiIgXSB8fCBkaWUgItGC0L7QutC10L0g0L3QtSDQv9C+0LvRg9GH0LXQvSIKb2sgItCy0L7RiNGR0Lsg0LIg0L/QsNC90LXQu9GMIgoKIyDilIDilIAgUmVhbGl0eS3QutC70Y7Rh9C4IE1vb25saWdodCAob3V0Ym91bmQg0L3QsCByZWxheSDihpIg0L3Rg9C20L3RiyBwdWJrZXkgKyBzaG9ydGlkKSDilIDilIDilIDilIAKUkVBTElUWV9FTlY9Ii9vcHQvJFNMVUcvbm9kZS9yZWFsaXR5LmVudiIKWyAtZiAiJFJFQUxJVFlfRU5WIiBdIHx8IGRpZSAi0L3QtdGCICRSRUFMSVRZX0VOViDigJQgZGVwbG95LW1vb25saWdodCDQvdC1INC30LDQstC10YDRiNGR0L0iCnNvdXJjZSAiJFJFQUxJVFlfRU5WIgpNT09OX1BVQktFWT0iJHtSRUFMSVRZX1BVQkxJQ19LRVk6LX0iCk1PT05fU0hPUlRJRD0iJHtSRUFMSVRZX1NIT1JUX0lEOi19IgpbIC1uICIkTU9PTl9QVUJLRVkiIF0gfHwgZGllICJSRUFMSVRZX1BVQkxJQ19LRVkg0L3QtSDQvdCw0LnQtNC10L0g0LIgJFJFQUxJVFlfRU5WIgpvayAiUmVhbGl0eS3QutC70Y7Rh9C4IE1vb25saWdodDogcHVia2V5PSR7TU9PTl9QVUJLRVk6MDoxNn3igKYiCgojIOKUgOKUgCAxLiDRgdC10YDQstC40YEt0Y7Qt9C10YAg0LrQsNGB0LrQsNC00LAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmxvZyAi0KHQtdGA0LLQuNGBLdGO0LfQtdGAINC60LDRgdC60LDQtNCwICgkU0VSVklDRV9VU0VSKSIKZXhpc3RpbmdfdT0iJChhcGkgR0VUICIvdXNlcnMvYnktdXNlcm5hbWUvJFNFUlZJQ0VfVVNFUiIgMj4vZGV2L251bGwpIiB8fCBleGlzdGluZ191PSIiCmlmIFsgLW4gIiRleGlzdGluZ191IiBdOyB0aGVuCiAgU0VSVklDRV9VVUlEPSIkKGp2YWwgIiRleGlzdGluZ191IiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiRTRVJWSUNFX1VVSUQiIF0gfHwgU0VSVklDRV9VVUlEPSIkKGp2YWwgIiRleGlzdGluZ191IiB1dWlkKSIKICBvayAi0YHQtdGA0LLQuNGBLdGO0LfQtdGAINGD0LbQtSDQtdGB0YLRjDogJFNFUlZJQ0VfVVVJRCIKZWxzZQogIHViPSIkKHB5dGhvbjMgLWMgImltcG9ydCBqc29uLHN5czsgcHJpbnQoanNvbi5kdW1wcyh7J3VzZXJuYW1lJzonJFNFUlZJQ0VfVVNFUicsJ3RyYWZmaWNMaW1pdEJ5dGVzJzowLCd0cmFmZmljTGltaXRTdHJhdGVneSc6J05PX1JFU0VUJywnZXhwaXJlQXQnOicyMDk5LTAxLTAxVDAwOjAwOjAwLjAwMFonLCdhY3RpdmVJbnRlcm5hbFNxdWFkcyc6W119KSkiKSIKICB1c3I9IiQoYXBpIFBPU1QgL3VzZXJzICIkdWIiKSIgfHwgZGllICLRgdC+0LfQtNCw0L3QuNC1INGB0LXRgNCy0LjRgS3RjtC30LXRgNCwIOKAlCDRgdC60LjQvdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCIKICBTRVJWSUNFX1VVSUQ9IiQoanZhbCAiJHVzciIgcmVzcG9uc2UudXVpZCkiOyBbIC1uICIkU0VSVklDRV9VVUlEIiBdIHx8IFNFUlZJQ0VfVVVJRD0iJChqdmFsICIkdXNyIiB1dWlkKSIKICBvayAi0YHQtdGA0LLQuNGBLdGO0LfQtdGAINGB0L7Qt9C00LDQvTogJFNFUlZJQ0VfVVVJRCIKZmkKIyDRhNC+0LvQsdGN0Log0YfQtdGA0LXQtyDQkdCUCmlmIFsgLXogIiR7U0VSVklDRV9VVUlEOi19IiBdOyB0aGVuCiAgU0VSVklDRV9VVUlEPSIkKGRvY2tlciBleGVjIC1pIHJlbW5hd2F2ZS1kYiBwc3FsIC1VIHBvc3RncmVzIC1kIHBvc3RncmVzIC10QWMgXAogICAgIlNFTEVDVCB1dWlkIEZST00gdXNlcnMgV0hFUkUgdXNlcm5hbWU9JyRTRVJWSUNFX1VTRVInIExJTUlUIDE7IiAyPi9kZXYvbnVsbCB8IHRyIC1kICdbOnNwYWNlOl0nKSIgfHwgU0VSVklDRV9VVUlEPSIiCiAgWyAtbiAiJFNFUlZJQ0VfVVVJRCIgXSAmJiBvayAiVVVJRCDRgdC10YDQstC40YEt0Y7Qt9C10YDQsCDQuNC3INCR0JQ6ICRTRVJWSUNFX1VVSUQiIHx8IGRpZSAi0L3QtSDQvNC+0LPRgyDQv9C+0LvRg9GH0LjRgtGMIFVVSUQg0YHQtdGA0LLQuNGBLdGO0LfQtdGA0LAiCmZpCgojIOKUgOKUgCAyLiByZWxheSBjb25maWctcHJvZmlsZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICJSZWxheSBjb25maWctcHJvZmlsZSAoJFBST0ZJTEVfTkFNRSkiCiMgUmVhbGl0eS3QutC70Y7Rh9C4IFN1bnNoaW5lOiDQv9C10YDQtdC40YHQv9C+0LvRjNC30YPQtdC8INC40Lcg0L/RgNC10LTRi9C00YPRidC10LPQviBib290c3RyYXAgKNGB0YLQsNCx0LjQu9GM0L3QvtGB0YLRjCDQutC70Y7Rh9C10LkhKQpSRUxBWV9QUklWPSIiOyBSRUxBWV9QVUI9IiI7IFJFTEFZX1NJRD0iIgpfcHJldl9icz0iL29wdC8kU0xVRy9yZWxheS1ib290c3RyYXAuZW52IgppZiBbIC1mICIkX3ByZXZfYnMiIF07IHRoZW4KICBfcD0iJChncmVwICdeUkVMQVlfUFJJVj0nICIkX3ByZXZfYnMiIHwgY3V0IC1kPSAtZjItKSI7IF9xPSIkKGdyZXAgJ15SRUxBWV9QVUI9JyAiJF9wcmV2X2JzIiB8IGN1dCAtZD0gLWYyLSkiCiAgX3M9IiQoZ3JlcCAnXlJFTEFZX1NJRD0nICIkX3ByZXZfYnMiIHwgY3V0IC1kPSAtZjItKSIKICBpZiBbIC1uICIkX3AiIF0gJiYgWyAtbiAiJF9xIiBdICYmIFsgLW4gIiRfcyIgXTsgdGhlbgogICAgUkVMQVlfUFJJVj0iJF9wIjsgUkVMQVlfUFVCPSIkX3EiOyBSRUxBWV9TSUQ9IiRfcyIKICAgIG9rICJSZWFsaXR5LdC60LvRjtGH0LggU3Vuc2hpbmUg4oCUINC/0LXRgNC10LjRgdC/0L7Qu9GM0LfRg9GOINC40LcgYm9vdHN0cmFwIChwdWJrZXk9JHtSRUxBWV9QVUI6MDoxNn3igKYpIgogIGZpCmZpCmlmIFsgLXogIiRSRUxBWV9QVUIiIF07IHRoZW4KICAjINCz0LXQvdC10YDQuNGA0YPQtdC8INCy0L/QtdGA0LLRi9C1CiAgaWYgY29tbWFuZCAtdiB4cmF5ID4vZGV2L251bGwgMj4mMTsgdGhlbgogICAgUkVMQVlfUFJJVj0iJCh4cmF5IHgyNTUxOSB8IGF3ayAnL1tQcF1yaXZhdGUve3ByaW50ICRORn0nKSI7IFJFTEFZX1BVQj0iJCh4cmF5IHgyNTUxOSAtaSAiJFJFTEFZX1BSSVYiIHwgYXdrICcvW1BwXXVibGljfFtQcF1hc3N3b3JkL3twcmludCAkTkZ9JykiCiAgZWxpZiBkb2NrZXIgZXhlYyByZW1uYW5vZGUgeHJheSB4MjU1MTkgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBSRUxBWV9QUklWPSIkKGRvY2tlciBleGVjIHJlbW5hbm9kZSB4cmF5IHgyNTUxOSB8IGF3ayAnL1tQcF1yaXZhdGUve3ByaW50ICRORn0nKSIKICAgIFJFTEFZX1BVQj0iJChkb2NrZXIgZXhlYyByZW1uYW5vZGUgeHJheSB4MjU1MTkgLWkgIiRSRUxBWV9QUklWIiB8IGF3ayAnL1tQcF11YmxpY3xbUHBdYXNzd29yZC97cHJpbnQgJE5GfScpIgogIGVsc2UKICAgIF9vdXQ9IiQoZG9ja2VyIHJ1biAtLXJtIC0tbmV0d29yayBub25lIGdoY3IuaW8veHRscy94cmF5LWNvcmU6bGF0ZXN0IHhyYXkgeDI1NTE5IDI+L2Rldi9udWxsKSIgfHwgX291dD0iIgogICAgUkVMQVlfUFJJVj0iJChlY2hvICIkX291dCIgfCBhd2sgJy9bUHBdcml2YXRlL3twcmludCAkTkZ9JykiOyBSRUxBWV9QVUI9IiQoZWNobyAiJF9vdXQiIHwgYXdrICcvW1BwXXVibGljfFtQcF1hc3N3b3JkL3twcmludCAkTkZ9JykiCiAgZmkKICBSRUxBWV9TSUQ9IiQob3BlbnNzbCByYW5kIC1oZXggOCkiCiAgWyAtbiAiJFJFTEFZX1BVQiIgXSB8fCBkaWUgItC90LUg0YPQtNCw0LvQvtGB0Ywg0YHQs9C10L3QtdGA0LjRgNC+0LLQsNGC0YwgUmVhbGl0eS3QutC70Y7Rh9C4INC00LvRjyBTdW5zaGluZSDigJQg0L3QtdGCIHhyYXkvZG9ja2VyIgogIG9rICJSZWFsaXR5LdC60LvRjtGH0LggU3Vuc2hpbmUg4oCUINGB0LPQtdC90LXRgNC40YDQvtCy0LDQvdGLINC90L7QstGL0LU6IHB1YmtleT0ke1JFTEFZX1BVQjowOjE2feKApiIKZmkKCk1PT05fSVA9IkBARVhJVF9JUEBAIgpyZWxheV94cmF5PSIkKHB5dGhvbjMgLSAiJFNFUlZJQ0VfVVVJRCIgIiRSRUxBWV9ET01BSU4iICIkUkVMQVlfUFJJViIgIiRSRUxBWV9TSUQiIFwKICAiJE1PT05fSVAiICIkTUFJTl9ET01BSU4iICIkTU9PTl9QVUJLRVkiICIkTU9PTl9TSE9SVElEIiAiJFdTX1BBVEgiICIkWEhUVFBfUEFUSCIgPDwnUFknCmltcG9ydCBzeXMsanNvbgpzdmNfdXVpZCxkb21haW4scHJpdixzaWQsbW9vbl9pcCxtb29uX3NuaSxtb29uX3B1Yixtb29uX3NpZCx3c19wYXRoLHhodHRwX3BhdGg9c3lzLmFyZ3ZbMTpdCnByaW50KGpzb24uZHVtcHMoewogICJpbmJvdW5kcyI6WwogICAgeyJ0YWciOiJTVU4tUkVBTElUWSIsImxpc3RlbiI6IjAuMC4wLjAiLCJwb3J0Ijo0NDMsInByb3RvY29sIjoidmxlc3MiLAogICAgICJzZXR0aW5ncyI6eyJjbGllbnRzIjpbXSwiZGVjcnlwdGlvbiI6Im5vbmUifSwKICAgICAic3RyZWFtU2V0dGluZ3MiOnsibmV0d29yayI6InRjcCIsInNlY3VyaXR5IjoicmVhbGl0eSIsCiAgICAgICAicmVhbGl0eVNldHRpbmdzIjp7InNob3ciOkZhbHNlLCJkZXN0IjoiMTI3LjAuMC4xOjg0NDMiLAogICAgICAgICAic2VydmVyTmFtZXMiOltkb21haW5dLCJwcml2YXRlS2V5Ijpwcml2LCJzaG9ydElkcyI6W3NpZF19fSwKICAgICAic25pZmZpbmciOnsiZW5hYmxlZCI6VHJ1ZSwiZGVzdE92ZXJyaWRlIjpbImh0dHAiLCJ0bHMiLCJxdWljIl19fSwKICAgIHsidGFnIjoiU1VOLVdTIiwibGlzdGVuIjoiMTI3LjAuMC4xIiwicG9ydCI6MjA1MywicHJvdG9jb2wiOiJ2bGVzcyIsCiAgICAgInNldHRpbmdzIjp7ImNsaWVudHMiOltdLCJkZWNyeXB0aW9uIjoibm9uZSJ9LAogICAgICJzdHJlYW1TZXR0aW5ncyI6eyJuZXR3b3JrIjoid3MiLCJzZWN1cml0eSI6Im5vbmUiLCJ3c1NldHRpbmdzIjp7InBhdGgiOndzX3BhdGh9fX0sCiAgICB7InRhZyI6IlNVTi1YSFRUUCIsImxpc3RlbiI6IjAuMC4wLjAiLCJwb3J0IjoyMDgzLCJwcm90b2NvbCI6InZsZXNzIiwKICAgICAic2V0dGluZ3MiOnsiY2xpZW50cyI6W10sImRlY3J5cHRpb24iOiJub25lIn0sCiAgICAgInN0cmVhbVNldHRpbmdzIjp7Im5ldHdvcmsiOiJ4aHR0cCIsInNlY3VyaXR5IjoicmVhbGl0eSIsCiAgICAgICAicmVhbGl0eVNldHRpbmdzIjp7InNob3ciOkZhbHNlLCJkZXN0IjoiMTI3LjAuMC4xOjg0NDMiLCJzZXJ2ZXJOYW1lcyI6W2RvbWFpbl0sInByaXZhdGVLZXkiOnByaXYsInNob3J0SWRzIjpbc2lkXX0sCiAgICAgICAieGh0dHBTZXR0aW5ncyI6eyJwYXRoIjp4aHR0cF9wYXRoLCJtb2RlIjoiYXV0byJ9fX0sCiAgICB7InRhZyI6IlNVTi1IWTIiLCJsaXN0ZW4iOiIwLjAuMC4wIiwicG9ydCI6NDQzLCJwcm90b2NvbCI6Imh5c3RlcmlhIiwKICAgICAic2V0dGluZ3MiOnsiY2xpZW50cyI6W119LAogICAgICJzdHJlYW1TZXR0aW5ncyI6eyJuZXR3b3JrIjoiaHlzdGVyaWEiLCJzZWN1cml0eSI6InRscyIsCiAgICAgICAidGxzU2V0dGluZ3MiOnsiYWxwbiI6WyJoMyJdLCJzZXJ2ZXJOYW1lIjpkb21haW4sCiAgICAgICAgICJjZXJ0aWZpY2F0ZXMiOlt7ImNlcnRpZmljYXRlRmlsZSI6Ii9jZXJ0cy9oeTIuY3J0Iiwia2V5RmlsZSI6Ii9jZXJ0cy9oeTIua2V5In1dfSwKICAgICAgICJoeXN0ZXJpYVNldHRpbmdzIjp7InZlcnNpb24iOjIsInVkcElkbGVUaW1lb3V0Ijo2MH19fQogIF0sCiAgIm91dGJvdW5kcyI6WwogICAgeyJ0YWciOiJ0by1tb29ubGlnaHQiLCJwcm90b2NvbCI6InZsZXNzIiwKICAgICAic2V0dGluZ3MiOnsidm5leHQiOlt7ImFkZHJlc3MiOm1vb25faXAsInBvcnQiOjQ0MywKICAgICAgICJ1c2VycyI6W3siaWQiOnN2Y191dWlkLCJlbmNyeXB0aW9uIjoibm9uZSIsImZsb3ciOiJ4dGxzLXJwcngtdmlzaW9uIn1dfV19LAogICAgICJzdHJlYW1TZXR0aW5ncyI6eyJuZXR3b3JrIjoidGNwIiwic2VjdXJpdHkiOiJyZWFsaXR5IiwKICAgICAgICJyZWFsaXR5U2V0dGluZ3MiOnsic2VydmVyTmFtZSI6bW9vbl9zbmksImZpbmdlcnByaW50IjoiY2hyb21lIiwKICAgICAgICAgInB1YmxpY0tleSI6bW9vbl9wdWIsInNob3J0SWQiOm1vb25fc2lkfX19LAogICAgeyJ0YWciOiJkaXJlY3QiLCJwcm90b2NvbCI6ImZyZWVkb20iLCJzZXR0aW5ncyI6eyJkb21haW5TdHJhdGVneSI6IlVzZUlQdjQifX0sCiAgICB7InRhZyI6ImJsb2NrIiwicHJvdG9jb2wiOiJibGFja2hvbGUifQogIF0sCiAgImRucyI6eyJzZXJ2ZXJzIjpbIjEuMS4xLjEiLCI4LjguOC44Il0sInF1ZXJ5U3RyYXRlZ3kiOiJVc2VJUHY0In0sCiAgInJvdXRpbmciOnsiZG9tYWluU3RyYXRlZ3kiOiJBc0lzIiwicnVsZXMiOlsKICAgIHsidHlwZSI6ImZpZWxkIiwiaW5ib3VuZFRhZyI6WyJTVU4tUkVBTElUWSIsIlNVTi1XUyIsIlNVTi1YSFRUUCIsIlNVTi1IWTIiXSwib3V0Ym91bmRUYWciOiJ0by1tb29ubGlnaHQifQogIF19Cn0pKQpQWQopIiB8fCBkaWUgItCz0LXQvdC10YDQsNGG0LjRjyB4cmF5LdC60L7QvdGE0LjQs9CwIHJlbGF5INC/0YDQvtCy0LDQu9C40LvQsNGB0YwiCgpwbGlzdD0iJChhcGkgR0VUIC9jb25maWctcHJvZmlsZXMpIiB8fCBkaWUgItGH0YLQtdC90LjQtSDQv9GA0L7RhNC40LvQtdC5IgpSRUxBWV9QUk9GSUxFX1VVSUQ9IiQocHl0aG9uMyAtICIkcGxpc3QiICIkUFJPRklMRV9OQU1FIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCmQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IGFycj1kLmdldCgicmVzcG9uc2UiLHt9KS5nZXQoImNvbmZpZ1Byb2ZpbGVzIikgb3IgZC5nZXQoImNvbmZpZ1Byb2ZpbGVzIikgb3IgKGQgaWYgaXNpbnN0YW5jZShkLGxpc3QpIGVsc2UgW10pCnByaW50KG5leHQoKHguZ2V0KCJ1dWlkIikgZm9yIHggaW4gYXJyIGlmIGlzaW5zdGFuY2UoeCxkaWN0KSBhbmQgeC5nZXQoIm5hbWUiKT09c3lzLmFyZ3ZbMl0pLCIiKSkKUFkKKSIKaWYgWyAtbiAiJFJFTEFZX1BST0ZJTEVfVVVJRCIgXTsgdGhlbgogIG9rICJyZWxheS3Qv9GA0L7RhNC40LvRjCDRg9C20LUg0LXRgdGC0Yw6ICRSRUxBWV9QUk9GSUxFX1VVSUQg4oCUINGD0LTQsNC70Y/RjiDQuCDQv9C10YDQtdGB0L7Qt9C00LDRjiAo0L7QsdC90L7QstC70LXQvdC40LUg0LrQvtC90YTQuNCz0LApIgogIGFwaSBERUxFVEUgIi9jb25maWctcHJvZmlsZXMvJFJFTEFZX1BST0ZJTEVfVVVJRCIgPi9kZXYvbnVsbCAyPiYxIHx8IHdhcm4gIkRFTEVURSDQv9GA0L7RhNC40LvRjyDQvdC1INC/0YDQvtGI0ZHQuyDigJQg0LLQvtC30LzQvtC20L3QviDRg9C20LUg0YPQtNCw0LvRkdC9IgogIFJFTEFZX1BST0ZJTEVfVVVJRD0iIgpmaQpwYm9keT0iJChweXRob24zIC0gIiRQUk9GSUxFX05BTUUiIDw8UFkKaW1wb3J0IHN5cyxqc29uCm5hbWU9c3lzLmFyZ3ZbMV0KY29uZmlnPWpzb24ubG9hZHMociIiIiRyZWxheV94cmF5IiIiKQpwcmludChqc29uLmR1bXBzKHsibmFtZSI6bmFtZSwiY29uZmlnIjpjb25maWd9KSkKUFkKKSIKcHJvZj0iJChhcGkgUE9TVCAvY29uZmlnLXByb2ZpbGVzICIkcGJvZHkiKSIgfHwgZGllICLRgdC+0LfQtNCw0L3QuNC1IHJlbGF5LdC/0YDQvtGE0LjQu9GPIOKAlCDRgdC60LjQvdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCIKUkVMQVlfUFJPRklMRV9VVUlEPSIkKGp2YWwgIiRwcm9mIiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiRSRUxBWV9QUk9GSUxFX1VVSUQiIF0gfHwgUkVMQVlfUFJPRklMRV9VVUlEPSIkKGp2YWwgIiRwcm9mIiB1dWlkKSIKb2sgInJlbGF5LdC/0YDQvtGE0LjQu9GMINGB0L7Qt9C00LDQvTogJFJFTEFZX1BST0ZJTEVfVVVJRCIKSU5CPSIkKGFwaSBHRVQgIi9jb25maWctcHJvZmlsZXMvJFJFTEFZX1BST0ZJTEVfVVVJRC9pbmJvdW5kcyIpIiB8fCB0cnVlClJFTEFZX0lOX1VVSURTPSIkKHB5dGhvbjMgLSAiJElOQiIgPDwnUFknCmltcG9ydCBzeXMsanNvbgp0cnk6IGE9anNvbi5sb2FkcyhzeXMuYXJndlsxXSkKZXhjZXB0IEV4Y2VwdGlvbjogYT1bXQphPWEuZ2V0KCJyZXNwb25zZSIsYSkgaWYgaXNpbnN0YW5jZShhLGRpY3QpIGVsc2UgYQphPWEuZ2V0KCJpbmJvdW5kcyIsYSkgaWYgaXNpbnN0YW5jZShhLGRpY3QpIGVsc2UgYQppZiBub3QgaXNpbnN0YW5jZShhLGxpc3QpOiBhPVtdCnByaW50KGpzb24uZHVtcHMoW3guZ2V0KCJ1dWlkIikgZm9yIHggaW4gYSBpZiBpc2luc3RhbmNlKHgsZGljdCkgYW5kIHguZ2V0KCJ1dWlkIildKSkKUFkKKSIKb2sgItC40L3QsdCw0YPQvdC00YsgcmVsYXkt0L/RgNC+0YTQuNC70Y86ICRSRUxBWV9JTl9VVUlEUyIKCiMg4pSA4pSAIDMuINC90L7QtNCwIFN1bnNoaW5lIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsb2cgItCd0L7QtNCwICRSRUxBWV9OQU1FICjQsNC00YDQtdGBOiAkUkVMQVlfSVApIgpub2RlX2JvZHk9IiQocHl0aG9uMyAtICIkUkVMQVlfTkFNRSIgIiRSRUxBWV9JUCIgIiROT0RFX1BPUlQiICIkUkVMQVlfUFJPRklMRV9VVUlEIiAiJFJFTEFZX0lOX1VVSURTIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCm5hbWUsYWRkcixwb3J0LHByb2YsaW5zPXN5cy5hcmd2WzE6Nl0KcHJpbnQoanNvbi5kdW1wcyh7Im5hbWUiOm5hbWUsImFkZHJlc3MiOmFkZHIsInBvcnQiOmludChwb3J0KSwKICAiY29uZmlnUHJvZmlsZSI6eyJhY3RpdmVDb25maWdQcm9maWxlVXVpZCI6cHJvZiwiYWN0aXZlSW5ib3VuZHMiOmpzb24ubG9hZHMoaW5zKX19KSkKUFkKKSIKbmxpc3Q9IiQoYXBpIEdFVCAvbm9kZXMpIiB8fCBkaWUgItGH0YLQtdC90LjQtSDQvdC+0LQiClJFTEFZX05PREVfVVVJRD0iJChweXRob24zIC0gIiRubGlzdCIgIiRSRUxBWV9OQU1FIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCmQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IGFycj1kLmdldCgicmVzcG9uc2UiKSBpZiBpc2luc3RhbmNlKGQsZGljdCkgZWxzZSBkCmlmIGlzaW5zdGFuY2UoYXJyLGRpY3QpOiBhcnI9YXJyLmdldCgibm9kZXMiKSBvciBhcnIuZ2V0KCJkYXRhIikgb3IgW10KcHJpbnQobmV4dCgobi5nZXQoInV1aWQiKSBmb3IgbiBpbiAoYXJyIG9yIFtdKSBpZiBpc2luc3RhbmNlKG4sZGljdCkgYW5kIG4uZ2V0KCJuYW1lIik9PXN5cy5hcmd2WzJdKSwiIikpClBZCikiCmlmIFsgLW4gIiRSRUxBWV9OT0RFX1VVSUQiIF07IHRoZW4KICBvayAi0L3QvtC00LAg0YPQttC1INC10YHRgtGMOiAkUkVMQVlfTk9ERV9VVUlEIOKAlCDQvtCx0L3QvtCy0LvRj9GOINC/0YDQvtGE0LjQu9GMINGH0LXRgNC10LcgUEFUQ0ggKNC90LUg0L/QtdGA0LXRgdC+0LfQtNCw0Y4pIgogIGlmIGFwaSBQQVRDSCAvbm9kZXMgIntcInV1aWRcIjpcIiRSRUxBWV9OT0RFX1VVSURcIixcImNvbmZpZ1Byb2ZpbGVcIjp7XCJhY3RpdmVDb25maWdQcm9maWxlVXVpZFwiOlwiJFJFTEFZX1BST0ZJTEVfVVVJRFwiLFwiYWN0aXZlSW5ib3VuZHNcIjokUkVMQVlfSU5fVVVJRFN9fSIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBvayAi0L/RgNC+0YTQuNC70Ywg0L3QvtC00Ysg0L7QsdC90L7QstC70ZHQvTogJFJFTEFZX05PREVfVVVJRCIKICBlbHNlCiAgICB3YXJuICJQQVRDSCDQvdC+0LTRiyDQvdC1INC/0YDQvtGI0ZHQuyDigJQg0L/QtdGA0LXRgdC+0LfQtNCw0Y4gKFNFQ1JFVF9LRVkg0LzQvtC20LXRgiDRgdC80LXQvdC40YLRjNGB0Y8pIgogICAgYXBpIERFTEVURSAiL25vZGVzLyRSRUxBWV9OT0RFX1VVSUQiID4vZGV2L251bGwgMj4mMSBcCiAgICAgIHx8IHdhcm4gIkRFTEVURSDQvdC+0LTRiyDQvdC1INC/0YDQvtGI0ZHQuyDigJQg0L/QvtC/0YvRgtCw0Y7RgdGMINGB0L7Qt9C00LDRgtGMINC90L7QstGD0Y4iCiAgICBSRUxBWV9OT0RFX1VVSUQ9IiIKICAgIG5vZGU9IiQoYXBpIFBPU1QgL25vZGVzICIkbm9kZV9ib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQsNC90LjQtSDQvdC+0LTRiyDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC60LgiCiAgICBSRUxBWV9OT0RFX1VVSUQ9IiQoanZhbCAiJG5vZGUiIHJlc3BvbnNlLnV1aWQpIjsgWyAtbiAiJFJFTEFZX05PREVfVVVJRCIgXSB8fCBSRUxBWV9OT0RFX1VVSUQ9IiQoanZhbCAiJG5vZGUiIHV1aWQpIgogICAgb2sgItC90L7QtNCwINC/0LXRgNC10YHQvtC30LTQsNC90LA6ICRSRUxBWV9OT0RFX1VVSUQiCiAgZmkKZWxzZQogIG5vZGU9IiQoYXBpIFBPU1QgL25vZGVzICIkbm9kZV9ib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQsNC90LjQtSDQvdC+0LTRiyDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC60LgiCiAgUkVMQVlfTk9ERV9VVUlEPSIkKGp2YWwgIiRub2RlIiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiRSRUxBWV9OT0RFX1VVSUQiIF0gfHwgUkVMQVlfTk9ERV9VVUlEPSIkKGp2YWwgIiRub2RlIiB1dWlkKSIKICBvayAi0L3QvtC00LAg0YHQvtC30LTQsNC90LA6ICRSRUxBWV9OT0RFX1VVSUQiCmZpCgojIOKUgOKUgCAzYi4g0JTQvtCx0LDQstC70Y/QtdC8INC40L3QsdCw0YPQvdC00YsgU3Vuc2hpbmUg0LIgbWFpbiBzcXVhZCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICLQn9GA0LjQstGP0LfRi9Cy0LDRjiDQuNC90LHQsNGD0L3QtNGLICRSRUxBWV9OQU1FINC6IHNxdWFkINC4INC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRj9C8IgojINCx0LXRgNGR0Lwg0LLRgdC1IHNxdWFkJ9GLCnNxdWFkcz0iJChhcGkgR0VUIC9pbnRlcm5hbC1zcXVhZHMgMj4vZGV2L251bGwpIiB8fCBzcXVhZHM9IiIKU1FVQURfVVVJRD0iJChweXRob24zIC0gIiRzcXVhZHMiIDw8J1BZJwppbXBvcnQgc3lzLGpzb24KdHJ5OgogIGQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IHI9ZC5nZXQoInJlc3BvbnNlIixkKQogIGFycj1yLmdldCgiaW50ZXJuYWxTcXVhZHMiKSBpZiBpc2luc3RhbmNlKHIsZGljdCkgZWxzZSAociBpZiBpc2luc3RhbmNlKHIsbGlzdCkgZWxzZSBbXSkKICAjINC/0YDQtdC00L/QvtGH0LjRgtCw0LXQvCBzcXVhZCDRgSDQuNC80LXQvdC10LwgJ21haW4nLCDQuNC90LDRh9C1INC/0LXRgNCy0YvQuQogIG1haW49bmV4dCgocy5nZXQoInV1aWQiKSBmb3IgcyBpbiBhcnIgaWYgaXNpbnN0YW5jZShzLGRpY3QpIGFuZCBzLmdldCgibmFtZSIpPT0ibWFpbiIpLCIiKQogIHByaW50KG1haW4gb3IgbmV4dCgocy5nZXQoInV1aWQiKSBmb3IgcyBpbiBhcnIgaWYgaXNpbnN0YW5jZShzLGRpY3QpKSwiIikpCmV4Y2VwdCBFeGNlcHRpb246IHByaW50KCIiKQpQWQopIgppZiBbIC1uICIkU1FVQURfVVVJRCIgXSAmJiBbIC1uICIkUkVMQVlfSU5fVVVJRFMiIF07IHRoZW4KICAjINC/0L7Qu9GD0YfQsNC10Lwg0YLQtdC60YPRidC40Lkg0YHQvtGB0YLQsNCyIHNxdWFkJ9CwCiAgc3FfZGF0YT0iJChhcGkgR0VUICIvaW50ZXJuYWwtc3F1YWRzLyRTUVVBRF9VVUlEIiAyPi9kZXYvbnVsbCkiIHx8IHNxX2RhdGE9IiIKICAjINC30LDQs9GA0YPQttCw0LXQvCDQv9GA0LXQtNGL0LTRg9GJ0LjQtSDQuNC90LHQsNGD0L3QtNGLIFN1bnNoaW5lINC40Lcg0YTQsNC50LvQsCAo0YfRgtC+0LHRiyDRg9C00LDQu9C40YLRjCDRg9GB0YLQsNGA0LXQstGI0LjQtSkKICBfb2xkX3JlbGF5X2ZpbGU9Ii9vcHQvJFNMVUcvLnJlbGF5LWluYm91bmQtdXVpZHMiCiAgX29sZF9yZWxheV9pbj0iJChbIC1mICIkX29sZF9yZWxheV9maWxlIiBdICYmIGNhdCAiJF9vbGRfcmVsYXlfZmlsZSIgfHwgZWNobyAnW10nKSIKICAjINC30LDQvNC10L3Rj9C10Lwg0YHRgtCw0YDRi9C1INC40L3QsdCw0YPQvdC00YsgU3Vuc2hpbmUg0LIgc3F1YWQg0L3QsCDQvdC+0LLRi9C1ICjQvdC1INC90LDQutCw0L/Qu9C40LLQsNC10Lwg0YHRgtC10LnQuykKICBuZXdfaW5ib3VuZHM9IiQocHl0aG9uMyAtICIkc3FfZGF0YSIgIiRSRUxBWV9JTl9VVUlEUyIgIiRfb2xkX3JlbGF5X2luIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnRyeToKICBkPWpzb24ubG9hZHMoc3lzLmFyZ3ZbMV0pOyByPWQuZ2V0KCJyZXNwb25zZSIsZCkKICBleGlzdGluZz1yLmdldCgiaW5ib3VuZHMiKSBvciBbXQogIGV4aXN0aW5nPVt4LmdldCgidXVpZCIpIGlmIGlzaW5zdGFuY2UoeCxkaWN0KSBlbHNlIHggZm9yIHggaW4gZXhpc3RpbmddCiAgbmV3PWpzb24ubG9hZHMoc3lzLmFyZ3ZbMl0pCiAgb2xkPXNldChqc29uLmxvYWRzKHN5cy5hcmd2WzNdKSkKICAjINGD0LTQsNC70Y/QtdC8INGD0YHRgtCw0YDQtdCy0YjQuNC1IFN1bnNoaW5lLdC40L3QsdCw0YPQvdC00YsgKNC60L7RgtC+0YDRi9C1INCx0YvQu9C4INCyINC/0YDQvtGI0LvRi9C5INGA0LDQtyksINC00L7QsdCw0LLQu9GP0LXQvCDQvdC+0LLRi9C1CiAgbWVyZ2VkPVt4IGZvciB4IGluIGV4aXN0aW5nIGlmIHggbm90IGluIG9sZF0rbmV3CiAgbWVyZ2VkPWxpc3QoZGljdC5mcm9ta2V5cyhtZXJnZWQpKQogIHByaW50KGpzb24uZHVtcHMobWVyZ2VkKSkKZXhjZXB0IEV4Y2VwdGlvbjogcHJpbnQoc3lzLmFyZ3ZbMl0pClBZCikiCiAgaWYgX3NxX3Jlc3VsdD0iJChhcGkgUEFUQ0ggIi9pbnRlcm5hbC1zcXVhZHMiIFwKICAgICJ7XCJ1dWlkXCI6XCIkU1FVQURfVVVJRFwiLFwiaW5ib3VuZHNcIjokbmV3X2luYm91bmRzfSIgMj4mMSkiOyB0aGVuCiAgICBvayAi0LjQvdCx0LDRg9C90LTRiyAkUkVMQVlfTkFNRSDQvtCx0L3QvtCy0LvQtdC90Ysg0LIgc3F1YWQgJFNRVUFEX1VVSUQgKNGD0YHRgtCw0YDQtdCy0YjQuNC1INGD0LTQsNC70LXQvdGLKSIKICAgIHByaW50ZiAnJXMnICIkUkVMQVlfSU5fVVVJRFMiID4gIiRfb2xkX3JlbGF5X2ZpbGUiCiAgZWxzZQogICAgd2FybiAi0L3QtSDRg9C00LDQu9C+0YHRjCDQvtCx0L3QvtCy0LjRgtGMINC40L3QsdCw0YPQvdC00Ysg0LIgc3F1YWQ6ICRfc3FfcmVzdWx0IgogICAgd2FybiAi0LTQvtCx0LDQstGMINCy0YDRg9GH0L3Rg9GOINCyINC/0LDQvdC10LvQuCDihpIgSW50ZXJuYWwgU3F1YWRzIOKGkiBtYWluIOKGkiDQtNC+0LHQsNCy0LjRgtGMINC40L3QsdCw0YPQvdC00YsgU3Vuc2hpbmUiCiAgZmkKZWxzZQogIHdhcm4gInNxdWFkINC90LUg0L3QsNC50LTQtdC9IOKAlCDQtNC+0LHQsNCy0Ywg0LjQvdCx0LDRg9C90LTRiyBTdW5zaGluZSDQstGA0YPRh9C90YPRjiDQsiDQv9Cw0L3QtdC70Lgg4oaSIEludGVybmFsIFNxdWFkcyIKZmkKCgoKIyDilIDilIAgM2MuINCh0LXRgNCy0LjRgS3RjtC30LXRgCDQutCw0YHQutCw0LTQsCDihpIgbWFpbiBzcXVhZCAo0LjQtNC10LzQv9C+0YLQtdC90YLQvdC+ICsg0LLQtdGA0LjRhNC40LrQsNGG0LjRjyArIHNlbGYtaGVhbCkg4pSA4pSACiMg0K3QotCeINCa0JvQrtCn0JXQktCe0Jkg0KjQkNCTOiDQsdC10LcgVVVJRCDQutCw0YHQutCw0LQt0Y7Qt9C10YDQsCDQsiBjbGllbnRzINC40L3QsdCw0YPQvdC00L7QsiBNb29ubGlnaHQg0JLQodCVCiMgdmlhLVN1bnNoaW5lINGB0L7QtdC00LjQvdC10L3QuNGPINC/0LDQtNCw0Y7RgiAodGxzOiBpbnRlcm5hbCBlcnJvciAvIGJhZCBIVFRQIHZlcnNpb24gLyBFT0YpLgpsb2cgItCS0LLQvtC20YMg0YHQtdGA0LLQuNGBLdGO0LfQtdGA0LAg0LrQsNGB0LrQsNC00LAg0LIgc3F1YWQgJyQoWyAtbiAiJFNRVUFEX1VVSUQiIF0gJiYgZWNobyBtYWluKScg0Lgg0L/RgNC+0LLQtdGA0Y/RjiDQutCw0YHQutCw0LQgZW5kLXRvLWVuZCIKaWYgWyAteiAiJFNRVUFEX1VVSUQiIF0gfHwgWyAteiAiJFNFUlZJQ0VfVVVJRCIgXTsgdGhlbgogIHdhcm4gItC90LXRgiBTUVVBRF9VVUlEL1NFUlZJQ0VfVVVJRCDigJQg0LrQsNGB0LrQsNC0INC90LDRgdGC0YDQvtC40YLRjCDQvdC10LvRjNC30Y8iCmVsc2UKICAjICgxKSDRiNGC0LDRgtC90YvQuSDQv9GD0YLRjCDigJQg0YfQtdGA0LXQtyBBUEkg0L/QsNC90LXQu9C4ICjRgtGA0LjQs9Cz0LXRgNC40YIg0LDQstGC0L4t0L/Rg9GIINC60L7QvdGE0LjQs9CwINC90LAg0L3QvtC00YspCiAgaWYgYXBpIFBBVENIICIvdXNlcnMiICJ7XCJ1dWlkXCI6XCIkU0VSVklDRV9VVUlEXCIsXCJhY3RpdmVJbnRlcm5hbFNxdWFkc1wiOltcIiRTUVVBRF9VVUlEXCJdfSIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBvayAiQVBJOiDRgdC10YDQstC40YEt0Y7Qt9C10YAg0LTQvtCx0LDQstC70LXQvSDQsiBzcXVhZCAkU1FVQURfVVVJRCIKICBlbHNlCiAgICB3YXJuICJBUEkgUEFUQ0ggL3VzZXJzINC90LUg0L/RgNC+0YjRkdC7IOKAlCDQv9GA0LjQvNC10L3RjiDQs9Cw0YDQsNC90YLQuNGOINGH0LXRgNC10Lcg0JHQlCIKICBmaQoKICAjICgyKSDQs9Cw0YDQsNC90YLQuNGPINGH0LXRgNC10Lcg0JHQlDog0YfQu9C10L3RgdGC0LLQviDQsiBzcXVhZCAo0LjQtNC10LzQv9C+0YLQtdC90YLQvdC+KSArINCw0LrRgtC40LLQvdGL0Lkg0YHRgtCw0YLRg9GBLgogICMgICAgIHhyYXkg0LLQutC70Y7Rh9Cw0LXRgiDQsiBjbGllbnRzINGC0L7Qu9GM0LrQviDQsNC60YLQuNCy0L3Ri9GFINGO0LfQtdGA0L7Qsi3Rh9C70LXQvdC+0LIg0L/RgNC40LLRj9C30LDQvdC90L7Qs9C+IHNxdWFkLgogIGlmIGRvY2tlciBleGVjIC1pIHJlbW5hd2F2ZS1kYiBwc3FsIC1VIHBvc3RncmVzIC1kIHBvc3RncmVzIC12IE9OX0VSUk9SX1NUT1A9MSA+L2Rldi9udWxsIDI+JjEgPDxTUUwKSU5TRVJUIElOVE8gaW50ZXJuYWxfc3F1YWRfbWVtYmVycyAoaW50ZXJuYWxfc3F1YWRfdXVpZCwgdXNlcl9pZCkKU0VMRUNUICckU1FVQURfVVVJRCcsICckU0VSVklDRV9VVUlEJwpXSEVSRSBOT1QgRVhJU1RTICgKICBTRUxFQ1QgMSBGUk9NIGludGVybmFsX3NxdWFkX21lbWJlcnMKICAgV0hFUkUgaW50ZXJuYWxfc3F1YWRfdXVpZD0nJFNRVUFEX1VVSUQnIEFORCB1c2VyX2lkPSckU0VSVklDRV9VVUlEJyk7ClNRTAogIHRoZW4KICAgIG9rICLQkdCUOiDRh9C70LXQvdGB0YLQstC+INGB0LXRgNCy0LjRgS3RjtC30LXRgNCwINCyIHNxdWFkINC/0L7QtNGC0LLQtdGA0LbQtNC10L3QviIKICBlbHNlCiAgICB3YXJuICLQkdCULdGE0L7Qu9Cx0Y3QuiDRh9C70LXQvdGB0YLQstCwINC90LUg0L7RgtGA0LDQsdC+0YLQsNC7IOKAlCDQv9GA0L7QstC10YDRjCDRgdGF0LXQvNGDIGludGVybmFsX3NxdWFkX21lbWJlcnMiCiAgZmkKCiAgIyDRhNGD0L3QutGG0LjRjyDQv9GA0L7QstC10YDQutC4OiDQv9GA0LjRgdGD0YLRgdGC0LLRg9C10YIg0LvQuCBTRVJWSUNFX1VVSUQg0LIg0LbQuNCy0L7QvCDQutC+0L3RhNC40LPQtSBleGl0LdC90L7QtNGLCiAgX3V1aWRfaW5fZXhpdCgpewogICAgZG9ja2VyIGV4ZWMgcmVtbmFub2RlIHB5dGhvbjMgLSAiJDEiIDI+L2Rldi9udWxsIDw8J1BZJwppbXBvcnQgc3lzLGpzb24sb3MsZ2xvYixodHRwLmNsaWVudCxzb2NrZXQKd2FudD1zeXMuYXJndlsxXQpzb2Nrcz1nbG9iLmdsb2IoJy9ydW4vcmVtbmF3YXZlLWludGVybmFsLSouc29jaycpCmlmIG5vdCBzb2Nrczogc3lzLmV4aXQoMikKcGlkPShvcy5wb3BlbigncGdyZXAgcnctY29yZScpLnJlYWQoKS5zdHJpcCgpIG9yICcwJykuc3BsaXQoKVswXQp0b2s9JycKdHJ5OgogIGZvciBwIGluIG9wZW4oJy9wcm9jLyVzL2NtZGxpbmUnJXBpZCkucmVhZCgpLnNwbGl0KCdceDAwJyk6CiAgICBpZiAndG9rZW49JyBpbiBwOiB0b2s9cC5zcGxpdCgndG9rZW49JywxKVsxXTsgYnJlYWsKZXhjZXB0IEV4Y2VwdGlvbjogc3lzLmV4aXQoMikKY2xhc3MgVShodHRwLmNsaWVudC5IVFRQQ29ubmVjdGlvbik6CiAgZGVmIF9faW5pdF9fKHMscCk6IHN1cGVyKCkuX19pbml0X18oJ2xvY2FsaG9zdCcpOyBzLnA9cAogIGRlZiBjb25uZWN0KHMpOgogICAgc289c29ja2V0LnNvY2tldChzb2NrZXQuQUZfVU5JWCxzb2NrZXQuU09DS19TVFJFQU0pOyBzby5jb25uZWN0KHMucCk7IHMuc29jaz1zbwp0cnk6CiAgYz1VKHNvY2tzWzBdKTsgYy5yZXF1ZXN0KCdHRVQnLCcvaW50ZXJuYWwvZ2V0LWNvbmZpZz90b2tlbj0nK3RvaykKICBjZmc9anNvbi5sb2FkcyhjLmdldHJlc3BvbnNlKCkucmVhZCgpKQpleGNlcHQgRXhjZXB0aW9uOiBzeXMuZXhpdCgyKQpmb3IgaSBpbiBjZmcuZ2V0KCdpbmJvdW5kcycsW10pOgogIGZvciBjbCBpbiBpLmdldCgnc2V0dGluZ3MnLHt9KS5nZXQoJ2NsaWVudHMnLFtdKToKICAgIGlmIGNsLmdldCgnaWQnKT09d2FudDogc3lzLmV4aXQoMCkKc3lzLmV4aXQoMSkKUFkKICB9CgogICMgKDMpINC/0LXRgNCy0LjRh9C90LDRjyDQv9GA0L7QstC10YDQutCwOiDQttC00ZHQvCDQsNCy0YLQvi3Qv9GD0Ygg0L/QsNC90LXQu9C4ICjQtNC+IDMw0YEpCiAgbG9nICLQn9GA0L7QstC10YDRj9GOLCDRh9GC0L4g0LrQsNGB0LrQsNC0LdGO0LfQtdGAINC/0L7Qv9Cw0Lsg0LIg0LjQvdCx0LDRg9C90LTRiyAkRVhJVF9OQU1FICjQsNCy0YLQvi3Qv9GD0Ygg0L/QsNC90LXQu9C4KeKApiIKICBfc2Vlbj0wCiAgZm9yIF9pIGluIDEgMiAzIDQgNSA2OyBkbyBfdXVpZF9pbl9leGl0ICIkU0VSVklDRV9VVUlEIiAmJiB7IF9zZWVuPTE7IGJyZWFrOyB9OyBzbGVlcCA1OyBkb25lCgogICMgKDQpIHNlbGYtaGVhbDog0LXRgdC70Lgg0L3QtSDQv9C+0Y/QstC40LvRgdGPIOKAlCDRhNC+0YDRgdC40LwgZXhpdC3QvdC+0LTRgyDQv9C10YDQtdGH0LjRgtCw0YLRjCDQutC+0L3RhNC40LMKICBpZiBbICIkX3NlZW4iID0gMCBdOyB0aGVuCiAgICB3YXJuICLQt9CwIDMw0YEg0L3QtSDQv9C+0Y/QstC40LvRgdGPIOKAlCDRhNC+0YDRgdC40YDRg9GOINC+0LHQvdC+0LLQu9C10L3QuNC1INC60L7QvdGE0LjQs9CwIGV4aXQt0L3QvtC00YsgJEVYSVRfTkFNRSIKICAgIEVYSVRfTk9ERV9VVUlEPSIkKGFwaSBHRVQgL25vZGVzIDI+L2Rldi9udWxsIHwgcHl0aG9uMyAtICIkRVhJVF9OQU1FIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnRyeToKICBkPWpzb24ubG9hZHMoc3lzLnN0ZGluLnJlYWQoKSk7IHI9ZC5nZXQoInJlc3BvbnNlIixkKQogIGFycj1yLmdldCgibm9kZXMiKSBpZiBpc2luc3RhbmNlKHIsZGljdCkgZWxzZSAociBpZiBpc2luc3RhbmNlKHIsbGlzdCkgZWxzZSBbXSkKICBwcmludChuZXh0KChuLmdldCgidXVpZCIpIGZvciBuIGluIChhcnIgb3IgW10pIGlmIGlzaW5zdGFuY2UobixkaWN0KSBhbmQgbi5nZXQoIm5hbWUiKT09c3lzLmFyZ3ZbMV0pLCIiKSkKZXhjZXB0IEV4Y2VwdGlvbjogcHJpbnQoIiIpClBZCikiCiAgICBfa2lja2VkPTAKICAgIGlmIFsgLW4gIiRFWElUX05PREVfVVVJRCIgXTsgdGhlbgogICAgICBhcGkgUE9TVCAiL25vZGVzLyRFWElUX05PREVfVVVJRC9hY3Rpb25zL3Jlc3RhcnQiID4vZGV2L251bGwgMj4mMSAmJiB7IF9raWNrZWQ9MTsgb2sgImV4aXQt0L3QvtC00LAg0L/QtdGA0LXQt9Cw0L/Rg9GJ0LXQvdCwINGH0LXRgNC10LcgQVBJIjsgfQogICAgZmkKICAgIFsgIiRfa2lja2VkIiA9IDAgXSAmJiB7IGRvY2tlciByZXN0YXJ0IHJlbW5hbm9kZSA+L2Rldi9udWxsIDI+JjEgJiYgb2sgImV4aXQt0L3QvtC00LAgKHJlbW5hbm9kZSkg0L/QtdGA0LXQt9Cw0L/Rg9GJ0LXQvdCwINC70L7QutCw0LvRjNC90L4iIHx8IHdhcm4gItC90LUg0YHQvNC+0LMg0L/QtdGA0LXQt9Cw0L/Rg9GB0YLQuNGC0YwgZXhpdC3QvdC+0LTRgyI7IH0KICAgICMg0LbQtNGR0Lwg0L/QvtC00YrRkdC80LAg0L3QvtC00Ysg0Lgg0L/QvtCy0YLQvtGA0L3QviDQv9GA0L7QstC10YDRj9C10LwgKNC00L4gNzXRgSkKICAgIGZvciBfaSBpbiAkKHNlcSAxIDE1KTsgZG8gX3V1aWRfaW5fZXhpdCAiJFNFUlZJQ0VfVVVJRCIgJiYgeyBfc2Vlbj0xOyBicmVhazsgfTsgc2xlZXAgNTsgZG9uZQogIGZpCgogICMgKDUpINC40YLQvtCzINC60LDRgdC60LDQtNCwCiAgaWYgWyAiJF9zZWVuIiA9IDEgXTsgdGhlbgogICAgb2sgItCa0JDQodCa0JDQlCDQntCaOiAkU0VSVklDRV9VVUlEINC/0YDQuNGB0YPRgtGB0YLQstGD0LXRgiDQsiDQuNC90LHQsNGD0L3QtNCw0YUgJEVYSVRfTkFNRSDigJQgdmlhLSRSRUxBWV9OQU1FINC30LDRgNCw0LHQvtGC0LDQtdGCIgogIGVsc2UKICAgIHdhcm4gItGB0LXRgNCy0LjRgS3RjtC30LXRgCDQstGB0ZEg0LXRidGRINC90LUg0LLQuNC00LXQvSDQsiDQuNC90LHQsNGD0L3QtNCw0YUgJEVYSVRfTkFNRSDigJQg0LrQsNGB0LrQsNC0INCd0JUg0LfQsNGA0LDQsdC+0YLQsNC10YIiCiAgICB3YXJuICLQtNC40LDQs9C90L7RgdGC0LjQutCwOiBkb2NrZXIgZXhlYyByZW1uYXdhdmUtZGIgcHNxbCAtVSBwb3N0Z3JlcyAtZCBwb3N0Z3JlcyAtYyBcIlNFTEVDVCAqIEZST00gaW50ZXJuYWxfc3F1YWRfbWVtYmVycyBXSEVSRSB1c2VyX2lkPSckU0VSVklDRV9VVUlEJztcIiIKICBmaQpmaQojIOKUgOKUgCA0LiBTRUNSRVRfS0VZIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsb2cgIlNFQ1JFVF9LRVkg0LTQu9GPICRSRUxBWV9OQU1FIgpORElSPSIvb3B0LyRTTFVHIjsgbWtkaXIgLXAgIiRORElSIgpTRUNSRVRfS0VZPSIiCiMg0KfQuNGB0YLRi9C5IHJlLXJ1bjog0L/QtdGA0LXQuNGB0L/QvtC70YzQt9GD0LXQvCDRgdGD0YnQtdGB0YLQstGD0Y7RidC40LkgU0VDUkVUX0tFWSwg0YfRgtC+0LHRiyDRg9C20LUg0YDQsNC30LLRkdGA0L3Rg9GC0LDRjwojINC90L7QtNCwICRSRUxBWV9OQU1FINC90LUg0L7RgtCy0LDQu9C40LvQsNGB0Ywg0Lgg0L3QtSDRgtGA0LXQsdC+0LLQsNC70YHRjyDQv9C+0LLRgtC+0YDQvdGL0Lkgc2V0dXAtcmVsYXktc3NoLnNoLgpmb3IgX2YgaW4gIiRORElSL25vZGUtJHtSRUxBWV9OQU1FfS5lbnYiICIkTkRJUi9yZWxheS1ib290c3RyYXAuZW52IjsgZG8KICBpZiBbIC1mICIkX2YiIF07IHRoZW4KICAgIF9rPSIkKGdyZXAgJ15TRUNSRVRfS0VZPScgIiRfZiIgfCBjdXQgLWQ9IC1mMi0pIgogICAgWyAtbiAiJF9rIiBdICYmIHsgU0VDUkVUX0tFWT0iJF9rIjsgb2sgIlNFQ1JFVF9LRVkg0L/QtdGA0LXQuNGB0L/QvtC70YzQt9C+0LLQsNC9INC40LcgJChiYXNlbmFtZSAiJF9mIikgKNC00LvQuNC90LAgJHsjU0VDUkVUX0tFWX0pIjsgYnJlYWs7IH0KICBmaQpkb25lCmlmIFsgLXogIiRTRUNSRVRfS0VZIiBdOyB0aGVuCiAga2c9IiQoYXBpIEdFVCAva2V5Z2VuKSIgfHwgd2FybiAia2V5Z2VuINC90LUg0L7RgtCy0LXRgtC40LsiCiAgZm9yIGYgaW4gcmVzcG9uc2UucHViS2V5IHJlc3BvbnNlLnNlY3JldEtleSByZXNwb25zZS5jZXJ0IHB1YktleSBzZWNyZXRLZXk7IGRvCiAgICBTRUNSRVRfS0VZPSIkKGp2YWwgIiRrZyIgIiRmIiAyPi9kZXYvbnVsbCkiOyBbIC1uICIkU0VDUkVUX0tFWSIgXSAmJiBicmVhawogIGRvbmUKICBbIC1uICIkU0VDUkVUX0tFWSIgXSB8fCBkaWUgItC90LUg0L/QvtC70YPRh9C40LsgU0VDUkVUX0tFWSDQuNC3IGtleWdlbiIKICBvayAiU0VDUkVUX0tFWSDQv9C+0LvRg9GH0LXQvSDQuNC3IGtleWdlbiAo0LTQu9C40L3QsCAkeyNTRUNSRVRfS0VZfSkiCmZpCnByaW50ZiAnTk9ERV9QT1JUPSVzXG5TRUNSRVRfS0VZPSVzXG4nICIkTk9ERV9QT1JUIiAiJFNFQ1JFVF9LRVkiID4gIiRORElSL25vZGUtJHtSRUxBWV9OQU1FfS5lbnYiCm9rICJTRUNSRVRfS0VZINC30LDQv9C40YHQsNC9INCyICRORElSL25vZGUtJHtSRUxBWV9OQU1FfS5lbnYgKNC00LvQuNC90LAgJHsjU0VDUkVUX0tFWX0pIgoKIyDilIDilIAgNS4gcmVsYXktYm9vdHN0cmFwLmVudiDihpIg0L3QsCBTdW5zaGluZSDRh9C10YDQtdC3IFNDUCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICLQn9Cw0LrRg9GOIHJlbGF5LWJvb3RzdHJhcC5lbnYiCmNhdCA+ICIvb3B0LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiIDw8RU9GCiMg0JDQstGC0L7Qs9C10L3QtdGA0LjRgNC+0LLQsNC90L4gcHJvdmlzaW9uLXJlbGF5LnNoIOKAlCDQvdC1INGA0LXQtNCw0LrRgtC40YDQvtCy0LDRgtGMINCy0YDRg9GH0L3Rg9GOClNMVUc9JFNMVUcKUkVMQVlfTkFNRT0kUkVMQVlfTkFNRQpSRUxBWV9ET01BSU49JFJFTEFZX0RPTUFJTgpFWElUX05BTUU9JEVYSVRfTkFNRQpFWElUX0lQPSRNT09OX0lQCk1BSU5fRE9NQUlOPSRNQUlOX0RPTUFJTgpNT09OX1BVQktFWT0kTU9PTl9QVUJLRVkKTU9PTl9TSE9SVElEPSRNT09OX1NIT1JUSUQKTU9PTl9JUD0kTU9PTl9JUApTRVJWSUNFX1VVSUQ9JFNFUlZJQ0VfVVVJRApSRUxBWV9OT0RFX1VVSUQ9JFJFTEFZX05PREVfVVVJRApSRUxBWV9QUklWPSRSRUxBWV9QUklWClJFTEFZX1BVQj0kUkVMQVlfUFVCClJFTEFZX1NJRD0kUkVMQVlfU0lECldTX1BBVEg9JFdTX1BBVEgKWEhUVFBfUEFUSD0kWEhUVFBfUEFUSApOT0RFX1BPUlQ9JE5PREVfUE9SVApTRUNSRVRfS0VZPSRTRUNSRVRfS0VZCkVPRgpvayAicmVsYXktYm9vdHN0cmFwLmVudiDQs9C+0YLQvtCyOiAvb3B0LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiCgojIOKUgOKUgCA2LiDQpdC+0YHRgtGLIHZpYSBTdW5zaGluZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICLQodC+0LfQtNCw0Y4v0L7QsdC90L7QstC70Y/RjiDRhdC+0YHRgtGLIHZpYSAkUkVMQVlfTkFNRSIKX2FsbF9ob3N0cz0iJChhcGkgR0VUIC9ob3N0cyAyPi9kZXYvbnVsbCkiIHx8IF9hbGxfaG9zdHM9IiIKX2lkeD0wCmZvciB0YWdfc3VmZml4IGluIFJFQUxJVFkgV1MgWEhUVFAgSFkyOyBkbwogIElOX1VVSUQ9IiQocHl0aG9uMyAtYyAiaW1wb3J0IGpzb247IGE9anNvbi5sb2FkcygnJFJFTEFZX0lOX1VVSURTJyk7IHByaW50KGFbJF9pZHhdIGlmIGxlbihhKT4kX2lkeCBlbHNlICcnKSIgMj4vZGV2L251bGwpIiB8fCBJTl9VVUlEPSIiCiAgWyAteiAiJElOX1VVSUQiIF0gJiYgeyBfaWR4PSQoKF9pZHgrMSkpOyBjb250aW51ZTsgfQogIGNhc2UgIiR0YWdfc3VmZml4IiBpbgogICAgUkVBTElUWSkgX3JlbWFyaz0idmlhICR7UkVMQVlfTkFNRX0gwrcgVkxFU1MtUkVBTElUWSIKICAgICAgICAgICAgIF9ib2R5PSJ7XCJyZW1hcmtcIjpcIiRfcmVtYXJrXCIsXCJhZGRyZXNzXCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJwb3J0XCI6NDQzLAogICAgICAgICAgICAgICBcImluYm91bmRcIjp7XCJjb25maWdQcm9maWxlVXVpZFwiOlwiJFJFTEFZX1BST0ZJTEVfVVVJRFwiLFwiY29uZmlnUHJvZmlsZUluYm91bmRVdWlkXCI6XCIkSU5fVVVJRFwifSwKICAgICAgICAgICAgICAgXCJzZWN1cml0eVwiOlwiREVGQVVMVFwiLFwic25pXCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJmaW5nZXJwcmludFwiOlwiY2hyb21lXCIsCiAgICAgICAgICAgICAgIFwicHVibGljS2V5XCI6XCIkUkVMQVlfUFVCXCIsXCJzaG9ydElkXCI6XCIkUkVMQVlfU0lEXCJ9IiA7OwogICAgV1MpICAgICAgX3JlbWFyaz0idmlhICR7UkVMQVlfTkFNRX0gwrcgVkxFU1MtV1MiCiAgICAgICAgICAgICBfYm9keT0ie1wicmVtYXJrXCI6XCIkX3JlbWFya1wiLFwiYWRkcmVzc1wiOlwiJFJFTEFZX0RPTUFJTlwiLFwicG9ydFwiOjQ0MywKICAgICAgICAgICAgICAgXCJpbmJvdW5kXCI6e1wiY29uZmlnUHJvZmlsZVV1aWRcIjpcIiRSRUxBWV9QUk9GSUxFX1VVSURcIixcImNvbmZpZ1Byb2ZpbGVJbmJvdW5kVXVpZFwiOlwiJElOX1VVSURcIn0sCiAgICAgICAgICAgICAgIFwic2VjdXJpdHlcIjpcIlRMU1wiLFwic25pXCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJob3N0XCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJwYXRoXCI6XCIkV1NfUEFUSFwifSIgOzsKICAgIFhIVFRQKSAgIF9yZW1hcms9InZpYSAke1JFTEFZX05BTUV9IMK3IFZMRVNTLVhIVFRQIgogICAgICAgICAgICAgX2JvZHk9IntcInJlbWFya1wiOlwiJF9yZW1hcmtcIixcImFkZHJlc3NcIjpcIiRSRUxBWV9ET01BSU5cIixcInBvcnRcIjoyMDgzLAogICAgICAgICAgICAgICBcImluYm91bmRcIjp7XCJjb25maWdQcm9maWxlVXVpZFwiOlwiJFJFTEFZX1BST0ZJTEVfVVVJRFwiLFwiY29uZmlnUHJvZmlsZUluYm91bmRVdWlkXCI6XCIkSU5fVVVJRFwifSwKICAgICAgICAgICAgICAgXCJzZWN1cml0eVwiOlwiREVGQVVMVFwiLFwic25pXCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJmaW5nZXJwcmludFwiOlwiY2hyb21lXCIsCiAgICAgICAgICAgICAgIFwicHVibGljS2V5XCI6XCIkUkVMQVlfUFVCXCIsXCJzaG9ydElkXCI6XCIkUkVMQVlfU0lEXCIsXCJwYXRoXCI6XCIkWEhUVFBfUEFUSFwifSIgOzsKICAgIEhZMikgICAgIF9yZW1hcms9InZpYSAke1JFTEFZX05BTUV9IMK3IEh5c3RlcmlhMiIKICAgICAgICAgICAgIF9ib2R5PSJ7XCJyZW1hcmtcIjpcIiRfcmVtYXJrXCIsXCJhZGRyZXNzXCI6XCIkUkVMQVlfRE9NQUlOXCIsXCJwb3J0XCI6NDQzLAogICAgICAgICAgICAgICBcImluYm91bmRcIjp7XCJjb25maWdQcm9maWxlVXVpZFwiOlwiJFJFTEFZX1BST0ZJTEVfVVVJRFwiLFwiY29uZmlnUHJvZmlsZUluYm91bmRVdWlkXCI6XCIkSU5fVVVJRFwifSwKICAgICAgICAgICAgICAgXCJzZWN1cml0eVwiOlwiVExTXCIsXCJzbmlcIjpcIiRSRUxBWV9ET01BSU5cIixcImFscG5cIjpcImgzXCJ9IiA7OwogIGVzYWMKICAjINGD0LTQsNC70Y/QtdC8INGB0YLQsNGA0YvQuSDRhdC+0YHRgiDRgSDRgtC10Lwg0LbQtSByZW1hcmsg0L/QtdGA0LXQtCDRgdC+0LfQtNCw0L3QuNC10LwgKNGH0YLQvtCx0Ysg0L7QsdC90L7QstC40YLRjCBpbmJvdW5kIFVVSUQpCiAgX29sZF9ob3N0X3V1aWQ9IiQocHl0aG9uMyAtICIkX2FsbF9ob3N0cyIgIiRfcmVtYXJrIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnRyeToKICBkPWpzb24ubG9hZHMoc3lzLmFyZ3ZbMV0pOyByPWQuZ2V0KCJyZXNwb25zZSIsZCkKICBhcnI9ci5nZXQoImhvc3RzIixyKSBpZiBpc2luc3RhbmNlKHIsZGljdCkgZWxzZSByCiAgaWYgbm90IGlzaW5zdGFuY2UoYXJyLGxpc3QpOiBhcnI9W10KICBwcmludChuZXh0KChoLmdldCgidXVpZCIpIGZvciBoIGluIGFyciBpZiBpc2luc3RhbmNlKGgsZGljdCkgYW5kIGguZ2V0KCJyZW1hcmsiKT09c3lzLmFyZ3ZbMl0pLCIiKSkKZXhjZXB0IEV4Y2VwdGlvbjogcHJpbnQoIiIpClBZCikiCiAgWyAtbiAiJF9vbGRfaG9zdF91dWlkIiBdICYmIHsgYXBpIERFTEVURSAiL2hvc3RzLyRfb2xkX2hvc3RfdXVpZCIgPi9kZXYvbnVsbCAyPiYxIFwKICAgICYmIG9rICLRgdGC0LDRgNGL0Lkg0YXQvtGB0YIg0YPQtNCw0LvRkdC9OiAkX3JlbWFyayIgXAogICAgfHwgd2FybiAi0L3QtSDRg9C00LDQu9C+0YHRjCDRg9C00LDQu9C40YLRjCDRgdGC0LDRgNGL0Lkg0YXQvtGB0YIgJF9vbGRfaG9zdF91dWlkIjsgfQogIGFwaSBQT1NUIC9ob3N0cyAiJF9ib2R5IiA+L2Rldi9udWxsIDI+JjEgXAogICAgJiYgb2sgItGF0L7RgdGCINGB0L7Qt9C00LDQvTogJF9yZW1hcmsiIFwKICAgIHx8IHdhcm4gItC90LUg0YPQtNCw0LvQvtGB0Ywg0YHQvtC30LTQsNGC0Ywg0YXQvtGB0YIgJyRfcmVtYXJrJyIKICBfaWR4PSQoKF9pZHgrMSkpCmRvbmUKCmVjaG8KZWNobyAi4pWQ4pWQ4pWQ4pWQINCT0J7QotCe0JLQniDilZDilZDilZDilZAiCmVjaG8gIiAgcmVsYXktYm9vdHN0cmFwLmVudjogL29wdC8kU0xVRy9yZWxheS1ib290c3RyYXAuZW52IgplY2hvICIgINCh0LvQtdC00YPRjtGJ0LjQuSDRiNCw0LM6IHNldHVwLXJlbGF5LXNzaC5zaCDRgdC60L7Qv9C40YDRg9C10YIg0LXQs9C+INC90LAgJFJFTEFZX05BTUUg0Lgg0LfQsNC/0YPRgdGC0LjRgiDQtNC10L/Qu9C+0LkiCg==
__B64__
  base64 -d > "$d/provision.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHByb3Zpc2lvbi5zaCDigJQgaGVhZGxlc3Mt0L3QsNGB0YLR
gNC+0LnQutCwIFJlbW5hd2F2ZSAyLjcueCDQsdC10Lcg0LfQsNGF0L7QtNCwINCyINC/0LDQvdC1
0LvRjC4KIyBhZG1pbiAoYXV0b2dlbiDQuNC70Lgg0LjQtyBjcmVkLdGE0LDQudC70LApIOKGkiBB
UEkt0YLQvtC60LXQvSDihpIgY29uZmlnLXByb2ZpbGUg4oaSINC90L7QtNCwIOKGkgojIGludGVy
bmFsIHNxdWFkIOKGkiDQv9C+0LvRjNC30L7QstCw0YLQtdC70YwgIlRlc3QiIOKGkiDQv9C+0LTQ
v9C40YHQutCwLgojCiMg0JfQsNC/0YPRgdC6OiAgc3VkbyBiYXNoIHByb3Zpc2lvbi5zaCAgICjQ
v9C+0YDRgiA0NDMvODQ0MyDQvtC/0YDQtdC00LXQu9GP0LXRgtGB0Y8g0YHQsNC8KQpzZXQgLXUK
SEVSRT0iJChjZCAiJChkaXJuYW1lICIkMCIpIiAmJiBwd2QpIgpbIC1mICIkSEVSRS9wcm92aXNp
b24uY29uZiIgXSAmJiAuICIkSEVSRS9wcm92aXNpb24uY29uZiIKClNMVUc9IiR7U0xVRzotbXlj
bG91ZH0iCkRPTUFJTj0iJHtET01BSU46LWNsb3VkLmV4YW1wbGUuY29tfSIKQVBJX1BPUlQ9IiR7
QVBJX1BPUlQ6LX0iICAgICAgICAgICAgICAgICAgICAgICAjINC/0YPRgdGC0L4gPSDQsNCy0YLQ
vtC+0L/RgNC10LTQtdC70LXQvdC40LUgNDQzLzg0NDMKTk9ERV9OQU1FPSIke05PREVfTkFNRTot
TW9vbmxpZ2h0fSIKTk9ERV9BRERSRVNTPSIke05PREVfQUREUkVTUzotJChob3N0bmFtZSAtSSAy
Pi9kZXYvbnVsbCB8IGF3ayAne3ByaW50ICQxfScpfSI7IFsgLW4gIiROT0RFX0FERFJFU1MiIF0g
fHwgTk9ERV9BRERSRVNTPSIxMjcuMC4wLjEiCk5PREVfUE9SVD0iJHtOT0RFX1BPUlQ6LTIyMjJ9
IgpQUk9GSUxFX05BTUU9IiR7UFJPRklMRV9OQU1FOi0ke05PREVfTkFNRX0tcHJvZmlsZX0iClNR
VUFEX05BTUU9IiR7U1FVQURfTkFNRTotbWFpbn0iClRFU1RfVVNFUj0iJHtURVNUX1VTRVI6LVRl
c3R9IgpYUkFZX0NPTkZJR19GSUxFPSIke1hSQVlfQ09ORklHX0ZJTEU6LS9vcHQvJFNMVUcvbm9k
ZS94cmF5LXByb2ZpbGUuanNvbn0iClJFQUxJVFlfRU5WX0ZJTEU9IiR7UkVBTElUWV9FTlZfRklM
RTotL29wdC8kU0xVRy9ub2RlL3JlYWxpdHkuZW52fSIKUkVBTElUWV9QVUJMSUNfS0VZPSIiOyBS
RUFMSVRZX1NIT1JUX0lEPSIiCmlmIFsgLWYgIiRSRUFMSVRZX0VOVl9GSUxFIiBdOyB0aGVuCiAg
UkVBTElUWV9QVUJMSUNfS0VZPSIkKGdyZXAgJ15SRUFMSVRZX1BVQkxJQ19LRVk9JyAiJFJFQUxJ
VFlfRU5WX0ZJTEUiIHwgY3V0IC1kPSAtZjIpIgogIFJFQUxJVFlfU0hPUlRfSUQ9IiQoZ3JlcCAn
XlJFQUxJVFlfU0hPUlRfSUQ9JyAiJFJFQUxJVFlfRU5WX0ZJTEUiIHwgY3V0IC1kPSAtZjIpIgpm
aQpDUkVEX0ZJTEU9IiR7Q1JFRF9GSUxFOi0vb3B0LyRTTFVHL2NyZWRlbnRpYWxzLnR4dH0iClVT
RV9UQUlMU0NBTEU9IiR7VVNFX1RBSUxTQ0FMRTotbm99IgpUT0tFTl9OQU1FPSIke1RPS0VOX05B
TUU6LXByb3Zpc2lvbn0iClJFTU5BV0FWRV9UT0tFTj0iJHtSRU1OQVdBVkVfVE9LRU46LX0iICAg
IyBBUEkt0YLQvtC60LXQvSDQuNC3INC00LDRiNCx0L7RgNC00LA7INC10YHQu9C4INC30LDQtNCw
0L0g4oCUIGF1dGgg0L/RgNC+0L/Rg9GB0LrQsNC10YLRgdGPCgpjKCl7IHByaW50ZiAnXDAzM1sl
c20lc1wwMzNbMG0nICIkMSIgIiQyIjsgfQpsb2coKXsgZWNobzsgZWNobyAiJChjICcxOzM2JyAn
4pa2JykgJCoiOyB9Cm9rKCl7IGVjaG8gIiAgJChjICcxOzMyJyAn4pyTJykgJCoiOyB9Cndhcm4o
KXsgZWNobyAiICAkKGMgJzE7MzMnICchJykgJCoiOyB9CmRpZSgpeyBlY2hvICIgICQoYyAnMTsz
MScgJ+KclycpICQqIiA+JjI7IGV4aXQgMTsgfQpuZWVkKCl7IGNvbW1hbmQgLXYgIiQxIiA+L2Rl
di9udWxsIDI+JjEgfHwgZGllICLQvdC10YIgJDEiOyB9Cm5lZWQgY3VybDsgbmVlZCBvcGVuc3Ns
OyBuZWVkIHB5dGhvbjMKCiMg0LvQvtCz0LjQvS/Qv9Cw0YDQvtC70Ywg0LDQtNC80LjQvdCwOiBl
bnYg4oaSIGNyZWQt0YTQsNC50Lsg4oaSIGF1dG9nZW4KQURNSU5fVVNFUj0iJHtBRE1JTl9VU0VS
Oi19IjsgQURNSU5fUEFTUz0iJHtBRE1JTl9QQVNTOi19IgppZiBbIC16ICIkQURNSU5fUEFTUyIg
XSAmJiBbIC1mICIkQ1JFRF9GSUxFIiBdOyB0aGVuCiAgWyAteiAiJEFETUlOX1VTRVIiIF0gJiYg
QURNSU5fVVNFUj0iJChncmVwIC1FICdeXHMqdXNlcjonICIkQ1JFRF9GSUxFIiB8IGF3ayAne3By
aW50ICQyfScgfCBoZWFkIC0xKSIKICBBRE1JTl9QQVNTPSIkKGdyZXAgLUUgJ15ccypwYXNzOicg
IiRDUkVEX0ZJTEUiIHwgYXdrICd7cHJpbnQgJDJ9JyB8IGhlYWQgLTEpIgogIFsgLW4gIiRBRE1J
Tl9QQVNTIiBdICYmIG9rICLQv9Cw0YDQvtC70Ywg0LDQtNC80LjQvdCwINCy0LfRj9GCINC40Lcg
JENSRURfRklMRSIKZmkKWyAteiAiJEFETUlOX1VTRVIiIF0gJiYgQURNSU5fVVNFUj0iYWRtaW4i
CkdFTkVSQVRFRD0wCmlmIFsgLXogIiRBRE1JTl9QQVNTIiBdOyB0aGVuCiAgQURNSU5fUEFTUz0i
JChvcGVuc3NsIHJhbmQgLWJhc2U2NCAxOCB8IHRyIC1kICcvKz0nIHwgY3V0IC1jMS0yMClBYTEh
IjsgR0VORVJBVEVEPTEKZmkKCiMganZhbCAnPGpzb24+JyBrZXkuc3Via2V5Cmp2YWwoKXsgcHl0
aG9uMyAtICIkMSIgIiQyIiA8PCdQWScgMj4vZGV2L251bGwKaW1wb3J0IHN5cyxqc29uCnRyeTog
ZD1qc29uLmxvYWRzKHN5cy5hcmd2WzFdKQpleGNlcHQgRXhjZXB0aW9uOiBzeXMuZXhpdCgxKQpm
b3IgayBpbiBzeXMuYXJndlsyXS5zcGxpdCgnLicpOgogICAgaWYgaXNpbnN0YW5jZShkLGxpc3Qp
OgogICAgICAgIHRyeTogZD1kW2ludChrKV0KICAgICAgICBleGNlcHQgRXhjZXB0aW9uOiBzeXMu
ZXhpdCgxKQogICAgZWxpZiBpc2luc3RhbmNlKGQsZGljdCk6IGQ9ZC5nZXQoaykKICAgIGVsc2U6
IHN5cy5leGl0KDEpCiAgICBpZiBkIGlzIE5vbmU6IHN5cy5leGl0KDEpCnByaW50KGQgaWYgbm90
IGlzaW5zdGFuY2UoZCwoZGljdCxsaXN0KSkgZWxzZSBqc29uLmR1bXBzKGQpKQpQWQp9CgojINC8
0LDRgNGI0YDRg9GCINC6IEFQSSDQv9Cw0L3QtdC70Lg6IFJFU09MVkVfQVJHUyDQv9GD0YHRgtC+
ID0g0LLQvdGD0YLRgNC10L3QvdC40LkgaHR0cHM6Ly9sb2NhbGhvc3Q6ODA4MQojIChDYWRkeSB0
bHMtaW50ZXJuYWwg4oaSINC/0LDQvdC10LvRjDozMDAwLCDRgdGD0YnQtdGB0YLQstGD0LXRgiDQ
otCe0JvQrNCa0J4g0L/QvtGB0LvQtSDRgdGC0LXQu9GB0LApOyDQuNC90LDRh9C1INC/0YPQsdC7
0LjRh9C90YvQuSA0NDMvODQ0MwpSRVNPTFZFX0FSR1M9KCkKc3RhdHVzX29rKCl7IGxvY2FsIGM7
IGM9IiQoY3VybCAtc1MgLWsgLW8gL2Rldi9udWxsICIke1JFU09MVkVfQVJHU1tAXX0iIC13ICcl
e2h0dHBfY29kZX0nICIke0FQSV9CQVNFfS9hdXRoL3N0YXR1cyIgMj4vZGV2L251bGwpIjsgWyAt
biAiJGMiIF0gJiYgWyAiJGMiIC1nZSAyMDAgXSAyPi9kZXYvbnVsbCAmJiBbICIkYyIgLWx0IDUw
MCBdIDI+L2Rldi9udWxsOyB9CgpUT0tFTj0iIgojIGFwaSBNRVRIT0QgUEFUSCBbYm9keV0g4oaS
IGVjaG8g0YLQtdC70LA7INC90LAg0L7RiNC40LHQutC1INC/0LXRh9Cw0YLQsNC10YIg0LHQu9C+
0Log0LIgc3RkZXJyINC4IHJldHVybiAxCmFwaSgpewogIGxvY2FsIG1ldGhvZD0iJDEiIHBhdGg9
IiQyIiBib2R5PSIkezM6LX0iIHJlc3AgY29kZQogIGxvY2FsIGFyZ3M9KC1zUyAtayAiJHtSRVNP
TFZFX0FSR1NbQF19IgogICAgICAgICAgICAgIC1YICIkbWV0aG9kIiAiJHtBUElfQkFTRX0ke3Bh
dGh9IiAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9qc29uIgogICAgICAgICAgICAgIC1I
ICJYLVJlbW5hd2F2ZS1DbGllbnQtVHlwZTogYnJvd3NlciIpICAgIyDQv9GD0YHQutCw0LXRgiBh
ZG1pbi1KV1Qg0LIgQVBJICjQutCw0Log0LTQsNGI0LHQvtGA0LQpCiAgWyAtbiAiJFRPS0VOIiBd
ICYmIGFyZ3MrPSgtSCAiQXV0aG9yaXphdGlvbjogQmVhcmVyICRUT0tFTiIpCiAgWyAtbiAiJGJv
ZHkiIF0gJiYgYXJncys9KC1kICIkYm9keSIpCiAgcmVzcD0iJChjdXJsICIke2FyZ3NbQF19IiAt
dyAkJ1xuJXtodHRwX2NvZGV9JykiIHx8IHsgZWNobyAiICDinJcgY3VybCDRg9C/0LDQuyDQvdCw
ICRtZXRob2QgJHBhdGgiID4mMjsgcmV0dXJuIDE7IH0KICBjb2RlPSIke3Jlc3AjIyokJ1xuJ30i
OyByZXNwPSIke3Jlc3AlJCdcbicqfSIKICBpZiBbICIkY29kZSIgLWx0IDIwMCBdIHx8IFsgIiRj
b2RlIiAtZ2UgMzAwIF07IHRoZW4KICAgIHsgZWNobzsgZWNobyAiICAhIEFQSSAkbWV0aG9kICRw
YXRoIOKGkiBIVFRQICRjb2RlIjsgZWNobyAiJHJlc3AiIHwgc2VkICdzL14vICAgIC8nOyB9ID4m
MgogICAgcmV0dXJuIDEKICBmaQogIHByaW50ZiAnJXMnICIkcmVzcCIKfQoKIyDilIDilIAgMC4g
0LzQsNGA0YjRgNGD0YIg0Log0L/QsNC90LXQu9C4ICsg0L7QttC40LTQsNC90LjQtSDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIAKbG9nICLQmNGJ0YMg0L/QsNC90LXQu9GMICgkRE9NQUlOKeKApiIKIyDQn9Cw0L3Q
tdC70Ywg0YLRgNC10LHRg9C10YIg0LfQsNCz0L7Qu9C+0LLQutC4IFgtRm9yd2FyZGVkLVByb3Rv
INGH0LXRgNC10LcgQ2FkZHkg4oCUIHBsYWluIEhUVFAg0L3QsCA6MzAwMCDQvdC1INGA0LDQsdC+
0YLQsNC10YIuCiMg0JjRgdC/0L7Qu9GM0LfRg9C10LwgbG9jYWxob3N0OjgwODEgKENhZGR5IHRs
cyBpbnRlcm5hbCkg0LjQu9C4INC/0YPQsdC70LjRh9C90YvQuSA0NDMvODQ0My4KaWYgWyAteiAi
JEFQSV9QT1JUIiBdOyB0aGVuCiAgQVBJX0JBU0U9Imh0dHBzOi8vbG9jYWxob3N0OjgwODEvYXBp
IjsgUkVTT0xWRV9BUkdTPSgpCiAgaWYgc3RhdHVzX29rOyB0aGVuCiAgICBvayAi0L/QsNC90LXQ
u9GMINC/0L4g0LLQvdGD0YLRgNC10L3QvdC10LzRgyDQvNCw0YDRiNGA0YPRgtGDIChsb2NhbGhv
c3Q6ODA4MSwg0LIg0L7QsdGF0L7QtCDRgdGC0LXQu9GB0LApIgogIGVsc2UKICAgIERFVFA9IiIK
ICAgIGZvciBpIGluICQoc2VxIDEgNjApOyBkbwogICAgICBmb3IgcCBpbiA0NDMgODQ0MzsgZG8K
ICAgICAgICBBUElfQkFTRT0iaHR0cHM6Ly8ke0RPTUFJTn06JHtwfS9hcGkiOyBSRVNPTFZFX0FS
R1M9KC0tcmVzb2x2ZSAiJHtET01BSU59OiR7cH06MTI3LjAuMC4xIikKICAgICAgICBzdGF0dXNf
b2sgJiYgeyBERVRQPSIkcCI7IGJyZWFrIDI7IH0KICAgICAgZG9uZQogICAgICBbICIkaSIgPSA2
MCBdICYmIGRpZSAi0L/QsNC90LXQu9GMINC90LUg0L7RgtCy0LXRh9Cw0LXRgjog0L3QuCBsb2Nh
bGhvc3Q6ODA4MSwg0L3QuCDQv9GD0LHQu9C40YfQvdGL0LUgNDQzLzg0NDMgKH4xMjDRgSkiCiAg
ICAgIHNsZWVwIDIKICAgIGRvbmUKICAgIEFQSV9QT1JUPSIkREVUUCI7IG9rICLQv9Cw0L3QtdC7
0Ywg0L3QsCA6JEFQSV9QT1JUICjQv9GD0LHQu9C40YfQvdGL0Lkg0LzQsNGA0YjRgNGD0YIpIgog
IGZpCmVsc2UKICBBUElfQkFTRT0iaHR0cHM6Ly8ke0RPTUFJTn06JHtBUElfUE9SVH0vYXBpIjsg
UkVTT0xWRV9BUkdTPSgtLXJlc29sdmUgIiR7RE9NQUlOfToke0FQSV9QT1JUfToxMjcuMC4wLjEi
KQogIGZvciBpIGluICQoc2VxIDEgNjApOyBkbyBzdGF0dXNfb2sgJiYgYnJlYWs7IFsgIiRpIiA9
IDYwIF0gJiYgZGllICLQv9Cw0L3QtdC70Ywg0L3QtSDQvtGC0LLQtdGH0LDQtdGCINC90LAgOiRB
UElfUE9SVCI7IHNsZWVwIDI7IGRvbmUKICBvayAi0L/QsNC90LXQu9GMINC90LAgOiRBUElfUE9S
VCIKZmkKCiMg4pSA4pSAIDAuNSBTVUJfUFVCTElDX0RPTUFJTjog0L/QvtC00L/QuNGB0LrQuCDQ
tNC+0LvQttC90Ysg0YPQutCw0LfRi9Cy0LDRgtGMINC90LAg0YLQstC+0Lkg0LTQvtC80LXQvSDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKUEVOVj0iL29wdC8kU0xVRy9w
YW5lbC8uZW52IgpXQU5UPSIke0RPTUFJTn0vYXBpL3N1YiIKaWYgWyAtZiAiJFBFTlYiIF0gJiYg
ISBncmVwIC1xICJeU1VCX1BVQkxJQ19ET01BSU49JHtXQU5UfVwkIiAiJFBFTlYiOyB0aGVuCiAg
bG9nICLQp9C40L3RjiBTVUJfUFVCTElDX0RPTUFJTiDihpIgJFdBTlQiCiAgaWYgZ3JlcCAtcSAn
XlNVQl9QVUJMSUNfRE9NQUlOPScgIiRQRU5WIjsgdGhlbgogICAgc2VkIC1pICJzfF5TVUJfUFVC
TElDX0RPTUFJTj0uKnxTVUJfUFVCTElDX0RPTUFJTj0ke1dBTlR9fCIgIiRQRU5WIgogIGVsc2Ug
ZWNobyAiU1VCX1BVQkxJQ19ET01BSU49JHtXQU5UfSIgPj4gIiRQRU5WIjsgZmkKICAoIGNkICIv
b3B0LyRTTFVHL3BhbmVsIiAmJiBkb2NrZXIgY29tcG9zZSBkb3duID4vZGV2L251bGwgMj4mMSAm
JiBkb2NrZXIgY29tcG9zZSB1cCAtZCA+L2Rldi9udWxsIDI+JjEgKSBcCiAgICAmJiBvayAi0L/Q
sNC90LXQu9GMINC/0LXRgNC10YHQvtC30LTQsNC90LAiIHx8IHdhcm4gItC90LUg0YHQvNC+0LMg
0L/QtdGA0LXRgdC+0LfQtNCw0YLRjCDQv9Cw0L3QtdC70Ywg4oCUINC/0YDQvtCy0LXRgNGMIC9v
cHQvJFNMVUcvcGFuZWwiCiAgbG9nICLQltC00YMg0LPQvtGC0L7QstC90L7RgdGC0Lgg0L/QsNC9
0LXQu9C4INC/0L7RgdC70LUg0L/QtdGA0LXRgdC+0LfQtNCw0L3QuNGP4oCmIgogIGZvciBpIGlu
ICQoc2VxIDEgOTApOyBkbyBzdGF0dXNfb2sgJiYgYnJlYWs7IFsgIiRpIiA9IDkwIF0gJiYgZGll
ICLQv9Cw0L3QtdC70Ywg0L3QtSDQvtGC0LTQsNGR0YIgMnh4LTR4eCDQv9C+0YHQu9C1INC/0LXR
gNC10YHQvtC30LTQsNC90LjRjyAo0LLRgdGRINC10YnRkSA1MDI/KSDigJQg0LPQu9GP0L3RjDog
ZG9ja2VyIGxvZ3MgcmVtbmF3YXZlIjsgc2xlZXAgMjsgZG9uZQogIG9rICLQv9Cw0L3QtdC70Ywg
0LPQvtGC0L7QstCwIgpmaQoKIyDilIDilIAgMS4g0LTQvtGB0YLRg9C/INC6IEFQSSDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAK
IyBSZW1uYXdhdmUgMi54INC/0YPRgdC60LDQtdGCIGFkbWluLUpXVCDQsiBBUEkg0L/RgNC4INC3
0LDQs9C+0LvQvtCy0LrQtSBYLVJlbW5hd2F2ZS1DbGllbnQtVHlwZToKIyBicm93c2VyICjQtdCz
0L4g0YjQu9GR0YIg0LTQsNGI0LHQvtGA0LQpIOKAlCDQvtC9INC00L7QsdCw0LLQu9C10L0g0LIg
YXBpKCkuINCd0LjQutCw0LrQvtC5IGRhc2hib2FyZC/RgtC+0LrQtdC9INC90LUg0L3Rg9C20LXQ
vS4KTUFERV9BRE1JTj0wCmlmIFsgLW4gIiRSRU1OQVdBVkVfVE9LRU4iIF07IHRoZW4KICBUT0tF
Tj0iJFJFTU5BV0FWRV9UT0tFTiI7IGxvZyAi0JjRgdC/0L7Qu9GM0LfRg9GOINC/0LXRgNC10LTQ
sNC90L3Ri9C5INGC0L7QutC10L0iCmVsc2UKICBsb2cgItCQ0LTQvNC40L0iCiAgVE9LRU49IiIK
ICBmb3IgdHJ5IGluIDEgMiAzIDQgNSA2OyBkbwogICAgcmVnPSIkKGN1cmwgLXNTIC1rICIke1JF
U09MVkVfQVJHU1tAXX0iIC1YIFBPU1QgIiR7QVBJX0JBU0V9L2F1dGgvcmVnaXN0ZXIiIFwKICAg
ICAgICAgICAgLUggJ0NvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbicgLUggJ1gtUmVtbmF3
YXZlLUNsaWVudC1UeXBlOiBicm93c2VyJyBcCiAgICAgICAgICAgIC1kICJ7XCJ1c2VybmFtZVwi
OlwiJEFETUlOX1VTRVJcIixcInBhc3N3b3JkXCI6XCIkQURNSU5fUEFTU1wifSIgLXcgJCdcbiV7
aHR0cF9jb2RlfScgMj4vZGV2L251bGwpIgogICAgcmNvZGU9IiR7cmVnIyMqJCdcbid9IjsgcmJv
ZHk9IiR7cmVnJSQnXG4nKn0iCiAgICBjYXNlICIkcmNvZGUiIGluCiAgICAgIDIwMHwyMDEpCiAg
ICAgICAgVE9LRU49IiQoanZhbCAiJHJib2R5IiByZXNwb25zZS5hY2Nlc3NUb2tlbikiOyBbIC1u
ICIkVE9LRU4iIF0gfHwgVE9LRU49IiQoanZhbCAiJHJib2R5IiBhY2Nlc3NUb2tlbikiCiAgICAg
ICAgaWYgWyAtbiAiJFRPS0VOIiBdOyB0aGVuCiAgICAgICAgICBta2RpciAtcCAiJChkaXJuYW1l
ICIkQ1JFRF9GSUxFIikiCiAgICAgICAgICB7IGVjaG8gIlJlbW5hd2F2ZSBhZG1pbiI7IGVjaG8g
IiAgdXJsOiAgaHR0cHM6Ly8ke0RPTUFJTn0vIjsgZWNobyAiICB1c2VyOiAkQURNSU5fVVNFUiI7
IGVjaG8gIiAgcGFzczogJEFETUlOX1BBU1MiOyB9ID4gIiRDUkVEX0ZJTEUiCiAgICAgICAgICBj
aG1vZCA2MDAgIiRDUkVEX0ZJTEUiOyBNQURFX0FETUlOPTEKICAgICAgICAgIG9rICLQsNC00LzQ
uNC9ICckQURNSU5fVVNFUicg0YHQvtC30LTQsNC9JChbICRHRU5FUkFURUQgPSAxIF0gJiYgZWNo
byAnICjQv9Cw0YDQvtC70Ywg0LDQstGC0L7Qs9C10L0pJyk7INC00L7RgdGC0YPQv9GLIOKGkiAk
Q1JFRF9GSUxFIgogICAgICAgIGZpCiAgICAgICAgYnJlYWsgOzsKICAgICAgNSp8MDAwfCIiKQog
ICAgICAgIHdhcm4gItC/0LDQvdC10LvRjCDQtdGJ0ZEg0LTQvtCz0YDRg9C20LDQtdGC0YHRjyAo
SFRUUCAke3Jjb2RlOi3QvdC10YIg0L7RgtCy0LXRgtCwfSksINC/0L7QstGC0L7RgCAkdHJ5Lzbi
gKYiOyBzbGVlcCA1OyBjb250aW51ZSA7OwogICAgICAqKQogICAgICAgIGxvZ2luPSIkKGFwaSBQ
T1NUIC9hdXRoL2xvZ2luICJ7XCJ1c2VybmFtZVwiOlwiJEFETUlOX1VTRVJcIixcInBhc3N3b3Jk
XCI6XCIkQURNSU5fUEFTU1wifSIpIiBcCiAgICAgICAgICB8fCB7IFsgJEdFTkVSQVRFRCA9IDEg
XSAmJiBkaWUgItCw0LTQvNC40L0g0YPQttC1INC10YHRgtGMLCDQsCDQv9Cw0YDQvtC70Ywg0LDQ
stGC0L7Qs9C10L3QvdGL0Lkg4oCUINC/0LXRgNC10LTQsNC5IEFETUlOX1BBU1M9PNGC0LLQvtC5
PiAo0YHQvC4gJENSRURfRklMRSkiOyBkaWUgItC70L7Qs9C40L0g0L3QtSDQv9GA0L7RiNGR0Lsg
4oCUINC/0YDQvtCy0LXRgNGMIEFETUlOX1BBU1Mg0LIgJENSRURfRklMRSI7IH0KICAgICAgICBU
T0tFTj0iJChqdmFsICIkbG9naW4iIHJlc3BvbnNlLmFjY2Vzc1Rva2VuKSI7IFsgLW4gIiRUT0tF
TiIgXSB8fCBUT0tFTj0iJChqdmFsICIkbG9naW4iIGFjY2Vzc1Rva2VuKSIKICAgICAgICBvayAi
0LLQvtGI0ZHQuyDRgdGD0YnQtdGB0YLQstGD0Y7RidC40Lwg0LDQtNC80LjQvdC+0LwiCiAgICAg
ICAgYnJlYWsgOzsKICAgIGVzYWMKICBkb25lCmZpClsgLW4gIiRUT0tFTiIgXSB8fCBkaWUgItC9
0LUg0L/QvtC70YPRh9C40Lsg0YLQvtC60LXQvSDigJQg0YHQutC40L3RjCDQvtGC0LLQtdGCIC9h
dXRoL2xvZ2luIgpvayAi0YLQvtC60LXQvSDQv9C+0LvRg9GH0LXQvSwg0YDQsNCx0L7RgtCw0Y4g
0LjQvCAoK9C30LDQs9C+0LvQvtCy0L7QuiBicm93c2VyKSIKCiMg4pSA4pSAIDMuIGNvbmZpZy1w
cm9maWxlIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgCAgIyBWRVJJRlkgcGF5bG9hZApsb2cgIkNvbmZpZy1wcm9maWxlIgpbIC1mICIkWFJB
WV9DT05GSUdfRklMRSIgXSB8fCBkaWUgItC90LXRgiAkWFJBWV9DT05GSUdfRklMRSDigJQg0L/R
gNC+0LLQtdGA0YwgU0xVRy/Qv9GD0YLRjCAo0LrQvtC90YLQtdC50L3QtdGAIGNhZGR5INC/0L7Q
tNGB0LrQsNC20LXRgiBzbHVnOiBkb2NrZXIgcHMgfCBncmVwIGNhZGR5KSIKYm9keT0iJChweXRo
b24zIC0gIiRQUk9GSUxFX05BTUUiICIkWFJBWV9DT05GSUdfRklMRSIgPDwnUFknCmltcG9ydCBz
eXMsanNvbgpwcmludChqc29uLmR1bXBzKHsibmFtZSI6c3lzLmFyZ3ZbMV0sImNvbmZpZyI6anNv
bi5sb2FkKG9wZW4oc3lzLmFyZ3ZbMl0pKX0pKQpQWQopIgpwbGlzdD0iJChhcGkgR0VUIC9jb25m
aWctcHJvZmlsZXMpIiB8fCBkaWUgItGH0YLQtdC90LjQtSDQv9GA0L7RhNC40LvQtdC5IOKAlCDR
gdC60LjQvdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCIKUFJPRklMRV9VVUlEPSIkKHB5dGhvbjMg
LSAiJHBsaXN0IiAiJFBST0ZJTEVfTkFNRSIgPDwnUFknCmltcG9ydCBzeXMsanNvbgpkPWpzb24u
bG9hZHMoc3lzLmFyZ3ZbMV0pOyBhcnI9ZC5nZXQoInJlc3BvbnNlIix7fSkuZ2V0KCJjb25maWdQ
cm9maWxlcyIpIG9yIGQuZ2V0KCJjb25maWdQcm9maWxlcyIpIG9yIChkIGlmIGlzaW5zdGFuY2Uo
ZCxsaXN0KSBlbHNlIFtdKQpwcmludChuZXh0KCh4LmdldCgidXVpZCIpIGZvciB4IGluIGFyciBp
ZiBpc2luc3RhbmNlKHgsZGljdCkgYW5kIHguZ2V0KCJuYW1lIik9PXN5cy5hcmd2WzJdKSwiIikp
ClBZCikiCmlmIFsgLW4gIiRQUk9GSUxFX1VVSUQiIF07IHRoZW4KICBvayAi0L/RgNC+0YTQuNC7
0Ywg0YPQttC1INC10YHRgtGMOiAkUFJPRklMRV9VVUlEIgplbHNlCiAgcHJvZj0iJChhcGkgUE9T
VCAvY29uZmlnLXByb2ZpbGVzICIkYm9keSIpIiB8fCBkaWUgItGB0L7Qt9C00LDQvdC40LUg0L/R
gNC+0YTQuNC70Y8g4oCUINGB0LrQuNC90Ywg0LHQu9C+0Log0L7RiNC40LHQutC4IgogIFBST0ZJ
TEVfVVVJRD0iJChqdmFsICIkcHJvZiIgcmVzcG9uc2UudXVpZCkiOyBbIC1uICIkUFJPRklMRV9V
VUlEIiBdIHx8IFBST0ZJTEVfVVVJRD0iJChqdmFsICIkcHJvZiIgdXVpZCkiCiAgb2sgItC/0YDQ
vtGE0LjQu9GMINGB0L7Qt9C00LDQvTogJFBST0ZJTEVfVVVJRCIKZmkKSU5CPSIkKGFwaSBHRVQg
Ii9jb25maWctcHJvZmlsZXMvJFBST0ZJTEVfVVVJRC9pbmJvdW5kcyIpIiB8fCB0cnVlCklOX1VV
SURTPSIkKHB5dGhvbjMgLSAiJElOQiIgPDwnUFknCmltcG9ydCBzeXMsanNvbgp0cnk6IGE9anNv
bi5sb2FkcyhzeXMuYXJndlsxXSkKZXhjZXB0IEV4Y2VwdGlvbjogYT1bXQphPWEuZ2V0KCJyZXNw
b25zZSIsYSkgaWYgaXNpbnN0YW5jZShhLGRpY3QpIGVsc2UgYQphPWEuZ2V0KCJpbmJvdW5kcyIs
YSkgaWYgaXNpbnN0YW5jZShhLGRpY3QpIGVsc2UgYQppZiBub3QgaXNpbnN0YW5jZShhLGxpc3Qp
OiBhPVtdCnByaW50KGpzb24uZHVtcHMoW3guZ2V0KCJ1dWlkIikgZm9yIHggaW4gYSBpZiBpc2lu
c3RhbmNlKHgsZGljdCkgYW5kIHguZ2V0KCJ1dWlkIildKSkKUFkKKSIKb2sgItC40L3QsdCw0YPQ
vdC00Ysg0L/RgNC+0YTQuNC70Y86ICRJTl9VVUlEUyIKCiMg4pSA4pSAIDQuINC90L7QtNCwIOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAjIFZFUklGWSBwYXlsb2FkICgrU0VDUkVUX0tF
WSkKbG9nICLQndC+0LTQsCIKIyDQsNC00YDQtdGBLCDQv9C+INC60L7RgtC+0YDQvtC80YMg0J/Q
kNCd0JXQm9CsICjQsiDQutC+0L3RgtC10LnQvdC10YDQtSkg0YDQtdCw0LvRjNC90L4g0LTQvtGB
0YLQsNGR0YIg0LvQvtC60LDQu9GM0L3Rg9GOINC90L7QtNGDOgojINGI0LvRjtC3INC10ZEgZG9j
a2VyLdGB0LXRgtC4ICjQv9GD0LHQu9C40YfQvdGL0LkgSVAg0YXQvtGB0YIg0YfQsNGB0YLQviDR
gdCw0Lwg0YHQtdCx0LUg0L3QtSDQt9Cw0LLQvtGA0LDRh9C40LLQsNC10YIg4oaSIDQ0MyDQsdGL
0Lsg0LHRiyDQv9GD0YHRgtC+0LkpClBBTkVMX0dXPSIkKGRvY2tlciBuZXR3b3JrIGluc3BlY3Qg
cmVtbmF3YXZlLW5ldHdvcmsgLWYgJ3t7KGluZGV4IC5JUEFNLkNvbmZpZyAwKS5HYXRld2F5fX0n
IDI+L2Rldi9udWxsIHx8IHRydWUpIgpbIC1uICIkUEFORUxfR1ciIF0gJiYgeyBOT0RFX0FERFJF
U1M9IiRQQU5FTF9HVyI7IG9rICLQsNC00YDQtdGBINC90L7QtNGLID0g0YjQu9GO0Lcg0YHQtdGC
0Lgg0L/QsNC90LXQu9C4ICgkTk9ERV9BRERSRVNTKSI7IH0Kbm9kZV9ib2R5PSIkKHB5dGhvbjMg
LSAiJE5PREVfTkFNRSIgIiROT0RFX0FERFJFU1MiICIkTk9ERV9QT1JUIiAiJFBST0ZJTEVfVVVJ
RCIgIiRJTl9VVUlEUyIgPDwnUFknCmltcG9ydCBzeXMsanNvbgpuYW1lLGFkZHIscG9ydCxwcm9m
LGlucz1zeXMuYXJndlsxOjZdCnByaW50KGpzb24uZHVtcHMoeyJuYW1lIjpuYW1lLCJhZGRyZXNz
IjphZGRyLCJwb3J0IjppbnQocG9ydCksCiAgImNvbmZpZ1Byb2ZpbGUiOnsiYWN0aXZlQ29uZmln
UHJvZmlsZVV1aWQiOnByb2YsImFjdGl2ZUluYm91bmRzIjpqc29uLmxvYWRzKGlucyl9fSkpClBZ
CikiCm5saXN0PSIkKGFwaSBHRVQgL25vZGVzKSIgfHwgZGllICLRh9GC0LXQvdC40LUg0L3QvtC0
IOKAlCDRgdC60LjQvdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCIKTk9ERV9VVUlEPSIkKHB5dGhv
bjMgLSAiJG5saXN0IiAiJE5PREVfTkFNRSIgPDwnUFknCmltcG9ydCBzeXMsanNvbgpkPWpzb24u
bG9hZHMoc3lzLmFyZ3ZbMV0pOyBhcnI9ZC5nZXQoInJlc3BvbnNlIikgaWYgaXNpbnN0YW5jZShk
LGRpY3QpIGVsc2UgZAppZiBpc2luc3RhbmNlKGFycixkaWN0KTogYXJyPWFyci5nZXQoIm5vZGVz
Iikgb3IgYXJyLmdldCgiZGF0YSIpIG9yIFtdCnByaW50KG5leHQoKG4uZ2V0KCJ1dWlkIikgZm9y
IG4gaW4gKGFyciBvciBbXSkgaWYgaXNpbnN0YW5jZShuLGRpY3QpIGFuZCBuLmdldCgibmFtZSIp
PT1zeXMuYXJndlsyXSksIiIpKQpQWQopIgppZiBbIC1uICIkTk9ERV9VVUlEIiBdOyB0aGVuCiAg
b2sgItC90L7QtNCwINGD0LbQtSDQtdGB0YLRjDogJE5PREVfVVVJRCIKZWxzZQogIG5vZGU9IiQo
YXBpIFBPU1QgL25vZGVzICIkbm9kZV9ib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQsNC90LjQtSDQ
vdC+0LTRiyDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC60LgiCiAgTk9ERV9VVUlE
PSIkKGp2YWwgIiRub2RlIiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiROT0RFX1VVSUQiIF0gfHwg
Tk9ERV9VVUlEPSIkKGp2YWwgIiRub2RlIiB1dWlkKSIKICBvayAi0L3QvtC00LAg0YHQvtC30LTQ
sNC90LA6ICROT0RFX1VVSUQiCmZpCiMg0LDQtNGA0LXRgSDQvdC+0LTRiyDQlNCe0JvQltCV0J0g
0LHRi9GC0Ywg0LTQvtGB0YLRg9C/0LXQvSDQuNC3INC60L7QvdGC0LXQudC90LXRgNCwINC/0LDQ
vdC10LvQuCAo0J3QlSAxMjcuMC4wLjEpIOKAlCDQsNC60YLRg9Cw0LvQuNC30LjRgNGD0LXQvAph
cGkgUEFUQ0ggL25vZGVzICJ7XCJ1dWlkXCI6XCIkTk9ERV9VVUlEXCIsXCJhZGRyZXNzXCI6XCIk
Tk9ERV9BRERSRVNTXCIsXCJwb3J0XCI6JE5PREVfUE9SVH0iID4vZGV2L251bGwgMj4mMSBcCiAg
JiYgb2sgItCw0LTRgNC10YEg0L3QvtC00Ys6ICROT0RFX0FERFJFU1M6JE5PREVfUE9SVCIgfHwg
d2FybiAi0LDQtNGA0LXRgSDQvdC+0LTRiyDQvdC1INC+0LHQvdC+0LLQu9GR0L0g4oCUINC/0YDQ
vtCy0LXRgNGMINCy0YDRg9GH0L3Rg9GOIgojIFNFQ1JFVF9LRVkg0L3QvtC00Ysg0LjQtyBrZXln
ZW4gQVBJIOKGkiAuZW52INC60L7QvdGC0LXQudC90LXRgNCwINC90L7QtNGLICjQstC80LXRgdGC
0L4g0YDRg9GH0L3QvtC5INCy0YHRgtCw0LLQutC4KQprZz0iJChhcGkgR0VUIC9rZXlnZW4pIiB8
fCB3YXJuICJrZXlnZW4g0L3QtSDQvtGC0LLQtdGC0LjQuyIKU0VDUkVUX0tFWT0iIgpmb3IgZiBp
biByZXNwb25zZS5wdWJLZXkgcmVzcG9uc2Uuc2VjcmV0S2V5IHJlc3BvbnNlLmNlcnQgcHViS2V5
IHNlY3JldEtleTsgZG8KICBTRUNSRVRfS0VZPSIkKGp2YWwgIiRrZyIgIiRmIikiOyBbIC1uICIk
U0VDUkVUX0tFWSIgXSAmJiBicmVhawpkb25lCmlmIFsgLW4gIiRTRUNSRVRfS0VZIiBdOyB0aGVu
CiAgTkRJUj0iL29wdC8kU0xVRy9ub2RlIjsgbWtkaXIgLXAgIiRORElSIgogIHsgZWNobyAiTk9E
RV9QT1JUPSR7Tk9ERV9QT1JUfSI7IGVjaG8gIlNFQ1JFVF9LRVk9JHtTRUNSRVRfS0VZfSI7IH0g
PiAiJE5ESVIvLmVudiIKICBvayAiU0VDUkVUX0tFWSDQvdC+0LTRiyDQt9Cw0L/QuNGB0LDQvSDQ
siAkTkRJUi8uZW52ICjQtNC70LjQvdCwICR7I1NFQ1JFVF9LRVl9KSIKZWxzZQogIHdhcm4gItC9
0LUg0L3QsNGI0ZHQuyDQutC70Y7RhyDQsiDQvtGC0LLQtdGC0LUga2V5Z2VuIOKAlCDRgdGC0YDR
g9C60YLRg9GA0YMg0LPQu9GP0L3QtdC8ICjRgdC60LjQvdGMOiBhcGkgR0VUIC9rZXlnZW4pIgpm
aQoKIyDilIDilIAgNS4gaW50ZXJuYWwgc3F1YWQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICAjIFZFUklGWSBwYXlsb2FkCmxvZyAi
SW50ZXJuYWwgc3F1YWQiCnNxdWFkcz0iJChhcGkgR0VUIC9pbnRlcm5hbC1zcXVhZHMpIiB8fCBk
aWUgItGB0L/QuNGB0L7QuiDRgdC60LLQsNC00L7QsiDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQ
vtGI0LjQsdC60LgiClNRVUFEX1VVSUQ9IiQocHl0aG9uMyAtICIkc3F1YWRzIiAiJFNRVUFEX05B
TUUiIDw8J1BZJwppbXBvcnQgc3lzLGpzb24KZD1qc29uLmxvYWRzKHN5cy5hcmd2WzFdKTsgCmFy
cj1kLmdldCgicmVzcG9uc2UiLHt9KS5nZXQoImludGVybmFsU3F1YWRzIikgb3IgZC5nZXQoImlu
dGVybmFsU3F1YWRzIikgb3IgKGQgaWYgaXNpbnN0YW5jZShkLGxpc3QpIGVsc2UgW10pCnByaW50
KG5leHQoKHMuZ2V0KCJ1dWlkIikgZm9yIHMgaW4gYXJyIGlmIGlzaW5zdGFuY2UocyxkaWN0KSBh
bmQgcy5nZXQoIm5hbWUiKT09c3lzLmFyZ3ZbMl0pLCIiKSkKUFkKKSIKaWYgWyAteiAiJFNRVUFE
X1VVSUQiIF07IHRoZW4KICBzcV9ib2R5PSIkKHB5dGhvbjMgLSAiJFNRVUFEX05BTUUiICIkSU5f
VVVJRFMiIDw8J1BZJwppbXBvcnQgc3lzLGpzb24KcHJpbnQoanNvbi5kdW1wcyh7Im5hbWUiOnN5
cy5hcmd2WzFdLCJpbmJvdW5kcyI6anNvbi5sb2FkcyhzeXMuYXJndlsyXSl9KSkKUFkKKSIKICBz
cT0iJChhcGkgUE9TVCAvaW50ZXJuYWwtc3F1YWRzICIkc3FfYm9keSIpIiB8fCBkaWUgItGB0L7Q
t9C00LDQvdC40LUg0YHQutCy0LDQtNCwIOKAlCDRgdC60LjQvdGMINCx0LvQvtC6INC+0YjQuNCx
0LrQuCIKICBTUVVBRF9VVUlEPSIkKGp2YWwgIiRzcSIgcmVzcG9uc2UudXVpZCkiOyBbIC1uICIk
U1FVQURfVVVJRCIgXSB8fCBTUVVBRF9VVUlEPSIkKGp2YWwgIiRzcSIgdXVpZCkiCiAgb2sgInNx
dWFkICckU1FVQURfTkFNRScg0YHQvtC30LTQsNC9OiAkU1FVQURfVVVJRCIKZWxzZSBvayAic3F1
YWQg0YPQttC1INC10YHRgtGMOiAkU1FVQURfVVVJRCI7IGZpCgojIOKUgOKUgCA2LiDQv9C+0LvR
jNC30L7QstCw0YLQtdC70YwgVGVzdCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIAgICMgVkVSSUZZIHBheWxvYWQKbG9nICLQn9C+0LvRjNC30L7Q
stCw0YLQtdC70YwgJFRFU1RfVVNFUiIKdXNlcl9ib2R5PSIkKHB5dGhvbjMgLSAiJFRFU1RfVVNF
UiIgIiRTUVVBRF9VVUlEIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnByaW50KGpzb24uZHVtcHMo
eyJ1c2VybmFtZSI6c3lzLmFyZ3ZbMV0sInRyYWZmaWNMaW1pdEJ5dGVzIjowLCJ0cmFmZmljTGlt
aXRTdHJhdGVneSI6Ik5PX1JFU0VUIiwKICAiZXhwaXJlQXQiOiIyMDk5LTAxLTAxVDAwOjAwOjAw
LjAwMFoiLCJhY3RpdmVJbnRlcm5hbFNxdWFkcyI6W3N5cy5hcmd2WzJdXSBpZiBzeXMuYXJndlsy
XSBlbHNlIFtdfSkpClBZCikiCmV4aXN0aW5nPSIkKGFwaSBHRVQgIi91c2Vycy9ieS11c2VybmFt
ZS8kVEVTVF9VU0VSIiAyPi9kZXYvbnVsbCkiIHx8IGV4aXN0aW5nPSIiCmlmIFsgLW4gIiRleGlz
dGluZyIgXTsgdGhlbgogIFNIT1JUPSIkKGp2YWwgIiRleGlzdGluZyIgcmVzcG9uc2Uuc2hvcnRV
dWlkKSI7IFsgLW4gIiRTSE9SVCIgXSB8fCBTSE9SVD0iJChqdmFsICIkZXhpc3RpbmciIHNob3J0
VXVpZCkiCiAgWyAtbiAiJFNIT1JUIiBdIHx8IFNIT1JUPSIkKGp2YWwgIiRleGlzdGluZyIgcmVz
cG9uc2UuMC5zaG9ydFV1aWQpIiAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgU1VCX1VSTD0iJChqdmFs
ICIkZXhpc3RpbmciIHJlc3BvbnNlLnN1YnNjcmlwdGlvblVybCkiOyBbIC1uICIkU1VCX1VSTCIg
XSB8fCBTVUJfVVJMPSIkKGp2YWwgIiRleGlzdGluZyIgc3Vic2NyaXB0aW9uVXJsKSIKICBvayAi
0L/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINGD0LbQtSDQtdGB0YLRjCAoc2hvcnRVdWlkOiAke1NI
T1JUOi0/fSkiCmVsc2UKICB1c3I9IiQoYXBpIFBPU1QgL3VzZXJzICIkdXNlcl9ib2R5IikiIHx8
IGRpZSAi0YHQvtC30LTQsNC90LjQtSDRjtC30LXRgNCwIOKAlCDRgdC60LjQvdGMINCx0LvQvtC6
INC+0YjQuNCx0LrQuCIKICBTVUJfVVJMPSIkKGp2YWwgIiR1c3IiIHJlc3BvbnNlLnN1YnNjcmlw
dGlvblVybCkiOyBbIC1uICIkU1VCX1VSTCIgXSB8fCBTVUJfVVJMPSIkKGp2YWwgIiR1c3IiIHN1
YnNjcmlwdGlvblVybCkiCiAgU0hPUlQ9IiQoanZhbCAiJHVzciIgcmVzcG9uc2Uuc2hvcnRVdWlk
KSI7IFsgLW4gIiRTSE9SVCIgXSB8fCBTSE9SVD0iJChqdmFsICIkdXNyIiBzaG9ydFV1aWQpIgog
IG9rICLQv9C+0LvRjNC30L7QstCw0YLQtdC70Ywg0YHQvtC30LTQsNC9IChzaG9ydFV1aWQ6ICR7
U0hPUlQ6LT99KSIKZmkKIyDQtdGB0LvQuCBBUEkg0L3QtSDQvtGC0LTQsNC7IHNob3J0VXVpZCDi
gJQg0LHQtdGA0ZHQvCDQvdCw0L/RgNGP0LzRg9GOINC40Lcg0JHQlCAo0L3QsNC00ZHQttC90YvQ
uSDRhNC+0LvQsdGN0LopCmlmIFsgLXogIiR7U0hPUlQ6LX0iIF07IHRoZW4KICBTSE9SVD0iJChk
b2NrZXIgZXhlYyAtaSByZW1uYXdhdmUtZGIgcHNxbCAtVSBwb3N0Z3JlcyAtZCBwb3N0Z3JlcyAt
dEFjIFwKICAgICJTRUxFQ1Qgc2hvcnRfdXVpZCBGUk9NIHVzZXJzIFdIRVJFIHVzZXJuYW1lPSck
VEVTVF9VU0VSJyBMSU1JVCAxOyIgMj4vZGV2L251bGwgfCB0ciAtZCAnWzpzcGFjZTpdJykiIHx8
IFNIT1JUPSIiCiAgWyAtbiAiJFNIT1JUIiBdICYmIG9rICJzaG9ydFV1aWQg0LLQt9GP0YIg0LjQ
tyDQkdCUOiAkU0hPUlQiIHx8IHdhcm4gInNob3J0VXVpZCDQvdC1INC90LDQudC00LXQvSDigJQg
VEVTVF9TVUJfVVVJRCDQsiBjb25mINC+0YHRgtCw0L3QtdGC0YHRjyDQv9GA0LXQttC90LjQvCIK
ZmkKIyDQoNCV0JDQm9Cs0J3Qq9CZIHNob3J0VXVpZCDRgtC10YHRgi3QutC70LjQtdC90YLQsCDi
hpIg0LIgY29uZiDQv9C+0LQgVEVTVF9TVUJfVVVJRCwg0YfRgtC+0LHRiyBzZXR1cC1jb25uZWN0
LW1pbiDQstC30Y/QuyDQtdCz0L4gKNCwINC90LUg0LfQsNCz0LvRg9GI0LrRgykKaWYgWyAtbiAi
JHtTSE9SVDotfSIgXTsgdGhlbgogIENGPSIvb3B0LyRTTFVHLy5kZXBsb3kvZGVwbG95LmNvbmYi
CiAgaWYgWyAtZiAiJENGIiBdOyB0aGVuCiAgICBpZiBncmVwIC1xICdeVEVTVF9TVUJfVVVJRD0n
ICIkQ0YiOyB0aGVuIHNlZCAtaSAic3xeVEVTVF9TVUJfVVVJRD0uKnxURVNUX1NVQl9VVUlEPSRT
SE9SVHwiICIkQ0YiCiAgICBlbHNlIHByaW50ZiAnVEVTVF9TVUJfVVVJRD0lc1xuJyAiJFNIT1JU
IiA+PiAiJENGIjsgZmkKICAgIG9rICJzaG9ydFV1aWQg0YLQtdGB0YIt0LrQu9C40LXQvdGC0LAg
0LfQsNC/0LjRgdCw0L0g0LIgY29uZiAoJFNIT1JUKSIKICBmaQpmaQoKIyDilIDilIAgNy4gSG9z
dHMgKNC60LvQuNC10L3RgtGB0LrQuNC1INCw0LTRgNC10YEv0L/QvtGA0YIvU05JINC90LAg0LrQ
sNC20LTRi9C5INC40L3QsdCw0YPQvdC0KSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgICMgVkVSSUZZIHBheWxvYWQKbG9n
ICJIb3N0cyIKRVhJU1RfSU5CPSIkKGFwaSBHRVQgL2hvc3RzIDI+L2Rldi9udWxsIHwgcHl0aG9u
MyAtYyAnCmltcG9ydCBzeXMsanNvbgp0cnk6IGQ9anNvbi5sb2FkKHN5cy5zdGRpbikKZXhjZXB0
IEV4Y2VwdGlvbjogZD1bXQphcnI9ZC5nZXQoInJlc3BvbnNlIikgaWYgaXNpbnN0YW5jZShkLGRp
Y3QpIGVsc2UgZAppZiBpc2luc3RhbmNlKGFycixkaWN0KTogYXJyPWFyci5nZXQoImhvc3RzIikg
b3IgW10KcHJpbnQoanNvbi5kdW1wcyhbKGguZ2V0KCJpbmJvdW5kIikgb3Ige30pLmdldCgiY29u
ZmlnUHJvZmlsZUluYm91bmRVdWlkIikgZm9yIGggaW4gKGFyciBvciBbXSkgaWYgaXNpbnN0YW5j
ZShoLGRpY3QpXSkpCicpIjsgWyAtbiAiJEVYSVNUX0lOQiIgXSB8fCBFWElTVF9JTkI9IltdIgpI
T1NUU19KU09OPSIkKHB5dGhvbjMgLSAiJFBST0ZJTEVfVVVJRCIgIiRET01BSU4iICIkWFJBWV9D
T05GSUdfRklMRSIgIiRJTkIiICIkRVhJU1RfSU5CIiAiJFJFQUxJVFlfUFVCTElDX0tFWSIgIiRS
RUFMSVRZX1NIT1JUX0lEIiA8PCdQWScKaW1wb3J0IHN5cywganNvbgpwcm9mLCBkb21haW4sIGNm
Z2YsIGluYiwgZXhpc3QsIHB1Yl9rZXksIHNob3J0X2lkID0gc3lzLmFyZ3ZbMV0sIHN5cy5hcmd2
WzJdLCBzeXMuYXJndlszXSwgc3lzLmFyZ3ZbNF0sIHN5cy5hcmd2WzVdLCBzeXMuYXJndls2XSwg
c3lzLmFyZ3ZbN10KY2ZnID0ganNvbi5sb2FkKG9wZW4oY2ZnZikpOyBjZmcgPSBjZmcuZ2V0KCJp
bmJvdW5kcyIsIGNmZyBpZiBpc2luc3RhbmNlKGNmZywgbGlzdCkgZWxzZSBbXSkKdHJ5OiBhID0g
anNvbi5sb2FkcyhpbmIpCmV4Y2VwdCBFeGNlcHRpb246IGEgPSBbXQphID0gYS5nZXQoInJlc3Bv
bnNlIiwgYSkgaWYgaXNpbnN0YW5jZShhLCBkaWN0KSBlbHNlIGEKYSA9IGEuZ2V0KCJpbmJvdW5k
cyIsIGEpIGlmIGlzaW5zdGFuY2UoYSwgZGljdCkgZWxzZSBhCmlmIG5vdCBpc2luc3RhbmNlKGEs
IGxpc3QpOiBhID0gW10KdHJ5OiBleGlzdGluZyA9IHNldCh4IGZvciB4IGluIGpzb24ubG9hZHMo
ZXhpc3QpIGlmIHgpCmV4Y2VwdCBFeGNlcHRpb246IGV4aXN0aW5nID0gc2V0KCkKdGFnMnV1aWQg
PSB7eC5nZXQoInRhZyIpOiB4LmdldCgidXVpZCIpIGZvciB4IGluIGEgaWYgaXNpbnN0YW5jZSh4
LCBkaWN0KX0Kb3V0ID0gW10KZm9yIGliIGluIGNmZzoKICAgIHRhZyA9IGliLmdldCgidGFnIik7
IHV1aWQgPSB0YWcydXVpZC5nZXQodGFnKQogICAgaWYgbm90IHV1aWQgb3IgdXVpZCBpbiBleGlz
dGluZzogY29udGludWUKICAgIHNzID0gaWIuZ2V0KCJzdHJlYW1TZXR0aW5ncyIsIHt9KSBvciB7
fQogICAgbmV0ID0gc3MuZ2V0KCJuZXR3b3JrIiwgInRjcCIpOyBzZWMgPSBzcy5nZXQoInNlY3Vy
aXR5IiwgIm5vbmUiKTsgcHJvdG8gPSBpYi5nZXQoInByb3RvY29sIiwgIiIpCiAgICBoID0geyJp
bmJvdW5kIjogeyJjb25maWdQcm9maWxlVXVpZCI6IHByb2YsICJjb25maWdQcm9maWxlSW5ib3Vu
ZFV1aWQiOiB1dWlkfSwKICAgICAgICAgInJlbWFyayI6ICh0YWcgb3IgcHJvdG8pWzo0MF0sICJh
ZGRyZXNzIjogZG9tYWluLCAicG9ydCI6IDQ0M30KICAgIGlmIHNlYyA9PSAicmVhbGl0eSIgYW5k
IG5ldCBpbiAoInhodHRwIiwgInNwbGl0aHR0cCIpOgogICAgICAgIHhzID0gc3MuZ2V0KCJ4aHR0
cFNldHRpbmdzIikgb3Igc3MuZ2V0KCJzcGxpdGh0dHBTZXR0aW5ncyIpIG9yIHt9CiAgICAgICAg
c25zID0gKHNzLmdldCgicmVhbGl0eVNldHRpbmdzIiwge30pIG9yIHt9KS5nZXQoInNlcnZlck5h
bWVzIikgb3IgW2RvbWFpbl0KICAgICAgICBoWyJwb3J0Il0gPSBpYi5nZXQoInBvcnQiLCA0NDMp
CiAgICAgICAgaFsicGF0aCJdID0geHMuZ2V0KCJwYXRoIiwgIi8iKTsgaFsic25pIl0gPSBzbnNb
MF07IGhbImZpbmdlcnByaW50Il0gPSAiY2hyb21lIjsgaFsic2VjdXJpdHlMYXllciJdID0gIkRF
RkFVTFQiCiAgICAgICAgaWYgcHViX2tleTogaFsicHVibGljS2V5Il0gPSBwdWJfa2V5CiAgICAg
ICAgaWYgc2hvcnRfaWQ6IGhbInNob3J0SWQiXSA9IHNob3J0X2lkCiAgICBlbGlmIHNlYyA9PSAi
cmVhbGl0eSI6CiAgICAgICAgc25zID0gKHNzLmdldCgicmVhbGl0eVNldHRpbmdzIiwge30pIG9y
IHt9KS5nZXQoInNlcnZlck5hbWVzIikgb3IgW2RvbWFpbl0KICAgICAgICBoWyJzbmkiXSA9IHNu
c1swXTsgaFsiZmluZ2VycHJpbnQiXSA9ICJjaHJvbWUiOyBoWyJzZWN1cml0eUxheWVyIl0gPSAi
REVGQVVMVCIKICAgICAgICBpZiBwdWJfa2V5OiBoWyJwdWJsaWNLZXkiXSA9IHB1Yl9rZXkKICAg
ICAgICBpZiBzaG9ydF9pZDogaFsic2hvcnRJZCJdID0gc2hvcnRfaWQKICAgIGVsaWYgbmV0ID09
ICJ3cyI6CiAgICAgICAgaFsicGF0aCJdID0gKHNzLmdldCgid3NTZXR0aW5ncyIsIHt9KSBvciB7
fSkuZ2V0KCJwYXRoIiwgIi8iKTsgaFsiaG9zdCJdID0gZG9tYWluOyBoWyJzbmkiXSA9IGRvbWFp
bjsgaFsic2VjdXJpdHlMYXllciJdID0gIlRMUyIKICAgIGVsaWYgbmV0IGluICgieGh0dHAiLCAi
c3BsaXRodHRwIik6CiAgICAgICAgeHMgPSBzcy5nZXQoInhodHRwU2V0dGluZ3MiKSBvciBzcy5n
ZXQoInNwbGl0aHR0cFNldHRpbmdzIikgb3Ige30KICAgICAgICBoWyJwYXRoIl0gPSB4cy5nZXQo
InBhdGgiLCAiLyIpOyBoWyJzbmkiXSA9IGRvbWFpbjsgaFsic2VjdXJpdHlMYXllciJdID0gIlRM
UyIKICAgIGVsaWYgcHJvdG8gaW4gKCJoeXN0ZXJpYSIsICJoeXN0ZXJpYTIiKToKICAgICAgICBo
WyJzbmkiXSA9IGRvbWFpbjsgaFsiYWxwbiJdID0gImgzIjsgaFsic2VjdXJpdHlMYXllciJdID0g
IlRMUyIKICAgIGVsc2U6CiAgICAgICAgaFsic25pIl0gPSBkb21haW47IGhbInNlY3VyaXR5TGF5
ZXIiXSA9ICJUTFMiCiAgICBvdXQuYXBwZW5kKGgpCmZvciBoIGluIG91dDogcHJpbnQoanNvbi5k
dW1wcyhoKSkKUFkKKSIKSENPVU5UPTAKd2hpbGUgSUZTPSByZWFkIC1yIGg7IGRvCiAgWyAteiAi
JGgiIF0gJiYgY29udGludWUKICBhcGkgUE9TVCAvaG9zdHMgIiRoIiA+L2Rldi9udWxsICYmIEhD
T1VOVD0kKChIQ09VTlQrMSkpIHx8IGRpZSAi0YHQvtC30LTQsNC90LjQtSBob3N0IOKAlCDRgdC6
0LjQvdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCAocGF5bG9hZDogJGgpIgpkb25lIDw8PCAiJEhP
U1RTX0pTT04iCm9rICLRgdC+0LfQtNCw0L3QviBIb3N0czogJEhDT1VOVCAo0YHRg9GJ0LXRgdGC
0LLRg9GO0YnQuNC1INC/0YDQvtC/0YPRidC10L3RiykiCgojIOKUgOKUgCBBUEkg0YLQvtC60LXQ
vSDQtNC70Y8gc3Vic2NyaXB0aW9uLXBhZ2Ug4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmxvZyAiQVBJINGC0L7QutC1
0L0g0LTQu9GPIHN1YnNjcmlwdGlvbi1wYWdlIgpTVUJfRU5WPSIvb3B0LyRTTFVHL3N1Yi8uZW52
IgpFWElTVElOR19UT0tFTj0iJChncmVwICdeUkVNTkFXQVZFX0FQSV9UT0tFTj0nICIkU1VCX0VO
ViIgMj4vZGV2L251bGwgfCBjdXQgLWQ9IC1mMikiCmlmIFsgLW4gIiRFWElTVElOR19UT0tFTiIg
XTsgdGhlbgogIG9rICLRgtC+0LrQtdC9INGD0LbQtSDQv9GA0L7Qv9C40YHQsNC9INCyICRTVUJf
RU5WIgplbHNlCiAgdG9rX3Jlc3A9IiQoYXBpIFBPU1QgL3Rva2VucyAie1widG9rZW5OYW1lXCI6
XCJzdWItcGFnZS0kKGRhdGUgKyVZJW0lZClcIn0iKSIgfHwgdG9rX3Jlc3A9IiIKICBBUElfVE9L
RU49IiQocHl0aG9uMyAtYyAiaW1wb3J0IHN5cyxqc29uOyBkPWpzb24ubG9hZHMoJyR0b2tfcmVz
cCcpOyBwcmludChkLmdldCgncmVzcG9uc2UnLHt9KS5nZXQoJ3Rva2VuJywnJykpIiAyPi9kZXYv
bnVsbCkiCiAgaWYgWyAtbiAiJEFQSV9UT0tFTiIgXTsgdGhlbgogICAgaWYgZ3JlcCAtcSAnXlJF
TU5BV0FWRV9BUElfVE9LRU49JyAiJFNVQl9FTlYiIDI+L2Rldi9udWxsOyB0aGVuCiAgICAgIHNl
ZCAtaSAic3xeUkVNTkFXQVZFX0FQSV9UT0tFTj0uKnxSRU1OQVdBVkVfQVBJX1RPS0VOPSRBUElf
VE9LRU58IiAiJFNVQl9FTlYiCiAgICBlbHNlCiAgICAgIGVjaG8gIlJFTU5BV0FWRV9BUElfVE9L
RU49JEFQSV9UT0tFTiIgPj4gIiRTVUJfRU5WIgogICAgZmkKICAgIGRvY2tlciByZXN0YXJ0IHJl
bW5hd2F2ZS1zdWJzY3JpcHRpb24tcGFnZSA+L2Rldi9udWxsIDI+JjEgJiYgb2sgInN1YnNjcmlw
dGlvbi1wYWdlINC/0LXRgNC10LfQsNC/0YPRidC10L3QsCDRgSDRgtC+0LrQtdC90L7QvCIgfHwg
dHJ1ZQogIGVsc2UKICAgIHdhcm4gItC90LUg0YPQtNCw0LvQvtGB0Ywg0YHQvtC30LTQsNGC0Ywg
QVBJINGC0L7QutC10L0g4oCUINC30LDQudC00Lgg0LIg0L/QsNC90LXQu9GMIOKGkiBTZXR0aW5n
cyDihpIgQVBJIFRva2VucyDihpIg0YHQvtC30LTQsNC5INCy0YDRg9GH0L3Rg9GOINC4INC/0YDQ
vtC/0LjRiNC4INCyICRTVUJfRU5WIgogIGZpCmZpCgojIOKUgOKUgCDQuNGC0L7QsyDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZWNobzsgZWNobyAiJChjICcxOzMyJyAn4pWQ
4pWQ4pWQ4pWQINCT0J7QotCe0JLQniDilZDilZDilZDilZAnKSIKZWNobyAiICDQn9Cw0L3QtdC7
0Yw6ICBodHRwczovLyR7RE9NQUlOfS8iClsgIiRNQURFX0FETUlOIiA9IDEgXSAmJiBlY2hvICIg
INCQ0LTQvNC40L06ICAgJEFETUlOX1VTRVIgIC8gICRBRE1JTl9QQVNTIgplY2hvICIgINCU0L7R
gdGC0YPQv9GLOiAkQ1JFRF9GSUxFIgpbIC1uICIke1NVQl9VUkw6LX0iIF0gJiYgZWNobyAiICDQ
n9C+0LTQv9C40YHQutCwIFRlc3Q6ICRTVUJfVVJMIgpbIC1uICIke1NIT1JUOi19IiBdICAgJiYg
ZWNobyAiICDQodGC0YDQsNC90LjRhtCwOiAgICAgIGh0dHBzOi8vJHtET01BSU59L2MvJHtTSE9S
VH0vIgppZiBbICIkVVNFX1RBSUxTQ0FMRSIgPSB5ZXMgXTsgdGhlbgogIGVjaG87IGVjaG8gIiQo
YyAnMTszNicgJ9CU0L7RgdGC0YPQvyDQuiDQv9Cw0L3QtdC70Lgg0YfQtdGA0LXQtyBUYWlsc2Nh
bGU6JykiCiAgZWNobyAiICAxLiDQn9C+0YHRgtCw0LLRjCBUYWlsc2NhbGUg0L3QsCDRg9GB0YLR
gNC+0LnRgdGC0LLQviAoaVBob25lOiBBcHAgU3RvcmU7INCf0Jo6IHRhaWxzY2FsZS5jb20vZG93
bmxvYWQg4oaSIHRhaWxzY2FsZSB1cCkuIgogIGVjaG8gIiAgMi4g0KHQtdGA0LLQtdGAINC4INGD
0YHRgtGA0L7QudGB0YLQstC+IOKAlCDQsiDQvtC00L3QvtC8INGC0LDQudC90LXRgtC1LiIKICBl
Y2hvICIgIDMuINCe0YLQutGA0L7QuSDQv9Cw0L3QtdC70Ywg0L/QviDRgtCw0LnQvdC10YIt0LDQ
tNGA0LXRgdGDINGD0LfQu9CwICjQv9C10YfQsNGC0LDQtdGCIHN0ZWFsdGguc2gpLCDQvdCw0L/R
gC4gaHR0cHM6Ly88bm9kZT4uPHRhaWxuZXQ+LnRzLm5ldCIKZmkK
__B64__
  base64 -d > "$d/setup-connect-min.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIHNldHVwLWNvbm5l
Y3QtbWluLnNoIOKAlCDRgdGC0YDQsNC90LjRhtCwLdCy0LjQt9C40YLQutCwIEBAQlJBTkRAQCAo
0LzQuNC90LjQvNGD0LwgKyDQvtCx0YnQuNC5IFFSICsg0LjQvNGPINC60LvQuNC10L3RgtCwKQoj
ICBSVS3RgdGC0YDQsNC90LjRhtCwOiDQvtCx0LvQsNC60L4t0LvQvtCz0L7RgtC40L8vZmF2aWNv
biwg0L7QsdGJ0LjQuSBRUiDQvdCwINCy0YHRjiDQv9C+0LTQv9C40YHQutGDLCDQutCw0YDRgtC+
0YfQutC4INC/0YDQvtGC0L7QutC+0LvQvtCyCiMgIChAQFJFTEFZX05BTUVAQC3RgNC10LvQtdC5
INGB0LXRgtC60L7QuSDQv9C10YDQstGL0LwsINC30LDRgtC10Lwg0L/RgNGP0LzRi9C1KSDRgSBR
UiAo0LrQu9C40LogPSDRgdC60L7Qv9C40YDQvtCy0LDRgtGMINGB0YHRi9C70LrRgykg0LgKIyAg
0LrQvdC+0L/QutC+0LkgItCe0YLQutGA0YvRgtGMINCyINC/0YDQuNC70L7QttC10L3QuNC4Ii4g
0KPQvNC90LDRjyDQv9C+0LTQv9C40YHQutCwIC9jLzxpZD4vc3ViOiDQtNC+0L/QuNGB0YvQstCw
0LXRgiBIeXN0ZXJpYTIg0LgKIyAg0LLQv9C40YHRi9Cy0LDQtdGCINC40LzRjyDQutC70LjQtdC9
0YLQsCDQsiDQvdCw0LfQstCw0L3QuNC1INC60LDQttC00L7Qs9C+INGB0LXRgNCy0LXRgNCwICgr
IHByb2ZpbGUtdGl0bGUpLiBjb25maWcuanNvbiDQuNC3CiMgINC/0L7QtNC/0LjRgdC60LggUmVt
bmF3YXZlLiDQoNCw0LfQtNCw0YfQsCBDYWRkeSDQvdCwIC9jLzx1dWlkPi8uINCR0LXQtyBQV0Ev
0L/QtdGA0LXQstC+0LTQvtCyL9GB0YLQsNGC0LjRgdGC0LjQutC4L9GI0LXRgNC40L3Qs9CwLgoj
ICDQl9Cw0L/Rg9GB0Lo6ICBzdWRvIGJhc2ggc2V0dXAtY29ubmVjdC1taW4uc2gKIyA9PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbApCQVNFPSIvb3B0L0BAU0xVR0BAL2Nvbm5l
Y3QiCkNBRERZRklMRT0iL29wdC9AQFNMVUdAQC9jYWRkeS9DYWRkeWZpbGUiCkNBRERZX0NUUj0i
QEBTTFVHQEAtY2FkZHkiCiMg0YDQtdCw0LvRjNC90YvQuSBzaG9ydFV1aWQg0YLQtdGB0YIt0LrQ
u9C40LXQvdGC0LAg0L/RgNC+0LLQuNC20LjQvdC10YAg0LrQu9Cw0LTRkdGCINCyIGNvbmYg4oCU
INCx0LXRgNGR0Lwg0L7RgtGC0YPQtNCwLCDQvdC1INC40Lcg0LfQsNCz0LvRg9GI0LrQuApfX0NG
PSIvb3B0L0BAU0xVR0BALy5kZXBsb3kvZGVwbG95LmNvbmYiCmlmIFsgLXogIiR7U1VCX1VVSUQ6
LX0iIF0gJiYgWyAtZiAiJF9fQ0YiIF07IHRoZW4KICBTVUJfVVVJRD0iJCggLiAiJF9fQ0YiIDI+
L2Rldi9udWxsOyBwcmludGYgJyVzJyAiJHtURVNUX1NVQl9VVUlEOi19IiApIgpmaQpTVUJfVVVJ
RD0iJHtTVUJfVVVJRDotQEBURVNUX1NVQl9VVUlEQEB9IiAgICAgIyDRhNC+0LvQsdGN0Lo6INC3
0L3QsNGH0LXQvdC40LUg0LjQtyDQstC40LfQsNGA0LTQsCAvINC30LDQs9C70YPRiNC60LAKIyBz
aG9ydFV1aWQg0LIgUmVtbmF3YXZlINGB0L7QtNC10YDQttC40YIgJy0nINC4INC00LvQuNC90L3Q
tdC1IDgg0YHQuNC80LLQvtC70L7QsiAo0L3QsNC/0YAuIEZiV3RCQnFVaktLLTY5NDEpCiMg0LXR
gdC70Lgg0LIgY29uZiDQu9C10LbQuNGCINC40LzRjyDQv9C+0LvRjNC30L7QstCw0YLQtdC70Y8g
KNCx0LXQtyAnLScpIOKAlCDQuNGJ0LXQvCBzaG9ydFV1aWQg0L3QsNC/0YDRj9C80YPRjiDQsiDQ
kdCUCmlmICEgcHJpbnRmICclcycgIiRTVUJfVVVJRCIgfCBncmVwIC1xICctJzsgdGhlbgogIF9f
REJfU0hPUlQ9IiQoZG9ja2VyIGV4ZWMgLWkgcmVtbmF3YXZlLWRiIHBzcWwgLVUgcG9zdGdyZXMg
LWQgcG9zdGdyZXMgLXRBYyBcCiAgICAiU0VMRUNUIHNob3J0X3V1aWQgRlJPTSB1c2VycyBXSEVS
RSB1c2VybmFtZT0nJFNVQl9VVUlEJyBMSU1JVCAxOyIgMj4vZGV2L251bGwgfCB0ciAtZCAnWzpz
cGFjZTpdJykiIHx8IF9fREJfU0hPUlQ9IiIKICBpZiBbIC1uICIkX19EQl9TSE9SVCIgXTsgdGhl
bgogICAgZWNobyAiICBTVUJfVVVJRCAnJFNVQl9VVUlEJyDigJQg0Y3RgtC+INC40LzRjyDQv9C+
0LvRjNC30L7QstCw0YLQtdC70Y8sINGA0LXQsNC70YzQvdGL0Lkgc2hvcnRVdWlkOiAkX19EQl9T
SE9SVCIKICAgIFNVQl9VVUlEPSIkX19EQl9TSE9SVCIKICAgICMg0L7QsdC90L7QstC40LwgY29u
Ziwg0YfRgtC+0LHRiyDQv9GA0Lgg0YHQu9C10LTRg9GO0YnQtdC8INC30LDQv9GD0YHQutC1INGD
0LbQtSDQsdGL0Lsg0L/RgNCw0LLQuNC70YzQvdGL0LkgVVVJRAogICAgWyAtZiAiJF9fQ0YiIF0g
JiYgc2VkIC1pICJzfF5URVNUX1NVQl9VVUlEPS4qfFRFU1RfU1VCX1VVSUQ9JFNVQl9VVUlEfCIg
IiRfX0NGIiAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgZWxzZQogICAgZWNobyAiICAhICckU1VCX1VV
SUQnINC90LUg0L3QsNC50LTQtdC9INCyINCR0JQg0LrQsNC6INC40LzRjyDQv9C+0LvRjNC30L7Q
stCw0YLQtdC70Y8g4oCUINGI0LDQsyBbNS81XSDRgdC60L7RgNC10LUg0LLRgdC10LPQviDRg9C/
0LDQtNGR0YIiCiAgZmkKZmkKdHM9JChkYXRlICslWSVtJWQtJUglTSVTKQoKZWNobyAiPT0gWzEv
NV0gc2Vnbm8gPT0iCnB5dGhvbjMgLWMgImltcG9ydCBzZWdubyIgMj4vZGV2L251bGwgfHwgYXB0
LWdldCBpbnN0YWxsIC15IHB5dGhvbjMtc2Vnbm8gMj4vZGV2L251bGwgfHwgeyBhcHQtZ2V0IGlu
c3RhbGwgLXkgcHl0aG9uMy1waXAgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWU7IHB5dGhvbjMgLW0g
cGlwIGluc3RhbGwgLS1icmVhay1zeXN0ZW0tcGFja2FnZXMgLS1xdWlldCBzZWdubzsgfQoKZWNo
byAiPT0gWzIvNV0g0YfQuNGB0YLQutCwINGB0YLQsNGA0L7Qs9C+IChNZXJpZGlhbi9wd2EvYXBw
cy5qc29uLCDQutGN0Ygg0YHRgtGA0LDQvdC40YYpID09IgpybSAtcmYgIiRCQVNFL3B3YSIgIiRC
QVNFL2FwcHMuanNvbiIgIiRCQVNFL190cGwiCnJtIC1mICIkQkFTRSIvKi9jb25maWcuanNvbiAi
JEJBU0UiLyovaW5kZXguaHRtbCAiJEJBU0UiLyovbWFuaWZlc3Qud2VibWFuaWZlc3QgMj4vZGV2
L251bGwgfHwgdHJ1ZQpta2RpciAtcCAiJEJBU0UvYXNzZXRzIiAiJEJBU0UvX3RwbCIKCmVjaG8g
Ij09IFszLzVdINGE0LDQudC70Ysg0LLQuNC30LjRgtC60LggKyDQs9C10L3QtdGA0LDRgtC+0YAg
KyDRgdC10YDQstC40YEgPT0iCmNhdCA+ICIkQkFTRS9hc3NldHMvc3R5bGUuY3NzIiA8PCdfX0NT
U19fJwo6cm9vdHsKICAtLWJnOiMwYjBkMTM7IC0tYmcyOiMwZjEzMjA7IC0tY2FyZDojMTUxOTI2
OyAtLWNhcmQyOiMxYjIwMzA7CiAgLS1ib3JkZXI6IzI2MmQzZjsgLS1mZzojZWVmMWY3OyAtLW11
dGVkOiM5OGExYjQ7IC0tYWNjZW50OiM2ZDhjZmY7IC0tYWNjZW50MjojOGE2Y2Y2Owp9Cip7Ym94
LXNpemluZzpib3JkZXItYm94fQpodG1sLGJvZHl7bWFyZ2luOjB9CmJvZHl7CiAgYmFja2dyb3Vu
ZDp2YXIoLS1iZyk7IGNvbG9yOnZhcigtLWZnKTsgbGluZS1oZWlnaHQ6MS41OyAtd2Via2l0LWZv
bnQtc21vb3RoaW5nOmFudGlhbGlhc2VkOwogIGZvbnQtZmFtaWx5Oi1hcHBsZS1zeXN0ZW0sQmxp
bmtNYWNTeXN0ZW1Gb250LCJTZWdvZSBVSSIsUm9ib3RvLEhlbHZldGljYSxBcmlhbCxzYW5zLXNl
cmlmOwogIGJhY2tncm91bmQtaW1hZ2U6cmFkaWFsLWdyYWRpZW50KDEyMDBweCAzODBweCBhdCA1
MCUgLTEyMHB4LHJnYmEoMTA5LDE0MCwyNTUsLjE2KSx0cmFuc3BhcmVudCA3MCUpOwp9Ci53cmFw
e21heC13aWR0aDo4ODBweDttYXJnaW46MCBhdXRvO3BhZGRpbmc6MzRweCAxNnB4IDQ4cHh9Ci5i
cmFuZHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmNlbnRl
cjt0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tYm90dG9tOjZweH0KLmJyYW5kIGltZ3t3aWR0aDo2
NHB4O2hlaWdodDo2NHB4O2ZpbHRlcjpkcm9wLXNoYWRvdygwIDdweCAxOHB4IHJnYmEoMTA5LDE0
MCwyNTUsLjQyKSl9Ci5icmFuZCBoMXttYXJnaW46MTNweCAwIDJweDtmb250LXNpemU6MjVweDtm
b250LXdlaWdodDo4MDA7bGV0dGVyLXNwYWNpbmc6LjE2ZW07dGV4dC10cmFuc2Zvcm06dXBwZXJj
YXNlfQoudGFne2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTRweDttYXJnaW46MH0KLmNs
aWVudHttYXJnaW46MTBweCBhdXRvIDA7ZGlzcGxheTppbmxpbmUtYmxvY2s7YmFja2dyb3VuZDp2
YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgY29sb3I6dmFyKC0t
ZmcpO2ZvbnQtc2l6ZToxM3B4O3BhZGRpbmc6NXB4IDEzcHg7Ym9yZGVyLXJhZGl1czo5OTlweH0K
LmNsaWVudCBie2NvbG9yOnZhcigtLWFjY2VudCl9Ci5ub3Rle2NvbG9yOnZhcigtLW11dGVkKTtm
b250LXNpemU6MTJweDttYXJnaW46MTFweCAwIDB9Ci5zZWN0aXRsZXtmb250LXNpemU6MTJweDtj
b2xvcjp2YXIoLS1tdXRlZCk7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2xldHRlci1zcGFjaW5n
Oi4wOGVtOwogIGZvbnQtd2VpZ2h0OjYwMDttYXJnaW46MjhweCA0cHggMTBweH0KLmNhcmR7YmFj
a2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVy
LXJhZGl1czoxNnB4O3BhZGRpbmc6MThweDttYXJnaW46MTJweCAwO3RleHQtYWxpZ246Y2VudGVy
fQouY2FyZC5oZXJve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE2MGRlZyx2YXIoLS1jYXJk
MiksdmFyKC0tY2FyZCkpO2JvcmRlci1jb2xvcjojMzM0MDZiO3BhZGRpbmc6MjRweH0KLmNhcmQg
LmxhYntmb250LXdlaWdodDo2MDA7Zm9udC1zaXplOjE1cHg7bWFyZ2luOjAgMCAxM3B4fQouY2Fy
ZCAuaGludHtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEyLjVweDttYXJnaW46MTJweCAw
IDB9Ci5xcnt3aWR0aDoyMDhweDtoZWlnaHQ6MjA4cHg7YmFja2dyb3VuZDojZmZmO2JvcmRlci1y
YWRpdXM6MTJweDtwYWRkaW5nOjlweDtkaXNwbGF5OmJsb2NrO21hcmdpbjowIGF1dG99Ci5xci50
YXB7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjp0cmFuc2Zvcm0gLjEyc30KLnFyLnRhcDphY3Rp
dmV7dHJhbnNmb3JtOnNjYWxlKC45Nil9Ci5idG57ZGlzcGxheTppbmxpbmUtYmxvY2s7bWFyZ2lu
LXRvcDoxNHB4O2JhY2tncm91bmQ6dmFyKC0tYWNjZW50KTtjb2xvcjojZmZmO3RleHQtZGVjb3Jh
dGlvbjpub25lOwogIHBhZGRpbmc6MTFweCAyMHB4O2JvcmRlci1yYWRpdXM6MTFweDtmb250LXdl
aWdodDo2MDA7Zm9udC1zaXplOjE0LjVweDt0cmFuc2l0aW9uOm9wYWNpdHkgLjE1c30KLmJ0bjph
Y3RpdmV7b3BhY2l0eTouODJ9CgovKiDQodC10YLQutCwOiDQv9C+INGD0LzQvtC70YfQsNC90LjR
jiA0INCyINGA0Y/QtCDQvdCwINC00LXRgdC60YLQvtC/0LUsINC60YDRg9C/0L3Ri9C1INC60LDR
gNGC0L7Rh9C60LggKi8KLnJvd3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOnJl
cGVhdCg0LCAxZnIpO2dhcDoxNnB4fQoucm93IC5jYXJke21hcmdpbjowO3BhZGRpbmc6MThweDti
b3JkZXItcmFkaXVzOjE0cHh9Ci5yb3cgLmxhYntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2
MDA7bWFyZ2luLWJvdHRvbToxMHB4O2xpbmUtaGVpZ2h0OjEuMn0KLnJvdyAucXJ7d2lkdGg6MTAw
JTtoZWlnaHQ6YXV0bztwYWRkaW5nOjZweDtib3JkZXItcmFkaXVzOjEwcHh9Ci5yb3cgLmJ0bntt
YXJnaW4tdG9wOjEycHg7cGFkZGluZzo5cHggNnB4O2ZvbnQtc2l6ZToxMnB4O3dpZHRoOjEwMCU7
Ym9yZGVyLXJhZGl1czo5cHh9CgovKiDQkNC00LDQv9GC0LjQsiDQtNC70Y8g0LzQvtCx0LjQu9C+
0Lo6INC/0LXRgNC10YHRgtGA0LDQuNCy0LDQtdC8INCyIDIg0LrQvtC70L7QvdC60LgsINGH0YLQ
vtCx0Ysg0LHRi9C70L4g0YPQtNC+0LHQvdC+INC/0L7Qu9GM0LfQvtCy0LDRgtGM0YHRjyAqLwpA
bWVkaWEobWF4LXdpZHRoOjc2OHB4KXsKICAucm93e2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBl
YXQoMiwgMWZyKTtnYXA6MTJweH0KICAucm93IC5jYXJke3BhZGRpbmc6MTRweDtib3JkZXItcmFk
aXVzOjEycHh9CiAgLnJvdyAubGFie2ZvbnQtc2l6ZToxMi41cHg7bWFyZ2luLWJvdHRvbTo4cHh9
CiAgLndyYXB7cGFkZGluZzoyNHB4IDEycHggMzZweH0KICAuY2FyZC5oZXJve3BhZGRpbmc6MjBw
eH0KICAucXJ7d2lkdGg6MTgwcHg7aGVpZ2h0OjE4MHB4fQp9CgoudG9hc3R7cG9zaXRpb246Zml4
ZWQ7bGVmdDo1MCU7Ym90dG9tOjI2cHg7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSkgdHJhbnNs
YXRlWSgxMnB4KTsKICBiYWNrZ3JvdW5kOiMyMjJhM2Q7Y29sb3I6I2ZmZjtib3JkZXI6MXB4IHNv
bGlkIHZhcigtLWJvcmRlcik7cGFkZGluZzoxMHB4IDE2cHg7Ym9yZGVyLXJhZGl1czoxMXB4Owog
IGZvbnQtc2l6ZToxMy41cHg7b3BhY2l0eTowO3BvaW50ZXItZXZlbnRzOm5vbmU7dHJhbnNpdGlv
bjpvcGFjaXR5IC4ycyx0cmFuc2Zvcm0gLjJzO3otaW5kZXg6MjA7CiAgYm94LXNoYWRvdzowIDEw
cHggMzBweCByZ2JhKDAsMCwwLC40KX0KLnRvYXN0LnNob3d7b3BhY2l0eToxO3RyYW5zZm9ybTp0
cmFuc2xhdGVYKC01MCUpIHRyYW5zbGF0ZVkoMCl9Ci5lcnJ7Y29sb3I6I2ZmNmI2Yjt0ZXh0LWFs
aWduOmNlbnRlcn0KX19DU1NfXwpjYXQgPiAiJEJBU0UvYXNzZXRzL2FwcC5qcyIgPDwnX19BUFBK
U19fJwooZnVuY3Rpb24gKCkgewogIHZhciByb290ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
ImFwcCIpOwogIGZ1bmN0aW9uIGVsKHRhZywgY2xzLCB0eHQpIHsgdmFyIGUgPSBkb2N1bWVudC5j
cmVhdGVFbGVtZW50KHRhZyk7IGlmIChjbHMpIGUuY2xhc3NOYW1lID0gY2xzOyBpZiAodHh0ICE9
IG51bGwpIGUudGV4dENvbnRlbnQgPSB0eHQ7IHJldHVybiBlOyB9CiAgZnVuY3Rpb24gc2hvcnRM
YWJlbChzKSB7IHZhciBtID0gKHMgfHwgIiIpLm1hdGNoKC9cKChbXildKylcKVxzKiQvKTsgcmV0
dXJuIG0gPyBtWzFdIDogKHMgfHwgIiIpOyB9CgogIHZhciB0b2FzdEVsID0gbnVsbCwgdG9hc3RU
aW1lciA9IG51bGw7CiAgZnVuY3Rpb24gdG9hc3QobXNnKSB7CiAgICBpZiAoIXRvYXN0RWwpIHsg
dG9hc3RFbCA9IGVsKCJkaXYiLCAidG9hc3QiKTsgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZCh0
b2FzdEVsKTsgfQogICAgdG9hc3RFbC50ZXh0Q29udGVudCA9IG1zZzsgdG9hc3RFbC5jbGFzc0xp
c3QuYWRkKCJzaG93Iik7CiAgICBjbGVhclRpbWVvdXQodG9hc3RUaW1lcik7IHRvYXN0VGltZXIg
PSBzZXRUaW1lb3V0KGZ1bmN0aW9uICgpIHsgdG9hc3RFbC5jbGFzc0xpc3QucmVtb3ZlKCJzaG93
Iik7IH0sIDE1MDApOwogIH0KICBmdW5jdGlvbiBjb3B5VGV4dCh0ZXh0KSB7CiAgICBpZiAobmF2
aWdhdG9yLmNsaXBib2FyZCAmJiBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCkgcmV0dXJu
IG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHRleHQpOwogICAgcmV0dXJuIG5ldyBQcm9t
aXNlKGZ1bmN0aW9uIChyZXMsIHJlaikgewogICAgICB0cnkgewogICAgICAgIHZhciB0YSA9IGRv
Y3VtZW50LmNyZWF0ZUVsZW1lbnQoInRleHRhcmVhIik7IHRhLnZhbHVlID0gdGV4dDsKICAgICAg
ICB0YS5zdHlsZS5wb3NpdGlvbiA9ICJmaXhlZCI7IHRhLnN0eWxlLm9wYWNpdHkgPSAiMCI7IGRv
Y3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQodGEpOwogICAgICAgIHRhLmZvY3VzKCk7IHRhLnNlbGVj
dCgpOyBkb2N1bWVudC5leGVjQ29tbWFuZCgiY29weSIpOyBkb2N1bWVudC5ib2R5LnJlbW92ZUNo
aWxkKHRhKTsgcmVzKCk7CiAgICAgIH0gY2F0Y2ggKGUpIHsgcmVqKGUpOyB9CiAgICB9KTsKICB9
CiAgZnVuY3Rpb24gcXJJbWcoYjY0LCB1cmwpIHsKICAgIHZhciBpID0gZWwoImltZyIsICJxciIg
KyAodXJsID8gIiB0YXAiIDogIiIpKTsgaS5hbHQgPSAiUVIt0LrQvtC0IjsKICAgIGkuc3JjID0g
ImRhdGE6aW1hZ2UvcG5nO2Jhc2U2NCwiICsgYjY0OwogICAgaWYgKHVybCkgewogICAgICBpLnRp
dGxlID0gItCd0LDQttC80LjRgtC1LCDRh9GC0L7QsdGLINGB0LrQvtC/0LjRgNC+0LLQsNGC0Ywg
0YHRgdGL0LvQutGDIjsKICAgICAgaS5hZGRFdmVudExpc3RlbmVyKCJjbGljayIsIGZ1bmN0aW9u
ICgpIHsKICAgICAgICBjb3B5VGV4dCh1cmwpLnRoZW4oZnVuY3Rpb24gKCkgeyB0b2FzdCgi0KHR
gdGL0LvQutCwINGB0LrQvtC/0LjRgNC+0LLQsNC90LAiKTsgfSkKICAgICAgICAgICAgICAgICAg
ICAgLmNhdGNoKGZ1bmN0aW9uICgpIHsgdG9hc3QoItCd0LUg0YPQtNCw0LvQvtGB0Ywg0YHQutC+
0L/QuNGA0L7QstCw0YLRjCIpOyB9KTsKICAgICAgfSk7CiAgICB9CiAgICByZXR1cm4gaTsKICB9
CiAgZnVuY3Rpb24gY2FyZChpdGVtLCBvcHRzKSB7CiAgICBvcHRzID0gb3B0cyB8fCB7fTsKICAg
IHZhciBkID0gZWwoImRpdiIsICJjYXJkIiArIChvcHRzLmhlcm8gPyAiIGhlcm8iIDogIiIpKTsK
ICAgIGQuYXBwZW5kQ2hpbGQoZWwoImRpdiIsICJsYWIiLCBvcHRzLmNvbXBhY3QgPyBzaG9ydExh
YmVsKGl0ZW0ubGFiZWwpIDogaXRlbS5sYWJlbCkpOwogICAgaWYgKGl0ZW0ucXIpIGQuYXBwZW5k
Q2hpbGQocXJJbWcoaXRlbS5xciwgaXRlbS51cmwpKTsKICAgIGlmIChpdGVtLmhpbnQpIGQuYXBw
ZW5kQ2hpbGQoZWwoInAiLCAiaGludCIsIGl0ZW0uaGludCkpOwogICAgaWYgKGl0ZW0udXJsICYm
ICFvcHRzLmhlcm8pIHsgdmFyIGEgPSBlbCgiYSIsICJidG4iLCBvcHRzLmNvbXBhY3QgPyAi0J7R
gtC60YDRi9GC0YwiIDogItCe0YLQutGA0YvRgtGMINCyINC/0YDQuNC70L7QttC10L3QuNC4Iik7
IGEuaHJlZiA9IGl0ZW0udXJsOyBkLmFwcGVuZENoaWxkKGEpOyB9CiAgICByZXR1cm4gZDsKICB9
CiAgZnVuY3Rpb24gcm93KGl0ZW1zKSB7CiAgICB2YXIgZyA9IGVsKCJkaXYiLCAicm93Iik7CiAg
ICBpdGVtcy5mb3JFYWNoKGZ1bmN0aW9uIChpdCkgeyBnLmFwcGVuZENoaWxkKGNhcmQoaXQsIHsg
Y29tcGFjdDogdHJ1ZSB9KSk7IH0pOwogICAgcmV0dXJuIGc7CiAgfQoKICBmZXRjaCgiY29uZmln
Lmpzb24iLCB7IGNhY2hlOiAibm8tc3RvcmUiIH0pCiAgICAudGhlbihmdW5jdGlvbiAocikgeyBy
ZXR1cm4gci5qc29uKCk7IH0pCiAgICAudGhlbihmdW5jdGlvbiAoY2ZnKSB7CiAgICAgIHJvb3Qu
aW5uZXJIVE1MID0gIiI7CiAgICAgIHZhciBiID0gZWwoImRpdiIsICJicmFuZCIpOwogICAgICB2
YXIgbG9nbyA9IGVsKCJpbWciKTsgbG9nby5zcmMgPSAiL2MvYXNzZXRzL2Zhdmljb24uc3ZnIjsg
bG9nby5hbHQgPSAiIjsgYi5hcHBlbmRDaGlsZChsb2dvKTsKICAgICAgYi5hcHBlbmRDaGlsZChl
bCgiaDEiLCBudWxsLCBjZmcuc2VydmVyX25hbWUgfHwgIlZQTiIpKTsKICAgICAgYi5hcHBlbmRD
aGlsZChlbCgicCIsICJ0YWciLCAi0JfQsNGJ0LjRidGR0L3QvdC+0LUg0L/QvtC00LrQu9GO0YfQ
tdC90LjQtSIpKTsKICAgICAgaWYgKGNmZy5jbGllbnRfbmFtZSkgeyB2YXIgYyA9IGVsKCJkaXYi
LCAiY2xpZW50Iik7IGMuaW5uZXJIVE1MID0gItCf0L7QtNC60LvRjtGH0LXQvdC40LUg0LTQu9GP
IDxiPjwvYj4iOyBjLnF1ZXJ5U2VsZWN0b3IoImIiKS50ZXh0Q29udGVudCA9IGNmZy5jbGllbnRf
bmFtZTsgYi5hcHBlbmRDaGlsZChjKTsgfQogICAgICBiLmFwcGVuZENoaWxkKGVsKCJwIiwgIm5v
dGUiLCAi0J3QsNC20LzQuNGC0LUg0L3QsCBRUi3QutC+0LQsINGH0YLQvtCx0Ysg0YHQutC+0L/Q
uNGA0L7QstCw0YLRjCDRgdGB0YvQu9C60YMiKSk7CiAgICAgIHJvb3QuYXBwZW5kQ2hpbGQoYik7
CgogICAgICBpZiAoY2ZnLnN1YnNjcmlwdGlvbl9xcikgewogICAgICAgIHJvb3QuYXBwZW5kQ2hp
bGQoZWwoImRpdiIsICJzZWN0aXRsZSIsICLQktGB0Y8g0L/QvtC00L/QuNGB0LrQsCIpKTsKICAg
ICAgICByb290LmFwcGVuZENoaWxkKGNhcmQoeyBsYWJlbDogItCS0YHQtSDQv9GA0L7RgtC+0LrQ
vtC70Ysg0YHRgNCw0LfRgyIsIHVybDogY2ZnLnN1YnNjcmlwdGlvbl91cmwsIHFyOiBjZmcuc3Vi
c2NyaXB0aW9uX3FyLAogICAgICAgICAgaGludDogItCe0YLRgdC60LDQvdC40YDRg9C50YLQtSDQ
uNC70Lgg0L3QsNC20LzQuNGC0LUsINGH0YLQvtCx0Ysg0YHQutC+0L/QuNGA0L7QstCw0YLRjCIg
fSwgeyBoZXJvOiB0cnVlIH0pKTsKICAgICAgfQogICAgICAoY2ZnLnJlbGF5cyB8fCBbXSkuZm9y
RWFjaChmdW5jdGlvbiAocmwpIHsKICAgICAgICByb290LmFwcGVuZENoaWxkKGVsKCJkaXYiLCAi
c2VjdGl0bGUiLCAi0KfQtdGA0LXQtyDRgNC10LvQtdC5ICIgKyAocmwubmFtZSB8fCAiIikpKTsK
ICAgICAgICByb290LmFwcGVuZENoaWxkKHJvdyhybC51cmxzIHx8IFtdKSk7CiAgICAgIH0pOwog
ICAgICBpZiAoKGNmZy5wcm90b2NvbHMgfHwgW10pLmxlbmd0aCkgewogICAgICAgIHJvb3QuYXBw
ZW5kQ2hpbGQoZWwoImRpdiIsICJzZWN0aXRsZSIsICLQn9GA0Y/QvNC+0LUg0L/QvtC00LrQu9GO
0YfQtdC90LjQtSIpKTsKICAgICAgICByb290LmFwcGVuZENoaWxkKHJvdyhjZmcucHJvdG9jb2xz
KSk7CiAgICAgIH0KICAgIH0pCiAgICAuY2F0Y2goZnVuY3Rpb24gKCkgeyByb290LmlubmVySFRN
TCA9ICc8cCBjbGFzcz0iZXJyIj7QndC1INGD0LTQsNC70L7RgdGMINC30LDQs9GA0YPQt9C40YLR
jCDQtNCw0L3QvdGL0LUg0L/QvtC00LrQu9GO0YfQtdC90LjRjy48L3A+JzsgfSk7Cn0pKCk7Cl9f
QVBQSlNfXwpjYXQgPiAiJEJBU0UvYXNzZXRzL2Zhdmljb24uc3ZnIiA8PCdfX0ZBVl9fJwo8c3Zn
IHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iLTIgLTIgMjggMjgi
PgogIDxkZWZzPjxsaW5lYXJHcmFkaWVudCBpZD0iZyIgeDE9IjAiIHkxPSIwIiB4Mj0iMSIgeTI9
IjEiPgogICAgPHN0b3Agb2Zmc2V0PSIwIiBzdG9wLWNvbG9yPSIjNWI3Y2ZhIi8+PHN0b3Agb2Zm
c2V0PSIxIiBzdG9wLWNvbG9yPSIjOGE2Y2Y2Ii8+CiAgPC9saW5lYXJHcmFkaWVudD48L2RlZnM+
CiAgPHBhdGggZD0iTTE5LjM1IDEwLjA0QzE4LjY3IDYuNTkgMTUuNjQgNCAxMiA0IDkuMTEgNCA2
LjYgNS42NCA1LjM1IDguMDQgMi4zNCA4LjM2IDAgMTAuOTEgMCAxNGMwIDMuMzEgMi42OSA2IDYg
NmgxM2MyLjc2IDAgNS0yLjI0IDUtNSAwLTIuNjQtMi4wNS00Ljc4LTQuNjUtNC45NnoiCiAgICAg
ICAgZmlsbD0idXJsKCNnKSIgc3Ryb2tlPSIjM2EzZmFlIiBzdHJva2Utd2lkdGg9IjEuMSIgc3Ry
b2tlLWxpbmVqb2luPSJyb3VuZCIvPgo8L3N2Zz4KX19GQVZfXwpjYXQgPiAiJEJBU0UvX3RwbC9p
bmRleC5odG1sIiA8PCdfX1RQTF9fJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0icnUiPgo8
aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVu
dD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+QEBCUkFOREBA
PC90aXRsZT4KPGxpbmsgcmVsPSJpY29uIiB0eXBlPSJpbWFnZS9zdmcreG1sIiBocmVmPSIvYy9h
c3NldHMvZmF2aWNvbi5zdmciPgo8bWV0YSBuYW1lPSJ0aGVtZS1jb2xvciIgY29udGVudD0iIzBi
MGQxMyI+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2MvYXNzZXRzL3N0eWxlLmNzcyI+
CjwvaGVhZD4KPGJvZHk+CjxtYWluIGlkPSJhcHAiIGNsYXNzPSJ3cmFwIj48cCBjbGFzcz0idGFn
IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXIiPtCX0LDQs9GA0YPQt9C60LDigKY8L3A+PC9tYWlu
Pgo8c2NyaXB0IHNyYz0iL2MvYXNzZXRzL2FwcC5qcyI+PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1s
PgpfX1RQTF9fCmNhdCA+ICIkQkFTRS9nZW5fY29uZmlnLnB5IiA8PCdfX0dFTl9fJwojIS91c3Iv
YmluL2VudiBweXRob24zCiIiItCc0LjQvdC40LzQsNC70YzQvdGL0Lkg0LPQtdC90LXRgNCw0YLQ
vtGAIGNvbmZpZy5qc29uINC00LvRjyDRgdGC0YDQsNC90LjRhtGLIEBAQlJBTkRAQC4K0JjRgdC/
0L7Qu9GM0LfQvtCy0LDQvdC40LU6IGdlbl9jb25maWcucHkgPHN1Yl9maWxlPiBbY2xpZW50X25h
bWVdIFtzdWJzY3JpcHRpb25fdXJsXSIiIgppbXBvcnQgc3lzLCBqc29uLCBiYXNlNjQsIGlvLCBy
ZQpmcm9tIHVybGxpYi5wYXJzZSBpbXBvcnQgdW5xdW90ZSwgcXVvdGUKdHJ5OgogICAgaW1wb3J0
IHNlZ25vCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIHN5cy5leGl0KCLQndGD0LbQtdC9IHNlZ25v
OiBhcHQtZ2V0IGluc3RhbGwgLXkgcHl0aG9uMy1zZWdubyIpCgpTRVJWRVJfTkFNRSA9ICJAQEJS
QU5EQEAiClJFTEFZX1NVRkZJWCA9ICJAQFJFTEFZX0RPTUFJTkBAIgpSRUxBWV9OQU1FICAgPSAi
QEBSRUxBWV9OQU1FQEAiCkhZMl9UTVBMID0gImh5c3RlcmlhMjovL3t1dWlkfUB7aG9zdH06NDQz
Lz9zbmk9e2hvc3R9JmFscG49aDMmaW5zZWN1cmU9MCN7bmFtZX0iCgpkZWYgcXIodSk6CiAgICBi
ID0gaW8uQnl0ZXNJTygpOyBzZWduby5tYWtlKHUpLnNhdmUoYiwga2luZD0icG5nIiwgc2NhbGU9
MTApCiAgICByZXR1cm4gYmFzZTY0LmI2NGVuY29kZShiLmdldHZhbHVlKCkpLmRlY29kZSgpCmRl
ZiBsYWJlbF9vZih1KTogcmV0dXJuIHVucXVvdGUodS5zcGxpdCgiIyIsMSlbMV0pIGlmICIjIiBp
biB1IGVsc2UgItCf0L7QtNC60LvRjtGH0LXQvdC40LUiCmRlZiBob3N0X29mKHUpOgogICAgbSA9
IHJlLnNlYXJjaChyJ0AoW146Lz8jXSspJywgdSk7IHJldHVybiBtLmdyb3VwKDEpIGlmIG0gZWxz
ZSAiIgpkZWYgYmFzZV9sYWJlbChsKTogcmV0dXJuIHJlLnN1YihyJ1xzKlwoW14pXSpcKVxzKiQn
LCcnLCBsKS5zdHJpcCgpCgpyYXcgPSBvcGVuKHN5cy5hcmd2WzFdLCBlbmNvZGluZz0idXRmLTgi
LCBlcnJvcnM9InJlcGxhY2UiKS5yZWFkKCkuc3RyaXAoKQpjbGllbnQgID0gc3lzLmFyZ3ZbMl0g
aWYgbGVuKHN5cy5hcmd2KSA+IDIgZWxzZSAiIgpzdWJfdXJsID0gc3lzLmFyZ3ZbM10gaWYgbGVu
KHN5cy5hcmd2KSA+IDMgZWxzZSAiIgoKbGlua3MgPSBbXQp0cnk6IGogPSBqc29uLmxvYWRzKHJh
dykKZXhjZXB0IEV4Y2VwdGlvbjogaiA9IE5vbmUKaWYgaXNpbnN0YW5jZShqLCBkaWN0KSBhbmQg
ai5nZXQoImxpbmtzIik6CiAgICBsaW5rcyA9IGpbImxpbmtzIl07IGNsaWVudCA9IGNsaWVudCBv
ciAoai5nZXQoInVzZXIiKSBvciB7fSkuZ2V0KCJ1c2VybmFtZSIsIiIpCmVsc2U6CiAgICB0ZXh0
ID0gcmF3CiAgICBpZiAiOi8vIiBub3QgaW4gcmF3OgogICAgICAgIHRyeToKICAgICAgICAgICAg
ZCA9IGJhc2U2NC5iNjRkZWNvZGUocmF3ICsgIj0iKigtbGVuKHJhdyklNCkpLmRlY29kZSgidXRm
LTgiLCJyZXBsYWNlIikKICAgICAgICAgICAgaWYgIjovLyIgaW4gZDogdGV4dCA9IGQKICAgICAg
ICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICBsaW5rcyA9IFt4LnN0cmlwKCkgZm9yIHggaW4g
dGV4dC5zcGxpdGxpbmVzKCkgaWYgIjovLyIgaW4geF0KCnByb3RvY29scyA9IFtdOyByZWxheV91
cmxzID0gW10KZm9yIHUgaW4gbGlua3M6CiAgICBpZiBub3QgdTogY29udGludWUKICAgIGl0ZW0g
PSB7ImxhYmVsIjogbGFiZWxfb2YodSksICJ1cmwiOiB1LCAicXIiOiBxcih1KX0KICAgIChyZWxh
eV91cmxzIGlmIGhvc3Rfb2YodSkuZW5kc3dpdGgoUkVMQVlfU1VGRklYKSBlbHNlIHByb3RvY29s
cykuYXBwZW5kKGl0ZW0pCgptID0gcmUuc2VhcmNoKHIndmxlc3M6Ly8oW15AP10rKUAnLCAiICIu
am9pbihsaW5rcykpCmlmIG06CiAgICB1dWlkID0gbS5ncm91cCgxKQogICAgaWYgcHJvdG9jb2xz
OgogICAgICAgIGggPSBob3N0X29mKHByb3RvY29sc1swXVsidXJsIl0pOyBubSA9IChiYXNlX2xh
YmVsKHByb3RvY29sc1swXVsibGFiZWwiXSkgb3IgIkRpcmVjdCIpKyIgKEh5c3RlcmlhMikiCiAg
ICAgICAgdSA9IEhZMl9UTVBMLmZvcm1hdCh1dWlkPXV1aWQsIGhvc3Q9aCwgbmFtZT1xdW90ZShu
bSwgc2FmZT0iKCkiKSkKICAgICAgICBwcm90b2NvbHMuYXBwZW5kKHsibGFiZWwiOiBubSwgInVy
bCI6IHUsICJxciI6IHFyKHUpfSkKICAgIGlmIHJlbGF5X3VybHM6CiAgICAgICAgaCA9IGhvc3Rf
b2YocmVsYXlfdXJsc1swXVsidXJsIl0pOyBubSA9IChiYXNlX2xhYmVsKHJlbGF5X3VybHNbMF1b
ImxhYmVsIl0pIG9yIFJFTEFZX05BTUUpKyIgKEh5c3RlcmlhMikiCiAgICAgICAgdSA9IEhZMl9U
TVBMLmZvcm1hdCh1dWlkPXV1aWQsIGhvc3Q9aCwgbmFtZT1xdW90ZShubSwgc2FmZT0iKCkiKSkK
ICAgICAgICByZWxheV91cmxzLmFwcGVuZCh7ImxhYmVsIjogbm0sICJ1cmwiOiB1LCAicXIiOiBx
cih1KX0pCgpjZmcgPSB7ImNsaWVudF9uYW1lIjogY2xpZW50LCAic2VydmVyX25hbWUiOiBTRVJW
RVJfTkFNRSwgInByb3RvY29scyI6IHByb3RvY29scywKICAgICAgICJyZWxheXMiOiBbeyJuYW1l
IjogUkVMQVlfTkFNRSwgInVybHMiOiByZWxheV91cmxzfV0gaWYgcmVsYXlfdXJscyBlbHNlIFtd
fQppZiBzdWJfdXJsOgogICAgY2ZnWyJzdWJzY3JpcHRpb25fdXJsIl0gPSBzdWJfdXJsCiAgICBj
ZmdbInN1YnNjcmlwdGlvbl9xciJdICA9IHFyKHN1Yl91cmwpCnByaW50KGpzb24uZHVtcHMoY2Zn
LCBlbnN1cmVfYXNjaWk9RmFsc2UsIGluZGVudD0yKSkKX19HRU5fXwpjYXQgPiAiJEJBU0UvY29u
bmVjdC1zZXJ2ZS5weSIgPDwnX19TRVJWRV9fJwojIS91c3IvYmluL2VudiBweXRob24zCiIiIkBA
QlJBTkRAQCBjb25uZWN0ICjQvNC40L3QuNC80LDQu9GM0L3Ri9C5ICsgdW1uYXlhINC/0L7QtNC/
0LjRgdC60LApLiDQodC90Y/RgtC40LUg0L7Qs9GA0LDQvdC40YfQtdC90LjQuSDQvdCwINC/0L7R
gNGC0YMgMzAxNS4iIiIKaW1wb3J0IG9zLCByZSwgc3lzLCB0aW1lLCBzdWJwcm9jZXNzLCBtaW1l
dHlwZXMsIGJhc2U2NApmcm9tIGh0dHAuc2VydmVyIGltcG9ydCBCYXNlSFRUUFJlcXVlc3RIYW5k
bGVyLCBUaHJlYWRpbmdIVFRQU2VydmVyCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCB1bnF1b3Rl
LCBxdW90ZQoKQkFTRSAgID0gIi9vcHQvQEBTTFVHQEAvY29ubmVjdCIKQVNTRVRTID0gb3MucGF0
aC5qb2luKEJBU0UsICJhc3NldHMiKQpUUEwgICAgPSBvcy5wYXRoLmpvaW4oQkFTRSwgIl90cGwi
LCAiaW5kZXguaHRtbCIpCkdFTiAgICA9IG9zLnBhdGguam9pbihCQVNFLCAiZ2VuX2NvbmZpZy5w
eSIpCkRPTUFJTiA9ICJAQE1BSU5fRE9NQUlOQEAiCkxJU1RFTiA9ICgiMTI3LjAuMC4xIiwgMzAx
NSkKTUFYX0FHRSA9IDg2NDAwClJFTEFZX1NVRkZJWCA9ICJAQFJFTEFZX0RPTUFJTkBAIgpSRU1B
UktfRk1UID0gInt1c2VyfSDCtyB7bmFtZX0iCkhZMl9UTVBMID0gImh5c3RlcmlhMjovL3t1dWlk
fUB7aG9zdH06NDQzLz9zbmk9e2hvc3R9JmFscG49aDMmaW5zZWN1cmU9MCN7bmFtZX0iClVVSURf
UkUgPSByZS5jb21waWxlKHInXltBLVphLXowLTkuXy1dezQsNjR9JCcpClNBRkUgPSB7IiIsICJp
bmRleC5odG1sIiwgImNvbmZpZy5qc29uIn0KbWltZXR5cGVzLmFkZF90eXBlKCJhcHBsaWNhdGlv
bi9qYXZhc2NyaXB0IiwgIi5qcyIpCm1pbWV0eXBlcy5hZGRfdHlwZSgiaW1hZ2Uvc3ZnK3htbCIs
ICIuc3ZnIikKCmRlZiBfaG9zdCh1KToKICAgIG0gPSByZS5zZWFyY2gocidAKFteOi8/I10rKScs
IHUpOyByZXR1cm4gbS5ncm91cCgxKSBpZiBtIGVsc2UgIiIKZGVmIF9iYXNlbmFtZSh1KToKICAg
IGYgPSB1LnNwbGl0KCIjIiwxKVsxXSBpZiAiIyIgaW4gdSBlbHNlICIiCiAgICByZXR1cm4gcmUu
c3ViKHInXHMqXChbXildKlwpXHMqJCcsJycsIHVucXVvdGUoZikpLnN0cmlwKCkKCmRlZiBnZW4o
dXVpZCk6CiAgICBkID0gb3MucGF0aC5qb2luKEJBU0UsIHV1aWQpOyBjZmcgPSBvcy5wYXRoLmpv
aW4oZCwgImNvbmZpZy5qc29uIikKICAgIGlmIG9zLnBhdGguZXhpc3RzKGNmZykgYW5kIHRpbWUu
dGltZSgpLW9zLnBhdGguZ2V0bXRpbWUoY2ZnKSA8IE1BWF9BR0U6CiAgICAgICAgcmV0dXJuIFRy
dWUKICAgIHNmeCA9ICIlZF8lZCIgJSAob3MuZ2V0cGlkKCksIHRpbWUudGltZV9ucygpICUgMTAw
MDAwMCkKICAgIGhmID0gIi90bXAvX2hfIitzZng7IGJmID0gIi90bXAvX3NfIitzZngKICAgIHRy
eToKICAgICAgICByID0gc3VicHJvY2Vzcy5ydW4oWyJjdXJsIiwiLWZzU2siLCItRCIsaGYsIi0t
cmVzb2x2ZSIsRE9NQUlOKyI6ODQ0MzoxMjcuMC4wLjEiLAogICAgICAgICAgICAgICAgICAgICAg
ICAgICAgIi1IIiwiVXNlci1BZ2VudDogTW96aWxsYS81LjAiLAogICAgICAgICAgICAgICAgICAg
ICAgICAgICAgImh0dHBzOi8vJXM6ODQ0My9hcGkvc3ViLyVzIiAlIChET01BSU4sIHV1aWQpLCIt
byIsYmZdLAogICAgICAgICAgICAgICAgICAgICAgICAgICBjYXB0dXJlX291dHB1dD1UcnVlLCB0
aW1lb3V0PTIwKQogICAgICAgIGlmIHIucmV0dXJuY29kZSAhPSAwIG9yIG5vdCBvcy5wYXRoLmV4
aXN0cyhiZikgb3Igb3MucGF0aC5nZXRzaXplKGJmKSA9PSAwOgogICAgICAgICAgICByZXR1cm4g
b3MucGF0aC5leGlzdHMoY2ZnKQogICAgICAgIGNsaWVudCA9IHV1aWQKICAgICAgICB0cnk6CiAg
ICAgICAgICAgIG0gPSByZS5zZWFyY2gocidmaWxlbmFtZT0iPyhbXiJcclxuO10rKScsIG9wZW4o
aGYsZW5jb2Rpbmc9InV0Zi04IixlcnJvcnM9InJlcGxhY2UiKS5yZWFkKCksIHJlLkkpCiAgICAg
ICAgICAgIGlmIG06IGNsaWVudCA9IG0uZ3JvdXAoMSkuc3RyaXAoKQogICAgICAgIGV4Y2VwdCBF
eGNlcHRpb246IHBhc3MKICAgICAgICBwdWIgPSAiaHR0cHM6Ly8lcy9jLyVzL3N1YiIgJSAoRE9N
QUlOLCB1dWlkKQogICAgICAgIG91dCA9IHN1YnByb2Nlc3MucnVuKFtzeXMuZXhlY3V0YWJsZSwg
R0VOLCBiZiwgY2xpZW50LCBwdWJdLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0aW1lb3V0PTMwLCB0
ZXh0PVRydWUpCiAgICAgICAgaWYgb3V0LnJldHVybmNvZGUgIT0gMCBvciBub3Qgb3V0LnN0ZG91
dC5zdHJpcCgpOgogICAgICAgICAgICByZXR1cm4gb3MucGF0aC5leGlzdHMoY2ZnKQogICAgICAg
IG9zLm1ha2VkaXJzKGQsIGV4aXN0X29rPVRydWUpCiAgICAgICAgb3BlbihjZmcsICJ3IiwgZW5j
b2Rpbmc9InV0Zi04Iikud3JpdGUob3V0LnN0ZG91dCkKICAgICAgICBpZiBvcy5wYXRoLmV4aXN0
cyhUUEwpOgogICAgICAgICAgICBvcGVuKG9zLnBhdGguam9pbihkLCAiaW5kZXguaHRtbCIpLCAi
dyIsIGVuY29kaW5nPSJ1dGYtOCIpLndyaXRlKG9wZW4oVFBMLCBlbmNvZGluZz0idXRmLTgiKS5y
ZWFkKCkpCiAgICAgICAgcmV0dXJuIFRydWUKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAg
cmV0dXJuIG9zLnBhdGguZXhpc3RzKGNmZykKICAgIGZpbmFsbHk6CiAgICAgICAgZm9yIHggaW4g
KGhmLCBiZik6CiAgICAgICAgICAgIHRyeTogb3MucmVtb3ZlKHgpCiAgICAgICAgICAgIGV4Y2Vw
dCBFeGNlcHRpb246IHBhc3MKCmRlZiBfc21hcnRfYjY0KGI2NGJvZHksIHVzZXJuYW1lKToKICAg
IHRyeToKICAgICAgICB0eHQgPSBiYXNlNjQuYjY0ZGVjb2RlKGI2NGJvZHkuc3RyaXAoKSsiPSIq
KC1sZW4oYjY0Ym9keS5zdHJpcCgpKSU0KSkuZGVjb2RlKCJ1dGYtOCIpCiAgICBleGNlcHQgRXhj
ZXB0aW9uOgogICAgICAgIHJldHVybiBOb25lCiAgICBpZiAidmxlc3M6Ly8iIG5vdCBpbiB0eHQ6
CiAgICAgICAgcmV0dXJuIE5vbmUKICAgIGxpbmtzID0gW2wuc3RyaXAoKSBmb3IgbCBpbiB0eHQu
c3BsaXRsaW5lcygpIGlmICI6Ly8iIGluIGxdCiAgICBpZiAiaHlzdGVyaWEyOi8vIiBub3QgaW4g
dHh0OgogICAgICAgIG0gPSByZS5zZWFyY2gocid2bGVzczovLyhbXkA/XSspQCcsIHR4dCkKICAg
ICAgICBpZiBtOgogICAgICAgICAgICB1dWlkID0gbS5ncm91cCgxKQogICAgICAgICAgICBkaXJl
Y3QgPSBuZXh0KChsIGZvciBsIGluIGxpbmtzIGlmIG5vdCBfaG9zdChsKS5lbmRzd2l0aChSRUxB
WV9TVUZGSVgpKSwgIiIpCiAgICAgICAgICAgIHJlbGF5ICA9IG5leHQoKGwgZm9yIGwgaW4gbGlu
a3MgaWYgX2hvc3QobCkuZW5kc3dpdGgoUkVMQVlfU1VGRklYKSksICIiKQogICAgICAgICAgICBp
ZiBkaXJlY3Q6IGxpbmtzLmFwcGVuZChIWTJfVE1QTC5mb3JtYXQodXVpZD11dWlkLCBob3N0PV9o
b3N0KGRpcmVjdCksIG5hbWU9KF9iYXNlbmFtZShkaXJlY3QpIG9yICJEaXJlY3QiKSsiIChIeXN0
ZXJpYTIpIikpCiAgICAgICAgICAgIGlmIHJlbGF5OiAgbGlua3MuYXBwZW5kKEhZMl9UTVBMLmZv
cm1hdCh1dWlkPXV1aWQsIGhvc3Q9X2hvc3QocmVsYXkpLCAgbmFtZT0oX2Jhc2VuYW1lKHJlbGF5
KSBvciAiUmVsYXkiKSsiIChIeXN0ZXJpYTIpIikpCiAgICBvdXQgPSBbXQogICAgZm9yIGwgaW4g
bGlua3M6CiAgICAgICAgYmFzZV9wYXJ0LCBzZXAsIGZyYWcgPSBsLnBhcnRpdGlvbigiIyIpCiAg
ICAgICAgbmFtZSA9IHVucXVvdGUoZnJhZykgaWYgZnJhZyBlbHNlICLQn9C+0LTQutC70Y7Rh9C1
0L3QuNC1IgogICAgICAgIGlmIHVzZXJuYW1lIGFuZCBub3QgbmFtZS5zdGFydHN3aXRoKHVzZXJu
YW1lICsgIiAiKToKICAgICAgICAgICAgbmFtZSA9IFJFTUFSS19GTVQuZm9ybWF0KHVzZXI9dXNl
cm5hbWUsIG5hbWU9bmFtZSkKICAgICAgICBvdXQuYXBwZW5kKGJhc2VfcGFydCArICIjIiArIHF1
b3RlKG5hbWUsIHNhZmU9IigpIikpCiAgICByZXR1cm4gYmFzZTY0LmI2NGVuY29kZSgiXG4iLmpv
aW4ob3V0KS5lbmNvZGUoKSkuZGVjb2RlKCkKCmNsYXNzIEgoQmFzZUhUVFBSZXF1ZXN0SGFuZGxl
cik6CiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEpOiBwYXNzCiAgICBkZWYgX3NlbmQoc2Vs
ZiwgcGF0aCk6CiAgICAgICAgY3QgPSBtaW1ldHlwZXMuZ3Vlc3NfdHlwZShwYXRoKVswXSBvciAi
YXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtIgogICAgICAgIGIgPSBvcGVuKHBhdGgsICJyYiIpLnJl
YWQoKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSgyMDApOyBzZWxmLnNlbmRfaGVhZGVyKCJD
b250ZW50LVR5cGUiLCBjdCkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0
aCIsIHN0cihsZW4oYikpKTsgc2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgaWYgc2VsZi5jb21t
YW5kICE9ICJIRUFEIjogc2VsZi53ZmlsZS53cml0ZShiKQogICAgZGVmIF80MDQoc2VsZik6CiAg
ICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKDQwNCk7IHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQt
VHlwZSIsInRleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgiKQogICAgICAgIHNlbGYuc2VuZF9oZWFk
ZXIoIkNvbnRlbnQtTGVuZ3RoIiwiOSIpOyBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBpZiBz
ZWxmLmNvbW1hbmQgIT0gIkhFQUQiOiBzZWxmLndmaWxlLndyaXRlKGIiTm90IGZvdW5kIikKICAg
IGRlZiBwcm94eV9zdWIoc2VsZiwgdXVpZCk6CiAgICAgICAgdWEgID0gc2VsZi5oZWFkZXJzLmdl
dCgiVXNlci1BZ2VudCIsICJNb3ppbGxhLzUuMCIpCiAgICAgICAgYWNjID0gc2VsZi5oZWFkZXJz
LmdldCgiQWNjZXB0IiwgIiovKiIpCiAgICAgICAgaWYgInRleHQvaHRtbCIgaW4gYWNjLmxvd2Vy
KCk6IGFjYyA9ICIqLyoiCiAgICAgICAgc2Z4ID0gIiVkXyVkIiAlIChvcy5nZXRwaWQoKSwgdGlt
ZS50aW1lX25zKCkgJSAxMDAwMDAwKQogICAgICAgIGhmID0gIi90bXAvX3BoXyIrc2Z4OyBiZiA9
ICIvdG1wL19wYl8iK3NmeAogICAgICAgIHRyeToKICAgICAgICAgICAgciA9IHN1YnByb2Nlc3Mu
cnVuKFsiY3VybCIsIi1mc1NrIiwiLUQiLGhmLCItLXJlc29sdmUiLERPTUFJTisiOjg0NDM6MTI3
LjAuMC4xIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiLUgiLCJVc2VyLUFnZW50
OiAiK3VhLCItSCIsIkFjY2VwdDogIithY2MsIi1IIiwiQWNjZXB0LUVuY29kaW5nOiBpZGVudGl0
eSIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgImh0dHBzOi8vJXM6ODQ0My9hcGkv
c3ViLyVzIiAlIChET01BSU4sIHV1aWQpLCItbyIsYmZdLAogICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGltZW91dD0yMCkKICAgICAgICAgICAgaWYg
ci5yZXR1cm5jb2RlICE9IDAgb3Igbm90IG9zLnBhdGguZXhpc3RzKGJmKToKICAgICAgICAgICAg
ICAgIHJldHVybiBzZWxmLl80MDQoKQogICAgICAgICAgICBib2R5ID0gb3BlbihiZiwgInJiIiku
cmVhZCgpCiAgICAgICAgICAgIHJhd2ggPSBvcGVuKGhmLCBlbmNvZGluZz0idXRmLTgiLCBlcnJv
cnM9InJlcGxhY2UiKS5yZWFkKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAg
ICByZXR1cm4gc2VsZi5fNDA0KCkKICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICBmb3IgeCBp
biAoaGYsIGJmKToKICAgICAgICAgICAgICAgIHRyeTogb3MucmVtb3ZlKHgpCiAgICAgICAgICAg
ICAgICBleGNlcHQgRXhjZXB0aW9uOiBwYXNzCiAgICAgICAgdXNlcm5hbWUgPSB1dWlkOyBjdHlw
ZSA9ICIiOyBmd2QgPSBbXQogICAgICAgIGZvciBsaW5lIGluIHJhd2guc3BsaXRsaW5lcygpOgog
ICAgICAgICAgICBpZiAiOiIgbm90IGluIGxpbmU6IGNvbnRpbnVlCiAgICAgICAgICAgIGssIHYg
PSBsaW5lLnNwbGl0KCI6IiwgMSk7IGsgPSBrLnN0cmlwKCk7IHYgPSB2LnN0cmlwKCk7IGtsID0g
ay5sb3dlcigpCiAgICAgICAgICAgIGlmIGtsID09ICJjb250ZW50LWRpc3Bvc2l0aW9uIjoKICAg
ICAgICAgICAgICAgIG0gPSByZS5zZWFyY2gocidmaWxlbmFtZT0iPyhbXiJcclxuO10rKScsIHYp
CiAgICAgICAgICAgICAgICBpZiBtOiB1c2VybmFtZSA9IG0uZ3JvdXAoMSkuc3RyaXAoKQogICAg
ICAgICAgICBpZiBrbCA9PSAiY29udGVudC10eXBlIjogY3R5cGUgPSB2Lmxvd2VyKCkKICAgICAg
ICAgICAgZndkLmFwcGVuZCgoaywgdikpCiAgICAgICAgaWYgInRleHQvcGxhaW4iIGluIGN0eXBl
OgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBuYiA9IF9zbWFydF9iNjQoYm9keS5k
ZWNvZGUoImFzY2lpIiwgInJlcGxhY2UiKSwgdXNlcm5hbWUpCiAgICAgICAgICAgICAgICBpZiBu
YjogYm9keSA9IG5iLmVuY29kZSgiYXNjaWkiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9u
OiBwYXNzCiAgICAgICAgdGl0bGUgPSAiYmFzZTY0OiIgKyBiYXNlNjQuYjY0ZW5jb2RlKHVzZXJu
YW1lLmVuY29kZSgpKS5kZWNvZGUoKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZSgyMDApCiAg
ICAgICAgc2tpcCA9IHsiY29udGVudC1sZW5ndGgiLCJ0cmFuc2Zlci1lbmNvZGluZyIsImNvbm5l
Y3Rpb24iLCJjb250ZW50LWVuY29kaW5nIiwKICAgICAgICAgICAgICAgICJwcm9maWxlLXRpdGxl
Iiwia2VlcC1hbGl2ZSIsImRhdGUiLCJzZXJ2ZXIiLCJhbHQtc3ZjIiwidmlhIn0KICAgICAgICBm
b3IgaywgdiBpbiBmd2Q6CiAgICAgICAgICAgIGlmIGsubG93ZXIoKSBpbiBza2lwOiBjb250aW51
ZQogICAgICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKGssIHYpCiAgICAgICAgc2VsZi5zZW5kX2hl
YWRlcigicHJvZmlsZS10aXRsZSIsIHRpdGxlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNv
bnRlbnQtTGVuZ3RoIiwgc3RyKGxlbihib2R5KSkpCiAgICAgICAgc2VsZi5lbmRfaGVhZGVycygp
CiAgICAgICAgaWYgc2VsZi5jb21tYW5kICE9ICJIRUFEIjogc2VsZi53ZmlsZS53cml0ZShib2R5
KQogICAgZGVmIGRvX0hFQUQoc2VsZik6IHNlbGYuZG9fR0VUKCkKICAgIGRlZiBkb19HRVQoc2Vs
Zik6CiAgICAgICAgcCA9IHNlbGYucGF0aC5zcGxpdCgiPyIsMSlbMF0uc3BsaXQoIiMiLDEpWzBd
CiAgICAgICAgaWYgbm90IHAuc3RhcnRzd2l0aCgiL2MvIik6IHJldHVybiBzZWxmLl80MDQoKQog
ICAgICAgIHN1YiA9IHBbMzpdCiAgICAgICAgaWYgc3ViLnN0YXJ0c3dpdGgoImFzc2V0cy8iKToK
ICAgICAgICAgICAgZnAgPSBvcy5wYXRoLm5vcm1wYXRoKG9zLnBhdGguam9pbihCQVNFLCBzdWIp
KQogICAgICAgICAgICBpZiBmcC5zdGFydHN3aXRoKEFTU0VUUyArIG9zLnNlcCkgYW5kIG9zLnBh
dGguaXNmaWxlKGZwKTogcmV0dXJuIHNlbGYuX3NlbmQoZnApCiAgICAgICAgICAgIHJldHVybiBz
ZWxmLl80MDQoKQogICAgICAgIHBhcnRzID0gc3ViLnNwbGl0KCIvIiwgMSk7IHV1aWQgPSBwYXJ0
c1swXTsgcmVzdCA9IHBhcnRzWzFdIGlmIGxlbihwYXJ0cykgPiAxIGVsc2UgIiIKICAgICAgICBp
ZiBub3QgVVVJRF9SRS5tYXRjaCh1dWlkKTogcmV0dXJuIHNlbGYuXzQwNCgpCiAgICAgICAgaWYg
cmVzdCA9PSAic3ViIjogcmV0dXJuIHNlbGYucHJveHlfc3ViKHV1aWQpCiAgICAgICAgaWYgcmVz
dCA9PSAiIiBhbmQgbm90IHAuZW5kc3dpdGgoIi8iKToKICAgICAgICAgICAgc2VsZi5zZW5kX3Jl
c3BvbnNlKDMwMSk7IHNlbGYuc2VuZF9oZWFkZXIoIkxvY2F0aW9uIiwgcCArICIvIik7IHNlbGYu
ZW5kX2hlYWRlcnMoKTsgcmV0dXJuCiAgICAgICAgaWYgcmVzdCBub3QgaW4gU0FGRTogcmV0dXJu
IHNlbGYuXzQwNCgpCiAgICAgICAgaWYgbm90IGdlbih1dWlkKTogcmV0dXJuIHNlbGYuXzQwNCgp
CiAgICAgICAgZnAgPSBvcy5wYXRoLmpvaW4oQkFTRSwgdXVpZCwgcmVzdCBvciAiaW5kZXguaHRt
bCIpCiAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUoZnApOiByZXR1cm4gc2VsZi5fc2VuZChmcCkK
ICAgICAgICByZXR1cm4gc2VsZi5fNDA0KCkKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAg
ICBwcmludCgiQEBTTFVHQEAtY29ubmVjdCBvbiAlczolZCIgJSBMSVNURU4sIGZsdXNoPVRydWUp
CiAgICBUaHJlYWRpbmdIVFRQU2VydmVyKExJU1RFTiwgSCkuc2VydmVfZm9yZXZlcigpCl9fU0VS
VkVfXwpweXRob24zIC1jICJpbXBvcnQgYXN0O2FzdC5wYXJzZShvcGVuKCckQkFTRS9nZW5fY29u
ZmlnLnB5JykucmVhZCgpKTthc3QucGFyc2Uob3BlbignJEJBU0UvY29ubmVjdC1zZXJ2ZS5weScp
LnJlYWQoKSkiICYmIGVjaG8gIiAgcHl0aG9uIE9LIgoKZWNobyAiPT0gWzQvNV0g0YHQtdGA0LLQ
uNGBIChzeXN0ZW1kIEBAU0xVR0BALWNvbm5lY3QsIDEyNy4wLjAuMTozMDE1KSA9PSIKY2F0ID4g
L2V0Yy9zeXN0ZW1kL3N5c3RlbS9AQFNMVUdAQC1jb25uZWN0LnNlcnZpY2UgPDwnX19VTklUX18n
CltVbml0XQpEZXNjcmlwdGlvbj1AQEJSQU5EQEAgY29ubmVjdCBwYWdlCkFmdGVyPW5ldHdvcmst
b25saW5lLnRhcmdldCBkb2NrZXIuc2VydmljZQpXYW50cz1uZXR3b3JrLW9ubGluZS50YXJnZXQK
CltTZXJ2aWNlXQpFeGVjU3RhcnQ9L3Vzci9iaW4vcHl0aG9uMyAvb3B0L0BAU0xVR0BAL2Nvbm5l
Y3QvY29ubmVjdC1zZXJ2ZS5weQpSZXN0YXJ0PWFsd2F5cwpSZXN0YXJ0U2VjPTIKVXNlcj1yb290
CgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQKX19VTklUX18Kc3lzdGVtY3Rs
IGRhZW1vbi1yZWxvYWQKc3lzdGVtY3RsIGVuYWJsZSBAQFNMVUdAQC1jb25uZWN0LnNlcnZpY2Ug
Pi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKc3lzdGVtY3RsIHJlc3RhcnQgQEBTTFVHQEAtY29ubmVj
dC5zZXJ2aWNlCnNsZWVwIDEKc3lzdGVtY3RsIGlzLWFjdGl2ZSAtLXF1aWV0IEBAU0xVR0BALWNv
bm5lY3Quc2VydmljZSAmJiBlY2hvICIgINGB0LXRgNCy0LjRgSDQt9Cw0L/Rg9GJ0LXQvSIgfHwg
eyBlY2hvICIgIOKdjCDQvdC1INGB0YLQsNGA0YLQvtCy0LDQuyI7IGpvdXJuYWxjdGwgLXUgQEBT
TFVHQEAtY29ubmVjdCAtLW5vLXBhZ2VyIC1uIDIwOyBleGl0IDE7IH0KCmlmIGdyZXAgLXEgInJl
dmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMTUiICIkQ0FERFlGSUxFIjsgdGhlbgogIGVjaG8gIiAg
Q2FkZHkg0YPQttC1INC+0YLQtNCw0ZHRgiAvYyAtPiDRgdC10YDQstC40YEiCmVsc2UKICBjcCAt
YSAiJENBRERZRklMRSIgIiRDQUREWUZJTEUuYmFrLiR0cyIKICBweXRob24zIC0gIiRDQUREWUZJ
TEUiIDw8J19fQ0FERFlfXycKaW1wb3J0IHN5cwpwPXN5cy5hcmd2WzFdOyBzPW9wZW4ocCkucmVh
ZCgpCmJsb2NrPSJcbiIuam9pbihbCiAiICAgIEBjcGFnZV9icm93c2VyIHsiLAogIiAgICAgICAg
cGF0aF9yZWdleHAgY3BpZCBeL2FwaS9zdWIvKFteL10rKS8/JCIsCiAiICAgICAgICBoZWFkZXIg
QWNjZXB0ICp0ZXh0L2h0bWwqIiwKICIgICAgfSIsCiAiICAgIHJlZGlyIEBjcGFnZV9icm93c2Vy
IC9jL3tyZS5jcGlkLjF9LyAzMDIiLAogIiAgICBoYW5kbGUgL2MvKiB7IiwKICIgICAgICAgIHJl
dmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMTUiLAogIiAgICB9IiwiIl0pCmFuY2hvcj0iICAgIGhh
bmRsZSB7XG4gICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjgwODBcbiAgICB9IgppZiBh
bmNob3IgaW4gczogb3BlbihwLCJ3Iikud3JpdGUocy5yZXBsYWNlKGFuY2hvciwgYmxvY2srYW5j
aG9yLDEpKTsgcHJpbnQoIiAgL2Mg0LTQvtCx0LDQstC70LXQvSDQsiBDYWRkeSIpCmVsc2U6IHBy
aW50KCIgIFdBUk46INGP0LrQvtGA0Ywg0LTQtdC60L7RjyDQvdC1INC90LDQudC00LXQvSDigJQg
0LTQvtCx0LDQstGMIC9jINCy0YDRg9GH0L3Rg9GOIikKX19DQUREWV9fCiAgZG9ja2VyIGV4ZWMg
IiRDQUREWV9DVFIiIGNhZGR5IHZhbGlkYXRlIC0tY29uZmlnIC9ldGMvY2FkZHkvQ2FkZHlmaWxl
ID4vZGV2L251bGwgMj4mMSBcCiAgICAmJiB7IGRvY2tlciBleGVjICIkQ0FERFlfQ1RSIiBjYWRk
eSByZWxvYWQgLS1jb25maWcgL2V0Yy9jYWRkeS9DYWRkeWZpbGUgMj4vZGV2L251bGwgfHwgZG9j
a2VyIHJlc3RhcnQgIiRDQUREWV9DVFIiID4vZGV2L251bGw7IGVjaG8gIiAgQ2FkZHkg0L/RgNC4
0LzQtdC90ZHQvSI7IH0gXAogICAgfHwgeyBlY2hvICIgIOKaoCB2YWxpZGF0ZSDQvdC1INC/0YDQ
vtGI0ZHQuyDigJQg0L7RgtC60LDRgiI7IGNwIC1hICIkQ0FERFlGSUxFLmJhay4kdHMiICIkQ0FE
RFlGSUxFIjsgZG9ja2VyIHJlc3RhcnQgIiRDQUREWV9DVFIiID4vZGV2L251bGw7IH0KZmkKCmVj
aG8gIj09IFs1LzVdINGB0LHQvtGA0LrQsCDQutC70LjQtdC90YLQsCAkU1VCX1VVSUQgKyDQv9GA
0L7QstC10YDQutCwID09IgpzZng9JCQKaWYgISBjdXJsIC1mc1NrIC1EICIvdG1wL19iX2guJHNm
eCIgLS1yZXNvbHZlIEBATUFJTl9ET01BSU5AQDo4NDQzOjEyNy4wLjAuMSAtSCAiVXNlci1BZ2Vu
dDogTW96aWxsYS81LjAiICJodHRwczovL0BATUFJTl9ET01BSU5AQDo4NDQzL2FwaS9zdWIvJFNV
Ql9VVUlEIiAtbyAiL3RtcC9fYl9zLiRzZngiOyB0aGVuCiAgZWNobyAiICAhIC9hcGkvc3ViLyRT
VUJfVVVJRCDQvdC10LTQvtGB0YLRg9C/0LXQvSAoSFRUUC3QvtGI0LjQsdC60LApIOKAlCDQv9C1
0YDQstC40YfQvdGD0Y4g0YHQsdC+0YDQutGDINC60LvQuNC10L3RgtCwINC/0YDQvtC/0YPRgdC6
0LDRji4iCiAgZWNobyAiICAgINCd0LUg0LrRgNC40YLQuNGH0L3Qvjog0YHRgtGA0LDQvdC40YbQ
sCAvYy88dXVpZD4vINGB0L7QsdC10YDRkdGC0YHRjyDQtNC70Y8g0YDQtdCw0LvRjNC90L7Qs9C+
INC60LvQuNC10L3RgtCwLiDQn9GA0L7QstC10YDRjCwg0YfRgtC+IFRFU1RfU1VCX1VVSUQg0LIg
L29wdC9AQFNMVUdAQC8uZGVwbG95L2RlcGxveS5jb25mID0g0YDQtdCw0LvRjNC90YvQuSBzaG9y
dFV1aWQg0LjQtyDQv9Cw0L3QtdC70LguIgogIHJtIC1mICIvdG1wL19iX2guJHNmeCIgIi90bXAv
X2Jfcy4kc2Z4IiAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgZXhpdCAwCmZpCkNMSUVOVD0kKGF3ayAt
RidmaWxlbmFtZT0nICd0b2xvd2VyKCQwKSB+IC9jb250ZW50LWRpc3Bvc2l0aW9uL3twcmludCAk
Mn0nICIvdG1wL19iX2guJHNmeCIgfCB0ciAtZCAnIlxyJyB8IGhlYWQgLTEpOyBbIC1uICIkQ0xJ
RU5UIiBdIHx8IENMSUVOVD0iJFNVQl9VVUlEIgpQVUI9Imh0dHBzOi8vQEBNQUlOX0RPTUFJTkBA
L2MvJFNVQl9VVUlEL3N1YiIKbWtkaXIgLXAgIiRCQVNFLyRTVUJfVVVJRCIKcHl0aG9uMyAiJEJB
U0UvZ2VuX2NvbmZpZy5weSIgIi90bXAvX2Jfcy4kc2Z4IiAiJENMSUVOVCIgIiRQVUIiID4gIiRC
QVNFLyRTVUJfVVVJRC9jb25maWcuanNvbiIKY3AgIiRCQVNFL190cGwvaW5kZXguaHRtbCIgIiRC
QVNFLyRTVUJfVVVJRC9pbmRleC5odG1sIgpybSAtZiAiL3RtcC9fYl9oLiRzZngiICIvdG1wL19i
X3MuJHNmeCIKZWNobyAiICDQutC70LjQtdC90YI6ICRDTElFTlQ7IGNvbmZpZzogJCh3YyAtYyA8
ICIkQkFTRS8kU1VCX1VVSUQvY29uZmlnLmpzb24iKSDQsdCw0LnRgiIKc2xlZXAgMQpSPSItLXJl
c29sdmUgQEBNQUlOX0RPTUFJTkBAOjg0NDM6MTI3LjAuMC4xIgpwcmludGYgIiAgL2MvYXNzZXRz
L2FwcC5qcyAgICAgIC0+ICI7IGN1cmwgLXNrIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2NvZGV9
XG4nICRSICJodHRwczovL0BATUFJTl9ET01BSU5AQDo4NDQzL2MvYXNzZXRzL2FwcC5qcyIKcHJp
bnRmICIgIC9jL2Fzc2V0cy9mYXZpY29uLnN2ZyAtPiAiOyBjdXJsIC1zayAtbyAvZGV2L251bGwg
LXcgJyV7aHR0cF9jb2RlfVxuJyAkUiAiaHR0cHM6Ly9AQE1BSU5fRE9NQUlOQEA6ODQ0My9jL2Fz
c2V0cy9mYXZpY29uLnN2ZyIKcHJpbnRmICIgIC9jLyRTVUJfVVVJRC8gICAgICAgICAgLT4gIjsg
Y3VybCAtc2sgLW8gL2Rldi9udWxsIC13ICcle2h0dHBfY29kZX1cbicgJFIgImh0dHBzOi8vQEBN
QUlOX0RPTUFJTkBAOjg0NDMvYy8kU1VCX1VVSUQvIgpwcmludGYgIiAgL2MvJFNVQl9VVUlEL3N1
YiAgICAgIC0+ICI7IGN1cmwgLXNrIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2NvZGV9XG4nICRS
ICJodHRwczovL0BATUFJTl9ET01BSU5AQDo4NDQzL2MvJFNVQl9VVUlEL3N1YiIKcHJpbnRmICIg
INGB0YHRi9C70L7QuiDQsiAvc3ViICjQttC00ZHQvCA4KTogIjsgY3VybCAtc2sgJFIgLUggIlVz
ZXItQWdlbnQ6IFNoYWRvd3JvY2tldCIgImh0dHBzOi8vQEBNQUlOX0RPTUFJTkBAOjg0NDMvYy8k
U1VCX1VVSUQvc3ViIiB8IGJhc2U2NCAtZCAyPi9kZXYvbnVsbCB8IGdyZXAgLWMgIjovLyIKcHJp
bnRmICIgINC40LzRjyDQsiByZW1hcmsgICAgICAgICAgOiAiOyBjdXJsIC1zayAkUiAtSCAiVXNl
ci1BZ2VudDogU2hhZG93cm9ja2V0IiAiaHR0cHM6Ly9AQE1BSU5fRE9NQUlOQEA6ODQ0My9jLyRT
VUJfVVVJRC9zdWIiIHwgYmFzZTY0IC1kIDI+L2Rldi9udWxsIHwgaGVhZCAtMQplY2hvCmVjaG8g
IuKchSDQk9C+0YLQvtCy0L4hINCf0YDQvtCy0LXRgNGP0Lkg0L3QsCDRgtC10LvQtdGE0L7QvdC1
OiBodHRwczovL0BATUFJTl9ET01BSU5AQC9jLyRTVUJfVVVJRC8iCg==
__B64__
  base64 -d > "$d/setup-relay-ssh.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHNldHVwLXJlbGF5LXNzaC5zaCDigJQgU1NILdC60LvRjtGH
ICsg0YPQtNCw0LvRkdC90L3Ri9C5INC00LXQv9C70L7QuSBAQFJFTEFZX05BTUVAQAojINCX0LDQ
v9GD0YHQutCw0LXRgtGB0Y8g0J3QkCBNT09OTElHSFQuINCT0LXQvdC10YDQuNGA0YPQtdGCINC6
0LvRjtGHLCDQutC+0L/QuNGA0YPQtdGCINC90LAgU3Vuc2hpbmUsINC00LXQv9C70L7QuNGCINC/
0L4gU1NILgpzZXQgLWV1byBwaXBlZmFpbApTTFVHPSJAQFNMVUdAQCIKUkVMQVlfTkFNRT0iQEBS
RUxBWV9OQU1FQEAiClJFTEFZX0lQPSJAQFJFTEFZX0lQQEAiClJFTEFZX0RPTUFJTj0iQEBSRUxB
WV9ET01BSU5AQCIKQUNNRV9FTUFJTD0iQEBBQ01FX0VNQUlMQEAiClNTSF9QT1JUPSIke1NTSF9Q
T1JUOi0yMn0iClNTSF9LRVk9Ii9yb290Ly5zc2gvaWRfZWQyNTUxOV9yZWxheSIKQk9PVFNUUkFQ
PSIvb3B0LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiClJFTU9URV9ESVI9Ii9vcHQvJFNMVUct
cmVsYXktZGVwbG95IgpTQ1JJUFRfU1JDPSIke0JBU0hfU09VUkNFWzBdJS8qfS9teWNsb3VkLWRl
cGxveS5zaCIKIyDQtdGB0LvQuCDQt9Cw0L/Rg9GB0LrQsNC10Lwg0LjQtyAuZGVwbG95IOKAlCDQ
uNGJ0LXQvCDQvtGA0LjQs9C40L3QsNC7INGA0Y/QtNC+0Lwg0LjQu9C4INCyIC9yb290ClsgLWYg
IiRTQ1JJUFRfU1JDIiBdIHx8IFNDUklQVF9TUkM9Ii9yb290L215Y2xvdWQtZGVwbG95LnNoIgpb
IC1mICIkU0NSSVBUX1NSQyIgXSB8fCBTQ1JJUFRfU1JDPSIkKGZpbmQgL29wdC8kU0xVRy8uZGVw
bG95IC1uYW1lICdteWNsb3VkLWRlcGxveS5zaCcgMj4vZGV2L251bGwgfCBoZWFkIC0xKSIKCm9r
KCl7ICBlY2hvICIgIOKckyAkKiI7IH0Kd2FybigpeyBlY2hvICIgICEgJCoiOyB9CmRpZSgpeyBl
Y2hvICIgIOKclyAkKiIgPiYyOyBleGl0IDE7IH0KClsgLWYgIiRCT09UU1RSQVAiIF0gfHwgZGll
ICLQvdC10YIgJEJPT1RTVFJBUCDigJQg0YHQvdCw0YfQsNC70LAg0LfQsNC/0YPRgdGC0LggcHJv
dmlzaW9uLXJlbGF5LnNoIgpbIC1mICIkU0NSSVBUX1NSQyIgXSB8fCBkaWUgItC90LUg0L3QsNGI
0ZHQuyBteWNsb3VkLWRlcGxveS5zaCAo0LjRgdC60LDQuyDQsiAvcm9vdCDQuCAvb3B0LyRTTFVH
Ly5kZXBsb3kpIgoKIyDilIDilIAgMS4gU1NILdC60LvRjtGHIOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAplY2hv
ICI9PT4gU1NILdC60LvRjtGHINC00LvRjyAkUkVMQVlfTkFNRSAoJFJFTEFZX0lQKeKApiIKaWYg
WyAhIC1mICIkU1NIX0tFWSIgXTsgdGhlbgogIHNzaC1rZXlnZW4gLXQgZWQyNTUxOSAtZiAiJFNT
SF9LRVkiIC1OICIiIC1DICJteWNsb3VkLXJlbGF5LSQoZGF0ZSArJVklbSVkKSIgPi9kZXYvbnVs
bAogIG9rICLQutC70Y7RhyDRgdCz0LXQvdC10YDQuNGA0L7QstCw0L06ICRTU0hfS0VZIgplbHNl
CiAgb2sgItC60LvRjtGHINGD0LbQtSDQtdGB0YLRjDogJFNTSF9LRVkiCmZpCgpTU0hfT1BUUz0o
LW8gU3RyaWN0SG9zdEtleUNoZWNraW5nPW5vIC1vIENvbm5lY3RUaW1lb3V0PTEwIC1wICIkU1NI
X1BPUlQiIC1pICIkU1NIX0tFWSIKICAgICAgICAgIC1vIENvbnRyb2xNYXN0ZXI9YXV0byAtbyBD
b250cm9sUGF0aD0iL3RtcC9zc2hfcmVsYXlfJWhfJXBfJXIiIC1vIENvbnRyb2xQZXJzaXN0PTMw
MCkKIyDQsdC10LcgQ29udHJvbE1hc3RlciDigJQg0LTQu9GPINC/0YDQvtCy0LXRgNC60Lgg0Lgg
0LrQvtC/0LjRgNC+0LLQsNC90LjRjyDQutC70Y7Rh9CwClNTSF9QTEFJTj0oLW8gU3RyaWN0SG9z
dEtleUNoZWNraW5nPW5vIC1vIENvbm5lY3RUaW1lb3V0PTEwIC1wICIkU1NIX1BPUlQiIC1pICIk
U1NIX0tFWSIKICAgICAgICAgICAtbyBDb250cm9sTWFzdGVyPW5vIC1vIFBhc3N3b3JkQXV0aGVu
dGljYXRpb249bm8gLW8gQmF0Y2hNb2RlPXllcykKCiMg4pSA4pSAIDIuINCa0L7Qv9C40YDRg9C1
0Lwg0LrQu9GO0Ycg0L3QsCBTdW5zaGluZSAo0L7QtNC40L0g0YDQsNC3INC/0L7Qv9GA0L7RgdC4
0YIg0L/QsNGA0L7Qu9GMKSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIAKZWNobyAiPT0+INCa0L7Qv9C40YDRg9GOIFNTSC3QutC70Y7RhyDQvdCw
ICRSRUxBWV9OQU1FICgkUkVMQVlfSVAp4oCmIgppZiBzc2ggIiR7U1NIX1BMQUlOW0BdfSIgInJv
b3RAJFJFTEFZX0lQIiAnZXhpdCAwJyAyPi9kZXYvbnVsbDsgdGhlbgogIG9rICJTU0gg0LHQtdC3
INC/0LDRgNC+0LvRjyDRg9C20LUg0YDQsNCx0L7RgtCw0LXRgiIKZWxzZQogIFBVQj0iJChjYXQg
IiR7U1NIX0tFWX0ucHViIikiCiAgZWNobyAiICAgINCS0LLQtdC00Lgg0L/QsNGA0L7Qu9GMIHJv
b3RAJFJFTEFZX0lQICjRgtC+0LvRjNC60L4g0Y3RgtC+0YIg0YDQsNC3KToiCiAgc3NoIC1vIFN0
cmljdEhvc3RLZXlDaGVja2luZz1ubyAtbyBDb25uZWN0VGltZW91dD0xMCAtcCAiJFNTSF9QT1JU
IiAicm9vdEAkUkVMQVlfSVAiIFwKICAgICJta2RpciAtcCB+Ly5zc2ggJiYgY2htb2QgNzAwIH4v
LnNzaCAmJiBlY2hvICckUFVCJyA+PiB+Ly5zc2gvYXV0aG9yaXplZF9rZXlzICYmIGNobW9kIDYw
MCB+Ly5zc2gvYXV0aG9yaXplZF9rZXlzICYmIGVjaG8gT0siIFwKICAgIHx8IGRpZSAi0L3QtSDR
g9C00LDQu9C+0YHRjCDRgdC60L7Qv9C40YDQvtCy0LDRgtGMINC60LvRjtGHIOKAlCDQv9GA0L7Q
stC10YDRjCDQtNC+0YHRgtGD0L/QvdC+0YHRgtGMICRSRUxBWV9JUDokU1NIX1BPUlQg0Lgg0L/Q
sNGA0L7Qu9GMIgogIG9rICJTU0gt0LrQu9GO0Ycg0YHQutC+0L/QuNGA0L7QstCw0L0iCmZpCiMg
0L7RgtC60YDRi9Cy0LDQtdC8IENvbnRyb2xNYXN0ZXIg4oCUINCy0YHQtSDQv9C+0YHQu9C10LTR
g9GO0YnQuNC1IHNzaC90YXIg0LjRgdC/0L7Qu9GM0LfRg9GO0YIg0LXQs9C+INGB0L7QutC10YIg
0LHQtdC3INC/0LDRgNC+0LvRjwpzc2ggIiR7U1NIX09QVFNbQF19IiAtZk4gInJvb3RAJFJFTEFZ
X0lQIiAyPi9kZXYvbnVsbCB8fCB0cnVlCm9rICJTU0gt0YLRg9C90L3QtdC70Ywg0YPRgdGC0LDQ
vdC+0LLQu9C10L0iCgojIOKUgOKUgCAzLiDQk9C+0YLQvtCy0LjQvCBTdW5zaGluZSDQuiDQtNC1
0L/Qu9C+0Y4g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmVjaG8gIj09PiDQn9C10YDQtdC00LDRjiDR
hNCw0LnQu9GLINC90LAgJFJFTEFZX05BTUXigKYiCnNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290
QCRSRUxBWV9JUCIgIm1rZGlyIC1wICRSRU1PVEVfRElSIgojINC/0LXRgNC10LTQsNGR0Lwg0YTQ
sNC50LvRiyDRh9C10YDQtdC3IHRhciDQv9C+IFNTSCAo0L7QtNC40L0g0LrQsNC90LDQuywg0LHQ
tdC3INC+0YLQtNC10LvRjNC90L7QuSDQsNGD0YLQtdC90YLQuNGE0LjQutCw0YbQuNC4KQp0YXIg
LWNmIC0gLUMgIiQoZGlybmFtZSAiJFNDUklQVF9TUkMiKSIgIiQoYmFzZW5hbWUgIiRTQ1JJUFRf
U1JDIikiIFwKICAtQyAiJChkaXJuYW1lICIkQk9PVFNUUkFQIikiICIkKGJhc2VuYW1lICIkQk9P
VFNUUkFQIikiIFwKICB8IHNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290QCRSRUxBWV9JUCIgInRh
ciAteGYgLSAtQyAkUkVNT1RFX0RJUiIKb2sgIm15Y2xvdWQtZGVwbG95LnNoICsgcmVsYXktYm9v
dHN0cmFwLmVudiDQv9C10YDQtdC00LDQvdGLIgoKIyDilIDilIAgNC4g0KTQvtGA0LzQuNGA0YPQ
tdC8IGRlcGxveS5jb25mINC00LvRjyBTdW5zaGluZSDQuCDQv9C10YDQtdC00LDRkdC8IOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgApzb3VyY2UgIiRCT09UU1RSQVAiCiMg0K/QstC90L4g0YTQuNC60YHQuNGA
0YPQtdC8INC00L7QvNC10L3Rizog0L3QsCBTdW5zaGluZSBNQUlOX0RPTUFJTiA9INC00L7QvNC1
0L0g0YDQtdC70LXRjyAocnUuYWxkZXJib3cuY29tKQpfU1VOU0hJTkVfRE9NQUlOPSJAQFJFTEFZ
X0RPTUFJTkBAIgpfTU9PTkxJR0hUX0RPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpjYXQgPiAvdG1w
L3JlbGF5LWRlcGxveS5jb25mLiQkIDw8RU9GClJPTEU9c3Vuc2hpbmUtbm9kZQpCUkFORD0kUkVM
QVlfTkFNRQpTTFVHPSRTTFVHCk1BSU5fRE9NQUlOPSRfU1VOU0hJTkVfRE9NQUlOClJFTEFZX0RP
TUFJTj0kX01PT05MSUdIVF9ET01BSU4KRVhJVF9JUD0kRVhJVF9JUApSRUxBWV9JUD0kUkVMQVlf
SVAKRVhJVF9OQU1FPSRFWElUX05BTUUKUkVMQVlfTkFNRT0kUkVMQVlfTkFNRQpBQ01FX0VNQUlM
PSRBQ01FX0VNQUlMClVTRV9UQUlMU0NBTEU9bm8KU1NIX1BPUlQ9JFNTSF9QT1JUCkhBUkRFTj1u
bwpHRU9fQkxPQ0s9bm8KUFE9bm8KVEVTVF9TVUJfVVVJRD1yZWxheQpFT0YKY2F0ICIvdG1wL3Jl
bGF5LWRlcGxveS5jb25mLiQkIiB8IHNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290QCRSRUxBWV9J
UCIgImNhdCA+ICRSRU1PVEVfRElSL2RlcGxveS5jb25mIgpybSAtZiAiL3RtcC9yZWxheS1kZXBs
b3kuY29uZi4kJCIKb2sgImRlcGxveS5jb25mINC00LvRjyAkUkVMQVlfTkFNRSDQv9C10YDQtdC0
0LDQvSIKCiMg4pSA4pSAIDUuINCX0LDQv9GD0YHQutCw0LXQvCDQtNC10L/Qu9C+0Lkg0L3QsCBT
dW5zaGluZSDQv9C+IFNTSCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIAKZWNobwplY2hvICI9PT4g0JfQsNC/0YPRgdC60LDRjiDQtNC10L/Qu9C+0Lkg
JFJFTEFZX05BTUUg0L3QsCAkUkVMQVlfSVDigKYiCmVjaG8gIiAgICAo0LLRi9Cy0L7QtCDQuNC0
0ZHRgiDQsiDRgNC10LDQu9GM0L3QvtC8INCy0YDQtdC80LXQvdC4KSIKZWNobwpzc2ggIiR7U1NI
X09QVFNbQF19IiAicm9vdEAkUkVMQVlfSVAiIFwKICAiTVlDTE9VRF9DT05GPSRSRU1PVEVfRElS
L2RlcGxveS5jb25mIFJFTEFZX0JPT1RTVFJBUD0kUkVNT1RFX0RJUi9yZWxheS1ib290c3RyYXAu
ZW52IFwKICAgYmFzaCAkUkVNT1RFX0RJUi9teWNsb3VkLWRlcGxveS5zaCBzdW5zaGluZS1ub2Rl
IgplY2hvCm9rICLQlNC10L/Qu9C+0LkgJFJFTEFZX05BTUUg0LfQsNCy0LXRgNGI0ZHQvSIK
__B64__
  base64 -d > "$d/setup-tailscale.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHNldHVwLXRhaWxzY2FsZS5zaCDigJQg0YPRgdGC0LDQvdC+
0LLQutCwIFRhaWxzY2FsZSArINCw0LLRgtC+0YDQuNC30LDRhtC40Y8gKyBzZXJ2ZSDQv9Cw0L3Q
tdC70LgKIyDQodC60YDQuNC/0YIg0LTQtdC70LDQtdGCINCy0YHRkSDRgdCw0LwuINCe0YIg0YLQ
tdCx0Y8g4oCUINGC0L7Qu9GM0LrQviDQv9C10YDQtdC50YLQuCDQv9C+INGB0YHRi9C70LrQtSDQ
sNCy0YLQvtGA0LjQt9Cw0YbQuNC4INCyINCx0YDQsNGD0LfQtdGA0LUuCnNldCAtZXVvIHBpcGVm
YWlsClNMVUc9IkBAU0xVR0BAIgpQQU5FTF9QT1JUPTgwODIgICAjIENhZGR5INGB0LvRg9GI0LDQ
tdGCIDEyNy4wLjAuMTo4MDgyIOKGkiDQv9Cw0L3QtdC70Yw6MzAwMCAoc3RlYWx0aC5zaCkKU0VS
VkVfVVJMPSJodHRwOi8vMTI3LjAuMC4xOiRQQU5FTF9QT1JUIgoKc2F5KCl7IGVjaG8gIiAgJCoi
OyB9Cm9rKCl7IGVjaG8gIiAg4pyTICQqIjsgfQpkaWUoKXsgZWNobyAiICDinJcgJCoiID4mMjsg
ZXhpdCAxOyB9CgojIOKUgOKUgCAxLiDQo9GB0YLQsNC90L7QstC60LAg4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmlm
IGNvbW1hbmQgLXYgdGFpbHNjYWxlID4vZGV2L251bGwgMj4mMTsgdGhlbgogIG9rICJUYWlsc2Nh
bGUg0YPQttC1INGD0YHRgtCw0L3QvtCy0LvQtdC9ICgkKHRhaWxzY2FsZSB2ZXJzaW9uIDI+L2Rl
di9udWxsIHwgaGVhZCAtMSkpIgplbHNlCiAgZWNobyAiPT0+INCj0YHRgtCw0L3QsNCy0LvQuNCy
0LDRjiBUYWlsc2NhbGXigKYiCiAgY3VybCAtZnNTTCBodHRwczovL3RhaWxzY2FsZS5jb20vaW5z
dGFsbC5zaCB8IHNoCiAgb2sgIlRhaWxzY2FsZSDRg9GB0YLQsNC90L7QstC70LXQvSIKZmkKCiMg
4pSA4pSAIDIuINCQ0LLRgtC+0YDQuNC30LDRhtC40Y8g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAClNUQVRVUz0iJCh0YWlsc2Nh
bGUgc3RhdHVzIDI+L2Rldi9udWxsIHx8IHRydWUpIgppZiBlY2hvICIkU1RBVFVTIiB8IGdyZXAg
LXFFICJeWzAtOV0rXC5bMC05XStcLlswLTldK1wuWzAtOV0rIjsgdGhlbgogIG9rICJUYWlsc2Nh
bGUg0YPQttC1INCw0LLRgtC+0YDQuNC30L7QstCw0L0iCmVsc2UKICBlY2hvCiAgZWNobyAiPT0+
INCX0LDQv9GD0YHQutCw0Y4gdGFpbHNjYWxlIHVw4oCmIgogICMgLS10aW1lb3V0PTAg0L7RgtC6
0LvRjtGH0LDQtdGCINCy0YHRgtGA0L7QtdC90L3Ri9C5INGC0LDQudC80LDRg9GCOyDQttC00ZHQ
vCDQstGA0YPRh9C90YPRjgogIHRhaWxzY2FsZSB1cCAtLWFjY2VwdC1yb3V0ZXMgMj4mMSB8IHRl
ZSAvdG1wL3RzX3VwX291dC4kJCAmCiAgVFNfUElEPSQhCiAgIyDQttC00ZHQvCDRgdGC0YDQvtC6
0YMg0YEgVVJMINCw0LLRgtC+0YDQuNC30LDRhtC40LggKNC00L4gMzDRgSkKICBBVVRIX1VSTD0i
IgogIGZvciBpIGluICQoc2VxIDEgNjApOyBkbwogICAgQVVUSF9VUkw9IiQoZ3JlcCAtb0UgJ2h0
dHBzOi8vbG9naW5cLnRhaWxzY2FsZVwuY29tL2EvW14gXSsnIC90bXAvdHNfdXBfb3V0LiQkIDI+
L2Rldi9udWxsIHwgaGVhZCAtMSB8fCB0cnVlKSIKICAgIFsgLW4gIiRBVVRIX1VSTCIgXSAmJiBi
cmVhawogICAgc2xlZXAgMC41CiAgZG9uZQogIHJtIC1mIC90bXAvdHNfdXBfb3V0LiQkCiAgaWYg
WyAteiAiJEFVVEhfVVJMIiBdOyB0aGVuCiAgICAjINC/0L7Qv9GA0L7QsdGD0LXQvCDQv9C+0LvR
g9GH0LjRgtGMIFVSTCDRh9C10YDQtdC3IC0tanNvbgogICAgQVVUSF9VUkw9IiQodGFpbHNjYWxl
IHVwIC0tYWNjZXB0LXJvdXRlcyAtLWpzb24gMj4vZGV2L251bGwgfCBweXRob24zIC1jIFwKICAg
ICAgJ2ltcG9ydCBzeXMsanNvbjsgZD1qc29uLmxvYWQoc3lzLnN0ZGluKTsgcHJpbnQoZC5nZXQo
IkF1dGhVUkwiLCIiKSknIDI+L2Rldi9udWxsIHx8IHRydWUpIgogIGZpCiAgaWYgWyAtbiAiJEFV
VEhfVVJMIiBdOyB0aGVuCiAgICBlY2hvCiAgICBlY2hvICIgIOKUjOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUkCIKICAgIGVjaG8gIiAg
4pSCICDQntGC0LrRgNC+0Lkg0Y3RgtGDINGB0YHRi9C70LrRgyDQsiDQsdGA0LDRg9C30LXRgNC1
INC4INCy0L7QudC00Lgg0LIgVGFpbHNjYWxlOiAgICAg4pSCIgogICAgZWNobyAiICDilIIgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIi
CiAgICBwcmludGYgIiAg4pSCICAlLTU1c+KUglxuIiAiJEFVVEhfVVJMIgogICAgZWNobyAiICDi
lIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICDilIIiCiAgICBlY2hvICIgIOKUlOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUmCIKICAgIGVjaG8KICAgIGVjaG8gIiAg0JbQtNGDINCw
0LLRgtC+0YDQuNC30LDRhtC40LggKNC00L4gNSDQvNC40L3Rg9GCKeKApiIKICAgIGZvciBpIGlu
ICQoc2VxIDEgNjApOyBkbwogICAgICBzbGVlcCA1CiAgICAgIFRTX1NUPSIkKHRhaWxzY2FsZSBz
dGF0dXMgMj4vZGV2L251bGwgfHwgdHJ1ZSkiCiAgICAgIGlmIGVjaG8gIiRUU19TVCIgfCBncmVw
IC1xRSAiXlswLTldK1wuWzAtOV0rXC5bMC05XStcLlswLTldKyI7IHRoZW4KICAgICAgICBvayAi
0JDQstGC0L7RgNC40LfQvtCy0LDQvSEiOyBicmVhawogICAgICBmaQogICAgICBbICIkaSIgPSA2
MCBdICYmIGRpZSAi0KLQsNC50LzQsNGD0YIg0LDQstGC0L7RgNC40LfQsNGG0LjQuCAoNSDQvNC4
0L0pLiDQl9Cw0L/Rg9GB0YLQuCB0YWlsc2NhbGUgdXAg0LLRgNGD0YfQvdGD0Y4g0Lgg0L/QvtCy
0YLQvtGA0Lgg0YjQsNCzLiIKICAgIGRvbmUKICAgIHdhaXQgIiRUU19QSUQiIDI+L2Rldi9udWxs
IHx8IHRydWUKICBlbHNlCiAgICAjINGD0LbQtSDQsNCy0YLQvtGA0LjQt9C+0LLQsNC9INC40LvQ
uCB0YWlsc2NhbGUgdXAg0LfQsNCy0LXRgNGI0LjQu9GB0Y8g0LHQtdC3IFVSTCAoU1NPL9C60LvR
jtGHKQogICAgd2FpdCAiJFRTX1BJRCIgMj4vZGV2L251bGwgfHwgdHJ1ZQogICAgdGFpbHNjYWxl
IHN0YXR1cyAyPi9kZXYvbnVsbCB8IGdyZXAgLXFFICJeWzAtOV0iICYmIG9rICLQkNCy0YLQvtGA
0LjQt9C+0LLQsNC9IiB8fCBkaWUgItCd0LUg0YPQtNCw0LvQvtGB0Ywg0LDQstGC0L7RgNC40LfQ
vtCy0LDRgtGMIFRhaWxzY2FsZS4g0JfQsNC/0YPRgdGC0LggdGFpbHNjYWxlIHVwINCy0YDRg9GH
0L3Rg9GOLiIKICBmaQpmaQoKIyDilIDilIAgMy4gdGFpbHNjYWxlIHNlcnZlIOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAplY2hvICI9PT4g0J3QsNGB
0YLRgNCw0LjQstCw0Y4gdGFpbHNjYWxlIHNlcnZlIOKGkiDQv9Cw0L3QtdC70YzigKYiCiMg0YHQ
sdGA0L7RgdC40Lwg0YHRgtCw0YDRi9C5IHNlcnZlINC10YHQu9C4INCx0YvQuwp0YWlsc2NhbGUg
c2VydmUgcmVzZXQgMj4vZGV2L251bGwgfHwgdHJ1ZQojINCS0JDQltCd0J46IHNlcnZlINCd0JUg
0L3QsCA0NDMg4oCUINC40L3QsNGH0LUgdGFpbHNjYWxlZCDQt9Cw0LnQvNGR0YIgOjQ0MyDQvdCw
IHRhaWxuZXQt0LjQvdGC0LXRgNGE0LXQudGB0LUKIyDQuCBYcmF5INC90LUg0YHQvNC+0LbQtdGC
INGB0LTQtdC70LDRgtGMIGJpbmQgMC4wLjAuMDo0NDMgKNC60L7QvdGE0LvQuNC60YIpLiDQmNGB
0L/QvtC70YzQt9GD0LXQvCA4NDQ0LgpUU19QT1JUPTg0NDQKdGFpbHNjYWxlIHNlcnZlIC0tYmcg
LS1odHRwcz0iJFRTX1BPUlQiICIkU0VSVkVfVVJMIiAyPi9kZXYvbnVsbCBcCiAgfHwgZGllICJ0
YWlsc2NhbGUgc2VydmUg0L3QtSDRg9C00LDQu9GB0Y8g4oCUINC/0YDQvtCy0LXRgNGMINCy0LXR
gNGB0LjRjiAo0L3Rg9C20L3QsCA+PSAxLjQwKSIKb2sgInRhaWxzY2FsZSBzZXJ2ZSDQvdCw0YHR
gtGA0L7QtdC9ICgkU0VSVkVfVVJMIOKGkiA6JFRTX1BPUlQpIgoKIyDilIDilIAgNC4g0JDQtNGA
0LXRgSDQv9Cw0L3QtdC70Lgg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSACnNsZWVwIDIKVFNfSE9TVE5BTUU9IiQodGFpbHNjYWxlIHN0
YXR1cyAtLWpzb24gMj4vZGV2L251bGwgXAogIHwgcHl0aG9uMyAtYyAnaW1wb3J0IHN5cyxqc29u
OyBkPWpzb24ubG9hZChzeXMuc3RkaW4pOyBwcmludChkLmdldCgiU2VsZiIse30pLmdldCgiRE5T
TmFtZSIsIiIpLnJzdHJpcCgiLiIpKScgMj4vZGV2L251bGwgfHwgdHJ1ZSkiCmVjaG8KaWYgWyAt
biAiJFRTX0hPU1ROQU1FIiBdOyB0aGVuCiAgb2sgItCf0LDQvdC10LvRjCDQtNC+0YHRgtGD0L/Q
vdCwINC/0L4g0YLQsNC50LvQvdC10YLRgzogaHR0cHM6Ly8kVFNfSE9TVE5BTUU6JFRTX1BPUlQi
CiAgZWNobyAiICAgINCU0L7QsdCw0LLRjCDRg9GB0YLRgNC+0LnRgdGC0LLQviAoaVBob25lL9C9
0L7Rg9GC0LHRg9C6KSDQsiDRgtC+0YIg0LbQtSDQsNC60LrQsNGD0L3RgiBUYWlsc2NhbGUiCiAg
ZWNobyAiICAgINC4INC+0YLQutGA0L7QuSDRjdGC0YMg0YHRgdGL0LvQutGDIOKAlCDQv9Cw0L3Q
tdC70Ywg0L7RgtC60YDQvtC10YLRgdGPINCx0LXQtyBWUE4g0Lgg0LHQtdC3INC/0YPQsdC70LjR
h9C90L7Qs9C+INC00L7RgdGC0YPQv9CwLiIKZWxzZQogIG9rICJ0YWlsc2NhbGUgc2VydmUg0L3Q
sNGB0YLRgNC+0LXQvS4g0JDQtNGA0LXRgTogdGFpbHNjYWxlIHN0YXR1cyAtLWpzb24gfCBweXRo
b24zIC1jICdpbXBvcnQgc3lzLGpzb247ZD1qc29uLmxvYWQoc3lzLnN0ZGluKTtwcmludChkLmdl
dChcIlNlbGZcIix7fSkuZ2V0KFwiRE5TTmFtZVwiLFwiXCIpKSciCmZpCg==
__B64__
  base64 -d > "$d/stealth.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIE15U3BoZXJlIHN0
ZWFsdGggKCM0KSDQtNC70Y8gQEBFWElUX05BTUVAQCDigJQgMiDRgdGC0LDQtNC40LgKIyAgICBz
dGVhbHRoLnNoIGRlY295ICAg4oCUINC/0L7QtNC90Y/RgtGMINC00LXQutC+0Lkg0L3QsCAxMjcu
MC4wLjE6ODA4MCAo0YLRgNCw0YTQuNC6INCd0JUg0YLRgNC+0LPQsNC10YIpCiMgICAgc3RlYWx0
aC5zaCBjYWRkeSAgIOKAlCDQv9C10YDQtdC60LvRjtGH0LjRgtGMIENhZGR5OiDQutC+0YDQtdC9
0YwgLT4g0LTQtdC60L7QuSwg0L/RgNC+0YLQvtC60L7Qu9GLK9C/0L7QtNC/0LjRgdC60LAg0YbQ
tdC70YsKIyAg0JTQtdC60L7QuTogZ2l0aHViLmNvbS9pcXViaWsvbXlmYWtlc2l0ZSAoTmdpbngr
UEhQKSwg0L3QviDQsdC10Lcg0YHQstC+0LXQs9C+IFNTTCDigJQgVExTINC90LAgQ2FkZHkKIyA9
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbAoKRE9NQUlOPSJAQE1BSU5fRE9N
QUlOQEAiClNVQl9VVUlEPSJAQFRFU1RfU1VCX1VVSURAQCIgICAgICAgICAgICMg0LTQu9GPINC/
0YDQvtCy0LXRgNC60Lgg0L/QvtC00L/QuNGB0LrQuCAo0L/QvtC/0YDQsNCy0YwsINC10YHQu9C4
INC00YDRg9Cz0L7QuSkKREVDT1k9Ii9vcHQvQEBTTFVHQEAvZGVjb3kiCkNBRERZRklMRT0iL29w
dC9AQFNMVUdAQC9jYWRkeS9DYWRkeWZpbGUiCkNBRERZX0NUUj0iQEBTTFVHQEAtY2FkZHkiCkRF
Q09ZX1BPUlQ9IjgwODAiCgpsb2coKXsgZWNobyAtZSAiXG49PT0gJCogPT09IjsgfQoKIyDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAK
c3RhZ2VfZGVjb3koKXsKICBsb2cgIlsxLzRdINCY0YHRhdC+0LTQvdC40LrQuCDQtNC10LrQvtGP
IC0+ICRERUNPWSIKICBjb21tYW5kIC12IGdpdCA+L2Rldi9udWxsIHx8IHsgYXB0LWdldCB1cGRh
dGUgLXkgJiYgYXB0LWdldCBpbnN0YWxsIC15IGdpdDsgfQogIGlmIFsgLWQgIiRERUNPWS8uZ2l0
IiBdOyB0aGVuIGdpdCAtQyAiJERFQ09ZIiBwdWxsIC0tZmYtb25seSB8fCB0cnVlCiAgZWxzZSBy
bSAtcmYgIiRERUNPWSI7IGdpdCBjbG9uZSAtLWRlcHRoIDEgaHR0cHM6Ly9naXRodWIuY29tL2lx
dWJpay9teWZha2VzaXRlLmdpdCAiJERFQ09ZIjsgZmkKCiAgbG9nICJbMi80XSDQn9C+0LTQvNC1
0L3Rj9GOIG5naW54LmNvbmYgKEhUVFAgOjgwLCDQsdC10LcgU1NML9GA0LXQtNC40YDQtdC60YLQ
sCkg0LggY29tcG9zZSAobG9jYWxob3N0OiRERUNPWV9QT1JUKSIKICBjYXQgPiAiJERFQ09ZL2Rh
dGEvbmdpbnguY29uZiIgPDwnTkdJTlhDT05GJwpsaW1pdF9yZXFfem9uZSAkYmluYXJ5X3JlbW90
ZV9hZGRyIHpvbmU9YXV0aF9saW1pdDoxMG0gcmF0ZT0zci9tOwpsaW1pdF9yZXFfc3RhdHVzIDQy
OTsKCm1hcCAkcmVxdWVzdF9pZCAkYXV0aF9lcnJvcl9tc2cgewogICAgZGVmYXVsdCAgICAgICAi
0J3QtdCy0LXRgNC90YvQuSDQu9C+0LPQuNC9INC40LvQuCDQv9Cw0YDQvtC70YwuINCf0L7Qv9GA
0L7QsdGD0LnRgtC1INC10YnRkSDRgNCw0LcuIjsKICAgICJ+XlswLTNdIiAgICAgItCf0L7Qu9GM
0LfQvtCy0LDRgtC10LvRjCDQvdC1INC90LDQudC00LXQvS4iOwogICAgIn5eWzQtN10iICAgICAi
0J3QtdCy0LXRgNC90YvQuSDQv9Cw0YDQvtC70YwuIjsKICAgICJ+Xls4LWJdIiAgICAgItCQ0LrQ
utCw0YPQvdGCINCy0YDQtdC80LXQvdC90L4g0LfQsNCx0LvQvtC60LjRgNC+0LLQsNC9LiDQn9C+
0L/RgNC+0LHRg9C50YLQtSDQv9C+0LfQttC1LiI7CiAgICAifl5bYy1mXSIgICAgICLQodC70LjR
iNC60L7QvCDQvNC90L7Qs9C+INC/0L7Qv9GL0YLQvtC6LiDQn9C+0LTQvtC20LTQuNGC0LUg0Lgg
0L/QvtC/0YDQvtCx0YPQudGC0LUg0YHQvdC+0LLQsC4iOwp9CgpzZXJ2ZXIgewogICAgbGlzdGVu
IDgwOwogICAgbGlzdGVuIFs6Ol06ODA7CiAgICBzZXJ2ZXJfbmFtZSBfOwoKICAgIGFkZF9oZWFk
ZXIgWC1Db250ZW50LVR5cGUtT3B0aW9ucyAibm9zbmlmZiIgYWx3YXlzOwogICAgYWRkX2hlYWRl
ciBYLUZyYW1lLU9wdGlvbnMgIlNBTUVPUklHSU4iIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgWC1Q
ZXJtaXR0ZWQtQ3Jvc3MtRG9tYWluLVBvbGljaWVzICJub25lIiBhbHdheXM7CiAgICBhZGRfaGVh
ZGVyIFgtUm9ib3RzLVRhZyAibm9pbmRleCwgbm9mb2xsb3ciIGFsd2F5czsKICAgIGFkZF9oZWFk
ZXIgWC1YU1MtUHJvdGVjdGlvbiAiMTsgbW9kZT1ibG9jayIgYWx3YXlzOwogICAgYWRkX2hlYWRl
ciBSZWZlcnJlci1Qb2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFN0
cmljdC1UcmFuc3BvcnQtU2VjdXJpdHkgIm1heC1hZ2U9MTU1NTIwMDA7IGluY2x1ZGVTdWJEb21h
aW5zIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIENvbnRlbnQtU2VjdXJpdHktUG9saWN5ICJkZWZh
dWx0LXNyYyAnc2VsZic7IHNjcmlwdC1zcmMgJ3NlbGYnICd1bnNhZmUtaW5saW5lJyAndW5zYWZl
LWV2YWwnIGh0dHBzOi8vY2RuanMuY2xvdWRmbGFyZS5jb207IHN0eWxlLXNyYyAnc2VsZicgJ3Vu
c2FmZS1pbmxpbmUnIGh0dHBzOi8vZm9udHMuZ29vZ2xlYXBpcy5jb207IGZvbnQtc3JjICdzZWxm
JyBodHRwczovL2ZvbnRzLmdzdGF0aWMuY29tOyBpbWctc3JjICdzZWxmJyBkYXRhOiBibG9iOjsg
Y29ubmVjdC1zcmMgJ3NlbGYnOyBtZWRpYS1zcmMgJ3NlbGYnOyBvYmplY3Qtc3JjICdub25lJzsg
ZnJhbWUtYW5jZXN0b3JzICdub25lJzsgYmFzZS11cmkgJ3NlbGYnOyIgYWx3YXlzOwoKICAgIHNl
cnZlcl90b2tlbnMgb2ZmOwogICAgYWNjZXNzX2xvZyBvZmY7CgogICAgbG9jYXRpb24gLyB7CiAg
ICAgICAgcm9vdCAvdXNyL3NoYXJlL25naW54L2h0bWw7CiAgICAgICAgaW5kZXggaW5kZXguaHRt
bDsKICAgICAgICB0cnlfZmlsZXMgJHVyaSAkdXJpLyAvaW5kZXguaHRtbDsKICAgIH0KCiAgICBs
b2NhdGlvbiB+IF4vYXBpL3N0YXR1cyQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlv
bi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1Qb3dlcmVkLUJ5ICJNeVNwaGVyZS8xLjQuNDIi
IGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFs
d2F5czsKICAgICAgICBhZGRfaGVhZGVyIFgtQ29udGVudC1UeXBlLU9wdGlvbnMgIm5vc25pZmYi
IGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFJlZmVycmVyLVBvbGljeSAibm8tcmVmZXJyZXIi
IGFsd2F5czsKICAgICAgICByZXR1cm4gMjAwICd7Im9ubGluZSI6dHJ1ZSwibWFpbnRlbmFuY2Ui
OmZhbHNlLCJ2ZXJzaW9uIjoiMS40LjQyIiwiYnVpbGQiOiIyMDI2LjAzLjE1IiwicHJvZHVjdCI6
Ik15U3BoZXJlIiwiYXBpIjoiMS4wIn0nOwogICAgfQoKICAgIGVycm9yX3BhZ2UgNDI5ID0gQHJh
dGVfbGltaXRlZDsKICAgIGxvY2F0aW9uIEByYXRlX2xpbWl0ZWQgewogICAgICAgIGRlZmF1bHRf
dHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgUmV0cnktQWZ0ZXIgIjIw
IiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDQyOSAneyJzdGF0dXMiOiJlcnJvciIsIm1lc3NhZ2Ui
OiLQodC70LjRiNC60L7QvCDQvNC90L7Qs9C+INC30LDQv9GA0L7RgdC+0LIuINCf0L7Qv9GA0L7Q
sdGD0LnRgtC1INGH0LXRgNC10LcgMjAg0YHQtdC60YPQvdC0LiJ9JzsKICAgIH0KCiAgICBsb2Nh
dGlvbiB+IF4vYXBpL2F1dGgkIHsKICAgICAgICBsaW1pdF9yZXEgem9uZT1hdXRoX2xpbWl0IGJ1
cnN0PTIgbm9kZWxheTsKICAgICAgICBhY2Nlc3NfbG9nIC92YXIvbG9nL215ZmFrZXNpdGUvYWNj
ZXNzLmxvZyBjb21iaW5lZDsKICAgICAgICBkZWZhdWx0X3R5cGUgYXBwbGljYXRpb24vanNvbjsK
ICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1JZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAg
ICAgICBhZGRfaGVhZGVyIFNldC1Db29raWUgIm1zX3Nlc3Npb249ZXlKaGJHY2lPaUpJVXpJMU5p
SjkuJHJlcXVlc3RfaWQuc2lnOyBQYXRoPS87IEh0dHBPbmx5OyBTZWN1cmU7IFNhbWVTaXRlPVN0
cmljdCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgU2V0LUNvb2tpZSAiX19Ib3N0LW1zX3By
aXZhY3k9YWNrOyBQYXRoPS87IFNlY3VyZTsgU2FtZVNpdGU9U3RyaWN0IiBhbHdheXM7CiAgICAg
ICAgYWRkX2hlYWRlciBSZWZlcnJlci1Qb2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICAg
ICAgcmV0dXJuIDQwMSAneyJzdGF0dXMiOiJlcnJvciIsIm1lc3NhZ2UiOiIkYXV0aF9lcnJvcl9t
c2cifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9maWxlcygvLiopPyQgewogICAgICAg
IGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1
ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MDEgJ3sic3RhdHVz
IjoiZXJyb3IiLCJtZXNzYWdlIjoi0KLRgNC10LHRg9C10YLRgdGPINCw0LLRgtC+0YDQuNC30LDR
htC40Y8ifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS91c2VycygvLiopPyQgewogICAg
ICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1S
ZXF1ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MDEgJ3sic3Rh
dHVzIjoiZXJyb3IiLCJtZXNzYWdlIjoi0KLRgNC10LHRg9C10YLRgdGPINCw0LLRgtC+0YDQuNC3
0LDRhtC40Y8ifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9zZXR0aW5ncyQgewogICAg
ICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1S
ZXF1ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIHJldHVybiAyMDAgJ3sic3Rh
dHVzIjoib2siLCJsYW5nIjoicnUiLCJ0aGVtZSI6ImF1dG8iLCJub3RpZmljYXRpb25zIjp0cnVl
LCJ0d29fZmFjdG9yIjpmYWxzZSwic3RvcmFnZSI6eyJ1c2VkIjoyODQ3MTkzNjAwLCJ0b3RhbCI6
MTA3Mzc0MTgyNDB9LCJsYXN0X2xvZ2luIjoiMjAyNi0wNC0xMFQxODozMjowN1oifSc7CiAgICB9
CgogICAgbG9jYXRpb24gPSAvcm9ib3RzLnR4dCB7CiAgICAgICAgZGVmYXVsdF90eXBlIHRleHQv
cGxhaW47CiAgICAgICAgcmV0dXJuIDIwMCAnVXNlci1hZ2VudDogKgpBbGxvdzogLwpEaXNhbGxv
dzogL2FwaS8KRGlzYWxsb3c6IC9hZG1pbi8KRGlzYWxsb3c6IC9pbnRlcm5hbC8KJzsKICAgIH0K
CiAgICBsb2NhdGlvbiA9IC9oZWFydGJlYXQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNh
dGlvbi9qc29uOwogICAgICAgIHJldHVybiAyMDAgJ3sib2siOnRydWUsInRzIjokbXNlY30nOwog
ICAgfQoKICAgIGxvY2F0aW9uID0gLy53ZWxsLWtub3duL3NlY3VyaXR5LnR4dCB7CiAgICAgICAg
ZGVmYXVsdF90eXBlIHRleHQvcGxhaW47CiAgICAgICAgYWRkX2hlYWRlciBBY2Nlc3MtQ29udHJv
bC1BbGxvdy1PcmlnaW4gIioiIGFsd2F5czsKICAgICAgICByZXR1cm4gMjAwICdDb250YWN0OiBt
YWlsdG86YWRtaW5AQEBNQUlOX0RPTUFJTkBAClByZWZlcnJlZC1MYW5ndWFnZXM6IHJ1LCBlbgpF
eHBpcmVzOiAyMDI3LTAxLTAxVDAwOjAwOjAwWgonOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9c
LndlbGwta25vd24vKD8hc2VjdXJpdHlcLnR4dCkgeyByZXR1cm4gNDA0OyB9CgogICAgbG9jYXRp
b24gPSAvZmF2aWNvbi5pY28gewogICAgICAgIHJvb3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwog
ICAgICAgIGV4cGlyZXMgMzBkOwogICAgICAgIGFkZF9oZWFkZXIgQ2FjaGUtQ29udHJvbCAicHVi
bGljLCBpbW11dGFibGUiIGFsd2F5czsKICAgIH0KICAgIGxvY2F0aW9uID0gL2FwcGxlLXRvdWNo
LWljb24ucG5nIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBl
eHBpcmVzIDMwZDsKICAgICAgICBhZGRfaGVhZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1t
dXRhYmxlIiBhbHdheXM7CiAgICB9CgogICAgbG9jYXRpb24gPSAvbG9nLXJvdGF0ZS1ieS1zaXpl
LnNoIHsgcmV0dXJuIDQwNDsgfQogICAgbG9jYXRpb24gPSAvZGF0YS9sb2ctcm90YXRlLWJ5LXNp
emUuc2ggeyByZXR1cm4gNDA0OyB9CgogICAgbG9jYXRpb24gfiBcLnBocCQgewogICAgICAgIHJv
b3QgL3Vzci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGZhc3RjZ2lfcGFzcyBwaHAtZnBtOjkw
MDA7CiAgICAgICAgZmFzdGNnaV9pbmRleCBpbmRleC5waHA7CiAgICAgICAgZmFzdGNnaV9wYXJh
bSBTQ1JJUFRfRklMRU5BTUUgJGRvY3VtZW50X3Jvb3QkZmFzdGNnaV9zY3JpcHRfbmFtZTsKICAg
ICAgICBpbmNsdWRlIGZhc3RjZ2lfcGFyYW1zOwogICAgICAgIGZhc3RjZ2lfaGlkZV9oZWFkZXIg
WC1Qb3dlcmVkLUJ5OwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi8oPzpcLmh0Lip8XC5naXQuKnxc
LmVudi4qfGRhdGEvfGNvbmZpZy98bGliL3wzcmRwYXJ0eS98dGVtcGxhdGVzLykgeyByZXR1cm4g
NDA0OyB9CgogICAgZXJyb3JfcGFnZSA1MDAgNTAyIDUwMyA1MDQgLzUweC5odG1sOwogICAgbG9j
YXRpb24gPSAvNTB4Lmh0bWwgeyByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsgfQp9Ck5HSU5Y
Q09ORgoKICBjYXQgPiAiJERFQ09ZL2RvY2tlci1jb21wb3NlLnltbCIgPDwnQ09NUE9TRScKc2Vy
dmljZXM6CiAgZmFrZXNpdGU6CiAgICBpbWFnZTogbmdpbng6YWxwaW5lCiAgICBjb250YWluZXJf
bmFtZTogQEBTTFVHQEAtZGVjb3kKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBwb3J0
czoKICAgICAgLSAiMTI3LjAuMC4xOjgwODA6ODAiCiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0
YS9hcHBsZS10b3VjaC1pY29uLnBuZzovdXNyL3NoYXJlL25naW54L2h0bWwvYXBwbGUtdG91Y2gt
aWNvbi5wbmc6cm8KICAgICAgLSAuL2RhdGEvZmF2aWNvbi5pY286L3Vzci9zaGFyZS9uZ2lueC9o
dG1sL2Zhdmljb24uaWNvOnJvCiAgICAgIC0gLi9kYXRhL2luZGV4Lmh0bWw6L3Vzci9zaGFyZS9u
Z2lueC9odG1sL2luZGV4Lmh0bWw6cm8KICAgICAgLSAuL2RhdGEvbmdpbnguY29uZjovZXRjL25n
aW54L2NvbmYuZC9kZWZhdWx0LmNvbmY6cm8KICAgICAgLSAuL2RhdGEvcGhwaW5mby5waHA6L3Vz
ci9zaGFyZS9uZ2lueC9odG1sL3BocGluZm8ucGhwOnJvCiAgICAgIC0gLi9kYXRhL3JvYm90cy50
eHQ6L3Vzci9zaGFyZS9uZ2lueC9odG1sL3JvYm90cy50eHQ6cm8KICAgICAgLSAuL2RhdGEvc3Rh
dHVzLnBocDovdXNyL3NoYXJlL25naW54L2h0bWwvc3RhdHVzLnBocDpybwogICAgICAtIC4vZGF0
YS9WRVJTSU9OOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9WRVJTSU9OOnJvCiAgICAgIC0gL3Zhci9s
b2cvbXlmYWtlc2l0ZTovdmFyL2xvZy9teWZha2VzaXRlCiAgICBuZXR3b3JrczogW2Zha2VzaXRl
XQogICAgZGVwZW5kc19vbjogW3BocC1mcG1dCiAgcGhwLWZwbToKICAgIGltYWdlOiBwaHA6OC4z
LWZwbS1hbHBpbmUKICAgIGNvbnRhaW5lcl9uYW1lOiBAQFNMVUdAQC1kZWNveS1waHAKICAgIHJl
c3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICB2b2x1bWVzOgogICAgICAtIC4vZGF0YS9zdGF0dXMu
cGhwOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9zdGF0dXMucGhwOnJvCiAgICAgIC0gLi9kYXRhL3Bo
cGluZm8ucGhwOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9waHBpbmZvLnBocDpybwogICAgbmV0d29y
a3M6IFtmYWtlc2l0ZV0KbmV0d29ya3M6CiAgZmFrZXNpdGU6CiAgICBkcml2ZXI6IGJyaWRnZQpD
T01QT1NFCgogIG1rZGlyIC1wIC92YXIvbG9nL215ZmFrZXNpdGUKCiAgbG9nICJbMy80XSDQl9Cw
0L/Rg9GB0Log0LrQvtC90YLQtdC50L3QtdGA0L7QsiDQtNC10LrQvtGPIgogIGNkICIkREVDT1ki
CiAgZG9ja2VyIGNvbXBvc2UgdXAgLWQKCiAgbG9nICJbNC80XSDQn9GA0L7QstC10YDQutCwINC0
0LXQutC+0Y8g0L3QsCAxMjcuMC4wLjE6JERFQ09ZX1BPUlQiCiAgc2xlZXAgMwogIGVjaG8gIi0t
LSAvYXBpL3N0YXR1cyAtLS0iOyBjdXJsIC1zICJodHRwOi8vMTI3LjAuMC4xOiRERUNPWV9QT1JU
L2FwaS9zdGF0dXMiOyBlY2hvCiAgZWNobyAiLS0tIC8gKNC/0LXRgNCy0YvQtSDRgdGC0YDQvtC6
0LgpIC0tLSI7IHsgY3VybCAtcyAiaHR0cDovLzEyNy4wLjAuMTokREVDT1lfUE9SVC8iIHwgaGVh
ZCAtYyAyMDA7IH0gfHwgdHJ1ZTsgZWNobwogIGVjaG8KICBlY2hvICLinIUg0JXRgdC70Lgg0LLR
i9GI0LUg0LLQuNC00LXQvSBKU09OIE15U3BoZXJlINC4IEhUTUwg4oCUINC00LXQutC+0Lkg0LbQ
uNCyLiDQlNCw0LvRjNGI0LU6IGJhc2ggc3RlYWx0aC5zaCBjYWRkeSIKfQoKIyDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKc3RhZ2Vf
Y2FkZHkoKXsKICBbIC1mICIkQ0FERFlGSUxFIiBdIHx8IHsgZWNobyAi0J3QtSDQvdCw0LnQtNC1
0L0gJENBRERZRklMRSI7IGV4aXQgMTsgfQogIGxvY2FsIGJhaz0iJHtDQUREWUZJTEV9LmJhay4k
KGRhdGUgKyVZJW0lZC0lSCVNJVMpIgogIGxvZyAiWzEvNF0g0JHRjdC60LDQvyBDYWRkeWZpbGUg
LT4gJGJhayIKICBjcCAiJENBRERZRklMRSIgIiRiYWsiCgogIGxvZyAiWzIvNF0g0J3QvtCy0YvQ
uSBDYWRkeWZpbGUgKNC60L7RgNC10L3RjCAtPiDQtNC10LrQvtC5LCDQv9GA0L7RgtC+0LrQvtC7
0Ysr0L/QvtC00L/QuNGB0LrQsCDRhtC10LvRiykiCiAgY2F0ID4gIiRDQUREWUZJTEUiIDw8J0NB
RERZJwp7CiAgICBzZXJ2ZXJzIDo4NDQzIHsKICAgICAgICBwcm90b2NvbHMgaDEKICAgIH0KQEBB
Q01FX1NUQUdJTkdfTElORUBACn0KQEBNQUlOX0RPTUFJTkBAOjg0NDMgewogICAgIyDQoNC10LDQ
u9GM0L3QsNGPINC/0L7QtNC/0LjRgdC60LAgUmVtbmF3YXZlICjQv9Cw0L3QtdC70Ywg0L7RgtC0
0LDRkdGCIC9hcGkvc3ViKSDigJQg0L7RgdGC0LDRkdGC0YHRjyDQv9GD0LHQu9C40YfQvdC+0LkK
ICAgIEBzdWIgcGF0aCAvYXBpL3N1YiAvYXBpL3N1Yi8qCiAgICBoYW5kbGUgQHN1YiB7CiAgICAg
ICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MzAwMAogICAgfQoKICAgICMg0KHRgtGA0LDQvdC4
0YbQsCDQv9C+0LTQv9C40YHQutC4IChzdWItcGFnZSkKICAgIGhhbmRsZV9wYXRoIC9zdWIvKiB7
CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MzAxMAogICAgfQoKICAgICMgVkxFU1Mg
V1MgLyBYSFRUUCDRgtGA0LDQvdGB0L/QvtGA0YLRiwogICAgQHdzIHBhdGggL3dzbmcgL3dzbmcv
KgogICAgaGFuZGxlIEB3cyB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1Mwog
ICAgfQogICAgIyDQktGB0ZEg0L7RgdGC0LDQu9GM0L3QvtC1ICjQutC+0YDQtdC90YwsIC9hcGkv
YXV0aCwgL2Rhc2hib2FyZCAuLi4pIC0+INC00LXQutC+0LkgTXlTcGhlcmUKICAgICMg0J/QsNC9
0LXQu9GMINCd0JUg0L/Rg9Cx0LvQuNGH0L3QsDog0LTQvtGB0YLRg9C/INGC0L7Qu9GM0LrQviDR
h9C10YDQtdC3IFNTSC3RgtGD0L3QvdC10LvRjCDQvdCwIDEyNy4wLjAuMTozMDAwCiAgICBoYW5k
bGUgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjgwODAKICAgIH0KfQoKIyDQn9Cw
0L3QtdC70Ywg0YfQtdGA0LXQtyBUYWlsc2NhbGU6IGB0YWlsc2NhbGUgc2VydmUgLS1iZyBodHRw
Oi8vMTI3LjAuMC4xOjgwODJgINGD0LrQsNC30YvQstCw0LXRgiDRgdGO0LTQsC4KIyDQlNC+0LLQ
tdGA0LXQvdC90YvQuSDRgdC10YDRgiDQtNCw0ZHRgiBUYWlsc2NhbGU7INC70LjRgdGC0LXQvdC1
0YAg0LvQvtC60LDQu9GM0L3Ri9C5LCDQvdCw0YDRg9C20YMg0L3QtSDRgtC+0YDRh9C40YIuCjo4
MDgyIHsKICAgIGJpbmQgMTI3LjAuMC4xCiAgICByZXZlcnNlX3Byb3h5IDEyNy4wLjAuMTozMDAw
IHsKICAgICAgICBoZWFkZXJfdXAgSG9zdCBAQE1BSU5fRE9NQUlOQEAKICAgICAgICBoZWFkZXJf
dXAgWC1Gb3J3YXJkZWQtSG9zdCBAQE1BSU5fRE9NQUlOQEAKICAgICAgICBoZWFkZXJfdXAgWC1G
b3J3YXJkZWQtUHJvdG8gaHR0cHMKICAgIH0KfQoKIyDQlNC10YHQutGC0L7Qvy3RhNC+0LvQsdGN
0Lo6IHNzaCAtTCA4MDgxOjEyNy4wLjAuMTo4MDgxLCDQvtGC0LrRgNGL0YLRjCBodHRwczovL2xv
Y2FsaG9zdDo4MDgxIChzZWxmLXNpZ25lZCwg0LHQtdC30L7Qv9Cw0YHQvdC+KS4KaHR0cHM6Ly9s
b2NhbGhvc3Q6ODA4MSB7CiAgICB0bHMgaW50ZXJuYWwKICAgIHJldmVyc2VfcHJveHkgMTI3LjAu
MC4xOjMwMDAgewogICAgICAgIGhlYWRlcl91cCBIb3N0IEBATUFJTl9ET01BSU5AQAogICAgICAg
IGhlYWRlcl91cCBYLUZvcndhcmRlZC1Ib3N0IEBATUFJTl9ET01BSU5AQAogICAgICAgIGhlYWRl
cl91cCBYLUZvcndhcmRlZC1Qcm90byBodHRwcwogICAgfQp9CkNBRERZCgogIGxvZyAiWzMvNF0g
0JLQsNC70LjQtNCw0YbQuNGPICsg0L/QtdGA0LXQt9Cw0LPRgNGD0LfQutCwIENhZGR5IgogIGlm
IGRvY2tlciBleGVjICIkQ0FERFlfQ1RSIiBjYWRkeSB2YWxpZGF0ZSAtLWNvbmZpZyAvZXRjL2Nh
ZGR5L0NhZGR5ZmlsZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGVjaG8gInZhbGlkYXRlOiBP
SyIKICAgIGRvY2tlciBleGVjICIkQ0FERFlfQ1RSIiBjYWRkeSByZWxvYWQgLS1jb25maWcgL2V0
Yy9jYWRkeS9DYWRkeWZpbGUgJiYgZWNobyAicmVsb2FkOiBPSyIgXAogICAgICB8fCB7IGVjaG8g
InJlbG9hZCDQvdC1INC/0YDQvtGI0ZHQuywg0L/QtdGA0LXQt9Cw0L/Rg9GB0LrQsNGOINC60L7Q
vdGC0LXQudC90LXRgCI7IGRvY2tlciByZXN0YXJ0ICIkQ0FERFlfQ1RSIjsgfQogIGVsc2UKICAg
IGVjaG8gInZhbGlkYXRlINC90LXQtNC+0YHRgtGD0L/QtdC9ICjQtNGA0YPQs9C+0Lkg0L/Rg9GC
0Ywg0LrQvtC90YTQuNCz0LA/KSDigJQg0L/QtdGA0LXQt9Cw0L/Rg9GB0LrQsNGOINC60L7QvdGC
0LXQudC90LXRgCIKICAgIGRvY2tlciByZXN0YXJ0ICIkQ0FERFlfQ1RSIgogIGZpCgogIGxvZyAi
WzQvNF0g0J/RgNC+0LLQtdGA0LrQsCDRh9C10YDQtdC3INGB0LDQvCBDYWRkeSAoODQ0Mywg0LIg
0L7QsdGF0L7QtCBSZWFsaXR5KSIKICBzbGVlcCAyCiAgZWNobyAiLS0tINC00LXQutC+0Lkg0LIg
0LrQvtGA0L3QtSAo0L7QttC40LTQsNC10LwgTXlTcGhlcmUgSlNPTikgLS0tIgogIGN1cmwgLXNr
IC0tcmVzb2x2ZSAiJERPTUFJTjo4NDQzOjEyNy4wLjAuMSIgImh0dHBzOi8vJERPTUFJTjo4NDQz
L2FwaS9zdGF0dXMiOyBlY2hvCiAgZWNobyAiLS0tINC/0L7QtNC/0LjRgdC60LAgKNC+0LbQuNC0
0LDQtdC8IFhyYXktSlNPTiwg0L3QtSDQtNC10LrQvtC5KSAtLS0iCiAgY3VybCAtc2sgLS1yZXNv
bHZlICIkRE9NQUlOOjg0NDM6MTI3LjAuMC4xIiAtQSBIYXBwICJodHRwczovLyRET01BSU46ODQ0
My9hcGkvc3ViLyRTVUJfVVVJRCIgfCBoZWFkIC1jIDE2MDsgZWNobwogIGVjaG8KICBlY2hvICLi
nIUg0JrQvtGA0LXQvdGMIC0+IE15U3BoZXJlLCAvYXBpL3N1YiAtPiDQv9C+0LTQv9C40YHQutCw
LiDQntGC0LrQsNGCINC/0YDQuCDQv9GA0L7QsdC70LXQvNCw0YU6IgogIGVjaG8gIiAgIGNwIFwi
JGJha1wiIFwiJENBRERZRklMRVwiICYmIGRvY2tlciBleGVjICRDQUREWV9DVFIgY2FkZHkgcmVs
b2FkIC0tY29uZmlnIC9ldGMvY2FkZHkvQ2FkZHlmaWxlIgogIGVjaG8KICBlY2hvICLQn9Cw0L3Q
tdC70Ywg0L3QtSDQv9GD0LHQu9C40YfQvdCwLiDQlNC+0YHRgtGD0L86IgogIGVjaG8gIiAgIC0g
VGFpbHNjYWxlICjQvtGB0L3QvtCy0L3QvtC5KTogaHR0cHM6Ly9tb29ubGlnaHQuPNGC0LLQvtC5
LXRhaWxuZXQ+LnRzLm5ldCIKICBlY2hvICIgICAgICAgKNC+0LTQuNC9INGA0LDQtzogdGFpbHNj
YWxlIHNlcnZlIC0tYmcgaHR0cDovLzEyNy4wLjAuMTo4MDgyKSIKICBlY2hvICIgICAtINCU0LXR
gdC60YLQvtC/LdGE0L7Qu9Cx0Y3Qujogc3NoIC1MIDgwODE6MTI3LjAuMC4xOjgwODEgcm9vdEBA
QEVYSVRfSVBAQCAtPiBodHRwczovL2xvY2FsaG9zdDo4MDgxIgp9CgpjYXNlICIkezE6LX0iIGlu
CiAgZGVjb3kpIHN0YWdlX2RlY295IDs7CiAgY2FkZHkpIHN0YWdlX2NhZGR5IDs7CiAgKikgZWNo
byAi0JjRgdC/0L7Qu9GM0LfQvtCy0LDQvdC40LU6IGJhc2ggc3RlYWx0aC5zaCB7ZGVjb3l8Y2Fk
ZHl9IjsgZXhpdCAxIDs7CmVzYWMK
__B64__
  base64 -d > "$d/sync-hy2-cert.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIHN5bmMtaHkyLWNl
cnQuc2gg4oCUINC60L7Qv9C40YDRg9C10YIgTEUt0YHQtdGA0YIg0LjQtyDRgtC+0LzQsCBDYWRk
eSDQsiDQv9Cw0L/QutGDINC90L7QtNGLIChIeXN0ZXJpYTIpLgojICDQn9C+0YHRgtCw0LLQuNGC
0Ywg0LIgY3JvbiDRgNCw0Lcg0LIg0L3QtdC00LXQu9GOICjRgdC10YDRgiDQttC40LLRkdGCIH4y
LTMg0LzQtdGBKS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWUKIyBNQUlOX0RPTUFJTiDQ
stGB0LXQs9C00LAg0YDQsNCy0LXQvSDQtNC+0LzQtdC90YMg0Y3RgtC+0LPQviDRgdC10YDQstC1
0YDQsCAoc2V0dXAtcmVsYXktc3NoLnNoCiMg0L/QtdGA0LXRgdGC0LDQstC70Y/QtdGCINC00L7Q
vNC10L3RiyDQsiByZWxheS1kZXBsb3kuY29uZiwg0L/QvtGN0YLQvtC80YMg0LLRgdC10LPQtNCw
INCx0LXRgNGR0LwgTUFJTl9ET01BSU4pCkRPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpDRVJURElS
PSIvb3B0L0BAU0xVR0BAL25vZGUvY2VydHMiClZPTD0iY2FkZHlfY2FkZHlfZGF0YSIKU1VCPSJj
YWRkeS9jZXJ0aWZpY2F0ZXMvYWNtZS12MDIuYXBpLmxldHNlbmNyeXB0Lm9yZy1kaXJlY3Rvcnkv
JHtET01BSU59IgoKbWtkaXIgLXAgIiRDRVJURElSIgoKZWNobyAiICDQltC00YMg0YHQtdGA0YLQ
uNGE0LjQutCw0YIg0LTQu9GPICRET01BSU4gKNC00L4gNSDQvNC40L0p4oCmIgpmb3IgaSBpbiAk
KHNlcSAxIDMwKTsgZG8KICBpZiBkb2NrZXIgcnVuIC0tcm0gLXYgIiR7Vk9MfSI6L2NkOnJvIGFs
cGluZSBzaCAtYyAidGVzdCAtZiAvY2QvJHtTVUJ9LyR7RE9NQUlOfS5jcnQiIDI+L2Rldi9udWxs
OyB0aGVuCiAgICBlY2hvICIgIOKckyDRgdC10YDRgtC40YTQuNC60LDRgiDQv9C+0Y/QstC40LvR
gdGPICjQv9C+0L/Ri9GC0LrQsCAkaSkiCiAgICBicmVhawogIGZpCiAgWyAiJGkiID0gMzAgXSAm
JiB7IGVjaG8gIiAg4pyXINGB0LXRgNGCINGC0LDQuiDQuCDQvdC1INC/0L7Rj9Cy0LjQu9GB0Y8g
0LfQsCA1INC80LjQvSDigJQg0L/RgNC+0LLQtdGA0Yw6IGRvY2tlciBsb2dzIEBAU0xVR0BALWNh
ZGR5IHwgdGFpbCAtMjAiOyBleGl0IDE7IH0KICBlY2hvICIgIOKApiDQv9C+0L/Ri9GC0LrQsCAk
aS8zMCwg0LbQtNGDIDEw0YEiCiAgc2xlZXAgMTAKZG9uZQoKZG9ja2VyIHJ1biAtLXJtIC12ICIk
e1ZPTH0iOi9jZDpybyAtdiAiJHtDRVJURElSfSI6L291dCBhbHBpbmUgc2ggLWMgIgogIGNwIC9j
ZC8ke1NVQn0vJHtET01BSU59LmNydCAvb3V0L2h5Mi5jcnQgJiYKICBjcCAvY2QvJHtTVUJ9LyR7
RE9NQUlOfS5rZXkgL291dC9oeTIua2V5ICYmCiAgY2htb2QgNjQ0IC9vdXQvaHkyLmNydCAmJiBj
aG1vZCA2MDAgL291dC9oeTIua2V5CiIKZWNobyAiT0s6INGB0LXRgNGCICR7RE9NQUlOfSDRgdC6
0L7Qv9C40YDQvtCy0LDQvSDQsiAkQ0VSVERJUiAoaHkyLmNydCwgaHkyLmtleSkiCmxzIC1sICIk
Q0VSVERJUiIKZG9ja2VyIHJlc3RhcnQgcmVtbmFub2RlID4vZGV2L251bGwgMj4mMSAmJiBlY2hv
ICLQndC+0LTQsCDQv9C10YDQtdC30LDQv9GD0YnQtdC90LAgKNC/0L7QtNGF0LLQsNGC0LjRgiDR
gdC10YDRgikiIHx8IHRydWUK
__B64__
  base64 -d > "$d/wdtt-build.sh.tpl" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHdkdHQtYnVpbGQuc2gg4oCUINGB0LHQvtGA0LrQsCDQuCDR
g9GB0YLQsNC90L7QstC60LAgV0RUVCBWUE4gU2VydmVyINC90LAgQEBFWElUX05BTUVAQApzZXQg
LWV1byBwaXBlZmFpbApleHBvcnQgUEFUSD0iJFBBVEg6L3Vzci9sb2NhbC9nby9iaW4iClNSQz0v
b3B0L0BAU0xVR0BAL3dkdHQvc3JjCm1rZGlyIC1wIC9vcHQvQEBTTFVHQEAvd2R0dAoKZWNobyAi
PT1bMC80XSDQl9Cw0LLQuNGB0LjQvNC+0YHRgtC4IChjdXJsLCBnaXQsIHVmdykgPT0iCmV4cG9y
dCBERUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUKYXB0LWdldCB1cGRhdGUgLXkgLXFxID4v
ZGV2L251bGwgMj4mMQphcHQtZ2V0IGluc3RhbGwgLXkgLXFxIGN1cmwgZ2l0IHVmdyA+L2Rldi9u
dWxsIDI+JjEKZWNobyAiICAgT0siCgoKZWNobyAiPT1bMS80XSBHbyAo0L3Rg9C20LXQvSA+PSAx
LjI1KSA9PSIKaWYgISBnbyB2ZXJzaW9uIDI+L2Rldi9udWxsIHwgZ3JlcCAtcUUgJ2dvMVwuKDJb
NS05XXxbMy05XVswLTldKSc7IHRoZW4KICBWRVI9ImdvMS4yNi40IgogIGVjaG8gIiAgINCj0YHR
gtCw0L3QsNCy0LvQuNCy0LDRjiAkVkVSINCyIC91c3IvbG9jYWwvZ28gLi4uIgogIGN1cmwgLWZz
U0wgImh0dHBzOi8vZGwuZ29vZ2xlLmNvbS9nby8ke1ZFUn0ubGludXgtYW1kNjQudGFyLmd6IiB8
IHRhciAtQyAvdXNyL2xvY2FsIC14egpmaQpnbyB2ZXJzaW9uCgplY2hvICI9PVsyLzRdINCY0YHR
hdC+0LTQvdC40LrQuCA9PSIKaWYgWyAtZCAiJFNSQy8uZ2l0IiBdOyB0aGVuCiAgZ2l0IC1DICIk
U1JDIiBwdWxsIC0tZmYtb25seQplbHNlCiAgZ2l0IGNsb25lIC0tZGVwdGggMSBodHRwczovL2dp
dGh1Yi5jb20vYW11cmNhbm92L3Byb3h5LXR1cm4tdmstYW5kcm9pZC5naXQgIiRTUkMiCmZpCgpl
Y2hvICI9PVszLzRdINCh0LHQvtGA0LrQsCB3ZHR0LXNlcnZlciAobGludXgvYW1kNjQpID09Igpj
ZCAiJFNSQyIKZWNobyAiICAgZ28gbW9kIHRpZHkgKNC30LDQv9C+0LvQvdGP0LXQvCBnby5zdW0p
Li4uIgpHT0ZMQUdTPS1tb2Q9bW9kIGdvIG1vZCB0aWR5IDI+JjEgfCB0YWlsIC01CkdPRkxBR1M9
LW1vZD1tb2QgR09PUz1saW51eCBHT0FSQ0g9YW1kNjQgQ0dPX0VOQUJMRUQ9MCBcCiAgZ28gYnVp
bGQgLWxkZmxhZ3M9Ii1zIC13IiAtbyAvdG1wL3dkdHQtc2VydmVyIHNlcnZlci5nbwoKZWNobyAi
PT1bNC80XSDQn9GA0L7QstC10YDQutCwID09IgpscyAtbGEgL3RtcC93ZHR0LXNlcnZlcgpmaWxl
IC90bXAvd2R0dC1zZXJ2ZXIgMj4vZGV2L251bGwgfHwgdHJ1ZQoKZWNobyAiPT1bNS81XSDQo9GB
0YLQsNC90L7QstC60LAgV0RUVCA9PSIKIyDQvtGC0LrQu9GO0YfQsNC10Lwgc2V0IC1lINC90LAg
0LLQtdGB0Ywg0LHQu9C+0Log4oCUIGRlcGxveS5zaCDQstC+0LfQstGA0LDRidCw0LXRgiDQvdC1
0L3Rg9C70LXQstC+0Lkg0LrQvtC0INC/0YDQuCAiYWN0aXZhdGluZyIKc2V0ICtldW8gcGlwZWZh
aWwKQ1JFRF9GSUxFPSIvb3B0L0BAU0xVR0BAL2NyZWRlbnRpYWxzLnR4dCIKWyAtZiAiJENSRURf
RklMRSIgXSB8fCB7IG1rZGlyIC1wICIvb3B0L0BAU0xVR0BAIjsgdG91Y2ggIiRDUkVEX0ZJTEUi
OyB9CiMg0L/RgNC40L7RgNC40YLQtdGCOiBXRFRUX1BBU1Mg0LjQtyDQstC40LfQsNGA0LTQsCAo
ZW52L2NvbmYpIOKGkiDRg9C20LUg0YHQvtGF0YDQsNC90ZHQvdC90YvQuSDQsiBjcmVkcyDihpIg
0YHQu9GD0YfQsNC50L3Ri9C5Cl9XRFRUX0ZST01fQ09ORj0iJHtXRFRUX1BBU1M6LX0iCldEVFRf
UEFTUz0iJChncmVwICded2R0dC1wYXNzd29yZDonICIkQ1JFRF9GSUxFIiAyPi9kZXYvbnVsbCB8
IGF3ayAne3ByaW50ICQyfScpIgppZiBbIC1uICIkX1dEVFRfRlJPTV9DT05GIiBdOyB0aGVuCiAg
V0RUVF9QQVNTPSIkX1dEVFRfRlJPTV9DT05GIgogIGlmIGdyZXAgLXEgJ153ZHR0LXBhc3N3b3Jk
OicgIiRDUkVEX0ZJTEUiIDI+L2Rldi9udWxsOyB0aGVuCiAgICBzZWQgLWkgInN8XndkdHQtcGFz
c3dvcmQ6Lip8d2R0dC1wYXNzd29yZDogJFdEVFRfUEFTU3wiICIkQ1JFRF9GSUxFIgogIGVsc2UK
ICAgIHByaW50ZiAnd2R0dC1wYXNzd29yZDogJXNcbicgIiRXRFRUX1BBU1MiID4+ICIkQ1JFRF9G
SUxFIgogIGZpCiAgZWNobyAiICDQv9Cw0YDQvtC70YwgV0RUVCDQt9Cw0LTQsNC9INCyINCy0LjQ
t9Cw0YDQtNC1LCDRgdC+0YXRgNCw0L3RkdC9INCyICRDUkVEX0ZJTEUiCmVsaWYgWyAteiAiJFdE
VFRfUEFTUyIgXTsgdGhlbgogIFdEVFRfUEFTUz0iJChvcGVuc3NsIHJhbmQgLWhleCAxMiAyPi9k
ZXYvbnVsbCkiCiAgcHJpbnRmICd3ZHR0LXBhc3N3b3JkOiAlc1xuJyAiJFdEVFRfUEFTUyIgPj4g
IiRDUkVEX0ZJTEUiCiAgZWNobyAiICDQv9Cw0YDQvtC70Ywg0YHQs9C10L3QtdGA0LjRgNC+0LLQ
sNC9INC4INGB0L7RhdGA0LDQvdGR0L0g0LIgJENSRURfRklMRSIKZWxzZQogIGVjaG8gIiAg0L/Q
sNGA0L7Qu9GMINGD0LbQtSDQtdGB0YLRjCDQsiAkQ1JFRF9GSUxFIgpmaQppcHRhYmxlcy1zYXZl
ID4gL3Jvb3QvaXB0YWJsZXMtYmVmb3JlLXdkdHQuYmFrIDI+L2Rldi9udWxsCldEVFRfQVJHUz0i
LXBhc3N3b3JkICRXRFRUX1BBU1MiIGJhc2ggIiRTUkMvYXBwL3NyYy9tYWluL2Fzc2V0cy9kZXBs
b3kuc2giIGluc3RhbGwKIyDRgdC+0LfQtNCw0ZHQvCBwYXNzd29yZHMuanNvbiDQvdCw0L/RgNGP
0LzRg9GOIOKAlCDQt9Cw0L/Rg9GB0LrQsNC10Lwg0YHQtdGA0LLQtdGAINC90LAgMyDRgdC10Log
0Lgg0YPQsdC40LLQsNC10LwKbWtkaXIgLXAgL2V0Yy93ZHR0Ci91c3IvbG9jYWwvYmluL3dkdHQt
c2VydmVyIC1jb25maWctZGlyIC9ldGMvd2R0dCAtcGFzc3dvcmQgIiRXRFRUX1BBU1MiICYKX3dw
aWQ9JCE7IHNsZWVwIDM7IGtpbGwgJF93cGlkIDI+L2Rldi9udWxsOyB3YWl0ICRfd3BpZCAyPi9k
ZXYvbnVsbApzeXN0ZW1jdGwgcmVzdGFydCB3ZHR0IDI+L2Rldi9udWxsCnNsZWVwIDMKaWYgc3lz
dGVtY3RsIGlzLWFjdGl2ZSAtLXF1aWV0IHdkdHQgMj4vZGV2L251bGw7IHRoZW4KICBlY2hvCiAg
ZWNobyAi4pyFIFdEVFQg0YPRgdGC0LDQvdC+0LLQu9C10L0g0Lgg0LfQsNC/0YPRidC10L0iCiAg
ZWNobyAiICAg0J/QsNGA0L7Qu9GMOiAkV0RUVF9QQVNTICjRgtCw0LrQttC1INCyICRDUkVEX0ZJ
TEUpIgogIGVjaG8gIiAgIGlPUyDQutC70LjQtdC90YI6IGdpdGh1Yi5jb20vYW50b240OC92ay10
dXJuLXByb3h5LWlvcyDihpIg0YDQtdC20LjQvCBTUlRQLVdSQVAtQSIKZWxzZQogIGVjaG8gIiAg
ISBXRFRUINC90LUg0YHRgtCw0YDRgtC+0LLQsNC7IOKAlCDQs9C70Y/QvdGMOiBqb3VybmFsY3Rs
IC11IHdkdHQgLW4gMjAiCmZpCg==
__B64__
  base64 -d > "$d/vpn-probe.py" <<'__B64__'
IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwojIC0qLSBjb2Rpbmc6IHV0Zi04IC0qLQoiIiIKdnBuLXBy
b2JlIOKAlCDQstC30LPQu9GP0LQgwqvQs9C70LDQt9Cw0LzQuCDRhtC10L3Qt9C+0YDQsMK7INC9
0LAg0YLQstC+0Lkg0YHQtdGA0LLQtdGAINGB0L3QsNGA0YPQttC4LgrQktC90LXRiNC90Y/RjyDQ
v9GA0L7QstC10YDQutCwINGB0LXRgNCy0LXRgNCwIMKr0LPQu9Cw0LfQsNC80Lgg0YbQtdC90LfQ
vtGA0LDCuyDQv9C+0LQgc2VsZnN0ZWFsICsgUmVtbmF3YXZlLgoK0JfQsNC/0YPRgdC6ICjRgSDQ
vdC+0YPRgtCwINC40LvQuCDQtNGA0YPQs9C+0LPQviBWUFMsINCd0JUg0YEg0YHQsNC80L7Qs9C+
INC/0YDQvtCy0LXRgNGP0LXQvNC+0LPQviDRgdC10YDQstC10YDQsCk6CiAgICBweXRob24zIHZw
bi1wcm9iZS5weSBjbG91ZC5leGFtcGxlLmNvbSBbcnUuZXhhbXBsZS5jb20gLi4uXQrQotC+0LvR
jNC60L4g0YHRgtCw0L3QtNCw0YDRgtC90LDRjyDQsdC40LHQu9C40L7RgtC10LrQsCBQeXRob24g
My44Ky4g0JXRgdC70Lgg0LXRgdGC0YwgYG9wZW5zc2xgIOKAlCDQuNGB0L/QvtC70YzQt9GD0LXR
giDQtdCz0L4g0LTQu9GPINGB0LXRgNGC0LjRhNC40LrQsNGC0LAuCgrQmtC+0LTRizogW09LXSDQ
vdC+0YDQvNCwIMK3IFtpXSDQuNC90YTQvi/QvtC20LjQtNCw0LXQvNC+INC00LvRjyBzZWxmc3Rl
YWwgwrcgWyFdINC/0L7QtNC+0LfRgNC40YLQtdC70YzQvdC+ICjRgdGC0L7QuNGCINGA0LDQt9C+
0LHRgNCw0YLRjNGB0Y8pCiIiIgppbXBvcnQgc3lzLCBzb2NrZXQsIHNzbCwgc3VicHJvY2Vzcywg
cmUsIGhhc2hsaWIKZnJvbSBkYXRldGltZSBpbXBvcnQgZGF0ZXRpbWUsIHRpbWV6b25lCgpUSU1F
T1VUID0gNgojINCf0L7RgNGC0YssINC+0YLQutGA0YvRgtC+0YHRgtGMINC60L7RgtC+0YDRi9GF
INGB0L3QsNGA0YPQttC4INCy0YvQtNCw0ZHRgiDQv9GA0L7QutGB0Lgt0LjQvdGE0YDQsNGB0YLR
gNGD0LrRgtGD0YDRgy4KU1VTUElDSU9VU19QT1JUUyA9IHsKICAgIDgwOiAgICLQvtCx0YvRh9C9
0YvQuSBIVFRQICjQvtC6LCDQtdGB0LvQuCDRgNC10LTQuNGA0LXQutGC0LjRgiDQvdCwIDQ0Myki
LAogICAgODA4MDogItGH0LDRgdGC0YvQuSBmYWxsYmFjayDQv9GA0L7QutGB0LgiLAogICAgODQ0
MzogItGH0LDRgdGC0YvQuSBmYWxsYmFjayAvINGC0LLQvtC5INC70L7QutCw0LvRjNC90YvQuSBS
ZWFsaXR5LWRlc3Qg4oCUINCd0JUg0LTQvtC70LbQtdC9INGC0L7RgNGH0LDRgtGMINC90LDRgNGD
0LbRgyIsCiAgICAyMDUzOiAi0L/QsNC90LXQu9C4IHgtdWkvM3gtdWkgKNC40LvQuCAvd3NuZyDQ
sdC10LrQtdC90LQg4oCUINC00L7Qu9C20LXQvSDQsdGL0YLRjCDRgtC+0LvRjNC60L4g0L3QsCAx
MjcuMC4wLjEpIiwKICAgIDIwNTQ6ICLRh9Cw0YHRgtC+IFhIVFRQLdCx0LXQutC10L3QtCDigJQg
0LTQvtC70LbQtdC9INCx0YvRgtGMINGC0L7Qu9GM0LrQviDQvdCwIDEyNy4wLjAuMSIsCiAgICAy
MDgzOiAi0L/QsNC90LXQu9C4IFZQTiIsIDIwODc6ICLQv9Cw0L3QtdC70LggVlBOIiwgMjA5Njog
ItC/0LDQvdC10LvQuCBWUE4iLAogICAgMzAwMDogIlJlbW5hd2F2ZS/Qv9Cw0L3QtdC70Ywg4oCU
INCd0JUg0LTQvtC70LbQtdC9INGC0L7RgNGH0LDRgtGMINC90LDRgNGD0LbRgyIsCiAgICAzMDEw
OiAic3ViLXBhZ2Ug0LHQtdC60LXQvdC0IOKAlCDRgtC+0LvRjNC60L4g0LvQvtC60LDQu9GM0L3Q
viIsCiAgICAzMDE1OiAiY29ubmVjdC3RgdGC0YDQsNC90LjRhtCwINCx0LXQutC10L3QtCDigJQg
0YLQvtC70YzQutC+INC70L7QutCw0LvRjNC90L4iLAogICAgMTAwMDA6ICJXZWJtaW4gLyDRg9C/
0YDQsNCy0LvQtdC90LjQtSDQv9GA0L7QutGB0LgiLAogICAgOTAwMDogItGH0LDRgdGC0L4gbWFu
YWdlbWVudC3Qv9C+0YDRgtGLIiwKfQojINCf0YPRgtC4OiDQvtCx0YnQuNC1INC80LDRgNC60LXR
gNGLINC/0YDQvtC60YHQuCArINCi0JLQntCYINGA0LXQsNC70YzQvdGL0LUg0YLRgNCw0L3RgdC/
0L7RgNGC0L3Ri9C1INC/0YPRgtC4LgpQUk9YWV9QQVRIUyA9IFsiL3dzIiwgIi9yYXkiLCAiL3Yy
cmF5IiwgIi92bWVzcyIsICIvdmxlc3MiLCAiL3Ryb2phbiIsICIvZ3JwYyIsCiAgICAgICAgICAg
ICAgICIvd3NuZyIsICIveGgiLCAiL3N1YiIsICIvYXBpL3N1YiIsICIvYy8iXQoKCmRlZiBjKGNv
ZGUsIHMpOgogICAgY29sID0geyJPSyI6ICJcMDMzWzMybSIsICJpIjogIlwwMzNbMzZtIiwgIiEi
OiAiXDAzM1szM20iLCAiaCI6ICJcMDMzWzE7MzdtIn0uZ2V0KGNvZGUsICIiKQogICAgcmV0dXJu
IGYie2NvbH17c31cMDMzWzBtIgoKCmRlZiBsaW5lKHRhZywgbXNnKToKICAgIHN5bSA9IHsiT0si
OiAiW09LXSIsICJpIjogIltpXSAiLCAiISI6ICJbIV0gIn1bdGFnXQogICAgcHJpbnQoZiIgIHtj
KHRhZywgc3ltKX0ge21zZ30iKQoKCmRlZiBoZWFkKHMpOgogICAgcHJpbnQoIlxuIiArIGMoImgi
LCBzKSkKCgpkZWYgcmVzb2x2ZShob3N0KToKICAgIHRyeToKICAgICAgICByZXR1cm4gc29ja2V0
LmdldGhvc3RieW5hbWUoaG9zdCkKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJu
IE5vbmUKCgpkZWYgcG9ydF9vcGVuKGlwLCBwb3J0KToKICAgIHRyeToKICAgICAgICB3aXRoIHNv
Y2tldC5jcmVhdGVfY29ubmVjdGlvbigoaXAsIHBvcnQpLCB0aW1lb3V0PTMpOgogICAgICAgICAg
ICByZXR1cm4gVHJ1ZQogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICByZXR1cm4gRmFsc2UK
CgpkZWYgdGxzX2dldChob3N0LCBwYXRoPSIvIiwgZXh0cmFfaGVhZGVycz1Ob25lLCBzbmk9Tm9u
ZSk6CiAgICAiIiJIVFRQUyBHRVQsINC90LUg0LLQsNC70LjQtNC40YDRg9GPINGB0LXRgNGC0LjR
hNC40LrQsNGCICjQutCw0Log0YbQtdC90LfQvtGAKS4gLT4gKHN0YXR1cywgaGVhZGVycywgYm9k
eSwgYWxwbikiIiIKICAgIGN0eCA9IHNzbC5jcmVhdGVfZGVmYXVsdF9jb250ZXh0KCkKICAgIGN0
eC5jaGVja19ob3N0bmFtZSA9IEZhbHNlCiAgICBjdHgudmVyaWZ5X21vZGUgPSBzc2wuQ0VSVF9O
T05FCiAgICB0cnk6CiAgICAgICAgY3R4LnNldF9hbHBuX3Byb3RvY29scyhbImgyIiwgImh0dHAv
MS4xIl0pCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIHRyeToKICAgICAg
ICByYXcgPSBzb2NrZXQuY3JlYXRlX2Nvbm5lY3Rpb24oKGhvc3QsIDQ0MyksIHRpbWVvdXQ9VElN
RU9VVCkKICAgICAgICBzID0gY3R4LndyYXBfc29ja2V0KHJhdywgc2VydmVyX2hvc3RuYW1lPXNu
aSBvciBob3N0KQogICAgICAgIGFscG4gPSBzLnNlbGVjdGVkX2FscG5fcHJvdG9jb2woKQogICAg
ICAgIGhkcnMgPSB7Ikhvc3QiOiBzbmkgb3IgaG9zdCwgIlVzZXItQWdlbnQiOiAiTW96aWxsYS81
LjAiLCAiQ29ubmVjdGlvbiI6ICJjbG9zZSJ9CiAgICAgICAgaWYgZXh0cmFfaGVhZGVyczoKICAg
ICAgICAgICAgaGRycy51cGRhdGUoZXh0cmFfaGVhZGVycykKICAgICAgICByZXEgPSBmIkdFVCB7
cGF0aH0gSFRUUC8xLjFcclxuIiArICIiLmpvaW4oZiJ7a306IHt2fVxyXG4iIGZvciBrLCB2IGlu
IGhkcnMuaXRlbXMoKSkgKyAiXHJcbiIKICAgICAgICBzLnNlbmRhbGwocmVxLmVuY29kZSgpKQog
ICAgICAgIGRhdGEgPSBiIiIKICAgICAgICB3aGlsZSBsZW4oZGF0YSkgPCA2NTUzNjoKICAgICAg
ICAgICAgdHJ5OgogICAgICAgICAgICAgICAgY2h1bmsgPSBzLnJlY3YoNDA5NikKICAgICAgICAg
ICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgIGlm
IG5vdCBjaHVuazoKICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgIGRhdGEgKz0gY2h1
bmsKICAgICAgICBzLmNsb3NlKCkKICAgICAgICB0ZXh0ID0gZGF0YS5kZWNvZGUoImxhdGluLTEi
LCAicmVwbGFjZSIpCiAgICAgICAgc3RhdHVzID0gMAogICAgICAgIG0gPSByZS5tYXRjaChyIkhU
VFAvW1xkLl0rIChcZCspIiwgdGV4dCkKICAgICAgICBpZiBtOgogICAgICAgICAgICBzdGF0dXMg
PSBpbnQobS5ncm91cCgxKSkKICAgICAgICBoZWFkX3BhcnQgPSB0ZXh0LnNwbGl0KCJcclxuXHJc
biIsIDEpWzBdCiAgICAgICAgaGVhZGVycyA9IHt9CiAgICAgICAgZm9yIGxuIGluIGhlYWRfcGFy
dC5zcGxpdCgiXHJcbiIpWzE6XToKICAgICAgICAgICAgaWYgIjoiIGluIGxuOgogICAgICAgICAg
ICAgICAgaywgdiA9IGxuLnNwbGl0KCI6IiwgMSkKICAgICAgICAgICAgICAgIGhlYWRlcnNbay5z
dHJpcCgpLmxvd2VyKCldID0gdi5zdHJpcCgpCiAgICAgICAgYm9keSA9IHRleHQuc3BsaXQoIlxy
XG5cclxuIiwgMSlbMV0gaWYgIlxyXG5cclxuIiBpbiB0ZXh0IGVsc2UgIiIKICAgICAgICByZXR1
cm4gc3RhdHVzLCBoZWFkZXJzLCBib2R5LCBhbHBuCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
ICAgIHJldHVybiBOb25lLCB7fSwgIiIsIE5vbmUKCgpkZWYgZ2V0X2NlcnRfb3BlbnNzbChob3N0
KToKICAgIHRyeToKICAgICAgICBwID0gc3VicHJvY2Vzcy5ydW4oWyJvcGVuc3NsIiwgInNfY2xp
ZW50IiwgIi1jb25uZWN0IiwgZiJ7aG9zdH06NDQzIiwgIi1zZXJ2ZXJuYW1lIiwgaG9zdF0sCiAg
ICAgICAgICAgICAgICAgICAgICAgICAgIGlucHV0PSIiLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0
ZXh0PVRydWUsIHRpbWVvdXQ9VElNRU9VVCkKICAgICAgICBvdXQgPSBwLnN0ZG91dAogICAgICAg
IHR4dCA9IHN1YnByb2Nlc3MucnVuKFsib3BlbnNzbCIsICJ4NTA5IiwgIi1ub291dCIsICItc3Vi
amVjdCIsICItaXNzdWVyIiwgIi1lbmRkYXRlIl0sCiAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgaW5wdXQ9b3V0LCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9VElN
RU9VVCkuc3Rkb3V0CiAgICAgICAgcmV0dXJuIHR4dAogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAg
ICAgICByZXR1cm4gIiIKCgpkZWYgY2hlY2tfcG9ydHMoaXApOgogICAgaGVhZCgiMS4g0J/QvtGA
0YIt0YHRkdGA0YTQtdC50YEgKNGH0YLQviDQvtGC0LrRgNGL0YLQviDRgdC90LDRgNGD0LbQuCki
KQogICAgaWYgbm90IHBvcnRfb3BlbihpcCwgNDQzKToKICAgICAgICBsaW5lKCIhIiwgIjQ0My90
Y3Ag0JfQkNCa0KDQq9CiIOKAlCDRgdC10YDQstC10YAg0L3QtdC00L7RgdGC0YPQv9C10L0g0L/Q
viBIVFRQUz8iKQogICAgZWxzZToKICAgICAgICBsaW5lKCJPSyIsICI0NDMvdGNwINC+0YLQutGA
0YvRgiAo0L7QttC40LTQsNC10LzQvikiKQogICAgZmxhZ2dlZCA9IDAKICAgIGZvciBwb3J0LCB3
aHkgaW4gU1VTUElDSU9VU19QT1JUUy5pdGVtcygpOgogICAgICAgIGlmIHBvcnQgPT0gNDQzOgog
ICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIHBvcnRfb3BlbihpcCwgcG9ydCk6CiAgICAg
ICAgICAgIHRhZyA9ICJpIiBpZiBwb3J0ID09IDgwIGVsc2UgIiEiCiAgICAgICAgICAgIGxpbmUo
dGFnLCBmIntwb3J0fS90Y3Ag0J7QotCa0KDQq9CiIOKAlCB7d2h5fSIpCiAgICAgICAgICAgIGlm
IHBvcnQgIT0gODA6CiAgICAgICAgICAgICAgICBmbGFnZ2VkICs9IDEKICAgIGlmIGZsYWdnZWQg
PT0gMDoKICAgICAgICBsaW5lKCJPSyIsICLQu9C40YjQvdC40YUg0L/RgNC+0LrRgdC4L9C/0LDQ
vdC10LvRjC3Qv9C+0YDRgtC+0LIg0L3QsNGA0YPQttGDINC90LUg0YLQvtGA0YfQuNGCIikKCgpk
ZWYgY2hlY2tfaHR0cChob3N0KToKICAgIGhlYWQoIjIuIEhUVFAt0L7RgtCy0LXRgiAo0L/QvtGF
0L7QttC1INC90LAg0L3QsNGB0YLQvtGP0YnQuNC5INGB0LDQudGCPykiKQogICAgc3QsIGhkcnMs
IGJvZHksIF8gPSB0bHNfZ2V0KGhvc3QsICIvIikKICAgIGlmIG5vdCBzdDoKICAgICAgICBsaW5l
KCIhIiwgItC90LUg0YPQtNCw0LvQvtGB0Ywg0L/RgNC+0YfQuNGC0LDRgtGMIEhUVFAt0L7RgtCy
0LXRgiDigJQgUmVhbGl0eSDRgNCy0ZHRgiDCq9C90LUtUmVhbGl0ecK7INGA0YPQutC+0L/QvtC2
0LDRgtC40LU/ICjQtNC70Y8g0LPQvtC70L7Qs9C+IElQINC90L7RgNC80LApIikKICAgICAgICBy
ZXR1cm4KICAgIHNydiA9IGhkcnMuZ2V0KCJzZXJ2ZXIiLCAiIikKICAgIGlmIHN0IGluICgyMDAs
IDMwMSwgMzAyLCA0MDMsIDQwNCk6CiAgICAgICAgbGluZSgiT0siLCBmItC60L7RgNC10L3RjCDQ
vtGC0LLQtdGH0LDQtdGCIEhUVFAge3N0fSAo0LrQsNC6INC+0LHRi9GH0L3Ri9C5INCy0LXQsS3R
gdC10YDQstC10YApIikKICAgIGVsc2U6CiAgICAgICAgbGluZSgiaSIsIGYi0LrQvtGA0LXQvdGM
INC+0YLQstC10YfQsNC10YIgSFRUUCB7c3R9IikKICAgIGlmIG5vdCBzcnY6CiAgICAgICAgbGlu
ZSgiT0siLCAi0LfQsNCz0L7Qu9C+0LLQvtC6IFNlcnZlciDQvtGC0YHRg9GC0YHRgtCy0YPQtdGC
L9GB0LrRgNGL0YIiKQogICAgZWxpZiByZS5zZWFyY2gociJcZCIsIHNydik6CiAgICAgICAgbGlu
ZSgiISIsIGYiU2VydmVyINGA0LDRgdC60YDRi9Cy0LDQtdGCINCy0LXRgNGB0LjRjjoge3Nydn0i
KQogICAgZWxzZToKICAgICAgICBsaW5lKCJPSyIsIGYiU2VydmVyOiB7c3J2fSAo0LHQtdC3INCy
0LXRgNGB0LjQuCkiKQogICAgc3QyLCBfLCBib2R5MiwgXyA9IHRsc19nZXQoaG9zdCwgIi96enot
cmFuZG9tLSIgKyBoYXNobGliLm1kNShob3N0LmVuY29kZSgpKS5oZXhkaWdlc3QoKVs6Nl0pCiAg
ICBpZiBzdDIgaW4gKDQwNCwgNDAzKToKICAgICAgICBsaW5lKCJPSyIsIGYi0YHQu9GD0YfQsNC5
0L3Ri9C5INC/0YPRgtGMIOKGkiB7c3QyfSAo0L3QvtGA0LzQsNC70YzQvdCw0Y8g0YDQtdCw0LrR
htC40Y8g0YHQsNC50YLQsCkiKQogICAgZWxpZiBzdDIgYW5kIHN0MiA9PSBzdCBhbmQgc3QgPT0g
MjAwOgogICAgICAgIGxpbmUoImkiLCAi0YHQu9GD0YfQsNC50L3Ri9C5INC/0YPRgtGMINC+0YLQ
stC10YfQsNC10YIg0LrQsNC6INC60L7RgNC10L3RjCDigJQg0LTQu9GPIGNsb3VkLdC00LXQutC+
0Y8vU1BBINGN0YLQviDQvtC6IikKCgpkZWYgY2hlY2tfY2VydChob3N0KToKICAgIGhlYWQoIjMu
IFRMUy3RgdC10YDRgtC40YTQuNC60LDRgiIpCiAgICB0eHQgPSBnZXRfY2VydF9vcGVuc3NsKGhv
c3QpCiAgICBpZiBub3QgdHh0OgogICAgICAgIGxpbmUoImkiLCAib3BlbnNzbCDQvdC10LTQvtGB
0YLRg9C/0LXQvSDigJQg0L/RgNC+0L/Rg9GB0LrQsNGOINC00LXRgtCw0LvRjNC90YvQuSDRgNCw
0LfQsdC+0YAg0YHQtdGA0YLQuNGE0LjQutCw0YLQsCIpCiAgICAgICAgcmV0dXJuCiAgICBzdWJq
ID0gcmUuc2VhcmNoKHIic3ViamVjdD0uKj9DTlxzKj1ccyooW15cbiwvXSspIiwgdHh0KQogICAg
aXNzID0gcmUuc2VhcmNoKHIiaXNzdWVyPS4qPyg/Ok98Q04pXHMqPVxzKihbXlxuLC9dKykiLCB0
eHQpCiAgICBlbmQgPSByZS5zZWFyY2gociJub3RBZnRlcj0oLispIiwgdHh0KQogICAgaWYgc3Vi
ajoKICAgICAgICBsaW5lKCJpIiwgZiLRgdC10YDRgtC40YTQuNC60LDRgiDQvdCwINC00L7QvNC1
0L06IHtzdWJqLmdyb3VwKDEpLnN0cmlwKCl9IOKAlCDQtNC70Y8gc2VsZnN0ZWFsINGN0YLQviDQ
ntCW0JjQlNCQ0JXQnNCeICjQtNC+0LzQtdC9INC4INC10YHRgtGMINC/0YDQuNC60YDRi9GC0LjQ
tSkiKQogICAgaWYgaXNzOgogICAgICAgIGxpbmUoIk9LIiwgZiLQuNC30LTQsNGC0LXQu9GMOiB7
aXNzLmdyb3VwKDEpLnN0cmlwKCl9IikKICAgIGlmIGVuZDoKICAgICAgICB0cnk6CiAgICAgICAg
ICAgIGV4cCA9IGRhdGV0aW1lLnN0cnB0aW1lKGVuZC5ncm91cCgxKS5zdHJpcCgpLCAiJWIgJWQg
JUg6JU06JVMgJVkgJVoiKS5yZXBsYWNlKHR6aW5mbz10aW1lem9uZS51dGMpCiAgICAgICAgICAg
IGRheXMgPSAoZXhwIC0gZGF0ZXRpbWUubm93KHRpbWV6b25lLnV0YykpLmRheXMKICAgICAgICAg
ICAgaWYgZGF5cyA8IDA6CiAgICAgICAgICAgICAgICBsaW5lKCIhIiwgZiLRgdC10YDRgtC40YTQ
uNC60LDRgiDQn9Cg0J7QodCg0J7Qp9CV0J0gKHtleHA6JVktJW0tJWR9KSIpCiAgICAgICAgICAg
IGVsaWYgZGF5cyA8IDE0OgogICAgICAgICAgICAgICAgbGluZSgiISIsIGYi0YHQtdGA0YLQuNGE
0LjQutCw0YIg0LjRgdGC0LXQutCw0LXRgiDRh9C10YDQtdC3IHtkYXlzfSDQtNC9LiAoe2V4cDol
WS0lbS0lZH0pIOKAlCDQvtCx0L3QvtCy0LgiKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAg
ICAgICAgbGluZSgiT0siLCBmItGB0LXRgNGC0LjRhNC40LrQsNGCINCy0LDQu9C40LTQtdC9INC1
0YnRkSB7ZGF5c30g0LTQvS4gKNC00L4ge2V4cDolWS0lbS0lZH0pIikKICAgICAgICBleGNlcHQg
RXhjZXB0aW9uOgogICAgICAgICAgICBsaW5lKCJpIiwgZiLRgdGA0L7Qujoge2VuZC5ncm91cCgx
KS5zdHJpcCgpfSIpCgoKZGVmIGNoZWNrX3BhdGhzKGhvc3QpOgogICAgaGVhZCgiNC4g0JTQuNGE
0YTQtdGA0LXQvdGG0LjQsNC7INGC0YDQsNC90YHQv9C+0YDRgtC90YvRhSDQv9GD0YLQtdC5ICjQ
s9C70LDQstC90L7QtSDQtNC70Y8g0YLQtdCx0Y8pIikKICAgIGN0cmwsIF8sIF8sIF8gPSB0bHNf
Z2V0KGhvc3QsICIvenp6LWNvbnRyb2wtIiArIGhhc2hsaWIubWQ1KGInYycpLmhleGRpZ2VzdCgp
Wzo2XSkKICAgIGlmIG5vdCBjdHJsOgogICAgICAgIGxpbmUoImkiLCAi0L3QtdGCINC90LDQtNGR
0LbQvdC+0LPQviBIVFRQLdC60L7QvdGC0YDQvtC70Y8g4oCUINC/0YDQvtC/0YPRgdC60LDRjiIp
CiAgICAgICAgcmV0dXJuCiAgICBvZGQgPSBbXQogICAgZm9yIHAgaW4gUFJPWFlfUEFUSFM6CiAg
ICAgICAgc3QsIGhkcnMsIF8sIF8gPSB0bHNfZ2V0KGhvc3QsIHApCiAgICAgICAgaWYgc3QgaXMg
Tm9uZToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBzdCA9PSAxMDEgb3IgaGRycy5n
ZXQoInVwZ3JhZGUiLCAiIikubG93ZXIoKSA9PSAid2Vic29ja2V0IjoKICAgICAgICAgICAgb2Rk
LmFwcGVuZChmIntwfSDihpIgMTAxL1VwZ3JhZGUgKNGP0LLQvdCw0Y8g0YLQvtGH0LrQsCDQv9GA
0L7QutGB0LgpIikKICAgICAgICBlbGlmIHN0ICE9IGN0cmwgYW5kIHN0IG5vdCBpbiAoNDA0LCA0
MDMsIDMwMSwgMzAyKToKICAgICAgICAgICAgb2RkLmFwcGVuZChmIntwfSDihpIge3N0fSAo0LrQ
vtC90YLRgNC+0LvRjCDQtNCw0ZHRgiB7Y3RybH0pIikKICAgIGlmIG5vdCBvZGQ6CiAgICAgICAg
bGluZSgiT0siLCBmItCy0YHQtSDQv9GD0YLQuCDQstC10LTRg9GCINGB0LXQsdGPINC+0LTQuNC9
0LDQutC+0LLQviAo0LrQvtC90YLRgNC+0LvRjD17Y3RybH0pIOKAlCDRgtGA0LDQvdGB0L/QvtGA
0YIg0L3QtSDQstGL0LTQtdC70Y/QtdGC0YHRjyIpCiAgICBlbHNlOgogICAgICAgIGZvciBvIGlu
IG9kZDoKICAgICAgICAgICAgbGluZSgiISIsIG8pCiAgICAgICAgbGluZSgiaSIsICLQstGL0LTQ
tdC70Y/RjtGJ0LjQtdGB0Y8g0L/Rg9GC0Lgg4oCUINC/0L7RgtC10L3RhtC40LDQu9GM0L3Ri9C5
INGE0LjQvdCz0LXRgNC/0YDQuNC90YI7INC70YPRh9GI0LUg0L/RgNGP0YLQsNGC0Ywg0LfQsCDQ
vtCx0YnQuNC5IGZhbGxiYWNrIikKCgpkZWYgY2hlY2tfd3MoaG9zdCk6CiAgICBoZWFkKCI1LiBX
ZWJTb2NrZXQtdXBncmFkZSIpCiAgICBoaXQgPSBbXQogICAgZm9yIHAgaW4gKCIvIiwgIi93cyIs
ICIvd3NuZyIpOgogICAgICAgIHN0LCBfLCBfLCBfID0gdGxzX2dldChob3N0LCBwLCB7IlVwZ3Jh
ZGUiOiAid2Vic29ja2V0IiwgIkNvbm5lY3Rpb24iOiAiVXBncmFkZSIsCiAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAiU2VjLVdlYlNvY2tldC1WZXJzaW9uIjogIjEzIiwK
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJTZWMtV2ViU29ja2V0LUtl
eSI6ICJ4M0pKSE1iREwxRXpMa2g5R0JoWER3PT0ifSkKICAgICAgICBpZiBzdCA9PSAxMDE6CiAg
ICAgICAgICAgIGhpdC5hcHBlbmQocCkKICAgIGlmIGhpdDoKICAgICAgICBsaW5lKCIhIiwgZiLR
gdC10YDQstC10YAg0L/RgNC40L3QuNC80LDQtdGCIFdTLXVwZ3JhZGUg0L3QsDogeycsICcuam9p
bihoaXQpfSDigJQg0LjQvdC00LjQutCw0YLQvtGAINGC0YDQsNC90YHQv9C+0YDRgtCwIikKICAg
IGVsc2U6CiAgICAgICAgbGluZSgiT0siLCAiV1MtdXBncmFkZSDQvdCw0YDRg9C20YMg0L3QtSDQ
stC40LTQtdC9IikKCgpkZWYgY2hlY2tfYWxwbihob3N0KToKICAgIGhlYWQoIjYuIEhUVFAvMiAo
QUxQTikiKQogICAgXywgXywgXywgYWxwbiA9IHRsc19nZXQoaG9zdCwgIi8iKQogICAgaWYgYWxw
biA9PSAiaDIiOgogICAgICAgIGxpbmUoIk9LIiwgItGB0L7Qs9C70LDRgdC+0LLQsNC9IGgyIOKA
lCDQutCw0Log0YMg0YHQvtCy0YDQtdC80LXQvdC90L7Qs9C+INGB0LDQudGC0LAiKQogICAgZWxp
ZiBhbHBuOgogICAgICAgIGxpbmUoImkiLCBmIkFMUE49e2FscG59ICjQsdC10LcgaDIg4oCUINGD
INC90LDRgdGC0L7Rj9GJ0LjRhSDRgdCw0LnRgtC+0LIgaDIg0L7QsdGL0YfQvdC+INC10YHRgtGM
KSIpCiAgICBlbHNlOgogICAgICAgIGxpbmUoImkiLCAiQUxQTiDQvdC1INGB0L7Qs9C70LDRgdC+
0LLQsNC9IikKCgpkZWYgY2hlY2tfcmRucyhpcCk6CiAgICBoZWFkKCI3LiDQntCx0YDQsNGC0L3R
i9C5IEROUyAoUFRSKSIpCiAgICB0cnk6CiAgICAgICAgcHRyID0gc29ja2V0LmdldGhvc3RieWFk
ZHIoaXApWzBdCiAgICAgICAgaWYgcmUuc2VhcmNoKHIiKHZwbnxwcm94eXx0b3J8eHVpfG1hcnp8
aGlkZCkiLCBwdHIsIHJlLkkpOgogICAgICAgICAgICBsaW5lKCIhIiwgZiJQVFIg0L/QvtC00L7Q
t9GA0LjRgtC10LvQtdC9OiB7cHRyfSIpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgbGluZSgi
aSIsIGYiUFRSOiB7cHRyfSIpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIGxpbmUoIk9L
IiwgIlBUUiDQvdC1INC30LDQtNCw0L0gKNC90LXQudGC0YDQsNC70YzQvdC+KSIpCgoKZGVmIHBy
b2JlKHRhcmdldCk6CiAgICBpcCA9IHJlc29sdmUodGFyZ2V0KSBvciB0YXJnZXQKICAgIHByaW50
KGMoImgiLCBmIlxu4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIHt0YXJnZXR9ICAoe2lwfSkg4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQIikpCiAgICBjaGVja19wb3J0cyhpcCkKICAgIGNoZWNrX2h0dHAodGFyZ2V0KQog
ICAgY2hlY2tfY2VydCh0YXJnZXQpCiAgICBjaGVja19wYXRocyh0YXJnZXQpCiAgICBjaGVja193
cyh0YXJnZXQpCiAgICBjaGVja19hbHBuKHRhcmdldCkKICAgIGNoZWNrX3JkbnMoaXApCgoKZGVm
IG1haW4oKToKICAgIHRhcmdldHMgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCB0YXJnZXRzOgog
ICAgICAgIHByaW50KCLQmNGB0L/QvtC70YzQt9C+0LLQsNC90LjQtTogcHl0aG9uMyB2cG4tcHJv
YmUucHkgPNC00L7QvNC10L0t0LjQu9C4LWlwPiBb0LXRidGRLi4uXSIpCiAgICAgICAgc3lzLmV4
aXQoMikKICAgIHByaW50KGMoImgiLCAidnBuLXByb2JlIOKAlCDQstC30LPQu9GP0LQg0YHQvdCw
0YDRg9C20LguIFtPS10g0L3QvtGA0LzQsCDCtyBbaV0g0L7QttC40LTQsNC10LzQviDQtNC70Y8g
c2VsZnN0ZWFsIMK3IFshXSDRgNCw0LfQvtCx0YDQsNGC0YzRgdGPIikpCiAgICBmb3IgdCBpbiB0
YXJnZXRzOgogICAgICAgIHByb2JlKHQpCiAgICBwcmludCgpCgoKaWYgX19uYW1lX18gPT0gIl9f
bWFpbl9fIjoKICAgIG1haW4oKQo=
__B64__
}
case "${1:-menu}" in
  wizard)  wizard ;;
  config)  load; for v in "${VARS[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done ;;
  render)  load; render "${2:?укажи имя шаблона}" ;;
  extract) ensure_templates; d="${2:?укажи каталог}"; mkdir -p "$d"; cp "$TPL_DIR"/* "$d"/; say "Шаблоны распакованы в $d" ;;
  probe)   if [ "$#" -gt 1 ]; then do_probe "${@:2}"; else load; do_probe "$MAIN_DOMAIN" "$RELAY_DOMAIN"; fi ;;
  update)  do_update ;;
  backup)  do_backup ;;
  restore) do_restore "${2:-}" || true ;;
  info)    do_info ;;
  reset)   do_reset ;;
  rotate)  do_rotate ;;
  stages)  do_stages ;;
  run)     run "${2:-}" ;;
  exit|moonlight) run exit ;;
  relay|sunshine) run relay ;;
  sunshine-node)  run sunshine-node ;;
  menu|"")
    [ -f "$CONF" ] || wizard
    load
    echo; say "Роль: $(c '1;32' "$ROLE") · бренд: $BRAND · домен: $MAIN_DOMAIN"
    echo "  1) Запустить развёртывание по роли ($ROLE)"
    echo "  2) Данные для подключения — панель, WDTT, подписка"
    echo "  3) Перенастроить (wizard)"
    echo "  4) Показать конфиг"
    echo "  5) Проверить серверы снаружи (probe)"
    echo "  6) Обновить компоненты (update)"
    echo "  7) Бэкап конфигов и БД (backup)"
    echo "  b) Восстановить из бэкапа (restore)"
    echo "  8) Сменить пароли (rotate)"
    echo "  9) Список фаз деплоя (stages)"
    echo "  r) Полный сброс — снести стек начисто (reset)"
    echo "  0) Выход"
    read -rp "  Выбор [1]: " ch || true
    case "${ch:-1}" in
      1) run "$ROLE" ;; 2) do_info ;; 3) wizard ;;
      4) for v in "${VARS[@]}"; do printf '%s=%s\n' "$v" "${!v:-}"; done ;;
      5) load; do_probe "$MAIN_DOMAIN" "$RELAY_DOMAIN" ;;
      6) do_update ;;
      7) do_backup ;;
      b|B) do_restore || true ;;
      8) do_rotate ;;
      9) do_stages ;;
      r|R) do_reset ;;
      *) exit 0 ;;
    esac ;;
  *) die "неизвестная команда: $1" ;;
esac
