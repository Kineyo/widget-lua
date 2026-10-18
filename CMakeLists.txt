cmake_minimum_required(VERSION 3.16)
project(qwen_widget_native VERSION 2.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/include)

if(UNIX AND NOT APPLE)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GLIB REQUIRED glib-2.0 gio-2.0)
    pkg_check_modules(X11 REQUIRED x11 xfixes xi)

    include_directories(${GLIB_INCLUDE_DIRS} ${X11_INCLUDE_DIRS})
    link_directories(${GLIB_LIBRARY_DIRS} ${X11_LIBRARY_DIRS})

    # 1. Native Lua C++ Module (qwen_native.so)
    add_library(qwen_native SHARED src/qwen_native.cpp)
    set_target_properties(qwen_native PROPERTIES
        PREFIX ""
        OUTPUT_NAME "qwen_native"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
    )
    target_compile_options(qwen_native PRIVATE -O2 -Wall -Wextra -Wno-unused-parameter)
    target_link_libraries(qwen_native PRIVATE
        ${GLIB_LIBRARIES}
        ${X11_LIBRARIES}
        pthread
        dl
    )

    # 2. POSIX mmap page-cache eviction guard for llama-server (< 500 MB RAM budget)
    add_library(qwen_mmap_guard SHARED src/qwen_mmap_guard.c)
    set_target_properties(qwen_mmap_guard PROPERTIES
        OUTPUT_NAME "qwen_mmap_guard"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
    )
    target_compile_options(qwen_mmap_guard PRIVATE -O2 -Wall)
    target_link_libraries(qwen_mmap_guard PRIVATE pthread)

    # 3. Embedded binary launcher
    add_executable(qwen-widget-bin src/qwen_runner.cpp)
    set_target_properties(qwen-widget-bin PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
    )
    target_compile_options(qwen-widget-bin PRIVATE -O2 -Wall)

elseif(WIN32)
    add_library(qwen_native SHARED src/qwen_native.cpp)
    set_target_properties(qwen_native PROPERTIES
        PREFIX ""
        OUTPUT_NAME "qwen_native"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
    )
    target_link_libraries(qwen_native PRIVATE user32 ole32 shell32)

    add_executable(qwen-widget-bin src/qwen_runner.cpp)
    set_target_properties(qwen-widget-bin PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
    )

elseif(APPLE)
    add_library(qwen_native SHARED src/qwen_native.cpp)
    set_target_properties(qwen_native PROPERTIES
        PREFIX ""
        SUFFIX ".so"
        OUTPUT_NAME "qwen_native"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/lib"
    )
    target_link_options(qwen_native PRIVATE "-undefined" "dynamic_lookup" "-framework" "ApplicationServices" "-framework" "CoreFoundation")

    add_executable(qwen-widget-bin src/qwen_runner.cpp)
    set_target_properties(qwen-widget-bin PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
    )
endif()
