#!/bin/bash
# specterdesktop_build.sh — Specter Desktop (Linux specterd zip and Electron AppImage) reproducible build verification
# Version: v0.3.1
# Organization: WalletScrutiny.com
# Last modified by: Daniel Garcia
# Last modified on: 2026-11-17
# Project: https://github.com/cryptoadvance/specter-desktop
# Disclaimer: for reproducible-build verification and research only. No warranty; users assume all risk and are responsible for legal compliance; the developers assume no liability for misuse.
# Steps: take the official release file (--binary or the GitHub release) and check it against the
# release's SHA256SUMS (and SHA256SUMS.asc when the signing key can be fetched). Clone the tag in a
# container and rebuild it the way upstream's .github/workflows/release.yml does on its Ubuntu 26.04
# runner: the same setup-python and setup-node builds at the same paths, apt packages and PyPI
# packages as of the official build's own timestamp. tarball: build specterd with PyInstaller and
# compare it, udev rules and README byte for byte; on a difference, unpack both PyInstaller archives
# and list which files differ. electron-gui: CI builds the AppImage around the official specterd's
# sha256 (version-data.json), so the official specterd zip is fed in the same way; then compare both
# AppImages byte for byte (the verdict), and on a difference the runtime and every squashfs entry. Writes
# COMPARISON_RESULTS.yaml next to the script.
# Supported: x86_64-linux-gnu, types tarball (specterd-v*-x86_64-linux-gnu.zip) and electron-gui
# (specter_desktop-v*-x86_64-linux-gnu.tar.gz). Windows and macOS builds: not covered.
# Design notes: script-notes/desktop/specter/changelog.md
# Exit codes: 0 = reproducible, 1 = not_reproducible or ftbfs, 2 = invalid parameters, 130 = stopped.
set -euo pipefail

SCRIPT_VERSION="v0.3.1"
APP_ID="specter"
GH_REPO="cryptoadvance/specter-desktop"
REPO_URL="https://github.com/${GH_REPO}.git"
REL_URL="https://github.com/${GH_REPO}/releases/download"
# "Specter Signer 2026", named in the v2.3.0 release notes.
SIGNER_FPR="9DC33CA830589DE3B3225C26EEF5756B2EA42349"
# CI runner: ubuntu-latest = ubuntu-26.04 (image 20261111.196 for v2.3.0).
UBUNTU_IMAGE="docker.io/library/ubuntu:26.04@sha256:0d5255be560e2d2ddcfbfda88549e9e815ef29e7cd7fc62183d5709e6e2963c6"
# setup-python '3.10' and setup-node '18' as resolved on 2026-11-13; libpython of this build is
# byte-identical to the one inside the official v2.3.0 specterd.
PY_VERSION="3.10.22"
PY_URL="https://github.com/actions/python-versions/releases/download/3.10.22-36876129702/python-3.10.22-linux-26.04-x64.tar.gz"
PY_SHA256="ac25c4ef1221aa49d2c666e6cc80d74218340a13908e0046bd9342ef7aae50c8"
PIP_VERSION="26.3"
NODE_VERSION="18.20.8"
NODE_URL="https://github.com/actions/node-versions/releases/download/18.20.8-14110393767/node-18.20.8-linux-x64.tar.gz"
NODE_SHA256="05566dbfd271209ff81c9abc1722d1702c9c582dbed6e2c19c256b7b6ca4056f"
PYIX_URL="https://raw.githubusercontent.com/extremecoders-re/pyinstxtractor/815d31cf26bc71e62f851b2e549452e7b7c9dd98/pyinstxtractor.py"
PYIX_SHA256="94e0b6c9d5151bbeefc7e7452e96e24b396c2dbfcb0348e5f12c4c0865fefe58"
# The runner's checkout path; PyInstaller and electron-builder see it.
CI_SRC="/home/runner/work/specter-desktop/specter-desktop"

EXIT_SUCCESS=0
EXIT_BUILD_FAILED=1
EXIT_INVALID_PARAMS=2

DOCKER_CMD="${DOCKER_CMD:-}"
APP_VERSION=""
APP_ARCH=""
APP_TYPE=""
BINARY_PATH=""
KEEP_IMAGE=false
EXEC_DIR="$(pwd -P)"
RESULTS_FILE="$(dirname "$(readlink -f "$0")")/COMPARISON_RESULTS.yaml"
WORK_DIR=""
SUFFIX=""
TOOL_IMAGE=""
TOOL_IMAGE_BOOT=""
ASSET_NAME=""
APP_HASH="N/A"
APP_COMMIT="N/A"
SCRIPT_HASH="N/A"
CUTOFF=""
SIG_STATUS="unchecked"
JOB_PID=""
JOB_TEE=""
JOB_CTR=""
declare -a USER_FLAGS=()
# Source failures only. Network, memory and registry errors must never become ftbfs: ABS publishes any YAML.
COMPILE_ERRORS='SyntaxError|ModuleNotFoundError|ImportError|pyinstaller: error|PyInstaller\.[A-Za-z.]*Error|\.(c|cc|cpp|h):[0-9]+(:[0-9]+)?: (fatal )?error:'
ENV_ERRORS='heap out of memory|MemoryError|Killed|ENOMEM|ENOSPC|No space left|EMFILE|ENFILE|[Tt]oo many open files|ECONNRESET|ETIMEDOUT|EAI_AGAIN|Could not resolve host|Temporary failure in name resolution|HTTP error 5[0-9][0-9]|status code 5[0-9][0-9]|Read timed out'

die() {
    echo "ERROR: $1" >&2
    exit "${2:-$EXIT_BUILD_FAILED}"
}

warn() {
    echo "WARN: $1" >&2
}

# True only for a source failure in this log; see COMPILE_ERRORS and ENV_ERRORS.
has_compile_error() {
    grep -qE "$ENV_ERRORS" "$1" && return 1
    grep -qE "$COMPILE_ERRORS" "$1"
}

