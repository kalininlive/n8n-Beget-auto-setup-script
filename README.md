# n8n Beget Auto-Setup

Скрипт автоматической настройки n8n на серверах **Beget** (Cloud/VPS). Превращает чистовую установку n8n из панели Beget в полноценную production-среду с ffmpeg, python3, yt-dlp, docker-in-docker и другими инструментами.

## Что делает скрипт

| Компонент | Описание |
|-----------|----------|
| **SWAP 4GB** | Автоматическая настройка swap-файла, без него ffmpeg убивается OOM killer |
| **Dockerfile.n8n** | Кастомный образ с ffmpeg, python3, yt-dlp, fontconfig, locales, git |
| **Shim-скрипты** | Прокладки для ffmpeg, python, python3, fc-scan, yt-dlp |
| **Docker-in-Docker** | Доступ к docker.sock и docker CLI из контейнера n8n |
| **Увеличенные лимиты** | Payload 512MB, FormData 2048MB, таймауты до 4 часов |
| **Community packages** | Включены, NODES_EXCLUDE=[] |
| **Queue mode** | Redis для очереди задач |
| **n8n-tools** | Контейнер с утилитами (опционально) |
| **Telegram-бот** | Управление n8n через Telegram (опционально) |
| **Backup/Update** | Готовые скрипты бэкапа и обновления |

## Быстрый старт

### 1. Установите n8n через панель Beget
Стандартная установка через Beget Panel → Приложения → n8n.

### 2. Запустите скрипт
```bash
# Подключитесь к серверу по SSH
ssh root@your-server

# Запуск одной командой
curl -fsSL https://raw.githubusercontent.com/kalininlive/n8n-beget-setup/main/setup.sh | bash
```

### 3. Или с параметрами
```bash
# Скачать и запустить с опциями
curl -fsSL https://raw.githubusercontent.com/kalininlive/n8n-beget-setup/main/setup.sh -o /tmp/setup.sh
bash /tmp/setup.sh --no-bot --timezone Asia/Yekaterinburg
```

## Параметры

| Параметр | Описание |
|----------|----------|
| `--no-bot` | Не устанавливать Telegram-бота |
| `--no-tools` | Не создавать контейнер n8n-tools |
| `--no-proxy` | Не добавлять переменные прокси |
| `--timezone ZONE` | Установить таймзону (по умолчанию из .env) |
| `--domain DOMAIN` | Переопределить домен |
| `--dry-run` | Показать что будет сделано без изменений |

## Что получается после установки

```
/opt/beget/n8n/
├── docker-compose.yml     # Модифицированный compose
├── Dockerfile.n8n         # Кастомный образ n8n
├── Dockerfile.tools       # Образ n8n-tools
├── .env                   # Переменные окружения (дополненные)
├── healthcheck.js         # Healthcheck для n8n
├── init-data.sh           # Инициализация PostgreSQL
├── backup_n8n.sh          # Скрипт бэкапа
├── update_n8n.sh          # Скрипт обновления
├── shims/                 # Shim-скрипты
│   ├── ffmpeg
│   ├── fc-scan
│   ├── python
│   ├── python3
│   └── yt-dlp
├── data/                  # Рабочие файлы n8n (/data в контейнере)
├── bot/                   # Telegram-бот (опционально)
│   ├── Dockerfile
│   ├── package.json
│   └── bot.js
├── backups/               # Бэкапы
│   └── pre-setup-*/       # Бэкап оригинальных файлов Beget
└── logs/                  # Логи
```

## Контейнеры

| Контейнер | Описание |
|-----------|----------|
| `n8n-app` | Основной n8n (кастомный образ) |
| `n8n-worker` | Worker для очереди задач |
| `n8n-postgres` | PostgreSQL 16 |
| `n8n-redis` | Redis 7 |
| `n8n-traefik` | Traefik 3.x (SSL) |
| `n8n-tools` | Утилиты (docker, git, curl) |
| `n8n-bot` | Telegram-бот |

## Настройка прокси

Если нужен HTTP-прокси (например, для Instagram API), добавьте в `.env`:

```env
PROXY_URL=http://user:password@proxy-host:port
NO_PROXY=localhost,127.0.0.1,postgres,redis,n8n,n8n-worker
```

Затем перезапустите:
```bash
cd /opt/beget/n8n && docker compose up -d
```

## Настройка Telegram-бота

1. Создайте бота через [@BotFather](https://t.me/BotFather)
2. Получите свой Telegram User ID через [@userinfobot](https://t.me/userinfobot)
3. Добавьте в `.env`:
```env
TG_BOT_TOKEN=123456:ABC-DEF...
TG_USER_ID=12345678
```
4. Перезапустите бота:
```bash
docker compose restart n8n-bot
```

### Команды бота
- `/start` — Список команд
- `/status` — Статус сервера и контейнеров
- `/logs` — Последние 100 строк логов n8n (отправляет файл если лог большой)
- `/backups` — Создать бэкап
- `/update` — Обновить n8n (сначала делает бэкап)

## Полезные команды

```bash
cd /opt/beget/n8n

# Статус
docker compose ps

# Логи n8n
docker compose logs -f n8n

# Проверка инструментов внутри контейнера
docker exec n8n-app ffmpeg -version
docker exec n8n-app python3 --version
docker exec n8n-app yt-dlp --version
docker exec n8n-app ffmpeg -filters | grep drawtext

# Бэкап
bash backup_n8n.sh

# Обновление n8n
bash update_n8n.sh

# Перестроить образы
docker compose build --no-cache n8n n8n-worker
docker compose up -d
```

## Откат к оригинальной конфигурации

Бэкап оригинальных файлов Beget сохраняется автоматически:

```bash
# Найти бэкап
ls /opt/beget/n8n/backups/pre-setup-*/

# Восстановить
cd /opt/beget/n8n
docker compose down
cp backups/pre-setup-*/docker-compose.yml .
cp backups/pre-setup-*/.env .
docker compose up -d
```

## SWAP (критически важно!)

Скрипт автоматически создаёт 4GB swap-файл. Без него ffmpeg **будет убиваться** OOM-killer на серверах с малым объёмом RAM (1-2GB). Скрипт также оптимизирует `vm.swappiness=10`.

Если SWAP уже существует — шаг пропускается.

```bash
# Проверка SWAP
free -h
swapon --show
```

## Совместимость

- **Beget Cloud/VPS** — Ubuntu 24.04+
- **Docker** — 28.x+
- **n8n** — 2.x (from Beget panel)

## Лицензия

MIT
