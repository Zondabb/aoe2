class_name MapDocument
extends RefCounted

const Data := preload("res://scripts/world/map_data.gd")
const HISTORY_LIMIT := 100
var data := Data.create()
var path := ""
var _saved := ""
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []

func _init() -> void:
	mark_saved()

func replace(value: Dictionary, file_path := "") -> void:
	data = value.duplicate(true)
	path = file_path
	_undo.clear()
	_redo.clear()
	mark_saved()

func commit(value: Dictionary) -> bool:
	if JSON.stringify(value) == JSON.stringify(data):
		return false
	_undo.append(data.duplicate(true))
	if _undo.size() > HISTORY_LIMIT:
		_undo.pop_front()
	_redo.clear()
	data = value.duplicate(true)
	return true

func undo() -> bool:
	if _undo.is_empty():
		return false
	_redo.append(data.duplicate(true))
	data = _undo.pop_back()
	return true

func redo() -> bool:
	if _redo.is_empty():
		return false
	_undo.append(data.duplicate(true))
	data = _redo.pop_back()
	return true

func is_dirty() -> bool:
	return JSON.stringify(data) != _saved

func mark_saved() -> void:
	_saved = JSON.stringify(data)
