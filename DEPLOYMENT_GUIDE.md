# Alderbow — полный гайд по развёртыванию с нуля

Этот документ написан так, чтобы по нему можно было развернуть всю инфраструктуру
заново, не помня ничего о проекте, кроме одного файла — `mycloud-deploy.sh`.

---

## 1. Архитектура — что вообще разворачивается

Два сервера:

- **Moonlight (exit)** — выходной сервер. На нём стоит панель Remnawave
  (управление VPN-пользователями), Xray-нода (реальный VPN-выход) и
  сайт-декой (маскировка — снаружи выглядит как обычный сайт облачного
  хранилища).
- **Sunshine (relay)** — необязательный второй сервер-релей. Пользователь
  подключается к Sunshine, трафик каскадом (ещё одним VLESS-туннелем)
  уходит на Moonlight и оттуда — в интернet. Нужен, если Moonlight
  заблокирован у части пользователей, а Sunshine — нет.

Оба сервера держат порт 443 одним и тем же образом ("selfsteal"):

```
Клиент → домен:443 (VLESS-REALITY, Xray) → не прошёл REALITY-хендшейк →
         fallback на 127.0.0.1:8443 (Caddy) → Caddy смотрит путь запроса:
           /            → сайт-декой (маскировка)
           /wsng        → 127.0.0.1:2053 (VLESS-WS backend)
           /xh          → 127.0.0.1:2054 (VLESS-XHTTP backend)
           /api/sub/*   → панель (страница подписки)
           /c/*         → connect-страница для клиента
```

Т.е. с точки зрения интернета на каждом сервере открыт только один порт 443,
и он выглядит как обычный HTTPS-сайт с настоящим Let's Encrypt-сертификатом.
Все VPN-протоколы прячутся за этим одним портом.

Протоколы, доступные пользователю в подписке:
- **VLESS-REALITY** (прямой, самый маскированный)
- **VLESS-WS** (WebSocket поверх TLS)
- **VLESS-XHTTP** (HTTP-подобный транспорт)
- **Hysteria2** (UDP/443, отдельный протокол)

Каждый из них — и напрямую на Moonlight, и "via Sunshine" (если релей развёрнут).

---

## 2. Что нужно ДО начала

1. **Два VPS** (Ubuntu 22.04/24.04 или Debian 12), root-доступ по SSH.
   Один — Moonlight (exit), второй — Sunshine (relay), если он нужен.
2. **Два домена** (или два поддомена), с A-записями, указывающими на IP
   соответствующих серверов. Например:
   - `memory.example.com` → IP Moonlight
   - `memoru.example.com` → IP Sunshine
   Домены обязаны резолвиться ПРАВИЛЬНО до запуска деплоя — иначе не
   выпустится Let's Encrypt сертификат.
3. **SSH root-доступ с Moonlight на Sunshine** должен быть возможен (по
   паролю хотя бы один раз — дальше скрипт сам заведёт ключ). Проще всего:
   на Sunshine включён вход по паролю root (или уже есть ключ).
4. Файл `mycloud-deploy.sh` (единственный файл нужен, все шаблоны зашиты
   внутрь base64-блобами). Взять из репозитория:
   ```bash
   curl -fsSL -o /root/mycloud-deploy.sh \
     https://raw.githubusercontent.com/jovial-nik/alderbow/<ветка>/mycloud-deploy.sh
   ```
   Актуальная стабильная ветка на момент написания: `stable/xhttp-fixed`.
   Рабочая ветка с текущей разработкой: `claude/hopeful-thompson-gr606f`.

---

## 3. Чистый деплой с нуля

### Шаг 1 — на Moonlight

```bash
ssh root@<IP_MOONLIGHT>
curl -fsSL -o /root/mycloud-deploy.sh \
  https://raw.githubusercontent.com/jovial-nik/alderbow/stable/xhttp-fixed/mycloud-deploy.sh
bash -n /root/mycloud-deploy.sh && echo "синтаксис ОК"
cd /root
```

### Шаг 2 — настроить конфигурацию (wizard)

```bash
sudo bash mycloud-deploy.sh wizard
```

Мастер спросит по очереди (Enter — оставить значение по умолчанию):

