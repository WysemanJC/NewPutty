# The native macOS (Cocoa) PuTTY application.
#
# This builds PuTTY.app, which links only against the libraries and
# frameworks that come with macOS. The command-line tools (plink, pscp,
# psftp, puttygen and so on) are built by unix/CMakeLists.txt as on any
# other Unix system.

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

set(MACOS_APP_SOURCES
  main.m
  window.m
  dialog.m
  eventloop.c
  config-macos.c
  ${CMAKE_SOURCE_DIR}/unix/config-unix.c
  ${CMAKE_SOURCE_DIR}/unix/unicode.c
  ${CMAKE_SOURCE_DIR}/unix/printing.c
  ${CMAKE_SOURCE_DIR}/stubs/no-console.c)

# The application icon, generated from the same source as every other
# PuTTY icon. Python 3 is needed for that; without it the app is built
# with the generic application icon.
find_package(Python3 COMPONENTS Interpreter)
set(MACOS_ICON_FILE)
if(Python3_Interpreter_FOUND)
  set(icondir ${CMAKE_CURRENT_BINARY_DIR}/icons)
  set(MACOS_ICON_FILE ${icondir}/PuTTY.icns)
  set(mkicon ${CMAKE_SOURCE_DIR}/icons/mkicon.py)
  set(macicon ${CMAKE_SOURCE_DIR}/icons/macicon.py)
  set(icon_commands)
  set(macicon_args)
  foreach(size 16 32 48)
    list(APPEND icon_commands
      COMMAND ${Python3_EXECUTABLE} ${mkicon} -2 putty_icon ${size}
              putty-${size}-mono.pam
      COMMAND ${Python3_EXECUTABLE} ${mkicon} putty_icon ${size}
              putty-${size}.pam)
    list(APPEND macicon_args
      mono:putty-${size}-mono.pam colour:putty-${size}.pam)
  endforeach()
  list(APPEND icon_commands
    COMMAND ${Python3_EXECUTABLE} ${mkicon} putty_icon 128 putty-128.pam)
  list(APPEND macicon_args colour:putty-128.pam)
  add_custom_command(OUTPUT ${MACOS_ICON_FILE}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${icondir}
    ${icon_commands}
    COMMAND ${Python3_EXECUTABLE} ${macicon} ${macicon_args}
            output:PuTTY.icns
    WORKING_DIRECTORY ${icondir}
    DEPENDS ${mkicon} ${macicon}
    COMMENT "Generating PuTTY.icns")
  file(MAKE_DIRECTORY ${icondir})
  set_source_files_properties(${MACOS_ICON_FILE} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources)
  set(MACOS_BUNDLE_ICON PuTTY.icns)
else()
  message(WARNING "Python 3 not found: PuTTY.app will have no icon")
  set(MACOS_BUNDLE_ICON "")
endif()

add_executable(putty MACOSX_BUNDLE
  ${MACOS_APP_SOURCES}
  ${MACOS_ICON_FILE})
be_list(putty PuTTY SSH SERIAL OTHERBACKENDS)
add_dependencies(putty generated_licence_h) # dialog.m uses licence.h
target_link_libraries(putty
  guiterminal eventloop sshclient otherbackends settings
  network crypto utils puttyxpms
  "-framework Cocoa" "-framework CoreText")
set_target_properties(putty PROPERTIES
  OUTPUT_NAME PuTTY
  LINK_INTERFACE_MULTIPLICITY 2
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
  MACOSX_BUNDLE_BUNDLE_NAME PuTTY
  MACOSX_BUNDLE_GUI_IDENTIFIER io.github.wysemanjc.newputty
  MACOSX_BUNDLE_ICON_FILE "${MACOS_BUNDLE_ICON}")

# The Objective-C parts use automatic reference counting.
set_source_files_properties(main.m window.m dialog.m PROPERTIES
  COMPILE_OPTIONS "-fobjc-arc")

# Read the version for Info.plist out of version.h.
file(STRINGS ${CMAKE_SOURCE_DIR}/version.h putty_release_line
  REGEX "^#define RELEASE ")
string(REGEX REPLACE "^#define RELEASE +" "" putty_release
  "${putty_release_line}")
if(NOT putty_release)
  set(putty_release "0.0")
endif()
set_target_properties(putty PROPERTIES
  MACOSX_BUNDLE_SHORT_VERSION_STRING ${putty_release}
  MACOSX_BUNDLE_BUNDLE_VERSION ${putty_release})
