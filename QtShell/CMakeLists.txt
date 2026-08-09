# Qt shell (cross-platform-plan Phase 2). Dev build:
#
#   Scripts/build.sh --qt     # builds the bridge (SwiftPM), configures, builds
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

# Version = latest git tag (leading v stripped), build = commit count —
# the same derivation as Scripts/package-app.sh (configure-time; dev
# builds may lag a few commits, which is fine for an About box).
execute_process(COMMAND git describe --tags --abbrev=0
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                OUTPUT_VARIABLE HFQT_VERSION
                OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
execute_process(COMMAND git rev-list --count HEAD
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
                OUTPUT_VARIABLE HFQT_BUILD
                OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT HFQT_VERSION)
    set(HFQT_VERSION "1.0.0")
endif()
string(REGEX REPLACE "^v" "" HFQT_VERSION "${HFQT_VERSION}")
if(NOT HFQT_BUILD)
    set(HFQT_BUILD "1")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Widgets ShaderTools)
qt_standard_project_setup(REQUIRES 6.5)

set(HYPERFOCAL_BRIDGE_DIR "" CACHE PATH
    "Directory containing the SwiftPM-built bridge library (see Scripts/build.sh)")
if(NOT HYPERFOCAL_BRIDGE_DIR)
    message(FATAL_ERROR "Pass -DHYPERFOCAL_BRIDGE_DIR=<dir with libHyperfocalBridge> (see Scripts/build.sh)")
endif()
# SwiftPM names the product libHyperfocalBridge.dylib / .so per platform.
find_library(HYPERFOCAL_BRIDGE_LIB HyperfocalBridge
             PATHS "${HYPERFOCAL_BRIDGE_DIR}" NO_DEFAULT_PATH)
if(NOT HYPERFOCAL_BRIDGE_LIB)
    message(FATAL_ERROR "libHyperfocalBridge not found in ${HYPERFOCAL_BRIDGE_DIR}")
endif()

qt_add_executable(hyperfocal-qt main.cpp)

