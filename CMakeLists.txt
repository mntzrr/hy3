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
# glesv2 is the same class of dependency as Lua below: src/render.cpp,
# src/shaders.cpp and src/TabGroup.cpp include <GLES2/gl2.h>, and nothing in
# hyprland.pc asks for it - its Requires names egl and cairo, not glesv2. The
# header was found only because mesa installs it under /usr/include, i.e. by
# luck rather than by cmake. Upstream #318 reports the same for glslang.
#
# Headers only, deliberately, and for the same reason as Lua: there is no
# target_link_libraries here at all. Every GL symbol is resolved from hyprland
# at load time, and linking libGLESv2 would add a DT_NEEDED on an
# implementation that need not be the one hyprland itself uses.
pkg_check_modules(DEPS REQUIRED hyprland pixman-1 libdrm pango pangocairo libinput wayland-client xkbcommon glesv2)

# src/dispatchers.cpp includes hyprland's lua binding headers, which include
# <lua.h>. Nothing in hyprland.pc points at it, so this only ever built where
# the distribution happens to install lua.h directly in /usr/include - on a
# distribution that puts it under /usr/include/lua5.4 the build fails.
#
# pkg-config rather than find_package(Lua), which cannot see the lua hyprland
# is built against. CMake's FindLua only learned about lua 5.5 in 4.3 - its own
# `.. versionadded:: 4.3` says so - and hyprland pins lua5_5. Anywhere with an
# older cmake the configure step dies with "Could NOT find Lua (missing:
# LUA_INCLUDE_DIR)" while the headers sit in the sysroot untouched, which is
# what CI has been failing on: nix gives it cmake 4.1.2, this machine has 4.4.2
# and never noticed. pkg-config has no such version ceiling.
#
# First match wins, so the unversioned name is tried first: nixpkgs and arch
# both ship lua.pc for the current lua, and the versioned spellings are there
# for distributions that only ship those.
#
# Headers only, deliberately: the lua symbols are resolved from hyprland at
# load time, which is why this has always linked without liblua on the command
# line. Linking one would add a DT_NEEDED on a lua that need not be the one
# hyprland itself uses - hence LUA_INCLUDE_DIRS below and no LUA_LIBRARIES.
pkg_search_module(LUA REQUIRED lua lua5.5 lua-5.5 lua55 lua5.4 lua-5.4)

add_library(hy3 SHARED
	src/main.cpp
	src/dispatchers.cpp
	src/Hy3Layout.cpp
	src/Hy3Node.cpp
	src/TabGroup.cpp
	src/shaders.cpp
	src/render.cpp
)

# Do NOT add -fvisibility=hidden here. It builds and links cleanly, and it
# takes the plugin from 926 exported symbols to 168, which looks like an
# unambiguous win right up until the compositor segfaults.
#
# Hyprland hands its managers to plugins as inline variables in headers -
# `inline UP<CPluginSystem> g_pPluginSystem;` in plugins/PluginSystem.hpp,
# `inline UP<CCompositor> g_pCompositor;` in Compositor.hpp, and so on for
# every one of them. An inline variable is emitted into each object that uses
# it and relies on the dynamic linker unifying the copies at load time, which
# only happens while they are visible. Hide them and hy3 gets its own
# zero-initialised copy of every manager pointer: g_pPluginSystem drops from a
# unique global to a local BSS symbol, and the first call through it - in this
# case getAllPlugins() from moveNodeToWorkspace - dereferences an empty UP.
#
# The same goes for Log::logger, the vtables and typeinfo of hyprland classes
# hy3 instantiates, and any function-local static inside a hyprland inline
# function. There is no partial version of this that is safe.
#
# What is safe, and is what the file-local helpers in Hy3Layout.cpp,
# Hy3Node.cpp and TabGroup.cpp are marked static for, is keeping hy3's *own*
# symbols out of the table. Nothing outside the plugin references them.

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

target_include_directories(hy3 PRIVATE ${DEPS_INCLUDE_DIRS} ${LUA_INCLUDE_DIRS})

install(TARGETS hy3 LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