# job LOG yes|no COMMAND...: long steps run as jobs, so a stop interrupts wait at once and the EXIT trap
# can end them. 'yes' also shows the output.
job() {
    local log="$1" show="$2" rc=0
    shift 2
    mkfifo "${WORK_DIR}/job.fifo"
    if [[ "$show" == yes ]]; then tee "$log" < "${WORK_DIR}/job.fifo" & else cat > "$log" < "${WORK_DIR}/job.fifo" & fi
    JOB_TEE=$!
    "$@" > "${WORK_DIR}/job.fifo" 2>&1 &
    JOB_PID=$!
    wait "$JOB_PID" || rc=$?
    JOB_PID=""
    wait "$JOB_TEE" || true
    JOB_TEE=""
    rm -f "${WORK_DIR}/job.fifo"
    return "$rc"
}

cleanup() {
    set +e
    [[ -n "$JOB_CTR" && -n "$DOCKER_CMD" ]] && "$DOCKER_CMD" rm -f "$JOB_CTR" >/dev/null 2>&1
    if [[ -n "$JOB_PID" ]]; then
        kill -TERM "$JOB_PID" 2>/dev/null
        local i
        for i in {1..30}; do
            kill -0 "$JOB_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$JOB_PID" 2>/dev/null
    fi
    [[ -n "$JOB_TEE" ]] && kill "$JOB_TEE" 2>/dev/null
    # unsquashfs and pip leave read-only files and directories; make the workspace deletable again.
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && chmod -R u+w "$WORK_DIR" 2>/dev/null
    [[ -n "$DOCKER_CMD" && "$KEEP_IMAGE" != true ]] || return 0
    [[ -n "$TOOL_IMAGE" ]] && "$DOCKER_CMD" rmi -f "$TOOL_IMAGE" >/dev/null 2>&1
    [[ -n "$TOOL_IMAGE_BOOT" ]] && "$DOCKER_CMD" rmi -f "$TOOL_IMAGE_BOOT" >/dev/null 2>&1
    return 0
}

detect_container_cmd() {
    if [[ -z "$DOCKER_CMD" ]]; then
        if command -v podman >/dev/null 2>&1; then
            DOCKER_CMD="podman"
        elif command -v docker >/dev/null 2>&1; then
            DOCKER_CMD="docker"
        else
            die "Neither podman nor docker was found in PATH" $EXIT_INVALID_PARAMS
        fi
    fi
    # Every file in the workspace stays the caller's: rootless podman maps container root to the caller
    # (--userns=keep-id fails on some hosts: ping_group_range); docker runs as the caller.
    if [[ "$(basename "$DOCKER_CMD")" == podman* ]]; then
        USER_FLAGS=()
    else
        USER_FLAGS=(--user "$(id -u):$(id -g)")
    fi
}

require_value() {
    if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        die "Missing value for parameter: $1" $EXIT_INVALID_PARAMS
    fi
}

usage() {
    echo "Usage: $0 --version X.Y.Z [--arch x86_64-linux-gnu] [--type tarball|electron-gui] [--binary FILE|DIR]"
    echo "  --type     tarball (default): specterd-vX.Y.Z-x86_64-linux-gnu.zip"
    echo "             electron-gui: specter_desktop-vX.Y.Z-x86_64-linux-gnu.tar.gz (AppImage inside)"
    echo "  --binary   the official file, or a directory holding it. For electron-gui the directory may"
    echo "             also hold the specterd zip; otherwise that is downloaded from the release."
    echo "  Without --binary the file is downloaded from the GitHub release v<version>. No GitHub API calls."
}

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        usage
        exit $EXIT_INVALID_PARAMS
    fi
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) require_value "$1" "${2:-}"; APP_VERSION="$2"; shift 2 ;;
            --arch)    require_value "$1" "${2:-}"; APP_ARCH="$2"; shift 2 ;;
            --type)    require_value "$1" "${2:-}"; APP_TYPE="$2"; shift 2 ;;
            --binary)  require_value "$1" "${2:-}"; BINARY_PATH="$2"; shift 2 ;;
            --keep-image) KEEP_IMAGE=true; shift ;;
            -h|--help) usage; exit $EXIT_INVALID_PARAMS ;;
            *)
                warn "Ignoring unknown parameter: $1"
                if [[ $# -ge 2 && "${2:-}" != --* ]]; then shift 2; else shift; fi
                ;;
        esac
    done

    [[ -n "$APP_VERSION" ]] || die "Missing required parameter: --version" $EXIT_INVALID_PARAMS
    APP_VERSION="${APP_VERSION#v}"
    [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid --version '$APP_VERSION' (expected X.Y.Z)" $EXIT_INVALID_PARAMS

    case "${APP_ARCH:-x86_64-linux-gnu}" in
        x86_64-linux-gnu|x86_64-linux|x86_64|amd64|linux/amd64) APP_ARCH="x86_64-linux-gnu" ;;
        *) die "Unsupported --arch '$APP_ARCH' (only x86_64-linux-gnu is rebuilt here)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -z "$APP_TYPE" ]]; then
        warn "No --type given; using tarball"
        APP_TYPE="tarball"
    fi
    case "$APP_TYPE" in
        tarball|specterd) APP_TYPE="tarball"; ASSET_NAME="specterd-v${APP_VERSION}-x86_64-linux-gnu.zip" ;;
        electron-gui|desktop|appimage) APP_TYPE="electron-gui"; ASSET_NAME="specter_desktop-v${APP_VERSION}-x86_64-linux-gnu.tar.gz" ;;
        *) die "Invalid --type '$APP_TYPE' (must be tarball or electron-gui)" $EXIT_INVALID_PARAMS ;;
    esac

    if [[ -n "$BINARY_PATH" ]]; then
        [[ -e "$BINARY_PATH" ]] || die "--binary path does not exist: $BINARY_PATH" $EXIT_INVALID_PARAMS
        BINARY_PATH=$(realpath "$BINARY_PATH")
        if [[ -f "$BINARY_PATH" && "$(basename "$BINARY_PATH")" != "$ASSET_NAME" ]]; then
            warn "--binary is named $(basename "$BINARY_PATH"), not ${ASSET_NAME}; its hash is checked against ${ASSET_NAME}"
        fi
        if [[ -d "$BINARY_PATH" && ! -f "$BINARY_PATH/$ASSET_NAME" ]]; then
            die "--binary directory holds no ${ASSET_NAME}" $EXIT_INVALID_PARAMS
        fi
    fi
    [[ "$(uname -m)" == "x86_64" ]] || die "This script needs an x86_64 host (no emulation)" $EXIT_INVALID_PARAMS
    local f
    for f in avx2 bmi2 fma movbe; do
        grep -qw "$f" /proc/cpuinfo || die "This host CPU lacks $f: the runner's amd64v3 (x86-64-v3) packages cannot run here" $EXIT_INVALID_PARAMS
    done
}