# UTF-8 active code page for the process (ROADMAP Windows residual 1): the
# C imaging stack under the bridge opens files through ANSI char* APIs; the
# manifest makes them interpret the UTF-8 paths the shell hands over. MSVC
# link merges .manifest sources automatically.
if(WIN32)
    target_sources(hyperfocal-qt PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/../Scripts/windows-utf8.manifest")
endif()

# Warnings are errors for the shell's own sources (first-party C++ only —
# vendored/generated code is not held to this). MSVC-scoped today: the one
# compiler this was verified clean against; extend per-compiler after a
# clean local build elsewhere.
if(MSVC)
    target_compile_options(hyperfocal-qt PRIVATE /WX)
endif()

qt_add_qml_module(hyperfocal-qt
    URI Hyperfocal
    VERSION 1.0
    QML_FILES Main.qml CropOverlay.qml RetouchOverlay.qml BrushCircle.qml
    RESOURCES crop-landscape.svg crop-portrait.svg
    SOURCES Shell.h Shell.cpp PaneItem.h PaneItem.cpp LutImageProvider.h
            CatalogTranslator.h CommandChannel.h
)

# Translations: generated from App/Resources/Localizable.xcstrings by
# Scripts/gen-translations.py and checked in, so Windows/Linux builds need
# no Python and no Qt Linguist tooling. CONFIGURE_DEPENDS re-runs the glob
# when a language is added or removed.
file(GLOB HFQT_I18N CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/i18n/*.json")
if(HFQT_I18N)
    foreach(catalog ${HFQT_I18N})
        get_filename_component(catalog_name "${catalog}" NAME)
        set_source_files_properties("${catalog}"
            PROPERTIES QT_RESOURCE_ALIAS "${catalog_name}")
    endforeach()
    qt_add_resources(hyperfocal-qt "hyperfocal-i18n"
        PREFIX "/i18n"
        FILES ${HFQT_I18N}
    )
else()
    message(WARNING
        "No QtShell/i18n/*.json — run Scripts/gen-translations.py; "
        "the shell will fall back to English.")
endif()

# The app icon rides in resources for QGuiApplication::setWindowIcon
# (dock/taskbar identity on every platform; macOS bundles would use an
# icns, but the dev shell is a bare executable).
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/../App/AppIcon.png"
    PROPERTIES QT_RESOURCE_ALIAS "AppIcon.png")
qt_add_resources(hyperfocal-qt "hyperfocal-icon"
    PREFIX "/"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../App/AppIcon.png"
)

# The crop overlay's rotate-cursor glyphs, shared with the Mac app rather
# than duplicated (Shell.cpp re-orients them into the eight sectors). The
# @2x art is the one that ships: cursors are built at 2x and marked so.
foreach(glyph 0 1)
    set_source_files_properties(
        "${CMAKE_CURRENT_SOURCE_DIR}/../App/Resources/crop-rotate-${glyph}@2x.png"
        PROPERTIES QT_RESOURCE_ALIAS "crop-rotate-${glyph}.png")
endforeach()
qt_add_resources(hyperfocal-qt "hyperfocal-cursors"
    PREFIX "/"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../App/Resources/crop-rotate-0@2x.png"
          "${CMAKE_CURRENT_SOURCE_DIR}/../App/Resources/crop-rotate-1@2x.png"
)

# Third-party notices + the standard license texts, for the About dialog's
# Third-Party Notices viewer (Shell::noticesMarkdown/licensesText). The
# notices are the Windows/Linux slice of the master NOTICE.md, generated by
# Scripts/gen-notices.py. They ALSO ship as plain files beside the
# executable — that is what the LGPL requires of a binary distribution — but
# a resource copy is what makes them readable from a Store install, whose
# package directory is write-protected and buried.
set(HFQT_NOTICE
    "${CMAKE_CURRENT_SOURCE_DIR}/../Packaging/notices/windows-linux/NOTICE.md")
set_source_files_properties("${HFQT_NOTICE}"
    PROPERTIES QT_RESOURCE_ALIAS "NOTICE.md")
file(GLOB HFQT_LICENSES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/../licenses/*.txt")
foreach(license ${HFQT_LICENSES})
    get_filename_component(license_name "${license}" NAME)
    set_source_files_properties("${license}"
        PROPERTIES QT_RESOURCE_ALIAS "licenses/${license_name}")
endforeach()
qt_add_resources(hyperfocal-qt "hyperfocal-notices"
    PREFIX "/notices"
    FILES "${HFQT_NOTICE}" ${HFQT_LICENSES}
)

# The pane's tone shader (see lut.frag) — compiled to qsb for the scene
# graph's RHI backends.
qt_add_shaders(hyperfocal-qt "hyperfocal-shaders"
    PREFIX "/"
    FILES lut.frag
)

target_include_directories(hyperfocal-qt PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(hyperfocal-qt PRIVATE
    HFQT_VERSION="${HFQT_VERSION}" HFQT_BUILD="${HFQT_BUILD}")
target_link_libraries(hyperfocal-qt PRIVATE
    Qt6::Quick Qt6::QuickControls2 Qt6::Widgets
    "${HYPERFOCAL_BRIDGE_LIB}")
set_target_properties(hyperfocal-qt PROPERTIES
    BUILD_RPATH "${HYPERFOCAL_BRIDGE_DIR}"
    MACOSX_BUNDLE FALSE)

# On Windows the shell IS the shipping app, and its file name is user-facing:
# the Start menu entry, Task Manager, the MSIX manifest's Executable=. So the
# binary is Hyperfocal.exe there; the CMake target keeps its build-tool name.
# Deliberately Windows-only — off Windows the Qt shell is a dev/validation
# build that runs beside the macOS app, and naming it Hyperfocal as well would
# leave `pgrep -x Hyperfocal` (Scripts/run.sh's already-running guard, and the
# same check for the Qt shell) unable to tell the two shells apart.
if(WIN32)
    set_target_properties(hyperfocal-qt PROPERTIES OUTPUT_NAME Hyperfocal)
endif()
