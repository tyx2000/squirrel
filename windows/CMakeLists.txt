# Purpose: Builds Space for Windows natively with Visual Studio (MSVC) or MinGW on Windows.
# The verified build is the cross-build in build.sh; this file is for working on the port
# in Visual Studio.

cmake_minimum_required(VERSION 3.20)
project(Space VERSION 1.0.0 LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB SPACE_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp")
add_executable(Space WIN32 ${SPACE_SOURCES} res/space.rc)

target_include_directories(Space PRIVATE src res)
target_compile_definitions(Space PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
    _WIN32_WINNT=0x0A00 WINVER=0x0A00 NTDDI_VERSION=0x0A000007)

target_link_libraries(Space PRIVATE
    d2d1 dwrite windowscodecs d3d11 dxgi dwmapi mfuuid ole32 oleaut32 uuid runtimeobject
    comctl32 shell32 shcore bcrypt version advapi32 user32 gdi32)

if(MSVC)
    target_compile_options(Space PRIVATE /W4 /utf-8 /permissive-)
    # space.rc embeds the manifest itself.
    target_link_options(Space PRIVATE /MANIFEST:NO)
    set_property(TARGET Space PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
    target_compile_options(Space PRIVATE -Wall -Wextra -Wno-missing-field-initializers -municode)
    target_link_options(Space PRIVATE -municode -static -static-libgcc -static-libstdc++)
endif()
