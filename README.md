# Remote Rails + Docker + Codex on VM

Этот набор файлов нужен для простого сценария:

- у тебя есть Linux VM
- на ней один раз выполняется `bootstrap.sh`
- рабочее окружение живёт на VM
- локально на Mac ты подключаешься через VS Code Remote-SSH и/или Codex app Remote connections
- VM можно запускать и останавливать через `serveroid_vm.py`, не заходя в UI

---

## Что уже есть

У тебя уже сохранены:

- `bootstrap.sh` — первичная настройка VM
- `serveroid_vm.py` — маленький Python CLI для запуска/остановки VM через API Serveroid

В этом комплекте ниже:

- `README.md` — инструкция
- `requirements.txt` — Python-зависимости для `serveroid_vm.py`
- `.env.example` — шаблон переменных окружения для Serveroid API
- `Makefile` — удобные команды-ярлыки
- `.gitignore` — чтобы не коммитить секреты

---

## 1. Что где происходит

### На VM

На сервере выполняются:

- Docker / Docker Compose
- код проекта
- Rails app
- PostgreSQL / Redis / Sidekiq / другие сервисы в контейнерах
- Codex CLI

### На локальном Mac

Локально используются:

- VS Code + Remote-SSH
- Dev Containers, если проект использует `.devcontainer`
- Codex app с remote connections
- `serveroid_vm.py` для запуска/остановки VM

Идея простая: **всё тяжёлое крутится на VM, а ноутбук — только клиент**.

---

## 2. Быстрый запуск с нуля

### Шаг 1. Подготовить VM

Скопируй `bootstrap.sh` на сервер и запусти:

```bash
sudo bash bootstrap.sh
```

После этого проверь на VM:

```bash
codex --version
docker --version
docker compose version
node --version
git --version
```

Если это работает — хост готов.

---

### Шаг 2. Настроить доступ к Serveroid API

Создай файл `.env` рядом с `serveroid_vm.py` на основе `.env.example`.

Минимально нужны:

```env
SERVEROID_CLIENT_ID=...
SERVEROID_API_KEY=...
SERVEROID_TENANT_ID=...
SERVEROID_VM_ID=...
```

Если `VM_ID` не знаешь, можно сначала получить список VM.

---

### Шаг 3. Установить локально Python-зависимости

Рекомендуется отдельное виртуальное окружение:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

### Шаг 4. Проверить работу управления VM

```bash
python serveroid_vm.py list
python serveroid_vm.py info
python serveroid_vm.py status
```

Запуск:

```bash
python serveroid_vm.py start
```

Остановка:

```bash
python serveroid_vm.py stop
```

Жёсткое выключение:

```bash
python serveroid_vm.py poweroff
```

---

## 3. Повседневный цикл работы

Утром / перед началом работы:

```bash
python serveroid_vm.py start
```

Потом подключаешься к серверу как тебе удобно:

- VS Code Remote-SSH
- Codex app Remote connections
- обычный SSH / terminal workflow

В конце дня:

```bash
python serveroid_vm.py stop
```

Если VM зависла или не отвечает на мягкое выключение:

```bash
python serveroid_vm.py poweroff
```

---

## 4. VS Code: как открыть проект на сервере

На Mac в VS Code поставь расширения:

- Remote - SSH
- Dev Containers
- Codex

Дальше:

1. `Cmd+Shift+P`
2. `Remote-SSH: Connect to Host...`
3. выбери свой хост
4. открой папку проекта на сервере, например:

```text
/home/YOUR_USER/workspace/myapp
```

Если проект использует devcontainer:

1. подключись по Remote-SSH
2. открой папку проекта на сервере
3. выполни `Dev Containers: Reopen in Container`

Так VS Code будет работать **не локально**, а против окружения на удалённой VM.

---

## 5. Codex app: как направить его на сервер

Схема такая:

1. на VM должен работать `codex`
2. в Codex app открываешь `Settings -> Connections`
3. добавляешь SSH-host
4. выбираешь папку проекта на сервере

После этого Codex app будет читать файлы и выполнять команды на VM.

Если remote connections ещё не видны, можно добавить в `~/.codex/config.toml`:

```toml
remote_control = true
```

---

## 6. Рекомендуемая структура проекта на VM

Например:

