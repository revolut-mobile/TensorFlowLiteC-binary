#!/bin/zsh

set -euo pipefail

readonly WORK_DIR="$(pwd)"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly TENSORFLOW_DIR="${BUILD_DIR}/tensorflow"
readonly OUTPUT_DIR="${BUILD_DIR}/output"
readonly TENSORFLOW_TARGET="TensorFlowLiteC_static_framework"

checkout_tensorflow() {
    echo "Checking out TensorFlow..."
    git clone --recurse-submodules --branch "v2.11.0" --depth 1 https://github.com/tensorflow/tensorflow.git "${TENSORFLOW_DIR}"
    cd "${TENSORFLOW_DIR}"
}

build_tensorflow() {
    cd ${TENSORFLOW_DIR}

    echo ""
    echo "Configuring TensorFlow..."
    # See: https://github.com/tensorflow/tensorflow/issues/8527
    export TF_CONFIGURE_IOS=1
    yes '' | ./configure || True

    echo ""
    echo "Building iphonesimulator framework..."
    bazelisk build --config=ios --ios_multi_cpus=sim_arm64,x86_64 -c opt --cxxopt=--std=c++17 //tensorflow/lite/ios:${TENSORFLOW_TARGET}
    
    echo ""
    echo "Building iphoneos framework..."
    bazelisk build --config=ios --ios_multi_cpus=armv7,arm64 -c opt --cxxopt=--std=c++17 //tensorflow/lite/ios:${TENSORFLOW_TARGET}

    echo ""
    echo "Creating xcframework..."
    mkdir -p "${BUILD_DIR}/iphonesimulator"
    unzip bazel-out/applebin_ios-ios_sim_arm64-opt-ST-f882807c96e5/bin/tensorflow/lite/ios/${TENSORFLOW_TARGET}.zip -d "${BUILD_DIR}/iphonesimulator"
    mkdir -p "${BUILD_DIR}/iphoneos"
    unzip bazel-out/applebin_ios-ios_armv7-opt-ST-5b7531beec20/bin/tensorflow/lite/ios/${TENSORFLOW_TARGET}.zip -d "${BUILD_DIR}/iphoneos"

    xcrun xcodebuild -quiet -create-xcframework \
        -framework "${BUILD_DIR}/iphoneos/TensorFlowLiteC.framework" \
        -framework "${BUILD_DIR}/iphonesimulator/TensorFlowLiteC.framework" \
        -output "${OUTPUT_DIR}/TensorFlowLiteC.xcframework"
}

build_2_11_0() {
    checkout_tensorflow
    build_tensorflow
}

rm -rf "${BUILD_DIR}"
mkdir "${BUILD_DIR}"
build_2_11_0