| Вопрос | Что ввести |
|---|---|
| Роль сервера | `exit` (это Moonlight) |
| Бренд | название для декой-сайта, например `Alderbow` |
| SSH-порт | обычно `22` |
| Hardening SSH+firewall | `no` (если не нужно ужесточение) |
| Домен выходного сервера | `memory.example.com` |
| Публичный IP выходного сервера | IP Moonlight |
| Имя выходного узла | `Moonlight` (метка, для читаемости) |
| E-mail для Let's Encrypt | твой email |
| Скрывать панель через Tailscale | `yes` (рекомендуется — панель НЕ будет публично доступна) |
| Блокировать RU-домены/IP на выходе | `no`, если не нужно |
| Post-quantum Reality | `no` (экспериментально, не включай без причины) |
| Staging-сертификат LE | `no` (staging — только для тестов, браузер будет ругаться) |
| Пароль WDTT | Enter — сгенерируется сам |
| Пароль admin-панели | Enter — сгенерируется сам |
| Публичный IP релея | IP Sunshine, если он есть; иначе Enter (пусто) |
| Домен релея | `memoru.example.com`, если релей есть |
| Имя релея | `Sunshine` |
| После exit сразу развернуть релей | `yes` — тогда всё сделается одной командой |

Конфиг сохранится в `deploy.conf` рядом со скриптом.

### Шаг 3 — запустить полный деплой

```bash
sudo bash mycloud-deploy.sh run exit
```

Это займёт 10-20 минут. Если в визарде включил `AUTO_RELAY=yes` и указал
`RELAY_IP` — Sunshine развернётся автоматически в конце этого же прогона
(скрипт сам зайдёт на Sunshine по SSH).

**Что произойдёт по фазам** (для понимания, если что-то упадёт на середине):

1. `wdtt-build.sh` — мобильный TURN-канал (аварийный VPN)
2. `deploy-moonlight.sh` — поднимает Docker, панель Remnawave, страницу
   подписки, временный Caddy на 443 (для выпуска сертификата), генерирует
   Reality-ключи и Xray-профиль
3. `provision.sh` — headless-настройка панели через API: создаёт админа,
   config-profile, ноду, squad, тестового пользователя `Test`, host-записи
   для подписки
4. `deploy-node.sh exit` — поднимает контейнер Xray-ноды
5. `sync-hy2-cert.sh exit` — копирует Let's Encrypt сертификат в ноду (для Hysteria2)
6. `handoff-moonlight.sh` — САМЫЙ ВАЖНЫЙ ШАГ: убирает Caddy с 443, отдаёт
   443 ноде (Xray Reality), Caddy остаётся на 8443 как fallback-бэкенд.
   Если панель не отвечает после этого — скрипт САМ откатывает Caddy
   обратно на 443, чтобы не потерять доступ.
7. `kick-node.sh exit` — пинает ноду через API, чтобы конфиг реально применился
8. `stealth.sh decoy` + `stealth.sh caddy` — деплоит сайт-декой и
   финальный Caddyfile (со всеми /wsng, /xh, /api/sub, /c маршрутами)
9. `deploy-decoy-pro.sh` + `deploy-decoy-pages.sh` — расширенные страницы декоя
10. `setup-connect-min.sh` — генерирует персональную connect-страницу
    `/c/<uuid>/` для тестового клиента
11. `health-check.sh` — итоговая проверка всех портов/сертификатов/контейнеров
12. (если `AUTO_RELAY=yes`) — авто-запуск `run relay` (см. ниже)
13. (если `USE_TAILSCALE=yes`) — `setup-tailscale.sh`, панель становится
    доступна по `https://<node>.<tailnet>.ts.net:8444`

### Шаг 4 — если релей НЕ развернулся автоматически

```bash
sudo bash mycloud-deploy.sh run relay
```

Фазы:
1. `provision-relay.sh` — запускается НА MOONLIGHT. Создаёт сервис-юзера
   каскада, config-profile для Sunshine (с 4 инбаундами SUN-REALITY/
   SUN-WS/SUN-XHTTP/SUN-HY2 и outbound-каскадом на Moonlight), ноду
   Sunshine, добавляет её инбаунды в squad, добавляет каскад-юзера в squad,
   создаёт SECRET_KEY и упаковывает всё в `relay-bootstrap.env`
2. `setup-relay-ssh.sh` — генерирует SSH-ключ (если его ещё нет),
   копирует его на Sunshine (спросит пароль root ОДИН раз), передаёт
   `mycloud-deploy.sh` + `relay-bootstrap.env`, запускает на Sunshine
   `run sunshine-node`
3. `kick-node.sh relay` — пинает ноду Sunshine с панели Moonlight
4. `health-check.sh`

На самом Sunshine (`run sunshine-node`, запускается удалённо через SSH
шагом выше) выполняются фазы:
1. `deploy-sunshine.sh` — Docker, IPv6 off, UFW, Caddy на 8443 + декой,
   Reality-ключи Sunshine
