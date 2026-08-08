cmake_minimum_required(VERSION 3.19)
project(Hy3 VERSION "0.1")
set(CMAKE_CXX_STANDARD 23)
add_compile_definitions(WLR_USE_UNSTABLE)
add_compile_options(-Wall -Wextra -Wno-unused-parameter -Wno-unused-value -Wno-missing-field-initializers -Wno-narrowing -Wno-pointer-arith)

# nix workaround
if(CMAKE_EXPORT_COMPILE_COMMANDS)
  set(CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES
      ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED hyprland pixman-1 libdrm pango pangocairo libinput wayland-client xkbcommon)

# src/dispatchers.cpp includes hyprland's lua binding headers, which include
# <lua.h>. Nothing in hyprland.pc points at it, so this only ever built where
# the distribution happens to install lua.h directly in /usr/include - on a
# distribution that puts it under /usr/include/lua5.4 the build fails.
#
# Headers only, deliberately: the lua symbols are resolved from hyprland at
# load time, which is why this has always linked without liblua on the command
# line. Linking one would add a DT_NEEDED on a lua that need not be the one
# hyprland itself uses.
find_package(Lua REQUIRED)

add_library(hy3 SHARED
	src/main.cpp
	src/dispatchers.cpp
	src/Hy3Layout.cpp
	src/Hy3Node.cpp
	src/TabGroup.cpp
	src/shaders.cpp
	src/render.cpp
)

configure_file(src/tab.vert ${CMAKE_CURRENT_BINARY_DIR}/src/tab.vert COPYONLY)
file(READ ${CMAKE_CURRENT_BINARY_DIR}/src/tab.vert SHADER_TAB_VERT)

configure_file(src/tab.frag ${CMAKE_CURRENT_BINARY_DIR}/src/tab.frag COPYONLY)
file(READ ${CMAKE_CURRENT_BINARY_DIR}/src/tab.frag SHADER_TAB_FRAG)

configure_file(src/shader_content.hpp.in src/shader_content.hpp @ONLY)
target_include_directories(hy3 PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/src)

option(HY3_NO_VERSION_CHECK "Disable hyprland version check" FALSE)

if (HY3_NO_VERSION_CHECK)
	target_compile_definitions(hy3 PRIVATE -DHY3_NO_VERSION_CHECK=TRUE)
endif()

target_include_directories(hy3 PRIVATE ${DEPS_INCLUDE_DIRS} ${LUA_INCLUDE_DIR})

install(TARGETS hy3 LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
