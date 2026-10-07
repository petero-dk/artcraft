set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreaded)
set(CMAKE_USER_MAKE_RULES_OVERRIDE "${CMAKE_CURRENT_LIST_FILE}")

foreach(language C CXX)
	foreach(configuration DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
		string(REGEX REPLACE "([/-])MDd?" "\\1MT"
			CMAKE_${language}_FLAGS_${configuration}_INIT
			"${CMAKE_${language}_FLAGS_${configuration}_INIT}")
	endforeach()
endforeach()