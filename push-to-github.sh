#!/usr/bin/env bash
# ============================================================
#  push-to-github.sh
#  Inisialisasi git repository dan push ke GitHub.
#
#  Jalankan dari folder root infralks26:
#    chmod +x push-to-github.sh
#    ./push-to-github.sh
#
#  Prasyarat:
#    - Git sudah terinstal
#    - GitHub account sudah ada
#    - Personal Access Token (PAT) atau SSH key sudah dikonfigurasi
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
log() { echo -e "${CYAN}[>>]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!!]${NC} $1"; }

echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     LKS 2026 — Push Kode ke GitHub             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

# ── Tanya username GitHub ─────────────────────────────────────
read -rp "  GitHub username: " GH_USER
[ -z "$GH_USER" ] && { echo "Username tidak boleh kosong."; exit 1; }

read -rp "  Nama repository GitHub (default: infraautomation): " REPO_NAME
REPO_NAME="${REPO_NAME:-infraautomation}"
REPO_URL="https://github.com/$GH_USER/$REPO_NAME.git"

echo ""
echo -e "  Repository yang akan dibuat: ${CYAN}$REPO_URL${NC}"
echo ""
echo -e "  ${YELLOW}Pastikan repository '$REPO_NAME' sudah dibuat di GitHub:${NC}"
echo -e "  https://github.com/new → Repository name: $REPO_NAME"
echo -e "  Pilih: Public, jangan centang 'Initialize this repository'"
echo ""
read -rp "  Sudah dibuat? (tekan Enter untuk lanjut)" _

# ── Git init & push ───────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if [ -d ".git" ]; then
  # Fix possible permission issue if .git was created by another user (e.g. root in container)
  if ! git config --local user.name &>/dev/null; then
    warn ".git ada tapi tidak bisa dibaca/ditulis — coba fix permission..."
    sudo chown -R "$(whoami)" .git 2>/dev/null \
      || { warn "sudo gagal, coba manual: sudo chown -R \$(whoami) .git"; exit 1; }
    ok "Permission .git diperbaiki"
  else
    warn "Repository sudah di-init. Skip git init."
  fi
else
  log "git init..."
  git init
  ok "git init selesai"
fi

# Pastikan git user dikonfigurasi
if ! git config --global user.email &>/dev/null; then
  read -rp "  Git email (untuk commit): " GIT_EMAIL
  git config --global user.email "${GIT_EMAIL:-lks2026@example.com}"
  git config --global user.name "${GH_USER}"
fi

log "git add semua file..."
git add .

log "Cek status..."
git status --short

log "git commit..."
git commit -m "Initial commit — LKS 2026 Cloud Computing Module" \
  --allow-empty 2>/dev/null || \
  git commit -m "Initial commit — LKS 2026 Cloud Computing Module"
ok "Commit selesai"

log "Set branch main..."
git branch -M main

log "Set remote origin ke $REPO_URL..."
if git remote get-url origin &>/dev/null; then
  git remote set-url origin "$REPO_URL" \
    && ok "Remote origin diupdate: $REPO_URL" \
    || { warn "Gagal set-url, coba remove dulu..."; git remote remove origin; git remote add origin "$REPO_URL"; ok "Remote origin di-reset: $REPO_URL"; }
else
  git remote add origin "$REPO_URL"
  ok "Remote origin ditambahkan: $REPO_URL"
fi

log "Push ke GitHub..."
git push -u origin main

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Kode berhasil di-push ke GitHub!               ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  URL: ${CYAN}https://github.com/$GH_USER/$REPO_NAME${NC}"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Langkah berikutnya:"
echo -e "${BOLD}║${NC}  1. Buka GitHub → Settings → Collaborators"
echo -e "${BOLD}║${NC}     Tambahkan: handipradana (Write access)"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  2. Tambahkan GitHub Secrets:"
echo -e "${BOLD}║${NC}     Settings → Secrets → Actions"
echo -e "${BOLD}║${NC}     (lihat .github/SETUP.md untuk daftar lengkap)"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  3. Untuk JURI:"
echo -e "${BOLD}║${NC}     ${CYAN}./testing/jury-deploy.sh${NC}"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  4. Untuk SISWA:"
echo -e "${BOLD}║${NC}     Kerjakan soal, lalu jalankan:"
echo -e "${BOLD}║${NC}     ${CYAN}./testing/student-check.sh${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"