2. `sync-hy2-cert.sh relay`
3. `deploy-node.sh relay` — поднимает Xray-ноду (SECRET_KEY уже есть из
   `relay-bootstrap.env`)
4. `deploy-decoy-sunshine.sh` — те же декой-страницы, что на Moonlight
5. `health-check.sh`

**Важный нюанс**: на Sunshine порт `tcp/443` обычно не успевает подняться
за 90 секунд ожидания в `deploy-node.sh` — это нормально, конфиг долетает
с панели чуть позже. Через 15-30 секунд после `kick-node.sh relay`
он появляется сам. Проверить:
```bash
ssh root@<IP_SUNSHINE> "ss -tlnp | grep ':443 '"
```

### Шаг 5 — проверка результата

```bash
sudo bash mycloud-deploy.sh info
```

Покажет: ссылку на панель, доступы, ссылку на подписку тестового
пользователя, WDTT-данные.

Открой ссылку подписки/connect-страницу на телефоне/компьютере в
VPN-клиенте (Shadowrocket / Happ / v2RayTun / любой на базе Xray или
sing-box), импортируй и протестируй задержку по всем протоколам.

---

## 4. Все команды CLI скрипта

```bash
sudo bash mycloud-deploy.sh wizard          # интерактивная настройка deploy.conf
sudo bash mycloud-deploy.sh config          # показать текущий конфиг
sudo bash mycloud-deploy.sh stages          # список фаз для текущей роли
sudo bash mycloud-deploy.sh run exit        # полный деплой роли exit (Moonlight)
sudo bash mycloud-deploy.sh run relay       # полный деплой роли relay (запускается на Moonlight, деплоит Sunshine по SSH)
sudo bash mycloud-deploy.sh --from <фаза> run exit   # запуск с конкретной фазы (напр. --from provision.sh)
sudo bash mycloud-deploy.sh info            # сводка: ссылки, доступы
sudo bash mycloud-deploy.sh probe           # проверка серверов СНАРУЖИ (как видит их клиент)
sudo bash mycloud-deploy.sh update          # обновить Docker-образы панели/ноды/Caddy
sudo bash mycloud-deploy.sh backup          # бэкап конфигов + дамп БД панели
sudo bash mycloud-deploy.sh restore [архив] # восстановить из бэкапа
sudo bash mycloud-deploy.sh rotate          # сменить пароли (панель, WDTT)
sudo bash mycloud-deploy.sh reset           # ПОЛНОЕ УДАЛЕНИЕ стека (необратимо!)
sudo bash mycloud-deploy.sh render <имя>    # вывести отрендеренный шаблон (для отладки)
sudo bash mycloud-deploy.sh extract <dir>   # распаковать все шаблоны в каталог (для чтения исходников)
```

Повторный запуск `run exit` / `run relay` на уже развёрнутом сервере —
**безопасен и идемпотентен**: скрипт видит существующие панель/ноду/
squad/хосты и обновляет их (upsert), а не создаёт дубликаты. Это основной
способ докатить новые фиксы на уже работающий сервер:

```bash
# обновить скрипт
curl -fsSL -o /root/mycloud-deploy.sh https://raw.githubusercontent.com/jovial-nik/alderbow/<ветка>/mycloud-deploy.sh
# перезапустить с нужной фазы (пропускает уже сделанное docker/ufw/etc, но
# провижининг панели через API прогонит заново и подхватит правки)
sudo bash mycloud-deploy.sh --from provision.sh run exit
sudo bash mycloud-deploy.sh --from provision-relay.sh run relay
```

---

## 5. Где лежат доступы и конфиги (на сервере)

| Файл | Что там |
|---|---|
| `/root/mycloud-deploy.sh` | сам скрипт |
| `/opt/<slug>/.deploy/deploy.conf` | сохранённая конфигурация wizard'а (slug — это бренд, приведённый к нижнему регистру, напр. `alderbow`) |
| `/opt/<slug>/credentials.txt` | логин/пароль admin панели Remnawave |
| `/opt/<slug>/summary.txt` | последняя сводка `info` |
| `/opt/<slug>/node/reality.env` | Reality-ключи Moonlight (private/public/shortId) |
| `/opt/<slug>/node/.env` | SECRET_KEY ноды Moonlight |
| `/opt/<slug>/relay-bootstrap.env` | всё, что нужно Sunshine (ключи, каскад-UUID, SECRET_KEY) |
| `/opt/<slug>/node-Sunshine.env` | локальная копия SECRET_KEY релея (для повторного использования при redeploy) |
| `/opt/<slug>/deploy.log` | лог всех прогонов деплоя |
| `/opt/<slug>/backups/*.tar.gz` | архивы, созданные командой `backup` |