# Python helper, run with the toolcache Python: zip/tar timestamps, AppImage runtime size, asar files.
write_helper() {
    cat > "${WORK_DIR}/helper.py" << 'HELPER_END'
import json, struct, sys, tarfile, zipfile, datetime
cmd, args = sys.argv[1], sys.argv[2:]
def utc(ts): return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc)
if cmd == 'zipmtime':  # DOS time of one entry; the runner's clock is UTC
    i = zipfile.ZipFile(args[0]).getinfo(args[1])
    print(datetime.datetime(*i.date_time).strftime('%Y%m%dT%H%M%SZ'))
elif cmd == 'tarmtime':
    m = [x for x in tarfile.open(args[0]).getmembers() if x.name.endswith('.AppImage')]
    if len(m) != 1: sys.exit('expected one AppImage in the tarball')
    print(m[0].name + ' ' + utc(m[0].mtime).strftime('%Y%m%dT%H%M%SZ'))
elif cmd == 'elfsize':  # the AppImage runtime ends where its section headers end; squashfs follows
    with open(args[0], 'rb') as f: h = f.read(64)
    if h[:4] != b'\x7fELF' or h[4] != 2: sys.exit('not a 64-bit ELF')
    shoff, = struct.unpack_from('<Q', h, 0x28); shentsize, shnum = struct.unpack_from('<HH', h, 0x3A)
    print(shoff + shentsize * shnum)
elif cmd == 'asar':  # print one file from an app.asar
    with open(args[0], 'rb') as f:
        d = f.read(16); hs, = struct.unpack_from('<I', d, 12); hdr = json.loads(f.read(hs))
        base = 8 + struct.unpack_from('<I', d, 4)[0]; e = hdr
        for p in args[1].split('/'): e = e['files'][p]
        f.seek(base + int(e['offset'])); sys.stdout.write(f.read(e['size']).decode())
elif cmd == 'pyc':  # classify differing .pyc: same code object tree, or not
    import marshal, types
    def norm(o):
        if isinstance(o, types.CodeType):
            return ('code',) + tuple(getattr(o, a) for a in ('co_name', 'co_filename', 'co_linetable', 'co_code',
                'co_flags', 'co_firstlineno', 'co_names', 'co_varnames', 'co_freevars', 'co_cellvars', 'co_argcount',
                'co_posonlyargcount', 'co_kwonlyargcount', 'co_nlocals', 'co_stacksize', 'co_exceptiontable'
                ) if hasattr(o, a)) + (tuple(norm(c) for c in o.co_consts),)
        if isinstance(o, (tuple, list)): return (type(o).__name__, tuple(norm(x) for x in o))
        if isinstance(o, frozenset): return ('frozenset', tuple(sorted(repr(x) for x in o)))
        return (type(o).__name__, repr(o))
    same = code = 0
    for line in open(args[0]):
        if not line.startswith('DIFFER ') or not line.rstrip().endswith('.pyc'): continue
        p = line.split()[1]
        a, b = (open(d + '/' + p, 'rb').read() for d in args[1:3])
        if a[:16] == b[:16] and norm(marshal.loads(a[16:])) == norm(marshal.loads(b[16:])): same += 1
        else: code += 1
    print(f'{same + code} differ, {same} with identical code objects (marshal encoding only), {code} in code or header')
else:
    sys.exit('unknown helper command ' + cmd)
HELPER_END
}

