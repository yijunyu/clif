#!/bin/bash
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Install CLIF primer script.

set -x -e

INSTALL_DIR="$HOME"
CLIFSRC_DIR="$PWD"
LLVM_DIR="$CLIFSRC_DIR/../clif_backend/llvm"
BUILD_DIR="$LLVM_DIR/build_matcher"

# Ensure CMake is installed (needs 3.5+)

CV=$(cmake --version | head -1 | cut -f3 -d\ ); CV=(${CV//./ })
if (( CV[0] < 3 || CV[0] == 3 && CV[1] < 5 )); then
  echo "Install CMake version 3.5+"
  exit 1
fi

# Ensure Google protobuf C++ source is installed (needs v3.2+).

PV=$(protoc --version | cut -f2 -d\ ); PV=(${PV//./ })
if (( PV[0] < 3 || PV[0] == 3 && PV[1] < 2 )); then
  echo "Install Google protobuf version 3.2+"
  exit 1
fi
PROTOC_PREFIX_PATH="$(dirname "$(dirname "$(which protoc)")")"

# If Ninja is installed, use it instead of make.  MUCH faster.

declare -a CMAKE_G_FLAG
declare -a MAKE_PARALLELISM
if which ninja; then
  CMAKE_G_FLAGS=(-G Ninja)
  MAKE_OR_NINJA="ninja"
  MAKE_PARALLELISM=()  # Ninja does this on its own.
  # ninja can run a dozen huge ld processes at once during install without
  # this flag... grinding a 12 core workstation with "only" 32GiB to a halt.
  # linking and installing should be I/O bound anyways.
  MAKE_INSTALL_PARALLELISM=(-j 2)
  echo "Using ninja for the clif backend build."
else
  CMAKE_G_FLAGS=()  # The default generates a Makefile.
  MAKE_OR_NINJA="make"
  MAKE_PARALLELISM=(-j 2)
  if [[ -r /proc/cpuinfo ]]; then
    N_CPUS="$(cat /proc/cpuinfo | grep -c ^processor)"
    [[ "$N_CPUS" -gt 0 ]] && MAKE_PARALLELISM=(-j $N_CPUS)
    MAKE_INSTALL_PARALLELISM=(${MAKE_PARALLELISM[@]})
  fi
  echo "Using make.  Build will take a long time.  Consider installing ninja."
fi

# Determine the Python to use.

if [[ "$1" =~ ^-?-h ]]; then
  echo "Usage: $0 [python interpreter]"
  exit 1
fi
PYTHON="python"
if [[ -n "$1" ]]; then
  PYTHON="$1"
fi
echo -n "Using Python interpreter: "
which "$PYTHON"

# Create a virtual environment for the pyclif installation.

CLIF_VIRTUALENV="$INSTALL_DIR"
CLIF_PIP=pip
# virtualenv -p "$PYTHON" "$CLIF_VIRTUALENV"
# Older pip and setuptools can fail.
# 
# Regardless, *necessary* on systems with older pip and setuptools.  comment
# these out if they cause you trouble.  if the final pip install fails, you
# may need a more recent pip and setuptools.
"$CLIF_PIP" install --upgrade pip
"$CLIF_PIP" install --upgrade setuptools

# Download, build and install LLVM and Clang (needs a specific revision).

if [ ! -d $LLVM_DIR ]; then
	mkdir -p "$LLVM_DIR"
	cd "$LLVM_DIR/.."
#	svn co https://llvm.org/svn/llvm-project/llvm/trunk@307315 llvm
	git clone https://github.com/llvm/llvm-project llvm
	cd llvm
	# git log | grep -B40 307315
	git checkout 1cda1d76b110dca737d9c3b8dafe27bab9adbb04
fi
cd $LLVM_DIR/llvm/tools
if [ ! -d clang ]; then
	#svn co https://llvm.org/svn/llvm-project/cfe/trunk@307315 clang
	ln -sf ../../clang .
fi
ln -s -f -n "$CLIFSRC_DIR/clif" clif

# Build and install the CLIF backend.  Our backend is part of the llvm build.
# NOTE: To speed up, we build only for X86. If you need it for a different
# arch, change it to your arch, or just remove the =X86 line below.
git clone https://github.com/python/cpython /workspace/cpython && cd !$ && git checkout v3.8.2 
./configure --prefix=/home/gitpod/.pyenv/versions/3.8.2 --enable-shared && make -j16 && make install
cp /workspace/cpython/libpython3.8.a /home/gitpod/.pyenv/versions/3.8.2/lib/libpython3.8.a
cp /workspace/fastseq/proto_util.cc /workspace/clif_backend/llvm/build_matcher/tools/clif/python/utils/proto_util.cc
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -DCMAKE_INSTALL_PREFIX="$CLIF_VIRTUALENV/clang" \
      -DCMAKE_PREFIX_PATH="/home/gitpod/.pyenv/versions/3.8.2" \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DCMAKE_CXX_FLAGS="-fPIC" \
      -DGOOGLE_PROTOBUF_INCLUDE_DIRS="/home/gitpod/.pyenv/versions/3.8.2/include" \
      -DGOOGLE_PROTOBUF_LIBRARY_DIRS="/home/gitpod/.pyenv/versions/3.8.2/lib" \
      -DLLVM_INSTALL_TOOLCHAIN_ONLY=true \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_BUILD_DOCS=false \
      -DLLVM_TARGETS_TO_BUILD=X86 \
      "${CMAKE_G_FLAGS[@]}" "$LLVM_DIR/llvm"
pip install protobuf pyparsing
"$MAKE_OR_NINJA" "${MAKE_PARALLELISM[@]}" -j 16 clif-matcher clif_python_utils_proto_util
"$MAKE_OR_NINJA" "${MAKE_INSTALL_PARALLELISM[@]}" install

# Get back to the CLIF Python directory and have pip run setup.py.

cd "$CLIFSRC_DIR"
# Grab the python compiled .proto
cp "$BUILD_DIR/tools/clif/protos/ast_pb2.py" clif/protos/
# Grab CLIF generated wrapper implementation for proto_util.
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.cc" clif/python/utils/
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.h" clif/python/utils/
cp "$BUILD_DIR/tools/clif/python/utils/proto_util.init.cc" clif/python/utils/
ln -sf /home/gitpod/.pyenv/versions/3.8.2/include/google cd /home/gitpod/.pyenv/versions/3.8.2/include/python3.8/google
"$CLIF_PIP" install .

echo "SUCCESS - To use pyclif, run $CLIF_VIRTUALENV/bin/pyclif."
