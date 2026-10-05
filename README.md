# Production deploy (ЭТП)

Каталог для развёртывания на Ubuntu через Docker Compose.

Для production публикуйте содержимое этого каталога как отдельный Git-репозиторий инфраструктуры и клонируйте его в `/opt/etp/deploy` рядом с `/opt/etp/backend` и `/opt/etp/frontend`. Не вкладывайте его в backend/frontend: Compose использует sibling-пути.

| Путь | Назначение |
|------|------------|
| `docker-compose.yml` | Prod-стек (gateway + API + DB + Redis + Horizon + Reverb) |
| `.env.example` | Пароли Postgres, порты 80/443 |
| `nginx/` | Публичный gateway: HTTP/HTTPS vhost, сертификаты, snippets |
| `../backend/docker/nginx/` | Внутренний nginx → PHP-FPM; `conf.d/default.conf` обязан быть в backend Git-репозитории |
| `scripts/switch-tls.sh` | Быстрое переключение HTTP ↔ HTTPS |
| `scripts/bootstrap-app.sh` | migrate, cache, права storage |
| `env/` | Примеры `backend/src/.env` и `frontend/.env.production` |

Полная инструкция: [`docs/ubuntu.md`](docs/ubuntu.md).