Панель НЕ публична (если `USE_TAILSCALE=yes`). Доступ к ней:
- **Tailscale**: `https://<node>.<tailnet>.ts.net:8444` (после `tailscale up`
  на своём устройстве в том же тайлнете)
- **SSH-туннель** (фолбэк, работает всегда):
  ```bash
  ssh -L 8081:127.0.0.1:8081 root@<IP_MOONLIGHT>
  # затем открыть в браузере https://localhost:8081 (сертификат
  # самоподписанный, это нормально — подтвердить "продолжить")
  ```

---

## 6. Диагностика и типовые проблемы

### 6.1 Быстрая проверка живости сервера

```bash
sudo bash mycloud-deploy.sh info                     # изнутри
sudo bash mycloud-deploy.sh probe                    # снаружи, как видит клиент
```

Или руками:
```bash
ss -tlnp | grep ':443 '                               # должен быть rw-core/xray
docker ps --format "table {{.Names}}\t{{.Status}}"
docker logs remnanode --tail 30
curl -sk -o /dev/null -w "%{http_code}\n" https://<домен>/
```

### 6.2 Доступ к API панели без браузера (headless)

Панель отвечает ТОЛЬКО через Caddy (HTTP-заголовки X-Forwarded-Proto
обязательны) — прямой `curl http://127.0.0.1:3000` не работает.

```bash
PASS=$(grep -E '^\s*pass:' /opt/<slug>/credentials.txt | awk '{print $2}' | head -1)
TOK=$(curl -sk -X POST https://localhost:8081/api/auth/login \
  -H 'Content-Type: application/json' -H 'X-Remnawave-Client-Type: browser' \
  -d "{\"username\":\"admin\",\"password\":\"$PASS\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["response"]["accessToken"])')

# дальше любой запрос:
curl -sk https://localhost:8081/api/nodes -H "Authorization: Bearer $TOK" -H 'X-Remnawave-Client-Type: browser'
```

Remnawave 2.7.x API (основные эндпоинты):
- `POST /auth/login`, `POST /auth/register`
- `GET/POST/DELETE /config-profiles`, `GET /config-profiles/{uuid}/inbounds`
- `GET/POST/PATCH /nodes`, `POST /nodes/{uuid}/actions/restart`,
  `POST /nodes/{uuid}/actions/enable`
- `GET/POST/PATCH /internal-squads`, `GET /internal-squads/{uuid}`
- `GET/POST/PATCH/DELETE /hosts`
- `GET/POST /users`, `GET /users/by-username/{name}`
- `GET /keygen` (SECRET_KEY для новой ноды)
- `POST /tokens` (API-токен для subscription-page)

### 6.3 Известные грабли (все найдены и исправлены в коде, но полезно знать)

Если когда-нибудь придётся откатиться на старую версию скрипта или
диагностировать похожую поломку — вот полный список того, что когда-либо
ломало XHTTP/relay в этом проекте:

1. **XHTTP host с securityLayer=REALITY вместо TLS.** XHTTP работает через
   selfsteal (backend на 127.0.0.1 за Caddy) — клиент должен подключаться
   обычным TLS, не REALITY-хендшейком.
2. **SUN-WS на Sunshine был на прямом TLS вместо selfsteal** — конфликт с
   Caddy, который тоже пытался проксировать на тот же порт как plain HTTP.
3. **`provision.sh` пропускал уже существующие host-записи** вместо
   обновления — из-за этого фиксы конфигурации не долетали до уже
   развёрнутого сервера при повторном прогоне. Исправлено: теперь
   удаляет старый host и создаёт новый (upsert).
4. **PATCH ноды не обновлял `activeInbounds`** при повторном provision —
   новый инбаунд (например, добавленный XHTTP) физически не поднимался в
   Xray, хотя в панели всё выглядело правильно.
5. **Caddyfile терял `flush_interval -1`** при перезаписи в некоторых
   фазах (`deploy-decoy-sunshine.sh`) — без этого Caddy буферизует
   стриминговый ответ XHTTP, и скачивающий поток не доходит до клиента.
6. **Squad (internal-squad) может отстать от инбаундов профиля** — если
   squad уже существует, `provision.sh` раньше вообще не трогал его
   список инбаундов. Теперь при каждом запуске доливает недостающие
   (union, ничего не удаляя — критично, чтобы не стереть чужие инбаунды
   Sunshine, как было при историческом инциденте с обнулением squad).
