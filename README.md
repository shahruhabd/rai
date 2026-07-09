# RAI Project

R/Shiny-приложение **ares** (PD-модель / скоринг на `randomForest`) плюс вспомогательный Flask-сервис **auth** (LDAP-логин и дашборд аналитики посещений).

## Что это за приложение

- **ares-ai** — основное приложение на R/Shiny (`backend/app.R`), использует обученную модель `backend/rf_pd_model.rds` (случайный лес для расчёта вероятности дефолта/PD). Работает через `shiny-server` внутри контейнера `rocker/shiny-verse`.
- **auth** — отдельный Flask-сервис:
  - `/login`, `/logout` — вход через LDAP (Active Directory) с дополнительной проверкой подразделения через внешнюю IDM-систему;
  - `/analytics` — дашборд с историей входов/выходов пользователей (сейчас доступен **без авторизации**);
  - `/sync-user/` — служебный endpoint для гранта/отзыва доступа по `employee_id`;
  - `/auth`, `/whoami` — health-check и данные текущей сессии.

  > На данный момент LDAP/IDM переменные окружения не заданы в `docker-compose.yml`, поэтому реальный вход через `/login` работать не будет (форма открывается, но проверка логина/пароля упадёт). Страница `/analytics` открыта для всех.

## Запуск через Docker

Требования: Docker Desktop (Windows/Mac/Linux), 4+ GB свободной памяти.

```bash
cd docker-rai
docker compose up -d --build
```

После старта:

| Сервис  | Адрес                          | Назначение                     |
|---------|---------------------------------|---------------------------------|
| ares-ai | http://localhost:8045/ares/     | Shiny-приложение (основной UI) |
| auth    | http://localhost:5000/analytics | Дашборд аналитики посещений     |
| auth    | http://localhost:5000/login     | Форма входа (LDAP не настроен)  |

Остановить:

```bash
docker compose down
```

Пересобрать один сервис после правок кода:

```bash
docker compose up -d --build auth       # или ares-ai
```

### Настройка LDAP/IDM (если нужен рабочий логин)

Добавьте в `environment:` сервиса `auth` в `docker-compose.yml` (или через `env_file: .env`):

```
LDAP_SERVER_URI=ldap(s)://...
LDAP_BIND_DN=...
LDAP_BIND_PASSWORD=...
LDAP_SEARCH_BASE=...
IDM_BASE=...
IDM_USER=...
IDM_PASS=...
```

`docker-rai/.env` уже содержит `IDM_*` значения, но они не подключены к контейнеру — их нужно явно прописать в `environment` или добавить `env_file: .env` в `docker-compose.yml`. Файл `.env` содержит реальные пароли и **не должен коммититься в git** (уже добавлен в `.gitignore`).

## Структура проекта

```
rai-project/
├── backend/                     # R/Shiny-приложение "ares"
│   ├── app.R                    # основной код приложения
│   └── rf_pd_model.rds          # обученная модель (randomForest)
│
└── docker-rai/
    ├── docker-compose.yml       # сервисы ares-ai + auth
    ├── Dockerfile                # образ ares-ai (rocker/shiny-verse)
    ├── .env                      # секреты IDM (не в git)
    │
    ├── auth/                    # Flask-сервис авторизации/аналитики
    │   ├── app.py                # LDAP-логин, IDM-проверка, аналитика
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   ├── usiag.crt              # корпоративный CA-сертификат (для pip/requests)
    │   ├── data/                  # SQLite БД (users.db, r_ai.db) — не в git
    │   └── templates/             # login.html, analytics.html
    │
    └── nginx/
        └── conf.d/r-ai.conf       # опциональный reverse-proxy конфиг (не используется в compose)
```

## Примечания

- `nginx/conf.d/r-ai.conf` не подключён к `docker-compose.yml` — используйте его, только если разворачиваете отдельный Nginx перед контейнерами (например, для HTTPS и домена `r-ai.finreg.kz`).
- База `auth/data/r_ai.db` создаётся автоматически при первом старте `auth`-контейнера; бэкап `r_ai.db.bak` не удалён, но исключён из git.
