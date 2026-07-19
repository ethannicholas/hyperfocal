# Qt shell (cross-platform-plan Phase 2). Dev build:
#
#   QtShell/build.sh          # builds the bridge (SwiftPM), configures, builds
#
# or by hand:
#   swift build --product HyperfocalBridge
#   cmake -S QtShell -B QtShell/build -DHYPERFOCAL_BRIDGE_DIR=$PWD/.build/debug
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
    "Directory containing the SwiftPM-built bridge library (see QtShell/build.sh)")
if(NOT HYPERFOCAL_BRIDGE_DIR)
    message(FATAL_ERROR "Pass -DHYPERFOCAL_BRIDGE_DIR=<dir with libHyperfocalBridge> (see QtShell/build.sh)")
endif()
# SwiftPM names the product libHyperfocalBridge.dylib / .so per platform.
find_library(HYPERFOCAL_BRIDGE_LIB HyperfocalBridge
             PATHS "${HYPERFOCAL_BRIDGE_DIR}" NO_DEFAULT_PATH)
if(NOT HYPERFOCAL_BRIDGE_LIB)
    message(FATAL_ERROR "libHyperfocalBridge not found in ${HYPERFOCAL_BRIDGE_DIR}")
endif()

qt_add_executable(hyperfocal-qt main.cpp)

qt_add_qml_module(hyperfocal-qt
    URI Hyperfocal
    VERSION 1.0
    QML_FILES Main.qml CropOverlay.qml
    SOURCES Shell.h Shell.cpp PaneItem.h PaneItem.cpp LutImageProvider.h
)

# The app icon rides in resources for QGuiApplication::setWindowIcon
# (dock/taskbar identity on every platform; macOS bundles would use an
# icns, but the dev shell is a bare executable).
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/../App/AppIcon.png"
    PROPERTIES QT_RESOURCE_ALIAS "AppIcon.png")
qt_add_resources(hyperfocal-qt "hyperfocal-icon"
    PREFIX "/"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../App/AppIcon.png"
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
    "${HYPERFOCAL_BRIDGE_LIB}")
set_target_properties(hyperfocal-qt PROPERTIES
    BUILD_RPATH "${HYPERFOCAL_BRIDGE_DIR}"
    MACOSX_BUNDLE FALSE)
