#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Reproducible build script for OnePlus 9 (SM8350) 5.4 QGKI Kernel
# Features: KernelSU-Next + SUSFS + Droidspaces
# Toolchain: Neutron Clang (LLVM)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/out}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/output}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-${ROOT_DIR}/anykernel}"
TOOLCHAINS_DIR="${TOOLCHAINS_DIR:-${ROOT_DIR}/../toolchains}"

DEFCONFIG="vendor/lahaina-qgki_defconfig"
ARCH="arm64"
JOBS="$(nproc)"

echo "=== [1/6] Preparing Compiler Toolchain ==="
if [ -z "${CLANG_PATH:-}" ]; then
    if [ -x "${ROOT_DIR}/toolchains/neutron-clang/bin/clang" ]; then
        CLANG_PATH="${ROOT_DIR}/toolchains/neutron-clang"
    elif [ -x "${TOOLCHAINS_DIR}/neutron-clang/bin/clang" ]; then
        CLANG_PATH="${TOOLCHAINS_DIR}/neutron-clang"
    else
        echo "Neutron Clang toolchain not found locally. Downloading via antman..."
        mkdir -p "${TOOLCHAINS_DIR}/neutron-clang"
        (
            cd "${TOOLCHAINS_DIR}/neutron-clang"
            curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman" | bash -s -- -S
        )
        CLANG_PATH="${TOOLCHAINS_DIR}/neutron-clang"
    fi
fi

export PATH="${CLANG_PATH}/bin:${PATH}"
echo "Using Clang from: ${CLANG_PATH}"
clang --version | head -n 1

echo "=== [2/6] Configuring Kernel (${DEFCONFIG}) ==="
mkdir -p "${OUT_DIR}" "${OUTPUT_DIR}"
make -C "${ROOT_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 "${DEFCONFIG}"

echo "=== [3/6] Building Kernel Image, Device Trees & Modules (-j${JOBS}) ==="
make -C "${ROOT_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 -j"${JOBS}" Image dtbs modules

echo "=== [4/6] Staging & Stripping Kernel Modules ==="
make -C "${ROOT_DIR}" O="${OUT_DIR}" ARCH="${ARCH}" LLVM=1 LLVM_IAS=1 \
    INSTALL_MOD_PATH="${OUT_DIR}/modules_install" \
    INSTALL_MOD_STRIP=1 \
    modules_install

echo "=== [5/6] Preparing AnyKernel3 & Packaging Flashable Zip ==="
if [ ! -d "${ANYKERNEL_DIR}" ]; then
    echo "Cloning AnyKernel3 template..."
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "${ANYKERNEL_DIR}"
fi

cat <<'EOF' > "${ANYKERNEL_DIR}/anykernel.sh"
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=KernelSU + SUSFS + Droidspaces Kernel 5.4 for OnePlus 9 (SM8350)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=lemonade
device.name2=lemonadep
device.name3=OnePlus9
device.name4=OnePlus9Pro
device.name5=LE2110
device.name6=LE2111
device.name7=LE2113
device.name8=LE2115
device.name9=LE2117
device.name10=martini
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install
EOF

# Copy kernel image
cp -f "${OUT_DIR}/arch/arm64/boot/Image" "${ANYKERNEL_DIR}/Image"

# Concatenate SM8350 device trees
cat "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lahaina.dtb" \
    "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lahaina-v2.dtb" \
    "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lahaina-v2.1.dtb" \
    > "${ANYKERNEL_DIR}/dtb"

# Create flashable zip using python3 (self-contained, no zip binary dependency)
python3 - <<PYEOF
import os, zipfile

src_dir = '${ANYKERNEL_DIR}'
output_dir = '${OUTPUT_DIR}'
exclude_prefixes = ('.git', '.github', 'README.md')

for zip_name in ['OnePlus9_Kernel_5.4_QGKI_KSU_SUSFS_Droidspaces.zip', 'OnePlus9_Kernel_5.4_QGKI_KSU_SUSFS.zip']:
    zip_path = os.path.join(output_dir, zip_name)
    with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(src_dir):
            dirs[:] = [d for d in dirs if not d.startswith('.git')]
            for file in files:
                if file in ('README.md', '.gitignore') or file.endswith('placeholder'):
                    continue
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, src_dir)
                if any(rel_path.startswith(p) for p in exclude_prefixes):
                    continue
                st = os.stat(full_path)
                zinfo = zipfile.ZipInfo.from_file(full_path, rel_path)
                zinfo.external_attr = (st.st_mode & 0xFFFF) << 16
                with open(full_path, 'rb') as f:
                    zf.writestr(zinfo, f.read(), compress_type=zipfile.ZIP_DEFLATED)
    print(f"Created: {zip_path} ({os.path.getsize(zip_path)} bytes)")
PYEOF

echo "=== [6/6] Exporting Deliverables ==="
cp -f "${OUT_DIR}/arch/arm64/boot/Image" "${OUTPUT_DIR}/Image"
cp -f "${ANYKERNEL_DIR}/dtb" "${OUTPUT_DIR}/dtb"
cp -f "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lahaina.dtb" "${OUTPUT_DIR}/lahaina.dtb"

if command -v mkdtboimg >/dev/null 2>&1; then
    mkdtboimg create "${OUTPUT_DIR}/dtbo.img" \
        "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lemonade-19825-overlay.dtbo" \
        "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lemonadep-19815-overlay.dtbo" \
        "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lemonadep-19815-overlay-t0.dtbo" \
        "${OUT_DIR}/arch/arm64/boot/dts/vendor/oplus/lemonadev/lemonadev-2080a-overlay.dtbo"
    echo "Created: ${OUTPUT_DIR}/dtbo.img"
fi

rm -rf "${OUTPUT_DIR}/modules"
cp -r "${OUT_DIR}/modules_install/lib/modules" "${OUTPUT_DIR}/modules"

echo ""
echo "============================================================"
echo " BUILD COMPLETE!"
echo " Flashable zip: ${OUTPUT_DIR}/OnePlus9_Kernel_5.4_QGKI_KSU_SUSFS_Droidspaces.zip"
echo " Kernel image:  ${OUTPUT_DIR}/Image"
echo " Output dir:    ${OUTPUT_DIR}"
echo "============================================================"
