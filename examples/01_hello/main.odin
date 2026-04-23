package example_hello

import "gui:skald"

State :: struct {}
Msg   :: struct {}

init   :: proc()                           -> State                                  { return {} }
update :: proc(s: State, m: Msg)           -> (State, skald.Command(Msg))            { return s, {} }
view   :: proc(s: State, ctx: ^skald.Ctx(Msg)) -> skald.View                         { return {} }

main :: proc() {
	skald.run(skald.App(State, Msg){
		title  = "Skald — Hello",
		size   = {960, 600},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
	})
}