```text
/home/YOUR_USER/workspace/
  myapp/
    Dockerfile.dev
    compose.yaml
    .devcontainer/
    AGENTS.md
```

---

## 7. Что добавить в репозиторий проекта

Для удобной работы советую добавить в проект:

- `compose.yaml`
- `Dockerfile.dev`
- `.devcontainer/devcontainer.json`
- `AGENTS.md`
- `Makefile`

### Пример `AGENTS.md`

```md
# AGENTS.md

## Common commands

- Start app: `docker compose up -d`
- App logs: `docker compose logs -f web`
- Rails console: `docker compose exec web bin/rails console`
- Run tests: `docker compose exec web bin/rails test`
- Rubocop: `docker compose exec web bundle exec rubocop`
- Migrate DB: `docker compose exec web bin/rails db:migrate`
```

Это полезно и тебе, и Codex.

---

## 8. Локальный SSH config

На Mac удобно завести запись в `~/.ssh/config`:

```sshconfig
Host rails-vm
  HostName YOUR_SERVER_IP_OR_DNS
  User YOUR_USER
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 30
  ServerAliveCountMax 3
  TCPKeepAlive yes
```

После этого обычное подключение выглядит так:

```bash
ssh rails-vm
```

---

## 9. Makefile shortcuts

Если используешь приложенный `Makefile`, команды будут такие:

```bash
make install
make list
make info
make status
make start
make stop
make poweroff
```

---

## 10. Что хранить в `.env`

Пример:

```env
SERVEROID_CLIENT_ID=your_client_id
SERVEROID_API_KEY=your_api_key
SERVEROID_TENANT_ID=12345
SERVEROID_VM_ID=67890
```

Если хочешь выбирать VM по имени:

```env
SERVEROID_VM_NAME=dev-rails
```

Но надёжнее использовать именно `VM_ID`.

---

## 11. Безопасность

Не коммить:

- `.env`
- API key
- `~/.codex/auth.json`
- приватные SSH-ключи

Если используешь git в этой папке, `.gitignore` из комплекта это уже прикрывает.

---

## 12. Частые команды

```bash
# Поднять VM
python serveroid_vm.py start

# Проверить состояние
python serveroid_vm.py status

# Посмотреть список VM
python serveroid_vm.py list

# Получить подробности по текущей VM
python serveroid_vm.py info

# Остановить VM мягко
python serveroid_vm.py stop

# Жёстко выключить
python serveroid_vm.py poweroff
```

Если используешь `Makefile`:

```bash
make start
make status
make stop
```

---

## 13. Рекомендуемый минимальный workflow

1. `make start`
2. открываешь VS Code через Remote-SSH
3. работаешь в проекте на VM
4. при необходимости используешь Codex app Remote connections
5. вечером `make stop`

---

## 14. Troubleshooting

### `Serveroid error: SERVEROID_CLIENT_ID and SERVEROID_API_KEY are required`

Не подгрузился `.env` или переменные не экспортированы.

Решение:

- проверь файл `.env`
- либо экспортируй переменные вручную

### `VM with name ... not found`

Имя VM не совпадает с именем в панели.

Решение:

- сначала выполни `python serveroid_vm.py list`
- лучше используй `SERVEROID_VM_ID`

### `codex --version` не работает на сервере

Значит `bootstrap.sh` не завершил установку или `codex` не попал в `PATH`.

### VS Code открыл локальную папку вместо удалённой

Ты открыл обычное окно VS Code, а не Remote-SSH-сессию.

Решение:

- заново открой VS Code
- `Remote-SSH: Connect to Host...`
- потом уже `Open Folder...` на сервере

---

## 15. Что можно улучшить потом

Дальше можно спокойно дорастить систему:

- добавить `.env`-подгрузку прямо в `serveroid_vm.py`
- завернуть CLI в пакет с `pyproject.toml`
- сделать команду `workon`, которая автоматически запускает VM
- добавить уведомления в Telegram/Slack
- добавить `compose.yaml` и `.devcontainer` шаблоны под Rails

---

## 16. Минимальный набор файлов рядом со скриптами

```text
bootstrap.sh
serveroid_vm.py
README.md
requirements.txt
.env.example
.gitignore
Makefile
```

Этого достаточно, чтобы:

- один раз поднять и подготовить VM
- потом запускать и останавливать её одной командой
- работать на ней из VS Code и Codex app

