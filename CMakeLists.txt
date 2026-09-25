cmake_minimum_required(VERSION 3.25)
project(cinmux VERSION 1.0.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
include(CTest)
include(GNUInstallDirs)
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 QuickDialogs2 Sql Network Svg)
find_package(tomlplusplus CONFIG REQUIRED)
find_package(ICU REQUIRED COMPONENTS uc)
find_package(PkgConfig REQUIRED)
pkg_check_modules(WLROOTS REQUIRED IMPORTED_TARGET wlroots-0.20>=0.20.2 wlroots-0.20<0.21)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-server wayland-client xkbcommon pixman-1)
qt_standard_project_setup(REQUIRES 6.8)
add_library(cinmux_core STATIC
    src/state_store.cpp src/state_store.h
    src/session_model.cpp src/session_model.h
    src/session_controller.cpp src/session_controller.h
    src/terminal_compositor.cpp src/terminal_compositor.h
    src/native_server.c src/native_server.h
    src/clipboard_bridge.cpp src/clipboard_bridge.h
    src/terminal_surface_item.cpp src/terminal_surface_item.h
    src/cli.cpp src/cli.h src/theme.cpp src/theme.h)
target_include_directories(cinmux_core PUBLIC src)
target_link_libraries(cinmux_core PUBLIC Qt6::Core Qt6::Gui Qt6::Quick Qt6::Qml Qt6::Sql Qt6::Network tomlplusplus::tomlplusplus)
target_link_libraries(cinmux_core PRIVATE ICU::uc PkgConfig::WLROOTS PkgConfig::WAYLAND)
target_compile_definitions(cinmux_core PRIVATE WLR_USE_UNSTABLE)
qt_add_executable(cinmux src/main.cpp)
target_link_libraries(cinmux PRIVATE cinmux_core Qt6::QuickControls2 Qt6::QuickDialogs2 Qt6::Svg)
file(GLOB CINMUX_ICONS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/resources/icons/*.svg")
qt_add_resources(cinmux core_resources PREFIX /cinmux BASE resources FILES resources/cinmux.tmux.conf ${CINMUX_ICONS})
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_qml_module(cinmux URI Cinmux VERSION 1.0 QML_FILES
    qml/Main.qml qml/AppHeader.qml qml/TerminalPane.qml
    qml/StartupError.qml
    qml/FolderSidebar.qml qml/SessionList.qml qml/ConfirmDialog.qml
    qml/Theme.qml qml/IconButton.qml qml/ActionButton.qml
    qml/PopupSurface.qml qml/AppMenu.qml qml/AppMenuItem.qml
    qml/AppMenuSeparator.qml qml/AppToolTip.qml)
string(REPLACE "\\" "\\\\\\\\" CINMUX_DESKTOP_EXEC "${CMAKE_INSTALL_FULL_BINDIR}/cinmux")
string(REPLACE "\"" "\\\"" CINMUX_DESKTOP_EXEC "${CINMUX_DESKTOP_EXEC}")
string(REPLACE "`" "\\`" CINMUX_DESKTOP_EXEC "${CINMUX_DESKTOP_EXEC}")
string(REPLACE "$" "\\$" CINMUX_DESKTOP_EXEC "${CINMUX_DESKTOP_EXEC}")
string(REPLACE "%" "%%" CINMUX_DESKTOP_EXEC "${CINMUX_DESKTOP_EXEC}")
set(CINMUX_DESKTOP_EXEC "\"${CINMUX_DESKTOP_EXEC}\"")
configure_file(resources/io.niay.cinmux.desktop.in io.niay.cinmux.desktop @ONLY)
install(TARGETS cinmux RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/io.niay.cinmux.desktop" DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES resources/io.niay.cinmux.svg DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps)
install(FILES LICENSE DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses/cinmux)
install(FILES resources/icons/LICENSE DESTINATION ${CMAKE_INSTALL_DATADIR}/licenses/cinmux RENAME Lucide-LICENSE)
install(FILES README.md DESTINATION ${CMAKE_INSTALL_DATADIR}/doc/cinmux)
install(FILES resources/omp/cinmux-activity.ts DESTINATION ${CMAKE_INSTALL_DATADIR}/cinmux/omp)
if(BUILD_TESTING)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    qt_add_executable(theme_test tests/theme_test.cpp)
    target_link_libraries(theme_test PRIVATE cinmux_core Qt6::Test)
    add_test(NAME theme COMMAND theme_test)
        qt_add_executable(backend_test tests/backend_test.cpp)
        target_link_libraries(backend_test PRIVATE cinmux_core Qt6::Test)
        qt_add_resources(backend_test test_resources PREFIX /cinmux BASE resources FILES resources/cinmux.tmux.conf)
        add_test(NAME backend COMMAND backend_test)
        set_tests_properties(backend PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()
