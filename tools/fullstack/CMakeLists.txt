cmake_minimum_required(VERSION 3.25)
project(helios_fullstack_probes LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
  message(FATAL_ERROR "FullStack Direct3D probes require the Windows MSVC toolchain")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(d3d11_create_probe ../d3d11_devicecreate_probe.cpp)
target_include_directories(d3d11_create_probe PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(d3d11_create_probe PRIVATE /W4 /EHsc)
target_link_libraries(d3d11_create_probe PRIVATE dxgi d3d11)

add_executable(d3d12_create_probe ../d3d12_devicecreate_probe.cpp)
target_include_directories(d3d12_create_probe PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(d3d12_create_probe PRIVATE /W4 /EHsc)
target_link_libraries(d3d12_create_probe PRIVATE dxgi d3d12 dxguid)

add_executable(caps_probe caps_probe.cpp)
target_include_directories(caps_probe PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(caps_probe PRIVATE /W4 /EHsc)
target_link_libraries(caps_probe PRIVATE dxgi d3d12 dxguid bcrypt)

foreach(target d3d11_create_probe d3d12_create_probe caps_probe)
  foreach(config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(${target} PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY_${config} "${CMAKE_BINARY_DIR}/bin")
  endforeach()
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
endforeach()
