#!/usr/bin/env bash
set -euo pipefail
shopt -s nocasematch

CLANG_VER="${CLANG_VER:-r547379}"
CLANG_URL_PRIMARY="${CLANG_URL_PRIMARY:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-${CLANG_VER}.tar.gz}"
CLANG_URL_FALLBACK="${CLANG_URL_FALLBACK:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main/clang-${CLANG_VER}?format=tar.gz}"

NDK_URL="${NDK_URL:-https://dl.google.com/android/repository/android-ndk-r21e-linux-x86_64.zip}"

KERNEL_NAME="${KERNEL_NAME:-MIUI-A10}"
DEFCONFIG="${DEFCONFIG:-surya_defconfig}"
OUTDIR="${OUTDIR:-out}"
ARCH="${ARCH:-arm64}"
SUBARCH="${SUBARCH:-arm64}"
BUILD_USER="${BUILD_USER:-fannndi}"
BUILD_HOST="${BUILD_HOST:-local}"
TUNE="${CPU_TUNE:-${TUNE:-default}}" #cortex-a76 #cortex-a55 #default
CACHE_DIR="${CACHE_DIR:-$(pwd)/toolchains}"
CCACHE="${CCACHE:-1}"               # set to 0 to disable ccache
USE_CCACHE=${USE_CCACHE:-$CCACHE}
KERNEL_VER=$(make kernelversion)
ZIPNAME="${ZIPNAME:-${KERNEL_NAME}-Surya-${KERNEL_VER}-${TUNE}-$(date '+%d%m%Y-%H%M').zip}"
BUILD_START=$(date +%s)
MAKE_PROCS="${MAKE_PROCS:-$(nproc)}"

# Colors & icons
CSI="\e["
CLR_RST="${CSI}0m"
CLR_RED="${CSI}31m"
CLR_GREEN="${CSI}32m"
CLR_YEL="${CSI}33m"
CLR_BLU="${CSI}34m"
CLR_MAG="${CSI}35m"
ICON_INFO="ℹ"
ICON_WARN="⚠"
ICON_ERR="❌"
ICON_OK="✅"
LOGFILE="build-artifacts/log.txt"

# Derived
CLANG_DIR="${CACHE_DIR}/clang-${CLANG_VER}"
CLANG_TAR="${CACHE_DIR}/clang-${CLANG_VER}.tar.gz"
NDK_DIR="${CACHE_DIR}/ndk"

# -------------------------
# Logging helpers
# -------------------------
_log() { local c="$1"; shift; echo -e "${c}$*${CLR_RST}"; }
info()  { _log "${CSI}1m${CLR_BLU}" "[$ICON_INFO] $*"; }
ok()    { _log "${CSI}1m${CLR_GREEN}" "[$ICON_OK] $*"; }
warn()  { _log "${CSI}1m${CLR_YEL}" "[$ICON_WARN] $*"; }
err()   { _log "${CSI}1m${CLR_RED}" "[$ICON_ERR] $*"; }

# Trap errors & exit
trap 'err "Build failed. Lihat ${LOGFILE} untuk detail."; exit 1' ERR
mkdir -p build-artifacts
rm -f "$LOGFILE"
exec > >(tee -i "$LOGFILE") 2>&1

# -------------------------
# Environment detection
# -------------------------
OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    BUILD_HOST="github-actions"
elif [[ -n "${GITPOD_WORKSPACE_ID:-}" ]]; then
    BUILD_HOST="gitpod"
else
    BUILD_HOST="local"
fi

# Tentukan CI flag otomatis berdasarkan BUILD_HOST
if [[ "$BUILD_HOST" == "github-actions" ]] || [[ "$BUILD_HOST" == "gitpod" ]]; then
    CI=true
else
    CI=false
fi

info "Detected environment: ${BUILD_HOST} (OS VERSION: ${OS_VERSION})"
info "CI mode: $CI"
info "Using Clang: ${CLANG_VER}"
info "NDK URL: ${NDK_URL}"
info "Tune target: ${TUNE}"
info "Out dir: ${OUTDIR}"
info "Make procs: ${MAKE_PROCS}"
if (( USE_CCACHE )); then info "ccache: enabled"; else warn "ccache: disabled"; fi

