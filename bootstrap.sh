#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu bootstrap for Rails + Docker + Codex remote development
# Target: Ubuntu 22.04/24.04
# Usage:
#   curl -fsSL https://example.com/bootstrap.sh -o bootstrap.sh
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Optional env vars:
#   DEV_USER=deploy
#   INSTALL_ZSH=1
#   INSTALL_MISE=0
#   INSTALL_POSTGRES_CLIENT=1
#   INSTALL_REDIS_TOOLS=1

DEV_USER="${DEV_USER:-${SUDO_USER:-$USER}}"
INSTALL_ZSH="${INSTALL_ZSH:-1}"
INSTALL_MISE="${INSTALL_MISE:-0}"
INSTALL_POSTGRES_CLIENT="${INSTALL_POSTGRES_CLIENT:-1}"
INSTALL_REDIS_TOOLS="${INSTALL_REDIS_TOOLS:-1}"

export DEBIAN_FRONTEND=noninteractive

log() { printf "\n\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m==>\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m==>\033[0m %s\n" "$*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo: sudo ./bootstrap.sh"
    exit 1
  fi
}

ubuntu_codename() {
  . /etc/os-release
  echo "${VERSION_CODENAME}"
}

install_base_packages() {
  log "Installing base packages"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    gh \
    gnupg \
    lsb-release \
    software-properties-common \
    build-essential \
    pkg-config \
    make \
    jq \
    unzip \
    zip \
    xz-utils \
    tmux \
    htop \
    tree \
    ripgrep \
    fd-find \
    fzf \
    bat \
    vim \
    nano \
    rsync \
    openssh-client \
    openssh-server \
    ufw \
    fail2ban \
    bash-completion \
    imagemagick \
    libyaml-dev \
    libssl-dev \
    zlib1g-dev \
    libreadline-dev \
    libffi-dev \
    libgdbm-dev \
    libncurses5-dev \
    libdb-dev \
    uuid-dev \
    libxml2-dev \
    libxslt1-dev \
    libpq-dev \
    shared-mime-info \
    file \
    acl
}

install_docker() {
  log "Installing Docker Engine + Compose plugin"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(ubuntu_codename)"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

  apt-get update -y
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl restart docker

  if id -u "${DEV_USER}" >/dev/null 2>&1; then
    usermod -aG docker "${DEV_USER}" || true
  fi
}

install_node_lts() {
  log "Installing Node.js LTS"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
  npm install -g npm@latest
}

install_codex() {
  log "Installing Codex CLI"
  npm install -g @openai/codex
}

install_mise() {
  if [[ "${INSTALL_MISE}" != "1" ]]; then
    return
  fi

  log "Installing mise (optional tool version manager)"
  curl -fsSL https://mise.run | sh

  local user_home
  user_home="$(eval echo "~${DEV_USER}")"

  cat >>"${user_home}/.bashrc" <<'EOF'

# mise
if [ -f "$HOME/.local/bin/mise" ]; then
  eval "$("$HOME/.local/bin/mise" activate bash)"
fi
EOF

  if [[ -f "${user_home}/.zshrc" ]]; then
    cat >>"${user_home}/.zshrc" <<'EOF'

# mise
if [ -f "$HOME/.local/bin/mise" ]; then
  eval "$("$HOME/.local/bin/mise" activate zsh)"
fi
EOF
  fi

  chown "${DEV_USER}:${DEV_USER}" "${user_home}/.bashrc" || true
  [[ -f "${user_home}/.zshrc" ]] && chown "${DEV_USER}:${DEV_USER}" "${user_home}/.zshrc" || true
}

install_optional_clients() {
  if [[ "${INSTALL_POSTGRES_CLIENT}" == "1" ]]; then
    log "Installing PostgreSQL client"
    apt-get install -y postgresql-client
  fi

  if [[ "${INSTALL_REDIS_TOOLS}" == "1" ]]; then
    log "Installing Redis tools"
    apt-get install -y redis-tools
  fi
}

configure_user_shell() {
  local user_home
  user_home="$(eval echo "~${DEV_USER}")"

  log "Configuring shell for ${DEV_USER}"

  touch "${user_home}/.bashrc"
  grep -q 'alias dc=' "${user_home}/.bashrc" || cat >>"${user_home}/.bashrc" <<'EOF'

# quality of life
alias ll='ls -lah'
alias dc='docker compose'
alias dps='docker ps'
alias dcu='docker compose up'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias cdx='codex'
export EDITOR=vim
EOF

  if [[ "${INSTALL_ZSH}" == "1" ]]; then
    apt-get install -y zsh
    chsh -s /usr/bin/zsh "${DEV_USER}" || true
    touch "${user_home}/.zshrc"
    grep -q 'alias dc=' "${user_home}/.zshrc" || cat >>"${user_home}/.zshrc" <<'EOF'

# quality of life
alias ll='ls -lah'
alias dc='docker compose'
alias dps='docker ps'
alias dcu='docker compose up'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias cdx='codex'
export EDITOR=vim
autoload -U compinit && compinit
EOF
  fi

  chown "${DEV_USER}:${DEV_USER}" "${user_home}/.bashrc" || true
  [[ -f "${user_home}/.zshrc" ]] && chown "${DEV_USER}:${DEV_USER}" "${user_home}/.zshrc" || true
}

