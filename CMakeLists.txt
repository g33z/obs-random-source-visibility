cmake_minimum_required(VERSION 3.16...3.29)

project(obs-random-source-visibility VERSION 1.3.0 LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(APPLE)
	set(OBS_APP_BUNDLE "/Applications/OBS.app" CACHE PATH "Installed OBS.app to link libobs against")
	set(OBS_LIBOBS_HEADERS_DIR "${CMAKE_SOURCE_DIR}/.deps/libobs-headers" CACHE PATH "libobs headers matching OBS_APP_BUNDLE's version")
	set(OBS_GENERATED_HEADERS_DIR "${CMAKE_SOURCE_DIR}/.deps/generated" CACHE PATH "Generated libobs headers (obsconfig.h)")

	set(OBS_LIBOBS_LIBRARY "${OBS_APP_BUNDLE}/Contents/Frameworks/libobs.framework/libobs")
	set(OBS_LIBOBS_INSTALL_NAME "@rpath/libobs.framework/Versions/A/libobs")

	if(NOT EXISTS "${OBS_LIBOBS_LIBRARY}")
		message(FATAL_ERROR "libobs not found at ${OBS_LIBOBS_LIBRARY} - run 'make deps' or install OBS.app")
	endif()
	if(NOT EXISTS "${OBS_LIBOBS_HEADERS_DIR}/obs.h")
		message(FATAL_ERROR "libobs headers not found at ${OBS_LIBOBS_HEADERS_DIR} - run 'make deps'")
	endif()

	find_path(SIMDE_INCLUDE_DIR simde/x86/sse2.h
		HINTS /opt/homebrew/opt/simde/include /usr/local/opt/simde/include
	)
	if(NOT SIMDE_INCLUDE_DIR)
		message(FATAL_ERROR "simde headers not found - run 'brew install simde'")
	endif()

	add_library(OBS::libobs SHARED IMPORTED)
	set_target_properties(OBS::libobs PROPERTIES
		IMPORTED_LOCATION "${OBS_LIBOBS_LIBRARY}"
		INTERFACE_INCLUDE_DIRECTORIES "${OBS_LIBOBS_HEADERS_DIR};${OBS_GENERATED_HEADERS_DIR};${SIMDE_INCLUDE_DIR}"
	)
elseif(WIN32)
	# Cross-compiled from Linux/macOS via mingw-w64 (see
	# cmake/mingw-w64-toolchain.cmake) - nothing is built on actual Windows.
	# Windows OBS builds ship obs.dll but no import library to link against,
	# so 'make deps-windows' (deps-windows.sh) synthesizes obs.lib from
	# obs.dll's export table into .deps/windows/generated, the same way
	# 'make deps' fetches matching libobs headers for macOS.
	set(OBS_STUDIO_DIR "${CMAKE_SOURCE_DIR}/.deps/windows/obs-root" CACHE PATH "Extracted OBS Studio Windows build to link libobs against")
	set(OBS_LIBOBS_HEADERS_DIR "${CMAKE_SOURCE_DIR}/.deps/windows/libobs-headers" CACHE PATH "libobs headers matching OBS_STUDIO_DIR's version")
	set(OBS_GENERATED_HEADERS_DIR "${CMAKE_SOURCE_DIR}/.deps/windows/generated" CACHE PATH "Generated libobs headers (obsconfig.h) and synthesized obs.lib")

	set(OBS_LIBOBS_DLL "${OBS_STUDIO_DIR}/bin/64bit/obs.dll")
	set(OBS_LIBOBS_IMPLIB "${OBS_GENERATED_HEADERS_DIR}/obs.lib")

	if(NOT EXISTS "${OBS_LIBOBS_DLL}")
		message(FATAL_ERROR "obs.dll not found at ${OBS_LIBOBS_DLL} - run 'make deps-windows'")
	endif()
	if(NOT EXISTS "${OBS_LIBOBS_IMPLIB}")
		message(FATAL_ERROR "obs.lib not found at ${OBS_LIBOBS_IMPLIB} - run 'make deps-windows'")
	endif()
	if(NOT EXISTS "${OBS_LIBOBS_HEADERS_DIR}/obs.h")
		message(FATAL_ERROR "libobs headers not found at ${OBS_LIBOBS_HEADERS_DIR} - run 'make deps-windows'")
	endif()

	add_library(OBS::libobs SHARED IMPORTED)
	set_target_properties(OBS::libobs PROPERTIES
		IMPORTED_LOCATION "${OBS_LIBOBS_DLL}"
		IMPORTED_IMPLIB "${OBS_LIBOBS_IMPLIB}"
		INTERFACE_INCLUDE_DIRECTORIES "${OBS_LIBOBS_HEADERS_DIR};${OBS_GENERATED_HEADERS_DIR}"
	)
else()
	find_package(libobs REQUIRED)
endif()

add_library(${CMAKE_PROJECT_NAME} MODULE)

target_sources(${CMAKE_PROJECT_NAME} PRIVATE
	src/plugin-main.c
	src/random-visibility-filter.c
	src/random-visibility-filter.h
)

target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE OBS::libobs)

target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
	PLUGIN_VERSION="${CMAKE_PROJECT_VERSION}"
)

set_target_properties(${CMAKE_PROJECT_NAME} PROPERTIES PREFIX "")

if(APPLE)
	set_target_properties(${CMAKE_PROJECT_NAME} PROPERTIES
		BUNDLE ON
		BUNDLE_EXTENSION "plugin"
	)

	add_custom_command(TARGET ${CMAKE_PROJECT_NAME} POST_BUILD
		COMMAND install_name_tool -change
			"${OBS_LIBOBS_INSTALL_NAME}"
			"@executable_path/../Frameworks/libobs.framework/Versions/A/libobs"
			"$<TARGET_FILE:${CMAKE_PROJECT_NAME}>"
	)
endif()

if(WIN32)
	# Real OBS Windows installs (and C:\ProgramData\obs-studio\plugins\<name>\,
	# see cmake/installer.nsi) expect the .dll one level deeper than
	# mac/Linux's flat obs-plugins/.
	set(OBS_PLUGIN_RUNTIME_DESTINATION "obs-plugins/64bit")
else()
	set(OBS_PLUGIN_RUNTIME_DESTINATION "obs-plugins")
endif()

install(TARGETS ${CMAKE_PROJECT_NAME}
	LIBRARY DESTINATION "${OBS_PLUGIN_RUNTIME_DESTINATION}"
	RUNTIME DESTINATION "${OBS_PLUGIN_RUNTIME_DESTINATION}"
	BUNDLE DESTINATION "obs-plugins"
)

install(DIRECTORY data/ DESTINATION "data/obs-plugins/${CMAKE_PROJECT_NAME}")