# -------------------------
# Utility: retry downloader
# -------------------------
_retry_wget() {
    local url=$1 out=$2 max=3 i=0 rc
    while (( i < max )); do
        info "Downloading (attempt $((i+1))/$max): $url"
        wget -c -q -O "$out" "$url" && rc=0 || rc=$?
        if [[ $rc -eq 0 && -s "$out" ]]; then
            ok "Downloaded: $out"
            return 0
        fi
        ((i++))
        sleep 2
    done
    return 1
}


# -------------------------
# Check & install light deps (only if apt exists)
# -------------------------
require_tools() {
    local missing=()
    for t in git wget tar unzip python3 zip make lz4 zstd cpio bc curl; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing+=("$t")
        fi
    done
    if (( ${#missing[@]} )); then
        warn "Missing tools: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            info "Installing missing packages via apt-get (sudo may be required)"
            sudo apt-get update -y -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
        else
            err "Package manager not found. Install: ${missing[*]}"
            exit 1
        fi
    fi
}

# -------------------------
# Prepare clang (cached)
# -------------------------
prepare_clang() {
    info "Preparing Clang ${CLANG_VER}..."
    mkdir -p "$CACHE_DIR"
    if [[ -f "$CLANG_TAR" && -s "$CLANG_TAR" ]]; then
        ok "Found clang tarball in cache"
    else
        info "Downloading clang tarball..."
        if ! _retry_wget "$CLANG_URL_PRIMARY" "$CLANG_TAR"; then
            warn "Primary failed, trying fallback..."
            if ! _retry_wget "$CLANG_URL_FALLBACK" "$CLANG_TAR"; then
                err "Failed to download clang tarball"
                exit 1
            fi
        fi
    fi

    rm -rf "${CLANG_DIR}.tmp" "$CLANG_DIR"
    mkdir -p "${CLANG_DIR}.tmp"
    info "Extracting clang (this may take a while)..."
    tar -xf "$CLANG_TAR" -C "${CLANG_DIR}.tmp" --warning=no-unknown-keyword || {
        tar -xzf "$CLANG_TAR" -C "${CLANG_DIR}.tmp"
    }

    local possible
    possible=$(find "${CLANG_DIR}.tmp" -maxdepth 3 -type f -name clang -executable -print -quit || true)
    if [[ -n "$possible" ]]; then
        local newroot
        newroot="$(dirname "$(dirname "$possible")")"
        mv "$newroot" "$CLANG_DIR"
    else
        if [[ -x "${CLANG_DIR}.tmp/bin/clang" ]]; then
            mv "${CLANG_DIR}.tmp" "$CLANG_DIR"
        else
            err "clang binary not found after extraction"
            exit 1
        fi
    fi
    rm -rf "${CLANG_DIR}.tmp"

    ln -sf "$CLANG_DIR/bin/llvm-as"      "$CLANG_DIR/bin/as"
    ln -sf "$CLANG_DIR/bin/ld.lld"       "$CLANG_DIR/bin/ld"
    ln -sf "$CLANG_DIR/bin/llvm-nm"      "$CLANG_DIR/bin/nm"
    ln -sf "$CLANG_DIR/bin/llvm-objcopy" "$CLANG_DIR/bin/objcopy"
    ln -sf "$CLANG_DIR/bin/llvm-strip"   "$CLANG_DIR/bin/strip"
    ln -sf "$CLANG_DIR/bin/llvm-objdump" "$CLANG_DIR/bin/objdump"

    echo "$CLANG_VER" > "$CLANG_DIR/clang.version"
    ok "Clang prepared at: $CLANG_DIR"
}

# -------------------------
# Prepare NDK
# -------------------------
prepare_ndk() {
    if [[ -d "$NDK_DIR" ]]; then
        ok "Found existing NDK at $NDK_DIR"
        return 0
    fi
    mkdir -p "$CACHE_DIR"
    local ndk_zip="$CACHE_DIR/ndk.zip"
    if [[ -f "$ndk_zip" && -s "$ndk_zip" ]]; then
        ok "Found cached ndk.zip"
    else
        info "Downloading NDK..."
        _retry_wget "$NDK_URL" "$ndk_zip" || { err "Failed to download NDK"; exit 1; }
    fi
    info "Extracting NDK..."
    unzip -q "$ndk_zip" -d "$CACHE_DIR"
    mv "$CACHE_DIR"/android-ndk-* "$NDK_DIR" 2>/dev/null || {
        local first
        first="$(find "$CACHE_DIR" -maxdepth 1 -type d -name 'android-ndk-*' -print -quit || true)"
        if [[ -n "$first" ]]; then mv "$first" "$NDK_DIR"; fi
    }
    ok "NDK prepared at: $NDK_DIR"
}

# -------------------------
# Setup PATH, ccache
# -------------------------
prepare_toolchains() {
    info "Setting up toolchains & environment..."
    mkdir -p "$CACHE_DIR"
    [[ -f "$CLANG_DIR/clang.version" ]] || prepare_clang
    prepare_ndk

    export PATH="$CLANG_DIR/bin:$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"

    if (( USE_CCACHE )); then
        if ! command -v ccache >/dev/null 2>&1; then
            warn "ccache not found; install to enable caching"
        else
            export CCACHE_DIR="${CACHE_DIR}/ccache"
            mkdir -p "$CCACHE_DIR"
            export CC="ccache clang"
            info "ccache enabled at $CCACHE_DIR"
            ccache -M 5G >/dev/null 2>&1 || true
        fi
    fi

    info "Toolchain summary:"
    command -v clang >/dev/null 2>&1 && clang --version | head -n 1 || warn "clang not on PATH"
    command -v "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" >/dev/null 2>&1 && \
        "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | head -n 1 || true

    info "System info (cpu/mem):"
    lscpu | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core' || true
    free -h || true
}

# -------------------------
# Check toolchain versions & sanity
# -------------------------
check_toolchain_versions() {
    info "Checking toolchain versions..."

    local clang_bin ld_bin ld_version clang_version

    clang_bin=$(command -v clang || true)
    if [[ -z "$clang_bin" ]]; then
        err "clang not found in PATH"
        exit 1
    fi

    clang_version=$("$clang_bin" --version | head -n1)
    info "clang version: $clang_version"

    ld_bin=$(command -v ld.lld || true)
    if [[ -z "$ld_bin" ]]; then
        warn "ld.lld not found in PATH; build may fallback to GNU ld and hit section limit"
    else
        ld_version=$("$ld_bin" --version 2>&1 | head -n1)
        info "ld.lld version: $ld_version"
    fi

    if [[ -x "${CLANG_DIR}/bin/ld.lld" ]]; then
        local ld_clang_version=$("${CLANG_DIR}/bin/ld.lld" --version 2>&1 | head -n1)
        info "ld.lld version (clang dir): $ld_clang_version"
    else
        warn "ld.lld not found in clang dir (${CLANG_DIR}/bin/ld.lld)"
    fi
}

# -------------------------
# Clean source safe
# -------------------------
ensure_clean_source() {
    info "Running make mrproper to reset source tree..."
    make mrproper
}

# -------------------------
# Clean outdir safely
# -------------------------
clean_output() {
    info "Cleaning old build outputs (safe)..."
    if [[ -d "$OUTDIR" ]]; then
        make O="$OUTDIR" clean || true
        rm -rf "$OUTDIR"/{*.img,.config,arch/arm64/boot/*.gz*} || true
    fi
}

# -------------------------
# Apply defconfig
# -------------------------
make_defconfig() {
    info "Applying defconfig: $DEFCONFIG"
    make O="$OUTDIR" ARCH=$ARCH "$DEFCONFIG" \
        CC=clang HOSTCC=clang HOSTCXX=clang++ \
        CROSS_COMPILE=aarch64-linux-android- \
        CROSS_COMPILE_ARM32=arm-linux-androideabi- \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        AS=llvm-as LD=ld.lld LLVM=1 LLVM_IAS=1
    ok "Defconfig applied"
}

# -------------------------
# Compile kernel (dual-target: A55 balance / A76 performance)
# Android 10 CAF, Clang Android 16 (safe & precise)
# -------------------------
compile_kernel() {
    info "Compiling kernel for Poco X3 NFC (Snapdragon 732G)..."

    # === Environment ===
    export ARCH="$ARCH"
    export SUBARCH="$SUBARCH"
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"

    # === Toolchain ===
    export CROSS_COMPILE=aarch64-linux-android-
    export CROSS_COMPILE_ARM32=arm-linux-androideabi-
    export CLANG_TRIPLE=aarch64-linux-gnu-
    export LD=ld.lld
    export AS=llvm-as
    export NM=llvm-nm
    export OBJCOPY=llvm-objcopy
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export LLVM=1
    export LLVM_IAS=1

    # === Parallel build ===
    export MAKEFLAGS="-j${MAKE_PROCS} -l${MAKE_PROCS} --output-sync=target"

    # === Kernel CFLAGS ===
    KCFLAGS=""

    # --- Per-core optimization ---
    case "$TUNE" in
        cortex-a55)
            info "Tuning for A55 (stable, battery friendly)..."
            KCFLAGS+=" -pipe -march=armv8.2-a+crypto+crc+fp16"
            KCFLAGS+=" -mcpu=$TUNE -mtune=$TUNE"
            KCFLAGS+=" -O2 -falign-functions=32 -falign-loops=16"
            KCFLAGS+=" -ftrivial-auto-var-init=zero -fno-plt -fno-pie"
            KCFLAGS+=" -fstrict-vtable-pointers"
            ;;
        cortex-a76)
            info "Tuning for A76 (ultra-performance, max optimization)..."
            KCFLAGS+=" -pipe -march=armv8.2-a+crypto+crc+fp16"
            KCFLAGS+=" -mcpu=$TUNE -mtune=$TUNE"
            KCFLAGS+=" -O3 -funroll-loops -finline-functions"
            KCFLAGS+=" -falign-functions=64 -falign-loops=128"
            KCFLAGS+=" -fomit-frame-pointer -fno-plt -fno-pie"
            KCFLAGS+=" -fstrict-vtable-pointers"
            ;;
        default)
            info "Tuning for default CPU (no per-core optimization)..."
            KCFLAGS+=" -pipe -march=armv8.2-a+crypto+crc+fp16"
            KCFLAGS+=" -O2 -falign-functions=32 -falign-loops=16"
            ;;
    esac

    # --- Safe aggressive flags ---
    KCFLAGS+=" -fno-semantic-interposition -mno-outline-atomics"
    KCFLAGS+=" -rtlib=compiler-rt"

    # --- Micro-optimizations ---
    KCFLAGS+=" -fno-common -fno-strict-aliasing"
    KCFLAGS+=" -fno-stack-protector -fno-exceptions -fno-rtti"

    # --- Runtime / unwinding stripping ---
    KCFLAGS+=" -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-check"

    # --- Data/function sections ---
    KCFLAGS+=" -fmerge-all-constants"

    # --- Debug / metadata cleanup ---
    KCFLAGS+=" -ffile-prefix-map=$(pwd)=. -fno-ident -g0"

    # --- Kernel safety: always keep null pointer checks ---
    KCFLAGS+=" -fno-delete-null-pointer-checks"

    export KCFLAGS
    export KBUILD_CFLAGS="$KCFLAGS"

    # === Linker flags ===
    KBUILD_LDFLAGS="-fuse-ld=lld --gc-sections -Wl,--no-undefined --enable-linker-response-file"

    # --- Auto strip flags based on CI environment ---
    case "$BUILD_HOST" in
        github-actions)
            KBUILD_LDFLAGS+=" --strip-all"
            info "GitHub Actions build → stripping all symbols"
            ;;
        gitpod)
            KBUILD_LDFLAGS+=" --strip-debug"
            info "Gitpod build → keep minimal debug info (no full strip)"
            ;;
        *)
            info "Local build → no stripping applied"
            ;;
    esac

    # --- CPU-specific linker tweaks ---
    case "$TUNE" in
        cortex-a55)
            KBUILD_LDFLAGS+=" -Wl,--sort-common"
            ;;
        cortex-a76)
            KBUILD_LDFLAGS+=" --icf=all --icf-sweep=all --pack-dyn-relocs=relr -Wl,--sort-common"
            ;;
        *)
            KBUILD_LDFLAGS+=" -Wl,--sort-common"
            ;;
    esac

    export KBUILD_LDFLAGS
    export KBUILD_COMPILER_STRING="$(clang --version | head -n1 || echo 'clang')"

    info "Compiler: $KBUILD_COMPILER_STRING"
    info "MAKEFLAGS: $MAKEFLAGS"
    info "TUNE: $TUNE"
    info "KCFLAGS: $KCFLAGS"
    info "KBUILD_LDFLAGS: $KBUILD_LDFLAGS"
    info "Starting build (vmlinux + Image.gz-dtb)..."

    # --- Compile kernel ---
    time make O="$OUTDIR" \
        CC=clang HOSTCC=clang HOSTCXX=clang++ \
        KCFLAGS="$KCFLAGS" \
        KBUILD_LDFLAGS="$KBUILD_LDFLAGS" \
        CFLAGS_KERNEL="-Wno-unused-but-set-variable -Wno-unused-variable -Wno-uninitialized -fno-plt -fno-pie -g0" \
        vmlinux

    ok "Kernel compile finished"

    # --- Generate compressed kernel image ---
    info "Generating Image.gz-dtb from vmlinux..."
    make O="$OUTDIR" ARCH=$ARCH CC=clang HOSTCC=clang HOSTCXX=clang++ \
         KCFLAGS="$KCFLAGS" KBUILD_LDFLAGS="$KBUILD_LDFLAGS" \
         CFLAGS_KERNEL="-Wno-unused-but-set-variable -Wno-unused-variable -Wno-uninitialized -fno-plt -fno-pie -g0" \
         Image.gz-dtb
    ok "Image.gz-dtb generated"
}

# -------------------------
# Build DTB & DTBO
# -------------------------
build_dtb_dtbo() {
    info "Building DTB & DTBO images..."
    shopt -s globstar nullglob
    local dtb_list=( $OUTDIR/arch/arm64/boot/dts/**/*.dtb )
    if (( ${#dtb_list[@]} )); then
        cat "${dtb_list[@]}" > "$OUTDIR/dtb.img"
        ok "Created dtb.img"
    else
        warn "No dtb files found; creating empty dtb.img"
        : > "$OUTDIR/dtb.img"
    fi

    if [[ -f tools/makedtboimg.py ]]; then
        python3 tools/makedtboimg.py create "$OUTDIR/dtbo.img" $OUTDIR/arch/arm64/boot/dts/**/*.dtbo || {
            warn "makedtboimg.py failed; creating empty dtbo.img"
            : > "$OUTDIR/dtbo.img"
        }
    elif command -v mkdtboimg &>/dev/null; then
        mkdtboimg create "$OUTDIR/dtbo.img" $OUTDIR/arch/arm64/boot/dts/**/*.dtbo || : > "$OUTDIR/dtbo.img"
    else
        warn "No makedtboimg.py nor mkdtboimg found; creating empty dtbo.img"
        : > "$OUTDIR/dtbo.img"
    fi
    shopt -u globstar nullglob
}

# -------------------------
# Save .config snapshot
# -------------------------
save_config_snapshot() {
    if [[ -f "$OUTDIR/.config" ]]; then
        cp "$OUTDIR/.config" "build-artifacts/${DEFCONFIG}.snapshot"
        ok "Saved .config snapshot"
    fi
}

# -------------------------
# Package AnyKernel3
# -------------------------
package_anykernel() {
    info "Packaging AnyKernel3..."
    local akdir="AnyKernel3"
    rm -rf "$akdir"
    if ! git clone --depth=1 https://github.com/rinnsakaguchi/AnyKernel3 -b FSociety "$akdir" 2>/dev/null; then
        git clone --depth=1 https://github.com/rinnsakaguchi/AnyKernel3 "$akdir" || true
    fi

    if [[ -f "$OUTDIR/arch/arm64/boot/Image.gz-dtb" ]]; then
        cp "$OUTDIR/arch/arm64/boot/Image.gz-dtb" "$akdir/" || true
    else
        warn "Image.gz-dtb not found; trying Image or zImage"
        cp "$OUTDIR/arch/arm64/boot/Image" "$akdir/" 2>/dev/null || true
        cp "$OUTDIR/arch/arm64/boot/zImage" "$akdir/" 2>/dev/null || true
    fi
    cp "$OUTDIR/dtb.img" "$akdir/" || true
    cp "$OUTDIR/dtbo.img" "$akdir/" || true

    pushd "$akdir" > /dev/null
    zip -r "../$ZIPNAME" ./*
    popd > /dev/null

    ok "Packaged kernel zip: $ZIPNAME"
}

# -------------------------
# Main build flow
# -------------------------
main() {
    require_tools
    prepare_toolchains
    check_toolchain_versions
    ensure_clean_source
    clean_output
    make_defconfig
    compile_kernel
    build_dtb_dtbo
    save_config_snapshot
    package_anykernel
    local duration=$(( $(date +%s) - BUILD_START ))
    ok "Build completed in $(($duration / 60)) min $(( $duration % 60 )) sec"
}

main "$@"