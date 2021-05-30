#!/usr/bin/env bash

KRNL=$(dirname "$(readlink -f "${0}")")
TC_BLD=${KRNL%/*}

function header() {
    BORDER="====$(for _ in $(seq ${#1}); do printf '='; done)===="
    printf '\033[1m\n%s\n%s\n%s\n\n\033[0m' "${BORDER}" "== ${1} ==" "${BORDER}"
}

# Parse parameters
function parse_parameters() {
    TARGETS=()
    while ((${#})); do
        case ${1} in
            "--allmodconfig")
                CONFIG_TARGET=allmodconfig
                ;;
            "--allyesconfig")
                CONFIG_TARGET=allyesconfig
                ;;
            "-b" | "--build-folder")
                shift
                BUILD_FOLDER=${1}
                ;;
            "-p" | "--path-override")
                shift
                PATH_OVERRIDE=${1}
                ;;
            "--pgo")
                PGO=true
                ;;
            "-s" | "--src-folder")
                shift
                SRC_FOLDER=${1}
                ;;
            "-t" | "--targets")
                shift
                IFS=";" read -ra LLVM_TARGETS <<<"${1}"
                # Convert LLVM targets into GNU triples
                for LLVM_TARGET in "${LLVM_TARGETS[@]}"; do
                    case ${LLVM_TARGET} in
                        "AArch64") TARGETS+=("aarch64-linux-gnu") ;;
                        "ARM") TARGETS+=("arm-linux-gnueabi") ;;
                    esac
                done
                ;;
        esac
        shift
    done
}

function set_default_values() {
    [[ -z ${TARGETS[*]} || ${TARGETS[*]} = "all" ]] && TARGETS=(
        "arm-linux-gnueabi"
        "aarch64-linux-gnu"
    )
    [[ -z ${CONFIG_TARGET} ]] && CONFIG_TARGET=defconfig
}

function setup_up_path() {
    # Add the default install bin folder to PATH for binutils
    export PATH=${TC_BLD}/install/bin:${PATH}
    # Add the stage 2 bin folder to PATH for the instrumented clang if we are doing PGO
    ${PGO:=false} && export PATH=${BUILD_FOLDER:=${TC_BLD}/build/llvm}/stage2/bin:${PATH}
    # If the user wants to add another folder to PATH, they can do it with the PATH_OVERRIDE variable
    [[ -n ${PATH_OVERRIDE} ]] && export PATH=${PATH_OVERRIDE}:${PATH}
}

function setup_krnl_src() {
    # A kernel folder can be supplied via '-f' for testing the script
    if [[ -n ${SRC_FOLDER} ]]; then
        cd "${SRC_FOLDER}" || exit 1
    else
        LINUX=linux-5.11.11
        LINUX_TARBALL=${KRNL}/${LINUX}.tar.xz
        LINUX_PATCH=${KRNL}/${LINUX}-${CONFIG_TARGET}.patch

        # If we don't have the source tarball, download and verify it
        if [[ ! -f ${LINUX_TARBALL} ]]; then
            curl -LSso "${LINUX_TARBALL}" https://cdn.kernel.org/pub/linux/kernel/v5.x/"${LINUX_TARBALL##*/}"

            (
                cd "${LINUX_TARBALL%/*}" || exit 1
                sha256sum -c "${LINUX_TARBALL}".sha256 --quiet
            ) || {
                echo "Linux tarball verification failed! Please remove '${LINUX_TARBALL}' and try again."
                exit 1
            }
        fi

        # If there is a patch to apply, remove the folder so that we can patch it accurately (we cannot assume it has already been patched)
        [[ -f ${LINUX_PATCH} ]] && rm -rf ${LINUX}
        [[ -d ${LINUX} ]] || { tar -xf "${LINUX_TARBALL}" || exit ${?}; }
        cd ${LINUX} || exit 1
        [[ -f ${LINUX_PATCH} ]] && { patch -p1 <"${LINUX_PATCH}" || exit ${?}; }
    fi
}

function check_binutils() {
    # Check for all binutils and build them if necessary
    BINUTILS_TARGETS=()
    for PREFIX in "${TARGETS[@]}"; do
        # We assume these scripts will be only used to make arm64/arm tc-builds
        COMMAND="${PREFIX}"-as
        command -v "${COMMAND}" &>/dev/null || BINUTILS_TARGETS+=("${PREFIX}")
    done
    [[ -n "${BINUTILS_TARGETS[*]}" ]] && { "${TC_BLD}"/build-binutils.py -t "${BINUTILS_TARGETS[@]}" || exit ${?}; }
}

function print_tc_info() {
    # Print final toolchain information
    header "Toolchain information"
    clang --version
}

function build_kernels() {
    # SC2191: The = here is literal. To assign by index, use ( [index]=value ) with no spaces. To keep as literal, quote it.
    # shellcheck disable=SC2191
    MAKE=(make -skj"$(nproc)" LLVM=1 O=out)
    case "$(uname -m)" in
        arm*) [[ ${TARGETS[*]} =~ arm ]] || NEED_GCC=true ;;
        aarch64) [[ ${TARGETS[*]} =~ aarch64 ]] || NEED_GCC=true ;;
    esac
    ${NEED_GCC:=false} && MAKE+=(HOSTCC=gcc HOSTCXX=g++)

    header "Building kernels"

    # If the user has any CFLAGS in their environment, they can cause issues when building tools/
    # Ideally, the kernel would always clobber user flags via ':=' but that is not always the case
    unset CFLAGS

    set -x

    for TARGET in "${TARGETS[@]}"; do
        case ${TARGET} in
            "arm-linux-gnueabi")
                time \
                    "${MAKE[@]}" \
                    ARCH=arm \
                    CROSS_COMPILE="${TARGET}-" \
                    KCONFIG_ALLCONFIG=<(echo CONFIG_CPU_BIG_ENDIAN=n) \
                    distclean "${CONFIG_TARGET}" zImage modules || exit ${?}
                ;;
            "aarch64-linux-gnu")
                time \
                    "${MAKE[@]}" \
                    ARCH=arm64 \
                    CROSS_COMPILE="${TARGET}-" \
                    KCONFIG_ALLCONFIG=<(echo CONFIG_CPU_BIG_ENDIAN=n) \
                    distclean "${CONFIG_TARGET}" Image.gz modules || exit ${?}
                ;;
        esac
    done
}

parse_parameters "${@}"
set_default_values
setup_up_path
setup_krnl_src
check_binutils
print_tc_info
build_kernels
