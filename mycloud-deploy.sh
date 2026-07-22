#!/usr/bin/env bash
# =============================================================================
#  mycloud-deploy.sh — ЕДИНЫЙ САМОДОСТАТОЧНЫЙ установщик (обезличенный стек)
#  Один файл: 16 шаблонов зашиты внутрь (base64). Кидаешь на VPS и:
#      sudo bash mycloud-deploy.sh
#  Спросит данные по SSH -> deploy.conf, распакует шаблоны, отрендерит твоими
#  значениями и развернёт по фазам, с паузами на ручные шаги панели.
#  Подкоманды: wizard | config | render <имя> | run <фаза|all> | extract <каталог> | probe [хост…] | verify
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
    echo "── WDTT (мобильный TURN-канал, форк ildarmaga/wdtt) ──"
    echo "  Сервер:  $EXIT_IP   DTLS: 56000/udp · WG: 56001/udp · CSQTT: 46000/udp"
    echo "  Пароль:  ${wdtt_pass:-<см. $CRED>}"
    echo "  iOS:  github.com/anton48/vk-turn-proxy-ios → режим SRTP-WRAP-A (или wdtt://-ссылка из панели)"
    echo "  Панель WDTT (не публична): ssh -L 2860:127.0.0.1:2860 root@$EXIT_IP  →  http://localhost:2860/wdtt/"
    echo "           логин: $(grep -E '^\s*wdtt-panel:' "$CRED" 2>/dev/null | sed 's/^[^(]*(//; s/)$//' || echo 'admin / wdtt — смени')"
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

# do_verify — сверяет ЖЕЛАЕМОЕ состояние (панель: node.activeInbounds,
# squad.inbounds, securityLayer у hosts) с ФАКТИЧЕСКИМ (что реально видит
# живой Xray-процесс в контейнере ноды через internal-сокет). Находит drift
# без ручной диагностики через docker logs/API одноразовыми curl-командами —
# именно так пришлось искать все баги XHTTP/relay в этом проекте.
# Запускать НА ТОМ сервере, чью ноду проверяешь (Moonlight — для exit,
# Sunshine — для relay/sunshine-node).
do_verify(){
  local -   # сохраняет set -e/pipefail и авто-восстанавливает при выходе из функции (bash 4.4+)
  set +e; set +o pipefail   # ниже полно "grep && die" / "cmd && break" — под set -e они бы падали на первом же непустом совпадении
  load 2>/dev/null || die "Нет конфига — деплой ещё не делался"
  local B="/opt/$SLUG"
  local CRED="$B/credentials.txt"
  [ -f "$CRED" ] || die "нет $CRED — деплой не завершён"
  local ADMIN_PASS; ADMIN_PASS="$(grep -E '^\s*pass:' "$CRED" | awk '{print $2}' | head -1)"
  [ -n "$ADMIN_PASS" ] || die "не нашёл пароль в $CRED"

  local PANEL_DOMAIN NODE_NAME SQUAD_NAME="${SQUAD_NAME:-main}"
  if [ "$ROLE" = exit ] || [ "$ROLE" = moonlight ]; then
    PANEL_DOMAIN="$MAIN_DOMAIN"; NODE_NAME="$EXIT_NAME"
  else
    # на конфиге relay/sunshine-node RELAY_DOMAIN хранит домен Moonlight
    # (так его пишет setup-relay-ssh.sh) — панель всегда там
    PANEL_DOMAIN="$RELAY_DOMAIN"; NODE_NAME="$RELAY_NAME"
  fi
  local FAIL=0
  ok(){ echo "  $(c '1;32' '✓') $*"; }
  warn(){ echo "  $(c '1;33' '!') $*"; FAIL=1; }

  say "Верификация: нода '$NODE_NAME', squad '$SQUAD_NAME' (роль: $ROLE)"

  local API_BASE RESOLVE_ARGS=()
  status_ok(){ local code; code="$(curl -sS -k -o /dev/null "${RESOLVE_ARGS[@]}" -w '%{http_code}' "${API_BASE}/auth/status" 2>/dev/null)"; [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null; }
  API_BASE="https://localhost:8081/api"; RESOLVE_ARGS=()
  if ! status_ok; then
    local p
    for p in 443 8443; do
      API_BASE="https://${PANEL_DOMAIN}:${p}/api"; RESOLVE_ARGS=(--resolve "${PANEL_DOMAIN}:${p}:127.0.0.1")
      status_ok && break
    done
  fi
  status_ok || die "панель не отвечает (ни localhost:8081, ни $PANEL_DOMAIN:443/8443)"

  local TMP; TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' RETURN

  curl -sS -k "${RESOLVE_ARGS[@]}" -X POST "${API_BASE}/auth/login" \
    -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser' \
    -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" -o "$TMP/login.json"
  local TOKEN; TOKEN="$(python3 -c "import json;print(json.load(open('$TMP/login.json')).get('response',{}).get('accessToken',''))" 2>/dev/null)"
  [ -n "$TOKEN" ] || die "не получил токен от панели"

  api_get(){ curl -sS -k "${RESOLVE_ARGS[@]}" "${API_BASE}$1" -H "Authorization: Bearer $TOKEN" -H 'X-Remnawave-Client-Type: browser'; }

  # ── 1. activeInbounds ноды в панели ──────────────────────────────────────
  api_get "/nodes" > "$TMP/nodes.json"
  python3 - "$TMP/nodes.json" "$NODE_NAME" "$TMP/active_tags.json" <<'PY'
import sys, json
nodes_f, name, out_f = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(nodes_f))
arr = d.get("response") if isinstance(d, dict) else d
if isinstance(arr, dict): arr = arr.get("nodes") or arr.get("data") or []
node = next((n for n in (arr or []) if isinstance(n, dict) and n.get("name") == name), None)
if not node:
    json.dump({"__error__": "not found"}, open(out_f, "w")); sys.exit(0)
ai = (node.get("configProfile") or {}).get("activeInbounds") or []
tags = sorted(x.get("tag") for x in ai if isinstance(x, dict) and x.get("tag"))
json.dump(tags, open(out_f, "w"))
PY
  grep -q '__error__' "$TMP/active_tags.json" 2>/dev/null && die "нода '$NODE_NAME' не найдена в панели"
  local ACTIVE_TAGS; ACTIVE_TAGS="$(cat "$TMP/active_tags.json")"
  ok "activeInbounds ноды в панели: $ACTIVE_TAGS"

  # ── 2. squad.inbounds ─────────────────────────────────────────────────────
  api_get "/internal-squads" > "$TMP/squads.json"
  python3 - "$TMP/squads.json" "$SQUAD_NAME" <<'PY' > "$TMP/squad_uuid.txt"
import sys, json
d = json.load(open(sys.argv[1]))
arr = d.get("response", {}).get("internalSquads") or []
print(next((s.get("uuid") for s in arr if s.get("name") == sys.argv[2]), ""))
PY
  local SQUAD_UUID; SQUAD_UUID="$(cat "$TMP/squad_uuid.txt")"
  [ -n "$SQUAD_UUID" ] || die "squad '$SQUAD_NAME' не найден"

  api_get "/internal-squads/$SQUAD_UUID" > "$TMP/squad.json"
  python3 - "$TMP/squad.json" <<'PY' > "$TMP/squad_tags.json"
import sys, json
d = json.load(open(sys.argv[1]))
r = d.get("response", d)
tags = sorted(x.get("tag") for x in (r.get("inbounds") or []) if x.get("tag"))
json.dump(tags, sys.stdout)
PY
  local SQUAD_TAGS; SQUAD_TAGS="$(cat "$TMP/squad_tags.json")"

  python3 - "$TMP/active_tags.json" "$TMP/squad_tags.json" <<'PY' > "$TMP/missing_squad.json"
import sys, json
a = set(json.load(open(sys.argv[1])))
b = set(json.load(open(sys.argv[2])))
json.dump(sorted(a - b), sys.stdout)
PY
  local MISSING_SQUAD; MISSING_SQUAD="$(cat "$TMP/missing_squad.json")"
  if [ "$MISSING_SQUAD" = "[]" ]; then
    ok "все активные инбаунды ноды присутствуют в squad"
  else
    warn "инбаунды есть у ноды, но ОТСУТСТВУЮТ в squad: $MISSING_SQUAD — трафик по ним не пойдёт клиентам (чинит: --from provision.sh / provision-relay.sh)"
  fi

  # ── 3. живой конфиг Xray в контейнере ноды ───────────────────────────────
  say "Живой конфиг Xray в контейнере ноды (internal-сокет)"
  docker exec -i remnanode python3 - <<'PY' > "$TMP/live_tags.json" 2>/dev/null || echo '[]' > "$TMP/live_tags.json"
import json, os, glob, http.client, socket, sys
socks = glob.glob('/run/remnawave-internal-*.sock')
if not socks: json.dump([], sys.stdout); sys.exit(0)
pid = (os.popen('pgrep rw-core').read().strip() or '0').split()
pid = pid[0] if pid else '0'
tok = ''
try:
    for p in open('/proc/%s/cmdline' % pid).read().split('\x00'):
        if 'token=' in p: tok = p.split('token=', 1)[1]; break
except Exception:
    json.dump([], sys.stdout); sys.exit(0)
class U(http.client.HTTPConnection):
    def __init__(s, p): super().__init__('localhost'); s.p = p
    def connect(s):
        so = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); so.connect(s.p); s.sock = so
try:
    c = U(socks[0]); c.request('GET', '/internal/get-config?token=' + tok)
    cfg = json.loads(c.getresponse().read())
except Exception:
    json.dump([], sys.stdout); sys.exit(0)
json.dump(sorted(i.get('tag') for i in cfg.get('inbounds', []) if i.get('tag')), sys.stdout)
PY
  local LIVE_TAGS; LIVE_TAGS="$(cat "$TMP/live_tags.json")"
  ok "реально поднято в Xray: $LIVE_TAGS"

  python3 - "$TMP/active_tags.json" "$TMP/live_tags.json" <<'PY' > "$TMP/missing_live.json"
import sys, json
a = set(json.load(open(sys.argv[1])))
b = set(json.load(open(sys.argv[2])))
json.dump(sorted(a - b), sys.stdout)
PY
  local MISSING_LIVE; MISSING_LIVE="$(cat "$TMP/missing_live.json")"
  if [ "$MISSING_LIVE" = "[]" ]; then
    ok "все activeInbounds панели реально подняты в живом Xray"
  else
    warn "инбаунды активны в панели, но НЕ подняты в живом Xray: $MISSING_LIVE — попробуй: docker restart remnanode, либо kick-node.sh"
  fi

  # ── 4. hosts: securityLayer заполнен? (типичный симптом опечатки в поле) ─
  say "Hosts — заполнен ли securityLayer"
  api_get "/hosts" > "$TMP/hosts.json"
  python3 - "$TMP/hosts.json" <<'PY' > "$TMP/bad_hosts.json"
import sys, json
d = json.load(open(sys.argv[1]))
r = d.get("response", d)
arr = r.get("hosts", r) if isinstance(r, dict) else r
bad = [h.get("remark") for h in (arr or []) if isinstance(h, dict) and not h.get("securityLayer")]
json.dump(bad, sys.stdout)
PY
  local BAD_HOSTS; BAD_HOSTS="$(cat "$TMP/bad_hosts.json")"
  if [ "$BAD_HOSTS" = "[]" ]; then
    ok "у всех hosts заполнен securityLayer"
  else
    warn "hosts БЕЗ securityLayer (API молча подставляет DEFAULT/REALITY вместо задуманного): $BAD_HOSTS"
  fi

  echo
  if [ "$FAIL" = 0 ]; then
    echo "$(c '1;32' '════ ВЕРИФИКАЦИЯ ПРОШЛА — состояние панели и живого Xray совпадают ════')"
  else
    echo "$(c '1;31' '════ НАЙДЕНЫ РАСХОЖДЕНИЯ — см. предупреждения выше ════')"
    return 1
  fi
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
      _s "wdtt-build.sh"        "Мобильный TURN-канал (аварийный VPN, форк ildarmaga/wdtt: панель+CSQTT), UDP 56000/56001/46000"
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

  # WDTT (форк ildarmaga/wdtt): пароль живёт в /etc/wdtt/panel.db — применяем его
  # повторным прогоном фазы wdtt-build.sh (идемпотентна, передаёт -p установщику)
  grep -q 'wdtt-password:' "$CRED" 2>/dev/null \
    && sed -i "s|^\s*wdtt-password: .*|wdtt-password: $new_wdtt|" "$CRED" \
    || printf 'wdtt-password: %s\n' "$new_wdtt" >> "$CRED"
  WDTT_PASS="$new_wdtt"
  grep -q '^WDTT_PASS=' "$CONF" 2>/dev/null \
    && sed -i "s|^WDTT_PASS=.*|WDTT_PASS=$(printf '%q' "$new_wdtt")|" "$CONF" \
    || printf 'WDTT_PASS=%q\n' "$new_wdtt" >> "$CONF"
  if [ -x /usr/local/bin/wdtt-app ]; then
    say "WDTT: применяю новый пароль (фаза wdtt-build.sh)…"
    run wdtt-build.sh || say "ПРЕДУПРЕЖДЕНИЕ: фаза wdtt-build.sh завершилась с ошибкой — см. /opt/$SLUG/wdtt/install-*.log"
  else
    say "ПРЕДУПРЕЖДЕНИЕ: WDTT-панель не найдена (/usr/local/bin/wdtt-app) — пароль сохранён в $CRED и $CONF, применится при: run wdtt-build.sh"
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
  ACME_EMAIL="$ACME_EMAIL" SSH_PORT="$SSH_PORT" GEO_BLOCK="$GEO_BLOCK" PQ="$PQ" HARDEN="$HARDEN" TEST_SUB_UUID="$TEST_SUB_UUID" ACME_STAGING_LINE="${ACME_STAGING_LINE:-}" \
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
PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbAoKRE9NQUlOPSJAQE1BSU5f
RE9NQUlOQEAiCkFDTUVfRU1BSUw9ImFkbWluQEBAU0xVR0BALmNvbSIKV1NfUEFUSD0iL3dzbmci
ClhIVFRQX1BBVEg9Ii94aCIKREVDT1k9Ii9vcHQvQEBTTFVHQEAvZGVjb3kiCkNBRERZRklMRT0i
L29wdC9AQFNMVUdAQC9jYWRkeS9DYWRkeWZpbGUiCkNBRERZX0NUUj0iQEBTTFVHQEAtY2FkZHki
CnRzPSQoZGF0ZSArJVklbSVkLSVIJU0lUykKClsgLWQgL29wdC9AQFNMVUdAQC9jYWRkeSBdIHx8
IHsgZWNobyAi0J3QtdGCIC9vcHQvQEBTTFVHQEAvY2FkZHkg4oCUINGB0L3QsNGH0LDQu9CwIGRl
cGxveS1zdW5zaGluZS5zaCI7IGV4aXQgMTsgfQoKZWNobyAiPT0gWzEvNV0g0JHQsNC30LAg0LTQ
tdC60L7RjyAobXlmYWtlc2l0ZTogZmF2aWNvbi9waHAvcm9ib3RzL1ZFUlNJT04pIC0+ICRERUNP
WSA9PSIKY29tbWFuZCAtdiBnaXQgPi9kZXYvbnVsbCB8fCB7IGFwdC1nZXQgdXBkYXRlIC15ID4v
ZGV2L251bGwgJiYgYXB0LWdldCBpbnN0YWxsIC15IGdpdCA+L2Rldi9udWxsOyB9CmlmIFsgLWQg
IiRERUNPWS8uZ2l0IiBdOyB0aGVuIGdpdCAtQyAiJERFQ09ZIiBwdWxsIC0tZmYtb25seSB8fCB0
cnVlCmVsc2Ugcm0gLXJmICIkREVDT1kiOyBnaXQgY2xvbmUgLS1kZXB0aCAxIGh0dHBzOi8vZ2l0
aHViLmNvbS9pcXViaWsvbXlmYWtlc2l0ZS5naXQgIiRERUNPWSI7IGZpCm1rZGlyIC1wICIkREVD
T1kvZGF0YS9hc3NldHMiIC92YXIvbG9nL215ZmFrZXNpdGUKCmVjaG8gIj09IFsyLzVdINCa0LvQ
sNC00YMg0L/QvtCy0LXRgNGFINGB0YLRgNCw0L3QuNGG0YsgQEBCUkFOREBAIENsb3VkLCDQsNGB
0YHQtdGC0YssIG5naW54LmNvbmYsIGNvbXBvc2UgPT0iCmNhdCA+ICIkREVDT1kvZGF0YS9uZ2lu
eC5jb25mIiA8PCdERUNPWV9OR0lOWCcKbGltaXRfcmVxX3pvbmUgJGJpbmFyeV9yZW1vdGVfYWRk
ciB6b25lPWF1dGhfbGltaXQ6MTBtIHJhdGU9M3IvbTsKbGltaXRfcmVxX3N0YXR1cyA0Mjk7Cgpt
YXAgJHJlcXVlc3RfaWQgJGF1dGhfZXJyb3JfbXNnIHsKICAgIGRlZmF1bHQgICAgICAgIkluY29y
cmVjdCBlbWFpbCBvciBwYXNzd29yZC4gUGxlYXNlIHRyeSBhZ2Fpbi4iOwogICAgIn5eWzAtM10i
ICAgICAiQWNjb3VudCBub3QgZm91bmQuIjsKICAgICJ+Xls0LTddIiAgICAgIkluY29ycmVjdCBw
YXNzd29yZC4iOwogICAgIn5eWzgtYl0iICAgICAiQWNjb3VudCB0ZW1wb3JhcmlseSBsb2NrZWQu
IFRyeSBhZ2FpbiBsYXRlci4iOwogICAgIn5eW2MtZl0iICAgICAiVG9vIG1hbnkgYXR0ZW1wdHMu
IFBsZWFzZSB3YWl0IGFuZCB0cnkgYWdhaW4uIjsKfQoKc2VydmVyIHsKICAgIGxpc3RlbiA4MDsK
ICAgIGxpc3RlbiBbOjpdOjgwOwogICAgc2VydmVyX25hbWUgXzsKCiAgICBhZGRfaGVhZGVyIFgt
Q29udGVudC1UeXBlLU9wdGlvbnMgIm5vc25pZmYiIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgWC1G
cmFtZS1PcHRpb25zICJTQU1FT1JJR0lOIiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFgtUGVybWl0
dGVkLUNyb3NzLURvbWFpbi1Qb2xpY2llcyAibm9uZSIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBY
LVJvYm90cy1UYWcgIm5vaW5kZXgsIG5vZm9sbG93IiBhbHdheXM7CiAgICBhZGRfaGVhZGVyIFgt
WFNTLVByb3RlY3Rpb24gIjE7IG1vZGU9YmxvY2siIGFsd2F5czsKICAgIGFkZF9oZWFkZXIgUmVm
ZXJyZXItUG9saWN5ICJuby1yZWZlcnJlciIgYWx3YXlzOwogICAgYWRkX2hlYWRlciBTdHJpY3Qt
VHJhbnNwb3J0LVNlY3VyaXR5ICJtYXgtYWdlPTE1NTUyMDAwOyBpbmNsdWRlU3ViRG9tYWlucyIg
YWx3YXlzOwogICAgYWRkX2hlYWRlciBDb250ZW50LVNlY3VyaXR5LVBvbGljeSAiZGVmYXVsdC1z
cmMgJ3NlbGYnOyBzY3JpcHQtc3JjICdzZWxmJzsgc3R5bGUtc3JjICdzZWxmJyAndW5zYWZlLWlu
bGluZSc7IGltZy1zcmMgJ3NlbGYnIGRhdGE6OyBjb25uZWN0LXNyYyAnc2VsZic7IGZvbnQtc3Jj
ICdzZWxmJzsgb2JqZWN0LXNyYyAnbm9uZSc7IGZyYW1lLWFuY2VzdG9ycyAnbm9uZSc7IGJhc2Ut
dXJpICdzZWxmJzsiIGFsd2F5czsKCiAgICBzZXJ2ZXJfdG9rZW5zIG9mZjsKICAgIGFjY2Vzc19s
b2cgb2ZmOwoKICAgICMg0KHRgtCw0YLQuNC60LAg0L/RgNC40LvQvtC20LXQvdC40Y8g4oCUINC+
0YLQtNCw0ZHQvCDQvdCw0L/RgNGP0LzRg9GOINGBINC00LvQuNC90L3Ri9C8INC60Y3RiNC+0Lws
INC60LDQuiDQvdCw0YHRgtC+0Y/RidC40Lkg0LHQuNC70LQKICAgIGxvY2F0aW9uIF5+IC9hc3Nl
dHMvIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBleHBpcmVz
IDMwZDsKICAgICAgICBhZGRfaGVhZGVyIENhY2hlLUNvbnRyb2wgInB1YmxpYywgaW1tdXRhYmxl
IiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBYLUNvbnRlbnQtVHlwZS1PcHRpb25zICJub3Nu
aWZmIiBhbHdheXM7CiAgICAgICAgdHJ5X2ZpbGVzICR1cmkgPTQwNDsKICAgIH0KCiAgICBsb2Nh
dGlvbiAvIHsKICAgICAgICByb290IC91c3Ivc2hhcmUvbmdpbngvaHRtbDsKICAgICAgICBpbmRl
eCBpbmRleC5odG1sOwogICAgICAgIHRyeV9maWxlcyAkdXJpICR1cmkuaHRtbCAkdXJpLyAvaW5k
ZXguaHRtbDsKICAgIH0KCiAgICBsb2NhdGlvbiB+IF4vYXBpL3N0YXR1cyQgewogICAgICAgIGRl
ZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1Qb3dlcmVk
LUJ5ICJAQFNMVUdAQC1hcGkiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFgtUmVxdWVzdC1J
ZCAiJHJlcXVlc3RfaWQiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFgtQ29udGVudC1UeXBl
LU9wdGlvbnMgIm5vc25pZmYiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFJlZmVycmVyLVBv
bGljeSAibm8tcmVmZXJyZXIiIGFsd2F5czsKICAgICAgICByZXR1cm4gMjAwICd7Im9ubGluZSI6
dHJ1ZSwibWFpbnRlbmFuY2UiOmZhbHNlLCJ2ZXJzaW9uIjoiMy4yLjciLCJidWlsZCI6IjIwMjUu
MTEuMDIiLCJwcm9kdWN0IjoiQEBCUkFOREBAIENsb3VkIiwiYXBpIjoiMS4wIn0nOwogICAgfQoK
ICAgIGVycm9yX3BhZ2UgNDI5ID0gQHJhdGVfbGltaXRlZDsKICAgIGxvY2F0aW9uIEByYXRlX2xp
bWl0ZWQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFk
ZF9oZWFkZXIgUmV0cnktQWZ0ZXIgIjIwIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDQyOSAneyJz
dGF0dXMiOiJlcnJvciIsIm1lc3NhZ2UiOiJUb28gbWFueSByZXF1ZXN0cy4gVHJ5IGFnYWluIGlu
IDIwIHNlY29uZHMuIn0nOwogICAgfQoKICAgIGxvY2F0aW9uIH4gXi9hcGkvYXV0aCQgewogICAg
ICAgIGxpbWl0X3JlcSB6b25lPWF1dGhfbGltaXQgYnVyc3Q9MiBub2RlbGF5OwogICAgICAgIGFj
Y2Vzc19sb2cgL3Zhci9sb2cvbXlmYWtlc2l0ZS9hY2Nlc3MubG9nIGNvbWJpbmVkOwogICAgICAg
IGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1
ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIGFkZF9oZWFkZXIgU2V0LUNvb2tp
ZSAiYWJfc2Vzc2lvbj1leUpoYkdjaU9pSklVekkxTmlKOS4kcmVxdWVzdF9pZC5zaWc7IFBhdGg9
LzsgSHR0cE9ubHk7IFNlY3VyZTsgU2FtZVNpdGU9U3RyaWN0IiBhbHdheXM7CiAgICAgICAgYWRk
X2hlYWRlciBTZXQtQ29va2llICJfX0hvc3QtYWJfcHJpdmFjeT1hY2s7IFBhdGg9LzsgU2VjdXJl
OyBTYW1lU2l0ZT1TdHJpY3QiIGFsd2F5czsKICAgICAgICBhZGRfaGVhZGVyIFJlZmVycmVyLVBv
bGljeSAibm8tcmVmZXJyZXIiIGFsd2F5czsKICAgICAgICByZXR1cm4gNDAxICd7InN0YXR1cyI6
ImVycm9yIiwibWVzc2FnZSI6IiRhdXRoX2Vycm9yX21zZyJ9JzsKICAgIH0KCiAgICBsb2NhdGlv
biB+IF4vYXBpL3JlZ2lzdGVyJCB7CiAgICAgICAgbGltaXRfcmVxIHpvbmU9YXV0aF9saW1pdCBi
dXJzdD0yIG5vZGVsYXk7CiAgICAgICAgZGVmYXVsdF90eXBlIGFwcGxpY2F0aW9uL2pzb247CiAg
ICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQgIiRyZXF1ZXN0X2lkIiBhbHdheXM7CiAgICAg
ICAgYWRkX2hlYWRlciBSZWZlcnJlci1Qb2xpY3kgIm5vLXJlZmVycmVyIiBhbHdheXM7CiAgICAg
ICAgcmV0dXJuIDIwMCAneyJzdGF0dXMiOiJvayIsIm1lc3NhZ2UiOiJDaGVjayB5b3VyIGluYm94
IOKAlCB3ZSBzZW50IGEgdmVyaWZpY2F0aW9uIGxpbmsgdG8gY29uZmlybSB5b3VyIGVtYWlsLiJ9
JzsKICAgIH0KCiAgICBsb2NhdGlvbiB+IF4vYXBpL3Jlc2V0JCB7CiAgICAgICAgbGltaXRfcmVx
IHpvbmU9YXV0aF9saW1pdCBidXJzdD0yIG5vZGVsYXk7CiAgICAgICAgZGVmYXVsdF90eXBlIGFw
cGxpY2F0aW9uL2pzb247CiAgICAgICAgYWRkX2hlYWRlciBYLVJlcXVlc3QtSWQgIiRyZXF1ZXN0
X2lkIiBhbHdheXM7CiAgICAgICAgYWRkX2hlYWRlciBSZWZlcnJlci1Qb2xpY3kgIm5vLXJlZmVy
cmVyIiBhbHdheXM7CiAgICAgICAgcmV0dXJuIDIwMCAneyJzdGF0dXMiOiJvayIsIm1lc3NhZ2Ui
OiJJZiBhbiBhY2NvdW50IGV4aXN0cyBmb3IgdGhhdCBlbWFpbCwgd2UganVzdCBzZW50IHJlc2V0
IGluc3RydWN0aW9ucy4ifSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS9maWxlcygvLiop
PyQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9o
ZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIHJldHVybiA0
MDEgJ3sic3RhdHVzIjoiZXJyb3IiLCJtZXNzYWdlIjoiQXV0aGVudGljYXRpb24gcmVxdWlyZWQi
fSc7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL2FwaS91c2VycygvLiopPyQgewogICAgICAgIGRl
ZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0
LUlkICIkcmVxdWVzdF9pZCIgYWx3YXlzOwogICAgICAgIHJldHVybiA0MDEgJ3sic3RhdHVzIjoi
ZXJyb3IiLCJtZXNzYWdlIjoiQXV0aGVudGljYXRpb24gcmVxdWlyZWQifSc7CiAgICB9CgogICAg
bG9jYXRpb24gfiBeL2FwaS9zZXR0aW5ncyQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNh
dGlvbi9qc29uOwogICAgICAgIGFkZF9oZWFkZXIgWC1SZXF1ZXN0LUlkICIkcmVxdWVzdF9pZCIg
YWx3YXlzOwogICAgICAgIHJldHVybiAyMDAgJ3sic3RhdHVzIjoib2siLCJsYW5nIjoiZW4iLCJ0
aGVtZSI6ImF1dG8iLCJub3RpZmljYXRpb25zIjp0cnVlLCJ0d29fZmFjdG9yIjpmYWxzZSwic3Rv
cmFnZSI6eyJ1c2VkIjo0ODkyMzEwMDAwLCJ0b3RhbCI6MjE0NzQ4MzY0ODB9LCJsYXN0X2xvZ2lu
IjoiMjAyNi0wNC0xMFQxODozMjowN1oifSc7CiAgICB9CgogICAgbG9jYXRpb24gPSAvcm9ib3Rz
LnR4dCB7CiAgICAgICAgZGVmYXVsdF90eXBlIHRleHQvcGxhaW47CiAgICAgICAgcmV0dXJuIDIw
MCAnVXNlci1hZ2VudDogKgpBbGxvdzogLwpEaXNhbGxvdzogL2FwaS8KRGlzYWxsb3c6IC9hZG1p
bi8KRGlzYWxsb3c6IC9pbnRlcm5hbC8KJzsKICAgIH0KCiAgICBsb2NhdGlvbiA9IC9oZWFydGJl
YXQgewogICAgICAgIGRlZmF1bHRfdHlwZSBhcHBsaWNhdGlvbi9qc29uOwogICAgICAgIHJldHVy
biAyMDAgJ3sib2siOnRydWUsInRzIjokbXNlY30nOwogICAgfQoKICAgIGxvY2F0aW9uID0gLy53
ZWxsLWtub3duL3NlY3VyaXR5LnR4dCB7CiAgICAgICAgZGVmYXVsdF90eXBlIHRleHQvcGxhaW47
CiAgICAgICAgYWRkX2hlYWRlciBBY2Nlc3MtQ29udHJvbC1BbGxvdy1PcmlnaW4gIioiIGFsd2F5
czsKICAgICAgICByZXR1cm4gMjAwICdDb250YWN0OiBtYWlsdG86YWRtaW5AQEBNQUlOX0RPTUFJ
TkBAClByZWZlcnJlZC1MYW5ndWFnZXM6IGVuCkV4cGlyZXM6IDIwMjctMDEtMDFUMDA6MDA6MDBa
Cic7CiAgICB9CgogICAgbG9jYXRpb24gfiBeL1wud2VsbC1rbm93bi8oPyFzZWN1cml0eVwudHh0
KSB7IHJldHVybiA0MDQ7IH0KCiAgICBsb2NhdGlvbiA9IC9mYXZpY29uLmljbyB7CiAgICAgICAg
cm9vdCAvdXNyL3NoYXJlL25naW54L2h0bWw7CiAgICAgICAgZXhwaXJlcyAzMGQ7CiAgICAgICAg
YWRkX2hlYWRlciBDYWNoZS1Db250cm9sICJwdWJsaWMsIGltbXV0YWJsZSIgYWx3YXlzOwogICAg
fQogICAgbG9jYXRpb24gPSAvYXBwbGUtdG91Y2gtaWNvbi5wbmcgewogICAgICAgIHJvb3QgL3Vz
ci9zaGFyZS9uZ2lueC9odG1sOwogICAgICAgIGV4cGlyZXMgMzBkOwogICAgICAgIGFkZF9oZWFk
ZXIgQ2FjaGUtQ29udHJvbCAicHVibGljLCBpbW11dGFibGUiIGFsd2F5czsKICAgIH0KCiAgICBs
b2NhdGlvbiA9IC9sb2ctcm90YXRlLWJ5LXNpemUuc2ggeyByZXR1cm4gNDA0OyB9CiAgICBsb2Nh
dGlvbiA9IC9kYXRhL2xvZy1yb3RhdGUtYnktc2l6ZS5zaCB7IHJldHVybiA0MDQ7IH0KCiAgICBs
b2NhdGlvbiB+IFwucGhwJCB7CiAgICAgICAgcm9vdCAvdXNyL3NoYXJlL25naW54L2h0bWw7CiAg
ICAgICAgZmFzdGNnaV9wYXNzIHBocC1mcG06OTAwMDsKICAgICAgICBmYXN0Y2dpX2luZGV4IGlu
ZGV4LnBocDsKICAgICAgICBmYXN0Y2dpX3BhcmFtIFNDUklQVF9GSUxFTkFNRSAkZG9jdW1lbnRf
cm9vdCRmYXN0Y2dpX3NjcmlwdF9uYW1lOwogICAgICAgIGluY2x1ZGUgZmFzdGNnaV9wYXJhbXM7
CiAgICAgICAgZmFzdGNnaV9oaWRlX2hlYWRlciBYLVBvd2VyZWQtQnk7CiAgICB9CgogICAgbG9j
YXRpb24gfiBeLyg/OlwuaHQuKnxcLmdpdC4qfFwuZW52Lip8ZGF0YS98Y29uZmlnL3xsaWIvfDNy
ZHBhcnR5L3x0ZW1wbGF0ZXMvKSB7IHJldHVybiA0MDQ7IH0KCiAgICBlcnJvcl9wYWdlIDUwMCA1
MDIgNTAzIDUwNCAvNTB4Lmh0bWw7CiAgICBsb2NhdGlvbiA9IC81MHguaHRtbCB7IHJvb3QgL3Vz
ci9zaGFyZS9uZ2lueC9odG1sOyB9Cn0KREVDT1lfTkdJTlgKCmNhdCA+ICIkREVDT1kvZGF0YS9p
bmRleC5odG1sIiA8PCdERUNPWV9JTkRFWCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVu
Ij4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIg
Y29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5h
bWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJl
ZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPkBAQlJBTkRAQCBDbG91ZCDi
gJQgU2VjdXJlIHN0b3JhZ2UgZm9yIHlvdXIgZmlsZXM8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNj
cmlwdGlvbiIgY29udGVudD0iQEBCUkFOREBAIENsb3VkIGtlZXBzIHlvdXIgZG9jdW1lbnRzLCBw
aG90b3MgYW5kIGJhY2t1cHMgZW5jcnlwdGVkIGFuZCBhdmFpbGFibGUgb24gZXZlcnkgZGV2aWNl
LiIgLz4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0i
YXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayBy
ZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJl
bD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8
aGVhZGVyPgogIDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJl
Zj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBh
cmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmls
bD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4
IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwv
c3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9
ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyIgY2xhc3M9ImFjdGl2ZSI+UHJvZHVj
dDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9
Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgog
ICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0
IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0i
L3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8
bWFpbiBjbGFzcz0id3JhcCI+CiAgPGRpdiBjbGFzcz0iZ3JpZCI+CiAgICA8c2VjdGlvbiBjbGFz
cz0icGl0Y2ggcmV2ZWFsIiBpZD0iZmVhdHVyZXMiPgogICAgICA8ZGl2IGNsYXNzPSJleWVicm93
Ij5FbmNyeXB0ZWQgZmlsZSBzdG9yYWdlPC9kaXY+CiAgICAgIDxoMT5Zb3VyIGZpbGVzLCBzYWZl
IGFuZCBpbiBzeW5jIGV2ZXJ5d2hlcmUuPC9oMT4KICAgICAgPHAgY2xhc3M9ImxlZGUiPkBAQlJB
TkRAQCBDbG91ZCBrZWVwcyBkb2N1bWVudHMsIHBob3RvcyBhbmQgYmFja3VwcyBlbmNyeXB0ZWQg
YXQgcmVzdCBhbmQgcmVhZHkgb24gZXZlcnkgZGV2aWNlLiBTaGFyZSBhIGxpbmssIHJlc3RvcmUg
YSB2ZXJzaW9uLCBrZWVwIHdvcmtpbmcgb2ZmbGluZS48L3A+CiAgICAgIDx1bCBjbGFzcz0iZmVh
dCI+CiAgICAgICAgPGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAg
MjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIu
MiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+RW5kLXRvLWVuZCBlbmNyeXB0aW9u
IHdpdGggY2xpZW50LXNpZGUga2V5czwvbGk+CiAgICAgICAgPGxpPjxzdmcgd2lkdGg9IjE4IiBo
ZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVu
dENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9z
dmc+VmVyc2lvbiBoaXN0b3J5IGFuZCAzMC1kYXkgZmlsZSByZWNvdmVyeTwvbGk+CiAgICAgICAg
PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9
Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0i
TTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+RGVza3RvcCwgbW9iaWxlIGFuZCB3ZWIg4oCUIGF1dG9t
YXRpYyBzeW5jPC9saT4KICAgICAgPC91bD4KICAgICAgPGltZyBjbGFzcz0iaGVyby1pbWciIHNy
Yz0iL2Fzc2V0cy9oZXJvLnN2ZyIgYWx0PSJGaWxlcyBzeW5jZWQgdG8gdGhlIGNsb3VkIiB3aWR0
aD0iNDYwIiBoZWlnaHQ9IjMyMCIgLz4KICAgICAgPGRpdiBjbGFzcz0idHJ1c3QiPgogICAgICAg
IDxzdmcgd2lkdGg9IjE2IiBoZWlnaHQ9IjE2IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5v
bmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIiPjxwYXRoIGQ9Ik0xMiAy
MnM4LTQgOC0xMFY1bC04LTMtOCAzdjdjMCA2IDggMTAgOCAxMFoiLz48L3N2Zz4KICAgICAgICBE
YXRhIGNlbnRlcnMgaW4gdGhlIEVVIMK3IDk5LjklIHVwdGltZQogICAgICA8L2Rpdj4KICAgIDwv
c2VjdGlvbj4KCiAgICA8c2VjdGlvbiBjbGFzcz0iYXV0aCByZXZlYWwgZDIiIGlkPSJzaWduaW4i
PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8aDI+U2lnbiBpbjwvaDI+CiAgICAg
ICAgPHAgY2xhc3M9InN1YiI+V2VsY29tZSBiYWNrLiBVc2UgeW91ciBAQEJSQU5EQEAgQ2xvdWQg
YWNjb3VudC48L3A+CiAgICAgICAgPGRpdiBjbGFzcz0ibXNnIiBpZD0ibXNnIiByb2xlPSJhbGVy
dCI+PC9kaXY+CiAgICAgICAgPGZvcm0gaWQ9ImxvZ2luIiBub3ZhbGlkYXRlPgogICAgICAgICAg
PGRpdiBjbGFzcz0iZmllbGQiPgogICAgICAgICAgICA8bGFiZWwgZm9yPSJlbWFpbCI+RW1haWw8
L2xhYmVsPgogICAgICAgICAgICA8aW5wdXQgaWQ9ImVtYWlsIiBuYW1lPSJlbWFpbCIgdHlwZT0i
ZW1haWwiIGF1dG9jb21wbGV0ZT0idXNlcm5hbWUiIHBsYWNlaG9sZGVyPSJ5b3VAZXhhbXBsZS5j
b20iIHJlcXVpcmVkIC8+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZp
ZWxkIj4KICAgICAgICAgICAgPGxhYmVsIGZvcj0icGFzc3dvcmQiPlBhc3N3b3JkPC9sYWJlbD4K
ICAgICAgICAgICAgPGlucHV0IGlkPSJwYXNzd29yZCIgbmFtZT0icGFzc3dvcmQiIHR5cGU9InBh
c3N3b3JkIiBhdXRvY29tcGxldGU9ImN1cnJlbnQtcGFzc3dvcmQiIHBsYWNlaG9sZGVyPSLigKLi
gKLigKLigKLigKLigKLigKLigKIiIHJlcXVpcmVkIC8+CiAgICAgICAgICA8L2Rpdj4KICAgICAg
ICAgIDxkaXYgY2xhc3M9InJvdyI+CiAgICAgICAgICAgIDxsYWJlbCBjbGFzcz0icmVtZW1iZXIi
PjxpbnB1dCB0eXBlPSJjaGVja2JveCIgbmFtZT0icmVtZW1iZXIiIC8+IEtlZXAgbWUgc2lnbmVk
IGluPC9sYWJlbD4KICAgICAgICAgICAgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9yZXNldCI+Rm9y
Z290IHBhc3N3b3JkPzwvYT4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFz
cz0iYnRuIGJsb2NrIiB0eXBlPSJzdWJtaXQiIGlkPSJzdWJtaXQiPlNpZ24gaW48L2J1dHRvbj4K
ICAgICAgICA8L2Zvcm0+CiAgICAgICAgPGRpdiBjbGFzcz0iZGl2aWRlciI+b3I8L2Rpdj4KICAg
ICAgICA8cCBjbGFzcz0iYWx0Ij5OZXcgdG8gQEBCUkFOREBAIENsb3VkPyA8YSBjbGFzcz0ibGlu
ayIgaHJlZj0iL3NpZ251cCI+Q3JlYXRlIGFuIGFjY291bnQ8L2E+PC9wPgogICAgICA8L2Rpdj4K
ICAgIDwvc2VjdGlvbj4KICA8L2Rpdj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3
cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0i
c2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwv
ZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAg
ICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+
UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJl
Zj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9
InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+
CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9o
dG1sPgpERUNPWV9JTkRFWAoKY2F0ID4gIiRERUNPWS9kYXRhL3ByaWNpbmcuaHRtbCIgPDwnREVD
T1lfUFJJQ0lORycKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRh
IGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9
ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29u
dGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50
PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlByaWNpbmcg4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0
bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJSQU5EQEAgQ2xvdWQgcHJp
Y2luZyDigJQgZnJlZSwgUGx1cyBhbmQgQnVzaW5lc3MgcGxhbnMgd2l0aCBlbmQtdG8tZW5kIGVu
Y3J5cHRpb24uIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxp
bmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+
CjxsaW5rIHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4K
PGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4K
PGJvZHk+CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJy
YW5kIiBocmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9
Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4
PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAw
IC40LTYuOTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIj
ZmZmIi8+PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5h
diBjbGFzcz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgog
ICAgICA8YSBocmVmPSIvcHJpY2luZyIgY2xhc3M9ImFjdGl2ZSI+UHJpY2luZzwvYT4KICAgICAg
PGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRv
Y3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFz
cz0iZ2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRu
IiBocmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hl
YWRlcj4KCjxtYWluIGNsYXNzPSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1o
ZWFkIj4KICAgIDxkaXYgY2xhc3M9ImV5ZWJyb3ciPlByaWNpbmc8L2Rpdj4KICAgIDxoMT5TaW1w
bGUgcGxhbnMgdGhhdCBzY2FsZSB3aXRoIHlvdS48L2gxPgogICAgPHA+U3RhcnQgZnJlZS4gVXBn
cmFkZSB3aGVuIHlvdSBuZWVkIG1vcmUgc3BhY2Ugb3IgdGVhbSBmZWF0dXJlcy4gQWxsIHBsYW5z
IGluY2x1ZGUgZW5kLXRvLWVuZCBlbmNyeXB0aW9uLjwvcD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNz
PSJwcmljaW5nIj4KICAgIDxkaXYgY2xhc3M9InRpZXIiPjxoMz5GcmVlPC9oMz48ZGl2IGNsYXNz
PSJwcmljZSI+4oKsMDxzcGFuPi9tbzwvc3Bhbj48L2Rpdj48dWw+PGxpPjxzdmcgd2lkdGg9IjE4
IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3Vy
cmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+
PC9zdmc+NSBHQiBlbmNyeXB0ZWQgc3RvcmFnZTwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWln
aHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENv
bG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+
U3luYyBvbiAyIGRldmljZXM8L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmll
d0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tl
LXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPjMwLWRheSBmaWxl
IHJlY292ZXJ5PC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAg
MCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0i
Mi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5MaW5rIHNoYXJpbmc8L2xpPjwv
dWw+PGEgY2xhc3M9ImJ0biBibG9jayIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+PC9k
aXY+CiAgICA8ZGl2IGNsYXNzPSJ0aWVyIGZlYXQtdGllciI+PHNwYW4gY2xhc3M9InRhZyI+TW9z
dCBwb3B1bGFyPC9zcGFuPjxoMz5QbHVzPC9oMz48ZGl2IGNsYXNzPSJwcmljZSI+4oKsNDxzcGFu
Pi9tbzwvc3Bhbj48L2Rpdj48dWw+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3
Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Ut
d2lkdGg9IjIuMiI+PHBhdGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+MjAwIEdCIGVuY3J5
cHRlZCBzdG9yYWdlPC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9
IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0
aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz5VbmxpbWl0ZWQgZGV2aWNl
czwvbGk+PGxpPjxzdmcgd2lkdGg9IjE4IiBoZWlnaHQ9IjE4IiB2aWV3Qm94PSIwIDAgMjQgMjQi
IGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuMiI+PHBh
dGggZD0iTTIwIDYgOSAxN2wtNS01Ii8+PC9zdmc+VmVyc2lvbiBoaXN0b3J5PC9saT48bGk+PHN2
ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5
IDE3bC01LTUiLz48L3N2Zz5QYXNzd29yZC1wcm90ZWN0ZWQgbGlua3M8L2xpPjxsaT48c3ZnIHdp
ZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJv
a2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTds
LTUtNSIvPjwvc3ZnPlByaW9yaXR5IHN1cHBvcnQ8L2xpPjwvdWw+PGEgY2xhc3M9ImJ0biBibG9j
ayIgaHJlZj0iL3NpZ251cCI+U3RhcnQgUGx1czwvYT48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InRp
ZXIiPjxoMz5CdXNpbmVzczwvaDM+PGRpdiBjbGFzcz0icHJpY2UiPuKCrDEyPHNwYW4+L3VzZXIv
bW88L3NwYW4+PC9kaXY+PHVsPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0Jv
eD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdp
ZHRoPSIyLjIiPjxwYXRoIGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPjIgVEIgcGVyIHVzZXI8
L2xpPjxsaT48c3ZnIHdpZHRoPSIxOCIgaGVpZ2h0PSIxOCIgdmlld0JveD0iMCAwIDI0IDI0IiBm
aWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjIiPjxwYXRo
IGQ9Ik0yMCA2IDkgMTdsLTUtNSIvPjwvc3ZnPlRlYW0gZm9sZGVycyAmIHJvbGVzPC9saT48bGk+
PHN2ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9u
ZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAg
NiA5IDE3bC01LTUiLz48L3N2Zz5BZG1pbiBjb25zb2xlICYgYXVkaXQgbG9nPC9saT48bGk+PHN2
ZyB3aWR0aD0iMTgiIGhlaWdodD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIg
c3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5
IDE3bC01LTUiLz48L3N2Zz5TU08gLyBTQU1MPC9saT48bGk+PHN2ZyB3aWR0aD0iMTgiIGhlaWdo
dD0iMTgiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29s
b3IiIHN0cm9rZS13aWR0aD0iMi4yIj48cGF0aCBkPSJNMjAgNiA5IDE3bC01LTUiLz48L3N2Zz45
OS45JSB1cHRpbWUgU0xBPC9saT48L3VsPjxhIGNsYXNzPSJidG4gYmxvY2siIGhyZWY9Ii9zaWdu
dXAiPkNvbnRhY3Qgc2FsZXM8L2E+PC9kaXY+CiAgPC9kaXY+CjwvbWFpbj4KCjxmb290ZXI+CiAg
PGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4gY2xh
c3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1
c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2Vj
dXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJl
Zj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+
CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2
PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAgPC9k
aXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0
Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfUFJJQ0lORwoKY2F0ID4gIiRERUNPWS9kYXRhL3NlY3Vy
aXR5Lmh0bWwiIDw8J0RFQ09ZX1NFQ1VSSVRZJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0i
ZW4iPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9InZpZXdwb3J0
IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIgLz4KPG1ldGEg
bmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1ldGEgbmFtZT0i
cmVmZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+U2VjdXJpdHkg4oCUIEBA
QlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJI
b3cgQEBCUkFOREBAIENsb3VkIGVuY3J5cHRzIGFuZCBwcm90ZWN0cyB5b3VyIGZpbGVzOiBjbGll
bnQtc2lkZSBrZXlzLCBBRVMtMjU2LCBUTFMgMS4zLCBFVSBkYXRhIGNlbnRlcnMuIiAvPgo8bGlu
ayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3Vj
aC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZl
c3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNo
ZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAg
PGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3Zn
IGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVu
PSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5
Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAw
LTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+
QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgog
ICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJp
Y2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5IiBjbGFzcz0iYWN0aXZl
Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+CiAgICA8L25hdj4K
ICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3QiIGhyZWY9Ii8j
c2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVmPSIvc2lnbnVwIj5H
ZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4KCjxtYWluIGNsYXNz
PSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFkIj4KICAgIDxkaXYgY2xh
c3M9ImV5ZWJyb3ciPlNlY3VyaXR5PC9kaXY+CiAgICA8aDE+WW91ciBkYXRhLCBlbmNyeXB0ZWQg
ZW5kIHRvIGVuZC48L2gxPgogICAgPHA+U2VjdXJpdHkgaXMgdGhlIGRlZmF1bHQsIG5vdCBhbiBh
ZGQtb24uIEhlcmUgaXMgaG93IEBAQlJBTkRAQCBDbG91ZCBwcm90ZWN0cyB5b3VyIGZpbGVzLjwv
cD4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJwcm9zZSI+CiAgICA8aDI+RW5jcnlwdGlvbjwvaDI+
CiAgICA8cD5GaWxlcyBhcmUgZW5jcnlwdGVkIG9uIHlvdXIgZGV2aWNlIGJlZm9yZSB0aGV5IGFy
ZSB1cGxvYWRlZC4gRW5jcnlwdGlvbiBrZXlzIGFyZSBkZXJpdmVkIGZyb20geW91ciBwYXNzd29y
ZCBhbmQgbmV2ZXIgbGVhdmUgeW91ciBkZXZpY2VzIGluIHBsYWludGV4dCwgc28gd2UgY2Fubm90
IHJlYWQgeW91ciBjb250ZW50LiBEYXRhIGF0IHJlc3QgaXMgc3RvcmVkIHdpdGggQUVTLTI1NiBh
bmQgYWxsIHRyYW5zcG9ydCBpcyBwcm90ZWN0ZWQgd2l0aCBUTFMgMS4zLjwvcD4KICAgIDxoMj5J
bmZyYXN0cnVjdHVyZTwvaDI+CiAgICA8cD5TdG9yYWdlIGFuZCBwcm9jZXNzaW5nIHJ1biBpbiBJ
U08gMjcwMDEtY2VydGlmaWVkIGRhdGEgY2VudGVycyBpbiB0aGUgRXVyb3BlYW4gVW5pb24uIE9i
amVjdCBzdG9yYWdlIGlzIHJlcGxpY2F0ZWQgYWNyb3NzIGF2YWlsYWJpbGl0eSB6b25lcywgYW5k
IGRlbGV0ZWQgZmlsZXMgcmVtYWluIHJlY292ZXJhYmxlIGZvciAzMCBkYXlzIGJlZm9yZSB0aGV5
IGFyZSBwdXJnZWQuPC9wPgogICAgPGgyPkFjY2VzcyAmYW1wOyBhY2NvdW50czwvaDI+CiAgICA8
dWw+CiAgICAgIDxsaT5PcHRpb25hbCB0d28tZmFjdG9yIGF1dGhlbnRpY2F0aW9uIChUT1RQIGFu
ZCBzZWN1cml0eSBrZXlzKS48L2xpPgogICAgICA8bGk+U2Vzc2lvbiBhbmQgZGV2aWNlIG1hbmFn
ZW1lbnQgd2l0aCByZW1vdGUgc2lnbi1vdXQuPC9saT4KICAgICAgPGxpPlJhdGUtbGltaXRlZCBh
dXRoZW50aWNhdGlvbiBhbmQgYW5vbWFseSBhbGVydHMgb24gbmV3IHNpZ24taW5zLjwvbGk+CiAg
ICA8L3VsPgogICAgPGgyPlJlc3BvbnNpYmxlIGRpc2Nsb3N1cmU8L2gyPgogICAgPHA+Rm91bmQg
c29tZXRoaW5nPyBXZSB3ZWxjb21lIHJlcG9ydHMgZnJvbSBzZWN1cml0eSByZXNlYXJjaGVycy4g
UmVhY2ggdXMgYXQgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Im1haWx0bzpzZWN1cml0eUBAQE1BSU5f
RE9NQUlOQEAiPnNlY3VyaXR5QEBATUFJTl9ET01BSU5AQDwvYT4g4oCUIHNlZSBhbHNvIG91ciA8
YSBjbGFzcz0ibGluayIgaHJlZj0iLy53ZWxsLWtub3duL3NlY3VyaXR5LnR4dCI+c2VjdXJpdHku
dHh0PC9hPi48L3A+CiAgICA8cCBjbGFzcz0ibXV0ZWQiPkxhc3QgcmV2aWV3ZWQ6IE5vdmVtYmVy
IDIwMjUuPC9wPgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9IndyYXAg
Zm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90
Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+
CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8
YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2
YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVmPSIv
c3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIi
PjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNj
cmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+
CkRFQ09ZX1NFQ1VSSVRZCgpjYXQgPiAiJERFQ09ZL2RhdGEvcHJpdmFjeS5odG1sIiA8PCdERUNP
WV9QUklWQUNZJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0iZW4iPgo8aGVhZD4KPG1ldGEg
Y2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1k
ZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIgLz4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250
ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1ldGEgbmFtZT0icmVmZXJyZXIiIGNvbnRlbnQ9
Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+UHJpdmFjeSBQb2xpY3kg4oCUIEBAQlJBTkRAQCBDbG91
ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJSQU5EQEAgQ2xv
dWQgcHJpdmFjeSBwb2xpY3kuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmlj
byIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNv
bi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5p
ZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+
CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEg
Y2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIg
MzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdo
dD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUg
My41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVa
IiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9h
PgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9k
dWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJl
Zj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+
CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hv
c3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVm
PSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4K
CjxtYWluIGNsYXNzPSJ3cmFwIHBhZ2UtbWFpbiI+CiAgPGRpdiBjbGFzcz0icGFnZS1oZWFkIj4K
ICAgIDxkaXYgY2xhc3M9ImV5ZWJyb3ciPkxlZ2FsPC9kaXY+CiAgICA8aDE+UHJpdmFjeSBQb2xp
Y3k8L2gxPgogICAgPHA+SG93IHdlIGhhbmRsZSB5b3VyIGRhdGEuIFRoaXMgc3VtbWFyeSBleHBs
YWlucyB3aGF0IHdlIGNvbGxlY3QgYW5kIHdoeS48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0i
cHJvc2UiPgogICAgPGgyPkluZm9ybWF0aW9uIHdlIGNvbGxlY3Q8L2gyPgogICAgPHA+QWNjb3Vu
dCBkZXRhaWxzIHlvdSBwcm92aWRlIChuYW1lLCBlbWFpbCksIGFuZCB0ZWNobmljYWwgZGF0YSBu
ZWVkZWQgdG8gcnVuIHRoZSBzZXJ2aWNlIChkZXZpY2UgdHlwZSwgSVAgYWRkcmVzcywgbG9nIHRp
bWVzdGFtcHMpLiBZb3VyIGZpbGVzIGFyZSBlbmNyeXB0ZWQgd2l0aCBrZXlzIHdlIGRvIG5vdCBo
b2xkLCBzbyB3ZSBjYW5ub3QgYWNjZXNzIHRoZWlyIGNvbnRlbnRzLjwvcD4KICAgIDxoMj5Ib3cg
d2UgdXNlIGl0PC9oMj4KICAgIDxwPlRvIHByb3ZpZGUgYW5kIHNlY3VyZSB0aGUgc2VydmljZSwg
dG8gY29tbXVuaWNhdGUgYWJvdXQgeW91ciBhY2NvdW50LCBhbmQgdG8gY29tcGx5IHdpdGggbGVn
YWwgb2JsaWdhdGlvbnMuIFdlIGRvIG5vdCBzZWxsIHBlcnNvbmFsIGRhdGEgb3IgdXNlIGZpbGUg
Y29udGVudHMgZm9yIGFkdmVydGlzaW5nLjwvcD4KICAgIDxoMj5TdG9yYWdlICZhbXA7IGVuY3J5
cHRpb248L2gyPgogICAgPHA+RGF0YSBpcyBzdG9yZWQgaW4gdGhlIEV1cm9wZWFuIFVuaW9uIGFu
ZCBlbmNyeXB0ZWQgYXQgcmVzdC4gQmFja3VwcyBhcmUgcmV0YWluZWQgZm9yIGRpc2FzdGVyIHJl
Y292ZXJ5IGFuZCByb3RhdGVkIG9uIGEgZml4ZWQgc2NoZWR1bGUuPC9wPgogICAgPGgyPllvdXIg
cmlnaHRzPC9oMj4KICAgIDx1bD4KICAgICAgPGxpPkFjY2VzcywgY29ycmVjdCBvciBleHBvcnQg
eW91ciBkYXRhLjwvbGk+CiAgICAgIDxsaT5EZWxldGUgeW91ciBhY2NvdW50IGFuZCBhc3NvY2lh
dGVkIGZpbGVzLjwvbGk+CiAgICAgIDxsaT5PYmplY3QgdG8gb3IgcmVzdHJpY3QgY2VydGFpbiBw
cm9jZXNzaW5nLjwvbGk+CiAgICA8L3VsPgogICAgPGgyPkNvbnRhY3Q8L2gyPgogICAgPHA+UXVl
c3Rpb25zIGFib3V0IHByaXZhY3k6IDxhIGNsYXNzPSJsaW5rIiBocmVmPSJtYWlsdG86cHJpdmFj
eUBAQE1BSU5fRE9NQUlOQEAiPnByaXZhY3lAQEBNQUlOX0RPTUFJTkBAPC9hPi48L3A+CiAgICA8
cCBjbGFzcz0ibXV0ZWQiPkxhc3QgdXBkYXRlZDogTm92ZW1iZXIgMjAyNS48L3A+CiAgPC9kaXY+
CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xh
c3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0i
c3RleHQiPkNoZWNraW5nIHN0YXR1c+KApjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxh
IGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0
YXR1czwvYT4KICAgICAgPGEgaHJlZj0iL3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhy
ZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9h
PgogICAgPC9uYXY+CiAgICA8ZGl2PsKpIDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFO
REBAIENsb3VkPC9kaXY+CiAgPC9kaXY+CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9h
cHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4KREVDT1lfUFJJVkFDWQoKY2F0
ID4gIiRERUNPWS9kYXRhL3Rlcm1zLmh0bWwiIDw8J0RFQ09ZX1RFUk1TJwo8IURPQ1RZUEUgaHRt
bD4KPGh0bWwgbGFuZz0iZW4iPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRh
IG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2Nh
bGU9MSIgLz4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIg
Lz4KPG1ldGEgbmFtZT0icmVmZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+
VGVybXMgb2YgU2VydmljZSDigJQgQEBCUkFOREBAIENsb3VkPC90aXRsZT4KPG1ldGEgbmFtZT0i
ZGVzY3JpcHRpb24iIGNvbnRlbnQ9IkBAQlJBTkRAQCBDbG91ZCB0ZXJtcyBvZiBzZXJ2aWNlLiIg
Lz4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSIvZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBw
bGUtdG91Y2gtaWNvbiIgaHJlZj0iL2FwcGxlLXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9
Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRzL3NpdGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0i
c3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0cy9hcHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVh
ZGVyPgogIDxkaXYgY2xhc3M9IndyYXAgYmFyIj4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0i
LyI+PHN2ZyBjbGFzcz0ibWFyayIgdmlld0JveD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlh
LWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lkdGg9IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0i
IzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41IDIxLjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUg
NSAwIDAgMC05LjUzLTEuNEE0IDQgMCAwIDAgMTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3Zn
PjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Nsb3VkPC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9Imxp
bmtzIj4KICAgICAgPGEgaHJlZj0iLyNmZWF0dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJl
Zj0iL3ByaWNpbmciPlByaWNpbmc8L2E+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJp
dHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2NzIj5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2
IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEgY2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+
U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0
ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBw
YWdlLW1haW4iPgogIDxkaXYgY2xhc3M9InBhZ2UtaGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVi
cm93Ij5MZWdhbDwvZGl2PgogICAgPGgxPlRlcm1zIG9mIFNlcnZpY2U8L2gxPgogICAgPHA+VGhl
IHJ1bGVzIGZvciB1c2luZyBAQEJSQU5EQEAgQ2xvdWQuIEJ5IHVzaW5nIHRoZSBzZXJ2aWNlIHlv
dSBhZ3JlZSB0byB0aGVzZSB0ZXJtcy48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icHJvc2Ui
PgogICAgPGgyPjEuIEFjY291bnRzPC9oMj4KICAgIDxwPllvdSBhcmUgcmVzcG9uc2libGUgZm9y
IGFjdGl2aXR5IHVuZGVyIHlvdXIgYWNjb3VudCBhbmQgZm9yIGtlZXBpbmcgeW91ciBjcmVkZW50
aWFscyBzZWN1cmUuIFlvdSBtdXN0IGJlIG9sZCBlbm91Z2ggdG8gZm9ybSBhIGJpbmRpbmcgY29u
dHJhY3QgaW4geW91ciBjb3VudHJ5LjwvcD4KICAgIDxoMj4yLiBBY2NlcHRhYmxlIHVzZTwvaDI+
CiAgICA8cD5EbyBub3QgdXNlIHRoZSBzZXJ2aWNlIHRvIHN0b3JlIG9yIGRpc3RyaWJ1dGUgdW5s
YXdmdWwgY29udGVudCwgdG8gaW5mcmluZ2Ugb3RoZXJzJyByaWdodHMsIG9yIHRvIGRpc3J1cHQg
dGhlIHNlcnZpY2UuIFdlIG1heSBzdXNwZW5kIGFjY291bnRzIHRoYXQgdmlvbGF0ZSB0aGVzZSB0
ZXJtcy48L3A+CiAgICA8aDI+My4gQXZhaWxhYmlsaXR5PC9oMj4KICAgIDxwPldlIGFpbSBmb3Ig
aGlnaCBhdmFpbGFiaWxpdHkgYnV0IHRoZSBzZXJ2aWNlIGlzIHByb3ZpZGVkICJhcyBpcyIuIFBs
YW5uZWQgbWFpbnRlbmFuY2UgaXMgYW5ub3VuY2VkIG9uIHRoZSBzdGF0dXMgcGFnZSB3aGVyZSBw
cmFjdGljYWwuPC9wPgogICAgPGgyPjQuIExpbWl0YXRpb24gb2YgbGlhYmlsaXR5PC9oMj4KICAg
IDxwPlRvIHRoZSBleHRlbnQgcGVybWl0dGVkIGJ5IGxhdywgd2UgYXJlIG5vdCBsaWFibGUgZm9y
IGluZGlyZWN0IG9yIGNvbnNlcXVlbnRpYWwgZGFtYWdlcy4gS2VlcCB5b3VyIG93biBiYWNrdXBz
IG9mIGNyaXRpY2FsIGRhdGEuPC9wPgogICAgPGgyPjUuIENoYW5nZXM8L2gyPgogICAgPHA+V2Ug
bWF5IHVwZGF0ZSB0aGVzZSB0ZXJtczsgbWF0ZXJpYWwgY2hhbmdlcyB3aWxsIGJlIGNvbW11bmlj
YXRlZCBieSBlbWFpbCBvciBpbi1hcHAgbm90aWNlLjwvcD4KICAgIDxoMj5Db250YWN0PC9oMj4K
ICAgIDxwPlF1ZXN0aW9uczogPGEgY2xhc3M9ImxpbmsiIGhyZWY9Im1haWx0bzpsZWdhbEBAQE1B
SU5fRE9NQUlOQEAiPmxlZ2FsQEBATUFJTl9ET01BSU5AQDwvYT4uPC9wPgogICAgPHAgY2xhc3M9
Im11dGVkIj5MYXN0IHVwZGF0ZWQ6IE5vdmVtYmVyIDIwMjUuPC9wPgogIDwvZGl2Pgo8L21haW4+
Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0
dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5D
aGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIv
c2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+
CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVy
bXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwv
bmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91
ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBk
ZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1RFUk1TCgpjYXQgPiAiJERFQ09Z
L2RhdGEvc3RhdHVzLmh0bWwiIDw8J0RFQ09ZX1NUQVRVUycKPCFET0NUWVBFIGh0bWw+CjxodG1s
IGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2
aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+
CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRh
IG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlN5c3RlbSBT
dGF0dXMg4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9u
IiBjb250ZW50PSJMaXZlIHN0YXR1cyBvZiBAQEJSQU5EQEAgQ2xvdWQgY29tcG9uZW50cy4iIC8+
CjxsaW5rIHJlbD0iaWNvbiIgaHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9ImFwcGxl
LXRvdWNoLWljb24iIGhyZWY9Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsgcmVsPSJt
YW5pZmVzdCIgaHJlZj0iL2Fzc2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayByZWw9InN0
eWxlc2hlZXQiIGhyZWY9Ii9hc3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4KPGhlYWRl
cj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhyZWY9Ii8i
PjxzdmcgY2xhc3M9Im1hcmsiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIgYXJpYS1o
aWRkZW49InRydWUiPjxyZWN0IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZpbGw9IiMz
YTViZDkiLz48cGF0aCBkPSJNMTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45OCA1IDUg
MCAwIDAtOS41My0xLjRBNCA0IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48L3N2Zz48
c3Bhbj5AQEJSQU5EQEAmbmJzcDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNzPSJsaW5r
cyI+CiAgICAgIDxhIGhyZWY9Ii8jZmVhdHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxhIGhyZWY9
Ii9wcmljaW5nIj5QcmljaW5nPC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5
PC9hPgogICAgICA8YSBocmVmPSIvZG9jcyI+RG9jczwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBj
bGFzcz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9zdCIgaHJlZj0iLyNzaWduaW4iPlNp
Z24gaW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9Ii9zaWdudXAiPkdldCBzdGFydGVk
PC9hPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4gY2xhc3M9IndyYXAgcGFn
ZS1tYWluIj4KICA8ZGl2IGNsYXNzPSJwYWdlLWhlYWQiPgogICAgPGRpdiBjbGFzcz0iZXllYnJv
dyI+U3lzdGVtIFN0YXR1czwvZGl2PgogICAgPGgxPkN1cnJlbnQgc2VydmljZSBzdGF0dXM8L2gx
PgogICAgPHA+TGl2ZSBzdGF0dXMgb2YgQEBCUkFOREBAIENsb3VkIGNvbXBvbmVudHMuIFN1YnNj
cmliZSB0byB1cGRhdGVzIG9uIHRoZSA8YSBjbGFzcz0ibGluayIgaHJlZj0iL3N1cHBvcnQiPnN1
cHBvcnQgcGFnZTwvYT4uPC9wPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InByb3NlIiBzdHlsZT0i
bWF4LXdpZHRoOjcyMHB4Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cy1iYW5uZXIiPjxzcGFuIGNs
YXNzPSJkb3Qgb2siPjwvc3Bhbj4gQWxsIHN5c3RlbXMgb3BlcmF0aW9uYWw8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9ImNvbXAiPjxzcGFuPkFQSTwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNs
YXNzPSJkb3QiPjwvc3Bhbj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9
ImNvbXAiPjxzcGFuPldlYiBhcHA8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBjbGFzcz0i
ZG90Ij48L3NwYW4+T3BlcmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjb21w
Ij48c3Bhbj5GaWxlIHN5bmM8L3NwYW4+PHNwYW4gY2xhc3M9Im9wIj48c3BhbiBjbGFzcz0iZG90
Ij48L3NwYW4+T3BlcmF0aW9uYWw8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjb21wIj48
c3Bhbj5PYmplY3Qgc3RvcmFnZTwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFuIGNsYXNzPSJk
b3QiPjwvc3Bhbj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNvbXAi
PjxzcGFuPkF1dGhlbnRpY2F0aW9uPC9zcGFuPjxzcGFuIGNsYXNzPSJvcCI+PHNwYW4gY2xhc3M9
ImRvdCI+PC9zcGFuPk9wZXJhdGlvbmFsPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iY29t
cCI+PHNwYW4+U2hhcmluZyAmYW1wOyBsaW5rczwvc3Bhbj48c3BhbiBjbGFzcz0ib3AiPjxzcGFu
IGNsYXNzPSJkb3QiPjwvc3Bhbj5PcGVyYXRpb25hbDwvc3Bhbj48L2Rpdj4KICAgIDxwIGNsYXNz
PSJtdXRlZCI+VXB0aW1lIG92ZXIgdGhlIGxhc3QgOTAgZGF5czogOTkuOTclLiBUaW1lcyBzaG93
biBpbiBVVEMuPC9wPgogIDwvZGl2Pgo8L21haW4+Cgo8Zm9vdGVyPgogIDxkaXYgY2xhc3M9Indy
YXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNsYXNzPSJkb3QiIGlkPSJz
ZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0dXPigKY8L3NwYW4+PC9k
aXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNlY3VyaXR5PC9hPgogICAg
ICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhyZWY9Ii9wcml2YWN5Ij5Q
cml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9hPgogICAgICA8YSBocmVm
PSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRpdj7CqSA8c3BhbiBpZD0i
eXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwvZGl2Pgo8L2Zvb3Rlcj4K
PHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0
bWw+CkRFQ09ZX1NUQVRVUwoKY2F0ID4gIiRERUNPWS9kYXRhL2RvY3MuaHRtbCIgPDwnREVDT1lf
RE9DUycKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJz
ZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNl
LXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0i
bm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1y
ZWZlcnJlciIgLz4KPHRpdGxlPkRvY3Mg4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+CjxtZXRh
IG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJAQEJSQU5EQEAgQ2xvdWQgZG9jdW1lbnRhdGlv
bjogZ2V0dGluZyBzdGFydGVkLCB1cGxvYWRzLCBzaGFyaW5nLCBzeW5jIGNsaWVudHMgYW5kIEFQ
SS4iIC8+CjxsaW5rIHJlbD0iaWNvbiIgaHJlZj0iL2Zhdmljb24uaWNvIiAvPgo8bGluayByZWw9
ImFwcGxlLXRvdWNoLWljb24iIGhyZWY9Ii9hcHBsZS10b3VjaC1pY29uLnBuZyIgLz4KPGxpbmsg
cmVsPSJtYW5pZmVzdCIgaHJlZj0iL2Fzc2V0cy9zaXRlLndlYm1hbmlmZXN0IiAvPgo8bGluayBy
ZWw9InN0eWxlc2hlZXQiIGhyZWY9Ii9hc3NldHMvYXBwLmNzcyIgLz4KPC9oZWFkPgo8Ym9keT4K
PGhlYWRlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGJhciI+CiAgICA8YSBjbGFzcz0iYnJhbmQiIGhy
ZWY9Ii8iPjxzdmcgY2xhc3M9Im1hcmsiIHZpZXdCb3g9IjAgMCAzMiAzMiIgZmlsbD0ibm9uZSIg
YXJpYS1oaWRkZW49InRydWUiPjxyZWN0IHdpZHRoPSIzMiIgaGVpZ2h0PSIzMiIgcng9IjgiIGZp
bGw9IiMzYTViZDkiLz48cGF0aCBkPSJNMTAuNSAyMS41aDExYTMuNSAzLjUgMCAwIDAgLjQtNi45
OCA1IDUgMCAwIDAtOS41My0xLjRBNCA0IDAgMCAwIDEwLjUgMjEuNVoiIGZpbGw9IiNmZmYiLz48
L3N2Zz48c3Bhbj5AQEJSQU5EQEAmbmJzcDtDbG91ZDwvc3Bhbj48L2E+CiAgICA8bmF2IGNsYXNz
PSJsaW5rcyI+CiAgICAgIDxhIGhyZWY9Ii8jZmVhdHVyZXMiPlByb2R1Y3Q8L2E+CiAgICAgIDxh
IGhyZWY9Ii9wcmljaW5nIj5QcmljaW5nPC9hPgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNl
Y3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvZG9jcyIgY2xhc3M9ImFjdGl2ZSI+RG9jczwvYT4K
ICAgIDwvbmF2PgogICAgPGRpdiBjbGFzcz0ibmF2LWN0YSI+CiAgICAgIDxhIGNsYXNzPSJnaG9z
dCIgaHJlZj0iLyNzaWduaW4iPlNpZ24gaW48L2E+CiAgICAgIDxhIGNsYXNzPSJidG4iIGhyZWY9
Ii9zaWdudXAiPkdldCBzdGFydGVkPC9hPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvaGVhZGVyPgoK
PG1haW4gY2xhc3M9IndyYXAgcGFnZS1tYWluIj4KICA8ZGl2IGNsYXNzPSJwYWdlLWhlYWQiPgog
ICAgPGRpdiBjbGFzcz0iZXllYnJvdyI+RG9jczwvZGl2PgogICAgPGgxPkRvY3VtZW50YXRpb248
L2gxPgogICAgPHA+RXZlcnl0aGluZyB5b3UgbmVlZCB0byBnZXQgdGhlIG1vc3Qgb3V0IG9mIEBA
QlJBTkRAQCBDbG91ZC48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0iZG9jcyI+CiAgICA8bmF2
IGNsYXNzPSJ0b2MiPgogICAgICA8YSBocmVmPSIjc3RhcnQiPkdldHRpbmcgc3RhcnRlZDwvYT4K
ICAgICAgPGEgaHJlZj0iI3VwbG9hZCI+VXBsb2FkaW5nIGZpbGVzPC9hPgogICAgICA8YSBocmVm
PSIjc2hhcmUiPlNoYXJpbmc8L2E+CiAgICAgIDxhIGhyZWY9IiNzeW5jIj5TeW5jIGNsaWVudHM8
L2E+CiAgICAgIDxhIGhyZWY9IiNhcGkiPkFQSTwvYT4KICAgIDwvbmF2PgogICAgPGRpdiBjbGFz
cz0icHJvc2UiPgogICAgICA8aDIgaWQ9InN0YXJ0Ij5HZXR0aW5nIHN0YXJ0ZWQ8L2gyPgogICAg
ICA8cD5DcmVhdGUgYW4gYWNjb3VudCwgaW5zdGFsbCB0aGUgZGVza3RvcCBvciBtb2JpbGUgYXBw
LCBhbmQgeW91ciBmaWxlcyBiZWdpbiBzeW5jaW5nIGF1dG9tYXRpY2FsbHkuIFRoZSB3ZWIgYXBw
IGlzIGF2YWlsYWJsZSBmcm9tIGFueSBicm93c2VyIHdpdGhvdXQgaW5zdGFsbGF0aW9uLjwvcD4K
ICAgICAgPGgyIGlkPSJ1cGxvYWQiPlVwbG9hZGluZyBmaWxlczwvaDI+CiAgICAgIDxwPkRyYWcg
ZmlsZXMgaW50byB0aGUgd2ViIGFwcCBvciBkcm9wIHRoZW0gaW50byB5b3VyIHN5bmNlZCBmb2xk
ZXIuIFVwbG9hZHMgYXJlIGVuY3J5cHRlZCBvbiB5b3VyIGRldmljZSBiZWZvcmUgdGhleSBsZWF2
ZSBpdC4gTGFyZ2UgZmlsZXMgYXJlIGNodW5rZWQgYW5kIHJlc3VtYWJsZS48L3A+CiAgICAgIDxo
MiBpZD0ic2hhcmUiPlNoYXJpbmc8L2gyPgogICAgICA8cD5DcmVhdGUgYSBzaGFyZSBsaW5rIGZv
ciBhbnkgZmlsZSBvciBmb2xkZXIuIExpbmtzIGNhbiBiZSBwYXNzd29yZC1wcm90ZWN0ZWQgYW5k
IGdpdmVuIGFuIGV4cGlyeSBkYXRlLiBSZXZva2UgYWNjZXNzIGF0IGFueSB0aW1lIGZyb20gdGhl
IGZpbGUgbWVudS48L3A+CiAgICAgIDxoMiBpZD0ic3luYyI+U3luYyBjbGllbnRzPC9oMj4KICAg
ICAgPHVsPgogICAgICAgIDxsaT5EZXNrdG9wOiBXaW5kb3dzLCBtYWNPUywgTGludXguPC9saT4K
ICAgICAgICA8bGk+TW9iaWxlOiBpT1MgYW5kIEFuZHJvaWQuPC9saT4KICAgICAgICA8bGk+V2Vi
OiBhbnkgbW9kZXJuIGJyb3dzZXIuPC9saT4KICAgICAgPC91bD4KICAgICAgPGgyIGlkPSJhcGki
PkFQSTwvaDI+CiAgICAgIDxwPkF1dG9tYXRlIHVwbG9hZHMgYW5kIGFjY291bnQgdGFza3Mgd2l0
aCB0aGUgUkVTVCBBUEkuIEF1dGhlbnRpY2F0ZSB3aXRoIGEgcGVyc29uYWwgdG9rZW4gZnJvbSB5
b3VyIGFjY291bnQgc2V0dGluZ3MuIEZ1bGwgcmVmZXJlbmNlIGlzIGF2YWlsYWJsZSB0byBzaWdu
ZWQtaW4gdXNlcnMuPC9wPgogICAgICA8cCBjbGFzcz0ibXV0ZWQiPk5lZWQgaGVscD8gVmlzaXQg
PGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPi48L3A+CiAgICA8L2Rp
dj4KICA8L2Rpdj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2IGNsYXNzPSJ3cmFwIGZvb3QiPgog
ICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0iZG90IiBpZD0ic2RvdCI+PC9zcGFu
PjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCmPC9zcGFuPjwvZGl2PgogICAgPG5h
dj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0i
L3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBocmVmPSIvcHJpdmFjeSI+UHJpdmFjeTwvYT4K
ICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwvYT4KICAgICAgPGEgaHJlZj0iL3N1cHBvcnQi
PlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxkaXY+wqkgPHNwYW4gaWQ9InlyIj4yMDI2PC9z
cGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4KPC9mb290ZXI+CjxzY3JpcHQgc3Jj
PSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgpERUNPWV9E
T0NTCgpjYXQgPiAiJERFQ09ZL2RhdGEvc2lnbnVwLmh0bWwiIDw8J0RFQ09ZX1NJR05VUCcKPCFE
T0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04
IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBp
bml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90cyIgY29udGVudD0ibm9pbmRleCwg
bm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBjb250ZW50PSJuby1yZWZlcnJlciIg
Lz4KPHRpdGxlPkNyZWF0ZSB5b3VyIGFjY291bnQg4oCUIEBAQlJBTkRAQCBDbG91ZDwvdGl0bGU+
CjxtZXRhIG5hbWU9ImRlc2NyaXB0aW9uIiBjb250ZW50PSJDcmVhdGUgYW4gQEBCUkFOREBAIENs
b3VkIGFjY291bnQg4oCUIDUgR0IgZnJlZSwgZW5kLXRvLWVuZCBlbmNyeXB0ZWQuIiAvPgo8bGlu
ayByZWw9Imljb24iIGhyZWY9Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3Vj
aC1pY29uIiBocmVmPSIvYXBwbGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZl
c3QiIGhyZWY9Ii9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNo
ZWV0IiBocmVmPSIvYXNzZXRzL2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAg
PGRpdiBjbGFzcz0id3JhcCBiYXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3Zn
IGNsYXNzPSJtYXJrIiB2aWV3Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVu
PSJ0cnVlIj48cmVjdCB3aWR0aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5
Ii8+PHBhdGggZD0iTTEwLjUgMjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAw
LTkuNTMtMS40QTQgNCAwIDAgMCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+
QEBCUkFOREBAJm5ic3A7Q2xvdWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgog
ICAgICA8YSBocmVmPSIvI2ZlYXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJp
Y2luZyI+UHJpY2luZzwvYT4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4K
ICAgICAgPGEgaHJlZj0iL2RvY3MiPkRvY3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9
Im5hdi1jdGEiPgogICAgICA8YSBjbGFzcz0iZ2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGlu
PC9hPgogICAgICA8YSBjbGFzcz0iYnRuIiBocmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4K
ICAgIDwvZGl2PgogIDwvZGl2Pgo8L2hlYWRlcj4KCjxtYWluIGNsYXNzPSJ3cmFwIj4KICA8c2Vj
dGlvbiBjbGFzcz0iYXV0aCIgc3R5bGU9ImdyaWQtY29sdW1uOjEvLTEiPgogICAgPGRpdiBjbGFz
cz0iY2FyZCBjZW50ZXItY2FyZCI+CiAgICAgIDxoMj5DcmVhdGUgeW91ciBhY2NvdW50PC9oMj4K
ICAgICAgPHAgY2xhc3M9InN1YiI+U3RhcnQgd2l0aCA1IEdCIGZyZWUuIE5vIGNyZWRpdCBjYXJk
IHJlcXVpcmVkLjwvcD4KICAgICAgPGRpdiBjbGFzcz0ibXNnIiBpZD0ibXNnIiByb2xlPSJhbGVy
dCI+PC9kaXY+CiAgICAgIDxmb3JtIGlkPSJzaWdudXAiIG5vdmFsaWRhdGU+CiAgICAgICAgPGRp
diBjbGFzcz0iZmllbGQiPgogICAgICAgICAgPGxhYmVsIGZvcj0ibmFtZSI+TmFtZTwvbGFiZWw+
CiAgICAgICAgICA8aW5wdXQgaWQ9Im5hbWUiIG5hbWU9Im5hbWUiIHR5cGU9InRleHQiIGF1dG9j
b21wbGV0ZT0ibmFtZSIgcGxhY2Vob2xkZXI9IllvdXIgbmFtZSIgcmVxdWlyZWQgLz4KICAgICAg
ICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgICAgICA8bGFiZWwgZm9y
PSJlbWFpbCI+RW1haWw8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGlkPSJlbWFpbCIgbmFtZT0i
ZW1haWwiIHR5cGU9ImVtYWlsIiBhdXRvY29tcGxldGU9ImVtYWlsIiBwbGFjZWhvbGRlcj0ieW91
QGV4YW1wbGUuY29tIiByZXF1aXJlZCAvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xh
c3M9ImZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBmb3I9InBhc3N3b3JkIj5QYXNzd29yZDwvbGFi
ZWw+CiAgICAgICAgICA8aW5wdXQgaWQ9InBhc3N3b3JkIiBuYW1lPSJwYXNzd29yZCIgdHlwZT0i
cGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0ibmV3LXBhc3N3b3JkIiBwbGFjZWhvbGRlcj0iQXQgbGVh
c3QgMTAgY2hhcmFjdGVycyIgcmVxdWlyZWQgLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8YnV0
dG9uIGNsYXNzPSJidG4gYmxvY2siIHR5cGU9InN1Ym1pdCIgaWQ9InN1Ym1pdCI+Q3JlYXRlIGFj
Y291bnQ8L2J1dHRvbj4KICAgICAgPC9mb3JtPgogICAgICA8cCBjbGFzcz0iYWx0Ij5BbHJlYWR5
IGhhdmUgYW4gYWNjb3VudD8gPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGlu
PC9hPjwvcD4KICAgIDwvZGl2PgogIDwvc2VjdGlvbj4KPC9tYWluPgoKPGZvb3Rlcj4KICA8ZGl2
IGNsYXNzPSJ3cmFwIGZvb3QiPgogICAgPGRpdiBjbGFzcz0ic3RhdHVzIj48c3BhbiBjbGFzcz0i
ZG90IiBpZD0ic2RvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGV4dCI+Q2hlY2tpbmcgc3RhdHVz4oCm
PC9zcGFuPjwvZGl2PgogICAgPG5hdj4KICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0
eTwvYT4KICAgICAgPGEgaHJlZj0iL3N0YXR1cyI+U3RhdHVzPC9hPgogICAgICA8YSBocmVmPSIv
cHJpdmFjeSI+UHJpdmFjeTwvYT4KICAgICAgPGEgaHJlZj0iL3Rlcm1zIj5UZXJtczwvYT4KICAg
ICAgPGEgaHJlZj0iL3N1cHBvcnQiPlN1cHBvcnQ8L2E+CiAgICA8L25hdj4KICAgIDxkaXY+wqkg
PHNwYW4gaWQ9InlyIj4yMDI2PC9zcGFuPiBAQEJSQU5EQEAgQ2xvdWQ8L2Rpdj4KICA8L2Rpdj4K
PC9mb290ZXI+CjxzY3JpcHQgc3JjPSIvYXNzZXRzL2FwcC5qcyIgZGVmZXI+PC9zY3JpcHQ+Cjwv
Ym9keT4KPC9odG1sPgpERUNPWV9TSUdOVVAKCmNhdCA+ICIkREVDT1kvZGF0YS9yZXNldC5odG1s
IiA8PCdERUNPWV9SRVNFVCcKPCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+
CjxtZXRhIGNoYXJzZXQ9IlVURi04IiAvPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0i
d2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEiIC8+CjxtZXRhIG5hbWU9InJvYm90
cyIgY29udGVudD0ibm9pbmRleCwgbm9mb2xsb3ciIC8+CjxtZXRhIG5hbWU9InJlZmVycmVyIiBj
b250ZW50PSJuby1yZWZlcnJlciIgLz4KPHRpdGxlPlJlc2V0IHBhc3N3b3JkIOKAlCBAQEJSQU5E
QEAgQ2xvdWQ8L3RpdGxlPgo8bWV0YSBuYW1lPSJkZXNjcmlwdGlvbiIgY29udGVudD0iUmVzZXQg
eW91ciBAQEJSQU5EQEAgQ2xvdWQgcGFzc3dvcmQuIiAvPgo8bGluayByZWw9Imljb24iIGhyZWY9
Ii9mYXZpY29uLmljbyIgLz4KPGxpbmsgcmVsPSJhcHBsZS10b3VjaC1pY29uIiBocmVmPSIvYXBw
bGUtdG91Y2gtaWNvbi5wbmciIC8+CjxsaW5rIHJlbD0ibWFuaWZlc3QiIGhyZWY9Ii9hc3NldHMv
c2l0ZS53ZWJtYW5pZmVzdCIgLz4KPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvYXNzZXRz
L2FwcC5jc3MiIC8+CjwvaGVhZD4KPGJvZHk+CjxoZWFkZXI+CiAgPGRpdiBjbGFzcz0id3JhcCBi
YXIiPgogICAgPGEgY2xhc3M9ImJyYW5kIiBocmVmPSIvIj48c3ZnIGNsYXNzPSJtYXJrIiB2aWV3
Qm94PSIwIDAgMzIgMzIiIGZpbGw9Im5vbmUiIGFyaWEtaGlkZGVuPSJ0cnVlIj48cmVjdCB3aWR0
aD0iMzIiIGhlaWdodD0iMzIiIHJ4PSI4IiBmaWxsPSIjM2E1YmQ5Ii8+PHBhdGggZD0iTTEwLjUg
MjEuNWgxMWEzLjUgMy41IDAgMCAwIC40LTYuOTggNSA1IDAgMCAwLTkuNTMtMS40QTQgNCAwIDAg
MCAxMC41IDIxLjVaIiBmaWxsPSIjZmZmIi8+PC9zdmc+PHNwYW4+QEBCUkFOREBAJm5ic3A7Q2xv
dWQ8L3NwYW4+PC9hPgogICAgPG5hdiBjbGFzcz0ibGlua3MiPgogICAgICA8YSBocmVmPSIvI2Zl
YXR1cmVzIj5Qcm9kdWN0PC9hPgogICAgICA8YSBocmVmPSIvcHJpY2luZyI+UHJpY2luZzwvYT4K
ICAgICAgPGEgaHJlZj0iL3NlY3VyaXR5Ij5TZWN1cml0eTwvYT4KICAgICAgPGEgaHJlZj0iL2Rv
Y3MiPkRvY3M8L2E+CiAgICA8L25hdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1jdGEiPgogICAgICA8
YSBjbGFzcz0iZ2hvc3QiIGhyZWY9Ii8jc2lnbmluIj5TaWduIGluPC9hPgogICAgICA8YSBjbGFz
cz0iYnRuIiBocmVmPSIvc2lnbnVwIj5HZXQgc3RhcnRlZDwvYT4KICAgIDwvZGl2PgogIDwvZGl2
Pgo8L2hlYWRlcj4KCjxtYWluIGNsYXNzPSJ3cmFwIj4KICA8c2VjdGlvbiBjbGFzcz0iYXV0aCIg
c3R5bGU9ImdyaWQtY29sdW1uOjEvLTEiPgogICAgPGRpdiBjbGFzcz0iY2FyZCBjZW50ZXItY2Fy
ZCI+CiAgICAgIDxoMj5SZXNldCB5b3VyIHBhc3N3b3JkPC9oMj4KICAgICAgPHAgY2xhc3M9InN1
YiI+RW50ZXIgeW91ciBlbWFpbCBhbmQgd2Ugd2lsbCBzZW5kIHJlc2V0IGluc3RydWN0aW9ucy48
L3A+CiAgICAgIDxkaXYgY2xhc3M9Im1zZyIgaWQ9Im1zZyIgcm9sZT0iYWxlcnQiPjwvZGl2Pgog
ICAgICA8Zm9ybSBpZD0icmVzZXQiIG5vdmFsaWRhdGU+CiAgICAgICAgPGRpdiBjbGFzcz0iZmll
bGQiPgogICAgICAgICAgPGxhYmVsIGZvcj0iZW1haWwiPkVtYWlsPC9sYWJlbD4KICAgICAgICAg
IDxpbnB1dCBpZD0iZW1haWwiIG5hbWU9ImVtYWlsIiB0eXBlPSJlbWFpbCIgYXV0b2NvbXBsZXRl
PSJlbWFpbCIgcGxhY2Vob2xkZXI9InlvdUBleGFtcGxlLmNvbSIgcmVxdWlyZWQgLz4KICAgICAg
ICA8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYmxvY2siIHR5cGU9InN1Ym1pdCIg
aWQ9InN1Ym1pdCI+U2VuZCByZXNldCBsaW5rPC9idXR0b24+CiAgICAgIDwvZm9ybT4KICAgICAg
PHAgY2xhc3M9ImFsdCI+PGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii8jc2lnbmluIj5CYWNrIHRvIHNp
Z24gaW48L2E+PC9wPgogICAgPC9kaXY+CiAgPC9zZWN0aW9uPgo8L21haW4+Cgo8Zm9vdGVyPgog
IDxkaXYgY2xhc3M9IndyYXAgZm9vdCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0dXMiPjxzcGFuIGNs
YXNzPSJkb3QiIGlkPSJzZG90Ij48L3NwYW4+PHNwYW4gaWQ9InN0ZXh0Ij5DaGVja2luZyBzdGF0
dXPigKY8L3NwYW4+PC9kaXY+CiAgICA8bmF2PgogICAgICA8YSBocmVmPSIvc2VjdXJpdHkiPlNl
Y3VyaXR5PC9hPgogICAgICA8YSBocmVmPSIvc3RhdHVzIj5TdGF0dXM8L2E+CiAgICAgIDxhIGhy
ZWY9Ii9wcml2YWN5Ij5Qcml2YWN5PC9hPgogICAgICA8YSBocmVmPSIvdGVybXMiPlRlcm1zPC9h
PgogICAgICA8YSBocmVmPSIvc3VwcG9ydCI+U3VwcG9ydDwvYT4KICAgIDwvbmF2PgogICAgPGRp
dj7CqSA8c3BhbiBpZD0ieXIiPjIwMjY8L3NwYW4+IEBAQlJBTkRAQCBDbG91ZDwvZGl2PgogIDwv
ZGl2Pgo8L2Zvb3Rlcj4KPHNjcmlwdCBzcmM9Ii9hc3NldHMvYXBwLmpzIiBkZWZlcj48L3Njcmlw
dD4KPC9ib2R5Pgo8L2h0bWw+CkRFQ09ZX1JFU0VUCgpjYXQgPiAiJERFQ09ZL2RhdGEvc3VwcG9y
dC5odG1sIiA8PCdERUNPWV9TVVBQT1JUJwo8IURPQ1RZUEUgaHRtbD4KPGh0bWwgbGFuZz0iZW4i
Pgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiIC8+CjxtZXRhIG5hbWU9InZpZXdwb3J0IiBj
b250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSIgLz4KPG1ldGEgbmFt
ZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyIgLz4KPG1ldGEgbmFtZT0icmVm
ZXJyZXIiIGNvbnRlbnQ9Im5vLXJlZmVycmVyIiAvPgo8dGl0bGU+U3VwcG9ydCDigJQgQEBCUkFO
REBAIENsb3VkPC90aXRsZT4KPG1ldGEgbmFtZT0iZGVzY3JpcHRpb24iIGNvbnRlbnQ9IkBAQlJB
TkRAQCBDbG91ZCBoZWxwIGFuZCBzdXBwb3J0LiIgLz4KPGxpbmsgcmVsPSJpY29uIiBocmVmPSIv
ZmF2aWNvbi5pY28iIC8+CjxsaW5rIHJlbD0iYXBwbGUtdG91Y2gtaWNvbiIgaHJlZj0iL2FwcGxl
LXRvdWNoLWljb24ucG5nIiAvPgo8bGluayByZWw9Im1hbmlmZXN0IiBocmVmPSIvYXNzZXRzL3Np
dGUud2VibWFuaWZlc3QiIC8+CjxsaW5rIHJlbD0ic3R5bGVzaGVldCIgaHJlZj0iL2Fzc2V0cy9h
cHAuY3NzIiAvPgo8L2hlYWQ+Cjxib2R5Pgo8aGVhZGVyPgogIDxkaXYgY2xhc3M9IndyYXAgYmFy
Ij4KICAgIDxhIGNsYXNzPSJicmFuZCIgaHJlZj0iLyI+PHN2ZyBjbGFzcz0ibWFyayIgdmlld0Jv
eD0iMCAwIDMyIDMyIiBmaWxsPSJub25lIiBhcmlhLWhpZGRlbj0idHJ1ZSI+PHJlY3Qgd2lkdGg9
IjMyIiBoZWlnaHQ9IjMyIiByeD0iOCIgZmlsbD0iIzNhNWJkOSIvPjxwYXRoIGQ9Ik0xMC41IDIx
LjVoMTFhMy41IDMuNSAwIDAgMCAuNC02Ljk4IDUgNSAwIDAgMC05LjUzLTEuNEE0IDQgMCAwIDAg
MTAuNSAyMS41WiIgZmlsbD0iI2ZmZiIvPjwvc3ZnPjxzcGFuPkBAQlJBTkRAQCZuYnNwO0Nsb3Vk
PC9zcGFuPjwvYT4KICAgIDxuYXYgY2xhc3M9ImxpbmtzIj4KICAgICAgPGEgaHJlZj0iLyNmZWF0
dXJlcyI+UHJvZHVjdDwvYT4KICAgICAgPGEgaHJlZj0iL3ByaWNpbmciPlByaWNpbmc8L2E+CiAg
ICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJpdHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9kb2Nz
Ij5Eb2NzPC9hPgogICAgPC9uYXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtY3RhIj4KICAgICAgPGEg
Y2xhc3M9Imdob3N0IiBocmVmPSIvI3NpZ25pbiI+U2lnbiBpbjwvYT4KICAgICAgPGEgY2xhc3M9
ImJ0biIgaHJlZj0iL3NpZ251cCI+R2V0IHN0YXJ0ZWQ8L2E+CiAgICA8L2Rpdj4KICA8L2Rpdj4K
PC9oZWFkZXI+Cgo8bWFpbiBjbGFzcz0id3JhcCBwYWdlLW1haW4iPgogIDxkaXYgY2xhc3M9InBh
Z2UtaGVhZCI+CiAgICA8ZGl2IGNsYXNzPSJleWVicm93Ij5TdXBwb3J0PC9kaXY+CiAgICA8aDE+
SGVscCAmYW1wOyBzdXBwb3J0PC9oMT4KICAgIDxwPkFuc3dlcnMgdG8gY29tbW9uIHF1ZXN0aW9u
cywgYW5kIGhvdyB0byByZWFjaCB1cy48L3A+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0icHJvc2Ui
PgogICAgPGgyPkZyZXF1ZW50bHkgYXNrZWQ8L2gyPgogICAgPHA+PHN0cm9uZz5Ib3cgZG8gSSBy
ZWNvdmVyIGEgZGVsZXRlZCBmaWxlPzwvc3Ryb25nPiBEZWxldGVkIGZpbGVzIHN0YXkgaW4geW91
ciB0cmFzaCBmb3IgMzAgZGF5cy4gT3BlbiB0aGUgd2ViIGFwcCwgZ28gdG8gVHJhc2ggYW5kIGNo
b29zZSBSZXN0b3JlLjwvcD4KICAgIDxwPjxzdHJvbmc+Q2FuIEkgYWNjZXNzIGZpbGVzIG9mZmxp
bmU/PC9zdHJvbmc+IFllcy4gVGhlIGRlc2t0b3AgYW5kIG1vYmlsZSBhcHBzIGtlZXAgYSBsb2Nh
bCBjb3B5IGFuZCBzeW5jIGNoYW5nZXMgd2hlbiB5b3UgcmVjb25uZWN0LjwvcD4KICAgIDxwPjxz
dHJvbmc+SG93IGRvIEkgZW5hYmxlIHR3by1mYWN0b3IgYXV0aGVudGljYXRpb24/PC9zdHJvbmc+
IEFjY291bnQgc2V0dGluZ3Mg4oaSIFNlY3VyaXR5IOKGkiBUd28tZmFjdG9yIGF1dGhlbnRpY2F0
aW9uLjwvcD4KICAgIDxoMj5Db250YWN0IHVzPC9oMj4KICAgIDxwPkVtYWlsIDxhIGNsYXNzPSJs
aW5rIiBocmVmPSJtYWlsdG86c3VwcG9ydEBAQE1BSU5fRE9NQUlOQEAiPnN1cHBvcnRAQEBNQUlO
X0RPTUFJTkBAPC9hPiBhbmQgd2UgdXN1YWxseSByZXBseSB3aXRoaW4gb25lIGJ1c2luZXNzIGRh
eS4gRm9yIHNlcnZpY2Ugc3RhdHVzIHNlZSB0aGUgPGEgY2xhc3M9ImxpbmsiIGhyZWY9Ii9zdGF0
dXMiPnN0YXR1cyBwYWdlPC9hPi48L3A+CiAgPC9kaXY+CjwvbWFpbj4KCjxmb290ZXI+CiAgPGRp
diBjbGFzcz0id3JhcCBmb290Ij4KICAgIDxkaXYgY2xhc3M9InN0YXR1cyI+PHNwYW4gY2xhc3M9
ImRvdCIgaWQ9InNkb3QiPjwvc3Bhbj48c3BhbiBpZD0ic3RleHQiPkNoZWNraW5nIHN0YXR1c+KA
pjwvc3Bhbj48L2Rpdj4KICAgIDxuYXY+CiAgICAgIDxhIGhyZWY9Ii9zZWN1cml0eSI+U2VjdXJp
dHk8L2E+CiAgICAgIDxhIGhyZWY9Ii9zdGF0dXMiPlN0YXR1czwvYT4KICAgICAgPGEgaHJlZj0i
L3ByaXZhY3kiPlByaXZhY3k8L2E+CiAgICAgIDxhIGhyZWY9Ii90ZXJtcyI+VGVybXM8L2E+CiAg
ICAgIDxhIGhyZWY9Ii9zdXBwb3J0Ij5TdXBwb3J0PC9hPgogICAgPC9uYXY+CiAgICA8ZGl2PsKp
IDxzcGFuIGlkPSJ5ciI+MjAyNjwvc3Bhbj4gQEBCUkFOREBAIENsb3VkPC9kaXY+CiAgPC9kaXY+
CjwvZm9vdGVyPgo8c2NyaXB0IHNyYz0iL2Fzc2V0cy9hcHAuanMiIGRlZmVyPjwvc2NyaXB0Pgo8
L2JvZHk+CjwvaHRtbD4KREVDT1lfU1VQUE9SVAoKY2F0ID4gIiRERUNPWS9kYXRhL2Fzc2V0cy9h
cHAuY3NzIiA8PCdERUNPWV9BUFBDU1MnCjpyb290ewogIC0tYmc6I2VlZjJmODsgLS1wYW5lbDoj
ZmZmZmZmOyAtLWluazojMTAxNzI4OyAtLW11dGVkOiM1YjZiODY7CiAgLS1saW5lOiNlMmU4ZjI7
IC0tYnJhbmQ6IzNhNWJkOTsgLS1icmFuZC1wcmVzczojMmY0OWFkOyAtLXJpbmc6IzlkYjRmNDsK
ICAtLW9rOiMxZjlkNTc7IC0td2FybjojYzIzYjNiOyAtLXNoYWRvdzowIDE4cHggNTBweCAtMjRw
eCByZ2JhKDIwLDQwLDkwLC4zNSk7CiAgLS1yYWRpdXM6MTRweDsKfQoqe2JveC1zaXppbmc6Ym9y
ZGVyLWJveH0KaHRtbCxib2R5e21hcmdpbjowO2hlaWdodDoxMDAlfQpib2R5ewogIGZvbnQtZmFt
aWx5Oi1hcHBsZS1zeXN0ZW0sQmxpbmtNYWNTeXN0ZW1Gb250LCJTZWdvZSBVSSIsUm9ib3RvLEhl
bHZldGljYSxBcmlhbCxzYW5zLXNlcmlmOwogIGNvbG9yOnZhcigtLWluayk7IGJhY2tncm91bmQ6
dmFyKC0tYmcpOwogIC13ZWJraXQtZm9udC1zbW9vdGhpbmc6YW50aWFsaWFzZWQ7IGxpbmUtaGVp
Z2h0OjEuNTsKICBiYWNrZ3JvdW5kLWltYWdlOnJhZGlhbC1ncmFkaWVudCgxMTAwcHggNTQwcHgg
YXQgODYlIC0xMCUsICNkZmU4ZmIgMCUsIHJnYmEoMjIzLDIzMiwyNTEsMCkgNjAlKSwKICAgICAg
ICAgICAgICAgICAgIHJhZGlhbC1ncmFkaWVudCg5MDBweCA1MDBweCBhdCAtMTAlIDExMCUsICNl
NmVmZmIgMCUsIHJnYmEoMjMwLDIzOSwyNTEsMCkgNTUlKTsKfQphe2NvbG9yOmluaGVyaXQ7dGV4
dC1kZWNvcmF0aW9uOm5vbmV9Ci53cmFwe21heC13aWR0aDoxMTYwcHg7bWFyZ2luOjAgYXV0bztw
YWRkaW5nOjAgMjRweH0KaGVhZGVye3Bvc2l0aW9uOnN0aWNreTt0b3A6MDt6LWluZGV4OjU7YmFj
a2Ryb3AtZmlsdGVyOnNhdHVyYXRlKDEuMSkgYmx1cig4cHgpOwogIGJhY2tncm91bmQ6cmdiYSgy
MzgsMjQyLDI0OCwuNzgpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpfQouYmFy
e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJl
dHdlZW47aGVpZ2h0OjY2cHh9Ci5icmFuZHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVy
O2dhcDoxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzotLjJweH0KLm1hcmt7d2lk
dGg6MzBweDtoZWlnaHQ6MzBweDtmbGV4Om5vbmV9Cm5hdi5saW5rc3tkaXNwbGF5OmZsZXg7Z2Fw
OjI4cHg7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQpuYXYubGlua3MgYTpob3Zl
cntjb2xvcjp2YXIoLS1pbmspfQoubmF2LWN0YXtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDoxNnB4fQouZ2hvc3R7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQou
Z2hvc3Q6aG92ZXJ7Y29sb3I6dmFyKC0taW5rKX0KLmJ0bnthcHBlYXJhbmNlOm5vbmU7Ym9yZGVy
OjA7Y3Vyc29yOnBvaW50ZXI7Zm9udDppbmhlcml0O2ZvbnQtd2VpZ2h0OjYwMDsKICBib3JkZXIt
cmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE4cHg7YmFja2dyb3VuZDp2YXIoLS1icmFuZCk7Y29s
b3I6I2ZmZjt0cmFuc2l0aW9uOmJhY2tncm91bmQgLjE1cywgdHJhbnNmb3JtIC4wNXN9Ci5idG46
aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1icmFuZC1wcmVzcyl9Ci5idG46YWN0aXZle3RyYW5zZm9y
bTp0cmFuc2xhdGVZKDFweCl9Ci5idG4uYmxvY2t7d2lkdGg6MTAwJTtwYWRkaW5nOjEzcHh9Ci5i
dG5bZGlzYWJsZWRde29wYWNpdHk6LjY7Y3Vyc29yOmRlZmF1bHR9Cm1haW57cGFkZGluZzo2NHB4
IDAgMjhweH0KLmdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxLjA1ZnIg
Ljk1ZnI7Z2FwOjY0cHg7YWxpZ24taXRlbXM6Y2VudGVyfQouZXllYnJvd3tmb250LXNpemU6MTIu
NXB4O2ZvbnQtd2VpZ2h0OjYwMDtsZXR0ZXItc3BhY2luZzouMTJlbTt0ZXh0LXRyYW5zZm9ybTp1
cHBlcmNhc2U7Y29sb3I6dmFyKC0tYnJhbmQpfQpoMXtmb250LXNpemU6NDZweDtsaW5lLWhlaWdo
dDoxLjA4O2xldHRlci1zcGFjaW5nOi0xLjFweDttYXJnaW46MTRweCAwIDE2cHg7Zm9udC13ZWln
aHQ6NzYwfQoubGVkZXtmb250LXNpemU6MTcuNXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXgtd2lk
dGg6MzBlbTttYXJnaW46MCAwIDI2cHh9CnVsLmZlYXR7bGlzdC1zdHlsZTpub25lO3BhZGRpbmc6
MDttYXJnaW46MDtkaXNwbGF5OmdyaWQ7Z2FwOjEzcHg7bWF4LXdpZHRoOjMwZW19CnVsLmZlYXQg
bGl7ZGlzcGxheTpmbGV4O2dhcDoxMXB4O2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7Zm9udC1zaXpl
OjE1cHh9CnVsLmZlYXQgc3Zne2ZsZXg6bm9uZTttYXJnaW4tdG9wOjJweDtjb2xvcjp2YXIoLS1i
cmFuZCl9Ci5oZXJvLWltZ3t3aWR0aDoxMDAlO21heC13aWR0aDo0MjBweDttYXJnaW46MjZweCAw
IDA7ZGlzcGxheTpibG9ja30KLnRydXN0e21hcmdpbi10b3A6MjRweDtmb250LXNpemU6MTNweDtj
b2xvcjp2YXIoLS1tdXRlZCk7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4
fQouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxp
bmUpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTsKICBib3gtc2hhZG93OnZhcigtLXNoYWRv
dyk7cGFkZGluZzozMHB4IDMwcHggMjZweH0KLmNhcmQgaDJ7bWFyZ2luOjAgMCA0cHg7Zm9udC1z
aXplOjIxcHg7bGV0dGVyLXNwYWNpbmc6LS4zcHh9Ci5jYXJkIC5zdWJ7bWFyZ2luOjAgMCAyMnB4
O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTRweH0KbGFiZWx7ZGlzcGxheTpibG9jaztm
b250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7bWFyZ2luOjAgMCA3cHg7Y29sb3I6IzMzNDE1
Y30KLmZpZWxke21hcmdpbi1ib3R0b206MTZweH0KaW5wdXRbdHlwZT1lbWFpbF0saW5wdXRbdHlw
ZT1wYXNzd29yZF17d2lkdGg6MTAwJTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRl
ci1yYWRpdXM6MTBweDsKICBwYWRkaW5nOjEycHggMTNweDtmb250OmluaGVyaXQ7YmFja2dyb3Vu
ZDojZmJmY2ZlO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4xNXMsIGJveC1zaGFkb3cgLjE1c30K
aW5wdXQ6Zm9jdXN7b3V0bGluZTowO2JvcmRlci1jb2xvcjp2YXIoLS1icmFuZCk7Ym94LXNoYWRv
dzowIDAgMCA0cHggdmFyKC0tcmluZyl9Ci5yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNl
bnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW46LTJweCAwIDE4cHh9Ci5y
ZW1lbWJlcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXpl
OjEzLjVweDtjb2xvcjp2YXIoLS1tdXRlZCl9Ci5saW5re2NvbG9yOnZhcigtLWJyYW5kKTtmb250
LXNpemU6MTMuNXB4O2ZvbnQtd2VpZ2h0OjYwMH0KLmxpbms6aG92ZXJ7dGV4dC1kZWNvcmF0aW9u
OnVuZGVybGluZX0KLm1zZ3tkaXNwbGF5Om5vbmU7bWFyZ2luOjAgMCAxNnB4O3BhZGRpbmc6MTBw
eCAxMnB4O2JvcmRlci1yYWRpdXM6OXB4O2ZvbnQtc2l6ZToxMy41cHg7CiAgYmFja2dyb3VuZDoj
ZmRlY2VjO2NvbG9yOiNhMDI5Mjk7Ym9yZGVyOjFweCBzb2xpZCAjZjZjY2NjfQoubXNnLnNob3d7
ZGlzcGxheTpibG9ja30KLmFsdHttYXJnaW46MDt0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6
MTMuNXB4O2NvbG9yOnZhcigtLW11dGVkKX0KLmRpdmlkZXJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtnYXA6MTJweDtjb2xvcjojOWFhN2JkO2ZvbnQtc2l6ZToxMnB4O21hcmdpbjoy
MHB4IDB9Ci5kaXZpZGVyOjpiZWZvcmUsLmRpdmlkZXI6OmFmdGVye2NvbnRlbnQ6IiI7aGVpZ2h0
OjFweDtiYWNrZ3JvdW5kOnZhcigtLWxpbmUpO2ZsZXg6MX0KZm9vdGVye2JvcmRlci10b3A6MXB4
IHNvbGlkIHZhcigtLWxpbmUpO21hcmdpbi10b3A6NDhweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1
NSwyNTUsLjUpfQouZm9vdHtkaXNwbGF5OmZsZXg7ZmxleC13cmFwOndyYXA7Z2FwOjE4cHggMjhw
eDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47CiAgcGFk
ZGluZzoyMnB4IDA7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpfQouZm9vdCBuYXZ7
ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDoxOHB4fQouZm9vdCBhOmhvdmVye2NvbG9y
OnZhcigtLWluayl9Ci5zdGF0dXN7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50
ZXI7Z2FwOjhweH0KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTti
YWNrZ3JvdW5kOiNjMmM5ZDZ9Ci5kb3Qub2t7YmFja2dyb3VuZDp2YXIoLS1vayk7Ym94LXNoYWRv
dzowIDAgMCAzcHggcmdiYSgzMSwxNTcsODcsLjE1KX0KLnJldmVhbHtvcGFjaXR5OjA7dHJhbnNm
b3JtOnRyYW5zbGF0ZVkoMTBweCk7YW5pbWF0aW9uOnJpc2UgLjZzIGN1YmljLWJlemllciguMiwu
NywuMiwxKSBmb3J3YXJkc30KLnJldmVhbC5kMnthbmltYXRpb24tZGVsYXk6LjA4c30KQGtleWZy
YW1lcyByaXNle3Rve29wYWNpdHk6MTt0cmFuc2Zvcm06bm9uZX19CkBtZWRpYSAocHJlZmVycy1y
ZWR1Y2VkLW1vdGlvbjpyZWR1Y2Upey5yZXZlYWx7YW5pbWF0aW9uOm5vbmU7b3BhY2l0eToxO3Ry
YW5zZm9ybTpub25lfX0KQG1lZGlhIChtYXgtd2lkdGg6ODgwcHgpewogIG5hdi5saW5rc3tkaXNw
bGF5Om5vbmV9CiAgLmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcjtnYXA6NDBweH0KICBt
YWlue3BhZGRpbmc6NDBweCAwIDE2cHh9CiAgaDF7Zm9udC1zaXplOjM2cHh9CiAgLnBpdGNoe29y
ZGVyOjJ9LmF1dGh7b3JkZXI6MX0KICAuaGVyby1pbWd7ZGlzcGxheTpub25lfQp9CgovKiDilIDi
lIAgbXVsdGktcGFnZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KLmxpbmtzIGEuYWN0
aXZle2NvbG9yOnZhcigtLWluayl9Ci5wYWdlLW1haW57cGFkZGluZzo1NnB4IDAgNDBweH0KLnBh
Z2UtaGVhZHttYXgtd2lkdGg6NzYwcHg7bWFyZ2luOjAgMCAyOHB4fQoucGFnZS1oZWFkIC5leWVi
cm93e21hcmdpbi1ib3R0b206OHB4fQoucGFnZS1oZWFkIGgxe2ZvbnQtc2l6ZTozOHB4O2xpbmUt
aGVpZ2h0OjEuMTttYXJnaW46NnB4IDAgMTBweH0KLnBhZ2UtaGVhZCBwe2NvbG9yOnZhcigtLW11
dGVkKTtmb250LXNpemU6MTdweDttYXgtd2lkdGg6NDJlbTttYXJnaW46MH0KLnByb3Nle21heC13
aWR0aDo3MjBweDtjb2xvcjojMmEzODUwO2ZvbnQtc2l6ZToxNS41cHh9Ci5wcm9zZSBoMntmb250
LXNpemU6MjBweDttYXJnaW46MzBweCAwIDEwcHg7bGV0dGVyLXNwYWNpbmc6LS4ycHh9Ci5wcm9z
ZSBwe21hcmdpbjowIDAgMTRweH0KLnByb3NlIHVse21hcmdpbjowIDAgMTRweDtwYWRkaW5nLWxl
ZnQ6MjBweH0KLnByb3NlIGxpe21hcmdpbjo2cHggMH0KLnByb3NlIC5tdXRlZHtjb2xvcjp2YXIo
LS1tdXRlZCk7Zm9udC1zaXplOjEzLjVweDttYXJnaW4tdG9wOjIycHh9Ci5tc2cub2t7YmFja2dy
b3VuZDojZTlmN2VmO2NvbG9yOiMxYzdhNDQ7Ym9yZGVyLWNvbG9yOiNiZmU2Y2R9Ci5jZW50ZXIt
Y2FyZHttYXgtd2lkdGg6NDIwcHg7bWFyZ2luOjQ4cHggYXV0byA4cHh9Ci8qIHByaWNpbmcgKi8K
LnByaWNpbmd7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoMywxZnIp
O2dhcDoyMHB4O21hcmdpbjo4cHggMCAwfQoudGllcntiYWNrZ3JvdW5kOnZhcigtLXBhbmVsKTti
b3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6dmFyKC0tcmFkaXVzKTtw
YWRkaW5nOjI0cHg7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbn0KLnRpZXIuZmVh
dC10aWVye2JvcmRlci1jb2xvcjp2YXIoLS1icmFuZCk7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cp
fQoudGllciBoM3ttYXJnaW46MCAwIDJweDtmb250LXNpemU6MTdweH0KLnRpZXIgLnByaWNle2Zv
bnQtc2l6ZTozMHB4O2ZvbnQtd2VpZ2h0Ojc0MDtsZXR0ZXItc3BhY2luZzotMXB4O21hcmdpbjo2
cHggMH0KLnRpZXIgLnByaWNlIHNwYW57Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NTAwO2Nv
bG9yOnZhcigtLW11dGVkKX0KLnRpZXIgdWx7bGlzdC1zdHlsZTpub25lO3BhZGRpbmc6MDttYXJn
aW46MTRweCAwIDIwcHg7ZGlzcGxheTpncmlkO2dhcDo5cHg7Zm9udC1zaXplOjE0cHg7Y29sb3I6
IzMzNDE1Y30KLnRpZXIgdWwgbGl7ZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRlbXM6Zmxl
eC1zdGFydH0KLnRpZXIgdWwgc3Zne2ZsZXg6bm9uZTttYXJnaW4tdG9wOjJweDtjb2xvcjp2YXIo
LS1icmFuZCl9Ci50aWVyIC5idG57bWFyZ2luLXRvcDphdXRvO3RleHQtYWxpZ246Y2VudGVyfQou
dGFne2Rpc3BsYXk6aW5saW5lLWJsb2NrO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDts
ZXR0ZXItc3BhY2luZzouMDhlbTt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7Y29sb3I6dmFyKC0t
YnJhbmQpO2JhY2tncm91bmQ6I2U4ZWRmZDtib3JkZXItcmFkaXVzOjk5OXB4O3BhZGRpbmc6M3B4
IDlweDthbGlnbi1zZWxmOmZsZXgtc3RhcnQ7bWFyZ2luLWJvdHRvbTo4cHh9Ci8qIHN0YXR1cyAq
Lwouc3RhdHVzLWJhbm5lcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4
O2JhY2tncm91bmQ6I2U5ZjdlZjtib3JkZXI6MXB4IHNvbGlkICNiZmU2Y2Q7Y29sb3I6IzFjN2E0
NDtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNnB4IDE4cHg7Zm9udC13ZWlnaHQ6NjAwO21h
cmdpbjowIDAgMThweH0KLmNvbXB7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0
aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjE0cHggMnB4O2JvcmRlci1ib3R0b206
MXB4IHNvbGlkIHZhcigtLWxpbmUpO2ZvbnQtc2l6ZToxNXB4fQouY29tcDpsYXN0LW9mLXR5cGV7
Ym9yZGVyLWJvdHRvbTowfQoub3B7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50
ZXI7Z2FwOjhweDtjb2xvcjp2YXIoLS1vayk7Zm9udC1zaXplOjEzLjVweDtmb250LXdlaWdodDo2
MDB9Ci5vcCAuZG90e2JhY2tncm91bmQ6dmFyKC0tb2spO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJn
YmEoMzEsMTU3LDg3LC4xNSl9Ci8qIGRvY3MgKi8KLmRvY3N7ZGlzcGxheTpncmlkO2dyaWQtdGVt
cGxhdGUtY29sdW1uczoyMjBweCAxZnI7Z2FwOjQwcHg7YWxpZ24taXRlbXM6c3RhcnR9Ci5kb2Nz
IG5hdi50b2N7cG9zaXRpb246c3RpY2t5O3RvcDo5MHB4O2Rpc3BsYXk6Z3JpZDtnYXA6NnB4O2Zv
bnQtc2l6ZToxNHB4fQouZG9jcyBuYXYudG9jIGF7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6
NXB4IDB9Ci5kb2NzIG5hdi50b2MgYTpob3Zlcntjb2xvcjp2YXIoLS1pbmspfQpAbWVkaWEgKG1h
eC13aWR0aDo4ODBweCl7CiAgLnByaWNpbmd7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0KICAu
ZG9jc3tncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfQogIC5kb2NzIG5hdi50b2N7cG9zaXRpb246
c3RhdGljfQogIC5wYWdlLWhlYWQgaDF7Zm9udC1zaXplOjMwcHh9Cn0KREVDT1lfQVBQQ1NTCgpj
YXQgPiAiJERFQ09ZL2RhdGEvYXNzZXRzL2FwcC5qcyIgPDwnREVDT1lfQVBQSlMnCi8qIEBAQlJB
TkRAQCBDbG91ZCDigJQgd2ViIGNsaWVudCBib290c3RyYXAgKi8KKGZ1bmN0aW9uKCl7CiAgInVz
ZSBzdHJpY3QiOwogIHZhciBBUEk9e3N0YXR1czoiL2FwaS9zdGF0dXMiLGF1dGg6Ii9hcGkvYXV0
aCIscmVnaXN0ZXI6Ii9hcGkvcmVnaXN0ZXIiLHJlc2V0OiIvYXBpL3Jlc2V0In07CgogIGZ1bmN0
aW9uIGVsKGlkKXtyZXR1cm4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpO30KICBmdW5jdGlv
biByZWFkeShmbil7aWYoZG9jdW1lbnQucmVhZHlTdGF0ZSE9PSJsb2FkaW5nIilmbigpO2Vsc2Ug
ZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigiRE9NQ29udGVudExvYWRlZCIsZm4pO30KICBmdW5j
dGlvbiBzaG93KG1zZyx0ZXh0LG9rKXtpZighbXNnKXJldHVybjttc2cudGV4dENvbnRlbnQ9dGV4
dDttc2cuY2xhc3NOYW1lPSJtc2cgc2hvdyIrKG9rPyIgb2siOiIiKTt9CiAgZnVuY3Rpb24gY2xl
YXIobXNnKXtpZihtc2cpbXNnLmNsYXNzTmFtZT0ibXNnIjt9CgogIHJlYWR5KGZ1bmN0aW9uKCl7
CiAgICB2YXIgeXI9ZWwoInlyIik7IGlmKHlyKSB5ci50ZXh0Q29udGVudD1uZXcgRGF0ZSgpLmdl
dEZ1bGxZZWFyKCk7CgogICAgLy8gc2VydmljZSBzdGF0dXMgaW5kaWNhdG9yIChmb290ZXIsIGV2
ZXJ5IHBhZ2UpCiAgICBmZXRjaChBUEkuc3RhdHVzLHtoZWFkZXJzOntBY2NlcHQ6ImFwcGxpY2F0
aW9uL2pzb24ifX0pCiAgICAgIC50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLm9rP3IuanNvbigp
OlByb21pc2UucmVqZWN0KCk7fSkKICAgICAgLnRoZW4oZnVuY3Rpb24oZCl7CiAgICAgICAgdmFy
IGRvdD1lbCgic2RvdCIpLHQ9ZWwoInN0ZXh0Iik7CiAgICAgICAgaWYoZCYmZC5vbmxpbmUpe2Rv
dCYmZG90LmNsYXNzTGlzdC5hZGQoIm9rIik7dCYmKHQudGV4dENvbnRlbnQ9IkFsbCBzeXN0ZW1z
IG9wZXJhdGlvbmFsIik7fQogICAgICAgIGVsc2V7dCYmKHQudGV4dENvbnRlbnQ9IkRlZ3JhZGVk
IHBlcmZvcm1hbmNlIik7fQogICAgICB9KQogICAgICAuY2F0Y2goZnVuY3Rpb24oKXt2YXIgdD1l
bCgic3RleHQiKTt0JiYodC50ZXh0Q29udGVudD0iU3RhdHVzIHVuYXZhaWxhYmxlIik7fSk7Cgog
ICAgLy8gc2lnbi1pbgogICAgdmFyIGxvZ2luPWVsKCJsb2dpbiIpOwogICAgaWYobG9naW4pewog
ICAgICB2YXIgbG1zZz1lbCgibXNnIiksbGJ0bj1lbCgic3VibWl0Iik7CiAgICAgIGxvZ2luLmFk
ZEV2ZW50TGlzdGVuZXIoInN1Ym1pdCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2ZW50RGVm
YXVsdCgpO2NsZWFyKGxtc2cpOwogICAgICAgIHZhciBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8
fCIiKS50cmltKCkscGFzcz1lbCgicGFzc3dvcmQiKS52YWx1ZXx8IiI7CiAgICAgICAgaWYoIWVt
YWlsfHwhcGFzcyl7c2hvdyhsbXNnLCJFbnRlciB5b3VyIGVtYWlsIGFuZCBwYXNzd29yZCB0byBj
b250aW51ZS4iKTtyZXR1cm47fQogICAgICAgIGxidG4uZGlzYWJsZWQ9dHJ1ZTtsYnRuLnRleHRD
b250ZW50PSJTaWduaW5nIGlu4oCmIjsKICAgICAgICBmZXRjaChBUEkuYXV0aCx7bWV0aG9kOiJQ
T1NUIixoZWFkZXJzOnsiQ29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJh
cHBsaWNhdGlvbi9qc29uIn0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtlbWFpbDpl
bWFpbCxwYXNzd29yZDpwYXNzLHJlbWVtYmVyOiEhbG9naW4ucmVtZW1iZXIuY2hlY2tlZH0pfSkK
ICAgICAgICAudGhlbihmdW5jdGlvbihyKXsKICAgICAgICAgIGlmKHIuc3RhdHVzPT09NDI5KXNo
b3cobG1zZywiVG9vIG1hbnkgYXR0ZW1wdHMuIFBsZWFzZSB3YWl0IGEgbW9tZW50IGFuZCB0cnkg
YWdhaW4uIik7CiAgICAgICAgICBlbHNlIHNob3cobG1zZywiRW1haWwgb3IgcGFzc3dvcmQgaXMg
aW5jb3JyZWN0LiIpOwogICAgICAgIH0pCiAgICAgICAgLmNhdGNoKGZ1bmN0aW9uKCl7c2hvdyhs
bXNnLCJDYW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hlY2sgeW91ciBjb25uZWN0aW9uIGFuZCB0
cnkgYWdhaW4uIik7fSkKICAgICAgICAuZmluYWxseShmdW5jdGlvbigpe2xidG4uZGlzYWJsZWQ9
ZmFsc2U7bGJ0bi50ZXh0Q29udGVudD0iU2lnbiBpbiI7fSk7CiAgICAgIH0pOwogICAgfQoKICAg
IC8vIGNyZWF0ZSBhY2NvdW50CiAgICB2YXIgc2lnbnVwPWVsKCJzaWdudXAiKTsKICAgIGlmKHNp
Z251cCl7CiAgICAgIHZhciBzbXNnPWVsKCJtc2ciKSxzYnRuPWVsKCJzdWJtaXQiKTsKICAgICAg
c2lnbnVwLmFkZEV2ZW50TGlzdGVuZXIoInN1Ym1pdCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5w
cmV2ZW50RGVmYXVsdCgpO2NsZWFyKHNtc2cpOwogICAgICAgIHZhciBuYW1lPShlbCgibmFtZSIp
LnZhbHVlfHwiIikudHJpbSgpLAogICAgICAgICAgICBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8
fCIiKS50cmltKCksCiAgICAgICAgICAgIHBhc3M9ZWwoInBhc3N3b3JkIikudmFsdWV8fCIiOwog
ICAgICAgIGlmKCFuYW1lfHwhZW1haWx8fCFwYXNzKXtzaG93KHNtc2csIlBsZWFzZSBmaWxsIGlu
IGV2ZXJ5IGZpZWxkIHRvIGNvbnRpbnVlLiIpO3JldHVybjt9CiAgICAgICAgaWYocGFzcy5sZW5n
dGg8MTApe3Nob3coc21zZywiVXNlIGF0IGxlYXN0IDEwIGNoYXJhY3RlcnMgZm9yIHlvdXIgcGFz
c3dvcmQuIik7cmV0dXJuO30KICAgICAgICBzYnRuLmRpc2FibGVkPXRydWU7c2J0bi50ZXh0Q29u
dGVudD0iQ3JlYXRpbmfigKYiOwogICAgICAgIGZldGNoKEFQSS5yZWdpc3Rlcix7bWV0aG9kOiJQ
T1NUIixoZWFkZXJzOnsiQ29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJh
cHBsaWNhdGlvbi9qc29uIn0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtuYW1lOm5h
bWUsZW1haWw6ZW1haWwscGFzc3dvcmQ6cGFzc30pfSkKICAgICAgICAudGhlbihmdW5jdGlvbihy
KXtyZXR1cm4gci5qc29uKCkuY2F0Y2goZnVuY3Rpb24oKXtyZXR1cm57fTt9KTt9KQogICAgICAg
IC50aGVuKGZ1bmN0aW9uKGope3Nob3coc21zZyxqLm1lc3NhZ2V8fCJDaGVjayB5b3VyIGluYm94
IHRvIGNvbmZpcm0geW91ciBlbWFpbC4iLHRydWUpO3NpZ251cC5yZXNldCgpO30pCiAgICAgICAg
LmNhdGNoKGZ1bmN0aW9uKCl7c2hvdyhzbXNnLCJDYW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hl
Y2sgeW91ciBjb25uZWN0aW9uIGFuZCB0cnkgYWdhaW4uIik7fSkKICAgICAgICAuZmluYWxseShm
dW5jdGlvbigpe3NidG4uZGlzYWJsZWQ9ZmFsc2U7c2J0bi50ZXh0Q29udGVudD0iQ3JlYXRlIGFj
Y291bnQiO30pOwogICAgICB9KTsKICAgIH0KCiAgICAvLyBwYXNzd29yZCByZXNldAogICAgdmFy
IHJlc2V0PWVsKCJyZXNldCIpOwogICAgaWYocmVzZXQpewogICAgICB2YXIgcm1zZz1lbCgibXNn
IikscmJ0bj1lbCgic3VibWl0Iik7CiAgICAgIHJlc2V0LmFkZEV2ZW50TGlzdGVuZXIoInN1Ym1p
dCIsZnVuY3Rpb24oZSl7CiAgICAgICAgZS5wcmV2ZW50RGVmYXVsdCgpO2NsZWFyKHJtc2cpOwog
ICAgICAgIHZhciBlbWFpbD0oZWwoImVtYWlsIikudmFsdWV8fCIiKS50cmltKCk7CiAgICAgICAg
aWYoIWVtYWlsKXtzaG93KHJtc2csIkVudGVyIHRoZSBlbWFpbCBmb3IgeW91ciBhY2NvdW50LiIp
O3JldHVybjt9CiAgICAgICAgcmJ0bi5kaXNhYmxlZD10cnVlO3JidG4udGV4dENvbnRlbnQ9IlNl
bmRpbmfigKYiOwogICAgICAgIGZldGNoKEFQSS5yZXNldCx7bWV0aG9kOiJQT1NUIixoZWFkZXJz
OnsiQ29udGVudC1UeXBlIjoiYXBwbGljYXRpb24vanNvbiIsQWNjZXB0OiJhcHBsaWNhdGlvbi9q
c29uIn0sCiAgICAgICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHtlbWFpbDplbWFpbH0pfSkKICAg
ICAgICAudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCkuY2F0Y2goZnVuY3Rpb24oKXty
ZXR1cm57fTt9KTt9KQogICAgICAgIC50aGVuKGZ1bmN0aW9uKGope3Nob3cocm1zZyxqLm1lc3Nh
Z2V8fCJJZiBhbiBhY2NvdW50IGV4aXN0cywgd2Ugc2VudCByZXNldCBpbnN0cnVjdGlvbnMuIix0
cnVlKTtyZXNldC5yZXNldCgpO30pCiAgICAgICAgLmNhdGNoKGZ1bmN0aW9uKCl7c2hvdyhybXNn
LCJDYW5ub3QgcmVhY2ggdGhlIHNlcnZlci4gQ2hlY2sgeW91ciBjb25uZWN0aW9uIGFuZCB0cnkg
YWdhaW4uIik7fSkKICAgICAgICAuZmluYWxseShmdW5jdGlvbigpe3JidG4uZGlzYWJsZWQ9ZmFs
c2U7cmJ0bi50ZXh0Q29udGVudD0iU2VuZCByZXNldCBsaW5rIjt9KTsKICAgICAgfSk7CiAgICB9
CiAgfSk7Cn0pKCk7CkRFQ09ZX0FQUEpTCgpjYXQgPiAiJERFQ09ZL2RhdGEvYXNzZXRzL2hlcm8u
c3ZnIiA8PCdERUNPWV9IRVJPU1ZHJwo8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAw
L3N2ZyIgdmlld0JveD0iMCAwIDQ2MCAzMjAiIGZpbGw9Im5vbmUiIHJvbGU9ImltZyIgYXJpYS1s
YWJlbD0iRmlsZXMgaW4gdGhlIGNsb3VkIj4KICA8ZGVmcz4KICAgIDxsaW5lYXJHcmFkaWVudCBp
ZD0iZzEiIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj4KICAgICAgPHN0b3Agb2Zmc2V0PSIw
IiBzdG9wLWNvbG9yPSIjNWI3OGU2Ii8+PHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSIjM2E1
YmQ5Ii8+CiAgICA8L2xpbmVhckdyYWRpZW50PgogIDwvZGVmcz4KICA8cmVjdCB4PSI0MCIgeT0i
NjAiIHdpZHRoPSIzODAiIGhlaWdodD0iMjEwIiByeD0iMTgiIGZpbGw9IiNmZmZmZmYiIHN0cm9r
ZT0iI2UyZThmMiIvPgogIDxyZWN0IHg9IjQwIiB5PSI2MCIgd2lkdGg9IjM4MCIgaGVpZ2h0PSI0
NiIgcng9IjE4IiBmaWxsPSIjZjNmNmZjIi8+CiAgPGNpcmNsZSBjeD0iNjQiIGN5PSI4MyIgcj0i
NSIgZmlsbD0iI2NmZDhlYSIvPjxjaXJjbGUgY3g9IjgyIiBjeT0iODMiIHI9IjUiIGZpbGw9IiNj
ZmQ4ZWEiLz48Y2lyY2xlIGN4PSIxMDAiIGN5PSI4MyIgcj0iNSIgZmlsbD0iI2NmZDhlYSIvPgog
IDxyZWN0IHg9IjY0IiB5PSIxMjgiIHdpZHRoPSIxNTAiIGhlaWdodD0iMTQiIHJ4PSI3IiBmaWxs
PSIjZTdlZGY3Ii8+CiAgPHJlY3QgeD0iNjQiIHk9IjE1NiIgd2lkdGg9IjMyMCIgaGVpZ2h0PSIx
MCIgcng9IjUiIGZpbGw9IiNlZWYyZjgiLz4KICA8cmVjdCB4PSI2NCIgeT0iMTc4IiB3aWR0aD0i
MzAwIiBoZWlnaHQ9IjEwIiByeD0iNSIgZmlsbD0iI2VlZjJmOCIvPgogIDxyZWN0IHg9IjY0IiB5
PSIyMDAiIHdpZHRoPSIyNjAiIGhlaWdodD0iMTAiIHJ4PSI1IiBmaWxsPSIjZWVmMmY4Ii8+CiAg
PGc+CiAgICA8cmVjdCB4PSIyNTAiIHk9IjEyMCIgd2lkdGg9IjEzNCIgaGVpZ2h0PSI5MiIgcng9
IjEyIiBmaWxsPSJ1cmwoI2cxKSIvPgogICAgPHBhdGggZD0iTTI4NiAxNzZoNDRhMTMgMTMgMCAw
IDAgMS42LTI1LjkgMTkgMTkgMCAwIDAtMzYtNS40QTE1IDE1IDAgMCAwIDI4NiAxNzZaIiBmaWxs
PSIjZmZmIiBvcGFjaXR5PSIuOTUiLz4KICAgIDxwYXRoIGQ9Ik0zMTYgMTU4djIybS0xMS0xMSAx
MSAxMSAxMS0xMSIgc3Ryb2tlPSIjM2E1YmQ5IiBzdHJva2Utd2lkdGg9IjMiIHN0cm9rZS1saW5l
Y2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPgogIDwvZz4KICA8Y2lyY2xlIGN4
PSIzOTIiIGN5PSIyNDgiIHI9IjI2IiBmaWxsPSIjZWFmMGZjIi8+CiAgPHBhdGggZD0iTTM4NCAy
NDhsNiA2IDEyLTEyIiBzdHJva2U9IiMzYTViZDkiIHN0cm9rZS13aWR0aD0iMy40IiBzdHJva2Ut
bGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz4KPC9zdmc+CkRFQ09ZX0hF
Uk9TVkcKCmNhdCA+ICIkREVDT1kvZGF0YS9hc3NldHMvc2l0ZS53ZWJtYW5pZmVzdCIgPDwnREVD
T1lfTUFOSUZFU1QnCnsKICAibmFtZSI6ICJAQEJSQU5EQEAgQ2xvdWQiLAogICJzaG9ydF9uYW1l
IjogIkBAQlJBTkRAQCIsCiAgInN0YXJ0X3VybCI6ICIvIiwKICAiZGlzcGxheSI6ICJzdGFuZGFs
b25lIiwKICAiYmFja2dyb3VuZF9jb2xvciI6ICIjZWVmMmY4IiwKICAidGhlbWVfY29sb3IiOiAi
IzNhNWJkOSIsCiAgImljb25zIjogWwogICAgeyAic3JjIjogIi9hcHBsZS10b3VjaC1pY29uLnBu
ZyIsICJzaXplcyI6ICIxODB4MTgwIiwgInR5cGUiOiAiaW1hZ2UvcG5nIiB9LAogICAgeyAic3Jj
IjogIi9mYXZpY29uLmljbyIsICJzaXplcyI6ICJhbnkiLCAidHlwZSI6ICJpbWFnZS94LWljb24i
IH0KICBdCn0KREVDT1lfTUFOSUZFU1QKCmNhdCA+ICIkREVDT1kvZG9ja2VyLWNvbXBvc2UueW1s
IiA8PCdERUNPWV9DT01QT1NFJwpzZXJ2aWNlczoKICBmYWtlc2l0ZToKICAgIGltYWdlOiBuZ2lu
eDphbHBpbmUKICAgIGNvbnRhaW5lcl9uYW1lOiBAQFNMVUdAQC1kZWNveQogICAgcmVzdGFydDog
dW5sZXNzLXN0b3BwZWQKICAgIHBvcnRzOgogICAgICAtICIxMjcuMC4wLjE6ODA4MDo4MCIKICAg
IHZvbHVtZXM6CiAgICAgIC0gLi9kYXRhL2FwcGxlLXRvdWNoLWljb24ucG5nOi91c3Ivc2hhcmUv
bmdpbngvaHRtbC9hcHBsZS10b3VjaC1pY29uLnBuZzpybwogICAgICAtIC4vZGF0YS9mYXZpY29u
LmljbzovdXNyL3NoYXJlL25naW54L2h0bWwvZmF2aWNvbi5pY286cm8KICAgICAgLSAuL2RhdGEv
aW5kZXguaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvaW5kZXguaHRtbDpybwogICAgICAtIC4v
ZGF0YS9wcmljaW5nLmh0bWw6L3Vzci9zaGFyZS9uZ2lueC9odG1sL3ByaWNpbmcuaHRtbDpybwog
ICAgICAtIC4vZGF0YS9zZWN1cml0eS5odG1sOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9zZWN1cml0
eS5odG1sOnJvCiAgICAgIC0gLi9kYXRhL3ByaXZhY3kuaHRtbDovdXNyL3NoYXJlL25naW54L2h0
bWwvcHJpdmFjeS5odG1sOnJvCiAgICAgIC0gLi9kYXRhL3Rlcm1zLmh0bWw6L3Vzci9zaGFyZS9u
Z2lueC9odG1sL3Rlcm1zLmh0bWw6cm8KICAgICAgLSAuL2RhdGEvc3RhdHVzLmh0bWw6L3Vzci9z
aGFyZS9uZ2lueC9odG1sL3N0YXR1cy5odG1sOnJvCiAgICAgIC0gLi9kYXRhL2RvY3MuaHRtbDov
dXNyL3NoYXJlL25naW54L2h0bWwvZG9jcy5odG1sOnJvCiAgICAgIC0gLi9kYXRhL3NpZ251cC5o
dG1sOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9zaWdudXAuaHRtbDpybwogICAgICAtIC4vZGF0YS9y
ZXNldC5odG1sOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9yZXNldC5odG1sOnJvCiAgICAgIC0gLi9k
YXRhL3N1cHBvcnQuaHRtbDovdXNyL3NoYXJlL25naW54L2h0bWwvc3VwcG9ydC5odG1sOnJvCiAg
ICAgIC0gLi9kYXRhL2Fzc2V0czovdXNyL3NoYXJlL25naW54L2h0bWwvYXNzZXRzOnJvCiAgICAg
IC0gLi9kYXRhL25naW54LmNvbmY6L2V0Yy9uZ2lueC9jb25mLmQvZGVmYXVsdC5jb25mOnJvCiAg
ICAgIC0gLi9kYXRhL3BocGluZm8ucGhwOi91c3Ivc2hhcmUvbmdpbngvaHRtbC9waHBpbmZvLnBo
cDpybwogICAgICAtIC4vZGF0YS9yb2JvdHMudHh0Oi91c3Ivc2hhcmUvbmdpbngvaHRtbC9yb2Jv
dHMudHh0OnJvCiAgICAgIC0gLi9kYXRhL3N0YXR1cy5waHA6L3Vzci9zaGFyZS9uZ2lueC9odG1s
L3N0YXR1cy5waHA6cm8KICAgICAgLSAuL2RhdGEvVkVSU0lPTjovdXNyL3NoYXJlL25naW54L2h0
bWwvVkVSU0lPTjpybwogICAgICAtIC92YXIvbG9nL215ZmFrZXNpdGU6L3Zhci9sb2cvbXlmYWtl
c2l0ZQogICAgbmV0d29ya3M6IFtmYWtlc2l0ZV0KICAgIGRlcGVuZHNfb246IFtwaHAtZnBtXQog
IHBocC1mcG06CiAgICBpbWFnZTogcGhwOjguMy1mcG0tYWxwaW5lCiAgICBjb250YWluZXJfbmFt
ZTogQEBTTFVHQEAtZGVjb3ktcGhwCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgdm9s
dW1lczoKICAgICAgLSAuL2RhdGEvc3RhdHVzLnBocDovdXNyL3NoYXJlL25naW54L2h0bWwvc3Rh
dHVzLnBocDpybwogICAgICAtIC4vZGF0YS9waHBpbmZvLnBocDovdXNyL3NoYXJlL25naW54L2h0
bWwvcGhwaW5mby5waHA6cm8KICAgIG5ldHdvcmtzOiBbZmFrZXNpdGVdCm5ldHdvcmtzOgogIGZh
a2VzaXRlOgogICAgZHJpdmVyOiBicmlkZ2UKREVDT1lfQ09NUE9TRQoKZWNobyAiPT0gWzMvNV0g
0J/QvtC00L3QuNC80LDRjiDQutC+0L3RgtC10LnQvdC10YAg0LTQtdC60L7RjyAoMTI3LjAuMC4x
OjgwODApID09IgpjZCAiJERFQ09ZIgpkb2NrZXIgY29tcG9zZSB1cCAtZApkb2NrZXIgZXhlYyBA
QFNMVUdAQC1kZWNveSBuZ2lueCAtdCAyPi9kZXYvbnVsbCAmJiBkb2NrZXIgZXhlYyBAQFNMVUdA
QC1kZWNveSBuZ2lueCAtcyByZWxvYWQgMj4vZGV2L251bGwgfHwgZG9ja2VyIHJlc3RhcnQgQEBT
TFVHQEAtZGVjb3kgPi9kZXYvbnVsbApzbGVlcCAzCmVjaG8gLW4gIiAg0LvQvtC60LDQu9GM0L3Q
viAvcHJpY2luZzogIjsgY3VybCAtcyAtbyAvZGV2L251bGwgLXcgJyV7aHR0cF9jb2RlfVxuJyBo
dHRwOi8vMTI3LjAuMC4xOjgwODAvcHJpY2luZwoKZWNobyAiPT0gWzQvNV0g0J/QtdGA0LXQutC7
0Y7Rh9Cw0Y4gQ2FkZHkgQEBSRUxBWV9OQU1FQEA6INC60L7RgNC10L3RjCAtPiDQtNC10LrQvtC5
ICjQstC80LXRgdGC0L4gZmlsZV9zZXJ2ZXIpID09IgpjcCAtYSAiJENBRERZRklMRSIgIiRDQURE
WUZJTEUuYmFrLiR0cyIgJiYgZWNobyAiICDQsdGN0LrQsNC/OiAkQ0FERFlGSUxFLmJhay4kdHMi
CmNhdCA+ICIkQ0FERFlGSUxFIiA8PENBRERZCnsKICAgIGVtYWlsICR7QUNNRV9FTUFJTH0KfQok
e0RPTUFJTn06ODQ0MyB7CiAgICBAd3MgcGF0aCAke1dTX1BBVEh9ICR7V1NfUEFUSH0vKgogICAg
aGFuZGxlIEB3cyB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1MwogICAgfQog
ICAgQHhoIHBhdGggJHtYSFRUUF9QQVRIfSAke1hIVFRQX1BBVEh9LyoKICAgIGhhbmRsZSBAeGgg
ewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjIwNTQgewogICAgICAgICAgICBmbHVz
aF9pbnRlcnZhbCAtMQogICAgICAgIH0KICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAgcmV2ZXJz
ZV9wcm94eSAxMjcuMC4wLjE6ODA4MAogICAgfQp9CkNBRERZCmlmIGRvY2tlciBleGVjICIkQ0FE
RFlfQ1RSIiBjYWRkeSB2YWxpZGF0ZSAtLWNvbmZpZyAvZXRjL2NhZGR5L0NhZGR5ZmlsZSA+L2Rl
di9udWxsIDI+JjE7IHRoZW4KICBkb2NrZXIgZXhlYyAiJENBRERZX0NUUiIgY2FkZHkgcmVsb2Fk
IC0tY29uZmlnIC9ldGMvY2FkZHkvQ2FkZHlmaWxlICYmIGVjaG8gIiAgY2FkZHkgcmVsb2FkIE9L
IiBcCiAgICB8fCB7IGVjaG8gIiAgcmVsb2FkINC90LUg0L/RgNC+0YjRkdC7IOKAlCDRgNC10YHR
gtCw0YDRgiI7IGRvY2tlciByZXN0YXJ0ICIkQ0FERFlfQ1RSIjsgfQplbHNlCiAgZWNobyAiICB2
YWxpZGF0ZSDQvdC10LTQvtGB0YLRg9C/0LXQvSDigJQg0YDQtdGB0YLQsNGA0YIiOyBkb2NrZXIg
cmVzdGFydCAiJENBRERZX0NUUiIKZmkKCmVjaG8gIj09IFs1LzVdINCf0YDQvtCy0LXRgNC60LAg
0YfQtdGA0LXQtyDRgdCw0LwgQ2FkZHkgKDg0NDMsINCyINC+0LHRhdC+0LQgUmVhbGl0eSkgPT0i
CnNsZWVwIDMKZm9yIHAgaW4gLyAvcHJpY2luZyAvc3RhdHVzOyBkbwogIHByaW50ZiAiICAlLTEw
cyAiICIkcCIKICBmb3IgX2kgaW4gMSAyIDM7IGRvCiAgICBjb2RlPSQoY3VybCAtc2sgLW8gL2Rl
di9udWxsIC13ICcle2h0dHBfY29kZX0nIC0tcmVzb2x2ZSAiJHtET01BSU59Ojg0NDM6MTI3LjAu
MC4xIiAiaHR0cHM6Ly8ke0RPTUFJTn06ODQ0MyRwIiAyPi9kZXYvbnVsbCkgfHwgY29kZT0iMDAw
IgogICAgWyAiJGNvZGUiICE9ICIwMDAiIF0gJiYgeyBlY2hvICIkY29kZSI7IGJyZWFrOyB9CiAg
ICBbICIkX2kiID0gIjMiIF0gJiYgZWNobyAiMDAwIChDYWRkeSDQtdGJ0ZEg0L/QtdGA0LXQt9Cw
0LPRgNGD0LbQsNC10YLRgdGPIOKAlCDQvdC+0YDQvNCwKSIKICAgIHNsZWVwIDIKICBkb25lCmRv
bmUKZWNobwplY2hvICLinIUgQEBSRUxBWV9OQU1FQEAg0YLQtdC/0LXRgNGMINC+0YLQtNCw0ZHR
giDRgtC+0YIg0LbQtSDCq0BAQlJBTkRAQCBDbG91ZMK7LCDRh9GC0L4g0LggQEBFWElUX05BTUVA
QC4iCmVjaG8gItCh0L3QsNGA0YPQttC4IChWUE4g0JLQq9Ca0JspOiBjdXJsLmV4ZSAtc0kgaHR0
cHM6Ly9AQFJFTEFZX0RPTUFJTkBAL3ByaWNpbmciCmVjaG8gItCe0YLQutCw0YIgQ2FkZHk6IGNw
IFwiJENBRERZRklMRS5iYWsuJHRzXCIgXCIkQ0FERFlGSUxFXCIgJiYgZG9ja2VyIHJlc3RhcnQg
JENBRERZX0NUUiIK
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
IDQ0My91ZHAgMjIyMi90Y3AgNTYwMDAvdWRwIDU2MDAxL3VkcDsgZG8gdWZ3IGFsbG93ICIkcCIg
Pi9kZXYvbnVsbDsgZG9uZQp1ZncgLS1mb3JjZSBlbmFibGUgPi9kZXYvbnVsbApvayAi0J7RgtC6
0YDRi9GC0Ys6IDIyLDgwLDQ0My90Y3AgwrcgNDQzL3VkcCDCtyAyMjIyL3RjcCjQvdC+0LTQsCkg
wrcgNTYwMDAsNTYwMDEvdWRwKFdEVFQpIgoKIyAtLS0gNC4g0J/QsNC90LXQu9GMIC0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQps
b2cgIjQvNiDQn9Cw0L3QtdC70YwgUmVtbmF3YXZlIgpjZCAiJEJBU0UvcGFuZWwiCltbIC1mIGRv
Y2tlci1jb21wb3NlLnltbCBdXSB8fCBjdXJsIC1mc1NMIC1vIGRvY2tlci1jb21wb3NlLnltbCBc
CiAgaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL3JlbW5hd2F2ZS9iYWNrZW5kL3Jl
ZnMvaGVhZHMvbWFpbi9kb2NrZXItY29tcG9zZS1wcm9kLnltbAppZiBbWyAhIC1mIC5lbnYgXV07
IHRoZW4KICBjdXJsIC1mc1NMIC1vIC5lbnYgaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQu
Y29tL3JlbW5hd2F2ZS9iYWNrZW5kL3JlZnMvaGVhZHMvbWFpbi8uZW52LnNhbXBsZQogIHNlZCAt
aSAicy9eSldUX0FVVEhfU0VDUkVUPS4qL0pXVF9BVVRIX1NFQ1JFVD0kKG9wZW5zc2wgcmFuZCAt
aGV4IDY0KS8iIC5lbnYKICBzZWQgLWkgInMvXkpXVF9BUElfVE9LRU5TX1NFQ1JFVD0uKi9KV1Rf
QVBJX1RPS0VOU19TRUNSRVQ9JChvcGVuc3NsIHJhbmQgLWhleCA2NCkvIiAuZW52CiAgc2VkIC1p
ICJzL15NRVRSSUNTX1BBU1M9LiovTUVUUklDU19QQVNTPSQob3BlbnNzbCByYW5kIC1oZXggNjQp
LyIgLmVudgogIHNlZCAtaSAicy9eV0VCSE9PS19TRUNSRVRfSEVBREVSPS4qL1dFQkhPT0tfU0VD
UkVUX0hFQURFUj0kKG9wZW5zc2wgcmFuZCAtaGV4IDY0KS8iIC5lbnYKICBQRz0kKG9wZW5zc2wg
cmFuZCAtaGV4IDI0KQogIHNlZCAtaSAicy9eUE9TVEdSRVNfUEFTU1dPUkQ9LiovUE9TVEdSRVNf
UEFTU1dPUkQ9JFBHLyIgLmVudgogIHNlZCAtaSAic3xeXChEQVRBQkFTRV9VUkw9XCJwb3N0Z3Jl
c3FsOi8vcG9zdGdyZXM6XClbXkBdKlwoQC4qXCl8XDEkUEdcMnwiIC5lbnYKICBvayAiLmVudiDR
gdC+0LfQtNCw0L0sINGB0LXQutGA0LXRgtGLINGB0LPQtdC90LXRgNC40YDQvtCy0LDQvdGLIgpl
bHNlIG9rICIuZW52INGD0LbQtSDQtdGB0YLRjCwg0L3QtSDRgtGA0L7Qs9Cw0Y4iOyBmaQpkb2Nr
ZXIgY29tcG9zZSB1cCAtZApvayAi0J/QsNC90LXQu9GMINC90LAgMTI3LjAuMC4xOjMwMDAiCgoj
IC0tLSA1LiDQn9C+0LTQv9C40YHQutCwICjQs9C+0YLQvtCy0YvQuSDQvtCx0YDQsNC3OyDQvdC1
INC60YDQuNGC0LjRh9C90L4sINC10YHQu9C4INC90LUg0LLRgdGC0LDQvdC10YIpIC0tLS0tLS0t
LS0tLS0tLQpsb2cgIjUvNiDQodGC0YDQsNC90LjRhtCwINC/0L7QtNC/0LjRgdC60LgiCmNkICIk
QkFTRS9zdWIiCmNhdCA+IGRvY2tlci1jb21wb3NlLnltbCA8PCdFT0YnCnNlcnZpY2VzOgogIHJl
bW5hd2F2ZS1zdWJzY3JpcHRpb24tcGFnZToKICAgIGltYWdlOiByZW1uYXdhdmUvc3Vic2NyaXB0
aW9uLXBhZ2U6bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogcmVtbmF3YXZlLXN1YnNjcmlwdGlv
bi1wYWdlCiAgICByZXN0YXJ0OiBhbHdheXMKICAgIGVudl9maWxlOiAuZW52CiAgICBwb3J0czoK
ICAgICAgLSAnMTI3LjAuMC4xOjMwMTA6MzAxMCcKICAgIG5ldHdvcmtzOgogICAgICAtIHJlbW5h
d2F2ZS1uZXR3b3JrCm5ldHdvcmtzOgogIHJlbW5hd2F2ZS1uZXR3b3JrOgogICAgZXh0ZXJuYWw6
IHRydWUKICAgIG5hbWU6IHJlbW5hd2F2ZS1uZXR3b3JrCkVPRgpbWyAtZiAuZW52IF1dIHx8IGNh
dCA+IC5lbnYgPDwnRU9GJwpBUFBfUE9SVD0zMDEwClJFTU5BV0FWRV9QQU5FTF9VUkw9aHR0cDov
L3JlbW5hd2F2ZTozMDAwCk1FVEFfVElUTEU9TXlTcGhlcmUKRU9GCmRvY2tlciBjb21wb3NlIHVw
IC1kIHx8IHdhcm4gInN1Yi1wYWdlINC90LUg0LLRgdGC0LDQu9CwIOKAlCDQvdC1INC60YDQuNGC
0LjRh9C90L4g0YHQtdC50YfQsNGBICjQvdGD0LbQvdCwINC/0L7Qt9C20LUg0LTQu9GPIFFSKS4i
Cm9rICLQn9C+0LTQv9C40YHQutCwICjQv9C+0L/Ri9GC0LrQsCkg0L3QsCAxMjcuMC4wLjE6MzAx
MCIKCiMgLS0tIDYuIENhZGR5INCd0JAgNDQzICsgUmVhbGl0eS3QutC70Y7Rh9C4ICsg0L/RgNC+
0YTQuNC70YwgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjYvNiBDYWRkeSDQ
vdCwIDQ0MyArINC60LvRjtGH0LggKyDQv9GA0L7RhNC40LvRjCIKaWYgW1sgLWYgIiRCQVNFL2Nh
ZGR5L0NhZGR5ZmlsZSIgXV0gJiYgZ3JlcCAtcSAnODQ0MycgIiRCQVNFL2NhZGR5L0NhZGR5Zmls
ZSIgJiYgZ3JlcCAtcSAiJHtET01BSU59IiAiJEJBU0UvY2FkZHkvQ2FkZHlmaWxlIjsgdGhlbgog
IG9rICJDYWRkeSDRg9C20LUg0L3QsCA4NDQzINC00LvRjyAke0RPTUFJTn0gKGhhbmRvZmYvc3Rl
YWx0aCDQv9GA0LjQvNC10L3RkdC9KSDigJQgQ2FkZHlmaWxlINC90LUg0YLRgNC+0LPQsNGOICjQ
uNC90LDRh9C1INGB0LvQvtC80LDRjiDRgdGC0LXQu9GBINC4INC/0L7QtNC10YDRg9GB0Ywg0YEg
WHJheSDQt9CwIDQ0MykiCmVsc2UKY2F0ID4gIiRCQVNFL2NhZGR5L0NhZGR5ZmlsZSIgPDxFT0YK
JHtET01BSU59IHsKICAgIGhhbmRsZV9wYXRoICR7U1VCX1BBVEh9LyogewogICAgICAgIHJldmVy
c2VfcHJveHkgMTI3LjAuMC4xOjMwMTAKICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAgcmV2ZXJz
ZV9wcm94eSAxMjcuMC4wLjE6MzAwMAogICAgfQp9CkVPRgpmaQpjYXQgPiAiJEJBU0UvY2FkZHkv
ZG9ja2VyLWNvbXBvc2UueW1sIiA8PCdFT0YnCnNlcnZpY2VzOgogIGNhZGR5OgogICAgaW1hZ2U6
IGNhZGR5OjIKICAgIGNvbnRhaW5lcl9uYW1lOiBAQFNMVUdAQC1jYWRkeQogICAgcmVzdGFydDog
YWx3YXlzCiAgICBuZXR3b3JrX21vZGU6IGhvc3QKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9DYWRk
eWZpbGU6L2V0Yy9jYWRkeS9DYWRkeWZpbGU6cm8KICAgICAgLSBjYWRkeV9kYXRhOi9kYXRhCiAg
ICAgIC0gY2FkZHlfY29uZmlnOi9jb25maWcKdm9sdW1lczoKICBjYWRkeV9kYXRhOgogIGNhZGR5
X2NvbmZpZzoKRU9GCmNkICIkQkFTRS9jYWRkeSIgJiYgZG9ja2VyIGNvbXBvc2UgdXAgLWQKb2sg
IkNhZGR5INC30LDQv9GD0YnQtdC9ICjRgdCy0LXQttC40Lkg0LHQvtC60YE6INC/0LDQvdC10LvR
jCDQvdCwIGh0dHBzOi8vJHtET01BSU59Lzsg0LfQsNGB0YLQtdC70YHQtdC90L3Ri9C5OiDQv9Cw
0L3QtdC70Ywg0LLQvdGD0YLRgNC4IGxvY2FsaG9zdDo4MDgxKSIKCmlmIFtbICEgLWYgIiRCQVNF
L25vZGUvcmVhbGl0eS5lbnYiIF1dOyB0aGVuCiAgS0VZUz0kKGRvY2tlciBydW4gLS1ybSBnaGNy
LmlvL3h0bHMveHJheS1jb3JlOmxhdGVzdCB4MjU1MTkgMj4vZGV2L251bGwgfHwgdHJ1ZSkKICBQ
UklWPSQoZWNobyAiJEtFWVMiIHwgZ3JlcCAtaUUgJ3ByaXZhdGUnIHwgYXdrICd7cHJpbnQgJE5G
fScpCiAgUFVCPSQoZWNobyAgIiRLRVlTIiB8IGdyZXAgLWlFICdwdWJsaWN8cGFzc3dvcmQnIHwg
YXdrICd7cHJpbnQgJE5GfScpCiAgU0lEPSQob3BlbnNzbCByYW5kIC1oZXggOCkKICBpZiBbWyAt
eiAiJFBSSVYiIHx8IC16ICIkUFVCIiBdXTsgdGhlbgogICAgd2FybiAi0J3QtSDRgNCw0YHQv9Cw
0YDRgdC40Lsg0LrQu9GO0YfQuCBSZWFsaXR5LiDQktGA0YPRh9C90YPRjjogZG9ja2VyIHJ1biAt
LXJtIGdoY3IuaW8veHRscy94cmF5LWNvcmU6bGF0ZXN0IHgyNTUxOSIKICAgIFBSSVY9ItCS0KHQ
otCQ0JLQrF9QUklWQVRFIjsgUFVCPSLQktCh0KLQkNCS0KxfUFVCTElDIgogIGZpCiAgY2F0ID4g
IiRCQVNFL25vZGUvcmVhbGl0eS5lbnYiIDw8RU9GClJFQUxJVFlfUFJJVkFURV9LRVk9JFBSSVYK
UkVBTElUWV9QVUJMSUNfS0VZPSRQVUIKUkVBTElUWV9TSE9SVF9JRD0kU0lECkVPRgogIG9rICJS
ZWFsaXR5LdC60LvRjtGH0Lgg0LIgJEJBU0Uvbm9kZS9yZWFsaXR5LmVudiIKZmkKc291cmNlICIk
QkFTRS9ub2RlL3JlYWxpdHkuZW52IgoKY2F0ID4gIiRCQVNFL25vZGUveHJheS1wcm9maWxlLmpz
b24iIDw8RU9GCnsKICAiaW5ib3VuZHMiOiBbCiAgICB7ICJ0YWciOiAiVkxFU1MtUkVBTElUWSIs
ICJsaXN0ZW4iOiAiMC4wLjAuMCIsICJwb3J0IjogNDQzLCAicHJvdG9jb2wiOiAidmxlc3MiLAog
ICAgICAic2V0dGluZ3MiOiB7ICJjbGllbnRzIjogW10sICJkZWNyeXB0aW9uIjogIm5vbmUiLCAi
ZmFsbGJhY2tzIjogWyB7ICJkZXN0IjogIjEyNy4wLjAuMTo4NDQzIiB9IF0gfSwKICAgICAgInN0
cmVhbVNldHRpbmdzIjogeyAibmV0d29yayI6ICJ0Y3AiLCAic2VjdXJpdHkiOiAicmVhbGl0eSIs
CiAgICAgICAgInJlYWxpdHlTZXR0aW5ncyI6IHsgInNob3ciOiBmYWxzZSwgImRlc3QiOiAiMTI3
LjAuMC4xOjg0NDMiLCAic2VydmVyTmFtZXMiOiBbIiR7RE9NQUlOfSJdLAogICAgICAgICAgInBy
aXZhdGVLZXkiOiAiJHtSRUFMSVRZX1BSSVZBVEVfS0VZfSIsICJzaG9ydElkcyI6IFsiJHtSRUFM
SVRZX1NIT1JUX0lEfSJdIH0gfSwKICAgICAgInNuaWZmaW5nIjogeyAiZW5hYmxlZCI6IHRydWUs
ICJkZXN0T3ZlcnJpZGUiOiBbImh0dHAiLCJ0bHMiLCJxdWljIl0gfSB9LAogICAgeyAidGFnIjog
IlZMRVNTLVdTIiwgImxpc3RlbiI6ICIxMjcuMC4wLjEiLCAicG9ydCI6IDIwNTMsICJwcm90b2Nv
bCI6ICJ2bGVzcyIsCiAgICAgICJzZXR0aW5ncyI6IHsgImNsaWVudHMiOiBbXSwgImRlY3J5cHRp
b24iOiAibm9uZSIgfSwKICAgICAgInN0cmVhbVNldHRpbmdzIjogeyAibmV0d29yayI6ICJ3cyIs
ICJzZWN1cml0eSI6ICJub25lIiwgIndzU2V0dGluZ3MiOiB7ICJwYXRoIjogIiR7V1NfUEFUSH0i
IH0gfSB9LAogICAgeyAidGFnIjogIlZMRVNTLVhIVFRQIiwgImxpc3RlbiI6ICIxMjcuMC4wLjEi
LCAicG9ydCI6IDIwNTQsICJwcm90b2NvbCI6ICJ2bGVzcyIsCiAgICAgICJzZXR0aW5ncyI6IHsg
ImNsaWVudHMiOiBbXSwgImRlY3J5cHRpb24iOiAibm9uZSIgfSwKICAgICAgInN0cmVhbVNldHRp
bmdzIjogeyAibmV0d29yayI6ICJ4aHR0cCIsICJzZWN1cml0eSI6ICJub25lIiwKICAgICAgICAi
eGh0dHBTZXR0aW5ncyI6IHsgInBhdGgiOiAiJHtYSFRUUF9QQVRIfSIgfSB9IH0sCiAgICB7ICJ0
YWciOiAiSFlTVEVSSUEyIiwgImxpc3RlbiI6ICIwLjAuMC4wIiwgInBvcnQiOiA0NDMsICJwcm90
b2NvbCI6ICJoeXN0ZXJpYSIsCiAgICAgICJzZXR0aW5ncyI6IHsgImNsaWVudHMiOiBbXSB9LAog
ICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogImh5c3RlcmlhIiwgInNlY3VyaXR5
IjogInRscyIsCiAgICAgICAgInRsc1NldHRpbmdzIjogeyAiYWxwbiI6IFsiaDMiXSwgImNlcnRp
ZmljYXRlcyI6IFsgeyAiY2VydGlmaWNhdGVGaWxlIjogIi9jZXJ0cy9oeTIuY3J0IiwgImtleUZp
bGUiOiAiL2NlcnRzL2h5Mi5rZXkiIH0gXSB9LAogICAgICAgICJoeXN0ZXJpYVNldHRpbmdzIjog
eyAidmVyc2lvbiI6IDIsICJ1ZHBJZGxlVGltZW91dCI6IDYwIH0gfSB9CiAgXSwKICAib3V0Ym91
bmRzIjogWwogICAgeyAidGFnIjogImRpcmVjdCIsICJwcm90b2NvbCI6ICJmcmVlZG9tIiwgInNl
dHRpbmdzIjogeyAiZG9tYWluU3RyYXRlZ3kiOiAiVXNlSVB2NCIgfSB9LAogICAgeyAidGFnIjog
ImJsb2NrIiwgInByb3RvY29sIjogImJsYWNraG9sZSIgfQogIF0sCiAgImRucyI6IHsgInNlcnZl
cnMiOiBbIjEuMS4xLjEiLCI4LjguOC44Il0sICJxdWVyeVN0cmF0ZWd5IjogIlVzZUlQdjQiIH0s
CiAgInJvdXRpbmciOiB7ICJkb21haW5TdHJhdGVneSI6ICJJUElmTm9uTWF0Y2giLCAicnVsZXMi
OiBbXSB9Cn0KRU9GCm9rICLQn9GA0L7RhNC40LvRjCDQs9C+0YLQvtCyOiAkQkFTRS9ub2RlL3hy
YXktcHJvZmlsZS5qc29uIgoKY2F0IDw8RU9GCgo9PT09PT09PT09PT09PT09PT09PT09PT0gINCk
0JDQl9CQIDEg0JPQntCi0J7QktCQICA9PT09PT09PT09PT09PT09PT09PT09PT0K0J/QsNC90LXQ
u9GMINC+0YLQutGA0YvQstCw0LXRgtGB0Y8g0L/QvjogIGh0dHBzOi8vJHtET01BSU59LyAgIChD
YWRkeSDQvdCwIDQ0MykK0J/QvtC00L7QttC00LggfjMwINGB0LXQuiDQvdCwINCy0YvQv9GD0YHQ
uiDRgdC10YDRgtC40YTQuNC60LDRgtCwLgoK0JTQsNC70YzRiNC1INCg0KPQmtCQ0JzQmCDQsiDQ
v9Cw0L3QtdC70LgsINC/0L4g0L/QvtGA0Y/QtNC60YM6CiAgQS4gaHR0cHM6Ly8ke0RPTUFJTn0v
ICAtPiDRgdC+0LfQtNCw0Lkg0LDQtNC80LjQvdCwLgogIEIuINCd0L7QtNGLIC0+INCh0L7Qt9C0
0LDRgtGMOiDQuNC80Y8gbW9vbmxpZ2h0LWV4aXQsINCw0LTRgNC10YEgJHtNWUlQfSwgTm9kZSBQ
b3J0IDIyMjIuCiAgICAgU0VDUkVUX0tFWSDQutC+0L/QuNGA0YPQuSDQmtCd0J7Qn9Ca0J7QmS3Q
mNCa0J7QndCa0J7QmSAo0L/QvtC70LUg0L7QsdGA0LXQt9Cw0L3Qviwg0LzRi9GI0LrQvtC5INC9
0LUg0LLRi9C00LXQu9GP0YLRjCEpLgogIEMuINCf0YDQvtGE0LjQu9C4IC0+IERlZmF1bHQtUHJv
ZmlsZSAtPiAi0JrQvtC90YTQuNCzLiBYcmF5IjoKICAgICBDdHJsK0EgLT4gRGVsZXRlIC0+INCy
0YHRgtCw0LLRjCDRgdC+0LTQtdGA0LbQuNC80L7QtSAkQkFTRS9ub2RlL3hyYXktcHJvZmlsZS5q
c29uIC0+INCh0L7RhdGA0LDQvdC4LgogIEQuINCd0L7QtNGLIC0+IG1vb25saWdodC1leGl0IC0+
INCf0YDQvtGE0LjQu9C4IC0+INCY0LfQvNC10L3QuNGC0YwgLT4g0LLRi9Cx0LXRgNC4IERlZmF1
bHQtUHJvZmlsZQogICAgICjQvtGC0LzQtdGC0Ywg0LLRgdC1IDQg0LjQvdCx0LDRg9C90LTQsCwg
0LLQutC7LiBIWVNURVJJQTIpIC0+INCy0L3QuNC30YMg0KHQvtGF0YDQsNC90LjRgtGMLiAo0J/R
gNC+0YTQuNC70Ywg0J7QkdCv0JfQkNCdINCx0YvRgtGMINC/0YDQuNCy0Y/Qt9Cw0L0uKQoK0J/Q
vtGC0L7QvCDQvdCwINGB0LXRgNCy0LXRgNC1INC/0L4g0L7Rh9C10YDQtdC00Lg6CiAgRS4gc3Vk
byBiYXNoIGRlcGxveS1ub2RlLW1vb25saWdodC5zaCAgICAgKNC/0L7QtNC90LjQvNC10YIg0L3Q
vtC00YM7IFNFQ1JFVF9LRVkg0LLRgdGC0LDQstC40YjRjCDQsiBuYW5vKQogIEYuIHN1ZG8gYmFz
aCBoYW5kb2ZmLW1vb25saWdodC5zaCAgICAgICAgIChDYWRkeSAtPiA4NDQzLCA0NDMg0L7RgtC0
0LDRkdC8INC90L7QtNC1LCDRgSDQsNCy0YLQvtC+0YLQutCw0YLQvtC8KQogIEcuIHN1ZG8gYmFz
aCBzeW5jLWh5Mi1jZXJ0LnNoICAgICAgICAgICAgICjQv9C+0LvQvtC20LjRgtGMIExFLdGB0LXR
gNGCINCyIG5vZGUvY2VydHMg0LTQu9GPIEh5c3RlcmlhMikKCtCa0LvRjtGH0LggUmVhbGl0eSDQ
tNC70Y8g0LHRg9C00YPRidC10LPQviBAQFJFTEFZX05BTUVAQDogJEJBU0Uvbm9kZS9yZWFsaXR5
LmVudgo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PQpFT0YK
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
IyEvdXNyL2Jpbi9lbnYgYmFzaAojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIGRlcGxveS1zdW5z
aGluZS5zaCAg4oCUICBAQFJFTEFZX05BTUVAQCAoQEBSRUxBWV9ET01BSU5AQCkgINCk0JDQl9CQ
IDEgIFvQoNCV0KLQoNCQ0J3QodCb0K/QotCe0KBdCiMgIEBAUkVMQVlfTkFNRUBAINC/0YDQvtGJ
0LUgQEBFWElUX05BTUVAQDog0L/QsNC90LXQu9C4INC90LXRgiAtPiDRhdC10L3QtNC+0YTRhCDQ
ndCVINC90YPQttC10L0uCiMgIENhZGR5INGB0YDQsNC30YMg0L3QsCA4NDQzICjRgdC10YDRgiDR
h9C10YDQtdC3INC/0L7RgNGCIDgwKSwg0L3QvtC00LAgUmVhbGl0eSDQsdC10YDRkdGCIDQ0MyDR
h9C40YHRgtC+LgojICDQktC10YHRjCDQutC70LjQtdC90YLRgdC60LjQuSDRgtGA0LDRhNC40Log
0LrQsNGB0LrQsNC00L7QvCDRg9GF0L7QtNC40YIg0L3QsCBAQEVYSVRfTkFNRUBAICjQstGL0YXQ
vtC0ID0gSVAgQEBFWElUX05BTUVAQCkuCiMgINCX0LDQv9GD0YHQujogIHN1ZG8gYmFzaCBkZXBs
b3ktc3Vuc2hpbmUuc2gKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQpzZXQgLWV1byBwaXBlZmFpbApv
aygpeyAgZWNobyAiICDinJMgJCoiOyB9Cndhcm4oKXsgZWNobyAiICAhICQqIjsgfQpkaWUoKXsg
ZWNobyAiICDinJcgJCoiID4mMjsgZXhpdCAxOyB9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSDQndCQ0KHQotCg0J7QmdCa0JggLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tCkRPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIiAgICAgICAgICAgICAgICAgICMg0LTQvtC8
0LXQvSBAQFJFTEFZX05BTUVAQCAoQS3Qt9Cw0L/QuNGB0YwgLT4gSVAgQEBSRUxBWV9OQU1FQEAp
CkFDTUVfRU1BSUw9IkBAQUNNRV9FTUFJTEBAIgpXU19QQVRIPSIvd3NuZyIKWEhUVFBfUEFUSD0i
L3hoIgojIC0tLSDQv9Cw0YDQsNC80LXRgtGA0Ysg0LrQsNGB0LrQsNC00LAg0L3QsCBAQEVYSVRf
TkFNRUBAICjQstGL0YXQvtC00L3QvtC5INGB0LXRgNCy0LXRgCkgLS0tCk1PT05fSVA9IiR7RVhJ
VF9JUDotQEBFWElUX0lQQEB9IgpNT09OX1NOST0iJHtSRUxBWV9ET01BSU46LUBAUkVMQVlfRE9N
QUlOQEB9IgojIFJlYWxpdHkt0LrQu9GO0YfQuCBNb29ubGlnaHQg0LggVVVJRCDRgdC10YDQstC4
0YEt0Y7Qt9C10YDQsCDQsdC10YDRkdC8INC40LcgcmVsYXktYm9vdHN0cmFwLmVudiAocHJvdmlz
aW9uLXJlbGF5LnNoKQpCT09UU1RSQVA9IiR7UkVMQVlfQk9PVFNUUkFQOi0vb3B0LyRCQVNFL3Jl
bGF5LWJvb3RzdHJhcC5lbnZ9IgpbIC1mICIkQk9PVFNUUkFQIiBdIHx8IEJPT1RTVFJBUD0iJChm
aW5kIC9vcHQgLW5hbWUgJ3JlbGF5LWJvb3RzdHJhcC5lbnYnIDI+L2Rldi9udWxsIHwgaGVhZCAt
MSkiCmlmIFsgLWYgIiRCT09UU1RSQVAiIF07IHRoZW4KICBzb3VyY2UgIiRCT09UU1RSQVAiCiAg
TU9PTl9QVUJLRVk9IiR7TU9PTl9QVUJLRVk6LX0iCiAgTU9PTl9TSE9SVElEPSIke01PT05fU0hP
UlRJRDotfSIKICBTRVJWSUNFX1VVSUQ9IiR7U0VSVklDRV9VVUlEOi19IgogICMgUmVhbGl0eS3Q
utC70Y7Rh9C4IFN1bnNoaW5lINGC0L7QttC1INC80L7Qs9GD0YIg0LHRi9GC0Ywg0LIgYm9vdHN0
cmFwCiAgUkVMQVlfUFJJVj0iJHtSRUxBWV9QUklWOi19IgogIFJFTEFZX1BVQj0iJHtSRUxBWV9Q
VUI6LX0iCiAgUkVMQVlfU0lEPSIke1JFTEFZX1NJRDotfSIKICBvayAicmVsYXktYm9vdHN0cmFw
LmVudiDQt9Cw0LPRgNGD0LbQtdC9IgplbHNlCiAgd2FybiAicmVsYXktYm9vdHN0cmFwLmVudiDQ
vdC1INC90LDQudC00LXQvSDigJQg0LjRgdC/0L7Qu9GM0LfRg9GO0YLRgdGPINC30LDRhdCw0YDQ
tNC60L7QttC10L3QvdGL0LUg0LrQu9GO0YfQuCAo0YPRgdGC0LDRgNC10LLRiNC40LUhKSIKICBN
T09OX1BVQktFWT0iQEBNT09OX1BVQktFWV9QTEFDRUhPTERFUkBAIgogIE1PT05fU0hPUlRJRD0i
QEBNT09OX1NIT1JUSURfUExBQ0VIT0xERVJAQCIKICBTRVJWSUNFX1VVSUQ9IiIKICBSRUxBWV9Q
UklWPSIiOyBSRUxBWV9QVUI9IiI7IFJFTEFZX1NJRD0iIgpmaQojIC0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tCgpCQVNFPS9vcHQvQEBTTFVHQEAKbG9nKCl7IGVjaG8gLWUgIlxuXDAzM1sxOzM2bT09PiAk
KlwwMzNbMG0iOyB9Cm9rKCl7ICBlY2hvIC1lICJcMDMzWzE7MzJtICBPSyAkKlwwMzNbMG0iOyB9
Cndhcm4oKXsgZWNobyAtZSAiXDAzM1sxOzMzbSAgISAkKlwwMzNbMG0iOyB9CgpbWyAkRVVJRCAt
ZXEgMCBdXSB8fCB7IGVjaG8gItCX0LDQv9GD0YHRgtC4INGH0LXRgNC10Lcgc3Vkbzogc3VkbyBi
YXNoICQwIjsgZXhpdCAxOyB9CmNvbW1hbmQgLXYgYXB0LWdldCA+L2Rldi9udWxsIHx8IHsgZWNo
byAi0J3Rg9C20LXQvSBVYnVudHUvRGViaWFuIChhcHQpLiI7IGV4aXQgMTsgfQpta2RpciAtcCAi
JEJBU0UiL3tjYWRkeSxub2RlLGRlY295fQoKIyAtLS0gMC4g0J/QsNC60LXRgtGLICsgRE5TIC0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQps
b2cgIjAvNSDQn9Cw0LrQtdGC0Ysg0LggRE5TIgpleHBvcnQgREVCSUFOX0ZST05URU5EPW5vbmlu
dGVyYWN0aXZlCmFwdC1nZXQgdXBkYXRlIC15ID4vZGV2L251bGwKYXB0LWdldCBpbnN0YWxsIC15
IGN1cmwgb3BlbnNzbCBjYS1jZXJ0aWZpY2F0ZXMgPi9kZXYvbnVsbApNWUlQPSQoY3VybCAtZnNT
NCBodHRwczovL2FwaS5pcGlmeS5vcmcgMj4vZGV2L251bGwgfHwgaG9zdG5hbWUgLUkgfCBhd2sg
J3twcmludCAkMX0nKQpETlNJUD0kKGdldGVudCBhaG9zdHN2NCAiJERPTUFJTiIgfCBhd2sgJ3tw
cmludCAkMTsgZXhpdH0nIHx8IHRydWUpCmlmIFtbIC1uICIkTVlJUCIgJiYgIiRETlNJUCIgPT0g
IiRNWUlQIiBdXTsgdGhlbgogIG9rICJETlM6ICRET01BSU4gLT4gJE1ZSVAgKNGN0YLQviBAQFJF
TEFZX05BTUVAQCkiCmVsc2UKICB3YXJuICLQlNC+0LzQtdC9ICRET01BSU4g0YPQutCw0LfRi9Cy
0LDQtdGCINC90LAgJyR7RE5TSVA6LdC90LjRh9C10LPQvn0nLCDQsCDRgdC10YDQstC10YAgJyRN
WUlQJy4iCiAgd2FybiAi0J3Rg9C20L3QsCBBLdC30LDQv9C40YHRjDogJERPTUFJTiAtPiAkTVlJ
UCAoRE5TIG9ubHkpLiDQkdC10Lcg0L3QtdGRINGB0LXRgNGCINC90LUg0LLRi9C/0YPRgdGC0LjR
gtGB0Y8uIgogIHdhcm4gItCf0YDQvtC00L7Qu9C20YMg0YfQtdGA0LXQtyAxNSDRgdC10Lo7INC/
0L7RgtC+0Lwg0L/QtdGA0LXQt9Cw0L/Rg9GB0YLQuCDRgdC60YDQuNC/0YIuIgogIHNsZWVwIDE1
CmZpCgojIC0tLSAxLiBEb2NrZXIgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmxvZyAiMS81IERvY2tlciIKaWYgY29tbWFuZCAt
diBkb2NrZXIgPi9kZXYvbnVsbCAmJiBkb2NrZXIgY29tcG9zZSB2ZXJzaW9uID4vZGV2L251bGwg
Mj4mMTsgdGhlbiBvayAiRG9ja2VyINGD0LbQtSDRgdGC0L7QuNGCIgplbHNlIGN1cmwgLWZzU0wg
aHR0cHM6Ly9nZXQuZG9ja2VyLmNvbSB8IHNoOyBvayAiRG9ja2VyINGD0YHRgtCw0L3QvtCy0LvQ
tdC9IjsgZmkKCiMgLS0tIDIuIElQdjYgb2ZmICsg0YTQvtGA0LLQsNGA0LTQuNC90LMgLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCmxvZyAiMi81IElQdjYg
b2ZmICsgaXBfZm9yd2FyZCIKY2F0ID4vZXRjL3N5c2N0bC5kLzk5LUBAU0xVR0BALmNvbmYgPDwn
RU9GJwpuZXQuaXB2Ni5jb25mLmFsbC5kaXNhYmxlX2lwdjYgPSAxCm5ldC5pcHY2LmNvbmYuZGVm
YXVsdC5kaXNhYmxlX2lwdjYgPSAxCm5ldC5pcHY2LmNvbmYubG8uZGlzYWJsZV9pcHY2ID0gMQpu
ZXQuaXB2NC5pcF9mb3J3YXJkID0gMQpFT0YKc3lzY3RsIC0tc3lzdGVtID4vZGV2L251bGwKb2sg
IklQdjYg0LLRi9C60LvRjtGH0LXQvSIKCiMgLS0tIDMuIFVGVyAtLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KbG9nICIzLzUg
RmlyZXdhbGwiCmFwdC1nZXQgaW5zdGFsbCAteSB1ZncgPi9kZXYvbnVsbAp1ZncgLS1mb3JjZSBy
ZXNldCA+L2Rldi9udWxsCnVmdyBkZWZhdWx0IGRlbnkgaW5jb21pbmcgPi9kZXYvbnVsbAp1Zncg
ZGVmYXVsdCBhbGxvdyBvdXRnb2luZyA+L2Rldi9udWxsCmZvciBwIGluIDIyL3RjcCA4MC90Y3Ag
NDQzL3RjcCA0NDMvdWRwIDIyMjIvdGNwOyBkbyB1ZncgYWxsb3cgIiRwIiA+L2Rldi9udWxsOyBk
b25lCnVmdyAtLWZvcmNlIGVuYWJsZSA+L2Rldi9udWxsCm9rICLQntGC0LrRgNGL0YLRizogMjIs
ODAsNDQzL3RjcCDCtyA0NDMvdWRwIMK3IDIyMjIvdGNwKNC90L7QtNCwKSIKCiMgLS0tIDQuIENh
ZGR5INC90LAgODQ0MyAo0LTQtdC60L7QuSArIHdzL3hodHRwKSwg0YHQtdGA0YIg0YfQtdGA0LXQ
tyDQv9C+0YDRgiA4MCAtLS0tLS0tLS0tLS0tLS0tLQpsb2cgIjQvNSBDYWRkeSDQvdCwIDg0NDMg
KyDQtNC10LrQvtC5IgpjYXQgPiAiJEJBU0UvZGVjb3kvaW5kZXguaHRtbCIgPDwnRU9GJwo8IWRv
Y3R5cGUgaHRtbD48aHRtbCBsYW5nPSJydSI+PGhlYWQ+PG1ldGEgY2hhcnNldD0idXRmLTgiPgo8
bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLGluaXRpYWwt
c2NhbGU9MSI+Cjx0aXRsZT5NeVNwaGVyZSDigJQg0L7QsdC70LDRh9C90L7QtSDRhdGA0LDQvdC4
0LvQuNGJ0LU8L3RpdGxlPgo8c3R5bGU+Ym9keXtmb250LWZhbWlseTpzeXN0ZW0tdWksQXJpYWws
c2Fucy1zZXJpZjtiYWNrZ3JvdW5kOiMwZjEyMjE7Y29sb3I6I2U4ZWFmMjsKZGlzcGxheTpmbGV4
O21pbi1oZWlnaHQ6MTAwdmg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50
ZXI7bWFyZ2luOjB9Ci5je3RleHQtYWxpZ246Y2VudGVyO21heC13aWR0aDo1MjBweDtwYWRkaW5n
OjQwcHh9aDF7Zm9udC1zaXplOjJyZW07bWFyZ2luOjAgMCAuNXJlbX0KcHtvcGFjaXR5Oi43O2xp
bmUtaGVpZ2h0OjEuNn0uYntkaXNwbGF5OmlubGluZS1ibG9jazttYXJnaW4tdG9wOjE4cHg7cGFk
ZGluZzoxMHB4IDIwcHg7CmJvcmRlcjoxcHggc29saWQgIzNhM2Y1Yztib3JkZXItcmFkaXVzOjhw
eDtjb2xvcjojOWZiMGZmO3RleHQtZGVjb3JhdGlvbjpub25lfTwvc3R5bGU+CjwvaGVhZD48Ym9k
eT48ZGl2IGNsYXNzPSJjIj48aDE+TXlTcGhlcmU8L2gxPgo8cD7Qm9C40YfQvdC+0LUg0L7QsdC7
0LDRh9C90L7QtSDRhdGA0LDQvdC40LvQuNGJ0LUuINCk0LDQudC70YssINGB0LjQvdGF0YDQvtC9
0LjQt9Cw0YbQuNGPLCDQtNC+0YHRgtGD0L8g0YEg0LvRjtCx0L7Qs9C+INGD0YHRgtGA0L7QudGB
0YLQstCwLjwvcD4KPGEgY2xhc3M9ImIiIGhyZWY9Ii9sb2dpbiI+0JLQvtC50YLQuDwvYT48L2Rp
dj48L2JvZHk+PC9odG1sPgpFT0YKY2F0ID4gIiRCQVNFL2NhZGR5L0NhZGR5ZmlsZSIgPDxFT0YK
ewogICAgZW1haWwgJHtBQ01FX0VNQUlMfQp9CiR7RE9NQUlOfTo4NDQzIHsKICAgIEB3cyBwYXRo
ICR7V1NfUEFUSH0gJHtXU19QQVRIfS8qCiAgICBoYW5kbGUgQHdzIHsKICAgICAgICByZXZlcnNl
X3Byb3h5IDEyNy4wLjAuMToyMDUzCiAgICB9CiAgICBAeGggcGF0aCAke1hIVFRQX1BBVEh9ICR7
WEhUVFBfUEFUSH0vKgogICAgaGFuZGxlIEB4aCB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcu
MC4wLjE6MjA1NCB7CiAgICAgICAgICAgIGZsdXNoX2ludGVydmFsIC0xCiAgICAgICAgfQogICAg
fQogICAgaGFuZGxlIHsKICAgICAgICByb290ICogL3Nydi9kZWNveQogICAgICAgIGZpbGVfc2Vy
dmVyCiAgICB9Cn0KRU9GCmNhdCA+ICIkQkFTRS9jYWRkeS9kb2NrZXItY29tcG9zZS55bWwiIDw8
RU9GCnNlcnZpY2VzOgogIGNhZGR5OgogICAgaW1hZ2U6IGNhZGR5OjIKICAgIGNvbnRhaW5lcl9u
YW1lOiBAQFNMVUdAQC1jYWRkeQogICAgcmVzdGFydDogYWx3YXlzCiAgICBuZXR3b3JrX21vZGU6
IGhvc3QKICAgIHZvbHVtZXM6CiAgICAgIC0gLi9DYWRkeWZpbGU6L2V0Yy9jYWRkeS9DYWRkeWZp
bGU6cm8KICAgICAgLSAke0JBU0V9L2RlY295Oi9zcnYvZGVjb3k6cm8KICAgICAgLSBjYWRkeV9k
YXRhOi9kYXRhCiAgICAgIC0gY2FkZHlfY29uZmlnOi9jb25maWcKdm9sdW1lczoKICBjYWRkeV9k
YXRhOgogIGNhZGR5X2NvbmZpZzoKRU9GCmNkICIkQkFTRS9jYWRkeSIgJiYgZG9ja2VyIGNvbXBv
c2UgdXAgLWQKb2sgIkNhZGR5INC90LAgODQ0MyAo0LTQtdC60L7QuSBNeVNwaGVyZSDQsiDQutC+
0YDQvdC1KS4g0KHQtdGA0YIg0LLRi9C/0YPRgdGC0LjRgtGB0Y8g0YfQtdGA0LXQtyDQv9C+0YDR
giA4MC4iCgojIC0tLSA1LiBSZWFsaXR5LdC60LvRjtGH0LggQEBSRUxBWV9OQU1FQEAgKyDQv9GA
0L7RhNC40LvRjCDRgSDQutCw0YHQutCw0LTQvtC8IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
CmxvZyAiNS81IFJlYWxpdHkt0LrQu9GO0YfQuCBAQFJFTEFZX05BTUVAQCArINC/0YDQvtGE0LjQ
u9GMINGBINC60LDRgdC60LDQtNC+0Lwg0L3QsCBAQEVYSVRfTkFNRUBAIgppZiBbWyAhIC1mICIk
QkFTRS9ub2RlL3JlYWxpdHkuZW52IiBdXTsgdGhlbgogIEtFWVM9JChkb2NrZXIgcnVuIC0tcm0g
Z2hjci5pby94dGxzL3hyYXktY29yZTpsYXRlc3QgeDI1NTE5IDI+L2Rldi9udWxsIHx8IHRydWUp
CiAgUFJJVj0kKGVjaG8gIiRLRVlTIiB8IGdyZXAgLWlFICdwcml2YXRlJyB8IGF3ayAne3ByaW50
ICRORn0nKQogIFBVQj0kKGVjaG8gICIkS0VZUyIgfCBncmVwIC1pRSAncHVibGljfHBhc3N3b3Jk
JyB8IGF3ayAne3ByaW50ICRORn0nKQogIFNJRD0kKG9wZW5zc2wgcmFuZCAtaGV4IDgpCiAgaWYg
W1sgLXogIiRQUklWIiB8fCAteiAiJFBVQiIgXV07IHRoZW4KICAgIHdhcm4gItCd0LUg0YDQsNGB
0L/QsNGA0YHQuNC7INC60LvRjtGH0LguINCS0YDRg9GH0L3Rg9GOOiBkb2NrZXIgcnVuIC0tcm0g
Z2hjci5pby94dGxzL3hyYXktY29yZTpsYXRlc3QgeDI1NTE5IgogICAgUFJJVj0i0JLQodCi0JDQ
ktCsX1BSSVZBVEUiOyBQVUI9ItCS0KHQotCQ0JLQrF9QVUJMSUMiCiAgZmkKICBjYXQgPiAiJEJB
U0Uvbm9kZS9yZWFsaXR5LmVudiIgPDxFT0YKUkVBTElUWV9QUklWQVRFX0tFWT0kUFJJVgpSRUFM
SVRZX1BVQkxJQ19LRVk9JFBVQgpSRUFMSVRZX1NIT1JUX0lEPSRTSUQKRU9GCiAgb2sgIlJlYWxp
dHkt0LrQu9GO0YfQuCBAQFJFTEFZX05BTUVAQCDQsiAkQkFTRS9ub2RlL3JlYWxpdHkuZW52Igpm
aQpzb3VyY2UgIiRCQVNFL25vZGUvcmVhbGl0eS5lbnYiCgpjYXQgPiAiJEJBU0Uvbm9kZS9zdW5z
aGluZS1wcm9maWxlLmpzb24iIDw8RU9GCnsKICAiaW5ib3VuZHMiOiBbCiAgICB7ICJ0YWciOiAi
U1VOLVJFQUxJVFkiLCAibGlzdGVuIjogIjAuMC4wLjAiLCAicG9ydCI6IDQ0MywgInByb3RvY29s
IjogInZsZXNzIiwKICAgICAgInNldHRpbmdzIjogeyAiY2xpZW50cyI6IFtdLCAiZGVjcnlwdGlv
biI6ICJub25lIiB9LAogICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogInRjcCIs
ICJzZWN1cml0eSI6ICJyZWFsaXR5IiwKICAgICAgICAicmVhbGl0eVNldHRpbmdzIjogeyAic2hv
dyI6IGZhbHNlLCAiZGVzdCI6ICIxMjcuMC4wLjE6ODQ0MyIsCiAgICAgICAgICAic2VydmVyTmFt
ZXMiOiBbIiR7RE9NQUlOfSJdLAogICAgICAgICAgInByaXZhdGVLZXkiOiAiJHtSRUFMSVRZX1BS
SVZBVEVfS0VZfSIsICJzaG9ydElkcyI6IFsiJHtSRUFMSVRZX1NIT1JUX0lEfSJdIH0gfSwKICAg
ICAgInNuaWZmaW5nIjogeyAiZW5hYmxlZCI6IHRydWUsICJkZXN0T3ZlcnJpZGUiOiBbImh0dHAi
LCJ0bHMiLCJxdWljIl0gfSB9LAogICAgeyAidGFnIjogIlNVTi1XUyIsICJsaXN0ZW4iOiAiMTI3
LjAuMC4xIiwgInBvcnQiOiAyMDUzLCAicHJvdG9jb2wiOiAidmxlc3MiLAogICAgICAic2V0dGlu
Z3MiOiB7ICJjbGllbnRzIjogW10sICJkZWNyeXB0aW9uIjogIm5vbmUiIH0sCiAgICAgICJzdHJl
YW1TZXR0aW5ncyI6IHsgIm5ldHdvcmsiOiAid3MiLCAic2VjdXJpdHkiOiAibm9uZSIsICJ3c1Nl
dHRpbmdzIjogeyAicGF0aCI6ICIke1dTX1BBVEh9IiB9IH0gfSwKICAgIHsgInRhZyI6ICJTVU4t
WEhUVFAiLCAibGlzdGVuIjogIjEyNy4wLjAuMSIsICJwb3J0IjogMjA1NCwgInByb3RvY29sIjog
InZsZXNzIiwKICAgICAgInNldHRpbmdzIjogeyAiY2xpZW50cyI6IFtdLCAiZGVjcnlwdGlvbiI6
ICJub25lIiB9LAogICAgICAic3RyZWFtU2V0dGluZ3MiOiB7ICJuZXR3b3JrIjogInhodHRwIiwg
InNlY3VyaXR5IjogIm5vbmUiLAogICAgICAgICJ4aHR0cFNldHRpbmdzIjogeyAicGF0aCI6ICIk
e1hIVFRQX1BBVEh9IiB9IH0gfQogIF0sCiAgIm91dGJvdW5kcyI6IFsKICAgIHsgInRhZyI6ICJ0
by1tb29ubGlnaHQiLCAicHJvdG9jb2wiOiAidmxlc3MiLAogICAgICAic2V0dGluZ3MiOiB7ICJ2
bmV4dCI6IFsgewogICAgICAgICJhZGRyZXNzIjogIiR7TU9PTl9JUH0iLCAicG9ydCI6IDQ0MywK
ICAgICAgICAidXNlcnMiOiBbIHsgImlkIjogIl9fU0VSVklDRV9VU0VSX1VVSURfXyIsICJlbmNy
eXB0aW9uIjogIm5vbmUiLCAiZmxvdyI6ICJ4dGxzLXJwcngtdmlzaW9uIiB9IF0KICAgICAgfSBd
IH0sCiAgICAgICJzdHJlYW1TZXR0aW5ncyI6IHsgIm5ldHdvcmsiOiAidGNwIiwgInNlY3VyaXR5
IjogInJlYWxpdHkiLAogICAgICAgICJyZWFsaXR5U2V0dGluZ3MiOiB7ICJzZXJ2ZXJOYW1lIjog
IiR7TU9PTl9TTkl9IiwgImZpbmdlcnByaW50IjogImNocm9tZSIsCiAgICAgICAgICAicHVibGlj
S2V5IjogIiR7TU9PTl9QVUJLRVl9IiwgInNob3J0SWQiOiAiJHtNT09OX1NIT1JUSUR9IiB9IH0g
fSwKICAgIHsgInRhZyI6ICJkaXJlY3QiLCAicHJvdG9jb2wiOiAiZnJlZWRvbSIsICJzZXR0aW5n
cyI6IHsgImRvbWFpblN0cmF0ZWd5IjogIlVzZUlQdjQiIH0gfSwKICAgIHsgInRhZyI6ICJibG9j
ayIsICJwcm90b2NvbCI6ICJibGFja2hvbGUiIH0KICBdLAogICJkbnMiOiB7ICJzZXJ2ZXJzIjog
WyIxLjEuMS4xIiwiOC44LjguOCJdLCAicXVlcnlTdHJhdGVneSI6ICJVc2VJUHY0IiB9LAogICJy
b3V0aW5nIjogeyAiZG9tYWluU3RyYXRlZ3kiOiAiQXNJcyIsICJydWxlcyI6IFsKICAgIHsgInR5
cGUiOiAiZmllbGQiLCAiaW5ib3VuZFRhZyI6IFsiU1VOLVJFQUxJVFkiLCJTVU4tV1MiLCJTVU4t
WEhUVFAiXSwgIm91dGJvdW5kVGFnIjogInRvLW1vb25saWdodCIgfQogIF0gfQp9CkVPRgpvayAi
0J/RgNC+0YTQuNC70YwgQEBSRUxBWV9OQU1FQEAg0LPQvtGC0L7QsjogJEJBU0Uvbm9kZS9zdW5z
aGluZS1wcm9maWxlLmpzb24iCgpjYXQgPDxFT0YKCj09PT09PT09PT09PT09PT09PT09PT09PSAg
U1VOU0hJTkUg0KTQkNCX0JAgMSDQk9Ce0KLQntCS0JAgID09PT09PT09PT09PT09PT09PT09PT09
PQpDYWRkeSDQvdCwIDg0NDMgKNC00LXQutC+0LkpLCDRgdC10YDRgiDQtNC70Y8gJHtET01BSU59
INCy0YvQv9GD0YHQutCw0LXRgtGB0Y8g0YfQtdGA0LXQtyDQv9C+0YDRgiA4MC4KUmVhbGl0eS3Q
utC70Y7Rh9C4IEBAUkVMQVlfTkFNRUBAOiAgJEJBU0Uvbm9kZS9yZWFsaXR5LmVudgogIFBVQkxJ
Q19LRVkgPSAke1JFQUxJVFlfUFVCTElDX0tFWX0KICBTSE9SVF9JRCAgID0gJHtSRUFMSVRZX1NI
T1JUX0lEfQogICjRjdGC0Lgg0LTQstCwINC90YPQttC90Ysg0LTQu9GPINGF0L7RgdGC0LAgIlJl
YWxpdHkgdmlhIEBAUkVMQVlfTkFNRUBAIiDQsiDQv9Cw0L3QtdC70LgpCgrQlNCw0LvRjNGI0LUg
0KDQo9Ca0JDQnNCYINCyINC/0LDQvdC10LvQuCBAQEVYSVRfTkFNRUBAIChodHRwczovLyR7TU9P
Tl9TTkl9LyksINC/0L4g0L/QvtGA0Y/QtNC60YMg4oCUINGB0LwuIFNVTlNISU5FLVJFQURNRS5t
ZDoKICBBLiDQn9C+0LvRjNC30L7QstCw0YLQtdC70LggLT4g0YHQvtC30LTQsNGC0Ywg0YHQtdGA
0LLQuNGBLdGO0LfQtdGA0LAgKNC90LDQv9GALiBzdmMtc3Vuc2hpbmUpLCDQv9GA0LjQstGP0LfQ
sNGC0Ywg0Log0YLQvtC80YMg0LbQtSDRgdC60LLQsNC00YMsCiAgICAg0LPQtNC1INC70LXQttCw
0YIg0LjQvdCx0LDRg9C90LTRiyBAQEVYSVRfTkFNRUBAICjRh9GC0L7QsdGLINC10LPQviBVVUlE
INCx0YvQuyDQstCw0LvQuNC00LXQvSDQvdCwIFJlYWxpdHkt0LjQvdCx0LDRg9C90LTQtSBAQEVY
SVRfTkFNRUBAKS4KICAgICDQodC60L7Qv9C40YDQvtCy0LDRgtGMINC10LPQviBVVUlELgogIEIu
INCd0LAg0KHQldCg0JLQldCg0JUgQEBSRUxBWV9OQU1FQEAg0L/QvtC00YHRgtCw0LLQuNGC0Ywg
0Y3RgtC+0YIgVVVJRCDQsiDQv9GA0L7RhNC40LvRjCAo0LLQvNC10YHRgtC+INC/0LvQtdC50YHR
hdC+0LvQtNC10YDQsCk6CiAgICAgICBzZWQgLWkgJ3MvX19TRVJWSUNFX1VTRVJfVVVJRF9fL9CS
0JDQqF9VVUlELycgJEJBU0Uvbm9kZS9zdW5zaGluZS1wcm9maWxlLmpzb24KICAgICAgIGNhdCAk
QkFTRS9ub2RlL3N1bnNoaW5lLXByb2ZpbGUuanNvbiAgICAgICMg0L/RgNC+0LLQtdGA0YwsINGH
0YLQviDQv9C70LXQudGB0YXQvtC70LTQtdGA0LAg0LHQvtC70YzRiNC1INC90LXRggogIEMuINCf
0YDQvtGE0LjQu9C4IC0+INGB0L7Qt9C00LDRgtGMINC90L7QstGL0Lkg0L/RgNC+0YTQuNC70Ywg
IkBAUkVMQVlfTkFNRUBALVByb2ZpbGUiIC0+INCa0L7QvdGE0LjQsyBYcmF5IC0+CiAgICAg0LLR
gdGC0LDQstC40YLRjCDRgdC+0LTQtdGA0LbQuNC80L7QtSBzdW5zaGluZS1wcm9maWxlLmpzb24g
LT4g0KHQvtGF0YDQsNC90LjRgtGMLgogIEQuINCd0L7QtNGLIC0+INGB0L7Qt9C00LDRgtGMINC9
0L7QtNGDOiDQuNC80Y8gc3Vuc2hpbmUtcmVsYXksINCw0LTRgNC10YEgJHtNWUlQfSwgTm9kZSBQ
b3J0IDIyMjIuCiAgICAg0J/RgNC+0YTQuNC70YwgPSBAQFJFTEFZX05BTUVAQC1Qcm9maWxlLCDQ
vtGC0LzQtdGC0LjRgtGMIDMg0LjQvdCx0LDRg9C90LTQsCwg0KHQntCl0KDQkNCd0JjQotCsINCy
0YvQsdC+0YAg0LjQvdCx0LDRg9C90LTQvtCyLgogICAgINCh0LrQvtC/0LjRgNC+0LLQsNGC0Ywg
U0VDUkVUX0tFWSDQutC90L7Qv9C60L7QuS3QuNC60L7QvdC60L7QuS4KICBFLiDQktC90YPRgtGA
0LXQvdC90LjQtSDRgdC60LLQsNC00Ys6INC00L7QsdCw0LLQuNGC0Ywg0LjQvdCx0LDRg9C90LTR
iyBAQFJFTEFZX05BTUVAQCDQsiDRgdC60LLQsNC0INC4INGD0LHQtdC00LjRgtGM0YHRjywg0YfR
gtC+INCyINGB0LrQstCw0LRlINC10YHRgtGMINGO0LfQtdGACiAgICAgKNC40L3QsNGH0LUg0L3Q
vtC00LAgQEBSRUxBWV9OQU1FQEAg0L/QvtC70YPRh9C40YIgaW5ib3VuZHM6W10g4oCUINC60LDQ
uiDQsdGL0LvQviDQvdCwIEBARVhJVF9OQU1FQEApLgogIEYuINCl0L7RgdGC0YsgLT4g0YHQvtC3
0LTQsNGC0YwgMyDRhdC+0YHRgtCwICJ2aWEgQEBSRUxBWV9OQU1FQEAiOgogICAgICAgUmVhbGl0
eTog0LDQtNGA0LXRgSAke0RPTUFJTn06NDQzLCBTTkkgJHtET01BSU59LCBwdWJrZXkvc2hvcnRJ
ZCDigJQgQEBSRUxBWV9OQU1FQEAgKNGB0LwuINCy0YvRiNC1KQogICAgICAgV1NTOiAgICDQsNC0
0YDQtdGBICR7RE9NQUlOfTo0NDMsIFNlY3VyaXR5IFRMUywgU05JK0hvc3QgJHtET01BSU59LCBw
YXRoICR7V1NfUEFUSH0KICAgICAgIFhIVFRQOiAg0LDQtNGA0LXRgSAke0RPTUFJTn06NDQzLCBT
ZWN1cml0eSBUTFMsIFNOSStIb3N0ICR7RE9NQUlOfSwgcGF0aCAke1hIVFRQX1BBVEh9CgrQn9C+
0YLQvtC8INC90LAgQEBSRUxBWV9OQU1FQEA6CiAgRy4gc3VkbyBiYXNoIGRlcGxveS1ub2RlLXN1
bnNoaW5lLnNoICAgKNC/0L7QtNC90LjQvNC10YIg0L3QvtC00YM7IFNFQ1JFVF9LRVkg0LLRgdGC
0LDQstC40YjRjCDQsiBuYW5vKQoK0J/RgNC+0LLQtdGA0LrQsDog0L/QvtC00LrQu9GO0YfQuNGC
0YzRgdGPINGH0LXRgNC10LcgInZpYSBAQFJFTEFZX05BTUVAQCIgLT4g0LLQvdC10YjQvdC40Lkg
SVAg0LTQvtC70LbQtdC9INCx0YvRgtGMICR7TU9PTl9JUH0gKEBARVhJVF9OQU1FQEApLArQsCDQ
stGF0L7QtCDigJQg0YfQtdGA0LXQtyAke0RPTUFJTn0gKEBAUkVMQVlfTkFNRUBAKS4KPT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PQpFT0YK
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
ZGR5ZmlsZSA8PEVPRgp7Cn0KJHtET01BSU59Ojg0NDMgewogICAgaGFuZGxlX3BhdGggJHtTVUJf
UEFUSH0vKiB7CiAgICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MzAxMAogICAgfQogICAg
QHdzIHBhdGggJHtXU19QQVRIfSAke1dTX1BBVEh9LyoKICAgIGhhbmRsZSBAd3MgewogICAgICAg
IHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjIwNTMKICAgIH0KICAgIEB4aCBwYXRoICR7WEhUVFBf
UEFUSH0gJHtYSFRUUF9QQVRIfS8qCiAgICBoYW5kbGUgQHhoIHsKICAgICAgICByZXZlcnNlX3By
b3h5IDEyNy4wLjAuMToyMDU0IHsKICAgICAgICAgICAgZmx1c2hfaW50ZXJ2YWwgLTEKICAgICAg
ICB9CiAgICB9CiAgICBoYW5kbGUgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjMw
MDAKICAgIH0KfQpFT0YKZG9ja2VyIGNvbXBvc2UgcmVzdGFydAoKZWNobyAiPT0+INCf0LXRgNC1
0LfQsNC/0YPRgdC60LDRjiDQvdC+0LTRgywg0YfRgtC+0LHRiyBYcmF5INC30LDQvdGP0Lsg0L7R
gdCy0L7QsdC+0LTQuNCy0YjQuNC50YHRjyA0NDMuLi4iCmRvY2tlciByZXN0YXJ0IHJlbW5hbm9k
ZSA+L2Rldi9udWxsIDI+JjEgfHwgdHJ1ZQoKZWNobyAiPT0+INCf0YDQvtCy0LXRgNGP0Y4sINC+
0YLQstC10YfQsNC10YIg0LvQuCDQv9Cw0L3QtdC70Ywg0YfQtdGA0LXQtyDQvdC+0LTRgyAo0LTQ
viA2INC/0L7Qv9GL0YLQvtC6KS4uLiIKQ09ERT0wMDAKZm9yIGkgaW4gMSAyIDMgNCA1IDY7IGRv
CiAgc2xlZXAgNQogIENPREU9JChjdXJsIC1zIC1vIC9kZXYvbnVsbCAtdyAiJXtodHRwX2NvZGV9
IiAtLW1heC10aW1lIDYgImh0dHBzOi8vJHtET01BSU59LyIgfHwgZWNobyAiMDAwIikKICBlY2hv
ICIgINC/0L7Qv9GL0YLQutCwICRpOiBIVFRQICRDT0RFIgogIGNhc2UgIiRDT0RFIiBpbiAyMDB8
MzAxfDMwMnwzMDd8MzA4KSBicmVhazs7IGVzYWMKZG9uZQoKY2FzZSAiJENPREUiIGluCiAgMjAw
fDMwMXwzMDJ8MzA3fDMwOCkKICAgIGVjaG8gIj09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09IgogICAgZWNobyAiINCj0KHQn9CV0KU6INC/0LDQvdC10LvR
jCDRgNCw0LHQvtGC0LDQtdGCINGH0LXRgNC10Lcg0L3QvtC00YMgKEhUVFAgJENPREUpLiIKICAg
IGVjaG8gIiA0NDMg0YLQtdC/0LXRgNGMINC30LAgWHJheToiCiAgICBzcyAtdGxucCB8IGdyZXAg
Jzo0NDMgJyB8fCB0cnVlCiAgICBlY2hvICI9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PSIKICAgIDs7CiAgKikKICAgIGVjaG8gItCf0LDQvdC10LvRjCDQ
vdC1INC+0YLQstC10YLQuNC70LAgKNC60L7QtCAkQ09ERSkg4oCUINCe0KLQmtCQ0KI6INCy0L7Q
t9Cy0YDQsNGJ0LDRjiBDYWRkeSDQvdCwIDQ0My4iCiAgICBjYXQgPiBDYWRkeWZpbGUgPDxFT0YK
JHtET01BSU59IHsKICAgIGhhbmRsZV9wYXRoICR7U1VCX1BBVEh9LyogewogICAgICAgIHJldmVy
c2VfcHJveHkgMTI3LjAuMC4xOjMwMTAKICAgIH0KICAgIGhhbmRsZSB7CiAgICAgICAgcmV2ZXJz
ZV9wcm94eSAxMjcuMC4wLjE6MzAwMAogICAgfQp9CkVPRgogICAgZG9ja2VyIGNvbXBvc2UgcmVz
dGFydAogICAgZWNobyAi0J7RgtC60LDRgiDRgdC00LXQu9Cw0L06INC/0LDQvdC10LvRjCDRgdC9
0L7QstCwINC00L7RgdGC0YPQv9C90LAg0L3QsCBodHRwczovLyR7RE9NQUlOfS8iCiAgICBlY2hv
ICItLS0g0LvQvtCz0Lgg0L3QvtC00Ysg0LTQu9GPINGA0LDQt9Cx0L7RgNCwICjQv9GA0LjRiNC7
0Lgg0LjRhSDQvNC90LUpIC0tLSIKICAgIGRvY2tlciBsb2dzIHJlbW5hbm9kZSAtLXRhaWwgMjUK
ICAgIDs7CmVzYWMK
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
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHByb3Zpc2lvbi1yZWxheS5zaCDigJQgaGVhZGxlc3Mg0L3Q
sNGB0YLRgNC+0LnQutCwINGA0LXQu9C10Y8gQEBSRUxBWV9OQU1FQEAg0YfQtdGA0LXQtyBBUEkg
0L/QsNC90LXQu9C4IEBARVhJVF9OQU1FQEAuCiMg0JfQsNC/0YPRgdC60LDQtdGC0YHRjyDQndCQ
IE1PT05MSUdIVC4g0KHQvtC30LTQsNGR0YI6CiMgICAtINGB0LXRgNCy0LjRgS3RjtC30LXRgNCw
INC60LDRgdC60LDQtNCwIChyZWxheS11c2VyKSDihpIg0LHQtdGA0ZHRgiDQtdCz0L4gVVVJRCDQ
tNC70Y8gb3V0Ym91bmQKIyAgIC0gcmVsYXkgY29uZmlnLXByb2ZpbGUg0YEgU1VOLSog0LjQvdCx
0LDRg9C90LTQsNC80Lgg0Lggb3V0Ym91bmQg0L3QsCBAQEVYSVRfTkFNRUBACiMgICAtINC90L7Q
tNGDIEBAUkVMQVlfTkFNRUBAICjQsNC00YDQtdGBID0gUkVMQVlfSVApCiMgICAtIFNFQ1JFVF9L
RVkg0L3QvtC00Ysg4oaSIC9vcHQvQEBTTFVHQEAvbm9kZS1AQFJFTEFZX05BTUVAQC5lbnYKIyAg
IC0gcmVsYXktYm9vdHN0cmFwLmVudiDihpIgL29wdC9AQFNMVUdAQC9yZWxheS1ib290c3RyYXAu
ZW52ICjQtNC70Y8gZGVwbG95LXN1bnNoaW5lKQpzZXQgLWV1byBwaXBlZmFpbApTTFVHPSJAQFNM
VUdAQCIKRVhJVF9OQU1FPSJAQEVYSVRfTkFNRUBAIgpSRUxBWV9OQU1FPSJAQFJFTEFZX05BTUVA
QCIKUkVMQVlfSVA9IkBAUkVMQVlfSVBAQCIKUkVMQVlfRE9NQUlOPSJAQFJFTEFZX0RPTUFJTkBA
IgpNQUlOX0RPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpOT0RFX1BPUlQ9MjIyMgpXU19QQVRIPSIv
d3NuZyIKWEhUVFBfUEFUSD0iL3hoIgpQUk9GSUxFX05BTUU9IkBAUkVMQVlfTkFNRUBALVByb2Zp
bGUiClNFUlZJQ0VfVVNFUj0icmVsYXktY2FzY2FkZS11c2VyIgoKYygpeyBwcmludGYgJ1wwMzNb
JXNtJyAiJDEiOyB9CmxvZygpeyBlY2hvOyBlY2hvICIkKGMgJzE7MzYnKeKWtiQoYyAwKSAkKiI7
IH0Kb2soKXsgIGVjaG8gIiAgJChjICcxOzMyJyninJMkKGMgMCkgJCoiOyB9Cndhcm4oKXsgZWNo
byAiICAkKGMgJzE7MzMnKSEkKGMgMCkgJCoiOyB9CmRpZSgpeyBlY2hvICIgICQoYyAnMTszMScp
4pyXJChjIDApICQqIiA+JjI7IGV4aXQgMTsgfQpqdmFsKCl7IHB5dGhvbjMgLSAiJDEiICIkMiIg
PDwnUFknIDI+L2Rldi9udWxsCmltcG9ydCBzeXMsanNvbgp0cnk6IGQ9anNvbi5sb2FkcyhzeXMu
YXJndlsxXSkKZXhjZXB0IEV4Y2VwdGlvbjogc3lzLmV4aXQoMSkKZm9yIGsgaW4gc3lzLmFyZ3Zb
Ml0uc3BsaXQoJy4nKToKICAgIGlmIGlzaW5zdGFuY2UoZCxsaXN0KToKICAgICAgICB0cnk6IGQ9
ZFtpbnQoayldCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjogc3lzLmV4aXQoMSkKICAgIGVsaWYg
aXNpbnN0YW5jZShkLGRpY3QpOiBkPWQuZ2V0KGspCiAgICBlbHNlOiBzeXMuZXhpdCgxKQogICAg
aWYgZCBpcyBOb25lOiBzeXMuZXhpdCgxKQpwcmludChkIGlmIG5vdCBpc2luc3RhbmNlKGQsKGRp
Y3QsbGlzdCkpIGVsc2UganNvbi5kdW1wcyhkKSkKUFkKfQoKIyDilIDilIAg0LDQstGC0L7RgNC4
0LfQsNGG0LjRjyDQvdCwINC/0LDQvdC10LvQuCAo0LLQvdGD0YLRgNC10L3QvdC40Lkg0LzQsNGA
0YjRgNGD0YIgbG9jYWxob3N0OjgwODEsINCyINC+0LHRhdC+0LQg0YHRgtC10LvRgdCwKSDilIDi
lIAKQ1JFRF9GSUxFPSIvb3B0LyRTTFVHL2NyZWRlbnRpYWxzLnR4dCIKWyAtZiAiJENSRURfRklM
RSIgXSB8fCBkaWUgItC90LXRgiAkQ1JFRF9GSUxFIOKAlCDQt9Cw0L/Rg9GB0YLQuCBwcm92aXNp
b24gZXhpdCDQv9C10YDQstGL0LwiCkFETUlOX1BBU1M9IiQoZ3JlcCAtRSAnXlxzKnBhc3M6JyAi
JENSRURfRklMRSIgfCBhd2sgJ3twcmludCAkMn0nIHwgaGVhZCAtMSkiClsgLW4gIiRBRE1JTl9Q
QVNTIiBdIHx8IGRpZSAi0L3QtSDQvdCw0YjRkdC7INC/0LDRgNC+0LvRjCDQsiAkQ1JFRF9GSUxF
IgoKUkVTT0xWRV9BUkdTPSgpCnN0YXR1c19vaygpeyBsb2NhbCBjOyBjPSIkKGN1cmwgLXNTIC1r
IC1vIC9kZXYvbnVsbCAiJHtSRVNPTFZFX0FSR1NbQF19IiAtdyAnJXtodHRwX2NvZGV9JyAiJHtB
UElfQkFTRX0vYXV0aC9zdGF0dXMiIDI+L2Rldi9udWxsKSI7IFsgLW4gIiRjIiBdICYmIFsgIiRj
IiAtZ2UgMjAwIF0gMj4vZGV2L251bGwgJiYgWyAiJGMiIC1sdCA1MDAgXSAyPi9kZXYvbnVsbDsg
fQpUT0tFTj0iIgphcGkoKXsKICBsb2NhbCBtZXRob2Q9IiQxIiBwYXRoPSIkMiIgYm9keT0iJHsz
Oi19IiByZXNwIGNvZGUKICBsb2NhbCBhcmdzPSgtc1MgLWsgIiR7UkVTT0xWRV9BUkdTW0BdfSIg
LVggIiRtZXRob2QiICIke0FQSV9CQVNFfSR7cGF0aH0iCiAgICAgICAgICAgICAgLUggIkNvbnRl
bnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgLUggIlgtUmVtbmF3YXZlLUNsaWVudC1UeXBlOiBi
cm93c2VyIikKICBbIC1uICIkVE9LRU4iIF0gJiYgYXJncys9KC1IICJBdXRob3JpemF0aW9uOiBC
ZWFyZXIgJFRPS0VOIikKICBbIC1uICIkYm9keSIgXSAmJiBhcmdzKz0oLWQgIiRib2R5IikKICBy
ZXNwPSIkKGN1cmwgIiR7YXJnc1tAXX0iIC13ICQnXG4le2h0dHBfY29kZX0nKSIgfHwgeyBlY2hv
ICIgIOKclyBjdXJsINGD0L/QsNC7INC90LAgJG1ldGhvZCAkcGF0aCIgPiYyOyByZXR1cm4gMTsg
fQogIGNvZGU9IiR7cmVzcCMjKiQnXG4nfSI7IHJlc3A9IiR7cmVzcCUkJ1xuJyp9IgogIGlmIFsg
IiRjb2RlIiAtbHQgMjAwIF0gfHwgWyAiJGNvZGUiIC1nZSAzMDAgXTsgdGhlbgogICAgeyBlY2hv
OyBlY2hvICIgICEgQVBJICRtZXRob2QgJHBhdGgg4oaSIEhUVFAgJGNvZGUiOyBlY2hvICIkcmVz
cCIgfCBzZWQgJ3MvXi8gICAgLyc7IH0gPiYyOyByZXR1cm4gMQogIGZpCiAgcHJpbnRmICclcycg
IiRyZXNwIgp9Cgpsb2cgItCY0YnRgyDQv9Cw0L3QtdC70YzigKYiCkFQSV9CQVNFPSJodHRwOi8v
MTI3LjAuMC4xOjMwMDAvYXBpIjsgUkVTT0xWRV9BUkdTPSgpCmlmIHN0YXR1c19vazsgdGhlbgog
IG9rICLQv9Cw0L3QtdC70Ywg0L/QviDQv9GA0Y/QvNC+0LzRgyDQvNCw0YDRiNGA0YPRgtGDICgx
MjcuMC4wLjE6MzAwMCkiCmVsc2UKICBmb3IgcCBpbiA4MDgxX2h0dHBzIDQ0MyA4NDQzOyBkbwog
ICAgaWYgWyAiJHAiID0gIjgwODFfaHR0cHMiIF07IHRoZW4KICAgICAgQVBJX0JBU0U9Imh0dHBz
Oi8vbG9jYWxob3N0OjgwODEvYXBpIjsgUkVTT0xWRV9BUkdTPSgpCiAgICBlbHNlCiAgICAgIEFQ
SV9CQVNFPSJodHRwczovLyR7TUFJTl9ET01BSU59OiR7cH0vYXBpIjsgUkVTT0xWRV9BUkdTPSgt
LXJlc29sdmUgIiR7TUFJTl9ET01BSU59OiR7cH06MTI3LjAuMC4xIikKICAgIGZpCiAgICBzdGF0
dXNfb2sgJiYgeyBvayAi0L/QsNC90LXQu9GMINC90LAgJHAiOyBicmVhazsgfQogICAgWyAiJHAi
ID0gODQ0MyBdICYmIGRpZSAi0L/QsNC90LXQu9GMINC90LUg0L7RgtCy0LXRh9Cw0LXRgiDQvdC4
INC90LAgMzAwMC84MDgxLzQ0My84NDQzIgogIGRvbmUKZmkKbG9naW49IiQoYXBpIFBPU1QgL2F1
dGgvbG9naW4gIntcInVzZXJuYW1lXCI6XCJhZG1pblwiLFwicGFzc3dvcmRcIjpcIiRBRE1JTl9Q
QVNTXCJ9IikiIHx8IGRpZSAi0LvQvtCz0LjQvSDQvdC1INC/0YDQvtGI0ZHQuyIKVE9LRU49IiQo
anZhbCAiJGxvZ2luIiByZXNwb25zZS5hY2Nlc3NUb2tlbikiOyBbIC1uICIkVE9LRU4iIF0gfHwg
VE9LRU49IiQoanZhbCAiJGxvZ2luIiBhY2Nlc3NUb2tlbikiClsgLW4gIiRUT0tFTiIgXSB8fCBk
aWUgItGC0L7QutC10L0g0L3QtSDQv9C+0LvRg9GH0LXQvSIKb2sgItCy0L7RiNGR0Lsg0LIg0L/Q
sNC90LXQu9GMIgoKIyDilIDilIAgUmVhbGl0eS3QutC70Y7Rh9C4IE1vb25saWdodCAob3V0Ym91
bmQg0L3QsCByZWxheSDihpIg0L3Rg9C20L3RiyBwdWJrZXkgKyBzaG9ydGlkKSDilIDilIDilIDi
lIAKUkVBTElUWV9FTlY9Ii9vcHQvJFNMVUcvbm9kZS9yZWFsaXR5LmVudiIKWyAtZiAiJFJFQUxJ
VFlfRU5WIiBdIHx8IGRpZSAi0L3QtdGCICRSRUFMSVRZX0VOViDigJQgZGVwbG95LW1vb25saWdo
dCDQvdC1INC30LDQstC10YDRiNGR0L0iCnNvdXJjZSAiJFJFQUxJVFlfRU5WIgpNT09OX1BVQktF
WT0iJHtSRUFMSVRZX1BVQkxJQ19LRVk6LX0iCk1PT05fU0hPUlRJRD0iJHtSRUFMSVRZX1NIT1JU
X0lEOi19IgpbIC1uICIkTU9PTl9QVUJLRVkiIF0gfHwgZGllICJSRUFMSVRZX1BVQkxJQ19LRVkg
0L3QtSDQvdCw0LnQtNC10L0g0LIgJFJFQUxJVFlfRU5WIgpvayAiUmVhbGl0eS3QutC70Y7Rh9C4
IE1vb25saWdodDogcHVia2V5PSR7TU9PTl9QVUJLRVk6MDoxNn3igKYiCgojIOKUgOKUgCAxLiDR
gdC10YDQstC40YEt0Y7Qt9C10YAg0LrQsNGB0LrQsNC00LAg4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSACmxvZyAi0KHQtdGA0LLQuNGBLdGO0LfQtdGAINC60LDRgdC60LDQ
tNCwICgkU0VSVklDRV9VU0VSKSIKZXhpc3RpbmdfdT0iJChhcGkgR0VUICIvdXNlcnMvYnktdXNl
cm5hbWUvJFNFUlZJQ0VfVVNFUiIgMj4vZGV2L251bGwpIiB8fCBleGlzdGluZ191PSIiCmlmIFsg
LW4gIiRleGlzdGluZ191IiBdOyB0aGVuCiAgU0VSVklDRV9VVUlEPSIkKGp2YWwgIiRleGlzdGlu
Z191IiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiRTRVJWSUNFX1VVSUQiIF0gfHwgU0VSVklDRV9V
VUlEPSIkKGp2YWwgIiRleGlzdGluZ191IiB1dWlkKSIKICBvayAi0YHQtdGA0LLQuNGBLdGO0LfQ
tdGAINGD0LbQtSDQtdGB0YLRjDogJFNFUlZJQ0VfVVVJRCIKZWxzZQogIHViPSIkKHB5dGhvbjMg
LWMgImltcG9ydCBqc29uLHN5czsgcHJpbnQoanNvbi5kdW1wcyh7J3VzZXJuYW1lJzonJFNFUlZJ
Q0VfVVNFUicsJ3RyYWZmaWNMaW1pdEJ5dGVzJzowLCd0cmFmZmljTGltaXRTdHJhdGVneSc6J05P
X1JFU0VUJywnZXhwaXJlQXQnOicyMDk5LTAxLTAxVDAwOjAwOjAwLjAwMFonLCdhY3RpdmVJbnRl
cm5hbFNxdWFkcyc6W119KSkiKSIKICB1c3I9IiQoYXBpIFBPU1QgL3VzZXJzICIkdWIiKSIgfHwg
ZGllICLRgdC+0LfQtNCw0L3QuNC1INGB0LXRgNCy0LjRgS3RjtC30LXRgNCwIOKAlCDRgdC60LjQ
vdGMINCx0LvQvtC6INC+0YjQuNCx0LrQuCIKICBTRVJWSUNFX1VVSUQ9IiQoanZhbCAiJHVzciIg
cmVzcG9uc2UudXVpZCkiOyBbIC1uICIkU0VSVklDRV9VVUlEIiBdIHx8IFNFUlZJQ0VfVVVJRD0i
JChqdmFsICIkdXNyIiB1dWlkKSIKICBvayAi0YHQtdGA0LLQuNGBLdGO0LfQtdGAINGB0L7Qt9C0
0LDQvTogJFNFUlZJQ0VfVVVJRCIKZmkKIyDRhNC+0LvQsdGN0Log0YfQtdGA0LXQtyDQkdCUCmlm
IFsgLXogIiR7U0VSVklDRV9VVUlEOi19IiBdOyB0aGVuCiAgU0VSVklDRV9VVUlEPSIkKGRvY2tl
ciBleGVjIC1pIHJlbW5hd2F2ZS1kYiBwc3FsIC1VIHBvc3RncmVzIC1kIHBvc3RncmVzIC10QWMg
XAogICAgIlNFTEVDVCB1dWlkIEZST00gdXNlcnMgV0hFUkUgdXNlcm5hbWU9JyRTRVJWSUNFX1VT
RVInIExJTUlUIDE7IiAyPi9kZXYvbnVsbCB8IHRyIC1kICdbOnNwYWNlOl0nKSIgfHwgU0VSVklD
RV9VVUlEPSIiCiAgWyAtbiAiJFNFUlZJQ0VfVVVJRCIgXSAmJiBvayAiVVVJRCDRgdC10YDQstC4
0YEt0Y7Qt9C10YDQsCDQuNC3INCR0JQ6ICRTRVJWSUNFX1VVSUQiIHx8IGRpZSAi0L3QtSDQvNC+
0LPRgyDQv9C+0LvRg9GH0LjRgtGMIFVVSUQg0YHQtdGA0LLQuNGBLdGO0LfQtdGA0LAiCmZpCgoj
IFZMRVNTIHByb3h5LVVVSUQg0LrQsNGB0LrQsNC0LdGO0LfQtdGA0LAuINCSIFJlbW5hd2F2ZSB1
c2Vycy52bGVzc191dWlkICE9IHVzZXJzLnV1aWQsINCwCiMgTW9vbmxpZ2h0INC+0L/QvtC30L3Q
sNGR0YIg0LrQu9C40LXQvdGC0L7QsiDQsiDQuNC90LHQsNGD0L3QtNCw0YUg0JjQnNCV0J3QndCe
INC/0L4gdmxlc3NfdXVpZC4gT3V0Ym91bmQgdG8tbW9vbmxpZ2h0CiMg0L7QsdGP0LfQsNC9INC4
0YHQv9C+0LvRjNC30L7QstCw0YLRjCB2bGVzc191dWlkLCDQuNC90LDRh9C1IFZMRVNTLdCw0LLR
gtC+0YDQuNC30LDRhtC40Y8g0L3QsCBNb29ubGlnaHQg0L7RgtC60LvQvtC90Y/QtdGCINC60LDR
gdC60LDQtAojIChyZWFsaXR5INC/0YDQvtGF0L7QtNC40YIsINC00LDQu9GM0YjQtSDRgtC40YjQ
uNC90LAvRU9GKSDQuCDQktCh0JUgdmlhLVN1bnNoaW5lINGB0L7QtdC00LjQvdC10L3QuNGPINC/
0LDQtNCw0Y7Rgi4KU0VSVklDRV9WTEVTU19VVUlEPSIkKGRvY2tlciBleGVjIC1pIHJlbW5hd2F2
ZS1kYiBwc3FsIC1VIHBvc3RncmVzIC1kIHBvc3RncmVzIC10QWMgXAogICJTRUxFQ1Qgdmxlc3Nf
dXVpZCBGUk9NIHVzZXJzIFdIRVJFIHVzZXJuYW1lPSckU0VSVklDRV9VU0VSJyBMSU1JVCAxOyIg
Mj4vZGV2L251bGwgfCB0ciAtZCAnWzpzcGFjZTpdJykiIHx8IFNFUlZJQ0VfVkxFU1NfVVVJRD0i
IgppZiBbIC16ICIkU0VSVklDRV9WTEVTU19VVUlEIiBdOyB0aGVuCiAgU0VSVklDRV9WTEVTU19V
VUlEPSIkKGp2YWwgIiR7ZXhpc3RpbmdfdTotfSIgcmVzcG9uc2Uudmxlc3NVdWlkIDI+L2Rldi9u
dWxsKSIKICBbIC1uICIkU0VSVklDRV9WTEVTU19VVUlEIiBdIHx8IFNFUlZJQ0VfVkxFU1NfVVVJ
RD0iJChqdmFsICIke3VzcjotfSIgcmVzcG9uc2Uudmxlc3NVdWlkIDI+L2Rldi9udWxsKSIKZmkK
WyAtbiAiJFNFUlZJQ0VfVkxFU1NfVVVJRCIgXSB8fCBTRVJWSUNFX1ZMRVNTX1VVSUQ9IiRTRVJW
SUNFX1VVSUQiICAgIyDRhNC+0LvQsdGN0LoKb2sgIlZMRVNTLVVVSUQg0LrQsNGB0LrQsNC0LdGO
0LfQtdGA0LAgKNC00LvRjyBvdXRib3VuZCB0by1tb29ubGlnaHQpOiAkU0VSVklDRV9WTEVTU19V
VUlEIgoKIyDilIDilIAgMi4gcmVsYXkgY29uZmlnLXByb2ZpbGUg4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSACmxvZyAiUmVsYXkgY29uZmlnLXByb2ZpbGUgKCRQUk9GSUxFX05B
TUUpIgojIFJlYWxpdHkt0LrQu9GO0YfQuCBTdW5zaGluZTog0L/QtdGA0LXQuNGB0L/QvtC70YzQ
t9GD0LXQvCDQuNC3INC/0YDQtdC00YvQtNGD0YnQtdCz0L4gYm9vdHN0cmFwICjRgdGC0LDQsdC4
0LvRjNC90L7RgdGC0Ywg0LrQu9GO0YfQtdC5ISkKUkVMQVlfUFJJVj0iIjsgUkVMQVlfUFVCPSIi
OyBSRUxBWV9TSUQ9IiIKX3ByZXZfYnM9Ii9vcHQvJFNMVUcvcmVsYXktYm9vdHN0cmFwLmVudiIK
aWYgWyAtZiAiJF9wcmV2X2JzIiBdOyB0aGVuCiAgX3A9IiQoZ3JlcCAnXlJFTEFZX1BSSVY9JyAi
JF9wcmV2X2JzIiB8IGN1dCAtZD0gLWYyLSkiOyBfcT0iJChncmVwICdeUkVMQVlfUFVCPScgIiRf
cHJldl9icyIgfCBjdXQgLWQ9IC1mMi0pIgogIF9zPSIkKGdyZXAgJ15SRUxBWV9TSUQ9JyAiJF9w
cmV2X2JzIiB8IGN1dCAtZD0gLWYyLSkiCiAgaWYgWyAtbiAiJF9wIiBdICYmIFsgLW4gIiRfcSIg
XSAmJiBbIC1uICIkX3MiIF07IHRoZW4KICAgIFJFTEFZX1BSSVY9IiRfcCI7IFJFTEFZX1BVQj0i
JF9xIjsgUkVMQVlfU0lEPSIkX3MiCiAgICBvayAiUmVhbGl0eS3QutC70Y7Rh9C4IFN1bnNoaW5l
IOKAlCDQv9C10YDQtdC40YHQv9C+0LvRjNC30YPRjiDQuNC3IGJvb3RzdHJhcCAocHVia2V5PSR7
UkVMQVlfUFVCOjA6MTZ94oCmKSIKICBmaQpmaQppZiBbIC16ICIkUkVMQVlfUFVCIiBdOyB0aGVu
CiAgIyDQs9C10L3QtdGA0LjRgNGD0LXQvCDQstC/0LXRgNCy0YvQtQogIGlmIGNvbW1hbmQgLXYg
eHJheSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIFJFTEFZX1BSSVY9IiQoeHJheSB4MjU1MTkg
fCBhd2sgJy9bUHBdcml2YXRlL3twcmludCAkTkZ9JykiOyBSRUxBWV9QVUI9IiQoeHJheSB4MjU1
MTkgLWkgIiRSRUxBWV9QUklWIiB8IGF3ayAnL1tQcF11YmxpY3xbUHBdYXNzd29yZC97cHJpbnQg
JE5GfScpIgogIGVsaWYgZG9ja2VyIGV4ZWMgcmVtbmFub2RlIHhyYXkgeDI1NTE5ID4vZGV2L251
bGwgMj4mMTsgdGhlbgogICAgUkVMQVlfUFJJVj0iJChkb2NrZXIgZXhlYyByZW1uYW5vZGUgeHJh
eSB4MjU1MTkgfCBhd2sgJy9bUHBdcml2YXRlL3twcmludCAkTkZ9JykiCiAgICBSRUxBWV9QVUI9
IiQoZG9ja2VyIGV4ZWMgcmVtbmFub2RlIHhyYXkgeDI1NTE5IC1pICIkUkVMQVlfUFJJViIgfCBh
d2sgJy9bUHBddWJsaWN8W1BwXWFzc3dvcmQve3ByaW50ICRORn0nKSIKICBlbHNlCiAgICBfb3V0
PSIkKGRvY2tlciBydW4gLS1ybSAtLW5ldHdvcmsgbm9uZSBnaGNyLmlvL3h0bHMveHJheS1jb3Jl
OmxhdGVzdCB4cmF5IHgyNTUxOSAyPi9kZXYvbnVsbCkiIHx8IF9vdXQ9IiIKICAgIFJFTEFZX1BS
SVY9IiQoZWNobyAiJF9vdXQiIHwgYXdrICcvW1BwXXJpdmF0ZS97cHJpbnQgJE5GfScpIjsgUkVM
QVlfUFVCPSIkKGVjaG8gIiRfb3V0IiB8IGF3ayAnL1tQcF11YmxpY3xbUHBdYXNzd29yZC97cHJp
bnQgJE5GfScpIgogIGZpCiAgUkVMQVlfU0lEPSIkKG9wZW5zc2wgcmFuZCAtaGV4IDgpIgogIFsg
LW4gIiRSRUxBWV9QVUIiIF0gfHwgZGllICLQvdC1INGD0LTQsNC70L7RgdGMINGB0LPQtdC90LXR
gNC40YDQvtCy0LDRgtGMIFJlYWxpdHkt0LrQu9GO0YfQuCDQtNC70Y8gU3Vuc2hpbmUg4oCUINC9
0LXRgiB4cmF5L2RvY2tlciIKICBvayAiUmVhbGl0eS3QutC70Y7Rh9C4IFN1bnNoaW5lIOKAlCDR
gdCz0LXQvdC10YDQuNGA0L7QstCw0L3RiyDQvdC+0LLRi9C1OiBwdWJrZXk9JHtSRUxBWV9QVUI6
MDoxNn3igKYiCmZpCgpNT09OX0lQPSJAQEVYSVRfSVBAQCIKcmVsYXlfeHJheT0iJChweXRob24z
IC0gIiRTRVJWSUNFX1ZMRVNTX1VVSUQiICIkUkVMQVlfRE9NQUlOIiAiJFJFTEFZX1BSSVYiICIk
UkVMQVlfU0lEIiBcCiAgIiRNT09OX0lQIiAiJE1BSU5fRE9NQUlOIiAiJE1PT05fUFVCS0VZIiAi
JE1PT05fU0hPUlRJRCIgIiRXU19QQVRIIiAiJFhIVFRQX1BBVEgiIDw8J1BZJwppbXBvcnQgc3lz
LGpzb24Kc3ZjX3V1aWQsZG9tYWluLHByaXYsc2lkLG1vb25faXAsbW9vbl9zbmksbW9vbl9wdWIs
bW9vbl9zaWQsd3NfcGF0aCx4aHR0cF9wYXRoPXN5cy5hcmd2WzE6XQpwcmludChqc29uLmR1bXBz
KHsKICAiaW5ib3VuZHMiOlsKICAgIHsidGFnIjoiU1VOLVJFQUxJVFkiLCJsaXN0ZW4iOiIwLjAu
MC4wIiwicG9ydCI6NDQzLCJwcm90b2NvbCI6InZsZXNzIiwKICAgICAic2V0dGluZ3MiOnsiY2xp
ZW50cyI6W10sImRlY3J5cHRpb24iOiJub25lIn0sCiAgICAgInN0cmVhbVNldHRpbmdzIjp7Im5l
dHdvcmsiOiJ0Y3AiLCJzZWN1cml0eSI6InJlYWxpdHkiLAogICAgICAgInJlYWxpdHlTZXR0aW5n
cyI6eyJzaG93IjpGYWxzZSwiZGVzdCI6IjEyNy4wLjAuMTo4NDQzIiwKICAgICAgICAgInNlcnZl
ck5hbWVzIjpbZG9tYWluXSwicHJpdmF0ZUtleSI6cHJpdiwic2hvcnRJZHMiOltzaWRdfX0sCiAg
ICAgInNuaWZmaW5nIjp7ImVuYWJsZWQiOlRydWUsImRlc3RPdmVycmlkZSI6WyJodHRwIiwidGxz
IiwicXVpYyJdfX0sCiAgICB7InRhZyI6IlNVTi1XUyIsImxpc3RlbiI6IjEyNy4wLjAuMSIsInBv
cnQiOjIwNTMsInByb3RvY29sIjoidmxlc3MiLAogICAgICJzZXR0aW5ncyI6eyJjbGllbnRzIjpb
XSwiZGVjcnlwdGlvbiI6Im5vbmUifSwKICAgICAic3RyZWFtU2V0dGluZ3MiOnsibmV0d29yayI6
IndzIiwic2VjdXJpdHkiOiJub25lIiwid3NTZXR0aW5ncyI6eyJwYXRoIjp3c19wYXRofX19LAog
ICAgeyJ0YWciOiJTVU4tWEhUVFAiLCJsaXN0ZW4iOiIxMjcuMC4wLjEiLCJwb3J0IjoyMDU0LCJw
cm90b2NvbCI6InZsZXNzIiwKICAgICAic2V0dGluZ3MiOnsiY2xpZW50cyI6W10sImRlY3J5cHRp
b24iOiJub25lIn0sCiAgICAgInN0cmVhbVNldHRpbmdzIjp7Im5ldHdvcmsiOiJ4aHR0cCIsInNl
Y3VyaXR5Ijoibm9uZSIsCiAgICAgICAieGh0dHBTZXR0aW5ncyI6eyJwYXRoIjp4aHR0cF9wYXRo
fX19LAogICAgeyJ0YWciOiJTVU4tSFkyIiwibGlzdGVuIjoiMC4wLjAuMCIsInBvcnQiOjQ0Mywi
cHJvdG9jb2wiOiJoeXN0ZXJpYSIsCiAgICAgInNldHRpbmdzIjp7ImNsaWVudHMiOltdfSwKICAg
ICAic3RyZWFtU2V0dGluZ3MiOnsibmV0d29yayI6Imh5c3RlcmlhIiwic2VjdXJpdHkiOiJ0bHMi
LAogICAgICAgInRsc1NldHRpbmdzIjp7ImFscG4iOlsiaDMiXSwic2VydmVyTmFtZSI6ZG9tYWlu
LAogICAgICAgICAiY2VydGlmaWNhdGVzIjpbeyJjZXJ0aWZpY2F0ZUZpbGUiOiIvY2VydHMvaHky
LmNydCIsImtleUZpbGUiOiIvY2VydHMvaHkyLmtleSJ9XX0sCiAgICAgICAiaHlzdGVyaWFTZXR0
aW5ncyI6eyJ2ZXJzaW9uIjoyLCJ1ZHBJZGxlVGltZW91dCI6NjB9fX0KICBdLAogICJvdXRib3Vu
ZHMiOlsKICAgIHsidGFnIjoidG8tbW9vbmxpZ2h0IiwicHJvdG9jb2wiOiJ2bGVzcyIsCiAgICAg
InNldHRpbmdzIjp7InZuZXh0IjpbeyJhZGRyZXNzIjptb29uX2lwLCJwb3J0Ijo0NDMsCiAgICAg
ICAidXNlcnMiOlt7ImlkIjpzdmNfdXVpZCwiZW5jcnlwdGlvbiI6Im5vbmUiLCJmbG93IjoieHRs
cy1ycHJ4LXZpc2lvbiJ9XX1dfSwKICAgICAic3RyZWFtU2V0dGluZ3MiOnsibmV0d29yayI6InRj
cCIsInNlY3VyaXR5IjoicmVhbGl0eSIsCiAgICAgICAicmVhbGl0eVNldHRpbmdzIjp7InNlcnZl
ck5hbWUiOm1vb25fc25pLCJmaW5nZXJwcmludCI6ImNocm9tZSIsCiAgICAgICAgICJwdWJsaWNL
ZXkiOm1vb25fcHViLCJzaG9ydElkIjptb29uX3NpZH19fSwKICAgIHsidGFnIjoiZGlyZWN0Iiwi
cHJvdG9jb2wiOiJmcmVlZG9tIiwic2V0dGluZ3MiOnsiZG9tYWluU3RyYXRlZ3kiOiJVc2VJUHY0
In19LAogICAgeyJ0YWciOiJibG9jayIsInByb3RvY29sIjoiYmxhY2tob2xlIn0KICBdLAogICJk
bnMiOnsic2VydmVycyI6WyIxLjEuMS4xIiwiOC44LjguOCJdLCJxdWVyeVN0cmF0ZWd5IjoiVXNl
SVB2NCJ9LAogICJyb3V0aW5nIjp7ImRvbWFpblN0cmF0ZWd5IjoiQXNJcyIsInJ1bGVzIjpbCiAg
ICB7InR5cGUiOiJmaWVsZCIsImluYm91bmRUYWciOlsiU1VOLVJFQUxJVFkiLCJTVU4tV1MiLCJT
VU4tWEhUVFAiLCJTVU4tSFkyIl0sIm91dGJvdW5kVGFnIjoidG8tbW9vbmxpZ2h0In0KICBdfQp9
KSkKUFkKKSIgfHwgZGllICLQs9C10L3QtdGA0LDRhtC40Y8geHJheS3QutC+0L3RhNC40LPQsCBy
ZWxheSDQv9GA0L7QstCw0LvQuNC70LDRgdGMIgoKcGxpc3Q9IiQoYXBpIEdFVCAvY29uZmlnLXBy
b2ZpbGVzKSIgfHwgZGllICLRh9GC0LXQvdC40LUg0L/RgNC+0YTQuNC70LXQuSIKUkVMQVlfUFJP
RklMRV9VVUlEPSIkKHB5dGhvbjMgLSAiJHBsaXN0IiAiJFBST0ZJTEVfTkFNRSIgPDwnUFknCmlt
cG9ydCBzeXMsanNvbgpkPWpzb24ubG9hZHMoc3lzLmFyZ3ZbMV0pOyBhcnI9ZC5nZXQoInJlc3Bv
bnNlIix7fSkuZ2V0KCJjb25maWdQcm9maWxlcyIpIG9yIGQuZ2V0KCJjb25maWdQcm9maWxlcyIp
IG9yIChkIGlmIGlzaW5zdGFuY2UoZCxsaXN0KSBlbHNlIFtdKQpwcmludChuZXh0KCh4LmdldCgi
dXVpZCIpIGZvciB4IGluIGFyciBpZiBpc2luc3RhbmNlKHgsZGljdCkgYW5kIHguZ2V0KCJuYW1l
Iik9PXN5cy5hcmd2WzJdKSwiIikpClBZCikiCmlmIFsgLW4gIiRSRUxBWV9QUk9GSUxFX1VVSUQi
IF07IHRoZW4KICBvayAicmVsYXkt0L/RgNC+0YTQuNC70Ywg0YPQttC1INC10YHRgtGMOiAkUkVM
QVlfUFJPRklMRV9VVUlEIOKAlCDRg9C00LDQu9GP0Y4g0Lgg0L/QtdGA0LXRgdC+0LfQtNCw0Y4g
KNC+0LHQvdC+0LLQu9C10L3QuNC1INC60L7QvdGE0LjQs9CwKSIKICBhcGkgREVMRVRFICIvY29u
ZmlnLXByb2ZpbGVzLyRSRUxBWV9QUk9GSUxFX1VVSUQiID4vZGV2L251bGwgMj4mMSB8fCB3YXJu
ICJERUxFVEUg0L/RgNC+0YTQuNC70Y8g0L3QtSDQv9GA0L7RiNGR0Lsg4oCUINCy0L7Qt9C80L7Q
ttC90L4g0YPQttC1INGD0LTQsNC70ZHQvSIKICBSRUxBWV9QUk9GSUxFX1VVSUQ9IiIKZmkKcGJv
ZHk9IiQocHl0aG9uMyAtICIkUFJPRklMRV9OQU1FIiA8PFBZCmltcG9ydCBzeXMsanNvbgpuYW1l
PXN5cy5hcmd2WzFdCmNvbmZpZz1qc29uLmxvYWRzKHIiIiIkcmVsYXlfeHJheSIiIikKcHJpbnQo
anNvbi5kdW1wcyh7Im5hbWUiOm5hbWUsImNvbmZpZyI6Y29uZmlnfSkpClBZCikiCnByb2Y9IiQo
YXBpIFBPU1QgL2NvbmZpZy1wcm9maWxlcyAiJHBib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQsNC9
0LjQtSByZWxheS3Qv9GA0L7RhNC40LvRjyDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQ
sdC60LgiClJFTEFZX1BST0ZJTEVfVVVJRD0iJChqdmFsICIkcHJvZiIgcmVzcG9uc2UudXVpZCki
OyBbIC1uICIkUkVMQVlfUFJPRklMRV9VVUlEIiBdIHx8IFJFTEFZX1BST0ZJTEVfVVVJRD0iJChq
dmFsICIkcHJvZiIgdXVpZCkiCm9rICJyZWxheS3Qv9GA0L7RhNC40LvRjCDRgdC+0LfQtNCw0L06
ICRSRUxBWV9QUk9GSUxFX1VVSUQiCklOQj0iJChhcGkgR0VUICIvY29uZmlnLXByb2ZpbGVzLyRS
RUxBWV9QUk9GSUxFX1VVSUQvaW5ib3VuZHMiKSIgfHwgdHJ1ZQpSRUxBWV9JTl9VVUlEUz0iJChw
eXRob24zIC0gIiRJTkIiIDw8J1BZJwppbXBvcnQgc3lzLGpzb24KdHJ5OiBhPWpzb24ubG9hZHMo
c3lzLmFyZ3ZbMV0pCmV4Y2VwdCBFeGNlcHRpb246IGE9W10KYT1hLmdldCgicmVzcG9uc2UiLGEp
IGlmIGlzaW5zdGFuY2UoYSxkaWN0KSBlbHNlIGEKYT1hLmdldCgiaW5ib3VuZHMiLGEpIGlmIGlz
aW5zdGFuY2UoYSxkaWN0KSBlbHNlIGEKaWYgbm90IGlzaW5zdGFuY2UoYSxsaXN0KTogYT1bXQpw
cmludChqc29uLmR1bXBzKFt4LmdldCgidXVpZCIpIGZvciB4IGluIGEgaWYgaXNpbnN0YW5jZSh4
LGRpY3QpIGFuZCB4LmdldCgidXVpZCIpXSkpClBZCikiCiMgVGFnLW1hcDogcm9idXN0IGxvb2t1
cCBmb3IgaG9zdCBjcmVhdGlvbiByZWdhcmRsZXNzIG9mIEFQSSByZXR1cm4gb3JkZXIKUkVMQVlf
SU5fVEFHX01BUD0iJChweXRob24zIC0gIiRJTkIiIDw8J1BZJwppbXBvcnQgc3lzLGpzb24KdHJ5
OiBhPWpzb24ubG9hZHMoc3lzLmFyZ3ZbMV0pCmV4Y2VwdCBFeGNlcHRpb246IGE9W10KYT1hLmdl
dCgicmVzcG9uc2UiLGEpIGlmIGlzaW5zdGFuY2UoYSxkaWN0KSBlbHNlIGEKYT1hLmdldCgiaW5i
b3VuZHMiLGEpIGlmIGlzaW5zdGFuY2UoYSxkaWN0KSBlbHNlIGEKaWYgbm90IGlzaW5zdGFuY2Uo
YSxsaXN0KTogYT1bXQpyZXN1bHQ9e30KZm9yIHggaW4gYToKICAgIGlmIG5vdCBpc2luc3RhbmNl
KHgsZGljdCkgb3Igbm90IHguZ2V0KCJ1dWlkIik6IGNvbnRpbnVlCiAgICB1aWQ9eC5nZXQoInV1
aWQiKQogICAgaWYgeC5nZXQoInRhZyIpOiByZXN1bHRbeFsidGFnIl1dPXVpZAogICAgcG9ydD1p
bnQoeC5nZXQoInBvcnQiLDApIG9yIDApCiAgICBsaXN0ZW49c3RyKHguZ2V0KCJsaXN0ZW4iLCIi
KSkKICAgIHByb3RvPXN0cih4LmdldCgicHJvdG9jb2wiLCIiKSkKICAgIGlmIHBvcnQ9PTIwNTM6
IHJlc3VsdC5zZXRkZWZhdWx0KCJTVU4tV1MiLHVpZCkKICAgIGVsaWYgcG9ydD09MjA1NDogcmVz
dWx0LnNldGRlZmF1bHQoIlNVTi1YSFRUUCIsdWlkKQogICAgZWxpZiBwb3J0PT00NDMgYW5kIHBy
b3RvPT0idmxlc3MiOiByZXN1bHQuc2V0ZGVmYXVsdCgiU1VOLVJFQUxJVFkiLHVpZCkKICAgIGVs
aWYgcG9ydD09NDQzIGFuZCBwcm90byBpbiAoImh5c3RlcmlhIiwiaHlzdGVyaWEyIik6IHJlc3Vs
dC5zZXRkZWZhdWx0KCJTVU4tSFkyIix1aWQpCnByaW50KGpzb24uZHVtcHMocmVzdWx0KSkKUFkK
KSIKb2sgItC40L3QsdCw0YPQvdC00YsgcmVsYXkt0L/RgNC+0YTQuNC70Y86ICRSRUxBWV9JTl9V
VUlEUyIKCiMg4pSA4pSAIDMuINC90L7QtNCwIFN1bnNoaW5lIOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsb2cgItCd0L7QtNCwICRSRUxB
WV9OQU1FICjQsNC00YDQtdGBOiAkUkVMQVlfSVApIgpub2RlX2JvZHk9IiQocHl0aG9uMyAtICIk
UkVMQVlfTkFNRSIgIiRSRUxBWV9JUCIgIiROT0RFX1BPUlQiICIkUkVMQVlfUFJPRklMRV9VVUlE
IiAiJFJFTEFZX0lOX1VVSURTIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCm5hbWUsYWRkcixwb3J0
LHByb2YsaW5zPXN5cy5hcmd2WzE6Nl0KcHJpbnQoanNvbi5kdW1wcyh7Im5hbWUiOm5hbWUsImFk
ZHJlc3MiOmFkZHIsInBvcnQiOmludChwb3J0KSwKICAiY29uZmlnUHJvZmlsZSI6eyJhY3RpdmVD
b25maWdQcm9maWxlVXVpZCI6cHJvZiwiYWN0aXZlSW5ib3VuZHMiOmpzb24ubG9hZHMoaW5zKX19
KSkKUFkKKSIKbmxpc3Q9IiQoYXBpIEdFVCAvbm9kZXMpIiB8fCBkaWUgItGH0YLQtdC90LjQtSDQ
vdC+0LQiClJFTEFZX05PREVfVVVJRD0iJChweXRob24zIC0gIiRubGlzdCIgIiRSRUxBWV9OQU1F
IiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCmQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IGFycj1k
LmdldCgicmVzcG9uc2UiKSBpZiBpc2luc3RhbmNlKGQsZGljdCkgZWxzZSBkCmlmIGlzaW5zdGFu
Y2UoYXJyLGRpY3QpOiBhcnI9YXJyLmdldCgibm9kZXMiKSBvciBhcnIuZ2V0KCJkYXRhIikgb3Ig
W10KcHJpbnQobmV4dCgobi5nZXQoInV1aWQiKSBmb3IgbiBpbiAoYXJyIG9yIFtdKSBpZiBpc2lu
c3RhbmNlKG4sZGljdCkgYW5kIG4uZ2V0KCJuYW1lIik9PXN5cy5hcmd2WzJdKSwiIikpClBZCiki
CmlmIFsgLW4gIiRSRUxBWV9OT0RFX1VVSUQiIF07IHRoZW4KICBvayAi0L3QvtC00LAg0YPQttC1
INC10YHRgtGMOiAkUkVMQVlfTk9ERV9VVUlEIOKAlCDQvtCx0L3QvtCy0LvRj9GOINC/0YDQvtGE
0LjQu9GMINGH0LXRgNC10LcgUEFUQ0ggKNC90LUg0L/QtdGA0LXRgdC+0LfQtNCw0Y4pIgogIGlm
IGFwaSBQQVRDSCAvbm9kZXMgIntcInV1aWRcIjpcIiRSRUxBWV9OT0RFX1VVSURcIixcImNvbmZp
Z1Byb2ZpbGVcIjp7XCJhY3RpdmVDb25maWdQcm9maWxlVXVpZFwiOlwiJFJFTEFZX1BST0ZJTEVf
VVVJRFwiLFwiYWN0aXZlSW5ib3VuZHNcIjokUkVMQVlfSU5fVVVJRFN9fSIgPi9kZXYvbnVsbCAy
PiYxOyB0aGVuCiAgICBvayAi0L/RgNC+0YTQuNC70Ywg0L3QvtC00Ysg0L7QsdC90L7QstC70ZHQ
vTogJFJFTEFZX05PREVfVVVJRCIKICBlbHNlCiAgICB3YXJuICJQQVRDSCDQvdC+0LTRiyDQvdC1
INC/0YDQvtGI0ZHQuyDigJQg0L/QtdGA0LXRgdC+0LfQtNCw0Y4gKFNFQ1JFVF9LRVkg0LzQvtC2
0LXRgiDRgdC80LXQvdC40YLRjNGB0Y8pIgogICAgYXBpIERFTEVURSAiL25vZGVzLyRSRUxBWV9O
T0RFX1VVSUQiID4vZGV2L251bGwgMj4mMSBcCiAgICAgIHx8IHdhcm4gIkRFTEVURSDQvdC+0LTR
iyDQvdC1INC/0YDQvtGI0ZHQuyDigJQg0L/QvtC/0YvRgtCw0Y7RgdGMINGB0L7Qt9C00LDRgtGM
INC90L7QstGD0Y4iCiAgICBSRUxBWV9OT0RFX1VVSUQ9IiIKICAgIG5vZGU9IiQoYXBpIFBPU1Qg
L25vZGVzICIkbm9kZV9ib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQsNC90LjQtSDQvdC+0LTRiyDi
gJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC60LgiCiAgICBSRUxBWV9OT0RFX1VVSUQ9
IiQoanZhbCAiJG5vZGUiIHJlc3BvbnNlLnV1aWQpIjsgWyAtbiAiJFJFTEFZX05PREVfVVVJRCIg
XSB8fCBSRUxBWV9OT0RFX1VVSUQ9IiQoanZhbCAiJG5vZGUiIHV1aWQpIgogICAgb2sgItC90L7Q
tNCwINC/0LXRgNC10YHQvtC30LTQsNC90LA6ICRSRUxBWV9OT0RFX1VVSUQiCiAgZmkKZWxzZQog
IG5vZGU9IiQoYXBpIFBPU1QgL25vZGVzICIkbm9kZV9ib2R5IikiIHx8IGRpZSAi0YHQvtC30LTQ
sNC90LjQtSDQvdC+0LTRiyDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC60LgiCiAg
UkVMQVlfTk9ERV9VVUlEPSIkKGp2YWwgIiRub2RlIiByZXNwb25zZS51dWlkKSI7IFsgLW4gIiRS
RUxBWV9OT0RFX1VVSUQiIF0gfHwgUkVMQVlfTk9ERV9VVUlEPSIkKGp2YWwgIiRub2RlIiB1dWlk
KSIKICBvayAi0L3QvtC00LAg0YHQvtC30LTQsNC90LA6ICRSRUxBWV9OT0RFX1VVSUQiCmZpCgoj
IOKUgOKUgCAzYi4g0JTQvtCx0LDQstC70Y/QtdC8INC40L3QsdCw0YPQvdC00YsgU3Vuc2hpbmUg
0LIgbWFpbiBzcXVhZCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICLQn9GA0LjQ
stGP0LfRi9Cy0LDRjiDQuNC90LHQsNGD0L3QtNGLICRSRUxBWV9OQU1FINC6IHNxdWFkINC4INC/
0L7Qu9GM0LfQvtCy0LDRgtC10LvRj9C8IgojINCx0LXRgNGR0Lwg0LLRgdC1IHNxdWFkJ9GLCnNx
dWFkcz0iJChhcGkgR0VUIC9pbnRlcm5hbC1zcXVhZHMgMj4vZGV2L251bGwpIiB8fCBzcXVhZHM9
IiIKU1FVQURfVVVJRD0iJChweXRob24zIC0gIiRzcXVhZHMiIDw8J1BZJwppbXBvcnQgc3lzLGpz
b24KdHJ5OgogIGQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IHI9ZC5nZXQoInJlc3BvbnNlIixk
KQogIGFycj1yLmdldCgiaW50ZXJuYWxTcXVhZHMiKSBpZiBpc2luc3RhbmNlKHIsZGljdCkgZWxz
ZSAociBpZiBpc2luc3RhbmNlKHIsbGlzdCkgZWxzZSBbXSkKICAjINC/0YDQtdC00L/QvtGH0LjR
gtCw0LXQvCBzcXVhZCDRgSDQuNC80LXQvdC10LwgJ21haW4nLCDQuNC90LDRh9C1INC/0LXRgNCy
0YvQuQogIG1haW49bmV4dCgocy5nZXQoInV1aWQiKSBmb3IgcyBpbiBhcnIgaWYgaXNpbnN0YW5j
ZShzLGRpY3QpIGFuZCBzLmdldCgibmFtZSIpPT0ibWFpbiIpLCIiKQogIHByaW50KG1haW4gb3Ig
bmV4dCgocy5nZXQoInV1aWQiKSBmb3IgcyBpbiBhcnIgaWYgaXNpbnN0YW5jZShzLGRpY3QpKSwi
IikpCmV4Y2VwdCBFeGNlcHRpb246IHByaW50KCIiKQpQWQopIgppZiBbIC1uICIkU1FVQURfVVVJ
RCIgXSAmJiBbIC1uICIkUkVMQVlfSU5fVVVJRFMiIF07IHRoZW4KICAjINC/0L7Qu9GD0YfQsNC1
0Lwg0YLQtdC60YPRidC40Lkg0YHQvtGB0YLQsNCyIHNxdWFkJ9CwCiAgc3FfZGF0YT0iJChhcGkg
R0VUICIvaW50ZXJuYWwtc3F1YWRzLyRTUVVBRF9VVUlEIiAyPi9kZXYvbnVsbCkiIHx8IHNxX2Rh
dGE9IiIKICAjINC30LDQs9GA0YPQttCw0LXQvCDQv9GA0LXQtNGL0LTRg9GJ0LjQtSDQuNC90LHQ
sNGD0L3QtNGLIFN1bnNoaW5lINC40Lcg0YTQsNC50LvQsCAo0YfRgtC+0LHRiyDRg9C00LDQu9C4
0YLRjCDRg9GB0YLQsNGA0LXQstGI0LjQtSkKICBfb2xkX3JlbGF5X2ZpbGU9Ii9vcHQvJFNMVUcv
LnJlbGF5LWluYm91bmQtdXVpZHMiCiAgX29sZF9yZWxheV9pbj0iJChbIC1mICIkX29sZF9yZWxh
eV9maWxlIiBdICYmIGNhdCAiJF9vbGRfcmVsYXlfZmlsZSIgfHwgZWNobyAnW10nKSIKICAjINC3
0LDQvNC10L3Rj9C10Lwg0YHRgtCw0YDRi9C1INC40L3QsdCw0YPQvdC00YsgU3Vuc2hpbmUg0LIg
c3F1YWQg0L3QsCDQvdC+0LLRi9C1ICjQvdC1INC90LDQutCw0L/Qu9C40LLQsNC10Lwg0YHRgtC1
0LnQuykKICBuZXdfaW5ib3VuZHM9IiQocHl0aG9uMyAtICIkc3FfZGF0YSIgIiRSRUxBWV9JTl9V
VUlEUyIgIiRfb2xkX3JlbGF5X2luIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnRyeToKICBkPWpz
b24ubG9hZHMoc3lzLmFyZ3ZbMV0pOyByPWQuZ2V0KCJyZXNwb25zZSIsZCkKICBleGlzdGluZz1y
LmdldCgiaW5ib3VuZHMiKSBvciBbXQogIGV4aXN0aW5nPVt4LmdldCgidXVpZCIpIGlmIGlzaW5z
dGFuY2UoeCxkaWN0KSBlbHNlIHggZm9yIHggaW4gZXhpc3RpbmddCiAgbmV3PWpzb24ubG9hZHMo
c3lzLmFyZ3ZbMl0pCiAgb2xkPXNldChqc29uLmxvYWRzKHN5cy5hcmd2WzNdKSkKICAjINGD0LTQ
sNC70Y/QtdC8INGD0YHRgtCw0YDQtdCy0YjQuNC1IFN1bnNoaW5lLdC40L3QsdCw0YPQvdC00Ysg
KNC60L7RgtC+0YDRi9C1INCx0YvQu9C4INCyINC/0YDQvtGI0LvRi9C5INGA0LDQtyksINC00L7Q
sdCw0LLQu9GP0LXQvCDQvdC+0LLRi9C1CiAgbWVyZ2VkPVt4IGZvciB4IGluIGV4aXN0aW5nIGlm
IHggbm90IGluIG9sZF0rbmV3CiAgbWVyZ2VkPWxpc3QoZGljdC5mcm9ta2V5cyhtZXJnZWQpKQog
IHByaW50KGpzb24uZHVtcHMobWVyZ2VkKSkKZXhjZXB0IEV4Y2VwdGlvbjogcHJpbnQoc3lzLmFy
Z3ZbMl0pClBZCikiCiAgaWYgX3NxX3Jlc3VsdD0iJChhcGkgUEFUQ0ggIi9pbnRlcm5hbC1zcXVh
ZHMiIFwKICAgICJ7XCJ1dWlkXCI6XCIkU1FVQURfVVVJRFwiLFwiaW5ib3VuZHNcIjokbmV3X2lu
Ym91bmRzfSIgMj4mMSkiOyB0aGVuCiAgICBvayAi0LjQvdCx0LDRg9C90LTRiyAkUkVMQVlfTkFN
RSDQvtCx0L3QvtCy0LvQtdC90Ysg0LIgc3F1YWQgJFNRVUFEX1VVSUQgKNGD0YHRgtCw0YDQtdCy
0YjQuNC1INGD0LTQsNC70LXQvdGLKSIKICAgIHByaW50ZiAnJXMnICIkUkVMQVlfSU5fVVVJRFMi
ID4gIiRfb2xkX3JlbGF5X2ZpbGUiCiAgZWxzZQogICAgd2FybiAi0L3QtSDRg9C00LDQu9C+0YHR
jCDQvtCx0L3QvtCy0LjRgtGMINC40L3QsdCw0YPQvdC00Ysg0LIgc3F1YWQ6ICRfc3FfcmVzdWx0
IgogICAgd2FybiAi0LTQvtCx0LDQstGMINCy0YDRg9GH0L3Rg9GOINCyINC/0LDQvdC10LvQuCDi
hpIgSW50ZXJuYWwgU3F1YWRzIOKGkiBtYWluIOKGkiDQtNC+0LHQsNCy0LjRgtGMINC40L3QsdCw
0YPQvdC00YsgU3Vuc2hpbmUiCiAgZmkKZWxzZQogIHdhcm4gInNxdWFkINC90LUg0L3QsNC50LTQ
tdC9IOKAlCDQtNC+0LHQsNCy0Ywg0LjQvdCx0LDRg9C90LTRiyBTdW5zaGluZSDQstGA0YPRh9C9
0YPRjiDQsiDQv9Cw0L3QtdC70Lgg4oaSIEludGVybmFsIFNxdWFkcyIKZmkKCgoKIyDilIDilIAg
M2MuINCh0LXRgNCy0LjRgS3RjtC30LXRgCDQutCw0YHQutCw0LTQsCDihpIgbWFpbiBzcXVhZCAo
0LjQtNC10LzQv9C+0YLQtdC90YLQvdC+ICsg0LLQtdGA0LjRhNC40LrQsNGG0LjRjyArIHNlbGYt
aGVhbCkg4pSA4pSACiMg0K3QotCeINCa0JvQrtCn0JXQktCe0Jkg0KjQkNCTOiDQsdC10LcgVVVJ
RCDQutCw0YHQutCw0LQt0Y7Qt9C10YDQsCDQsiBjbGllbnRzINC40L3QsdCw0YPQvdC00L7QsiBN
b29ubGlnaHQg0JLQodCVCiMgdmlhLVN1bnNoaW5lINGB0L7QtdC00LjQvdC10L3QuNGPINC/0LDQ
tNCw0Y7RgiAodGxzOiBpbnRlcm5hbCBlcnJvciAvIGJhZCBIVFRQIHZlcnNpb24gLyBFT0YpLgps
b2cgItCS0LLQvtC20YMg0YHQtdGA0LLQuNGBLdGO0LfQtdGA0LAg0LrQsNGB0LrQsNC00LAg0LIg
c3F1YWQgJyQoWyAtbiAiJFNRVUFEX1VVSUQiIF0gJiYgZWNobyBtYWluKScg0Lgg0L/RgNC+0LLQ
tdGA0Y/RjiDQutCw0YHQutCw0LQgZW5kLXRvLWVuZCIKaWYgWyAteiAiJFNRVUFEX1VVSUQiIF0g
fHwgWyAteiAiJFNFUlZJQ0VfVVVJRCIgXTsgdGhlbgogIHdhcm4gItC90LXRgiBTUVVBRF9VVUlE
L1NFUlZJQ0VfVVVJRCDigJQg0LrQsNGB0LrQsNC0INC90LDRgdGC0YDQvtC40YLRjCDQvdC10LvR
jNC30Y8iCmVsc2UKICAjICgxKSDRiNGC0LDRgtC90YvQuSDQv9GD0YLRjCDigJQg0YfQtdGA0LXQ
tyBBUEkg0L/QsNC90LXQu9C4ICjRgtGA0LjQs9Cz0LXRgNC40YIg0LDQstGC0L4t0L/Rg9GIINC6
0L7QvdGE0LjQs9CwINC90LAg0L3QvtC00YspCiAgaWYgYXBpIFBBVENIICIvdXNlcnMiICJ7XCJ1
dWlkXCI6XCIkU0VSVklDRV9VVUlEXCIsXCJhY3RpdmVJbnRlcm5hbFNxdWFkc1wiOltcIiRTUVVB
RF9VVUlEXCJdfSIgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBvayAiQVBJOiDRgdC10YDQstC4
0YEt0Y7Qt9C10YAg0LTQvtCx0LDQstC70LXQvSDQsiBzcXVhZCAkU1FVQURfVVVJRCIKICBlbHNl
CiAgICB3YXJuICJBUEkgUEFUQ0ggL3VzZXJzINC90LUg0L/RgNC+0YjRkdC7IOKAlCDQv9GA0LjQ
vNC10L3RjiDQs9Cw0YDQsNC90YLQuNGOINGH0LXRgNC10Lcg0JHQlCIKICBmaQoKICAjICgyKSDQ
s9Cw0YDQsNC90YLQuNGPINGH0LXRgNC10Lcg0JHQlDog0YfQu9C10L3RgdGC0LLQviDQsiBzcXVh
ZCAo0LjQtNC10LzQv9C+0YLQtdC90YLQvdC+KSArINCw0LrRgtC40LLQvdGL0Lkg0YHRgtCw0YLR
g9GBLgogICMgICAgIHhyYXkg0LLQutC70Y7Rh9Cw0LXRgiDQsiBjbGllbnRzINGC0L7Qu9GM0LrQ
viDQsNC60YLQuNCy0L3Ri9GFINGO0LfQtdGA0L7Qsi3Rh9C70LXQvdC+0LIg0L/RgNC40LLRj9C3
0LDQvdC90L7Qs9C+IHNxdWFkLgogIGlmIGRvY2tlciBleGVjIC1pIHJlbW5hd2F2ZS1kYiBwc3Fs
IC1VIHBvc3RncmVzIC1kIHBvc3RncmVzIC12IE9OX0VSUk9SX1NUT1A9MSA+L2Rldi9udWxsIDI+
JjEgPDxTUUwKSU5TRVJUIElOVE8gaW50ZXJuYWxfc3F1YWRfbWVtYmVycyAoaW50ZXJuYWxfc3F1
YWRfdXVpZCwgdXNlcl9pZCkKU0VMRUNUICckU1FVQURfVVVJRCcsICckU0VSVklDRV9VVUlEJwpX
SEVSRSBOT1QgRVhJU1RTICgKICBTRUxFQ1QgMSBGUk9NIGludGVybmFsX3NxdWFkX21lbWJlcnMK
ICAgV0hFUkUgaW50ZXJuYWxfc3F1YWRfdXVpZD0nJFNRVUFEX1VVSUQnIEFORCB1c2VyX2lkPSck
U0VSVklDRV9VVUlEJyk7ClNRTAogIHRoZW4KICAgIG9rICLQkdCUOiDRh9C70LXQvdGB0YLQstC+
INGB0LXRgNCy0LjRgS3RjtC30LXRgNCwINCyIHNxdWFkINC/0L7QtNGC0LLQtdGA0LbQtNC10L3Q
viIKICBlbHNlCiAgICB3YXJuICLQkdCULdGE0L7Qu9Cx0Y3QuiDRh9C70LXQvdGB0YLQstCwINC9
0LUg0L7RgtGA0LDQsdC+0YLQsNC7IOKAlCDQv9GA0L7QstC10YDRjCDRgdGF0LXQvNGDIGludGVy
bmFsX3NxdWFkX21lbWJlcnMiCiAgZmkKCiAgIyDRhNGD0L3QutGG0LjRjyDQv9GA0L7QstC10YDQ
utC4OiDQv9GA0LjRgdGD0YLRgdGC0LLRg9C10YIg0LvQuCBTRVJWSUNFX1VVSUQg0LIg0LbQuNCy
0L7QvCDQutC+0L3RhNC40LPQtSBleGl0LdC90L7QtNGLCiAgX3V1aWRfaW5fZXhpdCgpewogICAg
ZG9ja2VyIGV4ZWMgLWkgcmVtbmFub2RlIHB5dGhvbjMgLSAiJDEiIDI+L2Rldi9udWxsIDw8J1BZ
JwppbXBvcnQgc3lzLGpzb24sb3MsZ2xvYixodHRwLmNsaWVudCxzb2NrZXQKd2FudD1zeXMuYXJn
dlsxXQpzb2Nrcz1nbG9iLmdsb2IoJy9ydW4vcmVtbmF3YXZlLWludGVybmFsLSouc29jaycpCmlm
IG5vdCBzb2Nrczogc3lzLmV4aXQoMikKcGlkPShvcy5wb3BlbigncGdyZXAgcnctY29yZScpLnJl
YWQoKS5zdHJpcCgpIG9yICcwJykuc3BsaXQoKVswXQp0b2s9JycKdHJ5OgogIGZvciBwIGluIG9w
ZW4oJy9wcm9jLyVzL2NtZGxpbmUnJXBpZCkucmVhZCgpLnNwbGl0KCdceDAwJyk6CiAgICBpZiAn
dG9rZW49JyBpbiBwOiB0b2s9cC5zcGxpdCgndG9rZW49JywxKVsxXTsgYnJlYWsKZXhjZXB0IEV4
Y2VwdGlvbjogc3lzLmV4aXQoMikKY2xhc3MgVShodHRwLmNsaWVudC5IVFRQQ29ubmVjdGlvbik6
CiAgZGVmIF9faW5pdF9fKHMscCk6IHN1cGVyKCkuX19pbml0X18oJ2xvY2FsaG9zdCcpOyBzLnA9
cAogIGRlZiBjb25uZWN0KHMpOgogICAgc289c29ja2V0LnNvY2tldChzb2NrZXQuQUZfVU5JWCxz
b2NrZXQuU09DS19TVFJFQU0pOyBzby5jb25uZWN0KHMucCk7IHMuc29jaz1zbwp0cnk6CiAgYz1V
KHNvY2tzWzBdKTsgYy5yZXF1ZXN0KCdHRVQnLCcvaW50ZXJuYWwvZ2V0LWNvbmZpZz90b2tlbj0n
K3RvaykKICBjZmc9anNvbi5sb2FkcyhjLmdldHJlc3BvbnNlKCkucmVhZCgpKQpleGNlcHQgRXhj
ZXB0aW9uOiBzeXMuZXhpdCgyKQpmb3IgaSBpbiBjZmcuZ2V0KCdpbmJvdW5kcycsW10pOgogIGZv
ciBjbCBpbiBpLmdldCgnc2V0dGluZ3MnLHt9KS5nZXQoJ2NsaWVudHMnLFtdKToKICAgIGlmIGNs
LmdldCgnaWQnKT09d2FudDogc3lzLmV4aXQoMCkKc3lzLmV4aXQoMSkKUFkKICB9CgogICMgKDMp
INC/0LXRgNCy0LjRh9C90LDRjyDQv9GA0L7QstC10YDQutCwOiDQttC00ZHQvCDQsNCy0YLQvi3Q
v9GD0Ygg0L/QsNC90LXQu9C4ICjQtNC+IDMw0YEpCiAgbG9nICLQn9GA0L7QstC10YDRj9GOLCDR
h9GC0L4g0LrQsNGB0LrQsNC0LdGO0LfQtdGAINC/0L7Qv9Cw0Lsg0LIg0LjQvdCx0LDRg9C90LTR
iyAkRVhJVF9OQU1FICjQsNCy0YLQvi3Qv9GD0Ygg0L/QsNC90LXQu9C4KeKApiIKICBfc2Vlbj0w
CiAgZm9yIF9pIGluIDEgMiAzIDQgNSA2OyBkbyBfdXVpZF9pbl9leGl0ICIkU0VSVklDRV9WTEVT
U19VVUlEIiAmJiB7IF9zZWVuPTE7IGJyZWFrOyB9OyBzbGVlcCA1OyBkb25lCgogICMgKDQpIHNl
bGYtaGVhbDog0LXRgdC70Lgg0L3QtSDQv9C+0Y/QstC40LvRgdGPIOKAlCDRhNC+0YDRgdC40Lwg
ZXhpdC3QvdC+0LTRgyDQv9C10YDQtdGH0LjRgtCw0YLRjCDQutC+0L3RhNC40LMKICBpZiBbICIk
X3NlZW4iID0gMCBdOyB0aGVuCiAgICB3YXJuICLQt9CwIDMw0YEg0L3QtSDQv9C+0Y/QstC40LvR
gdGPIOKAlCDRhNC+0YDRgdC40YDRg9GOINC+0LHQvdC+0LLQu9C10L3QuNC1INC60L7QvdGE0LjQ
s9CwIGV4aXQt0L3QvtC00YsgJEVYSVRfTkFNRSIKICAgIEVYSVRfTk9ERV9VVUlEPSIkKGFwaSBH
RVQgL25vZGVzIDI+L2Rldi9udWxsIHwgcHl0aG9uMyAtICIkRVhJVF9OQU1FIiA8PCdQWScKaW1w
b3J0IHN5cyxqc29uCnRyeToKICBkPWpzb24ubG9hZHMoc3lzLnN0ZGluLnJlYWQoKSk7IHI9ZC5n
ZXQoInJlc3BvbnNlIixkKQogIGFycj1yLmdldCgibm9kZXMiKSBpZiBpc2luc3RhbmNlKHIsZGlj
dCkgZWxzZSAociBpZiBpc2luc3RhbmNlKHIsbGlzdCkgZWxzZSBbXSkKICBwcmludChuZXh0KChu
LmdldCgidXVpZCIpIGZvciBuIGluIChhcnIgb3IgW10pIGlmIGlzaW5zdGFuY2UobixkaWN0KSBh
bmQgbi5nZXQoIm5hbWUiKT09c3lzLmFyZ3ZbMV0pLCIiKSkKZXhjZXB0IEV4Y2VwdGlvbjogcHJp
bnQoIiIpClBZCikiCiAgICBfa2lja2VkPTAKICAgIGlmIFsgLW4gIiRFWElUX05PREVfVVVJRCIg
XTsgdGhlbgogICAgICBhcGkgUE9TVCAiL25vZGVzLyRFWElUX05PREVfVVVJRC9hY3Rpb25zL3Jl
c3RhcnQiID4vZGV2L251bGwgMj4mMSAmJiB7IF9raWNrZWQ9MTsgb2sgImV4aXQt0L3QvtC00LAg
0L/QtdGA0LXQt9Cw0L/Rg9GJ0LXQvdCwINGH0LXRgNC10LcgQVBJIjsgfQogICAgZmkKICAgIFsg
IiRfa2lja2VkIiA9IDAgXSAmJiB7IGRvY2tlciByZXN0YXJ0IHJlbW5hbm9kZSA+L2Rldi9udWxs
IDI+JjEgJiYgb2sgImV4aXQt0L3QvtC00LAgKHJlbW5hbm9kZSkg0L/QtdGA0LXQt9Cw0L/Rg9GJ
0LXQvdCwINC70L7QutCw0LvRjNC90L4iIHx8IHdhcm4gItC90LUg0YHQvNC+0LMg0L/QtdGA0LXQ
t9Cw0L/Rg9GB0YLQuNGC0YwgZXhpdC3QvdC+0LTRgyI7IH0KICAgICMg0LbQtNGR0Lwg0L/QvtC0
0YrRkdC80LAg0L3QvtC00Ysg0Lgg0L/QvtCy0YLQvtGA0L3QviDQv9GA0L7QstC10YDRj9C10Lwg
KNC00L4gNzXRgSkKICAgIGZvciBfaSBpbiAkKHNlcSAxIDE1KTsgZG8gX3V1aWRfaW5fZXhpdCAi
JFNFUlZJQ0VfVkxFU1NfVVVJRCIgJiYgeyBfc2Vlbj0xOyBicmVhazsgfTsgc2xlZXAgNTsgZG9u
ZQogIGZpCgogICMgKDUpINC40YLQvtCzINC60LDRgdC60LDQtNCwCiAgaWYgWyAiJF9zZWVuIiA9
IDEgXTsgdGhlbgogICAgb2sgItCa0JDQodCa0JDQlCDQntCaOiAkU0VSVklDRV9WTEVTU19VVUlE
INC/0YDQuNGB0YPRgtGB0YLQstGD0LXRgiDQsiDQuNC90LHQsNGD0L3QtNCw0YUgJEVYSVRfTkFN
RSDigJQgdmlhLSRSRUxBWV9OQU1FINC30LDRgNCw0LHQvtGC0LDQtdGCIgogIGVsc2UKICAgIHdh
cm4gItGB0LXRgNCy0LjRgS3RjtC30LXRgCDQstGB0ZEg0LXRidGRINC90LUg0LLQuNC00LXQvSDQ
siDQuNC90LHQsNGD0L3QtNCw0YUgJEVYSVRfTkFNRSDigJQg0LrQsNGB0LrQsNC0INCd0JUg0LfQ
sNGA0LDQsdC+0YLQsNC10YIiCiAgICB3YXJuICLQtNC40LDQs9C90L7RgdGC0LjQutCwOiBkb2Nr
ZXIgZXhlYyByZW1uYXdhdmUtZGIgcHNxbCAtVSBwb3N0Z3JlcyAtZCBwb3N0Z3JlcyAtYyBcIlNF
TEVDVCAqIEZST00gaW50ZXJuYWxfc3F1YWRfbWVtYmVycyBXSEVSRSB1c2VyX2lkPSckU0VSVklD
RV9VVUlEJztcIiIKICBmaQpmaQojIOKUgOKUgCA0LiBTRUNSRVRfS0VZIOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsb2cgIlNFQ1JF
VF9LRVkg0LTQu9GPICRSRUxBWV9OQU1FIgpORElSPSIvb3B0LyRTTFVHIjsgbWtkaXIgLXAgIiRO
RElSIgpTRUNSRVRfS0VZPSIiCiMg0KfQuNGB0YLRi9C5IHJlLXJ1bjog0L/QtdGA0LXQuNGB0L/Q
vtC70YzQt9GD0LXQvCDRgdGD0YnQtdGB0YLQstGD0Y7RidC40LkgU0VDUkVUX0tFWSwg0YfRgtC+
0LHRiyDRg9C20LUg0YDQsNC30LLRkdGA0L3Rg9GC0LDRjwojINC90L7QtNCwICRSRUxBWV9OQU1F
INC90LUg0L7RgtCy0LDQu9C40LvQsNGB0Ywg0Lgg0L3QtSDRgtGA0LXQsdC+0LLQsNC70YHRjyDQ
v9C+0LLRgtC+0YDQvdGL0Lkgc2V0dXAtcmVsYXktc3NoLnNoLgpmb3IgX2YgaW4gIiRORElSL25v
ZGUtJHtSRUxBWV9OQU1FfS5lbnYiICIkTkRJUi9yZWxheS1ib290c3RyYXAuZW52IjsgZG8KICBp
ZiBbIC1mICIkX2YiIF07IHRoZW4KICAgIF9rPSIkKGdyZXAgJ15TRUNSRVRfS0VZPScgIiRfZiIg
fCBjdXQgLWQ9IC1mMi0pIgogICAgWyAtbiAiJF9rIiBdICYmIHsgU0VDUkVUX0tFWT0iJF9rIjsg
b2sgIlNFQ1JFVF9LRVkg0L/QtdGA0LXQuNGB0L/QvtC70YzQt9C+0LLQsNC9INC40LcgJChiYXNl
bmFtZSAiJF9mIikgKNC00LvQuNC90LAgJHsjU0VDUkVUX0tFWX0pIjsgYnJlYWs7IH0KICBmaQpk
b25lCmlmIFsgLXogIiRTRUNSRVRfS0VZIiBdOyB0aGVuCiAga2c9IiQoYXBpIEdFVCAva2V5Z2Vu
KSIgfHwgd2FybiAia2V5Z2VuINC90LUg0L7RgtCy0LXRgtC40LsiCiAgZm9yIGYgaW4gcmVzcG9u
c2UucHViS2V5IHJlc3BvbnNlLnNlY3JldEtleSByZXNwb25zZS5jZXJ0IHB1YktleSBzZWNyZXRL
ZXk7IGRvCiAgICBTRUNSRVRfS0VZPSIkKGp2YWwgIiRrZyIgIiRmIiAyPi9kZXYvbnVsbCkiOyBb
IC1uICIkU0VDUkVUX0tFWSIgXSAmJiBicmVhawogIGRvbmUKICBbIC1uICIkU0VDUkVUX0tFWSIg
XSB8fCBkaWUgItC90LUg0L/QvtC70YPRh9C40LsgU0VDUkVUX0tFWSDQuNC3IGtleWdlbiIKICBv
ayAiU0VDUkVUX0tFWSDQv9C+0LvRg9GH0LXQvSDQuNC3IGtleWdlbiAo0LTQu9C40L3QsCAkeyNT
RUNSRVRfS0VZfSkiCmZpCnByaW50ZiAnTk9ERV9QT1JUPSVzXG5TRUNSRVRfS0VZPSVzXG4nICIk
Tk9ERV9QT1JUIiAiJFNFQ1JFVF9LRVkiID4gIiRORElSL25vZGUtJHtSRUxBWV9OQU1FfS5lbnYi
Cm9rICJTRUNSRVRfS0VZINC30LDQv9C40YHQsNC9INCyICRORElSL25vZGUtJHtSRUxBWV9OQU1F
fS5lbnYgKNC00LvQuNC90LAgJHsjU0VDUkVUX0tFWX0pIgoKIyDilIDilIAgNS4gcmVsYXktYm9v
dHN0cmFwLmVudiDihpIg0L3QsCBTdW5zaGluZSDRh9C10YDQtdC3IFNDUCDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIAKbG9nICLQn9Cw0LrRg9GOIHJlbGF5LWJvb3RzdHJhcC5lbnYiCmNhdCA+ICIv
b3B0LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiIDw8RU9GCiMg0JDQstGC0L7Qs9C10L3QtdGA
0LjRgNC+0LLQsNC90L4gcHJvdmlzaW9uLXJlbGF5LnNoIOKAlCDQvdC1INGA0LXQtNCw0LrRgtC4
0YDQvtCy0LDRgtGMINCy0YDRg9GH0L3Rg9GOClNMVUc9JFNMVUcKUkVMQVlfTkFNRT0kUkVMQVlf
TkFNRQpSRUxBWV9ET01BSU49JFJFTEFZX0RPTUFJTgpFWElUX05BTUU9JEVYSVRfTkFNRQpFWElU
X0lQPSRNT09OX0lQCk1BSU5fRE9NQUlOPSRNQUlOX0RPTUFJTgpNT09OX1BVQktFWT0kTU9PTl9Q
VUJLRVkKTU9PTl9TSE9SVElEPSRNT09OX1NIT1JUSUQKTU9PTl9JUD0kTU9PTl9JUApTRVJWSUNF
X1VVSUQ9JFNFUlZJQ0VfVVVJRApTRVJWSUNFX1ZMRVNTX1VVSUQ9JFNFUlZJQ0VfVkxFU1NfVVVJ
RApSRUxBWV9OT0RFX1VVSUQ9JFJFTEFZX05PREVfVVVJRApSRUxBWV9QUklWPSRSRUxBWV9QUklW
ClJFTEFZX1BVQj0kUkVMQVlfUFVCClJFTEFZX1NJRD0kUkVMQVlfU0lECldTX1BBVEg9JFdTX1BB
VEgKWEhUVFBfUEFUSD0kWEhUVFBfUEFUSApOT0RFX1BPUlQ9JE5PREVfUE9SVApTRUNSRVRfS0VZ
PSRTRUNSRVRfS0VZCkVPRgpvayAicmVsYXktYm9vdHN0cmFwLmVudiDQs9C+0YLQvtCyOiAvb3B0
LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiCgojIOKUgOKUgCA2LiDQpdC+0YHRgtGLIHZpYSBT
dW5zaGluZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbG9nICLQ
odC+0LfQtNCw0Y4v0L7QsdC90L7QstC70Y/RjiDRhdC+0YHRgtGLIHZpYSAkUkVMQVlfTkFNRSIK
X2FsbF9ob3N0cz0iJChhcGkgR0VUIC9ob3N0cyAyPi9kZXYvbnVsbCkiIHx8IF9hbGxfaG9zdHM9
IiIKX2lkeD0wCmZvciB0YWdfc3VmZml4IGluIFJFQUxJVFkgV1MgWEhUVFAgSFkyOyBkbwogIF94
cmF5X3RhZz0iU1VOLSR7dGFnX3N1ZmZpeH0iCiAgSU5fVVVJRD0iJChweXRob24zIC1jICJpbXBv
cnQganNvbjsgbT1qc29uLmxvYWRzKCckUkVMQVlfSU5fVEFHX01BUCcpOyBwcmludChtLmdldCgn
JF94cmF5X3RhZycsJycpKSIgMj4vZGV2L251bGwpIiB8fCBJTl9VVUlEPSIiCiAgWyAteiAiJElO
X1VVSUQiIF0gJiYgSU5fVVVJRD0iJChweXRob24zIC1jICJpbXBvcnQganNvbjsgYT1qc29uLmxv
YWRzKCckUkVMQVlfSU5fVVVJRFMnKTsgcHJpbnQoYVskX2lkeF0gaWYgbGVuKGEpPiRfaWR4IGVs
c2UgJycpIiAyPi9kZXYvbnVsbCkiIHx8IHRydWUKICBbIC16ICIkSU5fVVVJRCIgXSAmJiB7IF9p
ZHg9JCgoX2lkeCsxKSk7IGNvbnRpbnVlOyB9CiAgY2FzZSAiJHRhZ19zdWZmaXgiIGluCiAgICBS
RUFMSVRZKSBfcmVtYXJrPSJ2aWEgJHtSRUxBWV9OQU1FfSDCtyBWTEVTUy1SRUFMSVRZIgogICAg
ICAgICAgICAgX2JvZHk9IntcInJlbWFya1wiOlwiJF9yZW1hcmtcIixcImFkZHJlc3NcIjpcIiRS
RUxBWV9ET01BSU5cIixcInBvcnRcIjo0NDMsCiAgICAgICAgICAgICAgIFwiaW5ib3VuZFwiOntc
ImNvbmZpZ1Byb2ZpbGVVdWlkXCI6XCIkUkVMQVlfUFJPRklMRV9VVUlEXCIsXCJjb25maWdQcm9m
aWxlSW5ib3VuZFV1aWRcIjpcIiRJTl9VVUlEXCJ9LAogICAgICAgICAgICAgICBcInNlY3VyaXR5
TGF5ZXJcIjpcIkRFRkFVTFRcIixcInNuaVwiOlwiJFJFTEFZX0RPTUFJTlwiLFwiZmluZ2VycHJp
bnRcIjpcImNocm9tZVwiLAogICAgICAgICAgICAgICBcInB1YmxpY0tleVwiOlwiJFJFTEFZX1BV
QlwiLFwic2hvcnRJZFwiOlwiJFJFTEFZX1NJRFwifSIgOzsKICAgIFdTKSAgICAgIF9yZW1hcms9
InZpYSAke1JFTEFZX05BTUV9IMK3IFZMRVNTLVdTIgogICAgICAgICAgICAgIyDQktCQ0JbQndCe
OiDQv9C+0LvQtSDQvdCw0LfRi9Cy0LDQtdGC0YHRjyBzZWN1cml0eUxheWVyLCDQsCDQvdC1IHNl
Y3VyaXR5IOKAlCDRgSDQvdC10LLQtdGA0L3Ri9C8CiAgICAgICAgICAgICAjINC40LzQtdC90LXQ
vCBBUEkg0LzQvtC70YfQsCDQuNCz0L3QvtGA0LjRgNGD0LXRgiDQt9C90LDRh9C10L3QuNC1INC4
INC/0L7QtNGB0YLQsNCy0LvRj9C10YIgREVGQVVMVCAoUkVBTElUWSkKICAgICAgICAgICAgICMg
0LLQvNC10YHRgtC+IFRMUywg0YfRgtC+INC/0L7Qu9C90L7RgdGC0YzRjiDQu9C+0LzQsNC10YIg
V1MvWEhUVFAt0YLRgNCw0L3RgdC/0L7RgNGCLgogICAgICAgICAgICAgIyBhbHBuINCd0JUg0YTQ
vtGA0YHQuNC8IChDYWRkeSDQsdC10LcgcHJvdG9jb2xzIGgxKSDigJQg0LrQu9C40LXQvdGCINGB
0LDQvCDQtNC+0LPQvtCy0L7RgNC40YLRgdGPCiAgICAgICAgICAgICAjINC90LAgaDIsINGH0YLQ
viDQtNCw0ZHRgiBYSFRUUCDQvNGD0LvRjNGC0LjQv9C70LXQutGB0LjRgNC+0LLQsNC90LjQtSDQ
stC80LXRgdGC0L4g0LrRg9GH0Lgg0L7RgtC00LXQu9GM0L3Ri9GFCiAgICAgICAgICAgICAjIFRD
UC3RhdC10L3QtNGI0LXQudC60L7QsiDRh9C10YDQtdC3IFJFQUxJVFkt0YTQvtC70LHRjdC6INC9
0LAg0L3QtdGB0YLQsNCx0LjQu9GM0L3Ri9GFINGB0LXRgtGP0YUuCiAgICAgICAgICAgICBfYm9k
eT0ie1wicmVtYXJrXCI6XCIkX3JlbWFya1wiLFwiYWRkcmVzc1wiOlwiJFJFTEFZX0RPTUFJTlwi
LFwicG9ydFwiOjQ0MywKICAgICAgICAgICAgICAgXCJpbmJvdW5kXCI6e1wiY29uZmlnUHJvZmls
ZVV1aWRcIjpcIiRSRUxBWV9QUk9GSUxFX1VVSURcIixcImNvbmZpZ1Byb2ZpbGVJbmJvdW5kVXVp
ZFwiOlwiJElOX1VVSURcIn0sCiAgICAgICAgICAgICAgIFwic2VjdXJpdHlMYXllclwiOlwiVExT
XCIsXCJzbmlcIjpcIiRSRUxBWV9ET01BSU5cIixcImhvc3RcIjpcIiRSRUxBWV9ET01BSU5cIixc
InBhdGhcIjpcIiRXU19QQVRIXCJ9IiA7OwogICAgWEhUVFApICAgX3JlbWFyaz0idmlhICR7UkVM
QVlfTkFNRX0gwrcgVkxFU1MtWEhUVFAiCiAgICAgICAgICAgICBfYm9keT0ie1wicmVtYXJrXCI6
XCIkX3JlbWFya1wiLFwiYWRkcmVzc1wiOlwiJFJFTEFZX0RPTUFJTlwiLFwicG9ydFwiOjQ0MywK
ICAgICAgICAgICAgICAgXCJpbmJvdW5kXCI6e1wiY29uZmlnUHJvZmlsZVV1aWRcIjpcIiRSRUxB
WV9QUk9GSUxFX1VVSURcIixcImNvbmZpZ1Byb2ZpbGVJbmJvdW5kVXVpZFwiOlwiJElOX1VVSURc
In0sCiAgICAgICAgICAgICAgIFwic2VjdXJpdHlMYXllclwiOlwiVExTXCIsXCJzbmlcIjpcIiRS
RUxBWV9ET01BSU5cIixcImhvc3RcIjpcIiRSRUxBWV9ET01BSU5cIixcInBhdGhcIjpcIiRYSFRU
UF9QQVRIXCJ9IiA7OwogICAgSFkyKSAgICAgX3JlbWFyaz0idmlhICR7UkVMQVlfTkFNRX0gwrcg
SHlzdGVyaWEyIgogICAgICAgICAgICAgX2JvZHk9IntcInJlbWFya1wiOlwiJF9yZW1hcmtcIixc
ImFkZHJlc3NcIjpcIiRSRUxBWV9ET01BSU5cIixcInBvcnRcIjo0NDMsCiAgICAgICAgICAgICAg
IFwiaW5ib3VuZFwiOntcImNvbmZpZ1Byb2ZpbGVVdWlkXCI6XCIkUkVMQVlfUFJPRklMRV9VVUlE
XCIsXCJjb25maWdQcm9maWxlSW5ib3VuZFV1aWRcIjpcIiRJTl9VVUlEXCJ9LAogICAgICAgICAg
ICAgICBcInNlY3VyaXR5TGF5ZXJcIjpcIlRMU1wiLFwic25pXCI6XCIkUkVMQVlfRE9NQUlOXCIs
XCJhbHBuXCI6XCJoM1wifSIgOzsKICBlc2FjCiAgIyDRg9C00LDQu9GP0LXQvCDRgdGC0LDRgNGL
0Lkg0YXQvtGB0YIg0YEg0YLQtdC8INC20LUgcmVtYXJrINC/0LXRgNC10LQg0YHQvtC30LTQsNC9
0LjQtdC8ICjRh9GC0L7QsdGLINC+0LHQvdC+0LLQuNGC0YwgaW5ib3VuZCBVVUlEKQogIF9vbGRf
aG9zdF91dWlkPSIkKHB5dGhvbjMgLSAiJF9hbGxfaG9zdHMiICIkX3JlbWFyayIgPDwnUFknCmlt
cG9ydCBzeXMsanNvbgp0cnk6CiAgZD1qc29uLmxvYWRzKHN5cy5hcmd2WzFdKTsgcj1kLmdldCgi
cmVzcG9uc2UiLGQpCiAgYXJyPXIuZ2V0KCJob3N0cyIscikgaWYgaXNpbnN0YW5jZShyLGRpY3Qp
IGVsc2UgcgogIGlmIG5vdCBpc2luc3RhbmNlKGFycixsaXN0KTogYXJyPVtdCiAgcHJpbnQobmV4
dCgoaC5nZXQoInV1aWQiKSBmb3IgaCBpbiBhcnIgaWYgaXNpbnN0YW5jZShoLGRpY3QpIGFuZCBo
LmdldCgicmVtYXJrIik9PXN5cy5hcmd2WzJdKSwiIikpCmV4Y2VwdCBFeGNlcHRpb246IHByaW50
KCIiKQpQWQopIgogIFsgLW4gIiRfb2xkX2hvc3RfdXVpZCIgXSAmJiB7IGFwaSBERUxFVEUgIi9o
b3N0cy8kX29sZF9ob3N0X3V1aWQiID4vZGV2L251bGwgMj4mMSBcCiAgICAmJiBvayAi0YHRgtCw
0YDRi9C5INGF0L7RgdGCINGD0LTQsNC70ZHQvTogJF9yZW1hcmsiIFwKICAgIHx8IHdhcm4gItC9
0LUg0YPQtNCw0LvQvtGB0Ywg0YPQtNCw0LvQuNGC0Ywg0YHRgtCw0YDRi9C5INGF0L7RgdGCICRf
b2xkX2hvc3RfdXVpZCI7IH0KICBhcGkgUE9TVCAvaG9zdHMgIiRfYm9keSIgPi9kZXYvbnVsbCAy
PiYxIFwKICAgICYmIG9rICLRhdC+0YHRgiDRgdC+0LfQtNCw0L06ICRfcmVtYXJrIiBcCiAgICB8
fCB3YXJuICLQvdC1INGD0LTQsNC70L7RgdGMINGB0L7Qt9C00LDRgtGMINGF0L7RgdGCICckX3Jl
bWFyayciCiAgX2lkeD0kKChfaWR4KzEpKQpkb25lCgplY2hvCmVjaG8gIuKVkOKVkOKVkOKVkCDQ
k9Ce0KLQntCS0J4g4pWQ4pWQ4pWQ4pWQIgplY2hvICIgIHJlbGF5LWJvb3RzdHJhcC5lbnY6IC9v
cHQvJFNMVUcvcmVsYXktYm9vdHN0cmFwLmVudiIKZWNobyAiICDQodC70LXQtNGD0Y7RidC40Lkg
0YjQsNCzOiBzZXR1cC1yZWxheS1zc2guc2gg0YHQutC+0L/QuNGA0YPQtdGCINC10LPQviDQvdCw
ICRSRUxBWV9OQU1FINC4INC30LDQv9GD0YHRgtC40YIg0LTQtdC/0LvQvtC5Igo=
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
vdC10LvQuCAo0J3QlSAxMjcuMC4wLjEpIOKAlCDQsNC60YLRg9Cw0LvQuNC30LjRgNGD0LXQvC4K
IyDQktCQ0JbQndCeOiBhY3RpdmVJbmJvdW5kcyDRgtC+0LbQtSDQv9Cw0YLRh9C40Lwg0LrQsNC2
0LTRi9C5INGA0LDQtyDigJQg0LjQvdCw0YfQtSDQv9GA0Lgg0L/QvtCy0YLQvtGA0L3QvtC8IHBy
b3Zpc2lvbi5zaAojICjQvdC+0LTQsCDRg9C20LUg0YHRg9GJ0LXRgdGC0LLRg9C10YIpINC90L7Q
stGL0LUv0L/QtdGA0LXRgdC+0LfQtNCw0L3QvdGL0LUg0LjQvdCx0LDRg9C90LTRiyDQv9GA0L7R
hNC40LvRjyAo0L3QsNC/0YAuIFhIVFRQKSDQvdC1CiMg0L/QvtC/0LDQtNGD0YIg0LIg0LDQutGC
0LjQstC90YvQuSDRgdC/0LjRgdC+0Log0L3QvtC00YssINC4IFhyYXkg0LjRhSDQv9GA0L7RgdGC
0L4g0L3QtSDQv9C+0LTQvdC40LzQtdGCLgphcGkgUEFUQ0ggL25vZGVzICJ7XCJ1dWlkXCI6XCIk
Tk9ERV9VVUlEXCIsXCJhZGRyZXNzXCI6XCIkTk9ERV9BRERSRVNTXCIsXCJwb3J0XCI6JE5PREVf
UE9SVCxcImNvbmZpZ1Byb2ZpbGVcIjp7XCJhY3RpdmVDb25maWdQcm9maWxlVXVpZFwiOlwiJFBS
T0ZJTEVfVVVJRFwiLFwiYWN0aXZlSW5ib3VuZHNcIjokSU5fVVVJRFN9fSIgPi9kZXYvbnVsbCAy
PiYxIFwKICAmJiBvayAi0LDQtNGA0LXRgSDQuCDQsNC60YLQuNCy0L3Ri9C1INC40L3QsdCw0YPQ
vdC00Ysg0L3QvtC00Ysg0L7QsdC90L7QstC70LXQvdGLOiAkTk9ERV9BRERSRVNTOiROT0RFX1BP
UlQiIHx8IHdhcm4gIlBBVENIINC90L7QtNGLINC90LUg0L/RgNC+0YjRkdC7IOKAlCDQv9GA0L7Q
stC10YDRjCDQstGA0YPRh9C90YPRjiIKIyBTRUNSRVRfS0VZINC90L7QtNGLINC40Lcga2V5Z2Vu
IEFQSSDihpIgLmVudiDQutC+0L3RgtC10LnQvdC10YDQsCDQvdC+0LTRiyAo0LLQvNC10YHRgtC+
INGA0YPRh9C90L7QuSDQstGB0YLQsNCy0LrQuCkKa2c9IiQoYXBpIEdFVCAva2V5Z2VuKSIgfHwg
d2FybiAia2V5Z2VuINC90LUg0L7RgtCy0LXRgtC40LsiClNFQ1JFVF9LRVk9IiIKZm9yIGYgaW4g
cmVzcG9uc2UucHViS2V5IHJlc3BvbnNlLnNlY3JldEtleSByZXNwb25zZS5jZXJ0IHB1YktleSBz
ZWNyZXRLZXk7IGRvCiAgU0VDUkVUX0tFWT0iJChqdmFsICIka2ciICIkZiIpIjsgWyAtbiAiJFNF
Q1JFVF9LRVkiIF0gJiYgYnJlYWsKZG9uZQppZiBbIC1uICIkU0VDUkVUX0tFWSIgXTsgdGhlbgog
IE5ESVI9Ii9vcHQvJFNMVUcvbm9kZSI7IG1rZGlyIC1wICIkTkRJUiIKICB7IGVjaG8gIk5PREVf
UE9SVD0ke05PREVfUE9SVH0iOyBlY2hvICJTRUNSRVRfS0VZPSR7U0VDUkVUX0tFWX0iOyB9ID4g
IiRORElSLy5lbnYiCiAgb2sgIlNFQ1JFVF9LRVkg0L3QvtC00Ysg0LfQsNC/0LjRgdCw0L0g0LIg
JE5ESVIvLmVudiAo0LTQu9C40L3QsCAkeyNTRUNSRVRfS0VZfSkiCmVsc2UKICB3YXJuICLQvdC1
INC90LDRiNGR0Lsg0LrQu9GO0Ycg0LIg0L7RgtCy0LXRgtC1IGtleWdlbiDigJQg0YHRgtGA0YPQ
utGC0YPRgNGDINCz0LvRj9C90LXQvCAo0YHQutC40L3RjDogYXBpIEdFVCAva2V5Z2VuKSIKZmkK
CiMg4pSA4pSAIDUuIGludGVybmFsIHNxdWFkIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAgIyBWRVJJRlkgcGF5bG9hZApsb2cgIklu
dGVybmFsIHNxdWFkIgpzcXVhZHM9IiQoYXBpIEdFVCAvaW50ZXJuYWwtc3F1YWRzKSIgfHwgZGll
ICLRgdC/0LjRgdC+0Log0YHQutCy0LDQtNC+0LIg4oCUINGB0LrQuNC90Ywg0LHQu9C+0Log0L7R
iNC40LHQutC4IgpTUVVBRF9VVUlEPSIkKHB5dGhvbjMgLSAiJHNxdWFkcyIgIiRTUVVBRF9OQU1F
IiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCmQ9anNvbi5sb2FkcyhzeXMuYXJndlsxXSk7IAphcnI9
ZC5nZXQoInJlc3BvbnNlIix7fSkuZ2V0KCJpbnRlcm5hbFNxdWFkcyIpIG9yIGQuZ2V0KCJpbnRl
cm5hbFNxdWFkcyIpIG9yIChkIGlmIGlzaW5zdGFuY2UoZCxsaXN0KSBlbHNlIFtdKQpwcmludChu
ZXh0KChzLmdldCgidXVpZCIpIGZvciBzIGluIGFyciBpZiBpc2luc3RhbmNlKHMsZGljdCkgYW5k
IHMuZ2V0KCJuYW1lIik9PXN5cy5hcmd2WzJdKSwiIikpClBZCikiCmlmIFsgLXogIiRTUVVBRF9V
VUlEIiBdOyB0aGVuCiAgc3FfYm9keT0iJChweXRob24zIC0gIiRTUVVBRF9OQU1FIiAiJElOX1VV
SURTIiA8PCdQWScKaW1wb3J0IHN5cyxqc29uCnByaW50KGpzb24uZHVtcHMoeyJuYW1lIjpzeXMu
YXJndlsxXSwiaW5ib3VuZHMiOmpzb24ubG9hZHMoc3lzLmFyZ3ZbMl0pfSkpClBZCikiCiAgc3E9
IiQoYXBpIFBPU1QgL2ludGVybmFsLXNxdWFkcyAiJHNxX2JvZHkiKSIgfHwgZGllICLRgdC+0LfQ
tNCw0L3QuNC1INGB0LrQstCw0LTQsCDigJQg0YHQutC40L3RjCDQsdC70L7QuiDQvtGI0LjQsdC6
0LgiCiAgU1FVQURfVVVJRD0iJChqdmFsICIkc3EiIHJlc3BvbnNlLnV1aWQpIjsgWyAtbiAiJFNR
VUFEX1VVSUQiIF0gfHwgU1FVQURfVVVJRD0iJChqdmFsICIkc3EiIHV1aWQpIgogIG9rICJzcXVh
ZCAnJFNRVUFEX05BTUUnINGB0L7Qt9C00LDQvTogJFNRVUFEX1VVSUQiCmVsc2UKICBvayAic3F1
YWQg0YPQttC1INC10YHRgtGMOiAkU1FVQURfVVVJRCIKICAjINCS0JDQltCd0J46INGB0LrQstCw
0LQg0LzQvtCzINC+0YLRgdGC0LDRgtGMINC+0YIg0YLQtdC60YPRidC10LPQviDQvdCw0LHQvtGA
0LAg0LjQvdCx0LDRg9C90LTQvtCyINC/0YDQvtGE0LjQu9GPICjQvdCw0L/RgC4g0L/QvtGB0LvQ
tQogICMg0YHQvNC10L3Riy/QtNC+0LHQsNCy0LvQtdC90LjRjyDQuNC90LHQsNGD0L3QtNCwINGC
0LjQv9CwIFhIVFRQKSDigJQg0LTQvtC70LjQstCw0LXQvCDQvdC10LTQvtGB0YLQsNGO0YnQuNC1
INGH0LXRgNC10LcgdW5pb24sCiAgIyDQodCe0KXQoNCQ0J3Qr9CvINGD0LbQtSDQv9GA0LjRgdGD
0YLRgdGC0LLRg9GO0YnQuNC1ICjQsiDRgi7Rhy4g0YfRg9C20LjQtSDigJQg0L3QsNC/0YAuIHZp
YS1TdW5zaGluZSksINGH0YLQvtCx0Ysg0L3QtQogICMg0L/QvtCy0YLQvtGA0LjRgtGMINC40YHR
gtC+0YDQuNGH0LXRgdC60LjQuSDQsdCw0LMg0YEg0L7QsdC90YPQu9C10L3QuNC10Lwgc3F1YWQg
0L/RgNC4IFBBVENIINGC0L7Qu9GM0LrQviDRgdCy0L7QuNC80LgKICAjINC40L3QsdCw0YPQvdC0
0LDQvNC4LiBQQVRDSCDQuNC00LXQvNC/0L7RgtC10L3RgtC10L06INC10YHQu9C4INC90LjRh9C1
0LPQviDQvdC1INC40LfQvNC10L3QuNC70L7RgdGMIOKAlCDRgdC/0LjRgdC+0Log0YLQvtGCINC2
0LUuCiAgc3FfY3VyPSIkKGFwaSBHRVQgIi9pbnRlcm5hbC1zcXVhZHMvJFNRVUFEX1VVSUQiKSIg
fHwgc3FfY3VyPSIiCiAgbWVyZ2VkX2luYm91bmRzPSIkKHB5dGhvbjMgLSAiJHNxX2N1ciIgIiRJ
Tl9VVUlEUyIgPDwnUFknCmltcG9ydCBzeXMsanNvbgp0cnk6CiAgICBkPWpzb24ubG9hZHMoc3lz
LmFyZ3ZbMV0pOyByPWQuZ2V0KCJyZXNwb25zZSIsZCkKICAgIGV4aXN0aW5nPVt4LmdldCgidXVp
ZCIpIGlmIGlzaW5zdGFuY2UoeCxkaWN0KSBlbHNlIHggZm9yIHggaW4gKHIuZ2V0KCJpbmJvdW5k
cyIpIG9yIFtdKV0KZXhjZXB0IEV4Y2VwdGlvbjoKICAgIGV4aXN0aW5nPVtdCm5ldz1qc29uLmxv
YWRzKHN5cy5hcmd2WzJdKQptZXJnZWQ9bGlzdChkaWN0LmZyb21rZXlzKGV4aXN0aW5nK25ldykp
CnByaW50KGpzb24uZHVtcHMobWVyZ2VkKSkKUFkKKSIKICBhcGkgUEFUQ0ggL2ludGVybmFsLXNx
dWFkcyAie1widXVpZFwiOlwiJFNRVUFEX1VVSURcIixcImluYm91bmRzXCI6JG1lcmdlZF9pbmJv
dW5kc30iID4vZGV2L251bGwgMj4mMSBcCiAgICAmJiBvayAic3F1YWQ6INC40L3QsdCw0YPQvdC0
0Ysg0L/RgNC+0YTQuNC70Y8g0LTQvtC70LjQstCw0L3RiyDRh9C10YDQtdC3IHVuaW9uICjRgdGD
0YnQtdGB0YLQstGD0Y7RidC40LUg0L3QtSDRgtGA0L7QvdGD0YLRiykiIFwKICAgIHx8IHdhcm4g
ItC90LUg0YPQtNCw0LvQvtGB0Ywg0LTQvtC70LjRgtGMINC40L3QsdCw0YPQvdC00Ysg0LIgc3F1
YWQg4oCUINC/0YDQvtCy0LXRgNGMINCy0YDRg9GH0L3Rg9GOIgpmaQoKIyDilIDilIAgNi4g0L/Q
vtC70YzQt9C+0LLQsNGC0LXQu9GMIFRlc3Qg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICAjIFZFUklGWSBwYXlsb2FkCmxvZyAi0J/QvtC70YzQ
t9C+0LLQsNGC0LXQu9GMICRURVNUX1VTRVIiCnVzZXJfYm9keT0iJChweXRob24zIC0gIiRURVNU
X1VTRVIiICIkU1FVQURfVVVJRCIgPDwnUFknCmltcG9ydCBzeXMsanNvbgpwcmludChqc29uLmR1
bXBzKHsidXNlcm5hbWUiOnN5cy5hcmd2WzFdLCJ0cmFmZmljTGltaXRCeXRlcyI6MCwidHJhZmZp
Y0xpbWl0U3RyYXRlZ3kiOiJOT19SRVNFVCIsCiAgImV4cGlyZUF0IjoiMjA5OS0wMS0wMVQwMDow
MDowMC4wMDBaIiwiYWN0aXZlSW50ZXJuYWxTcXVhZHMiOltzeXMuYXJndlsyXV0gaWYgc3lzLmFy
Z3ZbMl0gZWxzZSBbXX0pKQpQWQopIgpleGlzdGluZz0iJChhcGkgR0VUICIvdXNlcnMvYnktdXNl
cm5hbWUvJFRFU1RfVVNFUiIgMj4vZGV2L251bGwpIiB8fCBleGlzdGluZz0iIgppZiBbIC1uICIk
ZXhpc3RpbmciIF07IHRoZW4KICBTSE9SVD0iJChqdmFsICIkZXhpc3RpbmciIHJlc3BvbnNlLnNo
b3J0VXVpZCkiOyBbIC1uICIkU0hPUlQiIF0gfHwgU0hPUlQ9IiQoanZhbCAiJGV4aXN0aW5nIiBz
aG9ydFV1aWQpIgogIFsgLW4gIiRTSE9SVCIgXSB8fCBTSE9SVD0iJChqdmFsICIkZXhpc3Rpbmci
IHJlc3BvbnNlLjAuc2hvcnRVdWlkKSIgMj4vZGV2L251bGwgfHwgdHJ1ZQogIFNVQl9VUkw9IiQo
anZhbCAiJGV4aXN0aW5nIiByZXNwb25zZS5zdWJzY3JpcHRpb25VcmwpIjsgWyAtbiAiJFNVQl9V
UkwiIF0gfHwgU1VCX1VSTD0iJChqdmFsICIkZXhpc3RpbmciIHN1YnNjcmlwdGlvblVybCkiCiAg
b2sgItC/0L7Qu9GM0LfQvtCy0LDRgtC10LvRjCDRg9C20LUg0LXRgdGC0YwgKHNob3J0VXVpZDog
JHtTSE9SVDotP30pIgplbHNlCiAgdXNyPSIkKGFwaSBQT1NUIC91c2VycyAiJHVzZXJfYm9keSIp
IiB8fCBkaWUgItGB0L7Qt9C00LDQvdC40LUg0Y7Qt9C10YDQsCDigJQg0YHQutC40L3RjCDQsdC7
0L7QuiDQvtGI0LjQsdC60LgiCiAgU1VCX1VSTD0iJChqdmFsICIkdXNyIiByZXNwb25zZS5zdWJz
Y3JpcHRpb25VcmwpIjsgWyAtbiAiJFNVQl9VUkwiIF0gfHwgU1VCX1VSTD0iJChqdmFsICIkdXNy
IiBzdWJzY3JpcHRpb25VcmwpIgogIFNIT1JUPSIkKGp2YWwgIiR1c3IiIHJlc3BvbnNlLnNob3J0
VXVpZCkiOyBbIC1uICIkU0hPUlQiIF0gfHwgU0hPUlQ9IiQoanZhbCAiJHVzciIgc2hvcnRVdWlk
KSIKICBvayAi0L/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINGB0L7Qt9C00LDQvSAoc2hvcnRVdWlk
OiAke1NIT1JUOi0/fSkiCmZpCiMg0LXRgdC70LggQVBJINC90LUg0L7RgtC00LDQuyBzaG9ydFV1
aWQg4oCUINCx0LXRgNGR0Lwg0L3QsNC/0YDRj9C80YPRjiDQuNC3INCR0JQgKNC90LDQtNGR0LbQ
vdGL0Lkg0YTQvtC70LHRjdC6KQppZiBbIC16ICIke1NIT1JUOi19IiBdOyB0aGVuCiAgU0hPUlQ9
IiQoZG9ja2VyIGV4ZWMgLWkgcmVtbmF3YXZlLWRiIHBzcWwgLVUgcG9zdGdyZXMgLWQgcG9zdGdy
ZXMgLXRBYyBcCiAgICAiU0VMRUNUIHNob3J0X3V1aWQgRlJPTSB1c2VycyBXSEVSRSB1c2VybmFt
ZT0nJFRFU1RfVVNFUicgTElNSVQgMTsiIDI+L2Rldi9udWxsIHwgdHIgLWQgJ1s6c3BhY2U6XScp
IiB8fCBTSE9SVD0iIgogIFsgLW4gIiRTSE9SVCIgXSAmJiBvayAic2hvcnRVdWlkINCy0LfRj9GC
INC40Lcg0JHQlDogJFNIT1JUIiB8fCB3YXJuICJzaG9ydFV1aWQg0L3QtSDQvdCw0LnQtNC10L0g
4oCUIFRFU1RfU1VCX1VVSUQg0LIgY29uZiDQvtGB0YLQsNC90LXRgtGB0Y8g0L/RgNC10LbQvdC4
0LwiCmZpCiMg0KDQldCQ0JvQrNCd0KvQmSBzaG9ydFV1aWQg0YLQtdGB0YIt0LrQu9C40LXQvdGC
0LAg4oaSINCyIGNvbmYg0L/QvtC0IFRFU1RfU1VCX1VVSUQsINGH0YLQvtCx0Ysgc2V0dXAtY29u
bmVjdC1taW4g0LLQt9GP0Lsg0LXQs9C+ICjQsCDQvdC1INC30LDQs9C70YPRiNC60YMpCmlmIFsg
LW4gIiR7U0hPUlQ6LX0iIF07IHRoZW4KICBDRj0iL29wdC8kU0xVRy8uZGVwbG95L2RlcGxveS5j
b25mIgogIGlmIFsgLWYgIiRDRiIgXTsgdGhlbgogICAgaWYgZ3JlcCAtcSAnXlRFU1RfU1VCX1VV
SUQ9JyAiJENGIjsgdGhlbiBzZWQgLWkgInN8XlRFU1RfU1VCX1VVSUQ9Lip8VEVTVF9TVUJfVVVJ
RD0kU0hPUlR8IiAiJENGIgogICAgZWxzZSBwcmludGYgJ1RFU1RfU1VCX1VVSUQ9JXNcbicgIiRT
SE9SVCIgPj4gIiRDRiI7IGZpCiAgICBvayAic2hvcnRVdWlkINGC0LXRgdGCLdC60LvQuNC10L3R
gtCwINC30LDQv9C40YHQsNC9INCyIGNvbmYgKCRTSE9SVCkiCiAgZmkKZmkKCiMg4pSA4pSAIDcu
IEhvc3RzICjQutC70LjQtdC90YLRgdC60LjQtSDQsNC00YDQtdGBL9C/0L7RgNGCL1NOSSDQvdCw
INC60LDQttC00YvQuSDQuNC90LHQsNGD0L3QtCkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICAjIFZFUklGWSBwYXlsb2Fk
CmxvZyAiSG9zdHMiCiMg0LrQsNGA0YLQsCBpbmJvdW5kVXVpZCAtPiDRgdGD0YnQtdGB0YLQstGD
0Y7RidC40LkgaG9zdFV1aWQgKNC00LvRjyB1cHNlcnQ6INGB0YLQsNGA0YvQuSDRhdC+0YHRgiDR
g9C00LDQu9GP0LXQvCDQuCDQv9C10YDQtdGB0L7Qt9C00LDRkdC8LAojINGH0YLQvtCx0Ysg0L/Q
vtCy0YLQvtGA0L3Ri9C5INC30LDQv9GD0YHQuiBwcm92aXNpb24uc2gg0L/QvtC00YXQstCw0YLR
i9Cy0LDQuyDQuNC30LzQtdC90LXQvdC40Y8g0LPQtdC90LXRgNCw0YLQvtGA0LAg4oCUINC90LDQ
v9GALiBzZWN1cml0eUxheWVyKQpFWElTVF9NQVA9IiQoYXBpIEdFVCAvaG9zdHMgMj4vZGV2L251
bGwgfCBweXRob24zIC1jICcKaW1wb3J0IHN5cyxqc29uCnRyeTogZD1qc29uLmxvYWQoc3lzLnN0
ZGluKQpleGNlcHQgRXhjZXB0aW9uOiBkPVtdCmFycj1kLmdldCgicmVzcG9uc2UiKSBpZiBpc2lu
c3RhbmNlKGQsZGljdCkgZWxzZSBkCmlmIGlzaW5zdGFuY2UoYXJyLGRpY3QpOiBhcnI9YXJyLmdl
dCgiaG9zdHMiKSBvciBbXQpvdXQ9e30KZm9yIGggaW4gKGFyciBvciBbXSk6CiAgICBpZiBub3Qg
aXNpbnN0YW5jZShoLGRpY3QpOiBjb250aW51ZQogICAgaXU9KGguZ2V0KCJpbmJvdW5kIikgb3Ig
e30pLmdldCgiY29uZmlnUHJvZmlsZUluYm91bmRVdWlkIik7IGh1PWguZ2V0KCJ1dWlkIikKICAg
IGlmIGl1IGFuZCBodTogb3V0W2l1XT1odQpwcmludChqc29uLmR1bXBzKG91dCkpCicpIjsgWyAt
biAiJEVYSVNUX01BUCIgXSB8fCBFWElTVF9NQVA9Int9IgpIT1NUU19KU09OPSIkKHB5dGhvbjMg
LSAiJFBST0ZJTEVfVVVJRCIgIiRET01BSU4iICIkWFJBWV9DT05GSUdfRklMRSIgIiRJTkIiICIk
RVhJU1RfTUFQIiAiJFJFQUxJVFlfUFVCTElDX0tFWSIgIiRSRUFMSVRZX1NIT1JUX0lEIiA8PCdQ
WScKaW1wb3J0IHN5cywganNvbgpwcm9mLCBkb21haW4sIGNmZ2YsIGluYiwgZXhpc3RfbWFwLCBw
dWJfa2V5LCBzaG9ydF9pZCA9IHN5cy5hcmd2WzFdLCBzeXMuYXJndlsyXSwgc3lzLmFyZ3ZbM10s
IHN5cy5hcmd2WzRdLCBzeXMuYXJndls1XSwgc3lzLmFyZ3ZbNl0sIHN5cy5hcmd2WzddCmNmZyA9
IGpzb24ubG9hZChvcGVuKGNmZ2YpKTsgY2ZnID0gY2ZnLmdldCgiaW5ib3VuZHMiLCBjZmcgaWYg
aXNpbnN0YW5jZShjZmcsIGxpc3QpIGVsc2UgW10pCnRyeTogYSA9IGpzb24ubG9hZHMoaW5iKQpl
eGNlcHQgRXhjZXB0aW9uOiBhID0gW10KYSA9IGEuZ2V0KCJyZXNwb25zZSIsIGEpIGlmIGlzaW5z
dGFuY2UoYSwgZGljdCkgZWxzZSBhCmEgPSBhLmdldCgiaW5ib3VuZHMiLCBhKSBpZiBpc2luc3Rh
bmNlKGEsIGRpY3QpIGVsc2UgYQppZiBub3QgaXNpbnN0YW5jZShhLCBsaXN0KTogYSA9IFtdCnRy
eTogZXhpc3RpbmcgPSBqc29uLmxvYWRzKGV4aXN0X21hcCkKZXhjZXB0IEV4Y2VwdGlvbjogZXhp
c3RpbmcgPSB7fQp0YWcydXVpZCA9IHt4LmdldCgidGFnIik6IHguZ2V0KCJ1dWlkIikgZm9yIHgg
aW4gYSBpZiBpc2luc3RhbmNlKHgsIGRpY3QpfQpvdXQgPSBbXQpmb3IgaWIgaW4gY2ZnOgogICAg
dGFnID0gaWIuZ2V0KCJ0YWciKTsgdXVpZCA9IHRhZzJ1dWlkLmdldCh0YWcpCiAgICBpZiBub3Qg
dXVpZDogY29udGludWUKICAgIHNzID0gaWIuZ2V0KCJzdHJlYW1TZXR0aW5ncyIsIHt9KSBvciB7
fQogICAgbmV0ID0gc3MuZ2V0KCJuZXR3b3JrIiwgInRjcCIpOyBzZWMgPSBzcy5nZXQoInNlY3Vy
aXR5IiwgIm5vbmUiKTsgcHJvdG8gPSBpYi5nZXQoInByb3RvY29sIiwgIiIpCiAgICBoID0geyJp
bmJvdW5kIjogeyJjb25maWdQcm9maWxlVXVpZCI6IHByb2YsICJjb25maWdQcm9maWxlSW5ib3Vu
ZFV1aWQiOiB1dWlkfSwKICAgICAgICAgInJlbWFyayI6ICh0YWcgb3IgcHJvdG8pWzo0MF0sICJh
ZGRyZXNzIjogZG9tYWluLCAicG9ydCI6IDQ0MywKICAgICAgICAgIl9vbGRfaG9zdF91dWlkIjog
ZXhpc3RpbmcuZ2V0KHV1aWQsICIiKX0KICAgIGlmIHNlYyA9PSAicmVhbGl0eSIgYW5kIG5ldCBp
biAoInhodHRwIiwgInNwbGl0aHR0cCIpOgogICAgICAgIHhzID0gc3MuZ2V0KCJ4aHR0cFNldHRp
bmdzIikgb3Igc3MuZ2V0KCJzcGxpdGh0dHBTZXR0aW5ncyIpIG9yIHt9CiAgICAgICAgc25zID0g
KHNzLmdldCgicmVhbGl0eVNldHRpbmdzIiwge30pIG9yIHt9KS5nZXQoInNlcnZlck5hbWVzIikg
b3IgW2RvbWFpbl0KICAgICAgICBoWyJwb3J0Il0gPSBpYi5nZXQoInBvcnQiLCA0NDMpCiAgICAg
ICAgaFsicGF0aCJdID0geHMuZ2V0KCJwYXRoIiwgIi8iKTsgaFsic25pIl0gPSBzbnNbMF07IGhb
ImZpbmdlcnByaW50Il0gPSAiY2hyb21lIjsgaFsic2VjdXJpdHlMYXllciJdID0gIkRFRkFVTFQi
CiAgICAgICAgaWYgcHViX2tleTogaFsicHVibGljS2V5Il0gPSBwdWJfa2V5CiAgICAgICAgaWYg
c2hvcnRfaWQ6IGhbInNob3J0SWQiXSA9IHNob3J0X2lkCiAgICBlbGlmIHNlYyA9PSAicmVhbGl0
eSI6CiAgICAgICAgc25zID0gKHNzLmdldCgicmVhbGl0eVNldHRpbmdzIiwge30pIG9yIHt9KS5n
ZXQoInNlcnZlck5hbWVzIikgb3IgW2RvbWFpbl0KICAgICAgICBoWyJzbmkiXSA9IHNuc1swXTsg
aFsiZmluZ2VycHJpbnQiXSA9ICJjaHJvbWUiOyBoWyJzZWN1cml0eUxheWVyIl0gPSAiREVGQVVM
VCIKICAgICAgICBpZiBwdWJfa2V5OiBoWyJwdWJsaWNLZXkiXSA9IHB1Yl9rZXkKICAgICAgICBp
ZiBzaG9ydF9pZDogaFsic2hvcnRJZCJdID0gc2hvcnRfaWQKICAgIGVsaWYgbmV0ID09ICJ3cyI6
CiAgICAgICAgIyBDYWRkeSDQvdCwIHNlbGZzdGVhbC3Qv9C+0YDRgtGDINCR0JXQlyDQvtCz0YDQ
sNC90LjRh9C10L3QuNGPIHByb3RvY29scyBoMSDigJQg0LrQu9C40LXQvdGCINGB0LDQvAogICAg
ICAgICMg0LTQvtCz0L7QstCw0YDQuNCy0LDQtdGC0YHRjyDQvdCwIGgyICjQtNCw0ZHRgiDQvNGD
0LvRjNGC0LjQv9C70LXQutGB0LjRgNC+0LLQsNC90LjQtSwg0LzQtdC90YzRiNC1INC+0YLQtNC1
0LvRjNC90YvRhSBUQ1AKICAgICAgICAjINGF0LXQvdC00YjQtdC50LrQvtCyINGH0LXRgNC10Lcg
UkVBTElUWS3RhNC+0LvQsdGN0Log4oCUINC60YDQuNGC0LjRh9C90L4g0LTQu9GPIFhIVFRQIHBh
Y2tldC11cCBtb2RlLAogICAgICAgICMg0LrQvtGC0L7RgNGL0Lkg0LjQvdCw0YfQtSDQvtGC0LrR
gNGL0LLQsNC10YIg0LzQvdC+0LPQviDQutC+0YDQvtGC0LrQuNGFINGB0L7QtdC00LjQvdC10L3Q
uNC5INC4INC70L7QstC40YIg0YLQsNC50LzQsNGD0YLRiwogICAgICAgICMg0L3QsCDQvdC10YHR
gtCw0LHQuNC70YzQvdGL0YUg0YHQtdGC0Y/RhSkuIGFscG4g0J3QlSDRhNC+0YDRgdC40Lwg4oCU
INC/0YPRgdGC0Ywg0LrQu9C40LXQvdGCINGA0LXRiNCw0LXRgiDRgdCw0LwuCiAgICAgICAgaFsi
cGF0aCJdID0gKHNzLmdldCgid3NTZXR0aW5ncyIsIHt9KSBvciB7fSkuZ2V0KCJwYXRoIiwgIi8i
KTsgaFsiaG9zdCJdID0gZG9tYWluOyBoWyJzbmkiXSA9IGRvbWFpbjsgaFsic2VjdXJpdHlMYXll
ciJdID0gIlRMUyIKICAgIGVsaWYgbmV0IGluICgieGh0dHAiLCAic3BsaXRodHRwIik6CiAgICAg
ICAgeHMgPSBzcy5nZXQoInhodHRwU2V0dGluZ3MiKSBvciBzcy5nZXQoInNwbGl0aHR0cFNldHRp
bmdzIikgb3Ige30KICAgICAgICBoWyJwYXRoIl0gPSB4cy5nZXQoInBhdGgiLCAiLyIpOyBoWyJz
bmkiXSA9IGRvbWFpbjsgaFsiaG9zdCJdID0gZG9tYWluOyBoWyJzZWN1cml0eUxheWVyIl0gPSAi
VExTIgogICAgZWxpZiBwcm90byBpbiAoImh5c3RlcmlhIiwgImh5c3RlcmlhMiIpOgogICAgICAg
IGhbInNuaSJdID0gZG9tYWluOyBoWyJhbHBuIl0gPSAiaDMiOyBoWyJzZWN1cml0eUxheWVyIl0g
PSAiVExTIgogICAgZWxzZToKICAgICAgICBoWyJzbmkiXSA9IGRvbWFpbjsgaFsic2VjdXJpdHlM
YXllciJdID0gIlRMUyIKICAgIG91dC5hcHBlbmQoaCkKZm9yIGggaW4gb3V0OiBwcmludChqc29u
LmR1bXBzKGgpKQpQWQopIgpIQ09VTlQ9MAp3aGlsZSBJRlM9IHJlYWQgLXIgaDsgZG8KICBbIC16
ICIkaCIgXSAmJiBjb250aW51ZQogIF9vbGRfdXVpZD0iJChwcmludGYgJyVzJyAiJGgiIHwgcHl0
aG9uMyAtYyAnaW1wb3J0IHN5cyxqc29uO3ByaW50KGpzb24ubG9hZChzeXMuc3RkaW4pLmdldCgi
X29sZF9ob3N0X3V1aWQiLCIiKSknIDI+L2Rldi9udWxsKSIgfHwgX29sZF91dWlkPSIiCiAgX2Jv
ZHk9IiQocHJpbnRmICclcycgIiRoIiB8IHB5dGhvbjMgLWMgJ2ltcG9ydCBzeXMsanNvbjtkPWpz
b24ubG9hZChzeXMuc3RkaW4pO2QucG9wKCJfb2xkX2hvc3RfdXVpZCIsTm9uZSk7cHJpbnQoanNv
bi5kdW1wcyhkKSknKSIKICBpZiBbIC1uICIkX29sZF91dWlkIiBdOyB0aGVuCiAgICBhcGkgREVM
RVRFICIvaG9zdHMvJF9vbGRfdXVpZCIgPi9kZXYvbnVsbCAyPiYxIHx8IHdhcm4gItC90LUg0YPQ
tNCw0LvQvtGB0Ywg0YPQtNCw0LvQuNGC0Ywg0YHRgtCw0YDRi9C5IGhvc3QgJF9vbGRfdXVpZCDi
gJQg0L/QtdGA0LXRgdC+0LfQtNCw0Lwg0L3QvtCy0YvQuSDRgNGP0LTQvtC8IgogIGZpCiAgYXBp
IFBPU1QgL2hvc3RzICIkX2JvZHkiID4vZGV2L251bGwgJiYgSENPVU5UPSQoKEhDT1VOVCsxKSkg
fHwgZGllICLRgdC+0LfQtNCw0L3QuNC1IGhvc3Qg4oCUINGB0LrQuNC90Ywg0LHQu9C+0Log0L7R
iNC40LHQutC4IChwYXlsb2FkOiAkX2JvZHkpIgpkb25lIDw8PCAiJEhPU1RTX0pTT04iCm9rICLQ
vtCx0L3QvtCy0LvQtdC90L4v0YHQvtC30LTQsNC90L4gSG9zdHM6ICRIQ09VTlQiCgojIOKUgOKU
gCBBUEkg0YLQvtC60LXQvSDQtNC70Y8gc3Vic2NyaXB0aW9uLXBhZ2Ug4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmxv
ZyAiQVBJINGC0L7QutC10L0g0LTQu9GPIHN1YnNjcmlwdGlvbi1wYWdlIgpTVUJfRU5WPSIvb3B0
LyRTTFVHL3N1Yi8uZW52IgpFWElTVElOR19UT0tFTj0iJChncmVwICdeUkVNTkFXQVZFX0FQSV9U
T0tFTj0nICIkU1VCX0VOViIgMj4vZGV2L251bGwgfCBjdXQgLWQ9IC1mMikiCmlmIFsgLW4gIiRF
WElTVElOR19UT0tFTiIgXTsgdGhlbgogIG9rICLRgtC+0LrQtdC9INGD0LbQtSDQv9GA0L7Qv9C4
0YHQsNC9INCyICRTVUJfRU5WIgplbHNlCiAgdG9rX3Jlc3A9IiQoYXBpIFBPU1QgL3Rva2VucyAi
e1widG9rZW5OYW1lXCI6XCJzdWItcGFnZS0kKGRhdGUgKyVZJW0lZClcIn0iKSIgfHwgdG9rX3Jl
c3A9IiIKICBBUElfVE9LRU49IiQocHl0aG9uMyAtYyAiaW1wb3J0IHN5cyxqc29uOyBkPWpzb24u
bG9hZHMoJyR0b2tfcmVzcCcpOyBwcmludChkLmdldCgncmVzcG9uc2UnLHt9KS5nZXQoJ3Rva2Vu
JywnJykpIiAyPi9kZXYvbnVsbCkiCiAgaWYgWyAtbiAiJEFQSV9UT0tFTiIgXTsgdGhlbgogICAg
aWYgZ3JlcCAtcSAnXlJFTU5BV0FWRV9BUElfVE9LRU49JyAiJFNVQl9FTlYiIDI+L2Rldi9udWxs
OyB0aGVuCiAgICAgIHNlZCAtaSAic3xeUkVNTkFXQVZFX0FQSV9UT0tFTj0uKnxSRU1OQVdBVkVf
QVBJX1RPS0VOPSRBUElfVE9LRU58IiAiJFNVQl9FTlYiCiAgICBlbHNlCiAgICAgIGVjaG8gIlJF
TU5BV0FWRV9BUElfVE9LRU49JEFQSV9UT0tFTiIgPj4gIiRTVUJfRU5WIgogICAgZmkKICAgIGRv
Y2tlciByZXN0YXJ0IHJlbW5hd2F2ZS1zdWJzY3JpcHRpb24tcGFnZSA+L2Rldi9udWxsIDI+JjEg
JiYgb2sgInN1YnNjcmlwdGlvbi1wYWdlINC/0LXRgNC10LfQsNC/0YPRidC10L3QsCDRgSDRgtC+
0LrQtdC90L7QvCIgfHwgdHJ1ZQogIGVsc2UKICAgIHdhcm4gItC90LUg0YPQtNCw0LvQvtGB0Ywg
0YHQvtC30LTQsNGC0YwgQVBJINGC0L7QutC10L0g4oCUINC30LDQudC00Lgg0LIg0L/QsNC90LXQ
u9GMIOKGkiBTZXR0aW5ncyDihpIgQVBJIFRva2VucyDihpIg0YHQvtC30LTQsNC5INCy0YDRg9GH
0L3Rg9GOINC4INC/0YDQvtC/0LjRiNC4INCyICRTVUJfRU5WIgogIGZpCmZpCgojIOKUgOKUgCDQ
uNGC0L7QsyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZWNobzsgZWNobyAi
JChjICcxOzMyJyAn4pWQ4pWQ4pWQ4pWQINCT0J7QotCe0JLQniDilZDilZDilZDilZAnKSIKZWNo
byAiICDQn9Cw0L3QtdC70Yw6ICBodHRwczovLyR7RE9NQUlOfS8iClsgIiRNQURFX0FETUlOIiA9
IDEgXSAmJiBlY2hvICIgINCQ0LTQvNC40L06ICAgJEFETUlOX1VTRVIgIC8gICRBRE1JTl9QQVNT
IgplY2hvICIgINCU0L7RgdGC0YPQv9GLOiAkQ1JFRF9GSUxFIgpbIC1uICIke1NVQl9VUkw6LX0i
IF0gJiYgZWNobyAiICDQn9C+0LTQv9C40YHQutCwIFRlc3Q6ICRTVUJfVVJMIgpbIC1uICIke1NI
T1JUOi19IiBdICAgJiYgZWNobyAiICDQodGC0YDQsNC90LjRhtCwOiAgICAgIGh0dHBzOi8vJHtE
T01BSU59L2MvJHtTSE9SVH0vIgppZiBbICIkVVNFX1RBSUxTQ0FMRSIgPSB5ZXMgXTsgdGhlbgog
IGVjaG87IGVjaG8gIiQoYyAnMTszNicgJ9CU0L7RgdGC0YPQvyDQuiDQv9Cw0L3QtdC70Lgg0YfQ
tdGA0LXQtyBUYWlsc2NhbGU6JykiCiAgZWNobyAiICAxLiDQn9C+0YHRgtCw0LLRjCBUYWlsc2Nh
bGUg0L3QsCDRg9GB0YLRgNC+0LnRgdGC0LLQviAoaVBob25lOiBBcHAgU3RvcmU7INCf0Jo6IHRh
aWxzY2FsZS5jb20vZG93bmxvYWQg4oaSIHRhaWxzY2FsZSB1cCkuIgogIGVjaG8gIiAgMi4g0KHQ
tdGA0LLQtdGAINC4INGD0YHRgtGA0L7QudGB0YLQstC+IOKAlCDQsiDQvtC00L3QvtC8INGC0LDQ
udC90LXRgtC1LiIKICBlY2hvICIgIDMuINCe0YLQutGA0L7QuSDQv9Cw0L3QtdC70Ywg0L/QviDR
gtCw0LnQvdC10YIt0LDQtNGA0LXRgdGDINGD0LfQu9CwICjQv9C10YfQsNGC0LDQtdGCIHN0ZWFs
dGguc2gpLCDQvdCw0L/RgC4gaHR0cHM6Ly88bm9kZT4uPHRhaWxuZXQ+LnRzLm5ldCIKZmkK
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
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHNldHVwLXJlbGF5LXNzaC5zaCDigJQgU1NILdC60LvRjtGHICsg0YPQtNCw0LvRkdC90L3Ri9C5INC00LXQv9C70L7QuSBAQFJFTEFZX05BTUVAQAojINCX0LDQv9GD0YHQutCw0LXRgtGB0Y8g0J3QkCBNT09OTElHSFQuINCT0LXQvdC10YDQuNGA0YPQtdGCINC60LvRjtGHLCDQutC+0L/QuNGA0YPQtdGCINC90LAgU3Vuc2hpbmUsINC00LXQv9C70L7QuNGCINC/0L4gU1NILgpzZXQgLWV1byBwaXBlZmFpbApTTFVHPSJAQFNMVUdAQCIKUkVMQVlfTkFNRT0iQEBSRUxBWV9OQU1FQEAiClJFTEFZX0lQPSJAQFJFTEFZX0lQQEAiClJFTEFZX0RPTUFJTj0iQEBSRUxBWV9ET01BSU5AQCIKQUNNRV9FTUFJTD0iQEBBQ01FX0VNQUlMQEAiClNTSF9QT1JUPSIke1NTSF9QT1JUOi0yMn0iClNTSF9LRVk9Ii9yb290Ly5zc2gvaWRfZWQyNTUxOV9yZWxheSIKQk9PVFNUUkFQPSIvb3B0LyRTTFVHL3JlbGF5LWJvb3RzdHJhcC5lbnYiClJFTU9URV9ESVI9Ii9vcHQvJFNMVUctcmVsYXktZGVwbG95IgpTQ1JJUFRfU1JDPSIke0JBU0hfU09VUkNFWzBdJS8qfS9teWNsb3VkLWRlcGxveS5zaCIKIyDQtdGB0LvQuCDQt9Cw0L/Rg9GB0LrQsNC10Lwg0LjQtyAuZGVwbG95IOKAlCDQuNGJ0LXQvCDQvtGA0LjQs9C40L3QsNC7INGA0Y/QtNC+0Lwg0LjQu9C4INCyIC9yb290ClsgLWYgIiRTQ1JJUFRfU1JDIiBdIHx8IFNDUklQVF9TUkM9Ii9yb290L215Y2xvdWQtZGVwbG95LnNoIgpbIC1mICIkU0NSSVBUX1NSQyIgXSB8fCBTQ1JJUFRfU1JDPSIkKGZpbmQgL29wdC8kU0xVRy8uZGVwbG95IC1uYW1lICdteWNsb3VkLWRlcGxveS5zaCcgMj4vZGV2L251bGwgfCBoZWFkIC0xKSIKCm9rKCl7ICBlY2hvICIgIOKckyAkKiI7IH0Kd2FybigpeyBlY2hvICIgICEgJCoiOyB9CmRpZSgpeyBlY2hvICIgIOKclyAkKiIgPiYyOyBleGl0IDE7IH0KClsgLWYgIiRCT09UU1RSQVAiIF0gfHwgZGllICLQvdC10YIgJEJPT1RTVFJBUCDigJQg0YHQvdCw0YfQsNC70LAg0LfQsNC/0YPRgdGC0LggcHJvdmlzaW9uLXJlbGF5LnNoIgpbIC1mICIkU0NSSVBUX1NSQyIgXSB8fCBkaWUgItC90LUg0L3QsNGI0ZHQuyBteWNsb3VkLWRlcGxveS5zaCAo0LjRgdC60LDQuyDQsiAvcm9vdCDQuCAvb3B0LyRTTFVHLy5kZXBsb3kpIgoKIyDilIDilIAgMS4gU1NILdC60LvRjtGHIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAplY2hvICI9PT4gU1NILdC60LvRjtGHINC00LvRjyAkUkVMQVlfTkFNRSAoJFJFTEFZX0lQKeKApiIKaWYgWyAhIC1mICIkU1NIX0tFWSIgXTsgdGhlbgogIHNzaC1rZXlnZW4gLXQgZWQyNTUxOSAtZiAiJFNTSF9LRVkiIC1OICIiIC1DICJteWNsb3VkLXJlbGF5LSQoZGF0ZSArJVklbSVkKSIgPi9kZXYvbnVsbAogIG9rICLQutC70Y7RhyDRgdCz0LXQvdC10YDQuNGA0L7QstCw0L06ICRTU0hfS0VZIgplbHNlCiAgb2sgItC60LvRjtGHINGD0LbQtSDQtdGB0YLRjDogJFNTSF9LRVkiCmZpCgpTU0hfT1BUUz0oLW8gU3RyaWN0SG9zdEtleUNoZWNraW5nPW5vIC1vIENvbm5lY3RUaW1lb3V0PTEwIC1wICIkU1NIX1BPUlQiIC1pICIkU1NIX0tFWSIKICAgICAgICAgIC1vIENvbnRyb2xNYXN0ZXI9YXV0byAtbyBDb250cm9sUGF0aD0iL3RtcC9zc2hfcmVsYXlfJWhfJXBfJXIiIC1vIENvbnRyb2xQZXJzaXN0PTMwMCkKIyDQsdC10LcgQ29udHJvbE1hc3RlciDigJQg0LTQu9GPINC/0YDQvtCy0LXRgNC60Lgg0Lgg0LrQvtC/0LjRgNC+0LLQsNC90LjRjyDQutC70Y7Rh9CwClNTSF9QTEFJTj0oLW8gU3RyaWN0SG9zdEtleUNoZWNraW5nPW5vIC1vIENvbm5lY3RUaW1lb3V0PTEwIC1wICIkU1NIX1BPUlQiIC1pICIkU1NIX0tFWSIKICAgICAgICAgICAtbyBDb250cm9sTWFzdGVyPW5vIC1vIFBhc3N3b3JkQXV0aGVudGljYXRpb249bm8gLW8gQmF0Y2hNb2RlPXllcykKCiMg4pSA4pSAIDIuINCa0L7Qv9C40YDRg9C10Lwg0LrQu9GO0Ycg0L3QsCBTdW5zaGluZSAo0L7QtNC40L0g0YDQsNC3INC/0L7Qv9GA0L7RgdC40YIg0L/QsNGA0L7Qu9GMKSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZWNobyAiPT0+INCa0L7Qv9C40YDRg9GOIFNTSC3QutC70Y7RhyDQvdCwICRSRUxBWV9OQU1FICgkUkVMQVlfSVAp4oCmIgppZiBzc2ggIiR7U1NIX1BMQUlOW0BdfSIgInJvb3RAJFJFTEFZX0lQIiAnZXhpdCAwJyAyPi9kZXYvbnVsbDsgdGhlbgogIG9rICJTU0gg0LHQtdC3INC/0LDRgNC+0LvRjyDRg9C20LUg0YDQsNCx0L7RgtCw0LXRgiIKZWxzZQogIFBVQj0iJChjYXQgIiR7U1NIX0tFWX0ucHViIikiCiAgZWNobyAiICAgINCS0LLQtdC00Lgg0L/QsNGA0L7Qu9GMIHJvb3RAJFJFTEFZX0lQICjRgtC+0LvRjNC60L4g0Y3RgtC+0YIg0YDQsNC3KToiCiAgc3NoIC1vIFN0cmljdEhvc3RLZXlDaGVja2luZz1ubyAtbyBDb25uZWN0VGltZW91dD0xMCAtcCAiJFNTSF9QT1JUIiAicm9vdEAkUkVMQVlfSVAiIFwKICAgICJta2RpciAtcCB+Ly5zc2ggJiYgY2htb2QgNzAwIH4vLnNzaCAmJiBlY2hvICckUFVCJyA+PiB+Ly5zc2gvYXV0aG9yaXplZF9rZXlzICYmIGNobW9kIDYwMCB+Ly5zc2gvYXV0aG9yaXplZF9rZXlzICYmIGVjaG8gT0siIFwKICAgIHx8IGRpZSAi0L3QtSDRg9C00LDQu9C+0YHRjCDRgdC60L7Qv9C40YDQvtCy0LDRgtGMINC60LvRjtGHIOKAlCDQv9GA0L7QstC10YDRjCDQtNC+0YHRgtGD0L/QvdC+0YHRgtGMICRSRUxBWV9JUDokU1NIX1BPUlQg0Lgg0L/QsNGA0L7Qu9GMIgogIG9rICJTU0gt0LrQu9GO0Ycg0YHQutC+0L/QuNGA0L7QstCw0L0iCmZpCiMg0L7RgtC60YDRi9Cy0LDQtdC8IENvbnRyb2xNYXN0ZXIg4oCUINCy0YHQtSDQv9C+0YHQu9C10LTRg9GO0YnQuNC1IHNzaC90YXIg0LjRgdC/0L7Qu9GM0LfRg9GO0YIg0LXQs9C+INGB0L7QutC10YIg0LHQtdC3INC/0LDRgNC+0LvRjwpzc2ggIiR7U1NIX09QVFNbQF19IiAtZk4gInJvb3RAJFJFTEFZX0lQIiAyPi9kZXYvbnVsbCB8fCB0cnVlCm9rICJTU0gt0YLRg9C90L3QtdC70Ywg0YPRgdGC0LDQvdC+0LLQu9C10L0iCgojIOKUgOKUgCAzLiDQk9C+0YLQvtCy0LjQvCBTdW5zaGluZSDQuiDQtNC10L/Qu9C+0Y4g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmVjaG8gIj09PiDQn9C10YDQtdC00LDRjiDRhNCw0LnQu9GLINC90LAgJFJFTEFZX05BTUXigKYiCnNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290QCRSRUxBWV9JUCIgIm1rZGlyIC1wICRSRU1PVEVfRElSIgojINC/0LXRgNC10LTQsNGR0Lwg0YTQsNC50LvRiyDRh9C10YDQtdC3IHRhciDQv9C+IFNTSCAo0L7QtNC40L0g0LrQsNC90LDQuywg0LHQtdC3INC+0YLQtNC10LvRjNC90L7QuSDQsNGD0YLQtdC90YLQuNGE0LjQutCw0YbQuNC4KQp0YXIgLWNmIC0gLUMgIiQoZGlybmFtZSAiJFNDUklQVF9TUkMiKSIgIiQoYmFzZW5hbWUgIiRTQ1JJUFRfU1JDIikiIFwKICAtQyAiJChkaXJuYW1lICIkQk9PVFNUUkFQIikiICIkKGJhc2VuYW1lICIkQk9PVFNUUkFQIikiIFwKICB8IHNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290QCRSRUxBWV9JUCIgInRhciAteGYgLSAtQyAkUkVNT1RFX0RJUiIKb2sgIm15Y2xvdWQtZGVwbG95LnNoICsgcmVsYXktYm9vdHN0cmFwLmVudiDQv9C10YDQtdC00LDQvdGLIgoKIyDilIDilIAgNC4g0KTQvtGA0LzQuNGA0YPQtdC8IGRlcGxveS5jb25mINC00LvRjyBTdW5zaGluZSDQuCDQv9C10YDQtdC00LDRkdC8IOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApzb3VyY2UgIiRCT09UU1RSQVAiCiMg0K/QstC90L4g0YTQuNC60YHQuNGA0YPQtdC8INC00L7QvNC10L3Rizog0L3QsCBTdW5zaGluZSBNQUlOX0RPTUFJTiA9INC00L7QvNC10L0g0YDQtdC70LXRjyAocnUuYWxkZXJib3cuY29tKQpfU1VOU0hJTkVfRE9NQUlOPSJAQFJFTEFZX0RPTUFJTkBAIgpfTU9PTkxJR0hUX0RPTUFJTj0iQEBNQUlOX0RPTUFJTkBAIgpjYXQgPiAvdG1wL3JlbGF5LWRlcGxveS5jb25mLiQkIDw8RU9GClJPTEU9c3Vuc2hpbmUtbm9kZQpCUkFORD0kUkVMQVlfTkFNRQpTTFVHPSRTTFVHCk1BSU5fRE9NQUlOPSRfU1VOU0hJTkVfRE9NQUlOClJFTEFZX0RPTUFJTj0kX01PT05MSUdIVF9ET01BSU4KRVhJVF9JUD0kRVhJVF9JUApSRUxBWV9JUD0kUkVMQVlfSVAKRVhJVF9OQU1FPSRFWElUX05BTUUKUkVMQVlfTkFNRT0kUkVMQVlfTkFNRQpBQ01FX0VNQUlMPSRBQ01FX0VNQUlMClVTRV9UQUlMU0NBTEU9bm8KU1NIX1BPUlQ9JFNTSF9QT1JUCkhBUkRFTj1ubwpHRU9fQkxPQ0s9bm8KUFE9bm8KVEVTVF9TVUJfVVVJRD1yZWxheQpFT0YKY2F0ICIvdG1wL3JlbGF5LWRlcGxveS5jb25mLiQkIiB8IHNzaCAiJHtTU0hfT1BUU1tAXX0iICJyb290QCRSRUxBWV9JUCIgImNhdCA+ICRSRU1PVEVfRElSL2RlcGxveS5jb25mIgpybSAtZiAiL3RtcC9yZWxheS1kZXBsb3kuY29uZi4kJCIKb2sgImRlcGxveS5jb25mINC00LvRjyAkUkVMQVlfTkFNRSDQv9C10YDQtdC00LDQvSIKCiMg4pSA4pSAIDUuINCX0LDQv9GD0YHQutCw0LXQvCDQtNC10L/Qu9C+0Lkg0L3QsCBTdW5zaGluZSDQv9C+IFNTSCDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKZWNobwplY2hvICI9PT4g0JfQsNC/0YPRgdC60LDRjiDQtNC10L/Qu9C+0LkgJFJFTEFZX05BTUUg0L3QsCAkUkVMQVlfSVDigKYiCmVjaG8gIiAgICAo0LLRi9Cy0L7QtCDQuNC00ZHRgiDQsiDRgNC10LDQu9GM0L3QvtC8INCy0YDQtdC80LXQvdC4KSIKZWNobwpzc2ggIiR7U1NIX09QVFNbQF19IiAicm9vdEAkUkVMQVlfSVAiIFwKICAiTVlDTE9VRF9DT05GPSRSRU1PVEVfRElSL2RlcGxveS5jb25mIFJFTEFZX0JPT1RTVFJBUD0kUkVNT1RFX0RJUi9yZWxheS1ib290c3RyYXAuZW52IFwKICAgYmFzaCAkUkVNT1RFX0RJUi9teWNsb3VkLWRlcGxveS5zaCBzdW5zaGluZS1ub2RlIiBcCiAgfHwgd2FybiAic3Vuc2hpbmUtbm9kZSDQt9Cw0LLQtdGA0YjQuNC70YHRjyDRgSDQvtGI0LjQsdC60L7QuSAo0L7QsdGL0YfQvdC+OiB4cmF5INC90LUg0YPRgdC/0LXQuyDRgdGC0LDRgNGC0L7QstCw0YLRjCDQt9CwIDkw0YEpIOKAlCBraWNrLW5vZGUuc2gg0YEgTW9vbmxpZ2h0INGA0LXRiNC40YIg0Y3RgtC+IgplY2hvCm9rICLQlNC10L/Qu9C+0LkgJFJFTEFZX05BTUUg0LfQsNCy0LXRgNGI0ZHQvSIK
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
RERZJwp7CkBAQUNNRV9TVEFHSU5HX0xJTkVAQAp9CkBATUFJTl9ET01BSU5AQDo4NDQzIHsKICAg
ICMg0KDQtdCw0LvRjNC90LDRjyDQv9C+0LTQv9C40YHQutCwIFJlbW5hd2F2ZSAo0L/QsNC90LXQ
u9GMINC+0YLQtNCw0ZHRgiAvYXBpL3N1Yikg4oCUINC+0YHRgtCw0ZHRgtGB0Y8g0L/Rg9Cx0LvQ
uNGH0L3QvtC5CiAgICBAc3ViIHBhdGggL2FwaS9zdWIgL2FwaS9zdWIvKgogICAgaGFuZGxlIEBz
dWIgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMDAKICAgIH0KCiAgICAjINCh
0YLRgNCw0L3QuNGG0LAg0L/QvtC00L/QuNGB0LrQuCAoc3ViLXBhZ2UpCiAgICBoYW5kbGVfcGF0
aCAvc3ViLyogewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMTAKICAgIH0KCiAg
ICAjIFZMRVNTIFdTIC8gWEhUVFAg0YLRgNCw0L3RgdC/0L7RgNGC0YsKICAgIEB3cyBwYXRoIC93
c25nIC93c25nLyoKICAgIGhhbmRsZSBAd3MgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAu
MC4xOjIwNTMKICAgIH0KICAgIEB4aCBwYXRoIC94aCAveGgvKgogICAgaGFuZGxlIEB4aCB7CiAg
ICAgICAgcmV2ZXJzZV9wcm94eSAxMjcuMC4wLjE6MjA1NCB7CiAgICAgICAgICAgIGZsdXNoX2lu
dGVydmFsIC0xCiAgICAgICAgfQogICAgfQogICAgIyDQktGB0ZEg0L7RgdGC0LDQu9GM0L3QvtC1
ICjQutC+0YDQtdC90YwsIC9hcGkvYXV0aCwgL2Rhc2hib2FyZCAuLi4pIC0+INC00LXQutC+0Lkg
TXlTcGhlcmUKICAgICMg0J/QsNC90LXQu9GMINCd0JUg0L/Rg9Cx0LvQuNGH0L3QsDog0LTQvtGB
0YLRg9C/INGC0L7Qu9GM0LrQviDRh9C10YDQtdC3IFNTSC3RgtGD0L3QvdC10LvRjCDQvdCwIDEy
Ny4wLjAuMTozMDAwCiAgICBoYW5kbGUgewogICAgICAgIHJldmVyc2VfcHJveHkgMTI3LjAuMC4x
OjgwODAKICAgIH0KfQoKIyDQn9Cw0L3QtdC70Ywg0YfQtdGA0LXQtyBUYWlsc2NhbGU6IGB0YWls
c2NhbGUgc2VydmUgLS1iZyBodHRwOi8vMTI3LjAuMC4xOjgwODJgINGD0LrQsNC30YvQstCw0LXR
giDRgdGO0LTQsC4KIyDQlNC+0LLQtdGA0LXQvdC90YvQuSDRgdC10YDRgiDQtNCw0ZHRgiBUYWls
c2NhbGU7INC70LjRgdGC0LXQvdC10YAg0LvQvtC60LDQu9GM0L3Ri9C5LCDQvdCw0YDRg9C20YMg
0L3QtSDRgtC+0YDRh9C40YIuCjo4MDgyIHsKICAgIGJpbmQgMTI3LjAuMC4xCiAgICByZXZlcnNl
X3Byb3h5IDEyNy4wLjAuMTozMDAwIHsKICAgICAgICBoZWFkZXJfdXAgSG9zdCBAQE1BSU5fRE9N
QUlOQEAKICAgICAgICBoZWFkZXJfdXAgWC1Gb3J3YXJkZWQtSG9zdCBAQE1BSU5fRE9NQUlOQEAK
ICAgICAgICBoZWFkZXJfdXAgWC1Gb3J3YXJkZWQtUHJvdG8gaHR0cHMKICAgIH0KfQoKIyDQlNC1
0YHQutGC0L7Qvy3RhNC+0LvQsdGN0Lo6IHNzaCAtTCA4MDgxOjEyNy4wLjAuMTo4MDgxLCDQvtGC
0LrRgNGL0YLRjCBodHRwczovL2xvY2FsaG9zdDo4MDgxIChzZWxmLXNpZ25lZCwg0LHQtdC30L7Q
v9Cw0YHQvdC+KS4KaHR0cHM6Ly9sb2NhbGhvc3Q6ODA4MSB7CiAgICB0bHMgaW50ZXJuYWwKICAg
IHJldmVyc2VfcHJveHkgMTI3LjAuMC4xOjMwMDAgewogICAgICAgIGhlYWRlcl91cCBIb3N0IEBA
TUFJTl9ET01BSU5AQAogICAgICAgIGhlYWRlcl91cCBYLUZvcndhcmRlZC1Ib3N0IEBATUFJTl9E
T01BSU5AQAogICAgICAgIGhlYWRlcl91cCBYLUZvcndhcmRlZC1Qcm90byBodHRwcwogICAgfQp9
CkNBRERZCgogIGxvZyAiWzMvNF0g0JLQsNC70LjQtNCw0YbQuNGPICsg0L/QtdGA0LXQt9Cw0LPR
gNGD0LfQutCwIENhZGR5IgogIGlmIGRvY2tlciBleGVjICIkQ0FERFlfQ1RSIiBjYWRkeSB2YWxp
ZGF0ZSAtLWNvbmZpZyAvZXRjL2NhZGR5L0NhZGR5ZmlsZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4K
ICAgIGVjaG8gInZhbGlkYXRlOiBPSyIKICAgIGRvY2tlciBleGVjICIkQ0FERFlfQ1RSIiBjYWRk
eSByZWxvYWQgLS1jb25maWcgL2V0Yy9jYWRkeS9DYWRkeWZpbGUgJiYgZWNobyAicmVsb2FkOiBP
SyIgXAogICAgICB8fCB7IGVjaG8gInJlbG9hZCDQvdC1INC/0YDQvtGI0ZHQuywg0L/QtdGA0LXQ
t9Cw0L/Rg9GB0LrQsNGOINC60L7QvdGC0LXQudC90LXRgCI7IGRvY2tlciByZXN0YXJ0ICIkQ0FE
RFlfQ1RSIjsgfQogIGVsc2UKICAgIGVjaG8gInZhbGlkYXRlINC90LXQtNC+0YHRgtGD0L/QtdC9
ICjQtNGA0YPQs9C+0Lkg0L/Rg9GC0Ywg0LrQvtC90YTQuNCz0LA/KSDigJQg0L/QtdGA0LXQt9Cw
0L/Rg9GB0LrQsNGOINC60L7QvdGC0LXQudC90LXRgCIKICAgIGRvY2tlciByZXN0YXJ0ICIkQ0FE
RFlfQ1RSIgogIGZpCgogIGxvZyAiWzQvNF0g0J/RgNC+0LLQtdGA0LrQsCDRh9C10YDQtdC3INGB
0LDQvCBDYWRkeSAoODQ0Mywg0LIg0L7QsdGF0L7QtCBSZWFsaXR5KSIKICBzbGVlcCAyCiAgZWNo
byAiLS0tINC00LXQutC+0Lkg0LIg0LrQvtGA0L3QtSAo0L7QttC40LTQsNC10LwgTXlTcGhlcmUg
SlNPTikgLS0tIgogIGN1cmwgLXNrIC0tcmVzb2x2ZSAiJERPTUFJTjo4NDQzOjEyNy4wLjAuMSIg
Imh0dHBzOi8vJERPTUFJTjo4NDQzL2FwaS9zdGF0dXMiOyBlY2hvCiAgZWNobyAiLS0tINC/0L7Q
tNC/0LjRgdC60LAgKNC+0LbQuNC00LDQtdC8IFhyYXktSlNPTiwg0L3QtSDQtNC10LrQvtC5KSAt
LS0iCiAgY3VybCAtc2sgLS1yZXNvbHZlICIkRE9NQUlOOjg0NDM6MTI3LjAuMC4xIiAtQSBIYXBw
ICJodHRwczovLyRET01BSU46ODQ0My9hcGkvc3ViLyRTVUJfVVVJRCIgfCBoZWFkIC1jIDE2MDsg
ZWNobwogIGVjaG8KICBlY2hvICLinIUg0JrQvtGA0LXQvdGMIC0+IE15U3BoZXJlLCAvYXBpL3N1
YiAtPiDQv9C+0LTQv9C40YHQutCwLiDQntGC0LrQsNGCINC/0YDQuCDQv9GA0L7QsdC70LXQvNCw
0YU6IgogIGVjaG8gIiAgIGNwIFwiJGJha1wiIFwiJENBRERZRklMRVwiICYmIGRvY2tlciBleGVj
ICRDQUREWV9DVFIgY2FkZHkgcmVsb2FkIC0tY29uZmlnIC9ldGMvY2FkZHkvQ2FkZHlmaWxlIgog
IGVjaG8KICBlY2hvICLQn9Cw0L3QtdC70Ywg0L3QtSDQv9GD0LHQu9C40YfQvdCwLiDQlNC+0YHR
gtGD0L86IgogIGVjaG8gIiAgIC0gVGFpbHNjYWxlICjQvtGB0L3QvtCy0L3QvtC5KTogaHR0cHM6
Ly9tb29ubGlnaHQuPNGC0LLQvtC5LXRhaWxuZXQ+LnRzLm5ldCIKICBlY2hvICIgICAgICAgKNC+
0LTQuNC9INGA0LDQtzogdGFpbHNjYWxlIHNlcnZlIC0tYmcgaHR0cDovLzEyNy4wLjAuMTo4MDgy
KSIKICBlY2hvICIgICAtINCU0LXRgdC60YLQvtC/LdGE0L7Qu9Cx0Y3Qujogc3NoIC1MIDgwODE6
MTI3LjAuMC4xOjgwODEgcm9vdEBAQEVYSVRfSVBAQCAtPiBodHRwczovL2xvY2FsaG9zdDo4MDgx
Igp9CgpjYXNlICIkezE6LX0iIGluCiAgZGVjb3kpIHN0YWdlX2RlY295IDs7CiAgY2FkZHkpIHN0
YWdlX2NhZGR5IDs7CiAgKikgZWNobyAi0JjRgdC/0L7Qu9GM0LfQvtCy0LDQvdC40LU6IGJhc2gg
c3RlYWx0aC5zaCB7ZGVjb3l8Y2FkZHl9IjsgZXhpdCAxIDs7CmVzYWMK
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
IyEvdXNyL2Jpbi9lbnYgYmFzaAojIHdkdHQtYnVpbGQuc2gg4oCUINGD0YHRgtCw0L3QvtCy0LrQ
sCBXRFRULdGB0LXRgNCy0LXRgNCwINC90LAgQEBFWElUX05BTUVAQCAo0YTQvtGA0LogaWxkYXJt
YWdhL3dkdHQpCiMKIyAg0J/RgNC10LbQvdGP0Y8g0YHQsdC+0YDQutCwINC40LcgYW11cmNhbm92
L3Byb3h5LXR1cm4tdmstYW5kcm9pZCDRgdCy0ZHRgNC90YPRgtCwINCw0LLRgtC+0YDQvtC8ICjR
gNC10L/QvtC30LjRgtC+0YDQuNC5CiMgINCw0YDRhdC40LLQuNGA0L7QstCw0L0sINC/0YDQtdC1
0LzQvdC40Log4oCUIENTUVRUKS4g0KTQvtGA0LogaWxkYXJtYWdhL3dkdHQg4oCUINGC0L7RgiDQ
ttC1INC/0YDQvtGC0L7QutC+0Lsg0Lgg0YLQtSDQttC1CiMgINC60LvQuNC10L3RgtGLIChpT1M6
IHZrLXR1cm4tcHJveHktaW9zLCDRgNC10LbQuNC8IFNSVFAtV1JBUC1BKSwg0L/Qu9GO0YE6INCy
0LXQsS3Qv9Cw0L3QtdC70Ywg0YEKIyAg0L/QvtC70YzQt9C+0LLQsNGC0LXQu9GP0LzQuC/Qu9C4
0LzQuNGC0LDQvNC4LCDQv9C+0LTQtNC10YDQttC60LAgQ1NRVFQt0LrQu9C40LXQvdGC0L7QsiAo
VURQIDQ2MDAwKSwgUkVTVCBBUEkuCiMKIyAg0KfRgtC+INC00LXQu9Cw0LXRgiDRhNCw0LfQsCAo
0LjQtNC10LzQv9C+0YLQtdC90YLQvdC+IOKAlCDQv9C+0LLRgtC+0YDQvdGL0Lkg0LfQsNC/0YPR
gdC6ID0g0L7QsdC90L7QstC70LXQvdC40LUpOgojICAgIOKAoiDQv9Cw0YDQvtC70YwgV0RUVDog
0LjQtyDQstC40LfQsNGA0LTQsCAoV0RUVF9QQVNTKSDihpIg0LjQtyBjcmVkZW50aWFscy50eHQg
4oaSINGB0LvRg9GH0LDQudC90YvQuQojICAgIOKAoiDRgdC90LDQv9GI0L7RgiBpcHRhYmxlcyDQ
uCAvZXRjL3dkdHQg0L/QtdGA0LXQtCDQu9GO0LHRi9C80Lgg0LjQt9C80LXQvdC10L3QuNGP0LzQ
uAojICAgIOKAoiDRgdGC0LDRgNGL0Lkg0L7QtNC40L3QvtGH0L3Ri9C5IHdkdHQtc2VydmVyIChh
bXVyY2Fub3YpINC+0YLRgdGC0LDQstC70Y/QtdGC0YHRjyDQsiDRgdGC0L7RgNC+0L3Rgywg0Y7Q
vdC40YIKIyAgICAgIHdkdHQuc2VydmljZSDQv9C10YDQtdC/0LjRgdGL0LLQsNC10YIg0YPRgdGC
0LDQvdC+0LLRidC40LogKC0tZm9yY2Ug0YLQvtC70YzQutC+INC/0YDQuCDQvNC40LPRgNCw0YbQ
uNC4KQojICAgIOKAoiDRg9GB0YLQsNC90L7QstGJ0LjQuiDRhNC+0YDQutCwINC30LDQv9GD0YHQ
utCw0LXRgtGB0Y8g0J3QldCY0J3QotCV0KDQkNCa0KLQmNCS0J3Qniwg0LHQtdC3INC10LPQviDR
gdC+0LHRgdGC0LLQtdC90L3QvtCz0L4gWHJheQojICAgICAgKFdEVFRfRElSRUNUPTEg4oCUINC8
0LDRgNGI0YDRg9GC0LjQt9Cw0YbQuNGPINGDINC90LDRgSDRgdCy0L7Rjywg0YfQtdGA0LXQtyBS
ZW1uYXdhdmUpCiMgICAg4oCiINC/0L7RgNGC0Ysg0LrQsNC6INC/0YDQtdC20LTQtTogRFRMUyA1
NjAwMC91ZHAsIFdHIDU2MDAxL3VkcDsg0L3QvtCy0YvQuSBDU1FUVCA0NjAwMC91ZHAKIyAgICDi
gKIg0L/QsNC90LXQu9GMICh0Y3AgMjg2MCkg0Lgg0LXRkSBzdWJzY3JpcHRpb24t0YHQtdGA0LLQ
uNGBICh0Y3AgMjA5Nikg0J3QlSDQv9GD0LHQu9C40LrRg9GO0YLRgdGPOgojICAgICAg0LTQvtGB
0YLRg9C/INGC0L7Qu9GM0LrQviDRh9C10YDQtdC3IFNTSC3RgtGD0L3QvdC10LvRjCDQuNC70Lgg
VGFpbHNjYWxlIOKAlCDQutCw0Log0YMg0L/QsNC90LXQu9C4IFJlbW5hd2F2ZQpzZXQgLWV1byBw
aXBlZmFpbApCPS9vcHQvQEBTTFVHQEAKVz0iJEIvd2R0dCIKQ1JFRF9GSUxFPSIkQi9jcmVkZW50
aWFscy50eHQiCklOU1RBTExFUl9VUkw9Imh0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNv
bS9pbGRhcm1hZ2Evd2R0dC1pbnN0YWxsL21haW4vaW5zdGFsbC5zaCIKRFRMU19QT1JUPTU2MDAw
OyBXR19QT1JUPTU2MDAxOyBDU1FUVF9QT1JUPTQ2MDAwClBBTkVMX1BPUlQ9Mjg2MDsgU1VCX1BP
UlQ9MjA5Ngp0cz0kKGRhdGUgKyVZJW0lZC0lSCVNJVMpCm1rZGlyIC1wICIkVyIKCmVjaG8gIj09
WzEvNl0g0JfQsNCy0LjRgdC40LzQvtGB0YLQuCA9PSIKZXhwb3J0IERFQklBTl9GUk9OVEVORD1u
b25pbnRlcmFjdGl2ZQphcHQtZ2V0IHVwZGF0ZSAteSAtcXEgPi9kZXYvbnVsbCAyPiYxIHx8IHRy
dWUKYXB0LWdldCBpbnN0YWxsIC15IC1xcSBjdXJsIHNxbGl0ZTMgaXB0YWJsZXMgY2EtY2VydGlm
aWNhdGVzID4vZGV2L251bGwgMj4mMQplY2hvICIgICBPSyIKCmVjaG8gIj09WzIvNl0g0J/QsNGA
0L7Qu9GMIFdEVFQgPT0iClsgLWYgIiRDUkVEX0ZJTEUiIF0gfHwgeyB0b3VjaCAiJENSRURfRklM
RSI7IGNobW9kIDYwMCAiJENSRURfRklMRSI7IH0KIyDQv9GA0LjQvtGA0LjRgtC10YI6IFdEVFRf
UEFTUyDQuNC3INCy0LjQt9Cw0YDQtNCwIChlbnYvY29uZikg4oaSINGD0LbQtSDRgdC+0YXRgNCw
0L3RkdC90L3Ri9C5INCyIGNyZWRzIOKGkiDRgdC70YPRh9Cw0LnQvdGL0LkKX1dEVFRfRlJPTV9D
T05GPSIke1dEVFRfUEFTUzotfSIKV0RUVF9QQVNTPSIkKGdyZXAgJ153ZHR0LXBhc3N3b3JkOicg
IiRDUkVEX0ZJTEUiIDI+L2Rldi9udWxsIHwgYXdrICd7cHJpbnQgJDJ9JyB8IGhlYWQgLTEgfHwg
dHJ1ZSkiCmlmIFsgLW4gIiRfV0RUVF9GUk9NX0NPTkYiIF07IHRoZW4KICBXRFRUX1BBU1M9IiRf
V0RUVF9GUk9NX0NPTkYiCiAgaWYgZ3JlcCAtcSAnXndkdHQtcGFzc3dvcmQ6JyAiJENSRURfRklM
RSIgMj4vZGV2L251bGw7IHRoZW4KICAgIHNlZCAtaSAic3xed2R0dC1wYXNzd29yZDouKnx3ZHR0
LXBhc3N3b3JkOiAkV0RUVF9QQVNTfCIgIiRDUkVEX0ZJTEUiCiAgZWxzZQogICAgcHJpbnRmICd3
ZHR0LXBhc3N3b3JkOiAlc1xuJyAiJFdEVFRfUEFTUyIgPj4gIiRDUkVEX0ZJTEUiCiAgZmkKICBl
Y2hvICIgICDQv9Cw0YDQvtC70Ywg0LjQtyDQstC40LfQsNGA0LTQsCwg0YHQvtGF0YDQsNC90ZHQ
vSDQsiAkQ1JFRF9GSUxFIgplbGlmIFsgLXogIiRXRFRUX1BBU1MiIF07IHRoZW4KICBXRFRUX1BB
U1M9IiQob3BlbnNzbCByYW5kIC1oZXggMTIgMj4vZGV2L251bGwpIgogIHByaW50ZiAnd2R0dC1w
YXNzd29yZDogJXNcbicgIiRXRFRUX1BBU1MiID4+ICIkQ1JFRF9GSUxFIgogIGVjaG8gIiAgINC/
0LDRgNC+0LvRjCDRgdCz0LXQvdC10YDQuNGA0L7QstCw0L0g0Lgg0YHQvtGF0YDQsNC90ZHQvSDQ
siAkQ1JFRF9GSUxFIgplbHNlCiAgZWNobyAiICAg0L/QsNGA0L7Qu9GMINGD0LbQtSDQtdGB0YLR
jCDQsiAkQ1JFRF9GSUxFIgpmaQoKZWNobyAiPT1bMy82XSDQodC90LDQv9GI0L7RgtGLINC4INGC
0L7Rh9C60LAg0L7RgtC60LDRgtCwID09IgojINCa0JvQrtCn0JXQktCe0JU6INGB0YLQsNGA0YvQ
uSDRgdC10YDQstC40YEg0J3QlSDRgtGA0L7Qs9Cw0LXQvCDigJQg0L7QvSDQtNC10YDQttC40YIg
NTYwMDAvNTYwMDEg0Lgg0L7QsdGB0LvRg9C20LjQstCw0LXRggojINC20LjQstGL0YUg0L/QvtC7
0YzQt9C+0LLQsNGC0LXQu9C10Lkg0LLRgdGRINCy0YDQtdC80Y8sINC/0L7QutCwINGD0YHRgtCw
0L3QvtCy0YnQuNC6INGB0L7QsdC40YDQsNC10YIg0YTQvtGA0Log0LjQtyDQuNGB0YXQvtC00L3Q
uNC60L7Qsi4KIyDQo9GB0YLQsNC90L7QstGJ0LjQuiDQt9Cw0LHQtdGA0ZHRgiDQv9C+0YDRgtGL
INGC0L7Qu9GM0LrQviDQsiDRgdCw0LzQvtC8INC60L7QvdGG0LUgKGluc3RhbGxfd2R0dF9zZXJ2
aWNlKSwg0Y3RgtC+CiMg0YHQtdC60YPQvdC00L3Ri9C5IGhhbmRvZmYuINCV0YHQu9C4INGB0LHQ
vtGA0LrQsCDRg9C/0LDQtNGR0YIg0YDQsNC90YzRiNC1IOKAlCDRgdGC0LDRgNGL0Lkg0YHQtdGA
0LLQuNGBINGC0LDQuiDQuCDRgNCw0LHQvtGC0LDQuy4KaXB0YWJsZXMtc2F2ZSA+ICIvcm9vdC9p
cHRhYmxlcy1iZWZvcmUtd2R0dC0kdHMuYmFrIiAyPi9kZXYvbnVsbCAmJiBlY2hvICIgICBpcHRh
YmxlcyAtPiAvcm9vdC9pcHRhYmxlcy1iZWZvcmUtd2R0dC0kdHMuYmFrIiB8fCB0cnVlClsgLWQg
L2V0Yy93ZHR0IF0gJiYgdGFyIC1jemYgIiRXL2V0Yy13ZHR0LSR0cy50Z3oiIC1DIC8gZXRjL3dk
dHQgMj4vZGV2L251bGwgJiYgZWNobyAiICAgL2V0Yy93ZHR0IC0+ICRXL2V0Yy13ZHR0LSR0cy50
Z3oiCk9MRF9VTklUPSIiOyBPTERfQklOPSIiCmlmIFsgLWYgL2V0Yy9zeXN0ZW1kL3N5c3RlbS93
ZHR0LnNlcnZpY2UgXTsgdGhlbgogIGNwIC1mIC9ldGMvc3lzdGVtZC9zeXN0ZW0vd2R0dC5zZXJ2
aWNlICIkVy93ZHR0LnNlcnZpY2Uub2xkLSR0cyI7IE9MRF9VTklUPSIkVy93ZHR0LnNlcnZpY2Uu
b2xkLSR0cyIKICBlY2hvICIgICDRjtC90LjRgiAtPiAkT0xEX1VOSVQiCmZpCmlmIFsgLXggL3Vz
ci9sb2NhbC9iaW4vd2R0dC1zZXJ2ZXIgXSAmJiBbICEgLXggL3Vzci9sb2NhbC9iaW4vd2R0dC1h
cHAgXTsgdGhlbgogIGNwIC1mIC91c3IvbG9jYWwvYmluL3dkdHQtc2VydmVyICIkVy93ZHR0LXNl
cnZlci5vbGQtJHRzIjsgT0xEX0JJTj0iJFcvd2R0dC1zZXJ2ZXIub2xkLSR0cyIKICBlY2hvICIg
ICDQvNC40LPRgNCw0YbQuNGPINGBIGFtdXJjYW5vdjsg0LHQuNC90LDRgNGMIC0+ICRPTERfQklO
ICjRgdGC0LDRgNGL0Lkg0YHQtdGA0LLQuNGBINC/0L7QutCwINCd0JUg0L7RgdGC0LDQvdCw0LLQ
u9C40LLQsNC10LwpIgogICMg0L/Rg9GB0YLQvtC5IHBhbmVsLmRiINC+0YIg0L/RgNC+0YjQu9C+
0Lkg0YPQv9Cw0LLRiNC10Lkg0L/QvtC/0YvRgtC60Lgg0LzQtdGI0LDQtdGCINGE0L7RgNC60YMg
0YHQvtC30LTQsNGC0Ywg0YfQuNGB0YLRg9GOINCR0JQg4oCUINGD0LHQuNGA0LDQtdC8CiAgIyAo
0YHQvdCw0L/RiNC+0YIgL2V0Yy93ZHR0INGD0LbQtSDRgdC00LXQu9Cw0L0g0LLRi9GI0LU7INGC
0YDQvtCz0LDQtdC8INGC0L7Qu9GM0LrQviDQtdGB0LvQuCDRhNCw0LnQuyDRgNC10LDQu9GM0L3Q
viDQv9GD0YHRgtC+0LkpCiAgWyAtZiAvZXRjL3dkdHQvcGFuZWwuZGIgXSAmJiBbICEgLXMgL2V0
Yy93ZHR0L3BhbmVsLmRiIF0gJiYgeyBybSAtZiAvZXRjL3dkdHQvcGFuZWwuZGI7IGVjaG8gIiAg
INGD0LTQsNC70LjQuyDQv9GD0YHRgtC+0LkgcGFuZWwuZGIg0L7RgiDQv9GA0L7RiNC70L7QuSDQ
v9C+0L/Ri9GC0LrQuCI7IH0KZmkKCnJvbGxiYWNrX29sZCgpewogIGVjaG8gIiAgICEhINC+0YLQ
utCw0YI6INCy0L7Qt9Cy0YDQsNGJ0LDRjiDQv9GA0LXQttC90LjQuSBXRFRUIgogIFsgLW4gIiRP
TERfQklOIiBdICAmJiB7IGNwIC1mICIkT0xEX0JJTiIgIC91c3IvbG9jYWwvYmluL3dkdHQtc2Vy
dmVyICYmIGNobW9kICt4IC91c3IvbG9jYWwvYmluL3dkdHQtc2VydmVyOyB9CiAgWyAtbiAiJE9M
RF9VTklUIiBdICYmIGNwIC1mICIkT0xEX1VOSVQiIC9ldGMvc3lzdGVtZC9zeXN0ZW0vd2R0dC5z
ZXJ2aWNlCiAgc3lzdGVtY3RsIGRhZW1vbi1yZWxvYWQgMj4vZGV2L251bGwgfHwgdHJ1ZQogIHN5
c3RlbWN0bCBzdGFydCB3ZHR0IDI+L2Rldi9udWxsIHx8IHRydWUKICBzbGVlcCAyCiAgaWYgc3lz
dGVtY3RsIGlzLWFjdGl2ZSAtLXF1aWV0IHdkdHQgMj4vZGV2L251bGw7IHRoZW4gZWNobyAiICAg
0L/RgNC10LbQvdC40LkgV0RUVCDRgdC90L7QstCwIGFjdGl2ZSDigJQg0L/QvtC70YzQt9C+0LLQ
sNGC0LXQu9C4INC90LAg0YHQstGP0LfQuCIKICBlbHNlIGVjaG8gIiAgICEhISDQv9GA0LXQttC9
0LjQuSBXRFRUINC90LUg0L/QvtC00L3Rj9C70YHRjyDigJQgam91cm5hbGN0bCAtdSB3ZHR0IC1u
IDMwIjsgZmkKfQoKZWNobyAiPT1bNC82XSDQo9GB0YLQsNC90L7QstC60LAgaWxkYXJtYWdhL3dk
dHQgKHBpcGVkLCDQuNC3INC40YHRhdC+0LTQvdC40LrQvtCyKSA9PSIKIyDQl9Cw0L/Rg9GB0Log
0JjQnNCV0J3QndCeINGH0LXRgNC10LcgcHJvY2VzcyBzdWJzdGl0dXRpb246INGC0L7Qu9GM0LrQ
viDRgtCw0Log0YMg0YPRgdGC0LDQvdC+0LLRidC40LrQsAojIEJBU0hfU09VUkNFPS9kZXYvZmQv
KiDihpIgaXNfcGlwZWRfaW5zdGFsbD10cnVlIOKGkiDQvtC9INGB0LDQvCDQutC70L7QvdC40YDR
g9C10YIg0YHQstC+0LgKIyB0ZW1wbGF0ZXMuINCX0LDQv9GD0YHQuiDQuNC3INGE0LDQudC70LAg
KGJhc2ggaW5zdGFsbC5zaCkg0LLQsNC70LjRgtGB0Y8g0L3QsCDCq9Co0LDQsdC70L7QvdGLINC9
0LUg0L3QsNC50LTQtdC90YvCuy4KIyBpbnN0YWxsIC0tZGlyZWN0OiDQsdC10Lcg0LXQs9C+INGB
0L7QsdGB0YLQstC10L3QvdC+0LPQviBYcmF5ICjQvNCw0YDRiNGA0YPRgtC40LfQsNGG0LjRjyDR
gyDQvdCw0YEg4oCUIFJlbW5hd2F2ZSwKIyBXRFRUINC/0YDQvtGB0YLQviBOQVQtTUFTUVVFUkFE
RSwg0LrQsNC6INCx0YvQu9C+KS4g0J/QvtGA0YLRiyDigJQg0YfQtdGA0LXQtyBlbnYsINC/0LDR
gNC+0LvRjCDigJQg0YfQtdGA0LXQtyAtcC4KIyAtLWZvcmNlINCe0JHQr9CX0JDQotCV0JvQldCd
OiDQsdC10Lcg0L3QtdCz0L4g0YPRgdGC0LDQvdC+0LLRidC40LosINGD0LLQuNC00LXQsiDRgdGC
0LDRgNGL0Lkgd2R0dC5zZXJ2aWNlK9Cx0LjQvdCw0YDRjCwKIyDRg9GF0L7QtNC40YIg0LIg0YDQ
tdC20LjQvCB1cGRhdGUg0Lgg0LLRi9GH0LjRgtGL0LLQsNC10YIg0L/QsNGA0L7Qu9GMINC40Lcg
0Y7QvdC40YLQsCDRgNC10LPRg9C70Y/RgNC60L7QuSAtcGFzc3dvcmQgJy4uLicKIyAo0YEg0LrQ
sNCy0YvRh9C60LDQvNC4KS4g0KHRgtCw0YDRi9C5IGFtdXJjYW5vdi3RjtC90LjRgiDQv9C40YjQ
tdGCIC1wYXNzd29yZCDQkdCV0Jcg0LrQsNCy0YvRh9C10Log4oaSINC/0LDRgNC+0LvRjCDQvdC1
CiMg0YDQsNGB0L/QvtC30L3QsNGR0YLRgdGPIOKGkiDQs9C10L3QtdGA0LjRgtGB0Y8g0YHQu9GD
0YfQsNC50L3Ri9C5IOKGkiDQstGB0LUg0LrQu9C40LXQvdGC0Ysg0L7RgtCy0LDQu9C40LLQsNGO
0YLRgdGPLiDQoSAtLWZvcmNlINC40LTRkdGCCiMg0L/Rg9GC0Ywg0YHQstC10LbQtdC5INGD0YHR
gtCw0L3QvtCy0LrQuCwg0LPQtNC1INC30LDQtNCw0L3QvdGL0LkgLXAg0YPQstCw0LbQsNC10YLR
gdGPINC60LDQuiDQtdGB0YLRjC4KZXhwb3J0IFdEVFRfRFRMU19QT1JUPSIkRFRMU19QT1JUIiBX
RFRUX1dHX1BPUlQ9IiRXR19QT1JUIiBXRFRUX0NTUVRUX1BPUlQ9IiRDU1FUVF9QT1JUIiBcCiAg
ICAgICBXRFRUX1BBTkVMX1BPUlQ9IiRQQU5FTF9QT1JUIiBXRFRUX1NVQl9QT1JUPSIkU1VCX1BP
UlQiIFdEVFRfU1NIX1BPUlQ9IiR7U1NIX1BPUlQ6LTIyfSIKc2V0ICtlCmJhc2ggPChjdXJsIC00
IC1mc1NMICIkSU5TVEFMTEVSX1VSTCIpIGluc3RhbGwgLS1uby1tZW51IC0tZm9yY2UgLS1kaXJl
Y3QgLXAgIiRXRFRUX1BBU1MiIDI+JjEgfCB0ZWUgIiRXL2luc3RhbGwtJHRzLmxvZyIKcmM9JHtQ
SVBFU1RBVFVTWzBdfQpzZXQgLWUKZWNobyAiICAg0YPRgdGC0LDQvdC+0LLRidC40Log0LfQsNCy
0LXRgNGI0LjQu9GB0Y8g0YEg0LrQvtC00L7QvCAkcmMgKNC70L7QszogJFcvaW5zdGFsbC0kdHMu
bG9nKSIKCiMgaGVhbHRoLWdhdGU6INGD0YHQv9C10YUgPSDRgdC10YDQstC40YEg0LDQutGC0LjQ
stC10L0g0Jgg0YHQu9GD0YjQsNC10YIgRFRMUy4g0JjQvdCw0YfQtSDigJQg0L7RgtC60LDRgiDQ
uCDQstGL0YXQvtC0LgpzbGVlcCAzCkhFQUxUSFk9MAppZiBbICIkcmMiID0gMCBdICYmIHN5c3Rl
bWN0bCBpcy1hY3RpdmUgLS1xdWlldCB3ZHR0IDI+L2Rldi9udWxsIFwKICAgJiYgc3MgLXVsbnAg
Mj4vZGV2L251bGwgfCBncmVwIC1xICI6JERUTFNfUE9SVCAiOyB0aGVuIEhFQUxUSFk9MTsgZmkK
aWYgWyAiJEhFQUxUSFkiICE9IDEgXTsgdGhlbgogIGVjaG8gIiAgIOKclyDRhNC+0YDQuiDQvdC1
INC/0L7QtNC90Y/Qu9GB0Y8gKHJjPSRyYywgRFRMUy3Qv9C+0YDRgiDQvdC1INGB0LvRg9GI0LDQ
tdGCKSIKICBqb3VybmFsY3RsIC11IHdkdHQgLW4gMjAgLS1uby1wYWdlciAyPi9kZXYvbnVsbCB8
IHNlZCAncy9eLyAgICAgLycgfHwgdHJ1ZQogIHJvbGxiYWNrX29sZAogIGRpZSAi0KPRgdGC0LDQ
vdC+0LLQutCwIFdEVFQt0YTQvtGA0LrQsCDQvdC1INGD0LTQsNC70LDRgdGMIOKAlCDQstGL0L/Q
vtC70L3QtdC9INC+0YLQutCw0YIg0L3QsCDQv9GA0LXQttC90LjQuSDRgdC10YDQstC10YAuINCb
0L7QszogJFcvaW5zdGFsbC0kdHMubG9nIgpmaQplY2hvICIgICDinJMg0YTQvtGA0Log0LDQutGC
0LjQstC10L0g0Lgg0YHQu9GD0YjQsNC10YIgJERUTFNfUE9SVCIKCmVjaG8gIj09WzUvNl0g0KHQ
tdGC0Yw6INC/0LDQvdC10LvRjCDQvdC1INC90LDRgNGD0LbRgywgVURQLdC/0L7RgNGC0Ysg0L7R
gtC60YDRi9GC0YsgPT0iCiMg0KPRgdGC0LDQvdC+0LLRidC40Log0LTQvtCx0LDQstC70Y/QtdGC
IEFDQ0VQVCDQvdCwIHRjcC8kUEFORUxfUE9SVCDQuCB0Y3AvJFNVQl9QT1JUINCyIElOUFVUICjQ
v9C+0YHQu9C1INGG0LXQv9C+0YfQtdC6IHVmdyDigJQKIyDRgi7QtS4gdWZ3INC40YUg0J3QlSDQ
v9C10YDQtdC60YDQvtC10YIpLiDQn9Cw0L3QtdC70Ywg0LTQvtC70LbQvdCwINCx0YvRgtGMINC/
0YDQuNCy0LDRgtC90L7QuSwg0LrQsNC6INGDIFJlbW5hd2F2ZTog0YPQsdC40YDQsNC10Lwg0Y3R
gtC4IEFDQ0VQVC4Kd2hpbGUgcmVhZCAtciBydWxlOyBkbwogIFsgLW4gIiRydWxlIiBdIHx8IGNv
bnRpbnVlCiAgIyBldmFsIOKAlCDQsiDQstGL0LLQvtC00LUgLVMg0LrQvtC80LzQtdC90YLQsNGA
0LjQuCDRgSDQv9GA0L7QsdC10LvQsNC80Lgg0L/RgNC40YXQvtC00Y/RgiDQsiDQutCw0LLRi9GH
0LrQsNGFCiAgZXZhbCAiaXB0YWJsZXMgLUQgSU5QVVQgJHtydWxlIy1BIElOUFVUIH0iIDI+L2Rl
di9udWxsICYmIGVjaG8gIiAgINGD0LHRgNCw0Lsg0L/Rg9Cx0LvQuNGH0L3Ri9C5IEFDQ0VQVDog
JHtydWxlIy1BIElOUFVUIH0iCmRvbmUgPCA8KGlwdGFibGVzIC1TIElOUFVUIDI+L2Rldi9udWxs
IHwgZ3JlcCAtRSAtLSAiLS1kcG9ydCAoJFBBTkVMX1BPUlR8JFNVQl9QT1JUKVxiIiB8IGdyZXAg
LUUgIkFDQ0VQVCIgfHwgdHJ1ZSkKaWYgY29tbWFuZCAtdiB1ZncgPi9kZXYvbnVsbCAyPiYxICYm
IHVmdyBzdGF0dXMgMj4vZGV2L251bGwgfCBncmVwIC1xICdeU3RhdHVzOiBhY3RpdmUnOyB0aGVu
CiAgdWZ3IGFsbG93ICIkRFRMU19QT1JUIi91ZHAgY29tbWVudCAnV0RUVCBEVExTJyA+L2Rldi9u
dWxsIDI+JjEgfHwgdHJ1ZQogIHVmdyBhbGxvdyAiJFdHX1BPUlQiL3VkcCAgIGNvbW1lbnQgJ1dE
VFQgV0cnICAgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKICB1ZncgYWxsb3cgIiRDU1FUVF9QT1JU
Ii91ZHAgY29tbWVudCAnV0RUVCBDU1FUVCcgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKICBpZiBp
cCBsaW5rIHNob3cgdGFpbHNjYWxlMCA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIHVmdyBhbGxv
dyBpbiBvbiB0YWlsc2NhbGUwIHRvIGFueSBwb3J0ICIkUEFORUxfUE9SVCIgcHJvdG8gdGNwIGNv
bW1lbnQgJ1dEVFQgcGFuZWwgdmlhIHRhaWxzY2FsZScgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUK
ICBmaQogIHVmdyBkZW55IGluICIkUEFORUxfUE9SVCIvdGNwIGNvbW1lbnQgJ1dEVFQgcGFuZWwg
cHJpdmF0ZScgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKICB1ZncgZGVueSBpbiAiJFNVQl9QT1JU
Ii90Y3AgICBjb21tZW50ICdXRFRUIHN1YiBwcml2YXRlJyAgID4vZGV2L251bGwgMj4mMSB8fCB0
cnVlCiAgZWNobyAiICAgdWZ3OiArJHtEVExTX1BPUlR9LCR7V0dfUE9SVH0sJHtDU1FUVF9QT1JU
fS91ZHA7ICR7UEFORUxfUE9SVH0sJHtTVUJfUE9SVH0vdGNwINC30LDQutGA0YvRgtGLINGB0L3Q
sNGA0YPQttC4IgplbHNlCiAgIyDQsdC10LcgdWZ3IOKAlCDQv9GA0Y/QvNGL0LUg0L/RgNCw0LLQ
uNC70LAgKyBndWFyZC3RjtC90LjRgiwg0YfRgtC+0LHRiyDQv9C10YDQtdC20LjQu9C4INC/0LXR
gNC10LfQsNC/0YPRgdC6IHdkdHQv0YHQtdGA0LLQtdGA0LAKICBjYXQgPiAvdXNyL2xvY2FsL2Jp
bi93ZHR0LXBhbmVsLWd1YXJkLnNoIDw8RU9GCiMhL3Vzci9iaW4vZW52IGJhc2gKZm9yIHAgaW4g
JFBBTkVMX1BPUlQgJFNVQl9QT1JUOyBkbwogIGlwdGFibGVzIC1DIElOUFVUIC1wIHRjcCAtLWRw
b3J0IFwkcCAhIC1pIGxvIC1tIGNvbW1lbnQgLS1jb21tZW50IFdEVFRfUEFORUxfR1VBUkQgLWog
RFJPUCAyPi9kZXYvbnVsbCBcXAogICAgfHwgaXB0YWJsZXMgLUkgSU5QVVQgMSAtcCB0Y3AgLS1k
cG9ydCBcJHAgISAtaSBsbyAtbSBjb21tZW50IC0tY29tbWVudCBXRFRUX1BBTkVMX0dVQVJEIC1q
IERST1AKICBpZiBpcCBsaW5rIHNob3cgdGFpbHNjYWxlMCA+L2Rldi9udWxsIDI+JjE7IHRoZW4K
ICAgIGlwdGFibGVzIC1DIElOUFVUIC1pIHRhaWxzY2FsZTAgLXAgdGNwIC0tZHBvcnQgXCRwIC1t
IGNvbW1lbnQgLS1jb21tZW50IFdEVFRfUEFORUxfR1VBUkQgLWogQUNDRVBUIDI+L2Rldi9udWxs
IFxcCiAgICAgIHx8IGlwdGFibGVzIC1JIElOUFVUIDEgLWkgdGFpbHNjYWxlMCAtcCB0Y3AgLS1k
cG9ydCBcJHAgLW0gY29tbWVudCAtLWNvbW1lbnQgV0RUVF9QQU5FTF9HVUFSRCAtaiBBQ0NFUFQK
ICBmaQpkb25lCkVPRgogIGNobW9kICt4IC91c3IvbG9jYWwvYmluL3dkdHQtcGFuZWwtZ3VhcmQu
c2gKICBjYXQgPiAvZXRjL3N5c3RlbWQvc3lzdGVtL3dkdHQtcGFuZWwtZ3VhcmQuc2VydmljZSA8
PCdFT0YnCltVbml0XQpEZXNjcmlwdGlvbj1LZWVwIFdEVFQgcGFuZWwvc3Vic2NyaXB0aW9uIHBv
cnRzIHByaXZhdGUgKFNTSCB0dW5uZWwgLyB0YWlsc2NhbGUgb25seSkKQWZ0ZXI9bmV0d29yay1v
bmxpbmUudGFyZ2V0IHdkdHQuc2VydmljZQpXYW50cz13ZHR0LnNlcnZpY2UKW1NlcnZpY2VdClR5
cGU9b25lc2hvdApFeGVjU3RhcnQ9L3Vzci9sb2NhbC9iaW4vd2R0dC1wYW5lbC1ndWFyZC5zaApS
ZW1haW5BZnRlckV4aXQ9eWVzCltJbnN0YWxsXQpXYW50ZWRCeT1tdWx0aS11c2VyLnRhcmdldApF
T0YKICBzeXN0ZW1jdGwgZGFlbW9uLXJlbG9hZDsgc3lzdGVtY3RsIGVuYWJsZSAtLW5vdyB3ZHR0
LXBhbmVsLWd1YXJkLnNlcnZpY2UgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKICBlY2hvICIgICB1
Zncg0L3QtdCw0LrRgtC40LLQtdC9IOKAlCDQv9Cw0L3QtdC70Ywg0LfQsNC60YDRi9GC0LAgaXB0
YWJsZXMtZ3VhcmQn0L7QvCAod2R0dC1wYW5lbC1ndWFyZC5zZXJ2aWNlKSIKZmkKCmVjaG8gIj09
WzYvNl0g0J/RgNC+0LLQtdGA0LrQsCA9PSIKc2xlZXAgMwppZiBzeXN0ZW1jdGwgaXMtYWN0aXZl
IC0tcXVpZXQgd2R0dCAyPi9kZXYvbnVsbDsgdGhlbgogIGVjaG8gIiAgIHdkdHQuc2VydmljZTog
YWN0aXZlIgplbHNlCiAgZWNobyAiICAgISB3ZHR0LnNlcnZpY2Ug0L3QtSDQsNC60YLQuNCy0LXQ
vSDigJQgam91cm5hbGN0bCAtdSB3ZHR0IC1uIDMwOiI7IGpvdXJuYWxjdGwgLXUgd2R0dCAtbiAz
MCAtLW5vLXBhZ2VyIDI+L2Rldi9udWxsIHx8IHRydWUKZmkKZWNobyAiICAg0YHQu9GD0YjQsNGO
0YIgKNC+0LbQuNC00LDQtdC8IHVkcCAkRFRMU19QT1JULyRXR19QT1JULyRDU1FUVF9QT1JULCB0
Y3AgJFBBTkVMX1BPUlQpOiIKc3MgLXVsbnAgMj4vZGV2L251bGwgfCBncmVwIC1FICI6KCREVExT
X1BPUlR8JFdHX1BPUlR8JENTUVRUX1BPUlQpICIgfCBzZWQgJ3MvXi8gICAgIC8nIHx8IGVjaG8g
IiAgICAgKHVkcC3Qv9C+0YDRgtGLINC90LUg0L3QsNC50LTQtdC90YspIgpzcyAtdGxucCAyPi9k
ZXYvbnVsbCB8IGdyZXAgLUUgIjokUEFORUxfUE9SVCAiIHwgc2VkICdzL14vICAgICAvJyB8fCBl
Y2hvICIgICAgICjQv9Cw0L3QtdC70Ywg0L3QsCAkUEFORUxfUE9SVCDQvdC1INGB0LvRg9GI0LDQ
tdGCKSIKUEFORUxfQ09ERT0iJChjdXJsIC1zIC1vIC9kZXYvbnVsbCAtdyAnJXtodHRwX2NvZGV9
JyAtLW1heC10aW1lIDQgImh0dHA6Ly8xMjcuMC4wLjE6JFBBTkVMX1BPUlQvd2R0dC8iIDI+L2Rl
di9udWxsIHx8IHRydWUpIgplY2hvICIgICDQv9Cw0L3QtdC70YwgaHR0cDovLzEyNy4wLjAuMTok
UEFORUxfUE9SVC93ZHR0LyAtPiBIVFRQICR7UEFORUxfQ09ERTot0L3QtdGCINC+0YLQstC10YLQ
sH0iCmdyZXAgLXEgJ153ZHR0LXBhbmVsOicgIiRDUkVEX0ZJTEUiIDI+L2Rldi9udWxsIFwKICB8
fCBwcmludGYgJ3dkdHQtcGFuZWw6IGh0dHA6Ly8xMjcuMC4wLjE6JXMvd2R0dC8gKGFkbWluIC8g
d2R0dCDigJQg0KHQnNCV0J3QmCDQsiDQvdCw0YHRgtGA0L7QudC60LDRhSDQv9Cw0L3QtdC70Lgp
XG4nICIkUEFORUxfUE9SVCIgPj4gIiRDUkVEX0ZJTEUiCmlmIFsgLW4gIiR7T0xEX0JJTjotfSIg
XTsgdGhlbiAgICMgT0xEX0JJTiDQt9Cw0LTQsNC9INGC0L7Qu9GM0LrQviDQv9GA0Lgg0LzQuNCz
0YDQsNGG0LjQuCDRgSBhbXVyY2Fub3YKICBlY2hvICIgICDQv9GA0L7QstC10YDQutCwLCDRh9GC
0L4g0L/QsNGA0L7Qu9GMINCyINC/0LDQvdC10LvQuCDRgdC+0LLQv9Cw0Lsg0YEg0L3QsNGI0LjQ
vDoiCiAgREJQPSIkKHNxbGl0ZTMgL2V0Yy93ZHR0L3BhbmVsLmRiICdTRUxFQ1QgbWFpbl9wYXNz
d29yZCBGUk9NIHdkdHRfZ2xvYmFsIExJTUlUIDE7JyAyPi9kZXYvbnVsbCB8fCB0cnVlKSIKICBp
ZiBbIC1uICIkREJQIiBdICYmIFsgIiREQlAiID0gIiRXRFRUX1BBU1MiIF07IHRoZW4gZWNobyAi
ICAgICBPSyDigJQg0LrQu9C40LXQvdGC0Ysg0YHQviDRgdGC0LDRgNGL0Lwg0L/QsNGA0L7Qu9C1
0Lwg0L/RgNC+0LTQvtC70LbQsNGCINGA0LDQsdC+0YLQsNGC0YwiCiAgZWxzZSBlY2hvICIgICAg
ICEg0LIgcGFuZWwuZGIg0LTRgNGD0LPQvtC5L9C/0YPRgdGC0L7QuSDQv9Cw0YDQvtC70Ywg4oCU
INC30LDQtNCw0Lkg0LIg0L/QsNC90LXQu9C4OiAkV0RUVF9QQVNTIjsgZmkKZmkKZWNobwplY2hv
ICLinIUgV0RUVCAoaWxkYXJtYWdhL3dkdHQpINGD0YHRgtCw0L3QvtCy0LvQtdC9IgplY2hvICIg
ICDQn9Cw0YDQvtC70Ywg0LrQu9C40LXQvdGC0LA6ICRXRFRUX1BBU1MgKNGC0LDQutC20LUg0LIg
JENSRURfRklMRSkiCmVjaG8gIiAgINCf0LDQvdC10LvRjDogc3NoIC1MICRQQU5FTF9QT1JUOjEy
Ny4wLjAuMTokUEFORUxfUE9SVCByb290QEBARVhJVF9JUEBAICDihpIgIGh0dHA6Ly9sb2NhbGhv
c3Q6JFBBTkVMX1BPUlQvd2R0dC8iCmVjaG8gIiAgICAgICAgICAg0LvQvtCz0LjQvSDQv9C+INGD
0LzQvtC70YfQsNC90LjRjiBhZG1pbiAvIHdkdHQg4oCUINCh0JzQldCd0Jgg0L/RgNC4INC/0LXR
gNCy0L7QvCDQstGF0L7QtNC1IgplY2hvICIgICDQmtC70LjQtdC90YLRizogaU9TIHZrLXR1cm4t
cHJveHktaW9zIChTUlRQLVdSQVAtQSwg0LjQu9C4IHdkdHQ6Ly8t0YHRgdGL0LvQutCwINC40Lcg
0L/QsNC90LXQu9C4KTsiCmVjaG8gIiAgICAgICAgICAgIEFuZHJvaWQgV0RUVC9xV0RUVDsgQ1NR
VFQt0LrQu9C40LXQvdGC0Ysg4oCUIFVEUCAkQ1NRVFRfUE9SVCIK
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
  verify)  do_verify ;;
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
    echo "  v) Сверить панель с живым Xray — найти расхождения (verify)"
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
      v|V) do_verify ;;
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
