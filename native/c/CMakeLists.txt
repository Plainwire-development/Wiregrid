cmake_minimum_required(VERSION 3.16)
project(wiregrid_c VERSION 1.0.0 LANGUAGES C)
include(GNUInstallDirs)

add_library(wiregrid SHARED src/wiregrid.c)
add_library(wiregrid_static STATIC src/wiregrid.c)
add_library(Wiregrid::wiregrid ALIAS wiregrid)

target_include_directories(wiregrid PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
target_include_directories(wiregrid_static PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
target_compile_features(wiregrid PUBLIC c_std_11)
target_compile_features(wiregrid_static PUBLIC c_std_11)
set_target_properties(wiregrid PROPERTIES VERSION ${PROJECT_VERSION} SOVERSION 1)
set_target_properties(wiregrid_static PROPERTIES OUTPUT_NAME wiregrid)

configure_file(wiregrid.pc.in wiregrid.pc @ONLY)
install(TARGETS wiregrid wiregrid_static
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES include/wiregrid.h DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/wiregrid.pc DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)

include(CTest)
if(BUILD_TESTING)
  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_executable(wiregrid_client_test tests/client_test.c)
  target_link_libraries(wiregrid_client_test PRIVATE wiregrid_static)
  target_compile_features(wiregrid_client_test PRIVATE c_std_11)
  add_test(
    NAME wiregrid_c_protocol
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_protocol_test.py $<TARGET_FILE:wiregrid_client_test>
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endif()
