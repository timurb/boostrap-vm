# Remote Rails + Docker + Codex on VM

Этот набор файлов нужен для простого provider-agnostic сценария:

- у тебя есть Ubuntu/Linux VM
- VM запускается вручную через web UI хостинга
- на VM один раз выполняется `bootstrap.sh`
- рабочее окружение живет на VM
- локально на Mac ты подключаешься через VS Code Remote-SSH и/или Codex app Remote connections
- сама VM может автоматически выключаться после простоя локальными средствами Linux

Здесь нет привязки к API конкретного хостинга. Если позже VM переедет к другому провайдеру, workflow останется тем же.

---

## Что есть в репозитории

- `bootstrap.sh` - первичная настройка Ubuntu VM для Rails/Docker/Codex remote development
- `vm_auto_poweroff.sh` - проверка активности и локальное выключение VM после простоя
- `install_vm_auto_poweroff.sh` - установка авто-выключателя как systemd timer
- `vm-auto-poweroff.service` и `vm-auto-poweroff.timer` - systemd units для регулярной проверки
- `README.md` - инструкция
- `.gitignore` - локальные секреты и временные файлы

---

## 1. Что где происходит

### На VM

На сервере выполняются:

- Docker / Docker Compose
- код проекта
- Rails app
- PostgreSQL / Redis / Sidekiq / другие сервисы в контейнерах
- Codex CLI
- `vm-auto-poweroff` timer, который выключает VM после простоя

### На локальном Mac

Локально используются:

- web UI хостинга для запуска VM
- VS Code + Remote-SSH
- Dev Containers, если проект использует `.devcontainer`
- Codex app с remote connections
- обычный SSH / terminal workflow при необходимости

Идея простая: **все тяжелое крутится на VM, а ноутбук - только клиент**.

---

## 2. Быстрый запуск с нуля

### Шаг 1. Запустить VM

Открой web UI хостинга и запусти VM вручную.

### Шаг 2. Подготовить VM

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

Если это работает - хост готов.

### Шаг 3. Установить авто-выключение

Скопируй файлы авто-выключателя на VM и выполни из папки репозитория:

```bash
sudo ./install_vm_auto_poweroff.sh
```

Installer:

- копирует `vm_auto_poweroff.sh` в `/usr/local/sbin/vm-auto-poweroff`
- создает `/etc/default/vm-auto-poweroff`
- устанавливает `vm-auto-poweroff.service`
- включает `vm-auto-poweroff.timer`

По умолчанию VM выключается после 30 минут без активности. Проверка запускается каждые 5 минут.

---

## 3. Повседневный цикл работы

1. Запусти VM через web UI хостинга.
2. Подключись к серверу через VS Code Remote-SSH, Codex app remote connection или обычный SSH.
3. Работай в проекте на VM.
4. Когда закончишь, просто отключись от VM.
5. Через 30 минут без активности VM выполнит локальный `systemctl poweroff`.

Авто-выключение не использует API хостинга. Оно работает изнутри VM и выключает ОС штатной Linux-командой.

---

## 4. Как авто-выключатель понимает активность

VM считается занятой, если есть хотя бы один из сигналов:

- личная интерактивная SSH login-сессия, у которой TTY idle меньше `SSH_SESSION_IDLE_MINUTES`
- CPU VM выше `CPU_BUSY_PERCENT`
- суммарная Docker CPU-нагрузка выше `DOCKER_BUSY_PERCENT`
- найден активный build/package/process из `BUSY_PROCESS_REGEX`

Перед проверкой `BUSY_PROCESS_REGEX` скрипт отбрасывает процессы из `IGNORED_PROCESS_REGEX`.
По умолчанию туда входят `codex app-server` и Ruby LSP процессы вроде `ruby-lsp-rails`, потому что после закрытия Codex app или VS Code они могут оставаться фоновыми bridge/LSP-процессами и сами по себе не означают активную работу.

Raw SSH-сокеты не считаются активностью. Это важно для Mac: macOS может оставлять TCP-сессию SSH established во сне.

### Эксперимент: VS Code workspace lock

Пробовали считать активностью свежий lock-файл VS Code Remote-SSH:

```text
~/.vscode-server/data/User/workspaceStorage/*/vscode.lock
```

На практике этот сигнал не сработал надежно: lock продолжал обновляться, хотя пользовательской активности уже не было или Mac предположительно уходил в сон. Поэтому проверка `vscode.lock` убрана из скрипта. VS Code сам по себе не считается activity-сигналом; VM держат только SSH TTY idle, CPU/Docker-нагрузка и явно busy-процессы.

Если VM занята, скрипт обновляет timestamp в:

```text
/var/lib/vm-auto-poweroff/last_busy
```

Если VM не занята, скрипт сравнивает текущее время с этим timestamp. После `IDLE_MINUTES` минут простоя он выполняет:

```bash
systemctl poweroff
```

---

## 5. Настройки авто-выключения

Основные настройки живут в:

```text
/etc/default/vm-auto-poweroff
```

Значения по умолчанию:

```bash
IDLE_MINUTES=30
SSH_SESSION_IDLE_MINUTES=30
CHECK_INTERVAL_SECONDS=300
DRY_RUN=0
CPU_BUSY_PERCENT=20
DOCKER_BUSY_PERCENT=5
# Unset by default in /etc/default; script default ignores codex app-server and Ruby LSP.
# IGNORED_PROCESS_REGEX='(^|[[:space:]/])codex[[:space:]]+app-server([[:space:]]|$)|ruby[-_]lsp|ruby_lsp_rails|ruby-lsp-rails'
```

Если поменяешь `CHECK_INTERVAL_SECONDS`, заново выполни:

```bash
sudo ./install_vm_auto_poweroff.sh
```

Так installer пересоздаст timer с новым интервалом.

Если хочешь проверить поведение без выключения VM:

```bash
DRY_RUN=1 /usr/local/sbin/vm-auto-poweroff
```

В dry-run режиме скрипт пишет, что он сделал бы, но не вызывает `systemctl poweroff`.

---

## 6. Управление systemd timer

Проверить статус:

```bash
systemctl status vm-auto-poweroff.timer
```

Посмотреть последние проверки:

```bash
journalctl -u vm-auto-poweroff.service -n 100 --no-pager
```

Запустить проверку вручную:

```bash
sudo systemctl start vm-auto-poweroff.service
```

Отключить авто-выключение:

```bash
sudo systemctl disable --now vm-auto-poweroff.timer
```

---

## 7. VS Code: как открыть проект на сервере

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

Так VS Code будет работать не локально, а против окружения на удаленной VM.

---

## 8. Codex app: как направить его на сервер

Схема такая:

1. на VM должен работать `codex`
2. в Codex app открой `Settings -> Connections`
3. добавь SSH-host
4. выбери папку проекта на сервере

После этого Codex app будет читать файлы и выполнять команды на VM.

Если remote connections еще не видны, можно добавить в `~/.codex/config.toml`:

```toml
remote_control = true
```

---

## 9. Рекомендуемая структура проекта на VM

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

## 10. Что добавить в репозиторий Rails-проекта

Для удобной работы советую добавить в сам Rails-проект:

- `compose.yaml`
- `Dockerfile.dev`
- `.devcontainer/devcontainer.json`
- `AGENTS.md`
- `Makefile` с командами приложения, если он нужен именно проекту

Пример `AGENTS.md`:

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

## 11. Локальный SSH config

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

## 12. Безопасность

Не коммить:

- приватные SSH-ключи
- `~/.codex/auth.json`
- токены и credentials проектов
- локальные `.env` файлы приложений

---

## 13. Troubleshooting

### VM не выключается

Проверь, что timer включен:

```bash
systemctl status vm-auto-poweroff.timer
```

Посмотри причину последнего решения:

```bash
journalctl -u vm-auto-poweroff.service -n 100 --no-pager
```

Чаще всего VM не выключается, потому что есть свежая SSH login-сессия, высокая CPU/Docker-нагрузка или процесс из `BUSY_PROCESS_REGEX`.
`codex app-server` и `ruby-lsp-rails` по умолчанию игнорируются; если они все равно появляются в причине, проверь кастомный `IGNORED_PROCESS_REGEX` в `/etc/default/vm-auto-poweroff`.

### Нужно проверить без риска выключения

```bash
DRY_RUN=1 /usr/local/sbin/vm-auto-poweroff
```

### `codex --version` не работает на сервере

Значит `bootstrap.sh` не завершил установку или `codex` не попал в `PATH`.

### VS Code открыл локальную папку вместо удаленной

Ты открыл обычное окно VS Code, а не Remote-SSH-сессию.

Решение:

- заново открой VS Code
- `Remote-SSH: Connect to Host...`
- потом уже `Open Folder...` на сервере

---

## 14. Минимальный набор файлов

```text
bootstrap.sh
install_vm_auto_poweroff.sh
vm_auto_poweroff.sh
vm-auto-poweroff.service
vm-auto-poweroff.timer
README.md
.gitignore
```

Этого достаточно, чтобы:

- один раз подготовить Ubuntu VM
- запускать VM вручную через web UI любого хостинга
- работать на ней из VS Code и Codex app
- автоматически выключать ее после простоя без provider-specific API
