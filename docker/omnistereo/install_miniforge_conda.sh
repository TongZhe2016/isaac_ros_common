#!/bin/bash
# Mirrors OmniStereo/setup_env.sh: Miniforge + conda env FD (Python 3.11), torch stack, then pip requirements.
# Keep in sync with OmniStereo/setup_env.sh and OmniStereo/requirements.txt when those change.
set -euo pipefail

MINIFORGE_PREFIX="/opt/miniforge3"
PLATFORM="${PLATFORM:-arm64}"

case "${PLATFORM}" in
  arm64|aarch64)
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh"
    ;;
  amd64|x86_64)
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
    ;;
  *)
    echo "Unsupported PLATFORM=${PLATFORM}" >&2
    exit 1
    ;;
esac

cd /tmp
wget -q "${MINIFORGE_URL}" -O Miniforge3.sh
bash Miniforge3.sh -b -p "${MINIFORGE_PREFIX}"
rm -f Miniforge3.sh

# shellcheck source=/dev/null
source "${MINIFORGE_PREFIX}/etc/profile.d/conda.sh"

conda create -n FD python=3.11 -y

conda run -n FD pip install --upgrade pip
# Legacy sdists (e.g. tables, dinov2) expect setuptools/pkg_resources during build; pip's isolated
# build env often lacks them → ModuleNotFoundError: pkg_resources. Use the FD env for builds.
# openexr (PyPI) uses PEP517 backend scikit_build_core — not the same as legacy scikit-build (skbuild)
conda run -n FD pip install setuptools wheel packaging scikit-build scikit-build-core ninja
conda run -n FD pip install torch==2.4.1 torchvision==0.19.1 torchaudio==2.4.1

# Bulk requirements:
# - flash-attn: setup imports torch (installed separately below).
# - xformers: on aarch64 there is essentially no PyPI wheel.
# - tables / h5py: on aarch64 prefer conda-forge binaries; pip sdists can hit PEP517/pkg_resources or
#   h5py ImportError: build_py_2to3 (removed in Python 3.11 / modern setuptools).
grep -vE '^[[:space:]]*flash-attn[[:space:]]*$' /tmp/conda-requirements.txt > /tmp/conda-requirements-stripped.txt
case "${PLATFORM}" in
  arm64|aarch64)
    grep -vE '^[[:space:]]*xformers' /tmp/conda-requirements-stripped.txt > /tmp/t1.txt
    grep -vE '^[[:space:]]*tables[[:space:]]*$' /tmp/t1.txt > /tmp/t2.txt
    grep -vE '^[[:space:]]*h5py[[:space:]]*$' /tmp/t2.txt > /tmp/t3.txt
    # opencv-contrib-python already provides cv2; pip may pick ancient opencv-python sdist → needs skbuild / fails
    grep -vE '^[[:space:]]*opencv-python' /tmp/t3.txt > /tmp/conda-requirements-no-flash.txt
    rm -f /tmp/t1.txt /tmp/t2.txt /tmp/t3.txt /tmp/conda-requirements-stripped.txt
    echo "NOTE: skipping xformers on aarch64 (no usable wheel in this environment)." >&2
    echo "NOTE: installing pytables+h5py via conda-forge on aarch64 (avoids broken pip sdists)." >&2
    echo "NOTE: skipping opencv-python on aarch64 (use opencv-contrib-python only)." >&2
    conda install -n FD -c conda-forge pytables h5py -y
    ;;
  *)
    mv /tmp/conda-requirements-stripped.txt /tmp/conda-requirements-no-flash.txt
    ;;
esac
# Must use the CLI flag; `env PIP_NO_BUILD_ISOLATION=1` does not reliably disable isolation under conda run.
conda run -n FD pip install --no-build-isolation -r /tmp/conda-requirements-no-flash.txt
rm -f /tmp/conda-requirements-no-flash.txt

# flash-attn must see the installed torch during metadata/build (see pip build isolation)
if ! conda run -n FD pip install flash-attn --no-build-isolation; then
  echo "WARNING: flash-attn failed to build/install. On aarch64/Jetson this is common; install manually if needed." >&2
  case "${PLATFORM}" in
    amd64|x86_64) exit 1 ;;
  esac
fi

# Login shells (e.g. run_dev.sh /bin/bash): same as appending to ~/.bashrc in setup_env.sh
cat > /etc/profile.d/zz_omnistereo_conda.sh <<'EOF'
# Miniforge (OmniStereo FD env)
if [ -f /opt/miniforge3/etc/profile.d/conda.sh ]; then
  . /opt/miniforge3/etc/profile.d/conda.sh
  conda activate FD
fi
EOF
chmod 644 /etc/profile.d/zz_omnistereo_conda.sh

# Match typical interactive behavior with /etc/bash.bashrc (already used by Isaac base images)
if ! grep -q 'zz_omnistereo_conda' /etc/bash.bashrc 2>/dev/null; then
  echo '' >> /etc/bash.bashrc
  echo '# OmniStereo conda (Miniforge FD)' >> /etc/bash.bashrc
  echo 'if [ -f /opt/miniforge3/etc/profile.d/conda.sh ]; then' >> /etc/bash.bashrc
  echo '  . /opt/miniforge3/etc/profile.d/conda.sh' >> /etc/bash.bashrc
  echo '  conda activate FD' >> /etc/bash.bashrc
  echo 'fi' >> /etc/bash.bashrc
fi

rm -f /tmp/conda-requirements.txt