7. **Опечатка в поле JSON**: `"security"` вместо `"securityLayer"` в
   host-теле в `provision-relay.sh` — API молча игнорировал поле и
   подставлял DEFAULT (REALITY) вместо TLS для всех via-Sunshine
   WS/XHTTP хостов.
8. **HTTP/2 vs HTTP/1.1 (ALPN) для XHTTP.** Это была финальная и самая
   тонкая проблема: Xray-клиент решает, какую версию HTTP использовать,
   по СВОЕЙ собственной настройке ALPN в конфиге — не по факту
   негоциации с сервером. Если форсить `protocols h1` на Caddy и/или
   `alpn: http/1.1` на клиенте — XHTTP переходит в режим `packet-up`,
   который открывает МНОГО отдельных коротких TCP-соединений для
   аплоуда. Каждое такое соединение — это отдельный проход через
   REALITY-фолбэк-хендшейк, и на нестабильной сети шанс, что хотя бы
   одно из них зависнет/оборвётся, гораздо выше, чем у WS (у него всего
   ОДНО долгоживущее соединение). Решение: НЕ ограничивать Caddy
   `protocols h1`, НЕ форсить `alpn` в host-записи — дать клиенту
   самому договориться на HTTP/2, тогда XHTTP получает мультиплексирование
   (много логических потоков через одно TCP-соединение) и становится
   так же стабилен, как WS. `flush_interval -1` при этом остаётся
   обязательным независимо от версии HTTP.

### 6.4 Если что-то сломалось после ручных правок в панели

Откатиться проще всего, перезапустив нужную фазу — почти все они
идемпотентны:
```bash
sudo bash mycloud-deploy.sh --from provision.sh run exit       # пере-провижинить панель Moonlight
sudo bash mycloud-deploy.sh --from provision-relay.sh run relay # пере-провижинить Sunshine
sudo bash mycloud-deploy.sh --from stealth.sh run exit          # переписать Caddyfile+декой Moonlight
```

Если совсем всё плохо — есть бэкап Caddyfile перед каждой перезаписью
(`/opt/<slug>/caddy/Caddyfile.bak.<timestamp>`), можно откатить руками:
```bash
cp /opt/<slug>/caddy/Caddyfile.bak.<TS> /opt/<slug>/caddy/Caddyfile
docker exec <slug>-caddy caddy reload --config /etc/caddy/Caddyfile
```

### 6.5 Полный снос и переустановка

```bash
sudo bash mycloud-deploy.sh reset      # спросит подтверждение словом YES, необратимо
sudo bash mycloud-deploy.sh wizard     # заново
sudo bash mycloud-deploy.sh run exit   # заново
```

---

## 7. Тестирование клиента

После деплоя — тестовый пользователь `Test` уже создан с подпиской на
все протоколы. Ссылки видны в выводе `run exit` / команде `info`:

```
Подписка: https://<домен>/api/sub/<shortUuid>
Страница: https://<домен>/c/<shortUuid>/
```

Импортируй в любой VPN-клиент на базе Xray-core (Shadowrocket, Happ,
v2RayTun, NekoBox и т.д.) и прогони тест задержки по всем профилям:
- `<Название> · VLESS-REALITY`
- `<Название> · VLESS-WS`
- `<Название> · VLESS-XHTTP`
- `<Название> · VLESS-REALITY (Hysteria2)`
- те же 4, но с префиксом `via Sunshine ·` — если релей развёрнут

Все восемь должны отвечать стабильно. Если какой-то падает — см. раздел
6.3 выше, там разобран практически весь спектр возможных поломок этой
конкретной архитектуры.

**Важно про клиент**: если тестируешь через приложение с автообновлением
подписки — после любого изменения host-записей на сервере (например,
после `provision.sh`/`provision-relay.sh`) обязательно **обнови
подписку** в клиенте вручную (кнопка "Обновить подписку" / re-import) —
иначе клиент продолжит использовать старые (закэшированные) параметры
хостов и результат теста будет вводить в заблуждение.

---

## 8. Безопасность — что НИКОГДА не должно происходить

- Никогда не публикуй `credentials.txt`, `reality.env`, `relay-bootstrap.env`
  или содержимое `deploy.conf` — там пароли и приватные ключи.
- Никогда не проси делиться SSH-приватными ключами/паролями в чате — это
  не нужно ни для настройки, ни для диагностики (весь этот гайд построен
  на том, что все команды выполняются САМИМ владельцем сервера в своём
  терминале).
- Панель НЕ должна быть публично доступна — держи `USE_TAILSCALE=yes`
  или используй только SSH-туннель.
