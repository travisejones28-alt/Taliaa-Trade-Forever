#!/usr/bin/env python3
"""Execute addon Lua and deterministic WoW mocks using the system Lua shared library."""
import ctypes, pathlib, sys
lib=ctypes.CDLL('liblua5.4.so.0')
lib.luaL_newstate.restype=ctypes.c_void_p
lib.luaL_openlibs.argtypes=[ctypes.c_void_p]
lib.luaL_loadfilex.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p]
lib.lua_pcallk.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_longlong,ctypes.c_void_p]
lib.lua_tolstring.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_size_t)];lib.lua_tolstring.restype=ctypes.c_char_p
lib.lua_close.argtypes=[ctypes.c_void_p]
lib.lua_pushstring.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
lib.lua_setglobal.argtypes=[ctypes.c_void_p,ctypes.c_char_p]
state=lib.luaL_newstate();lib.luaL_openlibs(state)
root=pathlib.Path(__file__).resolve().parent.parent
addon=root if (root/'Core.lua').exists() else root/'project'/'VoidMarkMarket'
lib.lua_pushstring(state,(str(addon)+'/').encode());lib.lua_setglobal(state,b'VMM_ADDON_PATH')
status=lib.luaL_loadfilex(state,str(pathlib.Path(__file__).with_name('test_addon.lua')).encode(),None)
if status==0:status=lib.lua_pcallk(state,0,-1,0,0,None)
if status:print(lib.lua_tolstring(state,-1,None).decode(),file=sys.stderr)
lib.lua_close(state);sys.exit(1 if status else 0)