# Ubuntu 26.04 like the runner, packages from snapshot.ubuntu.com at the official build's time, and
# the setup-python and setup-node builds CI used at the toolcache paths CI used.
build_tool_image() {
    mkdir -p "${WORK_DIR}/toolctx"
    cat > "${WORK_DIR}/toolctx/Containerfile" << EOF
FROM ${UBUNTU_IMAGE}
ARG SNAPSHOT
ENV DEBIAN_FRONTEND=noninteractive
# The runner installs Ubuntu's amd64v3 package builds; PyInstaller bundles 16 of its libraries.
RUN echo 'APT::Architecture-Variants "amd64v3";' > /etc/apt/apt.conf.d/99variants \\
    && apt-get update && apt-get install -y --no-install-recommends ca-certificates \\
    && apt-get update --snapshot "\$SNAPSHOT" \\
    && printf 'Package: *\\nPin: origin snapshot.ubuntu.com\\nPin-Priority: 1001\\n' > /etc/apt/preferences.d/snapshot \\
    && apt-get dist-upgrade -y --allow-downgrades --snapshot "\$SNAPSHOT" \\
    && apt-get install -y --no-install-recommends --allow-downgrades --snapshot "\$SNAPSHOT" \\
       build-essential git zip unzip curl xz-utils file binutils gnupg dirmngr squashfs-tools \\
       libusb-1.0-0-dev libudev-dev \\
    && rm -rf /var/lib/apt/lists/*
RUN set -e; mkdir -p /tmp/py /opt/hostedtoolcache/node/${NODE_VERSION}/x64; cd /tmp \\
    && curl -fsSL -o py.tgz "${PY_URL}" && echo "${PY_SHA256}  py.tgz" | sha256sum -c - \\
    && curl -fsSL -o node.tgz "${NODE_URL}" && echo "${NODE_SHA256}  node.tgz" | sha256sum -c - \\
    && tar xzf py.tgz -C /tmp/py && tar xzf node.tgz -C /opt/hostedtoolcache/node/${NODE_VERSION}/x64 \\
    && cd /tmp/py && sed -i 's/install --upgrade --force-reinstall pip /install --force-reinstall pip==${PIP_VERSION} /' setup.sh \\
    && RUNNER_TOOL_CACHE=/opt/hostedtoolcache bash ./setup.sh \\
    && chmod -R a+rwX /opt/hostedtoolcache && rm -rf /tmp/py /tmp/py.tgz /tmp/node.tgz
EOF
    echo "Building the tool image (Ubuntu 26.04, apt snapshot ${CUTOFF}, Python ${PY_VERSION}, Node ${NODE_VERSION})..."
    job "${WORK_DIR}/tool-image.log" no "$DOCKER_CMD" build --build-arg SNAPSHOT="$CUTOFF" -t "$TOOL_IMAGE" \
        -f "${WORK_DIR}/toolctx/Containerfile" "${WORK_DIR}/toolctx" \
        || { tail -20 "${WORK_DIR}/tool-image.log"; die "Tool image build failed; no COMPARISON_RESULTS.yaml written"; }
}

# Run a bash snippet in the tool image as the caller: tool [run options --] snippet [args];
# the args become $1.. inside the snippet. The source is mounted at the runner's checkout path.
tool() {
    local -a extra=()
    local a
    for a in "$@"; do
        [[ "$a" == -- ]] || continue
        while [[ "$1" != -- ]]; do extra+=("$1"); shift; done
        shift; break
    done
    local snippet="$1"; shift
    local -a src=()
    [[ -d "${WORK_DIR}/src" ]] && src=(-v "${WORK_DIR}/src:${CI_SRC}:z")
    "$DOCKER_CMD" run --rm "${extra[@]}" ${USER_FLAGS[@]+"${USER_FLAGS[@]}"} -e HOME=/w/home -e TMPDIR=/w/tmp \
        -e PATH="/opt/hostedtoolcache/Python/${PY_VERSION}/x64/bin:/opt/hostedtoolcache/node/${NODE_VERSION}/x64/bin:/usr/local/bin:/usr/bin:/bin" \
        -e LD_LIBRARY_PATH="/opt/hostedtoolcache/Python/${PY_VERSION}/x64/lib" \
        -v "${WORK_DIR}:/w:z" "${src[@]}" -w /w "$TOOL_IMAGE" bash -c "mkdir -p /w/home /w/tmp; ${snippet}" bash "$@"
}

# Downloads and checks before the tool image exists (its apt snapshot needs the official build time).
boot_image() {
    TOOL_IMAGE_BOOT="localhost/specter-verify-boot:${SUFFIX}"
    printf 'FROM %s\nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg dirmngr python3 && rm -rf /var/lib/apt/lists/*\n' "$UBUNTU_IMAGE" > "${WORK_DIR}/Containerfile.boot"
    job "${WORK_DIR}/boot-image.log" no "$DOCKER_CMD" build -t "$TOOL_IMAGE_BOOT" -f "${WORK_DIR}/Containerfile.boot" "${WORK_DIR}" \
        || { tail -20 "${WORK_DIR}/boot-image.log"; die "Download image build failed; no COMPARISON_RESULTS.yaml written"; }
}

boot() {
    "$DOCKER_CMD" run --rm ${USER_FLAGS[@]+"${USER_FLAGS[@]}"} -e HOME=/w/home -v "${WORK_DIR}:/w:z" -w /w "$TOOL_IMAGE_BOOT" \
        bash -c "mkdir -p /w/home; $1" bash "${@:2}"
}

# official_file NAME: copy from --binary or download, then check against SHA256SUMS.
official_file() {
    local name="$1" src=""
    if [[ -f "$BINARY_PATH" && "$name" == "$ASSET_NAME" ]]; then src="$BINARY_PATH"
    elif [[ -d "$BINARY_PATH" && -f "$BINARY_PATH/$name" ]]; then src="$BINARY_PATH/$name"; fi
    if [[ -n "$src" ]]; then
        cp "$src" "${WORK_DIR}/official/${name}"
        echo "Official ${name}: given with --binary (${src})"
    else
        echo "Downloading ${REL_URL}/v${APP_VERSION}/${name}..."
        boot 'curl -fsSL -o "/w/official/$2" "$1/$2"' "${REL_URL}/v${APP_VERSION}" "$name" \
            || die "Download of ${name} failed; no COMPARISON_RESULTS.yaml written"
    fi
    local got want
    got=$(sha256sum "${WORK_DIR}/official/${name}" | cut -d' ' -f1)
    want=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "${WORK_DIR}/official/SHA256SUMS")
    echo "  sha256 ${got} (SHA256SUMS: ${want:-missing})"
    [[ -n "$want" && "$got" == "$want" ]] \
        || die "${name} does not match the release's SHA256SUMS; no COMPARISON_RESULTS.yaml written"
}

fetch_official() {
    mkdir -p "${WORK_DIR}/official"
    boot_image
    boot 'curl -fsSL -o /w/official/SHA256SUMS "$1/SHA256SUMS" && curl -fsSL -o /w/official/SHA256SUMS.asc "$1/SHA256SUMS.asc"' \
        "${REL_URL}/v${APP_VERSION}" || die "Could not fetch SHA256SUMS(.asc) of release v${APP_VERSION}; no COMPARISON_RESULTS.yaml written"
    # Signature: informational unless BAD. A keyserver outage leaves it unchecked.
    local rc=0
    boot 'export GNUPGHOME=/w/home/gnupg; mkdir -p -m 700 $GNUPGHOME
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$1" -o /w/signer.asc || exit 3
        gpg -q --batch --import /w/signer.asc 2>/dev/null || exit 3
        gpg --batch --status-fd 1 --verify /w/official/SHA256SUMS.asc /w/official/SHA256SUMS > /w/gpg-status.txt 2>/w/gpg.log
        grep -q "^\[GNUPG:\] BADSIG" /w/gpg-status.txt && exit 4
        grep -q "^\[GNUPG:\] VALIDSIG $1 " /w/gpg-status.txt || exit 3' "$SIGNER_FPR" || rc=$?
    case "$rc" in
        0) SIG_STATUS="good (${SIGNER_FPR})" ;;
        4) die "SHA256SUMS.asc is a BAD signature; no COMPARISON_RESULTS.yaml written" ;;
        *) SIG_STATUS="unchecked (key ${SIGNER_FPR} not fetched or no valid signature by it)" ;;
    esac
    echo "SHA256SUMS signature: ${SIG_STATUS}"
    official_file "$ASSET_NAME"
    APP_HASH=$(sha256sum "${WORK_DIR}/official/${ASSET_NAME}" | cut -d' ' -f1)
    SPECTERD_ZIP="specterd-v${APP_VERSION}-x86_64-linux-gnu.zip"
    [[ "$APP_TYPE" == tarball ]] || official_file "$SPECTERD_ZIP"
    write_helper
    # Packages (apt snapshot, PyPI) as of the official build: the specterd zip entry's timestamp.
    CUTOFF=$(boot 'python3 /w/helper.py zipmtime "/w/official/$1" specterd' "$SPECTERD_ZIP") \
        || die "Official ${SPECTERD_ZIP} has no specterd entry; no COMPARISON_RESULTS.yaml written"
    echo "Official build time (specterd entry, UTC): ${CUTOFF}"
}

clone_source() {
    echo ""
    echo "Cloning ${REPO_URL} at v${APP_VERSION} (in container)..."
    tool 'set -e
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$1" "$2" /w/src
        cd /w/src
        echo "commit=$(git rev-parse HEAD)"
        t=$(git cat-file -t "refs/tags/v$1")
        if [ "$t" = tag ]; then
            echo "tag_type=annotated"
            git cat-file -p "refs/tags/v$1" | grep -q "BEGIN [A-Z]* *SIGNATURE" && echo "tag_signed=yes" || echo "tag_signed=no"
        else
            echo "tag_type=lightweight"; echo "tag_signed=n/a"
        fi
        git cat-file -p HEAD | grep -q "^gpgsig" && echo "commit_signed=yes" || echo "commit_signed=no"
    ' "$APP_VERSION" "$REPO_URL" > "${WORK_DIR}/git-info.txt" \
        || die "git clone of tag v${APP_VERSION} failed; no COMPARISON_RESULTS.yaml written"
    APP_COMMIT=$(sed -n 's/^commit=//p' "${WORK_DIR}/git-info.txt")
    echo "Commit: ${APP_COMMIT}"
}

write_ftbfs() {
    printf 'script_version: %s\nverdict: ftbfs\nnotes: "%s"\n' "$SCRIPT_VERSION" "$1" > "$RESULTS_FILE"
    display_results ftbfs
}

# run_build NAME SNIPPET: one build step in the tool image; STEP= lines mark how far it got, so only
# a failure in a source build step (never a download) can become ftbfs.
run_build() {
    local name="$1" snippet="$2" rc=0
    JOB_CTR="specter-${name}-${SUFFIX}"
    job "${WORK_DIR}/build.log" yes tool --name "$JOB_CTR" -e PIP_ROOT_USER_ACTION=ignore -e PIP_UPLOADED_PRIOR_TO="$(sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3T\4:\5:\6Z/' <<< "$CUTOFF")" \
        -e PIP_DISABLE_PIP_VERSION_CHECK=1 -e GITHUB_REPOSITORY="$GH_REPO" -- "$snippet" "$APP_VERSION" || rc=$?
    JOB_CTR=""
    [[ "$rc" -eq 0 ]] && return 0
    local step
    step=$(sed -n 's/^STEP=//p' "${WORK_DIR}/build.log" | tail -1)
    echo "Build failed at step: ${step:-setup}"
    if [[ "$step" == compile ]] && has_compile_error "${WORK_DIR}/build.log"; then
        write_ftbfs "Tag v${APP_VERSION} failed to build (${name}); see build.log."
    fi
    die "Build failed at step ${step:-setup} with no source compile error (network, memory, disk or tooling); no COMPARISON_RESULTS.yaml written"
}

# release.yml, job build-specterd-linux, step for step (pip runs as the runner user, not root).
build_specterd() {
    echo ""
    echo "Building specterd v${APP_VERSION} as release.yml does (PyPI as of ${CUTOFF})..."
    run_build specterd '
        set -euo pipefail
        unset CI GITHUB_ACTIONS
        cd '"$CI_SRC"'
        echo STEP=deps
        pip install virtualenv
        virtualenv --python=python3.10 .buildenv
        source .buildenv/bin/activate
        pip install -r requirements.txt --require-hashes
        pip install -e ".[test]"
        pip install build==0.10.0
        echo STEP=compile
        python3 -m build
        echo STEP=deps
        pip install ./dist/cryptoadvance_specter-*.whl
        pip install -r pyinstaller/requirements.txt
        pip freeze > /w/pip-freeze.txt
        echo STEP=compile
        echo "v$1" > pyinstaller/version.txt
        cd pyinstaller
        pyinstaller specterd.spec
        cd ..
        mkdir -p /w/built
        cp pyinstaller/dist/specterd /w/built/specterd
        echo STEP=done'
    BUILT_FILE="${WORK_DIR}/built/specterd"
    [[ -f "$BUILT_FILE" ]] || die "Build finished without pyinstaller/dist/specterd; no COMPARISON_RESULTS.yaml written"
    echo "Built specterd sha256 $(sha256sum "$BUILT_FILE" | cut -d' ' -f1)"
}

# release.yml, job build-electron-linux: the official specterd zip goes where CI unpacks its artifact.
build_electron() {
    mkdir -p "${WORK_DIR}/src/pyinstaller/dist"
    echo ""
    echo "Building the Electron AppImage v${APP_VERSION} around the official specterd, as release.yml does..."
    run_build electron '
        set -euo pipefail
        unset CI GITHUB_ACTIONS
        cd '"$CI_SRC"'
        echo STEP=deps
        unzip -q "/w/official/specterd-v$1-x86_64-linux-gnu.zip" -d pyinstaller/dist/
        cd pyinstaller/electron
        npm ci
        node ./set-version "v$1" ../dist/specterd
        cp -R ../../src/cryptoadvance/specter/static/fonts \
              ../../src/cryptoadvance/specter/static/output.css \
              ../../src/cryptoadvance/specter/static/typography.css .
        echo STEP=compile
        npm run dist -- --linux
        mkdir -p /w/built
        cp dist/Specter-*.AppImage /w/built/
        echo STEP=done'
    local -a out
    mapfile -t out < <(find "${WORK_DIR}/built" -maxdepth 1 -name 'Specter-*.AppImage' -type f)
    [[ ${#out[@]} -eq 1 ]] || die "Build finished without exactly one AppImage (found ${#out[@]}); no COMPARISON_RESULTS.yaml written"
    BUILT_FILE="${out[0]}"
    echo "Built $(basename "$BUILT_FILE") sha256 $(sha256sum "$BUILT_FILE" | cut -d' ' -f1)"
}

# Members of the official archive besides the main binary: udev rules and README, as CI packs them.
compare_extras() {
    local base="$1"
    : > "${WORK_DIR}/extras-diff.txt"
    local f
    while IFS= read -r f; do
        local rel="${f#"$base"/}" mine
        case "$rel" in
            README.md) mine="${WORK_DIR}/readme.expected"
                       echo "Don't forget to set up udev rules! Check out udev folder for instructions." > "$mine" ;;
            udev/*) mine="${WORK_DIR}/src/${rel}" ;;
            *) continue ;;
        esac
        cmp -s "$f" "$mine" || echo "DIFFER ${rel}" >> "${WORK_DIR}/extras-diff.txt"
    done < <(find "$base" -type f | LC_ALL=C sort)
    find "${WORK_DIR}/src/udev" -type f | while IFS= read -r f; do
        [[ -f "${base}/udev/${f#"${WORK_DIR}/src/udev/"}" ]] || echo "ONLY_BUILT udev/${f#"${WORK_DIR}/src/udev/"}"
    done >> "${WORK_DIR}/extras-diff.txt"
    EXTRAS_DIFF=$(grep -c . "${WORK_DIR}/extras-diff.txt" || true)
}

# list_tree DIR: path, type+mode, size and sha256 or link target per entry.
list_tree() {
    tool 'cd "$1" && find . -mindepth 1 -printf "%P\t%y%m %s " \( -type f -exec sh -c "sha256sum \"\$1\" | cut -c1-64" sh {} \; -o -type l -printf "%l\n" -o -printf "-\n" \)' "$1" \
        | LC_ALL=C sort > "${WORK_DIR}/$2"
}

diff_lists() {
    awk -F'\t' 'NR==FNR { a[$1]=$2; next } { b[$1]=$2 }
        END { for (k in a) if (!(k in b)) print "ONLY_OFFICIAL " k
              for (k in b) if (!(k in a)) print "ONLY_BUILT " k
              for (k in a) if ((k in b) && a[k] != b[k]) print "DIFFER " k "\n  official: " a[k] "\n  built:    " b[k] }' \
        "${WORK_DIR}/$1" "${WORK_DIR}/$2" > "${WORK_DIR}/$3"
}

compare_tarball() {
    echo ""
    echo "Comparing specterd, udev rules and README..."
    mkdir -p "${WORK_DIR}/official/unzipped"
    tool 'unzip -q "/w/official/$1" -d /w/official/unzipped' "$ASSET_NAME" || die "Could not unpack ${ASSET_NAME}"
    local off="${WORK_DIR}/official/unzipped/specterd"
    [[ -f "$off" ]] || die "Official zip holds no specterd"
    OFF_BIN_HASH=$(sha256sum "$off" | cut -d' ' -f1); BLT_BIN_HASH=$(sha256sum "$BUILT_FILE" | cut -d' ' -f1)
    BIN_MATCH=true; [[ "$OFF_BIN_HASH" == "$BLT_BIN_HASH" ]] || BIN_MATCH=false
    compare_extras "${WORK_DIR}/official/unzipped"
    : > "${WORK_DIR}/filesystem-diff.txt"
    INNER_TOTAL=0; INNER_DIFF=0
    if [[ "$BIN_MATCH" != true ]]; then
        echo "specterd differs; unpacking both PyInstaller archives..."
        tool 'set -e; curl -fsSL -o /w/pyinstxtractor.py "$1"; echo "$2  /w/pyinstxtractor.py" | sha256sum -c - >/dev/null
            for s in official built; do mkdir -p /w/x-$s; done
            cp /w/official/unzipped/specterd /w/x-official/specterd; cp /w/built/specterd /w/x-built/specterd
            for s in official built; do (cd /w/x-$s && python3 /w/pyinstxtractor.py specterd > /w/pyinstxtractor-$s.log 2>&1); rm /w/x-$s/specterd; done' \
            "$PYIX_URL" "$PYIX_SHA256" || die "Could not unpack the PyInstaller archives; no COMPARISON_RESULTS.yaml written"
        list_tree /w/x-official official-tree.list
        list_tree /w/x-built built-tree.list
        diff_lists official-tree.list built-tree.list filesystem-diff.txt
        INNER_TOTAL=$(cut -f1 "${WORK_DIR}/official-tree.list" "${WORK_DIR}/built-tree.list" | sort -u | grep -c .)
        INNER_DIFF=$(grep -cE '^(ONLY_OFFICIAL|ONLY_BUILT|DIFFER) ' "${WORK_DIR}/filesystem-diff.txt" || true)
        # A .pyc differs either in code or only in marshal encoding: reference flags and set order come
        # from refcounts and the hash seed of the compiling process (PYTHONHASHSEED is not fixed upstream).
        PYC_CLASS=$(tool 'python3 /w/helper.py pyc /w/filesystem-diff.txt /w/x-official /w/x-built' || echo "not classified")
        echo "Differing .pyc files: ${PYC_CLASS}"
    fi
    cat "${WORK_DIR}/extras-diff.txt" >> "${WORK_DIR}/filesystem-diff.txt"
    BUNDLE_VERSION=$(cat "${WORK_DIR}/x-official/specterd_extracted/version.txt" 2>/dev/null || echo "not read")
    PY_OFFICIAL=$(tool 'strings /w/x-official/specterd_extracted/libpython3.10.so.1.0 2>/dev/null | grep -m1 -xE "3\.[0-9]+\.[0-9]+"' || echo "not read")
    echo "specterd: official ${OFF_BIN_HASH}, built ${BLT_BIN_HASH}"
    [[ "$BIN_MATCH" == true ]] || echo "PyInstaller archive: ${INNER_TOTAL} entries compared, ${INNER_DIFF} differ"
    echo "udev rules and README: ${EXTRAS_DIFF} differ"
    local status=not_reproducible
    [[ "$BIN_MATCH" == true && "$EXTRAS_DIFF" -eq 0 ]] && status=reproducible
    cat > "$RESULTS_FILE" << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${status}
hashes:
  - ${APP_HASH}
notes: |
  Built tag v${APP_VERSION} (${APP_COMMIT}) as release.yml job build-specterd-linux does: Ubuntu 26.04,
  setup-python ${PY_VERSION} at the toolcache path, the runner checkout path, apt and PyPI packages as of
  the official build time ${CUTOFF} (pip --uploaded-prior-to; upstream pins hashes for requirements.txt only).
  Compared specterd from ${ASSET_NAME} byte for byte (official ${OFF_BIN_HASH}, built ${BLT_BIN_HASH}),
  plus udev rules and README. The zip itself is not compared: it stores build timestamps and owners.
  On a difference, both PyInstaller archives were unpacked; differing .pyc files: ${PYC_CLASS:-none}.
  specterd=${BIN_MATCH} pyinstaller_entries=${INNER_TOTAL} differ=${INNER_DIFF} extras_differ=${EXTRAS_DIFF} signature=${SIG_STATUS%% *}
YAML_END
    display_results "$status"
}

compare_electron() {
    echo ""
    echo "Comparing the AppImages, udev rules and README..."
    mkdir -p "${WORK_DIR}/official/untarred"
    tool 'tar --no-same-owner -xzf "/w/official/$1" -C /w/official/untarred' "$ASSET_NAME" || die "Could not unpack ${ASSET_NAME}"
    local -a offs
    mapfile -t offs < <(find "${WORK_DIR}/official/untarred" -maxdepth 1 -name 'Specter-*.AppImage' -type f)
    [[ ${#offs[@]} -eq 1 ]] || die "Official tarball holds ${#offs[@]} AppImages, expected one"
    local off="${offs[0]}"
    OFF_BIN_HASH=$(sha256sum "$off" | cut -d' ' -f1); BLT_BIN_HASH=$(sha256sum "$BUILT_FILE" | cut -d' ' -f1)
    BIN_MATCH=true; [[ "$OFF_BIN_HASH" == "$BLT_BIN_HASH" ]] || BIN_MATCH=false
    NAME_MATCH=true; [[ "$(basename "$off")" == "$(basename "$BUILT_FILE")" ]] || NAME_MATCH=false
    compare_extras "${WORK_DIR}/official/untarred"
    : > "${WORK_DIR}/filesystem-diff.txt"
    INNER_TOTAL=0; INNER_DIFF=0; RUNTIME_MATCH=n/a; META_MATCH=n/a
    local rel_off="/w/${off#"${WORK_DIR}"/}" rel_blt="/w/${BUILT_FILE#"${WORK_DIR}"/}"
    if [[ "$BIN_MATCH" != true ]]; then
        echo "AppImages differ; comparing runtime and squashfs entries..."
        tool 'set -e
            for s in official built; do
                f=$1; [ $s = built ] && f=$2
                n=$(python3 /w/helper.py elfsize "$f")
                head -c "$n" "$f" > /w/runtime-$s.bin
                unsquashfs -q -n -o "$n" -d /w/sq-$s "$f" > /dev/null
                unsquashfs -lln -o "$n" "$f" | awk "{\$4=\$5=\"\"; print}" | LC_ALL=C sort > /w/squashfs-$s.ls
            done' "$rel_off" "$rel_blt" || die "Could not unpack the AppImages; no COMPARISON_RESULTS.yaml written"
        RUNTIME_MATCH=true; cmp -s "${WORK_DIR}/runtime-official.bin" "${WORK_DIR}/runtime-built.bin" || RUNTIME_MATCH=false
        list_tree /w/sq-official official-tree.list
        list_tree /w/sq-built built-tree.list
        diff_lists official-tree.list built-tree.list filesystem-diff.txt
        [[ "$RUNTIME_MATCH" == true ]] || echo "DIFFER AppImage runtime (first $(stat -c%s "${WORK_DIR}/runtime-official.bin") bytes)" >> "${WORK_DIR}/filesystem-diff.txt"
        INNER_TOTAL=$(cut -f1 "${WORK_DIR}/official-tree.list" "${WORK_DIR}/built-tree.list" | sort -u | grep -c .)
        INNER_DIFF=$(grep -cE '^(ONLY_OFFICIAL|ONLY_BUILT|DIFFER) ' "${WORK_DIR}/filesystem-diff.txt" || true)
        # Mode, owner, size, path and link target of every entry, without the date and time columns.
        META_MATCH=true
        diff "${WORK_DIR}/squashfs-official.ls" "${WORK_DIR}/squashfs-built.ls" > "${WORK_DIR}/squashfs-meta-diff.txt" || META_MATCH=false
        [[ "$META_MATCH" == true ]] || echo "DIFFER squashfs metadata (mode/owner/size; squashfs-meta-diff.txt)" >> "${WORK_DIR}/filesystem-diff.txt"
        INNER_DIFF=$(grep -cE '^(ONLY_OFFICIAL|ONLY_BUILT|DIFFER) ' "${WORK_DIR}/filesystem-diff.txt" || true)
    fi
    cat "${WORK_DIR}/extras-diff.txt" >> "${WORK_DIR}/filesystem-diff.txt"
    PINNED=$(tool 'set -e; n=$(python3 /w/helper.py elfsize "$1"); unsquashfs -q -n -o "$n" -d /w/asar-off "$1" resources/app.asar >/dev/null; python3 /w/helper.py asar /w/asar-off/resources/app.asar version-data.json' "$rel_off" \
        | tr -d ' \n' | sed -n 's/.*"x64":"\([0-9a-f]\{64\}\)".*/\1/p' || true)
    SPECTERD_HASH=$(tool 'unzip -p "/w/official/$1" specterd | sha256sum | cut -d" " -f1' "$SPECTERD_ZIP" || true)
    echo "AppImage: official ${OFF_BIN_HASH}, built ${BLT_BIN_HASH}"
    [[ "$BIN_MATCH" == true ]] || echo "Runtime identical: ${RUNTIME_MATCH}; squashfs: ${INNER_TOTAL} entries compared, ${INNER_DIFF} differ"
    echo "udev rules and README: ${EXTRAS_DIFF} differ"
    echo "Official app.asar pins specterd sha256 ${PINNED:-not read} (official specterd: ${SPECTERD_HASH})"
    local status=not_reproducible
    # Byte-identical only. Squashfs timestamps (build-time mtimes) are upstream-fixable, so they count.
    TIMES_ONLY=false
    [[ "$BIN_MATCH" != true && "$RUNTIME_MATCH" == true && "$INNER_DIFF" -eq 0 ]] && TIMES_ONLY=true
    [[ "$BIN_MATCH" == true && "$EXTRAS_DIFF" -eq 0 && "$NAME_MATCH" == true ]] && status=reproducible
    cat > "$RESULTS_FILE" << YAML_END
script_version: ${SCRIPT_VERSION}
verdict: ${status}
hashes:
  - ${APP_HASH}
notes: |
  Built tag v${APP_VERSION} (${APP_COMMIT}) as release.yml job build-electron-linux does: Ubuntu 26.04,
  setup-node ${NODE_VERSION}, npm ci from the lockfile, electron-builder --linux, around the official
  ${SPECTERD_ZIP} (CI uses its own specterd artifact; the AppImage holds only its sha256 in
  version-data.json, so the specterd binary itself is verified by --type tarball, not here).
  Compared the AppImage in ${ASSET_NAME} byte for byte (official ${OFF_BIN_HASH}, built ${BLT_BIN_HASH});
  only identical bytes count. On a difference, its runtime and every squashfs entry's content, mode, owner,
  size and link target were compared (timestamps_only=true: those all match and only the build-time mtimes
  differ). Plus udev rules and README; the tar.gz is not compared.
  appimage=${BIN_MATCH} timestamps_only=${TIMES_ONLY} runtime=${RUNTIME_MATCH} squashfs_meta=${META_MATCH} squashfs_entries=${INNER_TOTAL} differ=${INNER_DIFF} extras_differ=${EXTRAS_DIFF} pinned_specterd=${PINNED:-unread} signature=${SIG_STATUS%% *}
YAML_END
    display_results "$status"
}

