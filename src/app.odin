package reskia

import rl "vendor:raylib"



App :: struct {
	canvas   : rl.RenderTexture2D,
	timeline : Timeline,
	tool     : Tool,
	camera   : rl.Camera2D,
	drawing  : bool,
}


Timeline :: struct {
	length : int,
}

Tool :: struct {
	name : string,
	size : int
}
