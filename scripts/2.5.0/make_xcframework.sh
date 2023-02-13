#!/bin/zsh

set -euo pipefail

readonly WORK_DIR="$(pwd)"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly TENSORFLOW_DIR="${BUILD_DIR}/tensorflow"
readonly XNNPACK_DIR="${BUILD_DIR}/XNNPACK"
readonly OUTPUT_DIR="${BUILD_DIR}/output"
readonly BAZEL_DIR="${BUILD_DIR}/bazel"
readonly PATCHED_BAZEL_BIN="${BAZEL_DIR}/bin/bazel"
readonly PATCHES_DIR="${WORK_DIR}/patches/2.5.0"
readonly TENSORFLOW_TARGET="TensorFlowLiteC_static_framework"

# Tensorflow does not support arm64 slices for the simulator yet. This patch is a workaround
# See: https://github.com/tensorflow/tensorflow/issues/47400
clone_and_patch_tensorflow() {
    git clone --recurse-submodules --branch "v2.5.0" --depth 1 https://github.com/tensorflow/tensorflow.git "${TENSORFLOW_DIR}"
    cd "${TENSORFLOW_DIR}"
    git apply "${PATCHES_DIR}/tensorflow.patch"
}

# XNNPACK does not support arm64 slices for the simulator yet. This patch is a workaround
clone_and_patch_XNNPACK() {
    git clone --recurse-submodules https://github.com/google/XNNPACK.git "${XNNPACK_DIR}"
    cd "${XNNPACK_DIR}"
    git checkout fb8d1f1b2bb2e32c141564528a39748c4631b453
    git apply "${PATCHES_DIR}/XNNPACK.patch"
}

# Bazel does not support arm64 slices for the simulator yet. But there is a workaround
# See: https://github.com/bazelbuild/rules_apple/issues/980#issuecomment-738645357
download_patched_version_of_bazel() {
    # Here we are using bazel 4.1.0 to build a patched version of bazel 3.7.2,
    # so we can build the iOS arm64 simulator slice. We are patching version 3.7.2 because
    # that is the version used by tensorflow 2.5.0
    mkdir -p "${BAZEL_DIR}/4.1.0"
    cd "${BAZEL_DIR}/4.1.0"
    curl -O -L "https://github.com/bazelbuild/bazel/releases/download/4.1.0/bazel-4.1.0-darwin-x86_64"
    mv bazel-4.1.0-darwin-x86_64 bazel
    chmod +x bazel

    cd "${BAZEL_DIR}"
    git clone --branch "3.7.2" --depth 1 https://github.com/bazelbuild/bazel.git "3.7.2"
    cd "3.7.2"
    git apply "${PATCHES_DIR}/bazel_ios_sim_arm64.patch"

    # To install java11 on macos: brew install java11 https://mkyong.com/java/how-to-install-java-on-mac-osx/
    # https://github.com/bazelbuild/bazel/issues/11399#issuecomment-628945756
    # https://github.com/bazelbuild/rules_nodejs/issues/1301
    export JAVA_HOME="/opt/homebrew/openjdk@11/libexec/openjdk.jdk/Contents/Home" && "${BAZEL_DIR}"/4.1.0/bazel build --incompatible_restrict_string_escapes=false -c opt //src:bazel
    mkdir -p "$(dirname ${PATCHED_BAZEL_BIN})"
    cp bazel-bin/src/bazel "${PATCHED_BAZEL_BIN}"
    chmod +x "${PATCHED_BAZEL_BIN}"
}

build_xcframework() {
    readonly SIM_ARM64_DIR="${BUILD_DIR}/iphonesimulator/ios_sim_arm64"
    readonly SIM_x86_DIR="${BUILD_DIR}/iphonesimulator/ios_x86_64"

    cd ${TENSORFLOW_DIR}

    # See: https://github.com/tensorflow/tensorflow/issues/8527#issuecomment-289272898
    export TF_CONFIGURE_IOS=1
    # See: https://github.com/tensorflow/tensorflow/issues/8527#issuecomment-287923871
    yes '' | ./configure || True

    # Make arm64 simulator slice
    ${PATCHED_BAZEL_BIN} build --config=ios --cpu=ios_sim_arm64 -c opt tensorflow/lite/ios:${TENSORFLOW_TARGET}
    mkdir -p "${SIM_ARM64_DIR}" && unzip bazel-bin/tensorflow/lite/ios/${TENSORFLOW_TARGET}.zip -d "${SIM_ARM64_DIR}"

    # Make x86_64 simulator slice
    bazelisk build --config=ios --cpu=ios_x86_64 -c opt tensorflow/lite/ios:${TENSORFLOW_TARGET}
    mkdir -p "${SIM_x86_DIR}" && unzip bazel-bin/tensorflow/lite/ios/${TENSORFLOW_TARGET}.zip -d "${SIM_x86_DIR}"

    # Merge both arm64 and x86_64 simulator slices into a fat framework
    merge_framework_slices_into_fat_framework \
        "TensorFlowLiteC" \
        "${SIM_ARM64_DIR}/TensorFlowLiteC.framework" \
        "${SIM_x86_DIR}/TensorFlowLiteC.framework" \
        "${BUILD_DIR}/iphonesimulator"

    # Make ios slices
    bazelisk build --config=ios --ios_multi_cpus=armv7,arm64 -c opt tensorflow/lite/ios:${TENSORFLOW_TARGET}
    unzip bazel-bin/tensorflow/lite/ios/${TENSORFLOW_TARGET}.zip -d "${BUILD_DIR}/iphoneos"

    # Create the xcframework
    xcrun xcodebuild -quiet -create-xcframework \
        -framework "${BUILD_DIR}/iphoneos/TensorFlowLiteC.framework" \
        -framework "${BUILD_DIR}/iphonesimulator/TensorFlowLiteC.framework" \
        -output "${OUTPUT_DIR}/TensorFlowLiteC.xcframework"
}

# Merge two framework slices into one fat framework
# Based on https://gist.github.com/sundeepgupta/3ad9c6106e2cd9f51c68cf9f475191fa
merge_framework_slices_into_fat_framework() {
    readonly NAME="${1}"
    readonly FRAMEWORK_1="${2}"
    readonly FRAMEWORK_2="${3}"
    readonly DESTINATION="${4}"

    # Step 2. Copy the framework structure (from iphoneos build) to the universal folder
    cp -R "${FRAMEWORK_1}" "${DESTINATION}/"

    # Step 3. Copy Swift modules from iphonesimulator build (if it exists) to the copied framework directory
    SIMULATOR_SWIFT_MODULES_DIR="${FRAMEWORK_2}/Modules/${NAME}.swiftmodule/."
    if [ -d "${SIMULATOR_SWIFT_MODULES_DIR}" ]; then
        cp -R "${SIMULATOR_SWIFT_MODULES_DIR}" "${DESTINATION}/${NAME}.framework/Modules/${NAME}.swiftmodule"
    fi

    # Step 4. Create universal binary file using lipo and place the combined executable in the copied framework directory
    lipo -create -output "${DESTINATION}/${NAME}.framework/${NAME}" "${FRAMEWORK_1}/${NAME}" "${FRAMEWORK_2}/${NAME}"
}

build_2_5_0() {
    clone_and_patch_tensorflow
    clone_and_patch_XNNPACK
    download_patched_version_of_bazel
    build_xcframework
}

rm -rf "${BUILD_DIR}"
mkdir "${BUILD_DIR}"
build_2_5_0