display_results() {
    local verdict="$1" flags
    flags=$(grep -E '^  [a-z]+=' "$RESULTS_FILE" | tail -1 | sed 's/^ *//' || true)
    echo ""
    echo "======================================================"
    echo "RESULTS"
    echo "======================================================"
    cat "$RESULTS_FILE"
    echo ""
    echo "===== Begin Results ====="
    echo "appId: ${APP_ID}"
    echo "signer: N/A"
    echo "apkVersionName: ${APP_VERSION}"
    echo "apkVersionCode: N/A"
    echo "verdict: ${verdict}"
    echo "appHash: ${APP_HASH}"
    echo "commit: ${APP_COMMIT}"
    echo "scriptVersion: ${SCRIPT_VERSION}"
    echo "scriptHash: ${SCRIPT_HASH}"
    echo ""
    echo "Diff:"
    if [[ -s "${WORK_DIR}/filesystem-diff.txt" ]]; then
        awk '/^[A-Z_]+ / && n++ < 5' "${WORK_DIR}/filesystem-diff.txt"
    else
        echo "${flags:-$verdict}"
    fi
    echo ""
    echo "===== End Results ====="
    echo "appHash = sha256 of the official ${ASSET_NAME} as downloaded (equal to its SHA256SUMS line); publish this one."
    [[ -n "${OFF_BIN_HASH:-}" ]] && echo "Inner binary (not for publishing): official ${OFF_BIN_HASH}, built ${BLT_BIN_HASH}"
    echo "SHA256SUMS signature: ${SIG_STATUS}"
    echo "Tag and signatures: $(grep -E '^(tag_type|tag_signed|commit_signed)=' "${WORK_DIR}/git-info.txt" 2>/dev/null | tr '\n' ' ')"
    [[ -n "${BUNDLE_VERSION:-}" ]] && echo "Official bundle: version.txt ${BUNDLE_VERSION}, Python ${PY_OFFICIAL:-not read} (built with ${PY_VERSION})"
    echo "Upstream skips in build log: $(grep -ci 'skip' "${WORK_DIR}/build.log" 2>/dev/null; true) line(s) mention 'skip'"
    [[ -s "${WORK_DIR}/filesystem-diff.txt" ]] && echo "Full diff: ${WORK_DIR}/filesystem-diff.txt ($(grep -cE '^[A-Z_]+ ' "${WORK_DIR}/filesystem-diff.txt") entries)"
    echo "Workspace: ${WORK_DIR} (build.log, pip-freeze.txt, *-tree.list)"
    echo "YAML: ${RESULTS_FILE}"
    echo ""
    if [[ "$verdict" == "reproducible" ]]; then
        echo "✅ VERDICT: REPRODUCIBLE"
        exit $EXIT_SUCCESS
    fi
    echo "❌ VERDICT: ${verdict^^}"
    exit $EXIT_BUILD_FAILED
}