configure_tmux() {
  local user_home
  user_home="$(eval echo "~${DEV_USER}")"

  log "Configuring tmux"
  cat >"${user_home}/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 100000
setw -g mode-keys vi
set -g base-index 1
setw -g pane-base-index 1
bind r source-file ~/.tmux.conf \; display-message "tmux reloaded"
EOF

  chown "${DEV_USER}:${DEV_USER}" "${user_home}/.tmux.conf" || true
}

configure_ssh_and_firewall() {
  log "Configuring SSH and firewall"

  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  grep -q '^ClientAliveInterval' /etc/ssh/sshd_config || echo 'ClientAliveInterval 60' >> /etc/ssh/sshd_config
  grep -q '^ClientAliveCountMax' /etc/ssh/sshd_config || echo 'ClientAliveCountMax 3' >> /etc/ssh/sshd_config

  systemctl enable ssh
  systemctl restart ssh

  ufw allow OpenSSH
  ufw --force enable

  systemctl enable fail2ban
  systemctl restart fail2ban
}

prepare_workspace() {
  local user_home
  user_home="$(eval echo "~${DEV_USER}")"

  log "Preparing workspace"
  install -d -m 0755 -o "${DEV_USER}" -g "${DEV_USER}" "${user_home}/workspace"
  install -d -m 0755 -o "${DEV_USER}" -g "${DEV_USER}" "${user_home}/bin"
  install -d -m 0755 -o "${DEV_USER}" -g "${DEV_USER}" "${user_home}/.config"

  cat >"${user_home}/workspace/README-DEV-SETUP.txt" <<'EOF'
Suggested next steps:
1. git clone your repository into ~/workspace
2. create docker-compose.yml / compose.yaml if not already present
3. start services:
   docker compose up -d
4. verify:
   docker compose ps
5. install/auth Codex if needed:
   codex
EOF

  chown "${DEV_USER}:${DEV_USER}" "${user_home}/workspace/README-DEV-SETUP.txt" || true
}

print_versions() {
  log "Installed versions"
  echo "User: ${DEV_USER}"
  echo "Docker: $(docker --version || true)"
  echo "Compose: $(docker compose version || true)"
  echo "Node: $(node --version || true)"
  echo "npm: $(npm --version || true)"
  echo "Codex: $(codex --version || true)"
  echo "Git: $(git --version || true)"
  echo "gh: $(gh --version | head -n1 || true)"
}

print_next_steps() {
  cat <<EOF

Done.

Next steps as ${DEV_USER}:
  newgrp docker
  cd ~/workspace
  git clone <your_repo.git>
  cd <repo>

Check Docker access:
  docker ps

Login to Codex:
  codex
  # or:
  # codex login

Optional:
  gh auth login

Recommended for Rails repo:
  - keep app/runtime inside Docker
  - commit an AGENTS.md with common commands like:
      bin/dev
      docker compose up -d
      docker compose exec web bin/rails test
      docker compose exec web bundle exec rubocop

If you use Codex app remote connections later, make sure:
  - ssh to this host works
  - codex is on PATH for the remote shell
EOF
}

install_amnezia_wg() {
  sudo apt update
  sudo apt install -y software-properties-common curl ca-certificates gnupg lsb-release linux-headers-$(uname -r)
  sudo add-apt-repository -y ppa:amnezia/ppa
  sudo apt update
  sudo apt install -y amneziawg amneziawg-tools
  sudo mkdir -p /etc/amnezia/amneziawg
  sudo systemctl enable awg-quick@awg0
  echo "Place your Amnezia config to /etc/amnezia/amneziawg/awg0.conf"
}

main() {
  require_root
  install_base_packages
  install_docker
  install_node_lts
  install_codex
  install_optional_clients
  configure_user_shell
  configure_tmux
  configure_ssh_and_firewall
  prepare_workspace
  install_mise
  install_amnezia_wg
  print_versions
  print_next_steps
}

echo "Run this script on remote server only. Don't run this on your PC"
echo "Press Ctrl-C to exit or Enter to continue"
read

main "$@"
