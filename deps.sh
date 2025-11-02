#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==================== WARNA TERMINAL ====================
GREEN='\033[1;32m'
RED='\033[1;31m'
BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Mendeteksi lingkungan & OS...${NC}"

# -------------------- DETEKSI ENVIRONMENT --------------------
IS_GITPOD=false
IS_GITHUB=false
IS_LOCAL=true

if [[ -n "${GITPOD_REPO_ROOT:-}" || -d "/workspace" ]]; then
  IS_GITPOD=true
  IS_LOCAL=false
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  IS_GITHUB=true
  IS_LOCAL=false
fi

ARCH=$(uname -m)
DISTRO=$(grep -oP '(?<=^NAME=).+' /etc/os-release | tr -d '"')
UBUNTU_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')

echo -e "${BLUE}🖥️  Arsitektur : ${GREEN}${ARCH}${NC}"
echo -e "${BLUE}🧩 Distro     : ${GREEN}${DISTRO}${NC} (Ubuntu ${UBUNTU_VERSION})"

if $IS_GITPOD; then
  echo -e "${BLUE}🌐 Mode       : ${GREEN}Gitpod${NC}"
elif $IS_GITHUB; then
  echo -e "${BLUE}🌐 Mode       : ${GREEN}GitHub Actions${NC}"
else
  echo -e "${BLUE}🌐 Mode       : ${GREEN}Manual/Local${NC}"
fi

# -------------------- CEK SUDO & APT --------------------
if ! command -v sudo &>/dev/null; then
  echo -e "${RED}❌ 'sudo' tidak tersedia. Jalankan sebagai root atau install sudo.${NC}"
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  echo -e "${RED}❌ Sistem ini tidak menggunakan APT. Hanya Debian/Ubuntu yang didukung.${NC}"
  exit 1
fi

if [[ "$DISTRO" != "Ubuntu" ]]; then
  echo -e "${RED}⚠️ Script ini diuji untuk Ubuntu. Lanjutkan dengan risiko sendiri.${NC}"
fi

# -------------------- UPDATE & UPGRADE --------------------
echo -e "${BLUE}🔄 Memperbarui database APT...${NC}"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y -qq

if $IS_LOCAL; then
  echo -e "${BLUE}⬆️  Meng-upgrade paket yang tersedia...${NC}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
else
  echo -e "${BLUE}ℹ️  Upgrade paket dilewati di environment ini.${NC}"
fi

# -------------------- COMMON DEPENDENCIES --------------------
COMMON_PKGS=(
  build-essential make bc bison flex libssl-dev libelf-dev
  libncurses5-dev libncursesw5-dev libzstd-dev lz4 zstd xz-utils
  liblz4-tool pigz cpio lzop python3 python3-pip python-is-python3
  python3-mako python3-virtualenv python3-setuptools
  device-tree-compiler libfdt-dev libudev-dev curl wget git zip unzip rsync jq ccache
  kmod ninja-build patchutils binutils cmake gettext
  protobuf-compiler libxml2-utils lsb-release openssl
)

echo -e "${BLUE}📦 Menginstal dependencies kernel build...${NC}"
for pkg in "${COMMON_PKGS[@]}"; do
  if apt-cache show "$pkg" &>/dev/null; then
    sudo apt-get install -y --no-install-recommends "$pkg"
  else
    echo -e "${BLUE}ℹ️ Paket '${pkg}' tidak tersedia di Ubuntu ${UBUNTU_VERSION}.${NC}"
  fi
done

# -------------------- VERIFIKASI TOOLS --------------------
echo -e "${BLUE}🔍 Verifikasi tools penting...${NC}"
REQUIRED_TOOLS=( bc make curl git zip python3 lz4 zstd dtc cpio jq rsync unzip )

MISSING=0
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    echo -e "${RED}❌ Tool '${tool}' tidak ditemukan setelah instalasi.${NC}"
    MISSING=1
  fi
done

if [[ "$MISSING" -eq 1 ]]; then
  echo -e "${RED}❌ Beberapa tools tidak ditemukan. Pastikan instalasi berhasil.${NC}"
  exit 1
fi

# -------------------- CLEANUP --------------------
echo -e "${BLUE}🧹 Membersihkan cache APT...${NC}"
sudo apt-get autoremove -y -qq
sudo apt-get clean

# -------------------- DONE --------------------
echo -e "${GREEN}✅ Semua dependencies berhasil diinstal dan diverifikasi!${NC}"