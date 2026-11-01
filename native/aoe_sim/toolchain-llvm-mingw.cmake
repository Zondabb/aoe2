# Windows x86_64 with llvm-mingw (https://github.com/mstorsjo/llvm-mingw),
# from a Linux or Windows host. Pass -DLLVM_MINGW=<llvm-mingw directory>.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
if(CMAKE_HOST_WIN32)
    set(_aoe_exe ".exe")
else()
    set(_aoe_exe "")
endif()
set(CMAKE_C_COMPILER "${LLVM_MINGW}/bin/x86_64-w64-mingw32-clang${_aoe_exe}")
set(CMAKE_CXX_COMPILER "${LLVM_MINGW}/bin/x86_64-w64-mingw32-clang++${_aoe_exe}")
set(CMAKE_RC_COMPILER "${LLVM_MINGW}/bin/x86_64-w64-mingw32-windres${_aoe_exe}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