main() {
    SCRIPT_HASH=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1) || true
    SCRIPT_HASH="${SCRIPT_HASH:-N/A}"
    echo "$(basename "$0") ${SCRIPT_VERSION} sha256: ${SCRIPT_HASH}"
    echo ""

    [[ "$(id -u)" -ne 0 ]] || die "Refusing to run as root; run as a normal user" $EXIT_INVALID_PARAMS
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    parse_arguments "$@"
    detect_container_cmd
    # A stale YAML must never reach ABS. An invalid call exits earlier and leaves it alone.
    rm -f "$RESULTS_FILE"

    SUFFIX="$(date +%s)-$$"
    WORK_DIR="${EXEC_DIR}/specter_verification_${APP_VERSION}_${SUFFIX}"
    # Exclusive: never reuse or delete a workspace another run may own.
    mkdir "$WORK_DIR" || die "Cannot create a new workspace at $WORK_DIR" $EXIT_INVALID_PARAMS
    echo "Workspace: $WORK_DIR"
    TOOL_IMAGE="localhost/specter-verify-tools:${SUFFIX}"

    fetch_official
    build_tool_image
    clone_source
    if [[ "$APP_TYPE" == tarball ]]; then
        build_specterd
        compare_tarball
    else
        build_electron
        compare_electron
    fi
}

main "$@"
