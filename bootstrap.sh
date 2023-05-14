#!/bin/bash -uxe

# 清空缓冲区/防止接收到期望外的输入
read -N 999999 -t 0.001

# 语句执行出错立即退出
set -e

# 目标VPS为ubuntu系统
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
  if [[ "$os_version" -lt 2004 ]]; then
      echo "Ubuntu 20.04 or higher is required to use this installer."
      echo "This version of Ubuntu is too old and unsupported."
      exit
    fi
fi

check_root() {
# 检测root用户
if [[ $EUID -ne 0 ]]; then
  if [[ ! -z "$1" ]]; then
    SUDO='sudo -E -H'
  else
    SUDO='sudo -E'
  fi
else
  SUDO=''
fi
}

install_dependencies_ubuntu() {
  REQUIRED_PACKAGES=(
    sudo
    software-properties-common
    dnsutils
    curl
    git
    locales
    rsync
    apparmor
    python3
    python3-setuptools
    python3-apt
    python3-venv
    python3-pip
    aptitude
    direnv
  )

  REQUIRED_PACKAGES_ARM64=(
    gcc
    python3-dev
    libffi-dev
    libssl-dev
    make
  )

  check_root
  # 禁用交互式apt
  export UBUNTU_FRONTEND=noninteractive
  # 更新apt，更新所有包并安装Ansible和依赖项
  $SUDO apt update -y;
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy dist-upgrade;
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy install "${REQUIRED_PACKAGES[@]}"
  yes | $SUDO apt-get -o Dpkg::Options::="--force-confold" -fuy autoremove;
  [ $(uname -m) == "aarch64" ] && yes | $SUDO apt install -fuy "${REQUIRED_PACKAGES_ARM64[@]}"
  export UBUNTU_FRONTEND=
}

# 安装依赖项
if [ "$os" == "ubuntu" ]; then
  install_dependencies_ubuntu
fi

# 克隆playbook
if [ -d "$HOME/Jerry-vpn" ]; then
  pushd $HOME/Jerry-vpn
  git pull
  popd
else
  git clone https://github.com/JerryAllthetime/Jerry-vpn $HOME/Jerry-vpn
fi

# 安装python环境
set +e
if which python3.9; then
  PYTHON=$(which python3.9)
else
  PYTHON=$(which python3)
fi
set -e
cd $HOME/Jerry-vpn
[ -d $HOME/Jerry-vpn/.venv ] || $PYTHON -m venv .venv
export VIRTUAL_ENV="$HOME/Jerry-vpn/.venv"
export PATH="$HOME/Jerry-vpn/.venv/bin:$PATH"
.venv/bin/python3 -m pip install --upgrade pip
.venv/bin/python3 -m pip install -r requirements.txt

# galaxy依赖
cd $HOME/ansible-easy-vpn && ansible-galaxy install --force -r galaxy_requirements.yml

# 创建新用户
clear
echo "Welcome to Jerry-vpn!"
echo "Enter your desired UNIX username"
read -p "Username: " username
until [[ "$username" =~ ^[a-z0-9]*$ ]]; do
  echo "Invalid username"
  echo "Make sure the username only contains lowercase letters and numbers"
  read -p "Username: " username
done

echo
echo "Enter your user password"
echo "This password will be used for Authelia login, administrative access and SSH login"
read -s -p "Password: " user_password
until [[ "${#user_password}" -lt 60 ]]; do
  echo
  echo "The password is too long"
  echo "OpenSSH does not support passwords longer than 72 characters"
  read -s -p "Password: " user_password
done
echo
read -s -p "Repeat password: " user_password2
echo
until [[ "$user_password" == "$user_password2" ]]; do
  echo
  echo "The passwords don't match"
  read -s -p "Password: " user_password
  echo
  read -s -p "Repeat password: " user_password2
done

# 输入域名
echo
echo
echo "Enter your domain name"
echo "The domain name should already resolve to the IP address of your server"
echo
read -p "Domain name: " root_host
until [[ "$root_host" =~ ^[a-z0-9\.\-]*$ ]]; do
  echo "Invalid domain name"
  read -p "Domain name: " root_host
done

# 获取主机IP和键入域的IP
public_ip=$(curl -s https://api.ipify.org)
domain_ip=$(dig +short @1.1.1.1 ${root_host})

# 确保键入域解析到主机IP
until [[ $domain_ip =~ $public_ip ]]; do
  echo
  echo "The domain $root_host does not resolve to the public IP of this server ($public_ip)"
  echo
  root_host_prev=$root_host
  read -p "Domain name [$root_host_prev]: " root_host
  if [ -z ${root_host} ]; then
    root_host=$root_host_prev
  fi
  public_ip=$(curl -s ipinfo.io/ip)
  domain_ip=$(dig +short @1.1.1.1 ${root_host})
  echo
done

# 为Vault文件设置权限
touch $HOME/Jerry-vpn/secret.yml
chmod 600 $HOME/Jerry-vpn/secret.yml

echo "user_password: \"${user_password}\"" >> $HOME/Jerry-vpn/secret.yml

jwt_secret=$(openssl rand -hex 23)
session_secret=$(openssl rand -hex 23)
storage_encryption_key=$(openssl rand -hex 23)
echo "jwt_secret: ${jwt_secret}" >> $HOME/Jerry-vpn/secret.yml
echo "session_secret: ${session_secret}" >> $HOME/Jerry-vpn/secret.yml
echo "storage_encryption_key: ${storage_encryption_key}" >> $HOME/Jerry-vpn/secret.yml

echo
echo "Encrypting the variables"
ansible-vault encrypt $HOME/Jerry-vpn/secret.yml

echo
echo "Success!"
echo
echo "Going to run the playbook"
if [[ $EUID -ne 0 ]]; then
    echo
    echo "Please enter your current sudo password now"
    cd $HOME/Jerry-vpn && ansible-playbook --ask-vault-pass -K run.yml
else
    cd $HOME/Jerry-vpn && ansible-playbook --ask-vault-pass run.yml
fi