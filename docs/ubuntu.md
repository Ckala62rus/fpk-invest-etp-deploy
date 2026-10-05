# Развёртывание ЭТП на Ubuntu

Этот runbook относится к production/test Docker Compose из корня deploy-репозитория. Compose требует три соседних checkout:

```text
/opt/etp/
├── backend/   # Laravel API
├── frontend/  # Vue SPA
└── deploy/    # этот репозиторий: Compose, gateway nginx, скрипты
```

Не вкладывайте `deploy/` внутрь backend или frontend: Compose и `scripts/release.sh` используют sibling-пути `../backend` и `../frontend`.

## 1. Требования

- Ubuntu 22.04 / 24.04;
- Docker Engine и Compose plugin (`docker compose`);
- открытый порт 80; для HTTPS также 443;
- Docker должен иметь доступ к образам `node:22-alpine`, `php:8.4-fpm-alpine`, nginx, PostgreSQL и Redis.

После добавления пользователя в группу Docker войдите по SSH заново:

```bash
sudo usermod -aG docker "$USER"
```

## 2. Получение трёх версий

Для каждого релиза записывайте и используйте три тега или commit SHA: deploy, backend и frontend. Не используйте движущиеся ветки для боевого релиза, если нужен воспроизводимый откат.

```bash
sudo install -d -o "$USER" -g "$USER" /opt/etp

git clone <BACKEND_REPOSITORY_URL> /opt/etp/backend
git -C /opt/etp/backend checkout --detach <BACKEND_TAG_OR_SHA>

git clone <FRONTEND_REPOSITORY_URL> /opt/etp/frontend
git -C /opt/etp/frontend checkout --detach <FRONTEND_TAG_OR_SHA>

git clone <DEPLOY_REPOSITORY_URL> /opt/etp/deploy
git -C /opt/etp/deploy checkout --detach <DEPLOY_TAG_OR_SHA>
```

Preflight-проверка:

```bash
test -f /opt/etp/deploy/docker-compose.yml
test -f /opt/etp/backend/src/artisan
test -f /opt/etp/backend/docker/nginx/config/conf.d/default.conf
test -f /opt/etp/frontend/package.json

git -C /opt/etp/deploy status --short
git -C /opt/etp/backend status --short
git -C /opt/etp/frontend status --short
```

Статусы Git должны быть пустыми. Исключение — серверные `.env`, которые обязаны игнорироваться Git.

## 3. Server-specific конфигурация

### Compose

```bash
cd /opt/etp/deploy
cp .env.example .env
chmod 600 .env
nano .env
```

Укажите сильный `POSTGRES_PASSWORD`. Файл `deploy/.env` хранит секреты, игнорируется `.gitignore` и не должен попадать в Git, архивы исходников или чат.

### Laravel

```bash
cp /opt/etp/deploy/env/backend.src.env.example /opt/etp/backend/src/.env
chmod 600 /opt/etp/backend/src/.env
nano /opt/etp/backend/src/.env
```

До первого релиза сгенерируйте постоянный `APP_KEY`:

```bash
docker run --rm php:8.4-cli-alpine php -r 'echo "base64:".base64_encode(random_bytes(32)).PHP_EOL;'
```

Вставьте его в `APP_KEY=`. Не запускайте `php artisan key:generate` после запуска приложения: это делает недоступными зашифрованные данные и существующие сессии.

Также задайте:

- `APP_URL` и `FRONTEND_URL` — единый публичный origin;
- `DB_PASSWORD` — в точности `POSTGRES_PASSWORD` из `deploy/.env`;
- `REVERB_APP_KEY` и `REVERB_APP_SECRET` — случайные строки;
- `SUPER_ADMIN_INN`, `SUPER_ADMIN_EMAIL`, `SUPER_ADMIN_PASSWORD`;
- production SMTP через `MAIL_*`; на test-сервере используйте MailHog по инструкции ниже.

### MailHog только для test-сервера

По умолчанию Compose не запускает MailHog. Для получения тестовых писем, включая ссылку подтверждения email и токен восстановления пароля, в `backend/src/.env` задайте:

```dotenv
MAIL_MAILER=smtp
MAIL_SCHEME=null
MAIL_HOST=mailhog-etp
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_FROM_ADDRESS="noreply@test.etp.local"
MAIL_FROM_NAME="${APP_NAME}"
```

Не задавайте `MAIL_URL`: он может переопределить отдельные SMTP-переменные. Затем включите профиль и примените изменённую Laravel-конфигурацию:

```bash
cd /opt/etp/deploy
docker compose --profile mailhog up -d mailhog-etp
docker compose exec backend-etp php artisan config:clear
docker compose restart backend-etp horizon-etp scheduler-etp
```

MailHog SMTP не опубликован наружу. Его UI привязан только к `127.0.0.1:8025` сервера и содержит секретные ссылки/токены, поэтому не открывайте этот порт в firewall и не проксируйте его через public gateway. На рабочем компьютере поднимите SSH-tunnel:

```bash
ssh -N -L 8025:127.0.0.1:8025 <USER>@<TEST_SERVER>
```

После этого откройте в браузере `http://localhost:8025`. Для следующего полного запуска test-стека используйте `docker compose --profile mailhog up -d --build`; обычный production-запуск профиль не включает.

Проверка: создайте нового пользователя и откройте письмо подтверждения email в MailHog; для существующего пользователя используйте страницу восстановления пароля. Письмо восстановления содержит одноразовый токен, который нужно вставить в форму reset, а не готовую ссылку.

Для HTTP по IP `10.60.25.87`:

```dotenv
APP_URL=http://10.60.25.87
FRONTEND_URL=http://10.60.25.87
SESSION_DOMAIN=
SESSION_SECURE_COOKIE=false
SANCTUM_STATEFUL_DOMAINS=10.60.25.87
REVERB_HOST=10.60.25.87
REVERB_PORT=80
REVERB_SCHEME=http
```

Для HTTPS используйте домен без схемы в `SESSION_DOMAIN` и `SANCTUM_STATEFUL_DOMAINS`, а `SESSION_SECURE_COOKIE=true`, `REVERB_PORT=443`, `REVERB_SCHEME=https`.

### Frontend

```bash
cp /opt/etp/deploy/env/frontend.env.production.example /opt/etp/frontend/.env.production
chmod 600 /opt/etp/frontend/.env.production
nano /opt/etp/frontend/.env.production
```

`VITE_REVERB_APP_KEY` обязан совпадать с backend `REVERB_APP_KEY`. Оставьте `VITE_API_BASE_URL=` пустым для same-origin. В production frontend `.env.production` должен игнорироваться Git.

## 4. HTTP или HTTPS

```bash
cd /opt/etp/deploy
chmod +x scripts/*.sh
./scripts/switch-tls.sh http
```

Для HTTPS до переключения разместите `nginx/certs/fullchain.pem` и `nginx/certs/privkey.pem`, задайте права `chmod 640 nginx/certs/privkey.pem`, затем выполните `./scripts/switch-tls.sh https`. После смены режима синхронизируйте URL, Reverb и `SESSION_SECURE_COOKIE` в `backend/src/.env`, затем очистите Laravel config и перезапустите PHP-сервисы.

## 5. Первый релиз

`release.sh` останавливает Compose-стек и не создаёт `APP_KEY` или demo-данные. Не прерывайте его `Ctrl+C`; при ошибке скрипт сам остановит частично поднятый стек.

```bash
cd /opt/etp/deploy
sudo install -d -m 700 -o "$USER" -g "$USER" /srv/etp-backups
docker compose config --quiet
docker compose down

./scripts/release.sh \
  --backend-ref <BACKEND_TAG_OR_SHA> \
  --frontend-ref <FRONTEND_TAG_OR_SHA> \
  --apply-migrations --confirm \
  --backup-dir /srv/etp-backups
```

На новой БД выполните только production-safe сидеры в указанном порядке:

```bash
docker compose exec backend-etp php artisan db:seed --class=RolesAndPermissionsSeeder --force
docker compose exec backend-etp php artisan db:seed --class=SettingsSeeder --force
docker compose exec backend-etp php artisan db:seed --class=NotificationTemplateSeeder --force
docker compose exec backend-etp php artisan db:seed --class=SuperAdminSeeder --force
```

Не запускайте `php artisan db:seed --force` без `--class`: общий сидер добавляет demo-данные.

## 6. Приёмка

```bash
docker compose ps
curl -fsS http://127.0.0.1/api/health | grep -F '"database":true'
curl -fsS http://127.0.0.1/api/health | grep -F '"redis":true'
curl -fsSI http://127.0.0.1/up
```

Откройте публичный URL, войдите под администратором и проверьте `/horizon`.

## 7. Частые проблемы

### 502 на `/api`

Проверьте:

```bash
docker compose ps
docker compose logs --tail=150 backend-etp nginx-etp gateway-etp
docker exec nginx-etp nginx -T 2>&1
test -f /opt/etp/backend/docker/nginx/config/conf.d/default.conf
```

Внутренний `nginx-etp` должен содержать `listen 80;` в `default.conf`. Если этот файл не пришёл в Git checkout backend, gateway вернёт 502.

### Release отклоняет frontend `.env.production`

Проверьте, что современный frontend содержит `/.env.production` в `.gitignore`. Для старого checkout добавьте локальное исключение, не добавляя файл в Git:

```bash
printf '/.env.production\n' >> /opt/etp/frontend/.git/info/exclude
```

## 8. Обновление

Сначала переключите deploy checkout на согласованный deploy SHA, затем остановите Compose и используйте `release.sh` с точными backend/frontend refs. Перед миграциями всегда указывайте `--apply-migrations --confirm --backup-dir /srv/etp-backups`. Не используйте `docker compose down -v` в обычном релизе: флаг `-v` удаляет volumes.
