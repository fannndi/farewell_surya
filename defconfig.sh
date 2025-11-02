#!/bin/bash
# Defconfig updater for Surya kernel (CAF safe & compact)

set -euo pipefail

# --- Paths & variables ---
KERNEL_DIR="$(pwd)"
OUT_DIR="out"
DEFCONFIG="surya_defconfig"
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"
CONFIG_FILE="$OUT_DIR/.config"
BACKUP_DIR="backups/defconfig"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_DIR/${DEFCONFIG}.${TIMESTAMP}.bak"

# --- Checks ---
[[ ! -f Makefile ]] && { echo "❌ Makefile tidak ditemukan di $KERNEL_DIR"; exit 1; }
[[ ! -f "$DEFCONFIG_PATH" ]] && { echo "❌ Defconfig tidak ditemukan: $DEFCONFIG_PATH"; exit 1; }

# --- Prepare ---
mkdir -p "$OUT_DIR" "$BACKUP_DIR"
echo "🧹 Membersihkan folder build lama..."
rm -rf "$OUT_DIR"

# --- Generate config ---
echo "📦 Membuat .config dari $DEFCONFIG..."
make ARCH=arm64 O="$OUT_DIR" "$DEFCONFIG"

echo "🔄 Menjalankan olddefconfig untuk update CAF..."
make ARCH=arm64 O="$OUT_DIR" olddefconfig

# --- Save compact defconfig ---
echo "💾 Menyimpan defconfig ringkas..."
make ARCH=arm64 O="$OUT_DIR" savedefconfig
cp "$OUT_DIR/defconfig" "$DEFCONFIG_PATH"

# --- Backup ---
echo "🛡️ Backup defconfig lama ke: $BACKUP"
cp "$DEFCONFIG_PATH" "$BACKUP"

echo "✅ Defconfig diperbarui dan tetap ringkas: $DEFCONFIG_PATH"

# --- Optional: add out/ to .gitignore ---
grep -qxF "$OUT_DIR/" .gitignore 2>/dev/null || echo "$OUT_DIR/" >> .gitignore

echo "🎉 Selesai! Defconfig berhasil diregenerasi dan ringkas."