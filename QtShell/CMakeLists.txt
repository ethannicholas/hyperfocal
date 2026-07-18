# Qt shell walking skeleton (cross-platform-plan Phase 2). macOS dev build:
#
#   QtShell/build.sh          # builds the bridge dylib, configures, builds, runs nothing
#
# or by hand:
#   xcodebuild -project App/Hyperfocal.xcodeproj -scheme HyperfocalBridge \
#       -configuration Debug CONFIGURATION_BUILD_DIR=$PWD/QtShell/build/bridge build
#   cmake -S QtShell -B QtShell/build -DHYPERFOCAL_BRIDGE_DIR=$PWD/QtShell/build/bridge
#   cmake --build QtShell/build
#
# Qt via Homebrew (qtbase/qtdeclarative): CMAKE_PREFIX_PATH=/opt/homebrew
# usually resolves automatically on Apple Silicon.
cmake_minimum_required(VERSION 3.21)
project(HyperfocalQtShell LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Widgets ShaderTools)
qt_standard_project_setup(REQUIRES 6.5)

set(HYPERFOCAL_BRIDGE_DIR "" CACHE PATH
    "Directory containing HyperfocalBridge.dylib (see header comment)")
if(NOT HYPERFOCAL_BRIDGE_DIR)
    message(FATAL_ERROR "Pass -DHYPERFOCAL_BRIDGE_DIR=<dir with HyperfocalBridge.dylib> (see QtShell/build.sh)")
endif()

qt_add_executable(hyperfocal-qt main.cpp)

qt_add_qml_module(hyperfocal-qt
    URI Hyperfocal
    VERSION 1.0
    QML_FILES Main.qml
    SOURCES Shell.h Shell.cpp PaneItem.h PaneItem.cpp LutImageProvider.h
)

# The pane's tone shader (see lut.frag) — compiled to qsb for the scene
# graph's RHI backends.
qt_add_shaders(hyperfocal-qt "hyperfocal-shaders"
    PREFIX "/"
    FILES lut.frag
)

target_include_directories(hyperfocal-qt PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(hyperfocal-qt PRIVATE
    Qt6::Quick Qt6::QuickControls2 Qt6::Widgets
    "${HYPERFOCAL_BRIDGE_DIR}/HyperfocalBridge.dylib")
set_target_properties(hyperfocal-qt PROPERTIES
    BUILD_RPATH "${HYPERFOCAL_BRIDGE_DIR}"
    MACOSX_BUNDLE FALSE)
