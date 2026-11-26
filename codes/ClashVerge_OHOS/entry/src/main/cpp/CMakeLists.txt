cmake_minimum_required(VERSION 3.5.0)
project(clash_verge_ohos)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(hilog-lib hilog_ndk.z)
find_library(ace-lib ace_napi.z)
find_library(dl-lib dl)

# NAPI 薄壳：只做参数搬运 + 线程安全回调，Go 内核通过 dlopen 在运行时挂上
add_library(clash_ohos SHARED napi_init.cpp clash_adapter.cpp fd_relay.cpp)
target_link_libraries(clash_ohos PUBLIC ${hilog-lib} ${ace-lib} ${dl-lib})
