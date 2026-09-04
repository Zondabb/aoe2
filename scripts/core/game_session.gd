extends Node

var player_civ_id: StringName = &"chinese"
var ai_civ_id: StringName = &"teutons"
## AI HTTP 服务地址；空则使用内嵌 LocalAiServer 默认端口。
var ai_service_url := ""
var ai_service_timeout_sec := 2.0
var ai_use_local_embedded := true
var ai_protocol_version := 1
