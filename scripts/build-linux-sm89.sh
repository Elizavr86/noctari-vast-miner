#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_COMMIT="6ff4e50987e59a70056324a94ed8667cc0bf598d"
WORK="/tmp/noctari-build"
SRC="$WORK/ccminer"
OUT="/workspace/dist"
PKG="$WORK/package"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  git ca-certificates build-essential automake autoconf autotools-dev \
  libtool pkg-config libcurl4-openssl-dev libssl-dev libjansson-dev \
  zlib1g-dev python3 file

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT" "$PKG/bin"

git clone https://github.com/tpruvot/ccminer.git "$SRC"
git -C "$SRC" checkout "$SOURCE_COMMIT"
git -C "$SRC" switch -c noctari-linux-sm89

SRC_DIR="$SRC" python3 <<'PY'
from pathlib import Path
import os, re

src = Path(os.environ["SRC_DIR"])

mf = src / "Makefile.am"
s = mf.read_text(encoding="utf-8")

s = re.sub(
    r"nvcc_ARCH :=.*?(?=\nnvcc_FLAGS =)",
    'nvcc_ARCH :=\n'
    'nvcc_ARCH += -gencode=arch=compute_89,code=\\"sm_89,compute_89\\"\n',
    s,
    flags=re.S,
)

# The full upstream program compiles old scrypt translation units even when
# only Quark is used. CUDA 11.8 cannot emit their hard-coded SM 3.x targets.
for old in ("20","21","30","32","35","37","50","52","53","60","61","62","70","72","75","80","86"):
    s = s.replace(f"compute_{old}", "compute_89")
    s = s.replace(f"sm_{old}", "sm_89")

mf.write_text(s, encoding="utf-8")

ca = src / "configure.ac"
c = ca.read_text(encoding="utf-8")
c = c.replace('if [[ $ARCH == "x86_64" ]];', 'if test "x$ARCH" = "xx86_64";')
c = c.replace('CUDA_LIBS="-lcudart"', 'CUDA_LIBS="-lcudart_static -ldl -lrt"')
c = c.replace('CUDA_LIBS="-lcudart -static-libstdc++"', 'CUDA_LIBS="-lcudart_static -ldl -lrt -static-libstdc++"')
ca.write_text(c, encoding="utf-8")

# GCC 11 rejects an array of one over-aligned legacy BLAKE2 state because
# sizeof(blake2b_state) is not a multiple of its requested alignment.
# Equihash is not used for Noctari Quark, but the full upstream miner still
# compiles this translation unit. Preserve behavior by using one object and
# passing its address explicitly.
bx = src / "equi/blake2/blake2bx.cpp"
b = bx.read_text(encoding="utf-8")
old_block = """\tblake2b_state S[1];

\t/* Verify parameters */"""
new_block = """\tblake2b_state S;

\t/* Verify parameters */"""
if old_block not in b:
    raise RuntimeError("Expected blake2b_state S[1] block was not found")
b = b.replace(old_block, new_block, 1)
b = b.replace("eq_blake2b_init_key(S, outlen, key, keylen)", "eq_blake2b_init_key(&S, outlen, key, keylen)", 1)
b = b.replace("eq_blake2b_init(S, outlen)", "eq_blake2b_init(&S, outlen)", 1)
b = b.replace("eq_blake2b_update(S, (const uint8_t *)in, inlen)", "eq_blake2b_update(&S, (const uint8_t *)in, inlen)", 1)
b = b.replace("eq_blake2b_final(S, out, outlen)", "eq_blake2b_final(&S, out, outlen)", 1)
bx.write_text(b, encoding="utf-8")
PY

cd "$SRC"
./autogen.sh

CFLAGS="-O3 -fcommon -D_REENTRANT" \
CXXFLAGS="-O3 -fcommon -D_REENTRANT -falign-functions=16 -falign-jumps=16 -falign-labels=16" \
CUDA_CFLAGS="-O3 -lineinfo -D_FORCE_INLINES -Xcompiler -Wno-deprecated-declarations" \
./configure --with-cuda=/usr/local/cuda --with-nvml=/usr/lib

make -j1
strip ccminer || true

/usr/local/cuda/bin/cuobjdump --list-elf ./ccminer > "$OUT/cuobjdump-elf.txt"
grep -q 'sm_89' "$OUT/cuobjdump-elf.txt"
/usr/local/cuda/bin/cuobjdump --list-ptx ./ccminer > "$OUT/cuobjdump-ptx.txt"
grep -q 'compute_89' "$OUT/cuobjdump-ptx.txt"

ldd ./ccminer > "$OUT/ldd.txt" || true
! grep -q 'libcudart' "$OUT/ldd.txt"
MISSING="$(awk '/not found/{print $1}' "$OUT/ldd.txt" | grep -v '^libcuda\.so\.1$' || true)"
[[ -z "$MISSING" ]] || { echo "Unexpected missing libraries: $MISSING" >&2; exit 1; }

cp ./ccminer "$PKG/bin/ccminer"
cat > "$PKG/BUILD_INFO.txt" <<EOF
Source: https://github.com/tpruvot/ccminer
Source commit: $SOURCE_COMMIT
Compiler image: nvidia/cuda:11.8.0-devel-ubuntu22.04
Target: native sm_89 and compute_89 PTX
CUDA runtime: statically linked
EOF

git diff --binary > "$OUT/SOURCE_PATCH.diff"
tar -czf "$OUT/noctari-ccminer-source-sm89.tar.gz" -C "$WORK" ccminer
tar -czf "$OUT/noctari-ccminer-linux-sm89.tar.gz" -C "$PKG" .

(
  cd "$OUT"
  sha256sum noctari-ccminer-linux-sm89.tar.gz > noctari-ccminer-linux-sm89.tar.gz.sha256
  sha256sum noctari-ccminer-source-sm89.tar.gz > noctari-ccminer-source-sm89.tar.gz.sha256
)
